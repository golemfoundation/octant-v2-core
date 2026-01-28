// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyLockedVault } from "src/core/MultistrategyLockedVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";

contract LockedVaultCustodyInvariant is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyLockedVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockFactory public factory;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public feeRecipient = address(0x5);
    address constant ZERO_ADDRESS = address(0);

    uint256 public defaultAmount = 10_000e18;
    uint256 public defaultProfitMaxUnlockTime = 7 days;
    uint256 public defaultRageQuitCooldown = 7 days;
    uint256 constant MAX_INT = type(uint256).max;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(alice, defaultAmount * 10);
        asset.mint(bob, defaultAmount * 10);
        asset.mint(charlie, defaultAmount * 10);

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

    // Helper function to get custody info
    function getCustodyInfo(address user) internal view returns (uint256 lockedShares, uint256 unlockTime) {
        (uint256 _lockedShares, uint256 _unlockTime) = vault.custodyInfo(user);
        return (_lockedShares, _unlockTime);
    }

    /*//////////////////////////////////////////////////////////////
                    1. CUSTODY AMOUNT INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_custodyNeverExceedsBalance() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        uint256 aliceBalance = vault.balanceOf(alice);

        // Try to initiate rage quit with more shares than balance
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InsufficientBalance.selector);
        vault.initiateRageQuit(aliceBalance + 1);

        // Initiate with valid amount
        vm.prank(alice);
        vault.initiateRageQuit(aliceBalance / 2);

        // Verify custody doesn't exceed balance
        (uint256 lockedShares, ) = getCustodyInfo(alice);
        assertLe(lockedShares, vault.balanceOf(alice), "Custody should never exceed balance");
    }

    function test_invariant_totalCustodyNeverExceedsTotalSupply() public {
        // Setup: Multiple users deposit and initiate rage quit
        userDeposit(alice, defaultAmount);
        userDeposit(bob, defaultAmount);
        userDeposit(charlie, defaultAmount);

        // Each user initiates rage quit with different amounts
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount / 2);

        vm.prank(bob);
        vault.initiateRageQuit(defaultAmount / 3);

        vm.prank(charlie);
        vault.initiateRageQuit(defaultAmount);

        // Calculate total custody
        (uint256 aliceLocked, ) = getCustodyInfo(alice);
        (uint256 bobLocked, ) = getCustodyInfo(bob);
        (uint256 charlieLocked, ) = getCustodyInfo(charlie);

        uint256 totalCustody = aliceLocked + bobLocked + charlieLocked;
        uint256 totalSupply = vault.totalSupply();

        assertLe(totalCustody, totalSupply, "Total custody should never exceed total supply");
    }

    function test_invariant_custodyOnlyDecreasesOrZero() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        (uint256 initialLocked, ) = getCustodyInfo(alice);
        assertEq(initialLocked, defaultAmount, "Initial custody should match requested amount");

        // Fast forward and withdraw partial amount
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        vm.prank(alice);
        vault.withdraw(defaultAmount / 2, alice, alice, 0, new address[](0));

        (uint256 afterWithdrawLocked, ) = getCustodyInfo(alice);
        assertLt(afterWithdrawLocked, initialLocked, "Custody should decrease after withdrawal");
        assertEq(afterWithdrawLocked, defaultAmount / 2, "Custody should decrease by withdrawn amount");

        // Withdraw remaining
        vm.prank(alice);
        vault.withdraw(defaultAmount / 2, alice, alice, 0, new address[](0));

        (uint256 finalLocked, ) = getCustodyInfo(alice);
        assertEq(finalLocked, 0, "Custody should be zero after full withdrawal");
    }

    function test_invariant_onlyOneActiveRageQuit() public {
        // Setup: User deposits
        userDeposit(alice, defaultAmount * 2);

        // First rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Try to initiate another rage quit (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.RageQuitAlreadyInitiated.selector);
        vault.initiateRageQuit(defaultAmount);

        // Verify only one active rage quit exists
        (uint256 lockedShares, ) = getCustodyInfo(alice);
        assertEq(lockedShares, defaultAmount, "Should only have one active rage quit");
    }

    /*//////////////////////////////////////////////////////////////
                    2. TRANSFER RESTRICTION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_cannotTransferLockedShares() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Try to transfer all shares (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transfer(bob, defaultAmount);

        // Try to transfer more than available (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transfer(bob, 1);

        // Deposit more and try to transfer only unlocked shares (should succeed)
        userDeposit(alice, defaultAmount);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, defaultAmount), "Should be able to transfer unlocked shares");

        // Verify custody remains unchanged
        (uint256 lockedShares, ) = getCustodyInfo(alice);
        assertEq(lockedShares, defaultAmount, "Custody should remain unchanged after transfer");
    }

    function test_invariant_transferFromRespectsLocks() public {
        // Setup: Alice deposits and approves Bob
        userDeposit(alice, defaultAmount * 2);

        vm.prank(alice);
        vault.approve(bob, defaultAmount * 2);

        // Alice initiates rage quit for half her shares
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Bob tries to transfer all of Alice's shares (should fail)
        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transferFrom(alice, bob, defaultAmount * 2);

        // Bob tries to transfer more than available (should fail)
        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transferFrom(alice, bob, defaultAmount + 1);

        // Bob transfers exactly the available amount (should succeed)
        vm.prank(bob);
        assertTrue(vault.transferFrom(alice, bob, defaultAmount), "Should transfer available shares");

        // Verify Alice still has locked shares
        (uint256 aliceLocked, ) = getCustodyInfo(alice);
        assertEq(aliceLocked, defaultAmount, "Alice's custody should remain unchanged");
        assertEq(vault.balanceOf(alice), defaultAmount, "Alice should still have locked shares");
        assertEq(vault.balanceOf(bob), defaultAmount, "Bob should have received unlocked shares");
    }

    function test_invariant_transferDoesNotAffectCustody() public {
        // Setup: Multiple users with custody
        userDeposit(alice, defaultAmount * 2);
        userDeposit(bob, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        vm.prank(bob);
        vault.initiateRageQuit(defaultAmount / 2);

        // Record initial custody states
        (uint256 aliceLockedBefore, ) = getCustodyInfo(alice);
        (uint256 bobLockedBefore, ) = getCustodyInfo(bob);

        // Alice transfers her available shares to Charlie
        vm.prank(alice);
        vault.transfer(charlie, defaultAmount);

        // Bob transfers his available shares to Charlie
        vm.prank(bob);
        vault.transfer(charlie, defaultAmount / 2);

        // Verify custody states remain unchanged
        (uint256 aliceLockedAfter, ) = getCustodyInfo(alice);
        (uint256 bobLockedAfter, ) = getCustodyInfo(bob);
        (uint256 charlieLocked, ) = getCustodyInfo(charlie);

        assertEq(aliceLockedAfter, aliceLockedBefore, "Alice's custody should not change");
        assertEq(bobLockedAfter, bobLockedBefore, "Bob's custody should not change");
        assertEq(charlieLocked, 0, "Charlie should have no custody");
    }

    function test_invariant_approvalDoesNotBypassLocks() public {
        // Setup: Alice deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Alice approves Bob for all her shares
        vm.prank(alice);
        vault.approve(bob, defaultAmount);

        // Bob still cannot transfer locked shares
        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transferFrom(alice, charlie, defaultAmount);

        // Even with max approval
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transferFrom(alice, charlie, 1);
    }

    /*//////////////////////////////////////////////////////////////
                3. WITHDRAWAL/REDEMPTION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_onlyCustodiedSharesCanBeWithdrawn() public {
        // Setup: User deposits but doesn't initiate rage quit
        userDeposit(alice, defaultAmount);

        // Try to withdraw without custody (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Initiate rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Now withdrawal should succeed
        vm.prank(alice);
        uint256 withdrawn = vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));
        assertEq(withdrawn, defaultAmount, "Should withdraw custodied amount");
    }

    function test_invariant_cannotWithdrawBeforeCooldown() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Try to withdraw immediately (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Try just before cooldown expires (should fail)
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() - 1);
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Try exactly at cooldown expiry (should succeed)
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        uint256 withdrawn = vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));
        assertEq(withdrawn, defaultAmount, "Should withdraw after cooldown");
    }

    function test_invariant_cannotWithdrawMoreThanCustodied() public {
        // Setup: User deposits and initiates partial rage quit
        userDeposit(alice, defaultAmount * 2);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Try to withdraw more than custodied (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vault.withdraw(defaultAmount * 2, alice, alice, 0, new address[](0));

        // Try to withdraw exactly one more than custodied (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vault.withdraw(defaultAmount + 1, alice, alice, 0, new address[](0));

        // Withdraw exactly custodied amount (should succeed)
        vm.prank(alice);
        uint256 withdrawn = vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));
        assertEq(withdrawn, defaultAmount, "Should withdraw exact custodied amount");
    }

    function test_invariant_withdrawalReducesCustody() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Withdraw partial amount
        uint256 withdrawAmount = defaultAmount / 4;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice, 0, new address[](0));

        // Check custody reduced by exact amount
        (uint256 lockedAfterFirst, ) = getCustodyInfo(alice);
        assertEq(lockedAfterFirst, defaultAmount - withdrawAmount, "Custody should reduce by withdrawn amount");

        // Withdraw another portion
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice, 0, new address[](0));

        (uint256 lockedAfterSecond, ) = getCustodyInfo(alice);
        assertEq(lockedAfterSecond, defaultAmount - (2 * withdrawAmount), "Custody should reduce cumulatively");
    }

    function test_invariant_fullWithdrawalClearsCustody() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Verify custody exists
        (uint256 lockedBefore, ) = getCustodyInfo(alice);
        assertEq(lockedBefore, defaultAmount, "Should have custody before withdrawal");

        // Fast forward and withdraw all
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);
        vm.prank(alice);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Verify custody is cleared
        (uint256 lockedAfter, uint256 unlockTime) = getCustodyInfo(alice);
        assertEq(lockedAfter, 0, "Custody should be zero after full withdrawal");
        assertEq(unlockTime, 0, "Unlock time should be cleared");
    }

    function test_invariant_redeemFollowsSameRulesAsWithdraw() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.initiateRageQuit(shares);

        // Test redeem without cooldown (should fail)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.redeem(shares, alice, alice, 0, new address[](0));

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Test redeem more than custodied (should fail)
        userDeposit(alice, defaultAmount); // Get more shares
        uint256 totalShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vault.redeem(totalShares, alice, alice, 0, new address[](0));

        // Test partial redeem (should succeed and reduce custody)
        uint256 redeemAmount = shares / 2;
        vm.prank(alice);
        uint256 assets = vault.redeem(redeemAmount, alice, alice, 0, new address[](0));
        assertTrue(assets > 0, "Should redeem assets");

        (uint256 remainingLocked, ) = getCustodyInfo(alice);
        assertEq(remainingLocked, shares - redeemAmount, "Custody should reduce by redeemed shares");

        // Test full remaining redeem clears custody
        vm.prank(alice);
        vault.redeem(remainingLocked, alice, alice, 0, new address[](0));

        (uint256 finalLocked, ) = getCustodyInfo(alice);
        assertEq(finalLocked, 0, "Custody should be cleared after full redemption");
    }

    /*//////////////////////////////////////////////////////////////
                    4. STATE TRANSITION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_initiateRageQuitSetsCorrectState() public {
        // Setup: User deposits
        userDeposit(alice, defaultAmount * 2);

        // Record time before
        uint256 timeBefore = block.timestamp;

        // Initiate rage quit with specific amount
        uint256 lockAmount = defaultAmount + 123; // Odd amount to test precision
        vm.prank(alice);
        vault.initiateRageQuit(lockAmount);

        // Verify state is set correctly
        (uint256 lockedShares, uint256 unlockTime) = getCustodyInfo(alice);
        assertEq(lockedShares, lockAmount, "Locked shares should match requested amount exactly");
        assertEq(unlockTime, timeBefore + vault.rageQuitCooldownPeriod(), "Unlock time should be correct");

        // Verify balance unchanged
        assertEq(vault.balanceOf(alice), defaultAmount * 2, "Balance should remain unchanged");
    }

    function test_invariant_cancelRageQuitClearsState() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Verify custody exists
        (uint256 lockedBefore, uint256 unlockTimeBefore) = getCustodyInfo(alice);
        assertEq(lockedBefore, defaultAmount, "Should have custody before cancel");
        assertTrue(unlockTimeBefore > 0, "Should have unlock time before cancel");

        // Cancel rage quit
        vm.prank(alice);
        vault.cancelRageQuit();

        // Verify state is completely cleared
        (uint256 lockedAfter, uint256 unlockTimeAfter) = getCustodyInfo(alice);
        assertEq(lockedAfter, 0, "Locked shares should be zero after cancel");
        assertEq(unlockTimeAfter, 0, "Unlock time should be zero after cancel");

        // Verify user can initiate new rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount / 2);

        (uint256 newLocked, ) = getCustodyInfo(alice);
        assertEq(newLocked, defaultAmount / 2, "Should be able to start new rage quit after cancel");
    }

    function test_invariant_depositsDoNotAffectExistingCustody() public {
        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Record custody state
        (uint256 lockedBefore, uint256 unlockTimeBefore) = getCustodyInfo(alice);

        // Make multiple deposits
        userDeposit(alice, defaultAmount / 2);
        userDeposit(alice, defaultAmount);
        userDeposit(alice, defaultAmount * 3);

        // Verify custody unchanged
        (uint256 lockedAfter, uint256 unlockTimeAfter) = getCustodyInfo(alice);
        assertEq(lockedAfter, lockedBefore, "Custody amount should not change with deposits");
        assertEq(unlockTimeAfter, unlockTimeBefore, "Unlock time should not change with deposits");

        // Verify user now has more balance but same custody
        uint256 totalBalance = vault.balanceOf(alice);
        assertGt(totalBalance, lockedAfter, "Balance should be greater than custody");
        assertEq(
            totalBalance,
            defaultAmount + defaultAmount / 2 + defaultAmount + defaultAmount * 3,
            "Balance should match all deposits"
        );
    }

    function test_invariant_mintingDoesNotCreateCustody() public {
        // This test verifies that balance changes through means other than deposits
        // don't affect custody state

        // Setup: Users deposit
        userDeposit(alice, defaultAmount);
        userDeposit(bob, defaultAmount);

        // Alice initiates rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount / 2);

        (uint256 aliceLockedBefore, ) = getCustodyInfo(alice);
        (uint256 bobLockedBefore, ) = getCustodyInfo(bob);
        uint256 aliceBalanceBefore = vault.balanceOf(alice);

        // Bob transfers shares to Alice (increasing Alice's balance without deposit)
        vm.prank(bob);
        vault.transfer(alice, defaultAmount / 4);

        // Charlie deposits and transfers to Alice
        userDeposit(charlie, defaultAmount);
        vm.prank(charlie);
        vault.transfer(alice, defaultAmount / 2);

        // Check custody states remain unchanged despite balance increases
        (uint256 aliceLockedAfter, ) = getCustodyInfo(alice);
        (uint256 bobLockedAfter, ) = getCustodyInfo(bob);
        uint256 aliceBalanceAfter = vault.balanceOf(alice);

        assertEq(aliceLockedAfter, aliceLockedBefore, "Alice's custody should not change from transfers");
        assertEq(bobLockedAfter, bobLockedBefore, "Bob's custody should not change from transfers");
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice's balance should have increased");
        assertEq(aliceLockedAfter, defaultAmount / 2, "Alice's custody should remain at original amount");
    }

    /*//////////////////////////////////////////////////////////////
                    5. BYPASS PREVENTION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_cannotBypassViaTransferBeforeWithdraw() public {
        // Setup: Alice deposits and initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Alice tries to transfer locked shares to Bob to bypass cooldown
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        vault.transfer(bob, defaultAmount);

        // Even if Bob had pre-existing balance, he can't withdraw Alice's locked shares
        userDeposit(bob, defaultAmount);

        // Bob cannot withdraw without his own rage quit
        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.withdraw(defaultAmount, bob, bob, 0, new address[](0));

        // Bob initiates his own rage quit
        vm.prank(bob);
        vault.initiateRageQuit(defaultAmount);

        // Bob still has to wait his own cooldown
        vm.prank(bob);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(defaultAmount, bob, bob, 0, new address[](0));

        // Fast forward Bob's cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Bob can only withdraw his own locked amount
        vm.prank(bob);
        uint256 withdrawn = vault.withdraw(defaultAmount, bob, bob, 0, new address[](0));
        assertEq(withdrawn, defaultAmount, "Bob can only withdraw his own locked shares");

        // Alice still has her locked shares
        (uint256 aliceLocked, ) = getCustodyInfo(alice);
        assertEq(aliceLocked, defaultAmount, "Alice's custody remains unchanged");
    }

    function test_invariant_cannotBypassViaMultipleAccounts() public {
        // Setup: Alice deposits and tries to split across accounts to bypass
        userDeposit(alice, defaultAmount * 3);

        // Alice initiates rage quit for part of her shares
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount * 2);

        // Alice creates helper accounts and transfers unlocked shares
        address alice2 = address(0x1234);
        address alice3 = address(0x5678);

        vm.prank(alice);
        vault.transfer(alice2, defaultAmount / 2);
        vm.prank(alice);
        vault.transfer(alice3, defaultAmount / 2);

        // Helper accounts cannot withdraw Alice's locked shares
        vm.prank(alice2);
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.withdraw(defaultAmount / 2, alice2, alice2, 0, new address[](0));

        // Even if helper accounts initiate their own rage quit
        vm.prank(alice2);
        vault.initiateRageQuit(defaultAmount / 2);

        // They still need to wait their own cooldown
        vm.prank(alice2);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(defaultAmount / 2, alice2, alice2, 0, new address[](0));

        // Alice's original locked shares remain locked to her
        (uint256 aliceLocked, ) = getCustodyInfo(alice);
        assertEq(aliceLocked, defaultAmount * 2, "Alice's locked shares unchanged");
    }

    function test_invariant_cannotInitiateAfterDeposit() public {
        // initiating rage quit before depositing
        // Now users must specify shares to lock at initiation

        // Alice has no shares
        assertEq(vault.balanceOf(alice), 0, "Alice starts with no shares");

        // Alice cannot initiate rage quit with shares she doesn't have
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InsufficientBalance.selector);
        vault.initiateRageQuit(defaultAmount);

        // Even with 0 amount
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InvalidShareAmount.selector);
        vault.initiateRageQuit(0);

        // Alice deposits
        userDeposit(alice, defaultAmount);

        // Now Alice can initiate rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // But she still must wait the cooldown
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));
    }

    function test_invariant_partialWithdrawalMaintainsLock() public {
        // This test verifies that after partial withdrawal, the remaining
        // custodied shares still require the original unlock window

        // Setup: User deposits and initiates rage quit
        userDeposit(alice, defaultAmount * 2);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount * 2);

        // Fast forward past cooldown
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Partial withdrawal - withdrawing assets, not shares
        // withdraw() takes assets as first param, returns shares
        vm.prank(alice);
        uint256 sharesWithdrawn = vault.withdraw(defaultAmount / 2, alice, alice, 0, new address[](0));

        // Check custody was reduced by shares withdrawn
        (uint256 remainingLocked, ) = getCustodyInfo(alice);
        assertEq(remainingLocked, defaultAmount * 2 - sharesWithdrawn, "Custody should reduce by shares withdrawn");

        // User balance also reduced
        uint256 aliceBalance = vault.balanceOf(alice);
        assertEq(aliceBalance, defaultAmount * 2 - sharesWithdrawn, "Balance should reduce by shares withdrawn");

        // Can continue withdrawing remaining custodied shares
        vm.prank(alice);
        uint256 secondWithdraw = vault.withdraw(remainingLocked, alice, alice, 0, new address[](0));
        assertEq(secondWithdraw, remainingLocked, "Should withdraw all remaining custodied shares");

        // Now custody should be cleared
        (uint256 clearedLocked, ) = getCustodyInfo(alice);
        assertEq(clearedLocked, 0, "Custody should be cleared after full withdrawal");

        // And user has no more shares
        assertEq(vault.balanceOf(alice), 0, "User should have no shares left");
    }

    /*//////////////////////////////////////////////////////////////
                        6. EDGE CASE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_zeroShareRageQuitReverts() public {
        // Setup: User deposits
        userDeposit(alice, defaultAmount);

        // Try to initiate rage quit with 0 shares
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InvalidShareAmount.selector);
        vault.initiateRageQuit(0);

        // Verify no custody was created
        (uint256 locked, ) = getCustodyInfo(alice);
        assertEq(locked, 0, "No custody should be created");
    }

    function test_invariant_insufficientBalanceRageQuitReverts() public {
        // Setup: User deposits some amount
        userDeposit(alice, defaultAmount);

        // Try to initiate rage quit with more shares than balance
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InsufficientBalance.selector);
        vault.initiateRageQuit(defaultAmount + 1);

        // Try with significantly more
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.InsufficientBalance.selector);
        vault.initiateRageQuit(defaultAmount * 10);

        // Verify no custody was created
        (uint256 locked, ) = getCustodyInfo(alice);
        assertEq(locked, 0, "No custody should be created");
    }

    function test_invariant_cancelWithoutActiveRageQuitReverts() public {
        // Setup: User with no active rage quit
        userDeposit(alice, defaultAmount);

        // Try to cancel non-existent rage quit
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.NoActiveRageQuit.selector);
        vault.cancelRageQuit();

        // Even after initiating and completing a rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Fast forward and withdraw all
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);
        vm.prank(alice);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Still cannot cancel (custody already cleared)
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.NoActiveRageQuit.selector);
        vault.cancelRageQuit();
    }

    function test_invariant_redeemFollowsSameRulesAsWithdraw_EdgeCases() public {
        // Setup: User deposits
        userDeposit(alice, defaultAmount);
        uint256 shares = vault.balanceOf(alice);

        // Test 1: Cannot redeem without custody
        vm.prank(alice);
        vm.expectRevert(IMultistrategyLockedVault.NoCustodiedShares.selector);
        vault.redeem(shares, alice, alice, 0, new address[](0));

        // Test 2: Initiate rage quit and test edge cases
        vm.prank(alice);
        vault.initiateRageQuit(shares);
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);

        // Redeeming 0 shares might revert with NoSharesToRedeem
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(0, alice, alice, 0, new address[](0));

        // Custody unchanged after failed redeem
        (uint256 locked, ) = getCustodyInfo(alice);
        assertEq(locked, shares, "Custody should remain unchanged");

        // Test 3: Redeem exactly 1 wei of shares
        vm.prank(alice);
        uint256 oneWeiAssets = vault.redeem(1, alice, alice, 0, new address[](0));
        assertTrue(oneWeiAssets >= 0, "Should be able to redeem 1 wei of shares");

        (uint256 lockedAfter, ) = getCustodyInfo(alice);
        assertEq(lockedAfter, shares - 1, "Custody should reduce by 1");
    }

    function test_invariant_extremeAmounts() public {
        // Test with very large amounts
        uint256 largeAmount = type(uint256).max / 2;
        asset.mint(alice, largeAmount);

        // Cannot initiate rage quit with more than balance
        vm.prank(alice);
        asset.approve(address(vault), largeAmount);

        // Deposit max allowed by vault
        uint256 maxDeposit = vault.maxDeposit(alice);
        if (maxDeposit > 0 && maxDeposit < largeAmount) {
            vm.prank(alice);
            vault.deposit(maxDeposit, alice);

            // Can initiate rage quit with full balance
            uint256 balance = vault.balanceOf(alice);
            vm.prank(alice);
            vault.initiateRageQuit(balance);

            (uint256 locked, ) = getCustodyInfo(alice);
            assertEq(locked, balance, "Should lock entire balance");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    7. CROSS-FUNCTION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_invariant_getCustodyInfoAccuracy() public {
        // Setup: Multiple users with different custody states
        userDeposit(alice, defaultAmount * 2);
        userDeposit(bob, defaultAmount);

        // Alice initiates rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);
        uint256 aliceUnlockTime = block.timestamp + vault.rageQuitCooldownPeriod();

        // Bob has no custody
        (uint256 bobLocked, uint256 bobUnlock) = getCustodyInfo(bob);
        assertEq(bobLocked, 0, "Bob should have no locked shares");
        assertEq(bobUnlock, 0, "Bob should have no unlock time");

        // Alice has custody
        (uint256 aliceLocked, uint256 aliceUnlock) = getCustodyInfo(alice);
        assertEq(aliceLocked, defaultAmount, "Alice locked shares should match");
        assertEq(aliceUnlock, aliceUnlockTime, "Alice unlock time should match");

        // Fast forward and partial withdrawal
        vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);
        vm.prank(alice);
        uint256 withdrawn = vault.withdraw(defaultAmount / 2, alice, alice, 0, new address[](0));

        // Verify getCustodyInfo reflects the change
        (uint256 aliceLockedAfter, uint256 aliceUnlockAfter) = getCustodyInfo(alice);
        assertEq(aliceLockedAfter, defaultAmount - withdrawn, "Custody info should reflect withdrawal");
        assertEq(aliceUnlockAfter, aliceUnlockTime, "Unlock time should remain unchanged");
    }

    function test_invariant_custodyPersistsThroughTime() public {
        // Setup: User initiates rage quit
        userDeposit(alice, defaultAmount);

        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Record initial state
        (uint256 lockedInit, uint256 unlockInit) = getCustodyInfo(alice);

        // Fast forward various time periods (but before unlock)
        uint256[] memory timeJumps = new uint256[](5);
        timeJumps[0] = 1 hours;
        timeJumps[1] = 1 days;
        timeJumps[2] = 3 days;
        timeJumps[3] = vault.rageQuitCooldownPeriod() / 2;
        timeJumps[4] = vault.rageQuitCooldownPeriod() - 1;

        for (uint i = 0; i < timeJumps.length; i++) {
            vm.warp(block.timestamp + timeJumps[i]);

            (uint256 locked, uint256 unlock) = getCustodyInfo(alice);
            assertEq(locked, lockedInit, "Locked amount should not change with time");
            assertEq(unlock, unlockInit, "Unlock time should not change with time");
        }

        // Even after unlock time passes, custody persists until withdrawal
        vm.warp(unlockInit + 1 days);
        (uint256 lockedAfter, uint256 unlockAfter) = getCustodyInfo(alice);
        assertEq(lockedAfter, lockedInit, "Custody persists after unlock time");
        assertEq(unlockAfter, unlockInit, "Unlock time unchanged after passing");
    }

    function test_invariant_custodyIndependentBetweenUsers() public {
        // Setup: Multiple users
        userDeposit(alice, defaultAmount * 2);
        userDeposit(bob, defaultAmount * 3);
        userDeposit(charlie, defaultAmount);

        // Alice initiates rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount);

        // Bob initiates rage quit with different amount
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        vault.initiateRageQuit(defaultAmount * 2);

        // Charlie doesn't initiate

        // Record all states
        (uint256 aliceLocked, uint256 aliceUnlock) = getCustodyInfo(alice);
        (uint256 bobLocked, uint256 bobUnlock) = getCustodyInfo(bob);
        (uint256 charlieLocked, ) = getCustodyInfo(charlie);

        // Verify independence
        assertEq(aliceLocked, defaultAmount, "Alice custody correct");
        assertEq(bobLocked, defaultAmount * 2, "Bob custody correct");
        assertEq(charlieLocked, 0, "Charlie has no custody");
        assertTrue(bobUnlock > aliceUnlock, "Bob initiated later");

        // Alice withdraws - shouldn't affect others
        vm.warp(aliceUnlock + 1);
        vm.prank(alice);
        vault.withdraw(defaultAmount, alice, alice, 0, new address[](0));

        // Check others unchanged
        (uint256 bobLockedAfter, ) = getCustodyInfo(bob);
        (uint256 charlieLockedAfter, ) = getCustodyInfo(charlie);
        assertEq(bobLockedAfter, defaultAmount * 2, "Bob custody unchanged");
        assertEq(charlieLockedAfter, 0, "Charlie still has no custody");

        // Bob cancels - shouldn't affect others
        vm.prank(bob);
        vault.cancelRageQuit();

        (uint256 aliceLockedFinal, ) = getCustodyInfo(alice);
        assertEq(aliceLockedFinal, 0, "Alice custody remains cleared");
    }

    function test_invariant_multipleOperationsConsistency() public {
        // Complex scenario with multiple operations
        userDeposit(alice, defaultAmount * 5);

        // Operation 1: Initiate rage quit
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount * 3);

        // Operation 2: Transfer available shares
        vm.prank(alice);
        vault.transfer(bob, defaultAmount * 2);

        // Verify custody unchanged
        (uint256 locked1, ) = getCustodyInfo(alice);
        assertEq(locked1, defaultAmount * 3, "Custody unchanged after transfer");

        // Operation 3: Cancel rage quit
        vm.prank(alice);
        vault.cancelRageQuit();

        // Operation 4: New rage quit with remaining balance
        vm.prank(alice);
        vault.initiateRageQuit(defaultAmount * 3); // Still has 3x after transfer

        // Operation 5: Deposit more
        userDeposit(alice, defaultAmount * 2);

        // Verify can transfer new deposits
        vm.prank(alice);
        vault.transfer(charlie, defaultAmount * 2);

        // Final state check
        (uint256 finalLocked, ) = getCustodyInfo(alice);
        assertEq(finalLocked, defaultAmount * 3, "Custody remains at original rage quit amount");
        assertEq(vault.balanceOf(alice), defaultAmount * 3, "Balance equals locked amount");
    }
}
