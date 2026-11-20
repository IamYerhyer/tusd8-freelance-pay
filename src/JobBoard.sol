// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 interface (only what the board needs).
interface IERC20Board {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title JobBoard — tUSD8 Freelance Pay (remote-work board edition)
/// @notice A Web3 remote-work board in the style of Mercor / Micro1 /
///         Microworkers, paid in tUSD8 on QDay Aevum testnet.
///         - A client posts a job with a pay-per-spot and a LIMITED number
///           of spots, and funds the full budget into escrow up front —
///           so every spot on the board is real, paid-for work.
///         - Freelancers APPLY for spots. The client approves the qualified
///           ones (that approval is the qualification gate); spots fill
///           first-come, first-approved until none are left.
///         - An approved freelancer delivers with proof; the client releases
///           that spot's pay from the pool. The refund guard protects both
///           sides: an undelivered spot can be reclaimed only after the
///           deadline, and a delivered spot only after the deadline AND a
///           3-day review window have passed.
///         - After the deadline (+ review window) the client closes the
///           posting and the unspent budget returns to them.
contract JobBoard {
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
        Refunded
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
    }

    uint256 public constant REVIEW_WINDOW = 3 days;

    IERC20Board public immutable token;
    uint256 public postingCount;
    uint256 public assignmentCount;
    mapping(uint256 => Posting) public postings;
    mapping(uint256 => Assignment) public assignments;
    mapping(uint256 => mapping(address => bool)) public hasApplied;

    event PostingCreated(uint256 indexed id, address indexed client, uint256 amountPerSpot, uint256 spots, uint256 deadline);
    event PostingClosed(uint256 indexed id, uint256 returnedAmount);
    event Applied(uint256 indexed assignmentId, uint256 indexed postingId, address indexed freelancer);
    event Approved(uint256 indexed assignmentId, uint256 indexed postingId);
    event Rejected(uint256 indexed assignmentId, uint256 indexed postingId);
    event Delivered(uint256 indexed assignmentId, string proof);
    event Released(uint256 indexed assignmentId, uint256 amount);
    event AssignmentRefunded(uint256 indexed assignmentId, uint256 amount);

    error NotClient(uint256 id);
    error NotFreelancer(uint256 id);
    error WrongState(uint256 id);
    error InvalidTerms();
    error TransferFailed();
    error RefundLocked(uint256 id);
    error AlreadyApplied(uint256 postingId);
    error NoSpotsLeft(uint256 postingId);
    error PostingNotOpen(uint256 postingId);

    constructor(address tokenAddress) {
        require(tokenAddress != address(0), "token is zero address");
        token = IERC20Board(tokenAddress);
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

    /// @notice Client releases one spot's pay to its freelancer.
    function release(uint256 assignmentId) external {
        Assignment storage a = assignments[assignmentId];
        Posting storage p = postings[a.postingId];
        if (msg.sender != p.client) revert NotClient(assignmentId);
        if (a.state != AssignmentState.Delivered) revert WrongState(assignmentId);
        a.state = AssignmentState.Released;
        p.releasedCount++;
        if (!token.transfer(a.freelancer, p.amountPerSpot)) revert TransferFailed();
        emit Released(assignmentId, p.amountPerSpot);
    }

    /// @notice Client reclaims one spot's pay under the guard:
    ///         - Approved (never delivered): only after the deadline.
    ///         - Delivered: only after BOTH the deadline and the review
    ///           window since delivery have passed.
    ///         The amount returns to the client immediately.
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
        if (!token.transfer(p.client, p.amountPerSpot)) revert TransferFailed();
        emit AssignmentRefunded(assignmentId, p.amountPerSpot);
    }

    /// @notice Close a posting after the deadline + review window: any
    ///         non-terminal assignments are settled as refunded/rejected,
    ///         and the whole unspent budget returns to the client.
    function closePosting(uint256 postingId) external {
        Posting storage p = postings[postingId];
        if (msg.sender != p.client) revert NotClient(postingId);
        if (p.state != PostingState.Open) revert WrongState(postingId);
        if (block.timestamp <= p.deadline + REVIEW_WINDOW) revert RefundLocked(postingId);
        p.state = PostingState.Closed;
        uint256 unspent = (p.spotsTotal - p.releasedCount - p.refundedCount) * p.amountPerSpot;
        // Approved/Delivered assignments that never settled are refunded by
        // this close (their amounts are inside `unspent`); Applied ones are
        // simply left unapproved. Mark the live ones Refunded for a clean record.
        for (uint256 i = 0; i < assignmentCount; i++) {
            Assignment storage a = assignments[i];
            if (a.postingId == postingId && (a.state == AssignmentState.Approved || a.state == AssignmentState.Delivered)) {
                a.state = AssignmentState.Refunded;
                p.refundedCount++;
            }
        }
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
