// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-20 interface (only what the escrow needs).
interface IERC20V2 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title FreelanceEscrowV2 — tUSD8 Freelance Pay (open job board edition)
/// @notice Escrow for freelance jobs paid in tUSD8 on QDay Aevum testnet.
///         V2 adds OPEN jobs alongside direct hire: a client can post a job
///         with no freelancer assigned, and the first freelancer to claim it
///         takes it. Claiming is not a guarantee of work — the client funds
///         (deposits) only a claimer they accept, and until deposit either
///         side can walk away (free cancel before funding). That funding
///         decision is the qualification gate.
///         The refund guard is unchanged from V1: free cancel before funding,
///         deadline-gated once funded, deadline + 3-day review window after
///         delivery.
contract FreelanceEscrowV2 {
    enum State {
        Created,
        Accepted,
        Funded,
        Delivered,
        Released,
        Refunded
    }

    struct Agreement {
        address client;
        address freelancer; // address(0) while an open job is unclaimed
        uint256 amount; // in tUSD8 (6 decimals)
        string title;
        string description;
        uint256 deadline; // unix timestamp
        State state;
        string deliverableProof; // link or hash attached on delivery
        uint256 createdAt;
        uint256 fundedAt;
        uint256 deliveredAt;
    }

    /// @notice How long after delivery the client must act before a
    ///         post-delivery refund can unlock (together with the deadline).
    uint256 public constant REVIEW_WINDOW = 3 days;

    IERC20V2 public immutable token;
    uint256 public agreementCount;
    mapping(uint256 => Agreement) public agreements;

    event AgreementCreated(
        uint256 indexed id, address indexed client, address indexed freelancer, uint256 amount, uint256 deadline
    );
    event AgreementClaimed(uint256 indexed id, address indexed freelancer);
    event AgreementAccepted(uint256 indexed id);
    event AgreementFunded(uint256 indexed id, uint256 amount);
    event AgreementDelivered(uint256 indexed id, string proof);
    event AgreementReleased(uint256 indexed id, uint256 amount);
    event AgreementRefunded(uint256 indexed id, uint256 amount);

    error NotClient(uint256 id);
    error NotFreelancer(uint256 id);
    error WrongState(uint256 id, State state);
    error InvalidTerms();
    error TransferFailed();
    error RefundLocked(uint256 id);

    constructor(address tokenAddress) {
        require(tokenAddress != address(0), "token is zero address");
        token = IERC20V2(tokenAddress);
    }

    /// @notice Create a job agreement in the Created state.
    /// @param freelancer The freelancer's address for a direct hire, or
    ///        address(0) to post an OPEN job any freelancer can claim.
    /// @return id The new agreement id.
    function createAgreement(address freelancer, uint256 amount, uint256 deadline, string calldata title, string calldata description)
        external
        returns (uint256 id)
    {
        if (freelancer == msg.sender) revert InvalidTerms();
        if (amount == 0) revert InvalidTerms();
        if (deadline <= block.timestamp) revert InvalidTerms();

        id = agreementCount++;
        Agreement storage a = agreements[id];
        a.client = msg.sender;
        a.freelancer = freelancer;
        a.amount = amount;
        a.title = title;
        a.description = description;
        a.deadline = deadline;
        a.state = State.Created;
        a.createdAt = block.timestamp;

        emit AgreementCreated(id, msg.sender, freelancer, amount, deadline);
    }

    /// @notice Accept a direct-hire agreement, or CLAIM an open job.
    /// @dev On an open job (freelancer unset) any account except the client
    ///      claims it and becomes the freelancer. On a direct hire only the
    ///      named freelancer can accept. Either way the state moves to
    ///      Accepted; the client still decides whether to fund the job.
    function acceptAgreement(uint256 id) external {
        Agreement storage a = agreements[id];
        if (a.state != State.Created) revert WrongState(id, a.state);
        if (a.freelancer == address(0)) {
            if (msg.sender == a.client) revert NotFreelancer(id);
            a.freelancer = msg.sender;
            emit AgreementClaimed(id, msg.sender);
        } else {
            if (msg.sender != a.freelancer) revert NotFreelancer(id);
        }
        a.state = State.Accepted;
        emit AgreementAccepted(id);
    }

    /// @notice Client deposits the agreed tUSD8 into escrow.
    /// @dev Caller must have approved this contract for at least `amount`.
    function deposit(uint256 id) external {
        Agreement storage a = agreements[id];
        if (msg.sender != a.client) revert NotClient(id);
        if (a.state != State.Accepted) revert WrongState(id, a.state);
        if (!token.transferFrom(msg.sender, address(this), a.amount)) revert TransferFailed();
        a.state = State.Funded;
        a.fundedAt = block.timestamp;
        emit AgreementFunded(id, a.amount);
    }

    /// @notice Freelancer marks the job delivered and attaches proof.
    function markDelivered(uint256 id, string calldata proof) external {
        Agreement storage a = agreements[id];
        if (msg.sender != a.freelancer) revert NotFreelancer(id);
        if (a.state != State.Funded) revert WrongState(id, a.state);
        a.deliverableProof = proof;
        a.state = State.Delivered;
        a.deliveredAt = block.timestamp;
        emit AgreementDelivered(id, proof);
    }

    /// @notice Client releases the escrowed tUSD8 to the freelancer.
    function release(uint256 id) external {
        Agreement storage a = agreements[id];
        if (msg.sender != a.client) revert NotClient(id);
        if (a.state != State.Delivered) revert WrongState(id, a.state);
        a.state = State.Released;
        if (!token.transfer(a.freelancer, a.amount)) revert TransferFailed();
        emit AgreementReleased(id, a.amount);
    }

    /// @notice Client refunds under the guard rules:
    ///         - Created / Accepted: always (nothing deposited yet).
    ///         - Funded: only after the deadline (freelancer never delivered).
    ///         - Delivered: only after BOTH the deadline and the review
    ///           window since delivery have passed.
    function refund(uint256 id) external {
        Agreement storage a = agreements[id];
        if (msg.sender != a.client) revert NotClient(id);

        if (a.state == State.Created || a.state == State.Accepted) {
            a.state = State.Refunded;
            emit AgreementRefunded(id, 0);
            return;
        }
        if (a.state == State.Funded) {
            if (block.timestamp <= a.deadline) revert RefundLocked(id);
            a.state = State.Refunded;
            if (!token.transfer(a.client, a.amount)) revert TransferFailed();
            emit AgreementRefunded(id, a.amount);
            return;
        }
        if (a.state == State.Delivered) {
            if (block.timestamp <= a.deadline || block.timestamp <= a.deliveredAt + REVIEW_WINDOW) {
                revert RefundLocked(id);
            }
            a.state = State.Refunded;
            if (!token.transfer(a.client, a.amount)) revert TransferFailed();
            emit AgreementRefunded(id, a.amount);
            return;
        }
        revert WrongState(id, a.state);
    }

    /// @notice Read a full agreement.
    function getAgreement(uint256 id) external view returns (Agreement memory) {
        return agreements[id];
    }
}
