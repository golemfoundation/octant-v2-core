// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";

/// @title Cantina Competition September 2025 – Finding 359 Fix
/// @notice Proves that reward schedule metadata is surfaced after notifying new rewards.
contract Cantina359Fix is OctantTestBase {
    uint256 internal constant FIRST_REWARD = 100 ether;
    uint256 internal constant SECOND_REWARD = 40 ether;

    function testFix_TracksAndEmitsRewardScheduleMetadata() public {
        // Fund the notifier for both reward notifications.
        rewardToken.mint(rewardNotifier, FIRST_REWARD + SECOND_REWARD);

        // --- First reward notification: no carry-over ---
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), FIRST_REWARD);
        uint256 expectedEndTimeFirst = block.timestamp + REWARD_DURATION;

        vm.expectEmit(false, false, false, true);
        emit Staker.RewardNotified(FIRST_REWARD, rewardNotifier);
        vm.expectEmit(false, false, false, true);
        emit RegenStakerBase.RewardScheduleUpdated(
            FIRST_REWARD,
            0,
            FIRST_REWARD,
            FIRST_REWARD,
            REWARD_DURATION,
            expectedEndTimeFirst
        );
        regenStaker.notifyRewardAmount(FIRST_REWARD);
        vm.stopPrank();

        (
            uint256 addedFirst,
            uint256 carryFirst,
            uint256 totalScheduledFirst,
            uint256 requiredFirst,
            uint256 durationFirst,
            uint256 endTimeFirst
        ) = regenStaker.latestRewardSchedule();
        assertEq(addedFirst, FIRST_REWARD, "first added amount mismatch");
        assertEq(carryFirst, 0, "first carry-over mismatch");
        assertEq(totalScheduledFirst, FIRST_REWARD, "first total scheduled mismatch");
        assertEq(requiredFirst, FIRST_REWARD, "first required balance mismatch");
        assertEq(durationFirst, REWARD_DURATION, "first duration mismatch");
        assertEq(endTimeFirst, expectedEndTimeFirst, "first end time mismatch");

        // --- Second reward notification: full carry-over from first cycle ---
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), SECOND_REWARD);
        uint256 expectedEndTimeSecond = block.timestamp + REWARD_DURATION;

        vm.expectEmit(false, false, false, true);
        emit Staker.RewardNotified(SECOND_REWARD, rewardNotifier);
        vm.expectEmit(false, false, false, true);
        emit RegenStakerBase.RewardScheduleUpdated(
            SECOND_REWARD,
            FIRST_REWARD,
            FIRST_REWARD + SECOND_REWARD,
            FIRST_REWARD + SECOND_REWARD,
            REWARD_DURATION,
            expectedEndTimeSecond
        );
        regenStaker.notifyRewardAmount(SECOND_REWARD);
        vm.stopPrank();

        (
            uint256 addedSecond,
            uint256 carrySecond,
            uint256 totalScheduledSecond,
            uint256 requiredSecond,
            uint256 durationSecond,
            uint256 endTimeSecond
        ) = regenStaker.latestRewardSchedule();
        assertEq(addedSecond, SECOND_REWARD, "second added amount mismatch");
        assertEq(carrySecond, FIRST_REWARD, "second carry-over mismatch");
        assertEq(totalScheduledSecond, FIRST_REWARD + SECOND_REWARD, "second total scheduled mismatch");
        assertEq(requiredSecond, FIRST_REWARD + SECOND_REWARD, "second required balance mismatch");
        assertEq(durationSecond, REWARD_DURATION, "second duration mismatch");
        assertEq(endTimeSecond, expectedEndTimeSecond, "second end time mismatch");
    }
}
