// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";

/// @title Cantina Competition September 2025 – Option 1 Fix
/// @notice Verifies reward schedule pausing when total earning power is zero.
contract Finding283Option1 is OctantTestBase {
    uint256 internal constant REWARD_AMOUNT = 10_000 ether;
    uint256 internal constant STAKE_AMOUNT = 1_000 ether;
    uint256 internal constant IDLE_WINDOW = 10 days;

    function testFix_PauseRewardScheduleWhenIdle() public {
        setUp();

        // Arrange: ensure alice can stake and rewards are funded.
        rewardToken.mint(address(regenStaker), REWARD_AMOUNT);

        vm.prank(rewardNotifier);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);

        uint256 initialEnd = regenStaker.rewardEndTime();

        // Act: advance time while there is no earning power.
        vm.warp(block.timestamp + IDLE_WINDOW);

        // Stake for Alice to resume the schedule.
        stakeToken.mint(alice, STAKE_AMOUNT);
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Assert: reward end time was extended and no rewards accrued during the idle window.
        assertEq(regenStaker.rewardEndTime(), initialEnd + IDLE_WINDOW, "rewardEndTime should extend by idle duration");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "no rewards should be earned while schedule is paused");
    }
}
