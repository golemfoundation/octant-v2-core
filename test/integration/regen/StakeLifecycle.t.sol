// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice StakeLifecycle integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationStakeLifecycleTest is RegenIntegrationBase {
    function testFuzz_StakeDeposit_StakeMore_UpdatesBalanceAndRewards(
        uint256 initialStakeRatio,
        uint256 additionalStakeRatio,
        uint256 timingPercent
    ) public {
        initialStakeRatio = bound(initialStakeRatio, 1, 10);
        additionalStakeRatio = bound(additionalStakeRatio, 1, 10);
        timingPercent = bound(timingPercent, 10, 90);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 baseAmount = getStakeAmount();
        uint256 initialStake = (baseAmount * initialStakeRatio) / 10;
        uint256 additionalStake = (baseAmount * additionalStakeRatio) / 10;

        stakeToken.mint(user, initialStake + additionalStake);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), initialStake + additionalStake);
        Staker.DepositIdentifier depositId = regenStaker.stake(initialStake, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), initialStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), initialStake);

        address otherStaker = makeAddr("otherStaker");
        authorizeUser(otherStaker, true, false, true);
        stakeToken.mint(otherStaker, getStakeAmount());
        vm.startPrank(otherStaker);
        stakeToken.approve(address(regenStaker), getStakeAmount());
        regenStaker.stake(getStakeAmount(), otherStaker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), getRewardAmount());
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(getRewardAmount());

        vm.warp(block.timestamp + (regenStaker.rewardDuration() * timingPercent) / 100);

        vm.startPrank(user);
        regenStaker.stakeMore(depositId, additionalStake);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), initialStake + additionalStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), initialStake + additionalStake);

        vm.warp(block.timestamp + regenStaker.rewardDuration() - (regenStaker.rewardDuration() * timingPercent) / 100);

        vm.startPrank(user);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertGt(claimedAmount, 0);
        assertLe(claimedAmount, getRewardAmount());
    }

    function testFuzz_StakeDeposit_MultipleDepositsSingleUser(
        uint256 stakeAmountBase1,
        uint256 stakeAmountBase2,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase1 = bound(stakeAmountBase1, 1, 10_000);
        stakeAmountBase2 = bound(stakeAmountBase2, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount1 = getStakeAmount(stakeAmountBase1);
        uint256 stakeAmount2 = getStakeAmount(stakeAmountBase2);
        uint256 totalStakeAmount = stakeAmount1 + stakeAmount2;

        stakeToken.mint(user, totalStakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), totalStakeAmount);

        Staker.DepositIdentifier depositId1 = regenStaker.stake(stakeAmount1, user);
        Staker.DepositIdentifier depositId2 = regenStaker.stake(stakeAmount2, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), totalStakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(user), totalStakeAmount);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(user);
        uint256 claimed1 = regenStaker.claimReward(depositId1);
        uint256 claimed2 = regenStaker.claimReward(depositId2);
        vm.stopPrank();

        uint256 expected1 = (rewardAmount * stakeAmount1) / totalStakeAmount;
        uint256 expected2 = (rewardAmount * stakeAmount2) / totalStakeAmount;

        assertApproxEqRel(claimed1, expected1, ONE_MICRO);
        assertApproxEqRel(claimed2, expected2, ONE_MICRO);
        assertApproxEqRel(claimed1 + claimed2, rewardAmount, ONE_MICRO);
    }

    function testFuzz_StakeWithdraw_PartialWithdraw_ReducesBalanceAndImpactsRewards(
        uint256 stakeAmountBase,
        uint256 withdrawRatio,
        uint256 otherStakeRatio,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 100, 10_000);
        withdrawRatio = bound(withdrawRatio, 1, 75);
        otherStakeRatio = bound(otherStakeRatio, 10, 200);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address user = makeAddr("user");
        address otherStaker = makeAddr("otherStaker");

        authorizeUser(user, true, false, true);
        authorizeUser(otherStaker, true, false, true);

        uint256 userStakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(user, userStakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), userStakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(userStakeAmount, user);
        vm.stopPrank();

        uint256 otherStakerAmount = (userStakeAmount * otherStakeRatio) / 100;
        stakeToken.mint(otherStaker, otherStakerAmount);
        vm.startPrank(otherStaker);
        stakeToken.approve(address(regenStaker), otherStakerAmount);
        Staker.DepositIdentifier otherDepositId = regenStaker.stake(otherStakerAmount, otherStaker);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        uint256 withdrawAmount = (userStakeAmount * withdrawRatio) / 100;
        vm.startPrank(user);
        regenStaker.withdraw(depositId, withdrawAmount);
        vm.stopPrank();

        uint256 remainingUserStake = userStakeAmount - withdrawAmount;
        assertEq(regenStaker.depositorTotalStaked(user), remainingUserStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), remainingUserStake);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        vm.startPrank(user);
        uint256 claimedAfterWithdraw = regenStaker.claimReward(depositId);
        vm.stopPrank();

        vm.startPrank(otherStaker);
        uint256 claimedByOtherStaker = regenStaker.claimReward(otherDepositId);
        vm.stopPrank();

        assertApproxEqRel(claimedAfterWithdraw + claimedByOtherStaker, rewardAmount, ONE_MICRO);
        assertGt(claimedAfterWithdraw, 0);
        assertGt(claimedByOtherStaker, 0);
    }

    function testFuzz_StakeWithdraw_FullWithdraw_BalanceZero_ClaimsAccrued_NoFutureRewards(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 withdrawTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        uint256 minWithdrawTime = 10;
        uint256 maxWithdrawTime = 90;
        withdrawTimePercent = bound(withdrawTimePercent, minWithdrawTime, maxWithdrawTime);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 withdrawTime = (regenStaker.rewardDuration() * withdrawTimePercent) / 100;
        vm.warp(block.timestamp + withdrawTime);

        vm.startPrank(user);
        regenStaker.withdraw(depositId, stakeAmount);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), 0);
        assertEq(regenStaker.depositorTotalEarningPower(user), 0);

        vm.startPrank(user);
        uint256 claimedImmediately = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedReward = (rewardAmount * withdrawTimePercent) / 100;
        assertApproxEqRel(claimedImmediately, expectedReward, ONE_MICRO);

        uint256 remainingTime = regenStaker.rewardDuration() - withdrawTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(user);
        uint256 claimedLater = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertEq(claimedLater, 0);
    }
}
