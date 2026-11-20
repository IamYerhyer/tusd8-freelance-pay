// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {JobBoard} from "../src/JobBoard.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm3 {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
}

contract JobBoardTest {
    Vm3 constant vm = Vm3(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockTUSD8 token;
    JobBoard board;

    address client = address(0xC11E47);
    address worker1 = address(0xF2EE1A);
    address worker2 = address(0x5EC02D);
    address worker3 = address(0x57A9E2);

    uint256 constant PER_SPOT = 1 * 10 ** 6; // 1 tUSD8
    uint256 deadline;

    function setUp() public {
        token = new MockTUSD8();
        board = new JobBoard(address(token));
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

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function testPostingFundsFullBudgetUpfront() public {
        uint256 id = _posting(5);
        assertEq(token.balanceOf(address(board)), 5 * PER_SPOT, "pool holds the full budget");
        JobBoard.Posting memory p = board.getPosting(id);
        assertEq(p.spotsTotal, 5, "spots recorded");
        assertEq(p.spotsFilled, 0, "no spots filled yet");
    }

    function testApplyApproveDeliverRelease() public {
        uint256 id = _posting(2);
        uint256 aid = _approved(id, worker1);

        vm.prank(worker1);
        board.deliver(aid, "https://files.example/labels.csv");

        uint256 before = token.balanceOf(worker1);
        vm.prank(client);
        board.release(aid);
        assertEq(token.balanceOf(worker1), before + PER_SPOT, "worker paid one spot");

        JobBoard.Posting memory p = board.getPosting(id);
        assertEq(p.releasedCount, 1, "released count tracks");
        assertEq(p.spotsFilled, 1, "spot stays filled after release");
    }

    function testOneApplicationPerWallet() public {
        uint256 id = _posting(2);
        vm.prank(worker1);
        board.applyForSpot(id);
        vm.prank(worker1);
        vm.expectRevert();
        board.applyForSpot(id);
    }

    function testClientCannotApplyToOwnPosting() public {
        uint256 id = _posting(2);
        vm.prank(client);
        vm.expectRevert();
        board.applyForSpot(id);
    }

    function testSpotsAreScarce() public {
        uint256 id = _posting(1); // ONE spot
        uint256 a1 = _approved(id, worker1);
        a1; // silence unused warning in spirit
        vm.prank(worker2);
        uint256 a2 = board.applyForSpot(id);
        vm.prank(client);
        vm.expectRevert(); // no spots left to approve into
        board.approveApplication(a2);
    }

    function testRejectKeepsSpotOpen() public {
        uint256 id = _posting(1);
        vm.prank(worker1);
        uint256 a1 = board.applyForSpot(id);
        vm.prank(client);
        board.rejectApplication(a1);
        uint256 a2 = _approved(id, worker2); // spot still available for worker2
        JobBoard.Assignment memory a = board.getAssignment(a2);
        require(a.state == JobBoard.AssignmentState.Approved, "second worker approved into the spot");
    }

    function testWrongRolesRevert() public {
        uint256 id = _posting(2);
        vm.prank(worker1);
        uint256 aid = board.applyForSpot(id);

        vm.prank(worker2); // non-client cannot approve
        vm.expectRevert();
        board.approveApplication(aid);

        vm.prank(client);
        board.approveApplication(aid);

        vm.prank(worker2); // non-assignee cannot deliver
        vm.expectRevert();
        board.deliver(aid, "proof");

        vm.prank(worker1);
        board.deliver(aid, "proof");

        vm.prank(worker1); // freelancer cannot release to themselves
        vm.expectRevert();
        board.release(aid);
    }

    function testRefundGuardOnAssignments() public {
        uint256 id = _posting(2);
        uint256 aid = _approved(id, worker1);

        vm.prank(client); // approved but before deadline: locked
        vm.expectRevert();
        board.refundAssignment(aid);

        vm.warp(deadline + 1); // after deadline, never delivered: refundable
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        board.refundAssignment(aid);
        assertEq(token.balanceOf(client), before + PER_SPOT, "spot pay returned to client");
    }

    function testClosePostingReturnsUnspent() public {
        uint256 id = _posting(3);
        uint256 aid = _approved(id, worker1);
        vm.prank(worker1);
        board.deliver(aid, "proof");
        vm.prank(client);
        board.release(aid); // 1 of 3 spots paid out

        vm.warp(deadline + 3 days + 1);
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        board.closePosting(id);
        assertEq(token.balanceOf(client), before + 2 * PER_SPOT, "two unspent spots returned");
        assertEq(token.balanceOf(address(board)), 0, "pool fully settled");
    }

    function testCloseTooEarlyReverts() public {
        uint256 id = _posting(1);
        vm.prank(client);
        vm.expectRevert();
        board.closePosting(id);
    }

    function testCreatePostingValidation() public {
        vm.prank(client);
        vm.expectRevert();
        board.createPosting(0, 3, deadline, "Free", "Nope");
        vm.prank(client);
        vm.expectRevert();
        board.createPosting(PER_SPOT, 0, deadline, "No spots", "Nope");
    }
}
