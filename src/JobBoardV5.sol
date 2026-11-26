// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 interface (only what the board needs).
interface IERC20BoardV5 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title JobBoardV5 — tUSD8 Freelance Pay (board + disputes + client ratings)
/// @notice Everything the V3 JobBoard does, plus the two trust mechanisms
///         the board was missing:
///         - DISPUTES: once work is delivered, either side can open a
///           dispute. The spot's money freezes (no client refund, no
///           forced settlement on close) until a neutral ARBITRATOR —
///           named at deployment — reviews the delivery against the job's
///           requirements and rules release (pay the freelancer) or
///           refund (return to the client). The client can still settle
///           voluntarily by releasing while a dispute is open.
///         - TWO-WAY RATINGS: a freelancer who has actually held a settled
///           spot with a client (paid or refunded) can give that client a
///           thumbs up or thumbs down, changeable at any time — and the
///           client can rate the freelancer back on the same terms. The
///           counts are public badges: the client's rides on their jobs
///           (judge before applying), the freelancer's rides on their
///           applications (judge before approving).
contract JobBoardV5 {
    enum PostingState {
        Open,
        Closed
    }

    enum AssignmentState {
        Applied,
        Approved,
        Delivered,
        Released,
        Rejected,
        Refunded,
        Disputed
    }

    struct Posting {
        address client;
        uint256 amountPerSpot; // tUSD8 (6 decimals)
        uint256 spotsTotal;
        uint256 spotsFilled; // approved assignments
        uint256 releasedCount;
        uint256 refundedCount;
        uint256 deadline;
        string title;
        string description; // includes category + requirements lines
        PostingState state;
        uint256 createdAt;
    }

    struct Assignment {
        uint256 postingId;
        address freelancer;
        AssignmentState state;
        string proof;
        uint256 appliedAt;
        uint256 deliveredAt;
        uint256 disputedAt;
        address disputeBy;
    }

    uint256 public constant REVIEW_WINDOW = 3 days;

    IERC20BoardV5 public immutable token;
    address public arbitrator;
    uint256 public postingCount;
    uint256 public assignmentCount;
    mapping(uint256 => Posting) public postings;
    mapping(uint256 => Assignment) public assignments;
    mapping(uint256 => mapping(address => bool)) public hasApplied;

    /// @notice freelancer => client => true once any of their spots with
    ///         that client has settled (Released or Refunded). Gates ratings.
    mapping(address => mapping(address => bool)) public hasWorkedWith;
    /// @notice client => rater => current thumb (+1 / -1 / 0 = none).
    mapping(address => mapping(address => int8)) public ratingOf;
    mapping(address => uint256) public clientUpvotes;
    mapping(address => uint256) public clientDownvotes;
    /// @notice freelancer => rater (a client) => current thumb (+1 / -1 / 0).
    mapping(address => mapping(address => int8)) public freelancerRatingOf;
    mapping(address => uint256) public freelancerUpvotes;
    mapping(address => uint256) public freelancerDownvotes;

    event PostingCreated(uint256 indexed id, address indexed client, uint256 amountPerSpot, uint256 spots, uint256 deadline);
    event PostingClosed(uint256 indexed id, uint256 returnedAmount);
    event Applied(uint256 indexed assignmentId, uint256 indexed postingId, address indexed freelancer);
    event Approved(uint256 indexed assignmentId, uint256 indexed postingId);
    event Rejected(uint256 indexed assignmentId, uint256 indexed postingId);
    event Delivered(uint256 indexed assignmentId, string proof);
    event Released(uint256 indexed assignmentId, uint256 amount);
    event AssignmentRefunded(uint256 indexed assignmentId, uint256 amount);
    event DisputeOpened(uint256 indexed assignmentId, uint256 indexed postingId, address indexed openedBy);
    event DisputeResolved(uint256 indexed assignmentId, bool paidFreelancer);
    event ArbitratorChanged(address indexed newArbitrator);
    event ClientRated(address indexed client, address indexed rater, bool up);
    event FreelancerRated(address indexed freelancer, address indexed rater, bool up);

    error NotClient(uint256 id);
    error NotFreelancer(uint256 id);
    error WrongState(uint256 id);
    error InvalidTerms();
    error TransferFailed();
    error RefundLocked(uint256 id);
    error AlreadyApplied(uint256 postingId);
    error NoSpotsLeft(uint256 postingId);
    error PostingNotOpen(uint256 postingId);
    error NotParty(uint256 id);
    error NotArbitrator();
    error NotEligibleToRate(address client);
    error NotEligibleToRateFreelancer(address freelancer);

    constructor(address tokenAddress, address arbitratorAddress) {
        require(tokenAddress != address(0), "token is zero address");
        require(arbitratorAddress != address(0), "arbitrator is zero address");
        token = IERC20BoardV5(tokenAddress);
        arbitrator = arbitratorAddress;
    }

    /// @notice The sitting arbitrator can hand the role to a new address.
    function transferArbitrator(address newArbitrator) external {
        if (msg.sender != arbitrator) revert NotArbitrator();
        require(newArbitrator != address(0), "arbitrator is zero address");
        arbitrator = newArbitrator;
        emit ArbitratorChanged(newArbitrator);
    }

    /// @notice Post a job and fund its full budget into escrow.
    /// @dev Caller must have approved this contract for amountPerSpot * spots.
    function createPosting(uint256 amountPerSpot, uint256 spots, uint256 deadline, string calldata title, string calldata description)
        external
        returns (uint256 id)
    {
        if (amountPerSpot == 0 || spots == 0) revert InvalidTerms();
        if (deadline <= block.timestamp) revert InvalidTerms();
        uint256 total = amountPerSpot * spots;
        if (!token.transferFrom(msg.sender, address(this), total)) revert TransferFailed();

        id = postingCount++;
        Posting storage p = postings[id];
        p.client = msg.sender;
        p.amountPerSpot = amountPerSpot;
        p.spotsTotal = spots;
        p.deadline = deadline;
        p.title = title;
        p.description = description;
        p.state = PostingState.Open;
        p.createdAt = block.timestamp;

        emit PostingCreated(id, msg.sender, amountPerSpot, spots, deadline);
    }

    /// @notice Apply for a spot on an open posting (one application per wallet).
    function applyForSpot(uint256 postingId) external returns (uint256 assignmentId) {
        Posting storage p = postings[postingId];
        if (p.state != PostingState.Open) revert PostingNotOpen(postingId);
        if (msg.sender == p.client) revert InvalidTerms();
        if (hasApplied[postingId][msg.sender]) revert AlreadyApplied(postingId);
        if (block.timestamp > p.deadline) revert PostingNotOpen(postingId);

        assignmentId = assignmentCount++;
        Assignment storage a = assignments[assignmentId];
        a.postingId = postingId;
        a.freelancer = msg.sender;
        a.state = AssignmentState.Applied;
        a.appliedAt = block.timestamp;
        hasApplied[postingId][msg.sender] = true;

        emit Applied(assignmentId, postingId, msg.sender);
    }

    /// @notice Client approves a qualified applicant — this allocates a spot.
    function approveApplication(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != p.client) revert NotClient(assignmentId);
        if (a.state != AssignmentState.Applied) revert WrongState(assignmentId);
        if (p.state != PostingState.Open) revert PostingNotOpen(a.postingId);
        if (p.spotsFilled >= p.spotsTotal) revert NoSpotsLeft(a.postingId);
        a.state = AssignmentState.Approved;
        p.spotsFilled++;
        emit Approved(assignmentId, a.postingId);
    }

    /// @notice Client rejects an application (frees nothing — no spot was held).
    function rejectApplication(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != p.client) revert NotClient(assignmentId);
        if (a.state != AssignmentState.Applied) revert WrongState(assignmentId);
        a.state = AssignmentState.Rejected;
        emit Rejected(assignmentId, a.postingId);
    }

    /// @notice Approved freelancer delivers the work with proof.
    function deliver(uint256 assignmentId, string calldata proof) external {
        Assignment storage a = assignments[assignmentId];
        if (msg.sender != a.freelancer) revert NotFreelancer(assignmentId);
        if (a.state != AssignmentState.Approved) revert WrongState(assignmentId);
        a.proof = proof;
        a.state = AssignmentState.Delivered;
        a.deliveredAt = block.timestamp;
        emit Delivered(assignmentId, proof);
    }

    /// @notice Client releases one spot's pay to its freelancer. Also the
    ///         voluntary settlement path while a dispute is open.
    function release(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != p.client) revert NotClient(assignmentId);
        if (a.state != AssignmentState.Delivered && a.state != AssignmentState.Disputed) {
            revert WrongState(assignmentId);
        }
        a.state = AssignmentState.Released;
        p.releasedCount++;
        hasWorkedWith[a.freelancer][p.client] = true;
        if (!token.transfer(a.freelancer, p.amountPerSpot)) revert TransferFailed();
        emit Released(assignmentId, p.amountPerSpot);
    }

    /// @notice Client reclaims one spot's pay under the guard:
    ///         - Approved (never delivered): only after the deadline.
    ///         - Delivered: only after BOTH the deadline and the review
    ///           window since delivery have passed.
    ///         A Disputed spot is frozen — this reverts until the
    ///         arbitrator rules.
    function refundAssignment(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != p.client) revert NotClient(assignmentId);
        if (a.state == AssignmentState.Approved) {
            if (block.timestamp <= p.deadline) revert RefundLocked(assignmentId);
        } else if (a.state == AssignmentState.Delivered) {
            if (block.timestamp <= p.deadline || block.timestamp <= a.deliveredAt + REVIEW_WINDOW) {
                revert RefundLocked(assignmentId);
            }
        } else {
            revert WrongState(assignmentId);
        }
        a.state = AssignmentState.Refunded;
        p.refundedCount++;
        hasWorkedWith[a.freelancer][p.client] = true;
        if (!token.transfer(p.client, p.amountPerSpot)) revert TransferFailed();
        emit AssignmentRefunded(assignmentId, p.amountPerSpot);
    }

    /// @notice Either side of a delivered spot can open a dispute. The
    ///         spot's pay freezes until the arbitrator rules (or the
    ///         client settles voluntarily with release()).
    function openDispute(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != a.freelancer && msg.sender != p.client) revert NotParty(assignmentId);
        if (a.state != AssignmentState.Delivered) revert WrongState(assignmentId);
        a.state = AssignmentState.Disputed;
        a.disputedAt = block.timestamp;
        a.disputeBy = msg.sender;
        emit DisputeOpened(assignmentId, a.postingId, msg.sender);
    }

    /// @notice The arbitrator rules on a disputed spot: pay the freelancer
    ///         (the work stands) or refund the client (it does not).
    function resolveDispute(uint256 assignmentId, bool payFreelancer) external {
        if (msg.sender != arbitrator) revert NotArbitrator();
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (a.state != AssignmentState.Disputed) revert WrongState(assignmentId);
        hasWorkedWith[a.freelancer][p.client] = true;
        if (payFreelancer) {
            a.state = AssignmentState.Released;
            p.releasedCount++;
            if (!token.transfer(a.freelancer, p.amountPerSpot)) revert TransferFailed();
            emit Released(assignmentId, p.amountPerSpot);
        } else {
            a.state = AssignmentState.Refunded;
            p.refundedCount++;
            if (!token.transfer(p.client, p.amountPerSpot)) revert TransferFailed();
            emit AssignmentRefunded(assignmentId, p.amountPerSpot);
        }
        emit DisputeResolved(assignmentId, payFreelancer);
    }

    /// @notice Give a client a thumbs up or down. Only wallets that have
    ///         actually held a settled spot with that client may rate, one
    ///         thumb per wallet, changeable at any time. The counts are the
    ///         public badge freelancers see before applying.
    function rateClient(address client, bool up) external {
        if (!hasWorkedWith[msg.sender][client]) revert NotEligibleToRate(client);
        int8 next = up ? int8(1) : int8(-1);
        int8 prev = ratingOf[client][msg.sender];
        if (prev == next) return; // same thumb again — nothing changes
        if (prev == 1) clientUpvotes[client]--;
        if (prev == -1) clientDownvotes[client]--;
        if (next == 1) clientUpvotes[client]++;
        if (next == -1) clientDownvotes[client]++;
        ratingOf[client][msg.sender] = next;
        emit ClientRated(client, msg.sender, up);
    }

    /// @notice The public badge: thumbs up / thumbs down counts for a client.
    function clientRating(address client) external view returns (uint256 up, uint256 down) {
        return (clientUpvotes[client], clientDownvotes[client]);
    }

    /// @notice Give a freelancer a thumbs up or down. Only clients that
    ///         have actually held a settled spot with that freelancer may
    ///         rate, one thumb per client, changeable at any time. The
    ///         counts are the public badge shown on their applications.
    function rateFreelancer(address freelancer, bool up) external {
        if (!hasWorkedWith[freelancer][msg.sender]) revert NotEligibleToRateFreelancer(freelancer);
        int8 next = up ? int8(1) : int8(-1);
        int8 prev = freelancerRatingOf[freelancer][msg.sender];
        if (prev == next) return; // same thumb again — nothing changes
        if (prev == 1) freelancerUpvotes[freelancer]--;
        if (prev == -1) freelancerDownvotes[freelancer]--;
        if (next == 1) freelancerUpvotes[freelancer]++;
        if (next == -1) freelancerDownvotes[freelancer]++;
        freelancerRatingOf[freelancer][msg.sender] = next;
        emit FreelancerRated(freelancer, msg.sender, up);
    }

    /// @notice The public badge: thumbs up / thumbs down counts for a freelancer.
    function freelancerRating(address freelancer) external view returns (uint256 up, uint256 down) {
        return (freelancerUpvotes[freelancer], freelancerDownvotes[freelancer]);
    }

    /// @notice Close a posting after the deadline + review window: any
    ///         non-terminal assignments are settled as refunded/rejected,
    ///         and the whole unspent budget returns to the client. Disputed
    ///         spots are NOT touched — their pay stays locked until the
    ///         arbitrator rules, even on a closed posting.
    function closePosting(uint256 postingId) external {
        Posting storage p = postings[postingId];
        if (msg.sender != p.client) revert NotClient(postingId);
        if (p.state != PostingState.Open) revert WrongState(postingId);
        if (block.timestamp <= p.deadline + REVIEW_WINDOW) revert RefundLocked(postingId);
        p.state = PostingState.Closed;
        // Unspent is computed from the counts BEFORE this loop marks the
        // live assignments Refunded — those spots' pay returns through this
        // transfer. Disputed spots are excluded: their pay stays locked.
        uint256 base = p.spotsTotal - p.releasedCount - p.refundedCount;
        uint256 disputedLive = 0;
        for (uint256 i = 0; i < assignmentCount; i++) {
            Assignment storage a = assignments[i];
            if (a.postingId != postingId) continue;
            if (a.state == AssignmentState.Approved || a.state == AssignmentState.Delivered) {
                a.state = AssignmentState.Refunded;
                p.refundedCount++;
                hasWorkedWith[a.freelancer][p.client] = true;
            } else if (a.state == AssignmentState.Disputed) {
                disputedLive++;
            }
        }
        uint256 unspent = (base - disputedLive) * p.amountPerSpot;
        if (unspent > 0 && !token.transfer(p.client, unspent)) revert TransferFailed();
        emit PostingClosed(postingId, unspent);
    }

    function getPosting(uint256 id) external view returns (Posting memory) {
        return postings[id];
    }

    function getAssignment(uint256 id) external view returns (Assignment memory) {
        return assignments[id];
    }
}
