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

/**
 * @title LockedVaultMaxWithdrawRedeemTest
 * @notice Tests for maxWithdraw/maxRedeem custody constraints in MultistrategyLockedVault
 * @dev Verifies that maxWithdraw/maxRedeem properly respect custody status and constraints
 */
contract LockedVaultMaxWithdrawRedeemTest is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyLockedVault vault;
    MockERC20 public asset;
    MockFactory public factory;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public alice = address(0x2);
    address public feeRecipient = address(0x3);

    uint256 public depositAmount = 10_000e18;
    uint256 public defaultProfitMaxUnlockTime = 7 days;
    uint256 public defaultRageQuitCooldown = 7 days;

    address[] public emptyStrategies = new address[](0);

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(alice, depositAmount);

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

        // Set deposit limit (as governance)
        vm.startPrank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.setDepositLimit(type(uint256).max, true);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    /**
     * @notice Test that maxWithdraw returns 0 when user has no custody
     */
    function test_maxWithdraw_returns_zero_without_custody() public view {
        // Alice has shares but no custody
        uint256 maxAssets = vault.maxWithdraw(alice, 0, emptyStrategies);

        // Should return 0 since no rage quit initiated
        assertEq(maxAssets, 0, "maxWithdraw should return 0 without custody");
    }

    /**
     * @notice Test that maxRedeem returns 0 when user has no custody
     */
    function test_maxRedeem_returns_zero_without_custody() public view {
        // Alice has shares but no custody
        uint256 maxShares = vault.maxRedeem(alice, 0, emptyStrategies);

        // Should return 0 since no rage quit initiated
        assertEq(maxShares, 0, "maxRedeem should return 0 without custody");
    }

    /**
     * @notice Test that maxWithdraw returns 0 during cooldown period
     */
    function test_maxWithdraw_returns_zero_during_cooldown() public {
        // Alice initiates rage quit for half her shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rageQuitShares = aliceShares / 2;

        vm.prank(alice);
        vault.initiateRageQuit(rageQuitShares);

        // Check maxWithdraw during cooldown
        uint256 maxAssets = vault.maxWithdraw(alice, 0, emptyStrategies);

        // Should return 0 since still in cooldown
        assertEq(maxAssets, 0, "maxWithdraw should return 0 during cooldown");
    }

    /**
     * @notice Test that maxRedeem returns 0 during cooldown period
     */
    function test_maxRedeem_returns_zero_during_cooldown() public {
        // Alice initiates rage quit for half her shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rageQuitShares = aliceShares / 2;

        vm.prank(alice);
        vault.initiateRageQuit(rageQuitShares);

        // Check maxRedeem during cooldown
        uint256 maxShares = vault.maxRedeem(alice, 0, emptyStrategies);

        // Should return 0 since still in cooldown
        assertEq(maxShares, 0, "maxRedeem should return 0 during cooldown");
    }

    /**
     * @notice Test that maxWithdraw returns custodied amount after cooldown
     */
    function test_maxWithdraw_returns_custody_amount_after_cooldown() public {
        // Alice initiates rage quit for half her shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rageQuitShares = aliceShares / 2;

        vm.prank(alice);
        vault.initiateRageQuit(rageQuitShares);

        // Fast forward past cooldown
        vm.warp(block.timestamp + defaultRageQuitCooldown + 1);

        // Check maxWithdraw after cooldown
        uint256 maxAssets = vault.maxWithdraw(alice, 0, emptyStrategies);
        uint256 expectedAssets = vault.convertToAssets(rageQuitShares);

        // Should return custodied amount in asset terms
        assertEq(maxAssets, expectedAssets, "maxWithdraw should return custodied amount");
    }

    /**
     * @notice Test that maxRedeem returns custodied shares after cooldown
     */
    function test_maxRedeem_returns_custody_shares_after_cooldown() public {
        // Alice initiates rage quit for half her shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rageQuitShares = aliceShares / 2;

        vm.prank(alice);
        vault.initiateRageQuit(rageQuitShares);

        // Fast forward past cooldown
        vm.warp(block.timestamp + defaultRageQuitCooldown + 1);

        // Check maxRedeem after cooldown
        uint256 maxShares = vault.maxRedeem(alice, 0, emptyStrategies);

        // Should return custodied shares
        assertEq(maxShares, rageQuitShares, "maxRedeem should return custodied shares");
    }

    /**
     * @notice Test that withdraw/redeem respect the max values
     */
    function test_withdraw_redeem_respect_max_values() public {
        // Alice initiates rage quit for half her shares
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 rageQuitShares = aliceShares / 2;

        vm.prank(alice);
        vault.initiateRageQuit(rageQuitShares);

        // Try to withdraw before cooldown - should fail
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        vm.prank(alice);
        vault.withdraw(1, alice, alice, 0, emptyStrategies);

        // Fast forward past cooldown
        vm.warp(block.timestamp + defaultRageQuitCooldown + 1);

        // Get max values
        uint256 maxAssets = vault.maxWithdraw(alice, 0, emptyStrategies);
        uint256 maxShares = vault.maxRedeem(alice, 0, emptyStrategies);

        // Try to withdraw more than max - should fail
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vm.prank(alice);
        vault.withdraw(maxAssets + 1, alice, alice, 0, emptyStrategies);

        // Try to redeem more than max - should fail
        vm.expectRevert(IMultistrategyLockedVault.ExceedsCustodiedAmount.selector);
        vm.prank(alice);
        vault.redeem(maxShares + 1, alice, alice, 0, emptyStrategies);

        // Withdraw exactly max - should succeed
        vm.prank(alice);
        uint256 sharesWithdrawn = vault.withdraw(maxAssets, alice, alice, 0, emptyStrategies);
        assertEq(sharesWithdrawn, rageQuitShares, "Should withdraw custodied shares");
    }
}
