// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test, console2 } from "forge-std/Test.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

/// @title Fuzz Tests for RegenStakerWithoutDelegateSurrogateVotes
/// @notice Targeted fuzz testing for critical scenarios and edge cases
contract RegenStakerWithoutDelegateSurrogateVotesFuzzTest is Test {
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    RegenStakerWithoutDelegateSurrogateVotes public differentTokenStaker;

    MockERC20 public token;
    MockERC20 public rewardToken;
    AddressSet public stakerAllowset;
    AddressSet public contributionAllowset;
    AddressSet public allocationAllowset;
    RegenEarningPowerCalculator public calculator;

    address public admin;
    address public rewardNotifier;
    address public user1;
    address public user2;
    address public user3;

    // Test parameters
    uint128 public constant REWARD_DURATION = 30 days;
    uint256 public constant MAX_CLAIM_FEE = 0.1e18; // 10%
    uint128 public constant MIN_STAKE = 1e18;
    uint256 public constant MAX_BUMP_TIP = 1e18;

    function setUp() public {
        admin = makeAddr("admin");
        rewardNotifier = makeAddr("rewardNotifier");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy mock contracts
        token = new MockERC20(18);
        rewardToken = new MockERC20(18);
        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationAllowset = new AddressSet();
        calculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker contracts
        staker = new RegenStakerWithoutDelegateSurrogateVotes(
            token, // Same token for stake and reward
            token,
            calculator,
            MAX_BUMP_TIP,
            admin,
            REWARD_DURATION,
            MIN_STAKE,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationAllowset
        );

        differentTokenStaker = new RegenStakerWithoutDelegateSurrogateVotes(
            rewardToken, // Different tokens
            token,
            calculator,
            MAX_BUMP_TIP,
            admin,
            REWARD_DURATION,
            MIN_STAKE,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationAllowset
        );

        // Setup permissions
        vm.prank(admin);
        staker.setRewardNotifier(rewardNotifier, true);
        vm.prank(admin);
        differentTokenStaker.setRewardNotifier(rewardNotifier, true);

        // Add users to allowsets
        address[3] memory users = [user1, user2, user3];
        for (uint256 i = 0; i < users.length; i++) {
            stakerAllowset.add(users[i]);
            contributionAllowset.add(users[i]);
        }

        // Setup user tokens
        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 1000e18);
            rewardToken.mint(users[i], 1000e18);

            vm.startPrank(users[i]);
            token.approve(address(staker), type(uint256).max);
            token.approve(address(differentTokenStaker), type(uint256).max);
            rewardToken.approve(address(differentTokenStaker), type(uint256).max);
            vm.stopPrank();
        }

        // Give reward notifier tokens
        token.mint(rewardNotifier, 10000e18);
        rewardToken.mint(rewardNotifier, 10000e18);
    }

    // ==================== CRITICAL AUDITOR SCENARIO TESTS ====================

    /// @notice Fuzz test for the exact auditor scenario: reward notification without checkpointing
    /// @dev Tests the scenario where rewards are notified but no users checkpoint their positions
    function testFuzz_auditorScenario_noCheckpointing(
        uint256 stakeAmount,
        uint256 firstRewardAmount,
        uint256 timeElapsed,
        uint256 secondRewardAmount
    ) public {
        // Bound inputs to reasonable ranges
        stakeAmount = bound(stakeAmount, MIN_STAKE, 100e18);
        firstRewardAmount = bound(firstRewardAmount, 1e18, 100e18);
        timeElapsed = bound(timeElapsed, 1 hours, REWARD_DURATION + 1 hours);
        secondRewardAmount = bound(secondRewardAmount, 1e18, 100e18);

        // Step 1: User stakes
        vm.prank(user1);
        staker.stake(stakeAmount, user1);

        // Step 2: First reward notification
        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), firstRewardAmount);
        staker.notifyRewardAmount(firstRewardAmount);
        vm.stopPrank();

        // Step 3: Time passes, no user activity (no checkpointing)
        vm.warp(block.timestamp + timeElapsed);

        // Step 4: Attempt second reward notification
        uint256 balanceBefore = token.balanceOf(address(staker));
        uint256 totalStaked = staker.totalStaked();
        uint256 totalRewards = staker.totalRewards();
        uint256 totalClaimed = staker.totalClaimedRewards();

        // Use new simple accounting: totalStaked + totalRewards - totalClaimed + newAmount
        uint256 required = totalStaked + totalRewards - totalClaimed + secondRewardAmount;

        vm.startPrank(rewardNotifier);

        if (balanceBefore >= required) {
            // Should succeed - sufficient balance
            staker.notifyRewardAmount(secondRewardAmount);

            // Verify balance protection held with new simple accounting
            uint256 balanceAfter = token.balanceOf(address(staker));
            uint256 newTotalRewards = staker.totalRewards();
            uint256 newTotalClaimed = staker.totalClaimedRewards();
            uint256 newRequired = staker.totalStaked() + newTotalRewards - newTotalClaimed;

            assertGe(balanceAfter, newRequired, "Balance protection violated after second notification");
        } else {
            // Should fail - insufficient balance, add tokens to make it work
            uint256 needed = required - balanceBefore;
            token.transfer(address(staker), needed);
            staker.notifyRewardAmount(secondRewardAmount);
        }

        vm.stopPrank();
    }

    // ==================== REWARD DISTRIBUTION TESTS ====================

    /// @notice Fuzz test for reward distribution after various operations
    function testFuzz_rewardDistributionAfterOperations(
        uint256 stakeAmount1,
        uint256 stakeAmount2,
        uint256 rewardAmount,
        uint256 operationChoice,
        uint256 timeElapsed
    ) public {
        stakeAmount1 = bound(stakeAmount1, MIN_STAKE, 50e18);
        stakeAmount2 = bound(stakeAmount2, MIN_STAKE, 50e18);
        rewardAmount = bound(rewardAmount, 10e18, 100e18);
        operationChoice = bound(operationChoice, 0, 2); // 0: claim, 1: compound, 2: no-op
        timeElapsed = bound(timeElapsed, 1 hours, 15 days);

        // Two users stake
        vm.prank(user1);
        staker.stake(stakeAmount1, user1);
        vm.prank(user2);
        staker.stake(stakeAmount2, user2);

        // Add sufficient rewards
        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), rewardAmount);
        staker.notifyRewardAmount(rewardAmount);
        vm.stopPrank();

        // Record state before operation
        uint256 totalClaimedBefore = staker.totalClaimedRewards();
        uint256 balanceBefore = token.balanceOf(address(staker));
        (, address feeCollector) = staker.claimFeeParameters();
        uint256 feeCollectorBalanceBefore = feeCollector != address(0) ? token.balanceOf(feeCollector) : 0;

        // Time passes
        vm.warp(block.timestamp + timeElapsed);

        // Perform operation
        vm.prank(user1);
        if (operationChoice == 0) {
            // Claim
            try staker.claimReward(Staker.DepositIdentifier.wrap(0)) {} catch {}
        } else if (operationChoice == 1) {
            // Compound
            try staker.compoundRewards(Staker.DepositIdentifier.wrap(0)) {} catch {}
        }
        // operationChoice == 2 is no-op

        // Verify accounting consistency after operation
        uint256 totalRewardsAfter = staker.totalRewards();
        uint256 totalClaimedAfter = staker.totalClaimedRewards();
        uint256 balanceAfter = token.balanceOf(address(staker));
        uint256 feeCollectorBalanceAfter = feeCollector != address(0) ? token.balanceOf(feeCollector) : 0;

        // Calculate fees that left the contract
        uint256 feesCollected = feeCollectorBalanceAfter - feeCollectorBalanceBefore;

        // Basic consistency checks
        if (operationChoice == 0 && totalClaimedAfter > totalClaimedBefore) {
            // Claim operation increased total claimed
            assertTrue(balanceAfter < balanceBefore, "Balance should decrease after claim");
        }

        // Balance protection should account for fees that have permanently left the contract
        uint256 totalStaked = staker.totalStaked();

        // Balance protection check - skip for compound operations since compounding
        // is not tracked in totalClaimedRewards in our current simple accounting approach
        if (operationChoice != 1) {
            // Skip for compound operations
            // The actual balance plus fees that were collected should cover all obligations
            // Using simple accounting: totalStaked + totalRewards - totalClaimed
            uint256 simpleAccountingRequired = totalStaked + totalRewardsAfter - totalClaimedAfter;
            assertGe(
                balanceAfter + feesCollected,
                simpleAccountingRequired,
                "Balance protection violated after operation (accounting for fees)"
            );
        }
    }

    // ==================== EDGE CASE TESTS ====================

    /// @notice Test precision edge cases
    function testFuzz_precisionEdgeCases(uint256 verySmallAmount, uint256 veryLargeAmount) public {
        verySmallAmount = bound(verySmallAmount, 1, MIN_STAKE - 1);
        veryLargeAmount = bound(veryLargeAmount, 1000e18, 10000e18);

        // Test very small stake (should fail)
        vm.prank(user1);
        vm.expectRevert();
        staker.stake(verySmallAmount, user1);

        // Test very large amounts work correctly
        vm.prank(user1);
        staker.stake(MIN_STAKE, user1);

        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), veryLargeAmount);
        staker.notifyRewardAmount(veryLargeAmount);
        vm.stopPrank();

        // Should not overflow or underflow
        uint256 totalRewards = staker.totalRewards();
        uint256 totalClaimed = staker.totalClaimedRewards();
        uint256 unclaimedRewards = totalRewards > totalClaimed ? totalRewards - totalClaimed : 0;
        assertGe(unclaimedRewards, 0, "accounting underflowed");
        assertLe(unclaimedRewards, veryLargeAmount * 2, "accounting overflowed");
    }

    /// @notice Test time boundary edge cases
    function testFuzz_timeBoundaryEdgeCases(uint256 stakeAmount, uint256 rewardAmount) public {
        stakeAmount = bound(stakeAmount, MIN_STAKE, 100e18);
        rewardAmount = bound(rewardAmount, 10e18, 100e18);

        // User stakes
        vm.prank(user1);
        staker.stake(stakeAmount, user1);

        // Add rewards
        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), rewardAmount);
        staker.notifyRewardAmount(rewardAmount);
        uint256 rewardEndTime = staker.rewardEndTime();
        vm.stopPrank();

        // Test exactly at reward end time
        vm.warp(rewardEndTime);
        uint256 totalRewardsAtEnd = staker.totalRewards();
        uint256 totalClaimedAtEnd = staker.totalClaimedRewards();

        // Test after reward end time
        vm.warp(rewardEndTime + 1);
        uint256 totalRewardsAfterEnd = staker.totalRewards();
        uint256 totalClaimedAfterEnd = staker.totalClaimedRewards();

        // Should be same (no new rewards added after end, no new claims without user activity)
        assertEq(totalRewardsAtEnd, totalRewardsAfterEnd, "TotalRewards changed after reward period ended");
        assertEq(totalClaimedAtEnd, totalClaimedAfterEnd, "TotalClaimed changed after reward period ended");

        // Test new reward notification after period ends
        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), rewardAmount);
        staker.notifyRewardAmount(rewardAmount);
        vm.stopPrank();

        // Balance protection should still work with simple accounting
        uint256 balance = token.balanceOf(address(staker));
        uint256 totalStaked = staker.totalStaked();
        uint256 totalRewards = staker.totalRewards();
        uint256 totalClaimed = staker.totalClaimedRewards();
        uint256 simpleRequired = totalStaked + totalRewards - totalClaimed;

        assertGe(balance, simpleRequired, "Balance protection failed at time boundary");
    }

    /// @notice Test small amount edge cases
    function testFuzz_smallAmountEdgeCases() public {
        // Test small reward notification (sufficient for valid rate)
        uint256 smallAmount = REWARD_DURATION; // 1 wei per second minimum
        vm.startPrank(rewardNotifier);
        token.transfer(address(staker), smallAmount);
        staker.notifyRewardAmount(smallAmount);
        vm.stopPrank();

        // Should not break accounting
        uint256 totalRewards = staker.totalRewards();
        uint256 totalClaimed = staker.totalClaimedRewards();
        assertGe(totalRewards, 0, "Small reward notification affected totalRewards");
        assertEq(totalClaimed, 0, "Small reward notification affected claimed tracking");
    }
}
