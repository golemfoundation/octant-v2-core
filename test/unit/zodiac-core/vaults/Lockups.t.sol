// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import { Setup } from "./Setup.sol";
import { DragonTokenizedStrategy__InsufficientLockupDuration, DragonTokenizedStrategy__RageQuitInProgress, DragonTokenizedStrategy__SharesStillLocked, DragonTokenizedStrategy__StrategyInShutdown, DragonTokenizedStrategy__SharesAlreadyUnlocked, DragonTokenizedStrategy__NoSharesToRageQuit, DragonTokenizedStrategy__ZeroLockupDuration, DragonTokenizedStrategy__WithdrawMoreThanMax, DragonTokenizedStrategy__RedeemMoreThanMax, TokenizedStrategy__TransferFailed, ZeroAssets, ZeroShares, DragonTokenizedStrategy__DepositMoreThanMax, DragonTokenizedStrategy__MintMoreThanMax, ERC20InsufficientBalance } from "src/errors.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract LockupsTest is Setup {
    // Events to track
    event NewLockupSet(address indexed user, uint256 lockTime, uint256 unlockTime, uint256 lockedShares);
    event RageQuitInitiated(address indexed user, uint256 indexed unlockTime);

    uint256 constant MINIMUM_LOCKUP_DURATION = 90 days;
    uint256 constant MAXIMUM_LOCKUP_DURATION = 3650 days;
    uint256 constant DEFAULT_RAGE_QUIT_DURATION = 90 days;
    uint256 constant INITIAL_DEPOSIT = 100_000e18;

    function setUp() public override {
        super.setUp();
        // Mint initial tokens to user for testing
        asset.mint(user, INITIAL_DEPOSIT);
        asset.mint(ben, INITIAL_DEPOSIT);

        vm.prank(user);
        asset.approve(address(strategy), type(uint256).max);
    }

    function test_depositWithLockup() public {
        uint256 lockupDuration = 100 days; // Just over minimum
        uint256 depositAmount = 10_000e18;

        // Expect the NewLockupSet event with appropriate parameters
        vm.expectEmit(true, true, true, true, address(strategy));
        emit NewLockupSet(user, 1, block.timestamp + lockupDuration, depositAmount);

        vm.startPrank(user);
        uint256 sharesBefore = strategy.totalSupply();
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        uint256 sharesAfter = strategy.totalSupply();
        vm.stopPrank();

        // Verify deposit succeeded
        assertEq(sharesAfter - sharesBefore, depositAmount, "Incorrect shares minted");

        // Verify lockup details
        (
            uint256 unlockTime,
            uint256 lockedShares,
            bool isRageQuit,
            uint256 totalShares,
            uint256 withdrawableShares
        ) = strategy.getUserLockupInfo(user);

        assertEq(unlockTime, block.timestamp + lockupDuration, "Incorrect unlock time");
        assertEq(lockedShares, depositAmount, "Incorrect locked shares");
        assertFalse(isRageQuit, "Should not be in rage quit");
        assertEq(totalShares, depositAmount, "Incorrect total shares");
        assertEq(withdrawableShares, 0, "Should have no withdrawable shares during lockup");
    }

    function test_mintWithLockup() public {
        uint256 lockupDuration = 100 days;
        uint256 sharesToMint = 10_000e18;

        vm.expectEmit(true, true, true, true, address(strategy));
        emit NewLockupSet(user, 1, block.timestamp + lockupDuration, sharesToMint);

        vm.startPrank(user);
        uint256 assetsBefore = asset.balanceOf(user);
        strategy.mintWithLockup(sharesToMint, user, lockupDuration);
        uint256 assetsAfter = asset.balanceOf(user);
        vm.stopPrank();

        uint256 assetsUsed = assetsBefore - assetsAfter;

        // Verify mint succeeded
        assertEq(strategy.balanceOf(user), sharesToMint, "Incorrect shares minted");
        assertTrue(assetsUsed > 0, "No assets were used");

        // Verify lockup details
        (uint256 unlockTime, uint256 lockedShares, , , ) = strategy.getUserLockupInfo(user);
        assertEq(unlockTime, block.timestamp + lockupDuration, "Incorrect unlock time");
        assertEq(lockedShares, sharesToMint, "Incorrect locked shares");
    }

    function test_revertBelowMinimumLockup() public {
        uint256 lockupDuration = 89 days; // Just under minimum
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__InsufficientLockupDuration.selector));
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        vm.stopPrank();
    }

    function test_extendLockup() public {
        // Initial lockup
        uint256 initialLockup = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, initialLockup);

        // Get initial unlock time
        (uint256 initialUnlockTime, , , , ) = strategy.getUserLockupInfo(user);

        // Extend lockup
        uint256 extensionPeriod = 50 days;
        strategy.depositWithLockup(depositAmount, user, extensionPeriod);

        // Verify extended lockup
        (uint256 newUnlockTime, , , , ) = strategy.getUserLockupInfo(user);
        assertEq(newUnlockTime, initialUnlockTime + extensionPeriod, "Lockup not extended correctly");
        vm.stopPrank();
    }

    function test_rageQuit() public {
        // Initial deposit with lockup
        uint256 initialLockup = 180 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, initialLockup);

        // Initiate rage quit
        vm.expectEmit(true, true, true, true, address(strategy));
        emit RageQuitInitiated(user, block.timestamp + MINIMUM_LOCKUP_DURATION);

        strategy.initiateRageQuit();

        // Verify rage quit state
        (
            uint256 unlockTime,
            uint256 lockedShares,
            bool isRageQuit,
            uint256 totalShares,
            uint256 withdrawableShares
        ) = strategy.getUserLockupInfo(user);

        assertEq(unlockTime, block.timestamp + MINIMUM_LOCKUP_DURATION, "Incorrect rage quit unlock time");
        assertEq(lockedShares, depositAmount, "Incorrect locked shares");
        assertTrue(isRageQuit, "Not in rage quit state");
        assertEq(totalShares, depositAmount, "Incorrect total shares");

        // Check partial unlocking after some time
        skip(45 days); // Half of MINIMUM_LOCKUP_DURATION
        uint256 expectedUnlocked = (depositAmount * 45 days) / MINIMUM_LOCKUP_DURATION;
        (, , , , withdrawableShares) = strategy.getUserLockupInfo(user);
        assertEq(withdrawableShares, expectedUnlocked, "Incorrect partial unlock amount");

        vm.stopPrank();
    }

    function test_rageQuit_cant_deposit_more() public {
        // Initial deposit with lockup
        uint256 initialLockup = 240 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, initialLockup);

        // Initiate rage quit
        vm.expectEmit(true, true, true, true, address(strategy));
        emit RageQuitInitiated(user, block.timestamp + MINIMUM_LOCKUP_DURATION);

        strategy.initiateRageQuit();

        // Attempt to deposit again during the rage quit period
        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.deposit(depositAmount, user);

        vm.stopPrank();
    }

    function test_rageQuit_cant_deposit_after_end_of_rage_quit_lockup() public {
        // Initial deposit with lockup
        uint256 initialLockup = 240 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, initialLockup);

        // Initiate rage quit
        vm.expectEmit(true, true, true, true, address(strategy));
        emit RageQuitInitiated(user, block.timestamp + MINIMUM_LOCKUP_DURATION);

        strategy.initiateRageQuit();

        skip(MINIMUM_LOCKUP_DURATION + 1 days);

        // Can't deposit even after the end of the rage quit period
        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.deposit(depositAmount, user);

        (, uint256 lockedShares, bool isRageQuit, uint256 totalShares, uint256 withdrawableShares) = strategy
            .getUserLockupInfo(user);

        assertEq(lockedShares, depositAmount, "Incorrect locked shares");
        assertEq(withdrawableShares, depositAmount, "Incorrect unlocked shares");
        assertTrue(isRageQuit, "Not in rage quit state");
        assertEq(totalShares, depositAmount, "Incorrect total shares");

        assertEq(
            strategy.maxRedeem(user),
            withdrawableShares,
            "After end of rage quit period all shares should be redeemable"
        );

        vm.stopPrank();
    }

    function test_revertRageQuitWithUnlockedShares() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Skip past lockup period
        skip(lockupDuration + 1);

        // Try to rage quit
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();
        vm.stopPrank();
    }

    function test_revertRageQuitTwice() public {
        uint256 lockupDuration = 180 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        strategy.initiateRageQuit();

        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.initiateRageQuit();
        vm.stopPrank();
    }

    function test_unlockedSharesCalculation() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Initially all shares should be locked
        assertEq(strategy.unlockedShares(user), 0, "Should have no unlocked shares initially");

        // Skip halfway through lockup
        skip(lockupDuration / 2);
        assertEq(strategy.unlockedShares(user), 0, "Should still have no unlocked shares mid-lockup");

        // Skip past lockup
        skip(lockupDuration);
        assertEq(strategy.unlockedShares(user), depositAmount, "All shares should be unlocked after lockup period");
        vm.stopPrank();
    }

    function test_withdrawWithLockup() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Try to withdraw during lockup
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.withdraw(depositAmount, user, user);

        // Skip past lockup
        skip(lockupDuration + 1);

        // Should be able to withdraw after lockup
        uint256 withdrawAmount = depositAmount / 2;
        strategy.withdraw(withdrawAmount, user, user);

        assertEq(strategy.balanceOf(user), depositAmount - withdrawAmount, "Incorrect remaining balance");
        vm.stopPrank();
    }

    function test_maxRedeem() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // During lockup, maxRedeem should be 0
        assertEq(strategy.maxRedeem(user), 0, "Should not be able to redeem during lockup");

        // Skip past lockup
        skip(lockupDuration + 1);

        // After lockup, should be able to redeem full amount
        assertEq(strategy.maxRedeem(user), depositAmount, "Should be able to redeem full amount after lockup");
        vm.stopPrank();
    }

    function test_revertWithdrawLockedShares() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;
        uint256 additionalDeposit = 5_000e18;

        vm.startPrank(user);
        // First deposit with lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Second deposit without lockup
        strategy.deposit(additionalDeposit, user);

        // Should not be able to withdraw locked shares
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.withdraw(depositAmount, user, user);

        // Skip past lockup
        skip(lockupDuration + 1);

        // Try to withdraw more than unlocked shares
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        strategy.withdraw(depositAmount + additionalDeposit + 1, user, user);

        strategy.withdraw(additionalDeposit, user, user, 0);
        vm.stopPrank();
    }

    function test_getUnlockTime() public {
        // Initially should be 0
        assertEq(strategy.getUnlockTime(user), 0, "Initial unlock time should be 0");

        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Check unlock time is set correctly
        assertEq(strategy.getUnlockTime(user), block.timestamp + lockupDuration, "Unlock time not set correctly");

        // Skip past lockup
        skip(lockupDuration + 1);

        // Unlock time should remain the same even after expiry
        assertEq(strategy.getUnlockTime(user), block.timestamp - 1, "Unlock time changed unexpectedly");

        // New deposit should update unlock time
        uint256 newLockupDuration = 120 days;
        strategy.depositWithLockup(depositAmount, user, newLockupDuration);
        assertEq(
            strategy.getUnlockTime(user),
            block.timestamp + newLockupDuration,
            "New unlock time not set correctly"
        );

        vm.stopPrank();
    }

    function test_maxWithdraw() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Initial deposit with lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // During lockup, max withdraw should be 0
        assertEq(strategy.maxWithdraw(user), 0, "Should not be able to withdraw during lockup");

        // Additional deposit without lockup has the current lockup applied to it
        uint256 topUpDepositLock = 5_000e18;
        strategy.deposit(topUpDepositLock, user);

        // Should be able to withdraw topUpDepositLock amount
        assertEq(strategy.maxWithdraw(user), 0, "Should be able to withdraw topUpDepositLock amount");

        // Skip past lockup
        skip(lockupDuration + 1);

        // After lockup, should be able to withdraw everything
        assertEq(
            strategy.maxWithdraw(user),
            depositAmount + topUpDepositLock,
            "Should be able to withdraw full amount after lockup"
        );

        vm.stopPrank();
    }

    function test_maxWithdrawWithMaxLoss() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;
        uint256 maxLoss = 100; // 1% max loss

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // During lockup
        assertEq(
            strategy.maxWithdraw(user, maxLoss),
            0,
            "Should not be able to withdraw during lockup even with maxLoss"
        );

        // Skip past lockup
        skip(lockupDuration + 1);

        // After lockup - maxLoss parameter should be ignored as per the implementation
        assertEq(
            strategy.maxWithdraw(user, maxLoss),
            strategy.maxWithdraw(user),
            "maxWithdraw with and without maxLoss should be equal"
        );

        vm.stopPrank();
    }

    function test_maxWithdrawRageQuit() public {
        uint256 lockupDuration = 180 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Initiate rage quit
        strategy.initiateRageQuit();

        // Initially should be 0
        assertEq(strategy.maxWithdraw(user), 0, "Should start at 0 withdraw amount");

        // Skip 45 days (half of MINIMUM_LOCKUP_DURATION)
        skip(45 days);

        // Should be able to withdraw ~50% of assets
        uint256 expectedWithdraw = (depositAmount * 45 days) / MINIMUM_LOCKUP_DURATION;
        uint256 actualWithdraw = strategy.maxWithdraw(user);
        assertApproxEqRel(
            actualWithdraw,
            expectedWithdraw,
            0.01e18, // 1% tolerance for rounding
            "Incorrect partial withdraw amount during rage quit"
        );

        // Skip to end of rage quit period
        skip(45 days);
        assertEq(
            strategy.maxWithdraw(user),
            depositAmount,
            "Should be able to withdraw full amount after rage quit period"
        );

        vm.stopPrank();
    }

    function test_maxRedeem_flow() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test initial state
        assertEq(strategy.maxRedeem(user), 0, "Should start with 0 redeemable shares");

        // Test during lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        assertEq(strategy.maxRedeem(user), 0, "Should have 0 redeemable shares during lockup");
        assertEq(strategy.maxRedeem(user, 100), 0, "MaxLoss parameter should not affect lockup");

        // Test mixed locked and topUpDepositLock shares
        uint256 topUpDeposit = 5_000e18;
        strategy.deposit(topUpDeposit, user);
        assertEq(strategy.maxRedeem(user), 0, "Should be able to redeem topUpDepositLock shares");

        // Test after lockup expires
        skip(lockupDuration + 1);
        uint256 actualRedeem = strategy.maxRedeem(user);
        assertEq(actualRedeem, depositAmount + topUpDeposit, "Should be able to redeem all shares after lockup");

        strategy.withdraw(strategy.maxRedeem(user), user, user);

        // Test during rage quit
        uint256 newLockupAmount = 100_000e18;
        strategy.depositWithLockup(newLockupAmount, user, 180 days);
        strategy.initiateRageQuit();

        // Skip 45 days (half of MINIMUM_LOCKUP_DURATION)
        skip(45 days);
        uint256 expectedRedeem = (newLockupAmount * 45 days) / MINIMUM_LOCKUP_DURATION;
        assertApproxEqRel(
            strategy.maxRedeem(user),
            expectedRedeem,
            0.01e18,
            "Incorrect redeemable shares during rage quit"
        );
        strategy.withdraw(expectedRedeem, user, user);

        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        strategy.withdraw(expectedRedeem, user, user);
        assertApproxEqRel(strategy.maxRedeem(user), 0, 0.01e18, "Incorrect redeemable shares during rage quit");

        skip(45 days / 2);

        strategy.withdraw(expectedRedeem / 2, user, user);

        vm.stopPrank();
    }

    function test_maxRedeem_flow_slippage() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test initial state
        assertEq(strategy.maxRedeem(user), 0, "Should start with 0 redeemable shares");

        // Test during lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        assertEq(strategy.maxRedeem(user), 0, "Should have 0 redeemable shares during lockup");
        assertEq(strategy.maxRedeem(user, 100), 0, "MaxLoss parameter should not affect lockup");

        // Test mixed locked and topUpDepositLock shares
        uint256 topUpDeposit = 5_000e18;
        strategy.deposit(topUpDeposit, user);
        assertEq(strategy.maxRedeem(user), 0, "Should be able to redeem topUpDepositLock shares");

        // Test after lockup expires
        skip(lockupDuration + 1);
        uint256 actualRedeem = strategy.maxRedeem(user);
        assertEq(actualRedeem, depositAmount + topUpDeposit, "Should be able to redeem all shares after lockup");

        strategy.withdraw(strategy.maxRedeem(user), user, user, 0);

        // Test during rage quit
        uint256 newLockupAmount = 100_000e18;
        strategy.depositWithLockup(newLockupAmount, user, 180 days);
        strategy.initiateRageQuit();

        // Skip 45 days (half of MINIMUM_LOCKUP_DURATION)
        skip(45 days);
        uint256 expectedRedeem = (newLockupAmount * 45 days) / MINIMUM_LOCKUP_DURATION;
        assertApproxEqRel(
            strategy.maxRedeem(user),
            expectedRedeem,
            0.01e18,
            "Incorrect redeemable shares during rage quit"
        );
        strategy.withdraw(expectedRedeem, user, user, 0);

        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        strategy.withdraw(expectedRedeem, user, user, 0);
        assertApproxEqRel(strategy.maxRedeem(user), 0, 0.01e18, "Incorrect redeemable shares during rage quit");

        skip(45 days / 2);

        strategy.withdraw(expectedRedeem / 2, user, user, 0);

        vm.stopPrank();
    }

    function test_getUnlockTime_comprehensive() public {
        // Initially should be 0 for unused address
        assertEq(strategy.getUnlockTime(user), 0, "Initial unlock time should be 0");
        assertEq(strategy.getUnlockTime(address(0xdead)), 0, "Should be 0 for unused address");

        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        // Set initial lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        uint256 actualUnlock = strategy.getUnlockTime(user);
        uint256 expectedUnlock = block.timestamp + lockupDuration;
        assertEq(actualUnlock, expectedUnlock, "Incorrect initial unlock time");

        // Additional deposit with longer lockup
        uint256 longerLockup = 200 days;
        strategy.depositWithLockup(depositAmount, user, longerLockup);
        expectedUnlock = expectedUnlock + longerLockup;
        assertEq(strategy.getUnlockTime(user), expectedUnlock, "Incorrect extended unlock time");

        // Additional deposit with shorter lockup (should still maintain longer unlock)
        uint256 shorterLockup = 50 days;
        strategy.depositWithLockup(depositAmount, user, shorterLockup);
        expectedUnlock = expectedUnlock + shorterLockup;

        assertEq(strategy.getUnlockTime(user), expectedUnlock, "Unlock time should not decrease");

        // Skip past unlock time
        skip(expectedUnlock + 1);
        // Should still return the same timestamp even after expiry
        assertEq(strategy.getUnlockTime(user), expectedUnlock, "Unlock time should not change after expiry");

        // Test during rage quit
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        strategy.initiateRageQuit();
        assertEq(
            strategy.getUnlockTime(user),
            block.timestamp + MINIMUM_LOCKUP_DURATION,
            "Incorrect unlock time after rage quit"
        );

        vm.stopPrank();
    }

    function test_getRemainingCooldown_comprehensive() public {
        // Initially should be 0
        assertEq(strategy.getRemainingCooldown(user), 0, "Initial cooldown should be 0");
        assertEq(strategy.getRemainingCooldown(address(0xdead)), 0, "Should be 0 for unused address");

        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Set initial lockup and check cooldown
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        uint256 actualCooldown = strategy.getRemainingCooldown(user);
        assertEq(actualCooldown, lockupDuration, "Initial cooldown incorrect");

        // Check cooldown reduces over time
        skip(10 days);
        assertEq(strategy.getRemainingCooldown(user), lockupDuration - 10 days, "Cooldown not decreasing correctly");

        // Additional deposit extending lockup
        uint256 extensionPeriod = 50 days;
        strategy.depositWithLockup(depositAmount, user, extensionPeriod);
        // Should now be original remaining time + extension
        assertEq(
            strategy.getRemainingCooldown(user),
            lockupDuration - 10 days + extensionPeriod,
            "Extended cooldown incorrect"
        );

        // Skip to end of cooldown
        skip(lockupDuration + extensionPeriod);
        assertEq(strategy.getRemainingCooldown(user), 0, "Cooldown should be 0 after completion");

        // Test rage quit cooldown
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        strategy.initiateRageQuit();
        assertEq(strategy.getRemainingCooldown(user), MINIMUM_LOCKUP_DURATION, "Incorrect cooldown after rage quit");

        // Check rage quit cooldown decreases
        skip(45 days);
        assertEq(
            strategy.getRemainingCooldown(user),
            MINIMUM_LOCKUP_DURATION - 45 days,
            "Rage quit cooldown not decreasing correctly"
        );

        vm.stopPrank();
    }

    function test_revert_initiateRageQuit_noShares() public {
        // Try to rage quit without any shares
        vm.prank(user);
        vm.expectRevert(DragonTokenizedStrategy__NoSharesToRageQuit.selector);
        strategy.initiateRageQuit();

        // Deposit without lockup and check it still fails
        uint256 depositAmount = 10_000e18;
        vm.startPrank(user);
        strategy.deposit(depositAmount, user);

        // skip any cooldown
        skip(1 days);

        // Should fail because no locked shares
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();
        vm.stopPrank();

        // Check with different users
        vm.prank(address(0xdead));
        vm.expectRevert(DragonTokenizedStrategy__NoSharesToRageQuit.selector);
        strategy.initiateRageQuit();
    }

    function test_revert_initiateRageQuit_alreadyInRageQuit() public {
        uint256 lockupDuration = 180 days;
        uint256 depositAmount = 10_000e18;

        // Set up initial locked position
        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // First rage quit should succeed
        strategy.initiateRageQuit();

        // Second rage quit should fail
        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.initiateRageQuit();

        // Skip some time and try again
        skip(45 days);
        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.initiateRageQuit();

        // Skip to end of rage quit period and try again
        skip(MINIMUM_LOCKUP_DURATION + 1);
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();
        vm.stopPrank();
    }

    function test_revert_initiateRageQuit_sharesAlreadyUnlocked() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        vm.expectRevert(DragonTokenizedStrategy__NoSharesToRageQuit.selector);
        strategy.initiateRageQuit();

        // Test with standard deposit (no lockup)
        strategy.deposit(depositAmount, user);
        assertEq(strategy.getUnlockTime(user), 0, "Unlock time should be 0 for unlocked shares");
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();

        // Test with expired lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        skip(lockupDuration + 1);
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();

        // Test with mixed locked and unlocked shares that are expired
        strategy.deposit(depositAmount, user);
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();

        // Test after completing a rage quit period
        uint256 newAmount = 5_000e18;
        strategy.depositWithLockup(newAmount, user, lockupDuration);
        strategy.initiateRageQuit();
        skip(MINIMUM_LOCKUP_DURATION + 1);
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();

        vm.stopPrank();
    }

    function test_revert_initiateRageQuit_unlockStates() public {
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test zero lockup
        strategy.deposit(depositAmount, user);
        vm.expectRevert(DragonTokenizedStrategy__SharesAlreadyUnlocked.selector);
        strategy.initiateRageQuit();

        // Test with locked shares
        uint256 lockupDuration = 100 days;
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Skip to just before unlock
        skip(lockupDuration - 1);
        // Should succeed
        strategy.initiateRageQuit();

        // Should fail since already in rage quit
        vm.expectRevert(DragonTokenizedStrategy__RageQuitInProgress.selector);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        vm.stopPrank();
    }

    function test_end_to_end_workflow() public {
        // Initial user setup
        vm.prank(user);
        asset.approve(address(strategy), type(uint256).max);

        // ======== Standard Deposit/Withdraw (No Lockup) ========
        uint256 standardDeposit = 10_000e18;
        vm.startPrank(user);

        // Test standard deposit
        uint256 sharesBefore = strategy.totalSupply();
        strategy.deposit(standardDeposit, user);
        uint256 sharesAfter = strategy.totalSupply();
        uint256 standardShares = sharesAfter - sharesBefore;

        // Verify standard deposit state
        (uint256 unlockTime, uint256 lockedShares, bool isRageQuit, , ) = strategy.getUserLockupInfo(user);
        assertEq(unlockTime, 0, "No unlock time should be set");
        assertEq(lockedShares, 0, "No shares should be locked");
        assertFalse(isRageQuit, "Should not be in rage quit");

        // Test standard withdraw
        uint256 assetsBefore = asset.balanceOf(user);
        uint256 assets = strategy.withdraw(standardDeposit / 2, user, user, 0); // Withdraw half
        assertEq(strategy.balanceOf(user), standardShares / 2, "Incorrect remaining balance after withdraw");
        assertEq(assetsBefore + assets, asset.balanceOf(user), "Incorrect remaining assets after withdraw");

        vm.stopPrank();

        // ======== Mint with Lockup ========
        uint256 sharesToMint = 20_000e18;
        uint256 lockupDuration = 100 days;

        vm.startPrank(user);
        strategy.mintWithLockup(sharesToMint, user, lockupDuration);

        // Verify locked mint state
        (unlockTime, lockedShares, isRageQuit, , ) = strategy.getUserLockupInfo(user);
        assertEq(unlockTime, block.timestamp + lockupDuration, "Incorrect unlock time");
        assertEq(lockedShares, standardShares / 2 + sharesToMint, "Incorrect locked shares");
        assertFalse(isRageQuit, "Should not be in rage quit");

        // Verify withdraw/redeem restrictions
        assertEq(strategy.maxWithdraw(user), 0, "Should not be able to withdraw locked shares");
        assertEq(strategy.maxRedeem(user), 0, "Should not be able to redeem locked shares");

        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.withdraw(0, user, user, 0);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.redeem(0, user, user, 0);

        // ======== Initiate Rage Quit for user ========
        strategy.initiateRageQuit();

        // Verify rage quit state
        (unlockTime, lockedShares, isRageQuit, , ) = strategy.getUserLockupInfo(user);
        assertTrue(isRageQuit, "Should be in rage quit");
        assertEq(unlockTime, block.timestamp + 90 days, "Incorrect rage quit duration");

        // Test partial withdrawal during rage quit
        skip(45 days); // Half of rage quit period
        uint256 expectedUnlock = ((standardShares / 2 + sharesToMint) * 45 days) / 90 days;
        uint256 actualMaxRedeem = strategy.maxRedeem(user);
        assertApproxEqRel(actualMaxRedeem, expectedUnlock, 0.01e18, "Incorrect unlocked amount during rage quit");
    }

    function test_revert_withdraw() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test withdraw with no balance
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        strategy.withdraw(depositAmount, user, user, 0);

        // Setup initial deposit with lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Test withdraw before unlock time
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.withdraw(depositAmount, user, user, 0);

        // Test withdraw more than max
        skip(lockupDuration + 1);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        strategy.withdraw(depositAmount + 1, user, user, 0);

        // Test withdraw zero amount
        vm.expectRevert(abi.encodeWithSelector(ZeroShares.selector));
        strategy.withdraw(0, user, user, 0);

        vm.stopPrank();
    }

    function test_revert_redeem() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test redeem with no balance
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__RedeemMoreThanMax.selector));
        strategy.redeem(depositAmount, user, user, 0);

        // Setup initial deposit with lockup
        strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Test redeem before unlock time
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__RedeemMoreThanMax.selector));
        strategy.redeem(depositAmount, user, user, 0);

        // Test redeem more than max
        skip(lockupDuration + 1);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__RedeemMoreThanMax.selector));
        strategy.redeem(depositAmount + 1, user, user, 0);

        // Test redeem zero amount
        vm.expectRevert(abi.encodeWithSelector(ZeroAssets.selector));
        strategy.redeem(0, user, user, 0);

        vm.stopPrank();
    }

    function test_revert_redeem_and_withdraw_precision() public {
        uint256 lockupDuration = 100 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);
        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        skip(lockupDuration + 1);

        // Test very small amounts that might cause precision issues
        uint256 tinyAmount = 1;
        strategy.withdraw(tinyAmount, user, user, 0);

        strategy.depositWithLockup(depositAmount, user, lockupDuration);
        skip(lockupDuration + 1);

        strategy.redeem(tinyAmount, user, user, 0);

        vm.stopPrank();
    }

    function test_revert_depositWithLockup() public {
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Test zero lockup duration
        vm.expectRevert(DragonTokenizedStrategy__ZeroLockupDuration.selector);
        strategy.depositWithLockup(depositAmount, user, 0);

        // Test lockup duration less than minimum
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__InsufficientLockupDuration.selector));
        strategy.depositWithLockup(depositAmount, user, MINIMUM_LOCKUP_DURATION - 1);

        // Test max uint deposit without enough balance
        uint256 sharesBefore = strategy.balanceOf(user);
        uint256 assetsBefore = asset.balanceOf(user);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__TransferFailed.selector));
        strategy.depositWithLockup(assetsBefore * 2, user, 100 days);
        //assertEq(asset.balanceOf(user), 0, "Should have no balance left after max deposit");
        assertEq(strategy.balanceOf(user), sharesBefore, "Should not have minted any shares");

        // Test max uint deposit with enough balance
        strategy.depositWithLockup(type(uint256).max, user, 100 days);
        assertEq(asset.balanceOf(user), 0, "Should have no balance left after max deposit");
        vm.stopPrank();
    }

    function test_revert_depositWithLockup_extendLockup() public {
        uint256 depositAmount = 10_000e18;
        uint256 initialLockup = 100 days;

        vm.startPrank(user);

        // Initial deposit
        strategy.depositWithLockup(depositAmount, user, initialLockup);
        skip(90 days);
        // Try to extend with insufficient duration
        uint256 shortExtension = 10 days;
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__InsufficientLockupDuration.selector));
        strategy.depositWithLockup(depositAmount, user, shortExtension);

        // Try to extend with zero duration
        vm.expectRevert(DragonTokenizedStrategy__ZeroLockupDuration.selector);
        strategy.depositWithLockup(depositAmount, user, 0);

        vm.stopPrank();
    }

    function test_revert_mintWithLockup() public {
        uint256 mintAmount = 10_000e18;

        vm.startPrank(user);

        // Test zero lockup duration
        vm.expectRevert(DragonTokenizedStrategy__ZeroLockupDuration.selector);
        strategy.mintWithLockup(mintAmount, user, 0);

        // Test minting zero shares
        vm.expectRevert(abi.encodeWithSelector(ZeroAssets.selector));
        strategy.mintWithLockup(0, user, 100 days);

        // Test mint requiring more assets than user has
        uint256 largeAmount = asset.balanceOf(user) + 1;
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__TransferFailed.selector));
        strategy.mintWithLockup(largeAmount, user, 100 days);
        assertEq(strategy.balanceOf(user), 0, "Should not have minted any shares");

        /// @dev if max mint of shares, the complete balance of the user is taken into account.
        // vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__TransferFailed.selector));
        // strategy.mintWithLockup(type(uint256).max, user, 100 days);
        vm.stopPrank();
    }

    function test_revert_mintWithLockup_extendLockup() public {
        uint256 mintAmount = 10_000e18;
        uint256 initialLockup = 100 days;

        vm.startPrank(user);

        // Initial mint
        strategy.mintWithLockup(mintAmount, user, initialLockup);
        skip(90 days);

        // Try to extend with insufficient duration
        uint256 shortExtension = 10 days;
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__InsufficientLockupDuration.selector));
        strategy.mintWithLockup(mintAmount, user, shortExtension);

        // Try to extend with zero duration
        vm.expectRevert(DragonTokenizedStrategy__ZeroLockupDuration.selector);
        strategy.mintWithLockup(mintAmount, user, 0);

        vm.stopPrank();
    }

    function test_revert_depositWithLockup_shutdown() public {
        uint256 depositAmount = 10_000e18;

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.startPrank(user);

        // Try to deposit after shutdown
        vm.expectRevert(DragonTokenizedStrategy__StrategyInShutdown.selector);
        strategy.depositWithLockup(depositAmount, user, 100 days);

        vm.stopPrank();
    }

    function test_revert_mintWithLockup_shutdown() public {
        uint256 mintAmount = 10_000e18;

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.startPrank(user);

        // Try to mint after shutdown
        vm.expectRevert(DragonTokenizedStrategy__StrategyInShutdown.selector);
        strategy.mintWithLockup(mintAmount, user, 100 days);

        vm.stopPrank();
    }

    function test_revert_deposit_shutdown() public {
        uint256 depositAmount = 10_000e18;

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.startPrank(user);

        // Try to deposit after shutdown
        vm.expectRevert(DragonTokenizedStrategy__StrategyInShutdown.selector);
        strategy.deposit(depositAmount, user);

        vm.stopPrank();
    }

    function test_redeem_during_ragequit() public {
        uint256 lockupDuration = 180 days;
        uint256 depositAmount = 10_000e18;

        vm.startPrank(user);

        // Initial setup
        uint256 shares = strategy.depositWithLockup(depositAmount, user, lockupDuration);

        // Initiate rage quit
        strategy.initiateRageQuit();

        // Get rage quit state
        (
            uint256 rageQuitUnlockTime,
            uint256 initialLockedShares,
            bool isRageQuit,
            uint256 totalShares,
            uint256 withdrawableShares
        ) = strategy.getUserLockupInfo(user);

        // Verify initial rage quit state
        assertTrue(isRageQuit, "Should be in rage quit");
        assertEq(rageQuitUnlockTime, block.timestamp + MINIMUM_LOCKUP_DURATION, "Incorrect rage quit duration");
        assertEq(initialLockedShares, depositAmount, "Initial locked shares incorrect");
        assertEq(totalShares, shares, "Total shares incorrect");
        assertEq(withdrawableShares, 0, "Should start with 0 withdrawable shares");

        // Skip to 25% through rage quit
        skip(MINIMUM_LOCKUP_DURATION / 4);

        // Calculate expected unlocked amount (25% should be unlocked)
        uint256 expectedUnlocked = (depositAmount * (MINIMUM_LOCKUP_DURATION / 4)) / MINIMUM_LOCKUP_DURATION;
        uint256 actualUnlocked = strategy.maxRedeem(user, 0);
        assertApproxEqRel(actualUnlocked, expectedUnlocked, 0.01e18, "Incorrect unlock amount at 25%");

        // Redeem half of available amount
        uint256 redeemAmount = actualUnlocked / 2;
        strategy.redeem(redeemAmount, user, user, 0);

        // Verify balances and state after first redeem
        (, uint256 remainingLockedShares, , uint256 newTotalShares, uint256 newWithdrawableShares) = strategy
            .getUserLockupInfo(user);

        assertEq(remainingLockedShares, depositAmount, "Remaining locked shares incorrect");
        assertEq(newTotalShares, shares - redeemAmount, "New total shares incorrect");
        assertEq(newWithdrawableShares, (actualUnlocked / 2), "New withdrawable shares incorrect");

        // Skip another 25% through rage quit (so 50% in total)
        skip(MINIMUM_LOCKUP_DURATION / 4);

        // Calculate expected unlocked amount (50% should be unlocked, including amount already redeemed)
        uint256 expectedUnlocked2 = (depositAmount * (MINIMUM_LOCKUP_DURATION / 2)) / MINIMUM_LOCKUP_DURATION;
        uint256 actualUnlocked2 = redeemAmount + strategy.maxRedeem(user, 0);
        assertEq(actualUnlocked2, expectedUnlocked2, "Incorrect unlock amount at 50%");
    }

    function test_topUpDepositWithLockup_rageQuit_withdrawSteps(
        uint64 randomInitialDeposit,
        uint64 randomSecondDeposit,
        uint8 initialLockupMultiplier,
        uint8 secondLockupMultiplier,
        uint8 topUpLockupMultiplier
    ) public {
        uint64 lockupBaseConstant = 30 days;
        // // Due to rounding down (`shares = _convertToShares(S, assets, Math.Rounding.Floor), 1 wei deposits end up with arithmetic issues
        vm.assume(randomInitialDeposit > 1 wei);
        vm.assume(randomSecondDeposit > 1 wei);

        // Keep existing assumptions
        vm.assume(
            lockupBaseConstant * initialLockupMultiplier >= MINIMUM_LOCKUP_DURATION &&
                lockupBaseConstant * initialLockupMultiplier <= MAXIMUM_LOCKUP_DURATION
        );
        vm.assume(
            lockupBaseConstant * secondLockupMultiplier >= MINIMUM_LOCKUP_DURATION &&
                lockupBaseConstant * secondLockupMultiplier <= MAXIMUM_LOCKUP_DURATION
        );
        vm.assume(
            lockupBaseConstant * topUpLockupMultiplier >= MINIMUM_LOCKUP_DURATION &&
                lockupBaseConstant * topUpLockupMultiplier <= MAXIMUM_LOCKUP_DURATION
        );
        vm.assume(lockupBaseConstant * (secondLockupMultiplier + topUpLockupMultiplier) <= MAXIMUM_LOCKUP_DURATION);

        uint256 initialLockup = lockupBaseConstant * initialLockupMultiplier;
        uint256 secondLockup = lockupBaseConstant * secondLockupMultiplier;
        uint256 topUpLockup = lockupBaseConstant * topUpLockupMultiplier;

        uint256 initialDeposit = uint256(randomInitialDeposit);
        uint256 secondDeposit = uint256(randomSecondDeposit);

        vm.startPrank(user);
        strategy.depositWithLockup(initialDeposit, user, initialLockup);

        // Withdraw initial deposit
        skip(initialLockup);
        strategy.withdraw(initialDeposit, user, user);

        // New deposit
        strategy.depositWithLockup(secondDeposit, user, secondLockup);

        // Top up deposit
        strategy.depositWithLockup(secondDeposit, user, topUpLockup);

        // Initiate rage quit
        strategy.initiateRageQuit();

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < DEFAULT_RAGE_QUIT_DURATION / lockupBaseConstant; i++) {
            skip(lockupBaseConstant);
            uint256 available = strategy.maxWithdraw(user);

            strategy.withdraw(available, user, user);
            totalWithdrawn += available;

            uint256 remaining = (secondDeposit * 2) - totalWithdrawn;
            assertEq(strategy.balanceOf(user), remaining, "Incorrect remaining balance");
        }

        // Verify full withdrawal after loop
        assertEq(strategy.balanceOf(user), 0, "Should have 0 balance");
        vm.stopPrank();
    }
}
