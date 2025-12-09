// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyLockedVault } from "src/core/MultistrategyLockedVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract TwoStepCooldownChangeInvariantTest is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyLockedVault vault;
    MultistrategyVaultFactory vaultFactory;
    MockERC20 asset;

    address gov = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);
    address nonGov = address(0x4);

    uint256 constant INITIAL_COOLDOWN = 7 days;
    uint256 constant CHANGE_DELAY = 14 days;
    uint256 constant MIN_COOLDOWN = 1 days;
    uint256 constant MAX_COOLDOWN = 30 days;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(user1, 1_000_000e18);
        asset.mint(user2, 1_000_000e18);

        // Deploy vault
        vaultImplementation = new MultistrategyLockedVault();
        vaultFactory = new MultistrategyVaultFactory("Test Factory", address(vaultImplementation), gov);

        vm.prank(gov);
        vault = MultistrategyLockedVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "TV", gov, 7 days));

        // Setup roles
        vm.startPrank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.setDepositLimit(type(uint256).max, false);
        vm.stopPrank();
    }

    // ===== PROPOSAL INVARIANTS =====

    function invariant_OnlyGovernanceCanPropose() public {
        // Test that non-governance cannot propose changes
        vm.startPrank(nonGov);
        vm.expectRevert(IMultistrategyLockedVault.NotRegenGovernance.selector);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();
    }

    function invariant_CannotProposeSamePeriod() public {
        uint256 currentPeriod = vault.rageQuitCooldownPeriod();

        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.InvalidRageQuitCooldownPeriod.selector);
        vault.proposeRageQuitCooldownPeriodChange(currentPeriod);
        vm.stopPrank();
    }

    function invariant_CannotProposeInvalidPeriods() public {
        // Test below minimum
        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.InvalidRageQuitCooldownPeriod.selector);
        vault.proposeRageQuitCooldownPeriodChange(MIN_COOLDOWN - 1);

        // Test above maximum
        vm.expectRevert(IMultistrategyLockedVault.InvalidRageQuitCooldownPeriod.selector);
        vault.proposeRageQuitCooldownPeriodChange(MAX_COOLDOWN + 1);
        vm.stopPrank();
    }

    function invariant_ProposalSetsStateCorrectly() public {
        uint256 newPeriod = 14 days;
        uint256 expectedTimestamp = block.timestamp;

        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(newPeriod);
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), newPeriod, "Pending period should be set");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), expectedTimestamp, "Timestamp should be set");
        assertEq(vault.rageQuitCooldownPeriod(), INITIAL_COOLDOWN, "Current period should be unchanged");
    }

    function invariant_CannotHaveMultiplePendingChanges() public {
        // Propose first change
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);

        // Try to propose second change (should replace the first)
        vault.proposeRageQuitCooldownPeriodChange(21 days);
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), 21 days, "Should replace pending change");
    }

    // ===== GRACE PERIOD INVARIANTS =====

    function invariant_CurrentPeriodUnchangedDuringGracePeriod() public {
        uint256 originalPeriod = vault.rageQuitCooldownPeriod();

        // Propose change
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        // Fast forward but not past delay
        vm.warp(block.timestamp + CHANGE_DELAY - 1);

        assertEq(vault.rageQuitCooldownPeriod(), originalPeriod, "Current period should be unchanged");
    }

    function invariant_UsersCanRageQuitDuringGracePeriod() public {
        // User deposits (need to ensure they have enough balance)
        uint256 depositAmount = 1000e18;
        vm.startPrank(user1);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);
        vm.stopPrank();

        // Verify user has shares
        uint256 userShares = vault.balanceOf(user1);
        assertGt(userShares, 0, "User should have shares");

        // Propose change
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        // User should be able to rage quit during grace period
        vm.startPrank(user1);
        vault.initiateRageQuit(userShares);
        vm.stopPrank();

        (uint256 lockedShares, uint256 unlockTime) = vault.custodyInfo(user1);
        assertGt(lockedShares, 0, "User should have locked shares");
        assertEq(unlockTime, block.timestamp + INITIAL_COOLDOWN, "Should use current cooldown period");
    }

    function invariant_PendingChangePeristsDuringGracePeriod() public {
        uint256 newPeriod = 14 days;

        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(newPeriod);
        vm.stopPrank();

        // Fast forward but not past delay
        vm.warp(block.timestamp + CHANGE_DELAY - 1);

        assertEq(vault.pendingRageQuitCooldownPeriod(), newPeriod, "Pending change should persist");
    }

    // ===== FINALIZATION INVARIANTS =====

    function invariant_CannotFinalizeBeforeDelay() public {
        vm.prank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);

        // Try to finalize immediately
        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();

        // Try to finalize just before delay
        vm.warp(block.timestamp + CHANGE_DELAY - 1);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    function invariant_AnyoneCanFinalize() public {
        uint256 newPeriod = 14 days;

        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(newPeriod);
        vm.stopPrank();

        // Fast forward past delay
        vm.warp(block.timestamp + CHANGE_DELAY + 1);

        // Anyone can finalize (including non-governance)
        vm.startPrank(nonGov);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.rageQuitCooldownPeriod(), newPeriod, "Period should be updated");
    }

    function invariant_FinalizationUpdatesStateCorrectly() public {
        uint256 newPeriod = 14 days;

        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(newPeriod);
        vm.stopPrank();

        vm.warp(block.timestamp + CHANGE_DELAY + 1);
        vm.startPrank(gov);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.rageQuitCooldownPeriod(), newPeriod, "Period should be updated");
        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "Pending period should be cleared");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "Timestamp should be cleared");
    }

    function invariant_CannotFinalizeNonExistentChange() public {
        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.NoPendingRageQuitCooldownPeriodChange.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    function invariant_CannotFinalizeTwice() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        vm.warp(block.timestamp + CHANGE_DELAY + 1);
        vm.startPrank(gov);
        vault.finalizeRageQuitCooldownPeriodChange();

        // Try to finalize again
        vm.expectRevert(IMultistrategyLockedVault.NoPendingRageQuitCooldownPeriodChange.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    // ===== CANCELLATION INVARIANTS =====

    function invariant_OnlyGovernanceCanCancel() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        vm.startPrank(nonGov);
        vm.expectRevert(IMultistrategyLockedVault.NotRegenGovernance.selector);
        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    function invariant_CancellationClearsState() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);

        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "Pending period should be cleared");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "Timestamp should be cleared");
    }

    function invariant_CannotCancelNonExistentChange() public {
        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.NoPendingRageQuitCooldownPeriodChange.selector);
        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    // ===== USER PROTECTION INVARIANTS =====

    function invariant_UsersUseCorrectCooldownPeriod() public {
        // User deposits
        vm.startPrank(user1);
        asset.approve(address(vault), 1000e18);
        vault.deposit(1000e18, user1);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        asset.approve(address(vault), 1000e18);
        vault.deposit(1000e18, user2);
        vm.stopPrank();

        // Store the time when user1 rage quits
        uint256 user1RageQuitTime = block.timestamp;

        // User1 rage quits before change
        vm.startPrank(user1);
        vault.initiateRageQuit(vault.balanceOf(user1));
        vm.stopPrank();

        // Propose change
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(21 days);
        vm.stopPrank();

        // Finalize change
        vm.warp(block.timestamp + CHANGE_DELAY + 1);
        vm.startPrank(gov);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();

        // Store the time when user2 rage quits
        uint256 user2RageQuitTime = block.timestamp;

        // User2 rage quits after change
        vm.startPrank(user2);
        vault.initiateRageQuit(vault.balanceOf(user2));
        vm.stopPrank();

        // Check cooldown periods
        (, uint256 user1UnlockTime) = vault.custodyInfo(user1);
        (, uint256 user2UnlockTime) = vault.custodyInfo(user2);

        // User1 should have used old period (7 days from their rage quit time)
        // User2 should have used new period (21 days from their rage quit time)
        uint256 user1ExpectedUnlock = user1RageQuitTime + INITIAL_COOLDOWN;
        uint256 user2ExpectedUnlock = user2RageQuitTime + 21 days;

        assertEq(user1UnlockTime, user1ExpectedUnlock, "User1 should use old cooldown");
        assertEq(user2UnlockTime, user2ExpectedUnlock, "User2 should use new cooldown");
    }

    // ===== STATE CONSISTENCY INVARIANTS =====

    function invariant_StateConsistencyWhenNoPendingChange() public {
        // Initially, no pending change
        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "No pending period initially");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "No timestamp initially");

        // After cancellation
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);

        vault.cancelRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "No pending period after cancel");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "No timestamp after cancel");

        // After finalization
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        vm.warp(block.timestamp + CHANGE_DELAY + 1);
        vm.startPrank(gov);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();

        assertEq(vault.pendingRageQuitCooldownPeriod(), 0, "No pending period after finalize");
        assertEq(vault.rageQuitCooldownPeriodChangeTimestamp(), 0, "No timestamp after finalize");
    }

    function invariant_CurrentPeriodOnlyChangesOnFinalization() public {
        uint256 originalPeriod = vault.rageQuitCooldownPeriod();

        // Period shouldn't change on proposal
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();
        assertEq(vault.rageQuitCooldownPeriod(), originalPeriod, "Period unchanged on proposal");

        // Period shouldn't change during grace period
        vm.warp(block.timestamp + CHANGE_DELAY - 1);
        assertEq(vault.rageQuitCooldownPeriod(), originalPeriod, "Period unchanged during grace");

        // Period should change on finalization
        vm.warp(block.timestamp + 2);
        vm.startPrank(gov);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
        assertEq(vault.rageQuitCooldownPeriod(), 14 days, "Period changed on finalization");
    }

    // ===== SECURITY INVARIANTS =====

    function invariant_CannotBypassGracePeriod() public {
        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        uint256 startTime = block.timestamp;

        // Try various ways to bypass grace period - test specific times
        vm.startPrank(gov);
        vm.warp(startTime + 1 days);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();

        vm.warp(startTime + 7 days);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();

        vm.warp(startTime + CHANGE_DELAY - 1);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }

    function invariant_CannotActivateChangesEarly() public {
        uint256 originalPeriod = vault.rageQuitCooldownPeriod();

        vm.startPrank(gov);
        vault.proposeRageQuitCooldownPeriodChange(14 days);
        vm.stopPrank();

        // Time travel to just before delay expires
        vm.warp(block.timestamp + CHANGE_DELAY - 1);

        assertEq(vault.rageQuitCooldownPeriod(), originalPeriod, "Period should not change early");

        vm.startPrank(gov);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitCooldownPeriodChangeDelayNotElapsed.selector);
        vault.finalizeRageQuitCooldownPeriodChange();
        vm.stopPrank();
    }
}
