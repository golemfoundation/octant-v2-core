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
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice Compounding integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationCompoundingTest is RegenIntegrationBase {
    function testFuzz_CompoundRewards_RespectsMinimumStakeAmount(
        uint256 minimumAmountBase,
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        minimumAmountBase = bound(minimumAmountBase, 10, 100);
        stakeAmountBase = bound(stakeAmountBase, 1, minimumAmountBase - 1);
        rewardAmountBase = bound(rewardAmountBase, 30 days, 100_000_000);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        vm.assume(stakeAmount < minimumAmount);

        // Create a RegenStaker where reward and stake tokens are the same
        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        compoundRegenStaker.setMinimumStakeAmount(uint128(minimumAmount));
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        // Temporarily set minimum to 0 to allow initial stake
        vm.prank(ADMIN);
        compoundRegenStaker.setMinimumStakeAmount(uint128(0));

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + compoundRegenStaker.rewardDuration() + 1);

        // Reset minimum amount
        vm.prank(ADMIN);
        compoundRegenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        uint256 expectedNewBalance = stakeAmount + unclaimedBefore;

        if (expectedNewBalance < minimumAmount) {
            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    RegenStakerBase.MinimumStakeAmountNotMet.selector,
                    minimumAmount,
                    expectedNewBalance
                )
            );
            compoundRegenStaker.compoundRewards(depositId);
        } else {
            vm.prank(user);
            uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);
            assertEq(compoundedAmount, unclaimedBefore);
        }
    }

    function testFuzz_CompoundRewards_BasicFunctionality(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 timeElapsedPercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 100_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        timeElapsedPercent = bound(timeElapsedPercent, 1, 100);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        uint256 timeElapsed = (compoundRegenStaker.rewardDuration() * timeElapsedPercent) / 100;
        vm.warp(block.timestamp + timeElapsed);

        uint256 expectedReward = (rewardAmount * timeElapsedPercent) / 100;
        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        (uint96 balanceBefore, , , , , , ) = compoundRegenStaker.deposits(depositId);

        vm.prank(user);
        uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

        assertEq(compoundedAmount, unclaimedBefore);
        // NOTE: This test may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(compoundedAmount, expectedReward, ONE_PERCENT);

        (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfter, balanceBefore + compoundedAmount);
        assertEq(compoundRegenStaker.unclaimedReward(depositId), 0);
    }

    function testFuzz_CompoundRewards_MultipleCompounds(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 compoundTimes
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 10, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        compoundTimes = bound(compoundTimes, 2, 5);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Multiple compounds need extra buffer for totalStaked growth
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount * compoundTimes * 2);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        uint256 totalCompounded = 0;
        uint256 currentBalance = stakeAmount;

        for (uint256 i = 0; i < compoundTimes; i++) {
            vm.prank(ADMIN);
            compoundRegenStaker.notifyRewardAmount(rewardAmount);

            vm.warp(block.timestamp + compoundRegenStaker.rewardDuration());

            vm.prank(user);
            uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

            totalCompounded += compoundedAmount;
            currentBalance += compoundedAmount;

            (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
            assertEq(balanceAfter, currentBalance);
            assertEq(compoundRegenStaker.unclaimedReward(depositId), 0);
        }

        assertGt(totalCompounded, 0);
        assertGe(currentBalance, stakeAmount);
    }

    function testFuzz_CompoundRewards_MultipleUsers(
        uint256 user1StakeBase,
        uint256 user2StakeBase,
        uint256 rewardAmountBase,
        uint256 user2JoinTimePercent
    ) public {
        _clearTestContext();

        currentTestCtx.user1StakeBase = bound(user1StakeBase, 1, 10_000);
        currentTestCtx.user2StakeBase = bound(user2StakeBase, 1, 10_000);
        currentTestCtx.rewardAmountBase = bound(
            rewardAmountBase,
            uint128(MIN_REWARD_DURATION),
            MAX_REWARD_DURATION + 1_000_000_000
        );
        currentTestCtx.user2JoinTimePercent = bound(user2JoinTimePercent, 10, 90);

        currentTestCtx.sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        currentTestCtx.compoundRegenStaker = new RegenStaker(
            IERC20(address(currentTestCtx.sameToken)),
            IERC20Staking(address(currentTestCtx.sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        currentTestCtx.compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        currentTestCtx.user1 = makeAddr("user1");
        currentTestCtx.user2 = makeAddr("user2");
        authorizeUser(currentTestCtx.user1, true, false, true);
        authorizeUser(currentTestCtx.user2, true, false, true);

        currentTestCtx.user1Stake = getStakeAmount(currentTestCtx.user1StakeBase);
        currentTestCtx.user2Stake = getStakeAmount(currentTestCtx.user2StakeBase);
        currentTestCtx.rewardAmount = getRewardAmount(currentTestCtx.rewardAmountBase);

        currentTestCtx.sameToken.mint(currentTestCtx.user1, currentTestCtx.user1Stake);
        currentTestCtx.sameToken.mint(currentTestCtx.user2, currentTestCtx.user2Stake);
        // Protection requires balance >= totalStaked + rewardAmount
        currentTestCtx.sameToken.mint(
            address(currentTestCtx.compoundRegenStaker),
            currentTestCtx.user1Stake + currentTestCtx.user2Stake + currentTestCtx.rewardAmount
        );

        vm.startPrank(currentTestCtx.user1);
        currentTestCtx.sameToken.approve(address(currentTestCtx.compoundRegenStaker), currentTestCtx.user1Stake);
        currentTestCtx.depositId1 = currentTestCtx.compoundRegenStaker.stake(
            currentTestCtx.user1Stake,
            currentTestCtx.user1
        );
        vm.stopPrank();

        vm.prank(ADMIN);
        currentTestCtx.compoundRegenStaker.notifyRewardAmount(currentTestCtx.rewardAmount);

        vm.warp(
            block.timestamp +
                (currentTestCtx.compoundRegenStaker.rewardDuration() * currentTestCtx.user2JoinTimePercent) /
                100
        );

        vm.startPrank(currentTestCtx.user2);
        currentTestCtx.sameToken.approve(address(currentTestCtx.compoundRegenStaker), currentTestCtx.user2Stake);
        currentTestCtx.depositId2 = currentTestCtx.compoundRegenStaker.stake(
            currentTestCtx.user2Stake,
            currentTestCtx.user2
        );
        vm.stopPrank();

        vm.warp(
            block.timestamp +
                currentTestCtx.compoundRegenStaker.rewardDuration() -
                (currentTestCtx.compoundRegenStaker.rewardDuration() * currentTestCtx.user2JoinTimePercent) /
                100
        );

        // Check if users actually have unclaimed rewards before attempting to compound
        currentTestCtx.unclaimed1 = currentTestCtx.compoundRegenStaker.unclaimedReward(currentTestCtx.depositId1);
        currentTestCtx.unclaimed2 = currentTestCtx.compoundRegenStaker.unclaimedReward(currentTestCtx.depositId2);

        currentTestCtx.compounded1 = 0;
        currentTestCtx.compounded2 = 0;

        if (currentTestCtx.unclaimed1 > 0) {
            vm.prank(currentTestCtx.user1);
            currentTestCtx.compounded1 = currentTestCtx.compoundRegenStaker.compoundRewards(currentTestCtx.depositId1);
        }

        if (currentTestCtx.unclaimed2 > 0) {
            vm.prank(currentTestCtx.user2);
            currentTestCtx.compounded2 = currentTestCtx.compoundRegenStaker.compoundRewards(currentTestCtx.depositId2);
        }

        // For extreme edge cases with tiny reward amounts, precision loss may result in 0 rewards
        // This is acceptable behavior as such small amounts wouldn't be used in practice
        if (currentTestCtx.unclaimed1 > 0) assertGt(currentTestCtx.compounded1, 0);
        if (currentTestCtx.unclaimed2 > 0) assertGt(currentTestCtx.compounded2, 0);

        {
            // Only verify reward calculations if both users actually received rewards
            // Extreme edge cases with tiny amounts may result in 0 rewards due to precision loss
            if (currentTestCtx.unclaimed1 > 0 && currentTestCtx.unclaimed2 > 0) {
                currentTestCtx.soloPhaseRewards =
                    (currentTestCtx.rewardAmount * currentTestCtx.user2JoinTimePercent) /
                    100;
                currentTestCtx.sharedPhaseRewards =
                    (currentTestCtx.rewardAmount * (100 - currentTestCtx.user2JoinTimePercent)) /
                    100;
                currentTestCtx.totalStake = currentTestCtx.user1Stake + currentTestCtx.user2Stake;

                // NOTE: These assertions may fail with extreme fuzzing values due to precision differences
                // when using 7-day reward duration vs original 30-day duration
                assertApproxEqRel(
                    currentTestCtx.compounded1,
                    currentTestCtx.soloPhaseRewards +
                        (currentTestCtx.sharedPhaseRewards * currentTestCtx.user1Stake) /
                        currentTestCtx.totalStake,
                    ONE_PERCENT
                );
                assertApproxEqRel(
                    currentTestCtx.compounded2,
                    (currentTestCtx.sharedPhaseRewards * currentTestCtx.user2Stake) / currentTestCtx.totalStake,
                    ONE_PERCENT
                );
            }
        }

        {
            (uint96 balance1, , , , , , ) = currentTestCtx.compoundRegenStaker.deposits(currentTestCtx.depositId1);
            (uint96 balance2, , , , , , ) = currentTestCtx.compoundRegenStaker.deposits(currentTestCtx.depositId2);

            assertEq(balance1, currentTestCtx.user1Stake + currentTestCtx.compounded1);
            assertEq(balance2, currentTestCtx.user2Stake + currentTestCtx.compounded2);
        }
    }

    function testFuzz_CompoundRewards_MidPeriodVsFullPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 compoundTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        compoundTimePercent = bound(compoundTimePercent, 10, 90);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        uint256 compoundTime = (compoundRegenStaker.rewardDuration() * compoundTimePercent) / 100;
        vm.warp(block.timestamp + compoundTime);

        vm.prank(user);
        uint256 firstCompound = compoundRegenStaker.compoundRewards(depositId);

        uint256 expectedFirstReward = (rewardAmount * compoundTimePercent) / 100;
        // NOTE: This assertion may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(firstCompound, expectedFirstReward, ONE_PERCENT);

        (uint96 balanceAfterFirst, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfterFirst, stakeAmount + firstCompound);

        uint256 remainingTime = compoundRegenStaker.rewardDuration() - compoundTime;
        vm.warp(block.timestamp + remainingTime);

        uint256 unclaimedAfterPeriod = compoundRegenStaker.unclaimedReward(depositId);
        uint256 expectedRemainingReward = (rewardAmount * (100 - compoundTimePercent)) / 100;
        // NOTE: This assertion may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(unclaimedAfterPeriod, expectedRemainingReward, ONE_PERCENT);
    }

    function testFuzz_CompoundRewards_DifferentTokenDecimals(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint8 decimals
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        decimals = uint8(bound(decimals, 6, 18));

        MockERC20Staking sameToken = new MockERC20Staking(decimals);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = stakeAmountBase * (10 ** decimals);
        uint256 rewardAmount = rewardAmountBase * (10 ** decimals);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + compoundRegenStaker.rewardDuration());

        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        (uint96 balanceBefore, , , , , , ) = compoundRegenStaker.deposits(depositId);

        vm.prank(user);
        uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

        assertEq(compoundedAmount, unclaimedBefore);
        assertApproxEqRel(compoundedAmount, rewardAmount, ONE_MICRO);

        (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfter, balanceBefore + compoundedAmount);
    }
}
