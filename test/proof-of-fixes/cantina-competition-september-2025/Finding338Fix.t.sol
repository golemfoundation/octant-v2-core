// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Cantina Competition September 2025 – Finding 338 Fix
/// @notice Ensures delegatee and claimer changes respect pause state.
contract Finding338Fix is Test, OctantTestBase {
    Staker.DepositIdentifier internal aliceDepositId;

    uint256 internal constant ALICE_STAKE = 1_000 ether;

    function testFix_AlterDelegateeHonorsPause() public {
        setUp();
        _seedDeposit();

        vm.prank(admin);
        regenStaker.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.alterDelegatee(aliceDepositId, bob);
    }

    function testFix_AlterClaimerHonorsPause() public {
        setUp();
        _seedDeposit();

        vm.prank(admin);
        regenStaker.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.alterClaimer(aliceDepositId, bob);
    }

    function _seedDeposit() internal {
        stakeToken.mint(alice, ALICE_STAKE);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), ALICE_STAKE);
        aliceDepositId = regenStaker.stake(ALICE_STAKE, alice, alice);
        vm.stopPrank();
    }
}
