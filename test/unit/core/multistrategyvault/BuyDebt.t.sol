// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";

contract BuyDebtTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;
    address gov;
    address fish;
    uint256 fishAmount = 1e18;

    function setUp() public {
        gov = address(this);
        fish = address(0x123);

        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set up strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Set roles - equivalent to the fixture in the Python test
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_PURCHASER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // set max deposit limit
        vault.set_deposit_limit(type(uint256).max, false);
    }

    function testBuyDebtStrategyNotActiveReverts() public {
        // Create a strategy that's not active in the vault
        MockYieldStrategy inactiveStrategy = new MockYieldStrategy(address(asset), address(vault));

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Approve vault to pull funds
        asset.mint(gov, fishAmount);
        asset.approve(address(vault), fishAmount);

        // Try to buy debt - should revert because strategy not active
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.buy_debt(address(inactiveStrategy), fishAmount);
    }

    function testBuyDebtNoDebtReverts() public {
        // Add strategy to vault but don't allocate any debt
        vault.add_strategy(address(strategy), false);

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Approve vault to pull funds
        asset.mint(gov, fishAmount);
        asset.approve(address(vault), fishAmount);

        // Try to buy debt - should revert because strategy has no debt
        vm.expectRevert(IMultistrategyVault.NothingToBuy.selector);
        vault.buy_debt(address(strategy), fishAmount);
    }

    function testBuyDebtNoAmountReverts() public {
        // Add strategy to vault
        vault.add_strategy(address(strategy), false);

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Add debt to strategy
        addDebtToStrategy(address(strategy), fishAmount);

        // Approve vault to pull funds
        asset.mint(gov, fishAmount);
        asset.approve(address(vault), fishAmount);

        // Try to buy 0 debt - should revert
        vm.expectRevert(IMultistrategyVault.NothingToBuyWith.selector);
        vault.buy_debt(address(strategy), 0);
    }

    function testBuyDebtMoreThanAvailableWithdrawsCurrentDebt() public {
        // Add strategy to vault
        vault.add_strategy(address(strategy), false);

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Add debt to strategy
        addDebtToStrategy(address(strategy), fishAmount);

        // Approve vault to pull funds
        asset.mint(gov, fishAmount);
        asset.approve(address(vault), fishAmount);

        uint256 beforeBalance = asset.balanceOf(gov);
        uint256 beforeShares = strategy.balanceOf(gov);

        // Try to buy more debt than available
        vm.expectEmit(true, true, false, true);
        emit IMultistrategyVault.DebtPurchased(address(strategy), fishAmount);
        vault.buy_debt(address(strategy), fishAmount * 2);

        // Check results
        assertEq(vault.totalIdle(), fishAmount);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals());

        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, 0);

        // Check gov balance and shares
        assertEq(asset.balanceOf(gov), beforeBalance - fishAmount);
        assertEq(strategy.balanceOf(gov), beforeShares + fishAmount);
    }

    function testBuyDebtFullDebt() public {
        // Add strategy to vault
        vault.add_strategy(address(strategy), false);

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Add debt to strategy
        addDebtToStrategy(address(strategy), fishAmount);

        // Approve vault to pull funds
        asset.mint(gov, fishAmount);
        asset.approve(address(vault), fishAmount);

        uint256 beforeBalance = asset.balanceOf(gov);
        uint256 beforeShares = strategy.balanceOf(gov);

        // Expect DebtUpdated event first
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtUpdated(address(strategy), fishAmount, 0);

        // Then expect DebtPurchased event
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtPurchased(address(strategy), fishAmount);

        vault.buy_debt(address(strategy), fishAmount);

        // Check results
        assertEq(vault.totalIdle(), fishAmount);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals());

        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, 0);

        // Check gov balance and shares
        assertEq(asset.balanceOf(gov), beforeBalance - fishAmount);
        assertEq(strategy.balanceOf(gov), beforeShares + fishAmount);
    }

    function testBuyDebtHalfDebt() public {
        // Add strategy to vault
        vault.add_strategy(address(strategy), false);

        // Deposit into vault
        mintAndDepositIntoVault(fish, fishAmount);

        // Add debt to strategy
        addDebtToStrategy(address(strategy), fishAmount);

        // We'll buy half the debt
        uint256 toBuy = fishAmount / 2;

        // Approve vault to pull funds
        asset.mint(gov, toBuy);
        asset.approve(address(vault), toBuy);

        uint256 beforeBalance = asset.balanceOf(gov);
        uint256 beforeShares = strategy.balanceOf(gov);

        // Buy half debt
        vm.expectEmit(true, true, false, true);
        emit IMultistrategyVault.DebtPurchased(address(strategy), toBuy);
        vault.buy_debt(address(strategy), toBuy);

        // Check results
        assertEq(vault.totalIdle(), toBuy);
        assertEq(vault.totalDebt(), fishAmount - toBuy);
        assertEq(vault.pricePerShare(), 10 ** asset.decimals());

        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, fishAmount - toBuy);

        // Check gov balance and shares
        assertEq(asset.balanceOf(gov), beforeBalance - toBuy);
        assertEq(strategy.balanceOf(gov), beforeShares + toBuy);
    }

    // Helper functions

    function mintAndDepositIntoVault(address receiver, uint256 amount) internal {
        asset.mint(receiver, amount);
        vm.startPrank(receiver);
        asset.approve(address(vault), amount);
        vault.deposit(amount, receiver);
        vm.stopPrank();
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        // First set max debt
        vault.update_max_debt_for_strategy(strategyAddress, type(uint256).max);
        // Then update debt
        vault.update_debt(strategyAddress, amount, 0);
    }

    function createStrategy() internal returns (MockYieldStrategy) {
        return new MockYieldStrategy(address(asset), address(vault));
    }
}
