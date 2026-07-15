// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice RewardDuration integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationRewardDurationTest is RegenIntegrationBase {
    function testFuzz_SetRewardDuration(uint256 newDuration) public {
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        // current duration
        uint256 currentDuration = regenStaker.rewardDuration();
        vm.assume(newDuration != currentDuration);

        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit RewardDurationSet(newDuration);
        regenStaker.setRewardDuration(uint128(newDuration));

        assertEq(regenStaker.rewardDuration(), newDuration);
    }

    function testFuzz_RevertIf_NonAdminCannotSetRewardDuration(address nonAdmin, uint256 newDuration) public {
        vm.assume(nonAdmin != ADMIN);
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setRewardDuration(uint128(newDuration));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationTooLow() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 6 days));
        regenStaker.setRewardDuration(6 days);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationToZero() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 0));
        regenStaker.setRewardDuration(uint128(0));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationTooHigh() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 3001 days));
        regenStaker.setRewardDuration(3001 days);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationDuringActiveReward(uint256 newDuration) public {
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(1);
        uint256 rewardAmount = getRewardAmount(regenStaker.rewardDuration());

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CannotChangeRewardDurationDuringActiveReward.selector));
        regenStaker.setRewardDuration(uint128(newDuration));
        vm.stopPrank();
    }

    function testFuzz_Constructor_WithCustomRewardDuration(uint256 customDuration) public {
        customDuration = bound(uint128(customDuration), uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        vm.startPrank(ADMIN);
        RegenStaker localRegenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(customDuration),
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            stakerAllowset
        );

        assertEq(localRegenStaker.rewardDuration(), customDuration);
        vm.stopPrank();
    }

    function testFuzz_Constructor_WithZeroRewardDurationReverts() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 0));
        new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            0,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            stakerAllowset
        );
        vm.stopPrank();
    }

    function testFuzz_VariableRewardDuration_SingleStaker_FullPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 100_000);
        customDurationDays = bound(customDurationDays, 30, 365);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

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

        vm.warp(block.timestamp + customDuration);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimedAmount, rewardAmount, ONE_MICRO);
    }

    function testFuzz_VariableRewardDuration_TwoStakers_ProRataShare(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays,
        uint256 secondStakerJoinPercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        customDurationDays = bound(customDurationDays, 30, 100);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);
        secondStakerJoinPercent = bound(secondStakerJoinPercent, 10, 90);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(stakerA, stakeAmount);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmount, stakerA);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 stakerBJoinTime = (customDuration * secondStakerJoinPercent) / 100;
        vm.warp(block.timestamp + stakerBJoinTime);

        stakeToken.mint(stakerB, stakeAmount);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmount, stakerB);
        vm.stopPrank();

        uint256 remainingTime = customDuration - stakerBJoinTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 soloPhaseRewards = (rewardAmount * secondStakerJoinPercent) / 100;
        uint256 sharedPhasePercent = 100 - secondStakerJoinPercent;
        uint256 sharedPhaseRewards = (rewardAmount * sharedPhasePercent) / 100;

        uint256 expectedA = soloPhaseRewards + (sharedPhaseRewards / 2);
        uint256 expectedB = sharedPhaseRewards / 2;

        assertApproxEqRel(claimedA, expectedA, ONE_MICRO);
        assertApproxEqRel(claimedB, expectedB, ONE_MICRO);
        assertApproxEqRel(claimedA + claimedB, rewardAmount, ONE_MICRO);
    }

    function testFuzz_VariableRewardDuration_ClaimsMidPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays,
        uint256 firstClaimTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        customDurationDays = bound(customDurationDays, 30, 100);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);
        firstClaimTimePercent = bound(firstClaimTimePercent, 10, 90);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

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

        uint256 firstClaimTime = (customDuration * firstClaimTimePercent) / 100;
        vm.warp(block.timestamp + firstClaimTime);

        vm.startPrank(staker);
        uint256 claimedAmount1 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedFirst = (rewardAmount * firstClaimTimePercent) / 100;
        assertApproxEqRel(claimedAmount1, expectedFirst, ONE_NANO);

        uint256 remainingTime = customDuration - firstClaimTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(staker);
        uint256 claimedAmount2 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 remainingTimePercent = 100 - firstClaimTimePercent;
        uint256 expectedSecond = (rewardAmount * remainingTimePercent) / 100;

        assertApproxEqRel(claimedAmount2, expectedSecond, ONE_NANO);
        assertApproxEqRel(claimedAmount1 + claimedAmount2, rewardAmount, ONE_NANO);
    }

    function testFuzz_VariableRewardDuration_ChangeDurationBetweenRewards(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 firstDurationDays,
        uint256 secondDurationDays
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        firstDurationDays = bound(firstDurationDays, 30, 60);
        secondDurationDays = bound(secondDurationDays, 30, 60);
        uint256 firstDuration = firstDurationDays * 1 days;
        uint256 secondDuration = secondDurationDays * 1 days;

        vm.assume(firstDuration != secondDuration);

        rewardAmountBase = bound(rewardAmountBase, max(firstDuration, secondDuration), 100_000_000);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(firstDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount * 2);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + firstDuration + 1);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(secondDuration));

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + secondDuration);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertGt(claimedAmount, 0);
        assertLe(claimedAmount, rewardAmount * 2);
    }
}
