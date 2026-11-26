// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {JobBoardV5} from "../src/JobBoardV5.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm5 {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
}

contract JobBoardV5Test {
    Vm5 constant vm = Vm5(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockTUSD8 token;
    JobBoardV5 board;

    address client = address(0xC11E47);
    address worker1 = address(0xF2EE1A);
    address worker2 = address(0x5EC02D);
    address arb = address(0xA2B17E);
    address stranger = address(0x57A9E2);

    uint256 constant PER_SPOT = 1 * 10 ** 6; // 1 tUSD8
    uint256 deadline;

    function setUp() public {
        token = new MockTUSD8();
        board = new JobBoardV5(address(token), arb);
        deadline = block.timestamp + 7 days;
        token.mint(client, 100 * 10 ** 6);
    }

    function _posting(uint256 spots) internal returns (uint256 id) {
        vm.prank(client);
        token.approve(address(board), PER_SPOT * spots);
        vm.prank(client);
        id = board.createPosting(PER_SPOT, spots, deadline, "Label images", "Category: AI training & evaluation");
    }

    function _approved(uint256 postingId, address worker) internal returns (uint256 aid) {
        vm.prank(worker);
        aid = board.applyForSpot(postingId);
        vm.prank(client);
        board.approveApplication(aid);
    }

    function _delivered(uint256 postingId, address worker) internal returns (uint256 aid) {
        aid = _approved(postingId, worker);
        vm.prank(worker);
        board.deliver(aid, "https://files.example/work.csv");
    }

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function assertState(uint256 aid, JobBoardV5.AssignmentState want, string memory what) internal view {
        JobBoardV5.Assignment memory a = board.getAssignment(aid);
        require(a.state == want, what);
    }

    // ---------- base board behaviour (spot-check the inherited flow) ----------

    function testBaseFlowStillWorks() public {
        uint256 id = _posting(2);
        uint256 aid = _delivered(id, worker1);
        uint256 before = token.balanceOf(worker1);
        vm.prank(client);
        board.release(aid);
        assertEq(token.balanceOf(worker1), before + PER_SPOT, "worker paid one spot");
        assertState(aid, JobBoardV5.AssignmentState.Released, "released state");
    }

    // ---------- disputes ----------

    function testFreelancerOpensDisputeAfterDelivery() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(worker1);
        board.openDispute(aid);
        assertState(aid, JobBoardV5.AssignmentState.Disputed, "state is disputed");
        JobBoardV5.Assignment memory a = board.getAssignment(aid);
        require(a.disputeBy == worker1, "dispute opener recorded");
    }

    function testClientCanOpenDisputeToo() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.openDispute(aid);
        assertState(aid, JobBoardV5.AssignmentState.Disputed, "client-opened dispute");
    }

    function testStrangerCannotOpenDispute() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(stranger);
        vm.expectRevert();
        board.openDispute(aid);
    }

    function testCannotDisputeBeforeDelivery() public {
        uint256 id = _posting(1);
        uint256 aid = _approved(id, worker1);
        vm.prank(worker1);
        vm.expectRevert();
        board.openDispute(aid);
    }

    function testRefundFrozenWhileDisputed() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(worker1);
        board.openDispute(aid);
        vm.warp(deadline + 3 days + 1); // even past every guard window
        vm.prank(client);
        vm.expectRevert();
        board.refundAssignment(aid);
    }

    function testClientCanSettleDisputeByReleasing() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(worker1);
        board.openDispute(aid);
        uint256 before = token.balanceOf(worker1);
        vm.prank(client);
        board.release(aid);
        assertEq(token.balanceOf(worker1), before + PER_SPOT, "settled by release");
        assertState(aid, JobBoardV5.AssignmentState.Released, "released after dispute");
    }

    function testArbitratorPaysFreelancer() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(worker1);
        board.openDispute(aid);
        uint256 before = token.balanceOf(worker1);
        vm.prank(arb);
        board.resolveDispute(aid, true);
        assertEq(token.balanceOf(worker1), before + PER_SPOT, "arbitrator paid the freelancer");
        assertState(aid, JobBoardV5.AssignmentState.Released, "resolved as released");
    }

    function testArbitratorRefundsClient() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.openDispute(aid);
        uint256 before = token.balanceOf(client);
        vm.prank(arb);
        board.resolveDispute(aid, false);
        assertEq(token.balanceOf(client), before + PER_SPOT, "arbitrator refunded the client");
        assertState(aid, JobBoardV5.AssignmentState.Refunded, "resolved as refunded");
    }

    function testOnlyArbitratorResolves() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(worker1);
        board.openDispute(aid);
        vm.prank(client);
        vm.expectRevert();
        board.resolveDispute(aid, true);
        vm.prank(worker1);
        vm.expectRevert();
        board.resolveDispute(aid, true);
    }

    function testClosePostingSkipsDisputedSpots() public {
        uint256 id = _posting(2);
        uint256 a1 = _delivered(id, worker1);
        uint256 a2 = _delivered(id, worker2);
        vm.prank(worker1);
        board.openDispute(a1); // a1 disputed, a2 just delivered

        vm.warp(deadline + 3 days + 1);
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        board.closePosting(id);
        // a2 force-refunded (1 spot back); a1's spot stays locked in the pool.
        assertEq(token.balanceOf(client), before + PER_SPOT, "only the undisputed spot returned");
        assertEq(token.balanceOf(address(board)), PER_SPOT, "disputed spot stays locked");
        assertState(a1, JobBoardV5.AssignmentState.Disputed, "dispute survives the close");
        assertState(a2, JobBoardV5.AssignmentState.Refunded, "undisputed spot refunded by close");

        vm.prank(arb); // and the arbitrator can still rule afterwards
        board.resolveDispute(a1, true);
        assertEq(token.balanceOf(address(board)), 0, "pool empty after ruling");
    }

    function testArbitratorHandover() public {
        address next = address(0xBEEF);
        vm.prank(client); // non-arbitrator cannot hand over
        vm.expectRevert();
        board.transferArbitrator(next);
        vm.prank(arb);
        board.transferArbitrator(next);
        require(board.arbitrator() == next, "arbitrator handed over");
    }

    // ---------- client ratings ----------

    function testCannotRateWithoutWorkingTogether() public {
        vm.prank(stranger);
        vm.expectRevert();
        board.rateClient(client, true);
    }

    function testCannotRateBeforeSettlement() public {
        uint256 id = _posting(1);
        _delivered(id, worker1); // delivered but not settled yet
        vm.prank(worker1);
        vm.expectRevert();
        board.rateClient(client, true);
    }

    function testThumbsUpAfterRelease() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.release(aid);
        vm.prank(worker1);
        board.rateClient(client, true);
        (uint256 up, uint256 down) = board.clientRating(client);
        assertEq(up, 1, "one thumbs up");
        assertEq(down, 0, "no thumbs down");
    }

    function testThumbsDownAfterGuardRefund() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        // Delivered refund needs block.timestamp past BOTH the deadline and
        // deliveredAt + REVIEW_WINDOW; deadline + 3 days satisfies both.
        vm.warp(deadline + 3 days + 1);
        vm.prank(client);
        board.refundAssignment(aid);
        vm.prank(worker1);
        board.rateClient(client, false);
        (uint256 up, uint256 down) = board.clientRating(client);
        assertEq(up, 0, "no thumbs up");
        assertEq(down, 1, "one thumbs down after guard refund");
    }

    function testThumbsDownViaDisputeRefund() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.openDispute(aid);
        vm.prank(arb);
        board.resolveDispute(aid, false); // refunded by ruling — still a real experience
        vm.prank(worker1);
        board.rateClient(client, false);
        (uint256 up, uint256 down) = board.clientRating(client);
        assertEq(up, 0, "no thumbs up");
        assertEq(down, 1, "one thumbs down");
    }

    function testThumbCanFlipAndCountsAdjust() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.release(aid);
        vm.prank(worker1);
        board.rateClient(client, true);
        vm.prank(worker1);
        board.rateClient(client, true); // same thumb again — idempotent
        (uint256 up, uint256 down) = board.clientRating(client);
        assertEq(up, 1, "still one up after repeat");
        assertEq(down, 0, "still no down");
        vm.prank(worker1);
        board.rateClient(client, false); // flip
        (up, down) = board.clientRating(client);
        assertEq(up, 0, "up removed on flip");
        assertEq(down, 1, "down added on flip");
    }

    function testTwoFreelancersRateIndependently() public {
        uint256 id = _posting(2);
        uint256 a1 = _delivered(id, worker1);
        uint256 a2 = _delivered(id, worker2);
        vm.prank(client);
        board.release(a1);
        vm.prank(client);
        board.release(a2);
        vm.prank(worker1);
        board.rateClient(client, true);
        vm.prank(worker2);
        board.rateClient(client, false);
        (uint256 up, uint256 down) = board.clientRating(client);
        assertEq(up, 1, "one up from worker1");
        assertEq(down, 1, "one down from worker2");
    }

    // ---------- freelancer ratings (the mirror badge) ----------

    function testClientCannotRateFreelancerWithoutSettledSpot() public {
        vm.prank(client);
        vm.expectRevert();
        board.rateFreelancer(worker1, true);
    }

    function testFreelancerThumbsUpAfterRelease() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.release(aid);
        vm.prank(client);
        board.rateFreelancer(worker1, true);
        (uint256 up, uint256 down) = board.freelancerRating(worker1);
        assertEq(up, 1, "one thumbs up for the freelancer");
        assertEq(down, 0, "no thumbs down");
    }

    function testFreelancerThumbsDownAfterDisputeRefund() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.openDispute(aid);
        vm.prank(arb);
        board.resolveDispute(aid, false); // junk work, ruled for the client
        vm.prank(client);
        board.rateFreelancer(worker1, false);
        (uint256 up, uint256 down) = board.freelancerRating(worker1);
        assertEq(up, 0, "no thumbs up");
        assertEq(down, 1, "one thumbs down for the freelancer");
    }

    function testFreelancerThumbFlipsAndCountsAdjust() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.release(aid);
        vm.prank(client);
        board.rateFreelancer(worker1, false);
        vm.prank(client);
        board.rateFreelancer(worker1, true); // flip
        (uint256 up, uint256 down) = board.freelancerRating(worker1);
        assertEq(up, 1, "up after flip");
        assertEq(down, 0, "down removed after flip");
    }

    function testStrangerCannotRateFreelancer() public {
        uint256 id = _posting(1);
        uint256 aid = _delivered(id, worker1);
        vm.prank(client);
        board.release(aid);
        vm.prank(stranger); // never settled a spot with worker1
        vm.expectRevert();
        board.rateFreelancer(worker1, true);
    }
}
