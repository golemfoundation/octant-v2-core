// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Cantina Competition September 2025 – Finding 663 Fix
/// @notice Ensures pausing the staker also halts earning power bumps.
contract Finding663Fix is Test, OctantTestBase {
    Staker.DepositIdentifier internal aliceDepositId;
    Staker.DepositIdentifier internal bobDepositId;
    Staker.DepositIdentifier internal charlieDepositId;

    uint256 internal constant ALICE_STAKE = 1_000 ether;
    uint256 internal constant BOB_STAKE = 100 ether;
    uint256 internal constant CHARLIE_STAKE = 50 ether;
    uint256 internal constant REWARD_AMOUNT = 100 ether;

    function testFix_BumpEarningPowerHonorsPause() public {
        setUp();

        _seedBaseScenario();

        vm.prank(admin);
        regenStaker.pause();

        vm.prank(charlie);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.bumpEarningPower(aliceDepositId, charlie, 0);
    }

    /// @dev Recreates the base setup, staking, reward notification and attack prep.
    function _seedBaseScenario() internal {
        // Fund actors
        stakeToken.mint(alice, ALICE_STAKE);
        stakeToken.mint(bob, BOB_STAKE);
        stakeToken.mint(charlie, CHARLIE_STAKE);
        rewardToken.mint(rewardNotifier, REWARD_AMOUNT);

        // AddressSet bump keeper for staking/earning power
        vm.prank(admin);
        stakerAllowset.add(charlie);
        vm.prank(admin);
        earningPowerAllowset.add(charlie);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), ALICE_STAKE);
        aliceDepositId = regenStaker.stake(ALICE_STAKE, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        stakeToken.approve(address(regenStaker), BOB_STAKE);
        bobDepositId = regenStaker.stake(BOB_STAKE, bob, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        stakeToken.approve(address(regenStaker), CHARLIE_STAKE);
        charlieDepositId = regenStaker.stake(CHARLIE_STAKE, charlie, charlie);
        vm.stopPrank();

        vm.prank(rewardNotifier);
        rewardToken.approve(address(regenStaker), REWARD_AMOUNT);
        vm.prank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), REWARD_AMOUNT);
        vm.prank(rewardNotifier);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + REWARD_DURATION / 2);

        vm.prank(alice);
        regenStaker.claimReward(aliceDepositId);

        vm.prank(admin);
        earningPowerAllowset.remove(alice);
    }
}
