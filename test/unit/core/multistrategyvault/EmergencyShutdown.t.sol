// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockDepositLimitModule } from "test/mocks/core/MockDepositLimitModule.sol";

contract EmergencyShutdownTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;
    address gov;
    address panda;

    function setUp() public {
        gov = address(this);
        panda = address(0x123);

        asset = new MockERC20(18);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        // Create and initialize the vault
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set up strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Set roles - equivalent to the fixture in the Python test
        vault.add_role(gov, IMultistrategyVault.Roles.EMERGENCY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // set max deposit limit
        vault.set_deposit_limit(type(uint256).max, false);
    }

    function testShutdown() public {
        // Test that unauthorized users can't shut down
        vm.prank(panda);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.shutdown_vault();

        // Test that authorized users can shut down
        vault.shutdown_vault();
        assertTrue(vault.isShutdown());
    }

    function testShutdownGivesDebtManagerRole() public {
        // Set panda as EMERGENCY_MANAGER only
        vault.set_role(panda, 1 << uint256(IMultistrategyVault.Roles.EMERGENCY_MANAGER));

        // Verify panda doesn't have DEBT_MANAGER initially
        assertTrue((vault.roles(panda) & (1 << uint256(IMultistrategyVault.Roles.DEBT_MANAGER))) == 0);

        // Have panda shut down the vault
        vm.prank(panda);
        vault.shutdown_vault();

        // Verify panda now has DEBT_MANAGER role
        assertTrue((vault.roles(panda) & (1 << uint256(IMultistrategyVault.Roles.DEBT_MANAGER))) != 0);

        // Also still has EMERGENCY_MANAGER role
        assertTrue((vault.roles(panda) & (1 << uint256(IMultistrategyVault.Roles.EMERGENCY_MANAGER))) != 0);
    }

    function testShutdownIncreaseDepositLimitReverts() public {
        // Deposit into vault
        mintAndDepositIntoVault(1e18);

        // Shut down vault
        vault.shutdown_vault();

        // Verify deposit limit is 0
        assertEq(vault.maxDeposit(gov), 0);

        // Try to set deposit limit
        vm.expectRevert(IMultistrategyVault.VaultShutdown.selector);
        vault.set_deposit_limit(1e18, false);

        // Verify deposit limit is still 0
        assertEq(vault.maxDeposit(gov), 0);
    }

    function testShutdownSetDepositLimitModuleReverts() public {
        // Deposit into vault
        mintAndDepositIntoVault(1e18);

        // Shut down vault
        vault.shutdown_vault();

        // Verify deposit limit is 0
        assertEq(vault.maxDeposit(gov), 0);

        // Deploy limit module
        MockDepositLimitModule limitModule = new MockDepositLimitModule();

        // Try to set deposit limit module
        vm.expectRevert(IMultistrategyVault.VaultShutdown.selector);
        vault.set_deposit_limit_module(address(limitModule), false);

        // Verify deposit limit is still 0
        assertEq(vault.maxDeposit(gov), 0);
    }

    function testShutdownDepositLimitModuleIsRemoved() public {
        // Deposit into vault
        mintAndDepositIntoVault(1e18);

        // Deploy and set limit module
        MockDepositLimitModule limitModule = new MockDepositLimitModule();
        vault.set_deposit_limit_module(address(limitModule), true);

        // Verify deposit is allowed
        assertTrue(vault.maxDeposit(gov) > 0);

        // Shut down vault
        vault.shutdown_vault();

        // Verify deposit limit module is removed
        assertEq(vault.depositLimitModule(), address(0));

        // Verify deposit limit is 0
        assertEq(vault.maxDeposit(gov), 0);
    }

    function testShutdownCantDepositCanWithdraw() public {
        // Deposit into vault - this gives shares to gov, not to the vault
        uint256 depositAmount = 1e18;
        mintAndDepositIntoVault(depositAmount);

        // Shut down vault
        vault.shutdown_vault();

        // Verify no more deposits allowed
        assertEq(vault.maxDeposit(gov), 0);

        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));

        // Try to deposit will fail at maxDeposit check
        asset.mint(address(this), depositAmount);
        asset.approve(address(vault), depositAmount);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(depositAmount, gov);

        // Vault balance unchanged
        assertEq(asset.balanceOf(address(vault)), vaultBalanceBefore);

        // But withdrawals still work - we need to use gov's shares, not the vault's
        uint256 govBalanceBefore = asset.balanceOf(gov);

        // Withdraw using gov's balance, since that's who we deposited for
        vm.prank(gov); // Need to be gov to withdraw gov's shares
        vault.withdraw(vault.balanceOf(gov), gov, gov, 0, new address[](0));

        // Gov received funds
        assertEq(asset.balanceOf(gov), govBalanceBefore + vaultBalanceBefore);

        // Vault is empty
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testStrategyReturnFunds() public {
        // Deposit into vault
        uint256 depositAmount = 1e18;
        mintAndDepositIntoVault(depositAmount);

        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertGt(vaultBalance, 0);

        // Add strategy to vault and allocate all funds to it
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        addDebtToStrategy(address(strategy), vaultBalance);

        // Verify funds were allocated
        assertEq(asset.balanceOf(address(strategy)), vaultBalance);
        assertEq(asset.balanceOf(address(vault)), 0);

        // Shut down vault
        vault.shutdown_vault();

        // Verify no more deposits allowed
        assertEq(vault.maxDeposit(gov), 0);

        // Return funds from strategy
        vault.update_debt(address(strategy), 0, 0);

        // Verify funds returned
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(vault)), vaultBalance);
    }

    // Helper functions

    function mintAndDepositIntoVault(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, gov);
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        vault.update_debt(strategyAddress, amount, 0);
    }
}
