// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";

/// @title Cantina Competition September 2025 - Finding 359 Fix
/// @notice Proves that reward notifications are tracked and emitted correctly.
/// @dev The original latestRewardSchedule struct was removed for bytecode savings.
///      Equivalent data is derivable from totalRewards, totalClaimedRewards, rewardEndTime,
///      and the RewardNotified event.
contract Cantina359Fix is OctantTestBase {
    uint256 internal constant FIRST_REWARD = 100 ether;
    uint256 internal constant SECOND_REWARD = 40 ether;

    function testFix_TracksAndEmitsRewardMetadata() public {
        // Fund the notifier for both reward notifications.
        rewardToken.mint(rewardNotifier, FIRST_REWARD + SECOND_REWARD);

        // --- First reward notification ---
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), FIRST_REWARD);
        uint256 expectedEndTimeFirst = block.timestamp + REWARD_DURATION;

        vm.expectEmit(false, false, false, true);
        emit Staker.RewardNotified(FIRST_REWARD, rewardNotifier);
        regenStaker.notifyRewardAmount(FIRST_REWARD);
        vm.stopPrank();

        assertEq(regenStaker.totalRewards(), FIRST_REWARD, "totalRewards after first notify");
        assertEq(regenStaker.rewardEndTime(), expectedEndTimeFirst, "rewardEndTime after first notify");

        // --- Second reward notification: full carry-over from first cycle ---
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), SECOND_REWARD);
        uint256 expectedEndTimeSecond = block.timestamp + REWARD_DURATION;

        vm.expectEmit(false, false, false, true);
        emit Staker.RewardNotified(SECOND_REWARD, rewardNotifier);
        regenStaker.notifyRewardAmount(SECOND_REWARD);
        vm.stopPrank();

        assertEq(regenStaker.totalRewards(), FIRST_REWARD + SECOND_REWARD, "totalRewards after second notify");
        assertEq(regenStaker.rewardEndTime(), expectedEndTimeSecond, "rewardEndTime after second notify");
        // Carry-over is derivable: totalRewards - totalClaimedRewards - SECOND_REWARD == FIRST_REWARD
        assertEq(
            regenStaker.totalRewards() - regenStaker.totalClaimedRewards() - SECOND_REWARD,
            FIRST_REWARD,
            "carry-over should equal first reward (nothing claimed yet)"
        );
    }
}
