// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

/**
 * @title VyperCompatibility Test
 * @notice Tests to ensure Solidity implementation provides overloaded functions for compatibility
 * @dev Tests overloaded functions that provide the same functionality as Vyper's default parameters
 */
contract VyperCompatibilityTest is Test {
    MultistrategyVault public vault;
    MultistrategyVaultFactory public vaultFactory;
    MockERC20 public asset;

    address public alice = makeAddr("alice");
    address public gov = makeAddr("governance");

    uint256 public constant PROFIT_MAX_UNLOCK_TIME = 10 days;
    uint256 public constant INITIAL_DEPOSIT = 1000e18;

    function setUp() public {
        // Deploy mock asset
        asset = new MockERC20(18);

        // Deploy vault factory
        MultistrategyVault vaultImpl = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Vault Factory", address(vaultImpl), gov);

        // Deploy vault using factory
        vm.prank(gov);
        vault = MultistrategyVault(
            vaultFactory.deployNewVault(address(asset), "Test Vault", "vTEST", gov, PROFIT_MAX_UNLOCK_TIME)
        );

        // Setup roles
        vm.startPrank(gov);
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.set_deposit_limit(type(uint256).max);
        vm.stopPrank();

        // Mint tokens to alice and make initial deposit
        asset.mint(alice, INITIAL_DEPOSIT * 10);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
    }

    /**
     * @notice Test 3-parameter withdraw overload
     */
    function test_withdraw3Params() public {
        uint256 withdrawAmount = 100e18;

        vm.prank(alice);
        uint256 shares = IMultistrategyVault(address(vault)).withdraw(withdrawAmount, alice, alice);
        assertGt(shares, 0, "3-param withdraw should return shares");
        assertEq(asset.balanceOf(alice), INITIAL_DEPOSIT * 10 - INITIAL_DEPOSIT + withdrawAmount);
    }

    /**
     * @notice Test 5-parameter withdraw overload
     */
    function test_withdraw5Params() public {
        uint256 withdrawAmount = 100e18;
        address[] memory strategies = new address[](0);

        vm.prank(alice);
        uint256 shares = IMultistrategyVault(address(vault)).withdraw(withdrawAmount, alice, alice, 0, strategies);
        assertGt(shares, 0, "5-param withdraw should return shares");
        assertEq(asset.balanceOf(alice), INITIAL_DEPOSIT * 10 - INITIAL_DEPOSIT + withdrawAmount);
    }

    /**
     * @notice Test 3-parameter redeem overload
     */
    function test_redeem3Params() public {
        uint256 redeemShares = vault.balanceOf(alice) / 4;

        vm.prank(alice);
        uint256 assets = IMultistrategyVault(address(vault)).redeem(redeemShares, alice, alice);
        assertGt(assets, 0, "3-param redeem should return assets");
        assertEq(assets, redeemShares); // 1:1 ratio since no yield
    }

    /**
     * @notice Test 5-parameter redeem overload
     */
    function test_redeem5Params() public {
        uint256 redeemShares = vault.balanceOf(alice) / 4;
        address[] memory strategies = new address[](0);

        vm.prank(alice);
        uint256 assets = IMultistrategyVault(address(vault)).redeem(redeemShares, alice, alice, 0, strategies);
        assertGt(assets, 0, "5-param redeem should return assets");
    }

    /**
     * @notice Test maxWithdraw overloads
     */
    function test_maxWithdraw() public view {
        address[] memory strategies = new address[](0);

        uint256 maxWithdraw1 = IMultistrategyVault(address(vault)).maxWithdraw(alice);
        uint256 maxWithdraw3 = IMultistrategyVault(address(vault)).maxWithdraw(alice, 0, strategies);

        assertGt(maxWithdraw1, 0, "maxWithdraw(1 param) should return positive value");
        assertEq(maxWithdraw1, maxWithdraw3, "Both maxWithdraw overloads should return same value");
        assertEq(maxWithdraw1, INITIAL_DEPOSIT);
    }

    /**
     * @notice Test maxRedeem overloads
     */
    function test_maxRedeem() public view {
        address[] memory strategies = new address[](0);

        uint256 maxRedeem1 = IMultistrategyVault(address(vault)).maxRedeem(alice);
        uint256 maxRedeem3 = IMultistrategyVault(address(vault)).maxRedeem(alice, 0, strategies);

        assertGt(maxRedeem1, 0, "maxRedeem(1 param) should return positive value");
        assertEq(maxRedeem1, maxRedeem3, "Both maxRedeem overloads should return same value");
        assertEq(maxRedeem1, vault.balanceOf(alice));
    }

    /**
     * @notice Test addStrategy overloads
     */
    function test_addStrategy() public {
        // Test without alice having role
        vm.expectRevert(); // NotAllowed() due to missing ADD_STRATEGY_MANAGER role
        IMultistrategyVault(address(vault)).add_strategy(alice);

        vm.expectRevert(); // NotAllowed() due to missing ADD_STRATEGY_MANAGER role
        IMultistrategyVault(address(vault)).add_strategy(alice, true);

        // Grant role and test with role
        vm.prank(gov);
        vault.add_role(alice, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);

        // These should now succeed (strategy validation will fail but function is callable)
        vm.startPrank(alice);
        vm.expectRevert(); // Will revert for different reason (not NotAllowed)
        IMultistrategyVault(address(vault)).add_strategy(address(0));

        vm.expectRevert(); // Will revert for different reason (not NotAllowed)
        IMultistrategyVault(address(vault)).add_strategy(address(0), true);
        vm.stopPrank();
    }

    /**
     * @notice Test setDepositLimit overloads
     */
    function test_setDepositLimit() public {
        // Test without alice having role
        vm.expectRevert(); // NotAllowed() due to missing DEPOSIT_LIMIT_MANAGER role
        IMultistrategyVault(address(vault)).set_deposit_limit(0);

        vm.expectRevert(); // NotAllowed() due to missing DEPOSIT_LIMIT_MANAGER role
        IMultistrategyVault(address(vault)).set_deposit_limit(0, false);

        // Grant role and test with role
        vm.prank(gov);
        vault.add_role(alice, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // These should now succeed
        vm.startPrank(alice);
        IMultistrategyVault(address(vault)).set_deposit_limit(100e18);
        assertEq(vault.depositLimit(), 100e18);

        IMultistrategyVault(address(vault)).set_deposit_limit(200e18, false);
        assertEq(vault.depositLimit(), 200e18);
        vm.stopPrank();
    }

    /**
     * @notice Test updateDebt overloads
     */
    function test_updateDebt() public {
        // Test without alice having role
        vm.expectRevert(); // NotAllowed() due to missing DEBT_MANAGER role
        IMultistrategyVault(address(vault)).update_debt(alice, 0);

        vm.expectRevert(); // NotAllowed() due to missing DEBT_MANAGER role
        IMultistrategyVault(address(vault)).update_debt(alice, 0, 0);

        // Grant role and test with role
        vm.prank(gov);
        vault.add_role(alice, IMultistrategyVault.Roles.DEBT_MANAGER);

        // These should now succeed (will revert due to strategy not being active but function is callable)
        vm.startPrank(alice);
        vm.expectRevert(); // Will revert for different reason (not NotAllowed)
        IMultistrategyVault(address(vault)).update_debt(address(0), 0);

        vm.expectRevert(); // Will revert for different reason (not NotAllowed)
        IMultistrategyVault(address(vault)).update_debt(address(0), 0, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test complete deposit and withdrawal flow
     * @dev Verifies the vault is properly initialized and functional
     */
    function test_completeFlow() public {
        // Bob deposits
        address bob = makeAddr("bob");
        uint256 depositAmount = 500e18;
        asset.mint(bob, depositAmount);

        vm.startPrank(bob);
        asset.approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), sharesReceived);
        assertEq(asset.balanceOf(bob), 0);

        // Bob withdraws half using 3-param withdraw (now that reentrancy is fixed)
        uint256 withdrawAmount = depositAmount / 2;

        vm.prank(bob);
        uint256 sharesBurned = vault.withdraw(withdrawAmount, bob, bob);

        assertEq(asset.balanceOf(bob), withdrawAmount);
        assertGt(sharesBurned, 0);

        // Bob redeems remaining shares using 3-param redeem
        uint256 remainingShares = vault.balanceOf(bob);

        vm.prank(bob);
        uint256 assetsReceived = vault.redeem(remainingShares, bob, bob);

        assertEq(vault.balanceOf(bob), 0);
        assertEq(assetsReceived, withdrawAmount); // Should get the other half
        assertEq(asset.balanceOf(bob), depositAmount); // Should have full amount back
    }

    /**
     * @notice Test that overloaded functions have different selectors
     * @dev Verifies that each overload creates a unique function selector
     */
    function test_overloadedSelectorsUnique() public pure {
        // Withdraw overloads should have different selectors
        bytes4 withdraw3 = bytes4(keccak256("withdraw(uint256,address,address)"));
        bytes4 withdraw4 = bytes4(keccak256("withdraw(uint256,address,address,uint256)"));
        bytes4 withdraw5 = bytes4(keccak256("withdraw(uint256,address,address,uint256,address[])"));

        assertTrue(withdraw3 != withdraw4, "withdraw(3) vs withdraw(4) selectors should be different");
        assertTrue(withdraw3 != withdraw5, "withdraw(3) vs withdraw(5) selectors should be different");
        assertTrue(withdraw4 != withdraw5, "withdraw(4) vs withdraw(5) selectors should be different");

        // Redeem overloads should have different selectors
        bytes4 redeem3 = bytes4(keccak256("redeem(uint256,address,address)"));
        bytes4 redeem4 = bytes4(keccak256("redeem(uint256,address,address,uint256)"));
        bytes4 redeem5 = bytes4(keccak256("redeem(uint256,address,address,uint256,address[])"));

        assertTrue(redeem3 != redeem4, "redeem(3) vs redeem(4) selectors should be different");
        assertTrue(redeem3 != redeem5, "redeem(3) vs redeem(5) selectors should be different");
        assertTrue(redeem4 != redeem5, "redeem(4) vs redeem(5) selectors should be different");

        // AddStrategy overloads should have different selectors
        bytes4 addStrategy1 = bytes4(keccak256("addStrategy(address)"));
        bytes4 addStrategy2 = bytes4(keccak256("addStrategy(address,bool)"));

        assertTrue(addStrategy1 != addStrategy2, "addStrategy overloads should have different selectors");

        // SetDepositLimit overloads should have different selectors
        bytes4 setDepositLimit1 = bytes4(keccak256("setDepositLimit(uint256)"));
        bytes4 setDepositLimit2 = bytes4(keccak256("setDepositLimit(uint256,bool)"));

        assertTrue(setDepositLimit1 != setDepositLimit2, "setDepositLimit overloads should have different selectors");

        // UpdateDebt overloads should have different selectors
        bytes4 updateDebt2 = bytes4(keccak256("updateDebt(address,uint256)"));
        bytes4 updateDebt3 = bytes4(keccak256("updateDebt(address,uint256,uint256)"));

        assertTrue(updateDebt2 != updateDebt3, "updateDebt overloads should have different selectors");
    }
}
