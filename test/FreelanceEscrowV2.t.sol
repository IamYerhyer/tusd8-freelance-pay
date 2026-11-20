// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FreelanceEscrowV2} from "../src/FreelanceEscrowV2.sol";
import {MockTUSD8} from "../src/MockTUSD8.sol";

/// @notice Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm2 {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
}

contract FreelanceEscrowV2Test {
    Vm2 constant vm = Vm2(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockTUSD8 token;
    FreelanceEscrowV2 escrow;

    address client = address(0xC11E47);
    address freelancer = address(0xF2EE1A);
    address second = address(0x5EC02D);
    address stranger = address(0x57A9E2);

    uint256 constant AMOUNT = 20 * 10 ** 6; // 20 tUSD8
    uint256 deadline;

    function setUp() public {
        token = new MockTUSD8();
        escrow = new FreelanceEscrowV2(address(token));
        deadline = block.timestamp + 7 days;
        token.mint(client, 100 * 10 ** 6);
    }

    function _createOpen() internal returns (uint256 id) {
        vm.prank(client);
        id = escrow.createAgreement(address(0), AMOUNT, deadline, "Label 500 images", "Category: AI training & evaluation");
    }

    function _createDirect() internal returns (uint256 id) {
        vm.prank(client);
        id = escrow.createAgreement(freelancer, AMOUNT, deadline, "Logo design", "Design a logo");
    }

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function assertState(uint256 id, FreelanceEscrowV2.State expected, string memory what) internal view {
        FreelanceEscrowV2.Agreement memory a = escrow.getAgreement(id);
        require(a.state == expected, what);
    }

    // ---------- open job (claim) flow ----------

    function testOpenJobClaimThenFullFlow() public {
        uint256 id = _createOpen();

        vm.prank(freelancer); // a qualified freelancer claims the open job
        escrow.acceptAgreement(id);

        FreelanceEscrowV2.Agreement memory a = escrow.getAgreement(id);
        require(a.freelancer == freelancer, "claimer becomes the freelancer");
        assertState(id, FreelanceEscrowV2.State.Accepted, "claimed job is Accepted");

        vm.prank(client);
        token.approve(address(escrow), AMOUNT);
        vm.prank(client);
        escrow.deposit(id);

        vm.prank(freelancer);
        escrow.markDelivered(id, "https://files.example/labels.csv");

        vm.prank(client);
        escrow.release(id);

        assertState(id, FreelanceEscrowV2.State.Released, "open job completes end to end");
        assertEq(token.balanceOf(freelancer), AMOUNT, "claimer paid in full");
    }

    function testClientCannotClaimOwnOpenJob() public {
        uint256 id = _createOpen();
        vm.prank(client);
        vm.expectRevert();
        escrow.acceptAgreement(id);
    }

    function testSecondClaimReverts() public {
        uint256 id = _createOpen();
        vm.prank(freelancer);
        escrow.acceptAgreement(id);
        vm.prank(second); // too late — job already claimed
        vm.expectRevert();
        escrow.acceptAgreement(id);
    }

    function testClientCanRejectClaimByCancelling() public {
        uint256 id = _createOpen();
        vm.prank(stranger); // an unqualified claimer grabs it
        escrow.acceptAgreement(id);
        // The qualification gate: the client simply never funds it, and can
        // cancel freely before any deposit.
        vm.prank(client);
        escrow.refund(id);
        assertState(id, FreelanceEscrowV2.State.Refunded, "client can cancel a bad claim pre-funding");
    }

    // ---------- direct hire still works (V1 behaviour) ----------

    function testDirectHireUnchanged() public {
        uint256 id = _createDirect();
        vm.prank(stranger); // only the named freelancer may accept
        vm.expectRevert();
        escrow.acceptAgreement(id);

        vm.prank(freelancer);
        escrow.acceptAgreement(id);
        assertState(id, FreelanceEscrowV2.State.Accepted, "direct hire accepted by named freelancer");
    }

    function testSelfJobStillRejected() public {
        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(client, AMOUNT, deadline, "Self job", "Nope");
    }

    function testZeroAmountStillRejected() public {
        vm.prank(client);
        vm.expectRevert();
        escrow.createAgreement(address(0), 0, deadline, "Free job", "Nope");
    }

    function testRefundGuardStillAppliesAfterClaim() public {
        uint256 id = _createOpen();
        vm.prank(freelancer);
        escrow.acceptAgreement(id);
        vm.prank(client);
        token.approve(address(escrow), AMOUNT);
        vm.prank(client);
        escrow.deposit(id);
        vm.prank(client); // funded, before deadline: refund locked
        vm.expectRevert();
        escrow.refund(id);
    }
}
