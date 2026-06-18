// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice RewardAccrual integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationRewardAccrualTest is RegenIntegrationBase {
    function testFuzz_ContinuousReward_SingleStaker_JoinsLate(uint256 joinTimePercent) public {
        uint256 minJoinTime = 1;
        uint256 maxJoinTime = 99;
        joinTimePercent = bound(joinTimePercent, minJoinTime, maxJoinTime);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 totalRewardAmount = getRewardAmount();
        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(totalRewardAmount);

        uint256 joinTime = (regenStaker.rewardDuration() * joinTimePercent) / 100;
        vm.warp(block.timestamp + joinTime);

        uint256 stakeAmount = getStakeAmount();
        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        uint256 remainingTime = regenStaker.rewardDuration() - joinTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 timeStakedPercent = 100 - joinTimePercent;
        uint256 expectedReward = (totalRewardAmount * timeStakedPercent) / 100;

        assertApproxEqRel(claimedAmount, expectedReward, ONE_MICRO);
    }

    function testFuzz_ContinuousReward_TwoStakers_DifferentAmounts_ProRataShare(
        uint256 stakerARatio,
        uint256 stakerBRatio
    ) public {
        uint256 minRatio = 1;
        uint256 maxRatio = 10;
        stakerARatio = bound(stakerARatio, minRatio, maxRatio);
        stakerBRatio = bound(stakerBRatio, minRatio, maxRatio);

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 baseStakeAmount = getStakeAmount();
        uint256 ratioScaleFactor = 5;
        uint256 stakeAmountA = (baseStakeAmount * stakerARatio) / ratioScaleFactor;
        uint256 stakeAmountB = (baseStakeAmount * stakerBRatio) / ratioScaleFactor;

        stakeToken.mint(stakerA, stakeAmountA);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmountA);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmountA, stakerA);
        vm.stopPrank();

        stakeToken.mint(stakerB, stakeAmountB);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmountB);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmountB, stakerB);
        vm.stopPrank();

        uint256 totalRewardAmount = getRewardAmount();
        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(totalRewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 totalStake = stakeAmountA + stakeAmountB;
        uint256 expectedA = (totalRewardAmount * stakeAmountA) / totalStake;
        uint256 expectedB = (totalRewardAmount * stakeAmountB) / totalStake;

        assertApproxEqRel(claimedA, expectedA, ONE_PICO);
        assertApproxEqRel(claimedB, expectedB, ONE_PICO);
        assertApproxEqRel(claimedA + claimedB, totalRewardAmount, ONE_PICO);
    }

    function test_PauseRewardScheduleWhenNoEarningPower() public {
        _clearTestContext();

        uint256 duration = regenStaker.rewardDuration();
        uint256 rewardAmount = getRewardAmount();
        uint256 stakeAmount = getStakeAmount();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 initialEnd = regenStaker.rewardEndTime();
        uint256 halfDuration = duration / 2;

        vm.warp(block.timestamp + halfDuration);

        address staker = makeAddr("option1Staker");
        authorizeUser(staker, true, false, true);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        uint256 expectedEnd = initialEnd + halfDuration;
        assertEq(regenStaker.rewardEndTime(), expectedEnd, "rewardEndTime should extend by idle window");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "no rewards should accrue during pause");

        vm.warp(expectedEnd);

        vm.startPrank(staker);
        uint256 claimed = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimed, rewardAmount, ONE_MICRO, "reward should stream fully after pause");
    }

    function testFuzz_TimeWeightedReward_NoEarningIfNotOnEarningAddressSet(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, false);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertEq(claimedAmount, 0);
    }

    function testFuzz_TimeWeightedReward_EarningStopsIfRemovedFromEarningAllowsetMidPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address allowlistedStaker = makeAddr("allowlistedStaker");
        address nonAllowlistedStaker = makeAddr("nonAllowlistedStaker");

        authorizeUser(allowlistedStaker, true, false, true);
        authorizeUser(nonAllowlistedStaker, true, false, false);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(allowlistedStaker, stakeAmount);
        stakeToken.mint(nonAllowlistedStaker, stakeAmount);

        vm.startPrank(allowlistedStaker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier allowlistedDepositId = regenStaker.stake(stakeAmount, allowlistedStaker);
        vm.stopPrank();

        vm.startPrank(nonAllowlistedStaker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier nonAllowlistedDepositId = regenStaker.stake(stakeAmount, nonAllowlistedStaker);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(allowlistedStaker), stakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(nonAllowlistedStaker), 0);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(allowlistedStaker);
        uint256 claimedByAllowlisted = regenStaker.claimReward(allowlistedDepositId);
        vm.stopPrank();

        vm.startPrank(nonAllowlistedStaker);
        uint256 claimedByNonAllowlisted = regenStaker.claimReward(nonAllowlistedDepositId);
        vm.stopPrank();

        assertApproxEqRel(claimedByAllowlisted, rewardAmount, ONE_MICRO);
        assertEq(claimedByNonAllowlisted, 0);
    }

    function testFuzz_TimeWeightedReward_RateResetsWithNewRewardNotification(
        uint256 rewardPart1Base,
        uint256 rewardPart2Base,
        uint256 stakeAmountBase,
        uint256 stakerBJoinTimePercent
    ) public {
        rewardPart1Base = bound(rewardPart1Base, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        rewardPart2Base = bound(rewardPart2Base, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 minJoinTime = 10;
        uint256 maxJoinTime = 90;
        stakerBJoinTimePercent = bound(stakerBJoinTimePercent, minJoinTime, maxJoinTime);

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        stakeToken.mint(stakerA, stakeAmount);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmount, stakerA);
        vm.stopPrank();

        uint256 rewardPart1 = getRewardAmount(rewardPart1Base);
        uint256 rewardPart2 = getRewardAmount(rewardPart2Base);
        uint256 totalRewardAmount = rewardPart1 + rewardPart2;

        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardPart1);

        uint256 stakerBJoinTime = (regenStaker.rewardDuration() * stakerBJoinTimePercent) / 100;
        vm.warp(block.timestamp + stakerBJoinTime);

        stakeToken.mint(stakerB, stakeAmount);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmount, stakerB);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardPart2);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 stakerASoloEarnings = (rewardPart1 * stakerBJoinTimePercent) / 100;
        uint256 remainingPart1 = rewardPart1 - stakerASoloEarnings;
        uint256 totalNewPeriodRewards = remainingPart1 + rewardPart2;
        uint256 eachStakerNewPeriodEarnings = totalNewPeriodRewards / 2;

        uint256 expectedA = stakerASoloEarnings + eachStakerNewPeriodEarnings;
        uint256 expectedB = eachStakerNewPeriodEarnings;

        assertApproxEqRel(claimedA, expectedA, ONE_MICRO);
        assertApproxEqRel(claimedB, expectedB, ONE_MICRO);
        assertApproxEqRel(claimedA + claimedB, totalRewardAmount, ONE_MICRO);
    }
}
