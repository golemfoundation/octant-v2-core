// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyLockedVault } from "src/core/MultistrategyLockedVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/core/MockYieldStrategy.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";

contract LockedVaultTest is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyLockedVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockFactory public factory;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public fish = address(0x2);
    address public feeRecipient = address(0x3);
    address constant ZERO_ADDRESS = address(0);
    uint256 internal constant RAGE_QUIT_COOLDOWN_CHANGE_DELAY = 14 days;

    uint256 public fishAmount = 10_000e18;
    uint256 public defaultProfitMaxUnlockTime = 7 days;
    uint256 public defaultRageQuitCooldown = 7 days;
    uint256 constant MAX_INT = type(uint256).max;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        // Deploy factory
        vm.prank(gov);
        factory = new MockFactory(0, feeRecipient);

        // Deploy vault
        vm.startPrank(address(factory));
        vaultImplementation = new MultistrategyLockedVault();
        vaultFactory = new MultistrategyVaultFactory("Locked Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyLockedVault(
            vaultFactory.deployNewVault(address(asset), "Locked Test Vault", "vLTST", gov, defaultProfitMaxUnlockTime)
        );

        // Initialize with rage quit cooldown period
        vm.expectRevert(); // Should revert since initialize was already called during deployment
        vault.initialize(address(asset), "Locked Test Vault", "vLTST", gov, defaultProfitMaxUnlockTime);
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set max deposit limit
        vault.set_deposit_limit(MAX_INT, false);
        vm.stopPrank();
    }

    function userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function testFuzz_RageQuitCooldownPeriodSetting(uint256 cooldownPeriod) public {
        // Bound to valid range: 1 day to 30 days (vault maximum), excluding current default (7 days)
        cooldownPeriod = bound(cooldownPeriod, 1 days, 30 days);

        // Skip the default value (7 days) since setting it to the same value should revert
        if (cooldownPeriod == 7 days) {
            cooldownPeriod = 8 days; // Use 8 days instead
        }

        // Should be able to propose and finalize rage quit cooldown period change
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(cooldownPeriod);
        assertEq(vault.pendingRageQuitCooldownPeriod(), cooldownPeriod, "Pending period should be set");

        // Fast forward past delay period
        vm.warp(block.timestamp + RAGE_QUIT_COOLDOWN_CHANGE_DELAY + 1);

        vault.finalizeRageQuitCooldownPeriodChange();
        assertEq(vault.rageQuitCooldownPeriod(), cooldownPeriod, "Rage quit cooldown period should be updated");
        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "Pending period should be cleared");
        vm.stopPrank();
    }

    function testFuzz_RageQuitCooldownPeriodSettingInvalid(uint256 invalidPeriod) public {
        // Test invalid periods (below 1 day or above 30 days)
        vm.assume(invalidPeriod < 1 days || invalidPeriod > 30 days);

        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.InvalidRageQuitCooldownPeriod.selector);
        vault.proposeRageQuitCooldownPeriodChange(invalidPeriod);
        vm.stopPrank();
    }

    function testFuzz_InitiateRageQuit(uint256 depositAmount, uint256 sharesToLock) public {
        // Bound deposit amount to reasonable range
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Bound shares to lock to not exceed balance
        uint256 userBalance = vault.balanceOf(fish);
        sharesToLock = bound(sharesToLock, 1, userBalance);

        // Initiate rage quit
        vm.prank(fish);
        vault.initiateRageQuit(sharesToLock);

        // Verify custody info
        (uint256 lockedShares, uint256 unlockTime) = vault.custodyInfo(fish);
        assertEq(
            unlockTime,
            block.timestamp + vault.rageQuitCooldownPeriod(),
            "Unlock time should be set to current time plus cooldown"
        );
        assertEq(lockedShares, sharesToLock, "Locked shares should match requested amount");
    }

    function testFuzz_CannotInitiateRageQuitWithoutShares(uint256 invalidAmount) public {
        // Test with zero amount
        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.InvalidShareAmount.selector);
        vault.initiateRageQuit(0);

        // Test when user has no balance but tries to lock positive amount
        invalidAmount = bound(invalidAmount, 1, type(uint256).max);
        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.InsufficientBalance.selector);
        vault.initiateRageQuit(invalidAmount);
    }

    function testFuzz_CanInitiateRageQuitWhenAlreadyUnlocked(uint256 firstDeposit, uint256 secondDeposit) public {
        // Bound deposits to reasonable ranges
        firstDeposit = bound(firstDeposit, 1e18, 500_000e18);
        secondDeposit = bound(secondDeposit, 1e18, 500_000e18);

        // Mint and deposit first amount
        asset.mint(fish, firstDeposit);
        userDeposit(fish, firstDeposit);

        // Initiate rage quit
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Withdraw all shares to clear custody
        vault.withdraw(firstDeposit, fish, fish, 0, new address[](0));

        // Deposit again
        vm.stopPrank();
        asset.mint(fish, secondDeposit);
        userDeposit(fish, secondDeposit);

        // Should be able to initiate rage quit again after custody is cleared
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Verify custody info
        (uint256 lockedShares, uint256 unlockTime) = vault.custodyInfo(fish);
        assertEq(unlockTime, block.timestamp + vault.rageQuitCooldownPeriod(), "Unlock time should be updated");
        assertEq(lockedShares, vault.balanceOf(fish), "Locked shares should match balance");
        vm.stopPrank();
    }

    function test_RegenGovernanceDirectTransfer() public {
        address newGovernance = address(0xABCD);

        vm.startPrank(gov);
        vm.expectEmit(true, true, false, true);
        emit IMultistrategyLockedVault.RegenGovernanceChanged(gov, newGovernance);
        vault.setRegenGovernance(newGovernance);
        vm.stopPrank();

        assertEq(vault.regenGovernance(), newGovernance, "governance should update immediately");
    }

    function test_RegenGovernanceRejectsInvalidAddresses() public {
        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.InvalidGovernanceAddress.selector);
        vault.setRegenGovernance(address(0));
        vault.setRegenGovernance(gov);
        vm.stopPrank();
    }

    // --- Additional branch coverage tests ---

    function test_CancelRageQuit_NoActiveRageQuit_Reverts() public {
        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.NoActiveRageQuit.selector);
        vault.cancelRageQuit();
    }

    function test_CancelRageQuit_Succeeds() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Now cancel
        vault.cancelRageQuit();
        vm.stopPrank();

        // Verify custody is cleared
        (uint256 lockedShares, ) = vault.custodyInfo(fish);
        assertEq(lockedShares, 0, "Custody should be cleared after cancel");
    }

    function test_ProposeRageQuitCooldownPeriod_SameAsCurrent_Reverts() public {
        vm.prank(gov);
        vm.expectRevert(IMultistrategyLockedVault.InvalidRageQuitCooldownPeriod.selector);
        vault.proposeRageQuitCooldownPeriodChange(7 days); // same as default
    }

    function test_ProposeRageQuitCooldownPeriodChange_NotGovernance_Reverts() public {
        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.NotRegenGovernance.selector);
        vault.proposeRageQuitCooldownPeriodChange(10 days);
    }

    function test_FinalizeRageQuitCooldownPeriodChange_NoPending_Reverts() public {
        vm.expectRevert(IMultistrategyLockedVault.NoPendingRageQuitCooldownPeriodChange.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
    }

    function test_FinalizeRageQuitCooldownPeriodChange_DelayNotElapsed_Reverts() public {
        vm.prank(gov);
        vault.proposeRageQuitCooldownPeriodChange(10 days);

        // Try to finalize immediately (delay not elapsed)
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
    }

    function test_CancelRageQuitCooldownPeriodChange_NoPending_Reverts() public {
        vm.prank(gov);
        vm.expectRevert(IMultistrategyLockedVault.NoPendingRageQuitCooldownPeriodChange.selector);
        vault.cancelRageQuitCooldownPeriodChange();
    }

    function test_CancelRageQuitCooldownPeriodChange_DelayElapsed_Reverts() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(10 days);

        // Warp past the delay
        vm.warp(block.timestamp + RAGE_QUIT_COOLDOWN_CHANGE_DELAY + 1);

        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayElapsed.selector);
        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    function test_CancelRageQuitCooldownPeriodChange_Succeeds() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(10 days);

        // Cancel while still in delay
        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "Pending should be cleared");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "Timestamp should be cleared");
    }

    function test_CancelRageQuitCooldownPeriodChange_NotGovernance_Reverts() public {
        vm.prank(gov);
        vault.proposeRageQuitCooldownPeriodChange(10 days);

        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.NotRegenGovernance.selector);
        vault.cancelRageQuitCooldownPeriodChange();
    }

    function test_Transfer_WithLockedShares_Reverts() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Try to transfer while shares are locked
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transfer(gov, 1);
        vm.stopPrank();
    }

    function test_Transfer_WithPartialLockedShares_Succeeds() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        uint256 balance = vault.balanceOf(fish);
        uint256 lockAmount = balance / 2;

        vm.startPrank(fish);
        vault.initiateRageQuit(lockAmount);

        // Transfer only the unlocked portion should succeed
        uint256 transferable = balance - lockAmount;
        vault.transfer(gov, transferable);
        vm.stopPrank();

        assertEq(vault.balanceOf(gov), transferable, "Gov should receive transferable shares");
    }

    function test_GetTransferableShares() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        uint256 balance = vault.balanceOf(fish);

        // No custody - all shares transferable (balance - lockedShares)
        (uint256 lockedShares, ) = vault.custodyInfo(fish);
        assertEq(balance - lockedShares, balance, "All shares should be transferable");

        // Lock half
        vm.prank(fish);
        vault.initiateRageQuit(balance / 2);

        (lockedShares, ) = vault.custodyInfo(fish);
        assertEq(balance - lockedShares, balance - balance / 2, "Half should be transferable");
    }

    function test_GetRageQuitableShares() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        uint256 balance = vault.balanceOf(fish);

        // No custody - all shares rage quitable
        (uint256 lockedShares, ) = vault.custodyInfo(fish);
        assertEq(lockedShares, 0, "All shares should be rage quitable");

        // Lock some
        vm.prank(fish);
        vault.initiateRageQuit(balance / 2);

        // Already has active custody
        (lockedShares, ) = vault.custodyInfo(fish);
        assertGt(lockedShares, 0, "Should have active custody");
    }

    function test_SetRegenGovernance_NotGovernance_Reverts() public {
        vm.prank(fish);
        vm.expectRevert(IMultistrategyLockedVault.NotRegenGovernance.selector);
        vault.setRegenGovernance(address(0xABC));
    }

    function test_WithdrawExceedsCustodiedAmount_Reverts() public {
        uint256 depositAmount = 10e18;
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        uint256 balance = vault.balanceOf(fish);
        uint256 lockAmount = balance / 2;

        vm.startPrank(fish);
        vault.initiateRageQuit(lockAmount);

        // Warp past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Try to withdraw more than custodied
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vault.withdraw(depositAmount, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_CannotInitiateRageQuitWhenAlreadyUnlockedAndCooldownPeriodHasNotPassed(
        uint256 depositAmount,
        uint256 timeElapsed
    ) public {
        // Bound deposit amount and time elapsed
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);
        uint256 cooldownPeriod = vault.rageQuitCooldownPeriod();
        timeElapsed = bound(timeElapsed, 1, cooldownPeriod - 1);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Initiate rage quit
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward but not past unlock time
        vm.warp(block.timestamp + timeElapsed);

        // Should revert when trying to initiate again while one is active
        vm.expectRevert(IMultistrategyLockedVault.RageQuitAlreadyInitiated.selector);
        vault.initiateRageQuit(depositAmount); // Try to lock same amount again
        vm.stopPrank();
    }

    function testFuzz_WithdrawAndRedeemWhenLocked(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound deposit amount
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Bound withdraw amount to be within deposited range
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        // Initiate rage quit
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Try to withdraw during lock period (should fail)
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(withdrawAmount, fish, fish, 0, new address[](0));

        // Try to redeem during lock period (should fail)
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.redeem(withdrawAmount, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_WithdrawAfterUnlock(uint256 depositAmount) public {
        // Bound deposit amount
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        // Store initial balance
        uint256 initialBalance = asset.balanceOf(fish);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Initiate rage quit
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Should be able to withdraw now
        uint256 withdrawnAmount = vault.withdraw(depositAmount, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, depositAmount, "Should withdraw correct amount");

        // Verify balances
        assertEq(vault.balanceOf(fish), 0, "Fish should have no remaining shares");
        assertEq(asset.balanceOf(fish), initialBalance + depositAmount, "Fish should have received all assets back");
        vm.stopPrank();
    }

    function testFuzz_RedeemAfterUnlock(uint256 depositAmount) public {
        // Bound deposit amount
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        // Store initial balance
        uint256 initialBalance = asset.balanceOf(fish);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Initiate rage quit
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // redeem
        uint256 shares = vault.balanceOf(fish);

        // Should be able to redeem now
        uint256 redeemedAmount = vault.redeem(shares, fish, fish, 0, new address[](0));
        assertEq(redeemedAmount, depositAmount, "Should redeem correct amount");

        // Verify balances
        assertEq(vault.balanceOf(fish), 0, "Fish should have no remaining shares");
        assertEq(asset.balanceOf(fish), initialBalance + depositAmount, "Fish should have received all assets back");
        vm.stopPrank();
    }

    function testFuzz_NormalWithdrawWithoutLockupShouldRevert(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound deposit amount
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Should not be able to withdraw without rage quit
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vm.prank(fish);
        vault.withdraw(withdrawAmount, fish, fish, 0, new address[](0));
    }

    function testFuzz_ReinitializeRageQuit(
        uint256 firstDeposit,
        uint256 partialLock,
        uint256 secondDeposit,
        uint256 newCooldown,
        uint256 timeElapsed
    ) public {
        // Bound inputs
        firstDeposit = bound(firstDeposit, 2e18, 500_000e18); // Need at least 2 to have partial
        partialLock = bound(partialLock, 1e18, firstDeposit / 2);
        secondDeposit = bound(secondDeposit, 1e18, 500_000e18);
        newCooldown = bound(newCooldown, 8 days, 30 days); // Different from default 7 days
        timeElapsed = bound(timeElapsed, 1 days, 6 days); // Less than original cooldown

        // Mint and deposit first amount
        asset.mint(fish, firstDeposit);
        userDeposit(fish, firstDeposit);

        // Initiate rage quit for partial amount initially
        vm.startPrank(fish);
        vault.initiateRageQuit(partialLock);

        (, uint256 originalUnlockTime) = vault.custodyInfo(fish);

        // Change cooldown period (this doesn't affect existing rage quits)
        vm.stopPrank();
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(newCooldown);
        vm.warp(block.timestamp + RAGE_QUIT_COOLDOWN_CHANGE_DELAY + 1);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();

        // Fast forward partway through cooldown
        vm.warp(block.timestamp + timeElapsed);

        // Mint more tokens for second deposit
        asset.mint(fish, secondDeposit);

        // Redeposit some funds (this should work as fish has available shares)
        userDeposit(fish, secondDeposit);

        // Original unlock time should not change despite re-deposit
        (, uint256 currentUnlockTime) = vault.custodyInfo(fish);
        assertEq(currentUnlockTime, originalUnlockTime, "Unlock time should not change on re-deposit");
    }

    function testFuzz_CannotWithdrawAgainAfterFirstWithdrawalWithoutNewRageQuit(
        uint256 depositAmount,
        uint256 firstWithdrawPercent
    ) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 2e18, 1_000_000e18); // Need at least 2 to split
        firstWithdrawPercent = bound(firstWithdrawPercent, 10, 90); // 10-90% for first withdrawal

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Initiate rage quit for full amount
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // First withdrawal (partial)
        uint256 firstWithdrawAmount = (depositAmount * firstWithdrawPercent) / 100;
        uint256 withdrawnAmount = vault.withdraw(firstWithdrawAmount, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, firstWithdrawAmount, "Should withdraw correct amount");

        // Can withdraw remaining custodied shares (no new rage quit needed)
        uint256 remainingAmount = depositAmount - firstWithdrawAmount;
        uint256 secondWithdrawAmount = vault.withdraw(remainingAmount, fish, fish, 0, new address[](0));
        assertEq(secondWithdrawAmount, remainingAmount, "Should withdraw remaining custodied amount");

        // Now custody should be cleared and no more withdrawals possible
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.withdraw(1, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_CanWithdrawAgainAfterNewRageQuit(uint256 depositAmount, uint256 firstLockPercent) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 2e18, 1_000_000e18); // Need at least 2 to split
        firstLockPercent = bound(firstLockPercent, 10, 90); // 10-90% for first lock

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // First rage quit for partial amount
        vm.startPrank(fish);
        uint256 firstLockAmount = (depositAmount * firstLockPercent) / 100;
        vault.initiateRageQuit(firstLockAmount);

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // First withdrawal (partial amount)
        uint256 withdrawnAmount = vault.withdraw(firstLockAmount, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, firstLockAmount, "Should withdraw correct amount");

        // Now custody cleared, can initiate new rage quit for remaining shares
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past new unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Should be able to withdraw remaining shares after new rage quit
        uint256 remainingAmount = depositAmount - firstLockAmount;
        withdrawnAmount = vault.withdraw(remainingAmount, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, remainingAmount, "Should withdraw remaining amount");
        vm.stopPrank();
    }

    function testFuzz_CannotRedeemAgainAfterFirstRedeemWithoutNewRageQuit(
        uint256 depositAmount,
        uint256 firstRedeemPercent
    ) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 2e18, 1_000_000e18); // Need at least 2 to split
        firstRedeemPercent = bound(firstRedeemPercent, 10, 90); // 10-90% for first redeem

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // Initiate rage quit for full amount
        vm.startPrank(fish);
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // First redeem (partial)
        uint256 firstRedeemAmount = (depositAmount * firstRedeemPercent) / 100;
        uint256 sharesToRedeem = vault.previewWithdraw(firstRedeemAmount);
        uint256 withdrawnAmount = vault.redeem(sharesToRedeem, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, firstRedeemAmount, "Should redeem correct amount");

        // Can redeem remaining custodied shares (no new rage quit needed)
        uint256 remainingShares = vault.balanceOf(fish);
        uint256 remainingAmount = depositAmount - firstRedeemAmount;
        uint256 secondWithdrawAmount = vault.redeem(remainingShares, fish, fish, 0, new address[](0));
        assertEq(secondWithdrawAmount, remainingAmount, "Should redeem remaining custodied amount");

        // Now custody should be cleared and no more redemptions possible
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.redeem(1, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testFuzz_CanRedeemAgainAfterNewRageQuit(uint256 depositAmount, uint256 firstLockPercent) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 2e18, 1_000_000e18); // Need at least 2 to split
        firstLockPercent = bound(firstLockPercent, 10, 90); // 10-90% for first lock

        // Mint and deposit
        asset.mint(fish, depositAmount);
        userDeposit(fish, depositAmount);

        // First rage quit for partial amount
        vm.startPrank(fish);
        uint256 firstLockAmount = (depositAmount * firstLockPercent) / 100;
        uint256 sharesToLock = vault.previewWithdraw(firstLockAmount);
        vault.initiateRageQuit(sharesToLock);

        // Fast forward past unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // First redeem (exactly what was locked)
        uint256 withdrawnAmount = vault.redeem(sharesToLock, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, firstLockAmount, "Should redeem correct amount");

        // Now custody cleared, can initiate new rage quit for remaining shares
        vault.initiateRageQuit(vault.balanceOf(fish));

        // Fast forward past new unlock time
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Should be able to redeem remaining shares after new rage quit
        uint256 remainingShares = vault.balanceOf(fish);
        uint256 remainingAmount = depositAmount - firstLockAmount;
        withdrawnAmount = vault.redeem(remainingShares, fish, fish, 0, new address[](0));
        assertEq(withdrawnAmount, remainingAmount, "Should redeem remaining amount");
        vm.stopPrank();
    }

    // ========================================================
    //  Coverage: getter functions and edge case branches
    // ========================================================

    function test_pendingRageQuitCooldownPeriod_returnsValue() public {
        // Before any proposal, should be 0
        assertEq(vault.pendingRageQuitCooldownPeriod(), 0);

        // After proposal, should return the pending value
        vm.prank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        assertEq(vault.pendingRageQuitCooldownPeriod(), 14 days);
    }

    function test_rageQuitCooldownPeriodChangeTimestamp_returnsValue() public {
        // Before any proposal, should be 0
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0);

        // After proposal, should return the timestamp
        vm.prank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        assertGt(vault.rageQuitCooldownPeriodChangeTimestamp(), 0);
    }

    function test_processCustodyWithdrawal_insufficientBalance() public {
        // Deposit and initiate rage quit
        userDeposit(fish, fishAmount);
        uint256 shares = vault.balanceOf(fish);

        vm.prank(fish);
        vault.initiateRageQuit(shares);

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Directly reduce fish's balance below lockedShares via vm.store
        // ERC20Upgradeable uses slot keccak256(abi.encode(account, uint256(0x52))) for balances
        // (ERC20StorageLocation = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff)))
        // Slot 0 in the ERC20 storage struct is _balances mapping
        // But we can use the deal cheatcode for ERC20 tokens:
        deal(address(vault), fish, shares - 1, true);

        // Now balanceOf(fish) < shares but lockedShares == shares
        assertLt(vault.balanceOf(fish), shares);

        // Try to redeem - balance < shares triggers InsufficientSharesToRedeem in base vault
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InsufficientSharesToRedeem.selector);
        vault.redeem(shares, fish, fish, 0, new address[](0));
    }
}
