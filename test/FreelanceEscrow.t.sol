// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FreelanceEscrow} from "../src/FreelanceEscrow.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
}

contract FreelanceEscrowTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockTUSD8 token;
    FreelanceEscrow escrow;

    address client = address(0xC11E47);
    address freelancer = address(0xF2EE1A);
    address stranger = address(0x57A9E2);

    uint256 constant AMOUNT = 20 * 10 ** 6; // 20 tUSD8
    uint256 deadline;

    function setUp() public {
        token = new MockTUSD8();
        escrow = new FreelanceEscrow(address(token));
        deadline = block.timestamp + 7 days;
        token.mint(client, 100 * 10 ** 6);
    }

    // ---------- helpers ----------

    function _create() internal returns (uint256 id) {
        vm.prank(client);
        id = escrow.createAgreement(freelancer, AMOUNT, deadline, "Logo design", "Design a logo");
    }

    function _funded() internal returns (uint256 id) {
        id = _create();
        vm.prank(freelancer);
        escrow.acceptAgreement(id);
        vm.prank(client);
        token.approve(address(escrow), AMOUNT);
        vm.prank(client);
        escrow.deposit(id);
    }

    function _delivered() internal returns (uint256 id) {
        id = _funded();
        vm.prank(freelancer);
        escrow.markDelivered(id, "https://files.example/logo.png");
    }

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function assertState(uint256 id, FreelanceEscrow.State expected, string memory what) internal view {
        FreelanceEscrow.Agreement memory a = escrow.getAgreement(id);
        require(a.state == expected, what);
    }

    // ---------- tests (spec section 11 checklist) ----------

    function testHappyPath() public {
        uint256 id = _delivered();
        assertEq(token.balanceOf(address(escrow)), AMOUNT, "escrow should hold the deposit");
        assertEq(token.balanceOf(freelancer), 0, "freelancer not paid before release");

        vm.prank(client);
        escrow.release(id);

        assertState(id, FreelanceEscrow.State.Released, "state should be Released");
        assertEq(token.balanceOf(freelancer), AMOUNT, "freelancer paid in full");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow emptied");
    }

    function testCancelBeforeFunding() public {
        uint256 id = _create();
        vm.prank(client);
        escrow.refund(id);
        assertState(id, FreelanceEscrow.State.Refunded, "cancel in Created refunds");

        uint256 id2 = _create();
        vm.prank(freelancer);
        escrow.acceptAgreement(id2);
        vm.prank(client);
        escrow.refund(id2);
        assertState(id2, FreelanceEscrow.State.Refunded, "cancel in Accepted refunds");
    }

    function testRefundFundedBeforeDeadlineLocked() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert();
        escrow.refund(id);
    }

    function testRefundAfterDeadlineNeverDelivered() public {
        uint256 id = _funded();
        vm.warp(deadline + 1);
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        escrow.refund(id);
        assertState(id, FreelanceEscrow.State.Refunded, "state should be Refunded");
        assertEq(token.balanceOf(client), before + AMOUNT, "client got the deposit back");
    }

    function testRefundDeliveredLockedInsideWindow() public {
        // Deliver just before the deadline, so that when the deadline
        // passes the 3-day review window (from delivery) is still running.
        uint256 id = _funded();
        vm.warp(deadline - 1 hours);
        vm.prank(freelancer);
        escrow.markDelivered(id, "https://files.example/logo.png");
        vm.warp(deadline + 1);
        vm.prank(client);
        vm.expectRevert();
        escrow.refund(id);
    }

    function testRefundDeliveredAfterDeadlineAndReviewWindow() public {
        uint256 id = _delivered();
        vm.warp(block.timestamp + 8 days); // beyond deadline AND deliveredAt + 3 days
        uint256 before = token.balanceOf(client);
        vm.prank(client);
        escrow.refund(id);
        assertState(id, FreelanceEscrow.State.Refunded, "state should be Refunded");
        assertEq(token.balanceOf(client), before + AMOUNT, "client refunded after both windows");
    }

    function testWrongWalletCallsRejected() public {
        uint256 id = _create();

        vm.prank(client); // client cannot accept their own job
        vm.expectRevert();
        escrow.acceptAgreement(id);

        vm.prank(freelancer);
        escrow.acceptAgreement(id);

        vm.prank(freelancer); // freelancer cannot deposit
        vm.expectRevert();
        escrow.deposit(id);

        vm.prank(client);
        token.approve(address(escrow), AMOUNT);
        vm.prank(client);
        escrow.deposit(id);

        vm.prank(client); // client cannot mark delivered
        vm.expectRevert();
        escrow.markDelivered(id, "proof");

        vm.prank(freelancer);
        escrow.markDelivered(id, "proof");

        vm.prank(freelancer); // freelancer cannot release to themselves
        vm.expectRevert();
        escrow.release(id);

        vm.prank(stranger); // stranger cannot refund
        vm.expectRevert();
        escrow.refund(id);
    }

    function testDoubleDepositAndDoubleReleaseImpossible() public {
        uint256 id = _funded();
        vm.prank(client);
        vm.expectRevert();
        escrow.deposit(id);

        vm.prank(freelancer);
        escrow.markDelivered(id, "proof");
        vm.prank(client);
        escrow.release(id);

        vm.prank(client);
        vm.expectRevert();
        escrow.release(id);
    }

    function testZeroAmountRejected() public {
        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(freelancer, 0, deadline, "Free job", "Nope");
    }

    function testInvalidTermsRejected() public {
        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(address(0), AMOUNT, deadline, "Ghost job", "Nope");

        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(client, AMOUNT, deadline, "Self job", "Nope");

        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(freelancer, AMOUNT, block.timestamp - 1, "Late job", "Nope");
    }

    function testDepositWithoutApprovalFails() public {
        uint256 id = _create();
        vm.prank(freelancer);
        escrow.acceptAgreement(id);
        vm.prank(client);
        vm.expectRevert();
        escrow.deposit(id);
    }
}
