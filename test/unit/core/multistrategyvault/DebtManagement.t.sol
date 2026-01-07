// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockLockedStrategy } from "test/mocks/core/MockLockedStrategy.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";
import { MockFaultyStrategy } from "test/mocks/core/MockFaultyStrategy.sol";

contract DebtManagementTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MockLockedStrategy lockedStrategy;
    MockYieldStrategy lossyStrategy;
    MultistrategyVaultFactory vaultFactory;
    address gov;
    address bunny;
    uint256 constant DAY = 86400;
    uint256 constant MAX_BPS = 10_000;

    function setUp() public {
        gov = address(this);
        bunny = address(0x123);

        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set up strategies
        strategy = new MockYieldStrategy(address(asset), address(vault));
        lockedStrategy = new MockLockedStrategy(address(asset), address(vault));
        lossyStrategy = new MockYieldStrategy(address(asset), address(vault));

        // Set roles
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // set max deposit limit
        vault.set_deposit_limit(type(uint256).max, false);

        // Add strategies to vault
        vault.add_strategy(address(strategy), true);
        vault.add_strategy(address(lockedStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);

        // Seed vault with funds - 1 ETH + 0.5 ETH
        seedVaultWithFunds(1e18, 5e17);
    }

    function testUpdateMaxDebtWithDebtValue(uint256 maxDebt) public {
        // Bound to reasonable values
        maxDebt = bound(maxDebt, 0, 10 ** 22);

        // Update max debt for strategy
        vault.update_max_debt_for_strategy(address(strategy), maxDebt);

        // Check max debt was updated
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.maxDebt, maxDebt);
    }

    function testUpdateMaxDebtWithInactiveStrategyReverts() public {
        // Create a strategy that's not added to the vault
        MockYieldStrategy inactiveStrategy = new MockYieldStrategy(address(asset), address(vault));
        uint256 maxDebt = 1e18;

        // Try to update max debt - should revert
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.update_max_debt_for_strategy(address(inactiveStrategy), maxDebt);
    }

    function testUpdateDebtWithoutPermissionReverts() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance / 2;

        // Set max debt for strategy
        vault.update_max_debt_for_strategy(address(strategy), newDebt);

        // Try to update debt as bunny - should revert
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.update_debt(address(strategy), newDebt, 0);
    }

    function testUpdateDebtWithStrategyMaxDebtLessThanNewDebt() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance / 2;

        // Set max debt for strategy
        vault.update_max_debt_for_strategy(address(strategy), newDebt);

        // Try to update debt to more than max debt
        uint256 returnValue = vault.update_debt(address(strategy), newDebt + 10, 0);

        // Should be capped at max debt
        assertEq(returnValue, newDebt);

        // Check strategy state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, newDebt);

        // Check balances
        assertEq(asset.balanceOf(address(strategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - newDebt);

        // Check vault accounting
        assertEq(vault.totalIdle(), vaultBalance - newDebt);
        assertEq(vault.totalDebt(), newDebt);
    }

    function testUpdateDebtWithCurrentDebtLessThanNewDebt() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance / 2;

        // Get initial state
        IMultistrategyVault.StrategyParams memory initialParams = vault.strategies(address(strategy));
        uint256 currentDebt = initialParams.currentDebt;
        uint256 difference = newDebt - currentDebt;
        uint256 initialIdle = vault.totalIdle();
        uint256 initialDebt = vault.totalDebt();

        // Set max debt for strategy
        vault.update_max_debt_for_strategy(address(strategy), newDebt);

        // Update debt to new value
        vault.update_debt(address(strategy), newDebt, 0);

        // Check strategy state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, newDebt);

        // Check balances
        assertEq(asset.balanceOf(address(strategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - newDebt);

        // Check vault accounting
        assertEq(vault.totalIdle(), initialIdle - difference);
        assertEq(vault.totalDebt(), initialDebt + difference);
    }

    function testUpdateDebtWithCurrentDebtEqualToNewDebtReverts() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance / 2;

        // First set the debt
        vault.update_max_debt_for_strategy(address(strategy), newDebt);
        vault.update_debt(address(strategy), newDebt, 0);

        // Then try to set it to the same value
        vm.expectRevert(IMultistrategyVault.NewDebtEqualsCurrentDebt.selector);
        vault.update_debt(address(strategy), newDebt, 0);
    }

    function testUpdateDebtWithCurrentDebtGreaterThanNewDebtAndZeroWithdrawable() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 currentDebt = vaultBalance;
        uint256 newDebt = vaultBalance / 2;

        // First set full debt
        vault.update_max_debt_for_strategy(address(lockedStrategy), currentDebt);
        vault.update_debt(address(lockedStrategy), currentDebt, 0);

        // Lock all the funds
        lockedStrategy.setLockedFunds(currentDebt, DAY);

        // Try to reduce debt
        vault.update_max_debt_for_strategy(address(lockedStrategy), newDebt);
        uint256 returnValue = vault.update_debt(address(lockedStrategy), newDebt, 0);

        // Should stay at current debt since funds are locked
        assertEq(returnValue, currentDebt);
    }

    function testUpdateDebtWithCurrentDebtLessThanNewDebtAndMinimumTotalIdleReducingNewDebt() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;

        // Get initial state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        uint256 currentDebt = params.currentDebt;
        uint256 initialIdle = vault.totalIdle();
        uint256 initialDebt = vault.totalDebt();

        // Set minimum total idle to keep a small amount in vault
        uint256 minimumTotalIdle = vaultBalance - 1;
        vault.set_minimum_total_idle(minimumTotalIdle);

        // Calculate expected adjustments
        uint256 expectedNewDifference = initialIdle - minimumTotalIdle;
        uint256 expectedNewDebt = currentDebt + expectedNewDifference;

        // Set max debt and update debt
        vault.update_max_debt_for_strategy(address(strategy), newDebt);
        vault.update_debt(address(strategy), newDebt, 0);

        // Verify state
        params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, expectedNewDebt);
        assertEq(asset.balanceOf(address(strategy)), expectedNewDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - expectedNewDifference);
        assertEq(vault.totalIdle(), initialIdle - expectedNewDifference);
        assertEq(vault.totalDebt(), initialDebt + expectedNewDifference);
    }

    function testUpdateDebtWithCurrentDebtGreaterThanNewDebtAndMinimumTotalIdle() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 currentDebt = vaultBalance;
        uint256 newDebt = vaultBalance / 2;
        uint256 difference = currentDebt - newDebt;

        // First allocate full debt
        addDebtToStrategy(address(strategy), currentDebt);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        uint256 initialDebt = vault.totalDebt();

        // Set a small minimum total idle
        uint256 minimumTotalIdle = 1;
        vault.set_minimum_total_idle(minimumTotalIdle);

        // Reduce debt in strategy
        vault.update_max_debt_for_strategy(address(strategy), newDebt);
        vault.update_debt(address(strategy), newDebt, 0);

        // Verify state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(asset.balanceOf(address(strategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - newDebt);
        assertEq(vault.totalIdle(), initialIdle + difference);
        assertEq(vault.totalDebt(), initialDebt - difference);
    }

    function testUpdateDebtWithCurrentDebtGreaterThanNewDebtAndTotalIdleLessThanMinimumTotalIdle() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 currentDebt = vaultBalance;
        uint256 newDebt = vaultBalance / 3;

        // First allocate full debt
        addDebtToStrategy(address(strategy), currentDebt);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        uint256 initialDebt = vault.totalDebt();

        // Set minimum idle higher than the debt difference would allow
        uint256 minimumTotalIdle = (currentDebt - newDebt) + 1;
        vault.set_minimum_total_idle(minimumTotalIdle);

        // Calculate expected adjustments
        uint256 expectedNewDifference = minimumTotalIdle - initialIdle;
        uint256 expectedNewDebt = currentDebt - expectedNewDifference;

        // Reduce debt in strategy
        vault.update_max_debt_for_strategy(address(strategy), newDebt);
        vault.update_debt(address(strategy), newDebt, 0);

        // Verify state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, expectedNewDebt);
        assertEq(asset.balanceOf(address(strategy)), expectedNewDebt);
        assertEq(asset.balanceOf(address(vault)), minimumTotalIdle);
        assertEq(vault.totalIdle(), initialIdle + expectedNewDifference);
        assertEq(vault.totalDebt(), initialDebt - expectedNewDifference);
    }

    function testUpdateDebtWithLossyStrategyThatWithdrawsLessThanRequested() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));

        // Deploy lossy strategy
        MockLossyStrategy _lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(_lossyStrategy), true);

        // Allocate full debt to strategy
        addDebtToStrategy(address(_lossyStrategy), vaultBalance);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(_lossyStrategy));
        uint256 currentDebt = params.currentDebt;

        // Set 10% loss on withdrawal
        uint256 loss = currentDebt / 10;
        uint256 newDebt = 0;
        uint256 difference = currentDebt - loss;
        _lossyStrategy.setWithdrawingLoss(loss);

        // Record initial price per share
        uint256 initialPps = vault.pricePerShare();

        // Update debt to 0 (withdraw everything)
        vault.update_debt(address(_lossyStrategy), newDebt, MAX_BPS); // Allow full loss

        // Verify state
        params = vault.strategies(address(_lossyStrategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(asset.balanceOf(address(_lossyStrategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - loss);
        assertEq(vault.totalIdle(), initialIdle + difference);
        assertEq(vault.totalDebt(), newDebt);

        // Price per share should decrease due to loss
        assertLt(vault.pricePerShare(), initialPps);
    }

    function testUpdateDebtWithLossyStrategyThatWithdrawsLessThanRequestedMaxLoss() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));

        // Deploy lossy strategy
        MockLossyStrategy _lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(_lossyStrategy), true);

        // Allocate full debt to strategy
        addDebtToStrategy(address(_lossyStrategy), vaultBalance);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(_lossyStrategy));
        uint256 currentDebt = params.currentDebt;

        // Set 10% loss on withdrawal
        uint256 loss = currentDebt / 10;
        uint256 newDebt = 0;
        uint256 difference = currentDebt - loss;
        _lossyStrategy.setWithdrawingLoss(loss);

        // Record initial price per share
        uint256 initialPps = vault.pricePerShare();

        // With 0 max loss should revert
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.update_debt(address(_lossyStrategy), newDebt, 0);

        // Up to the loss percent should revert (999 bps < 1000 bps needed)
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.update_debt(address(_lossyStrategy), newDebt, 999);

        // With sufficient max loss should succeed
        vault.update_debt(address(_lossyStrategy), newDebt, 1000);

        // Verify state
        params = vault.strategies(address(_lossyStrategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(asset.balanceOf(address(_lossyStrategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance - loss);
        assertEq(vault.totalIdle(), initialIdle + difference);
        assertEq(vault.totalDebt(), newDebt);

        // Price per share should decrease due to loss
        assertLt(vault.pricePerShare(), initialPps);
    }

    function testUpdateDebtWithFaultyStrategyThatWithdrawsMoreThanRequested() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));

        // Deploy lossy strategy with extra yield
        MockLossyStrategy _lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(_lossyStrategy), true);

        // Allocate full debt to strategy
        addDebtToStrategy(address(_lossyStrategy), vaultBalance);

        // Get updated state
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(_lossyStrategy));
        uint256 currentDebt = params.currentDebt;

        // Set 10% extra on withdrawal
        uint256 extra = currentDebt / 10;
        uint256 newDebt = 0;

        // Simulate airdrop to strategy
        asset.mint(address(_lossyStrategy), extra);

        // Set negative loss (extra yield)
        _lossyStrategy.setWithdrawingExtraYield(extra);

        // Record initial price per share
        uint256 initialPps = vault.pricePerShare();

        // Update debt to 0
        vault.update_debt(address(_lossyStrategy), 0, 0);

        // Verify state
        params = vault.strategies(address(_lossyStrategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(_lossyStrategy.totalAssets(), newDebt);
        assertEq(asset.balanceOf(address(vault)), vaultBalance + extra);
        assertEq(vault.totalIdle(), vaultBalance);
        assertEq(vault.totalDebt(), newDebt);

        // Price per share should remain unchanged
        assertEq(vault.pricePerShare(), initialPps);
    }

    function testUpdateDebtWithFaultyStrategyThatDepositsLessThanRequestedWithAirdrop() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 currentDebt = vaultBalance;
        uint256 expectedDebt = currentDebt / 2;
        uint256 fishAmount = 1e17; // 0.1 ETH as fish_amount

        // Airdrop some asset to the vault
        airdropAsset(address(vault), fishAmount);

        // Deploy faulty strategy that only takes half the funds
        MockFaultyStrategy faultyStrategy = new MockFaultyStrategy(address(asset), address(vault));
        vault.add_strategy(address(faultyStrategy), true);

        // Allocate full debt to strategy, but it only takes half
        addDebtToStrategy(address(faultyStrategy), currentDebt);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        uint256 initialDebt = vault.totalDebt();

        // Check the strategy only took half and vault recorded it correctly
        assertEq(initialIdle, expectedDebt, "initialIdle");
        assertEq(initialDebt, expectedDebt, "initialDebt");
        assertEq(vault.strategies(address(faultyStrategy)).currentDebt, expectedDebt, "currentDebt");
        assertEq(asset.balanceOf(address(faultyStrategy)), expectedDebt, "assetBalance");
    }

    function testUpdateDebtWithLossyStrategyThatWithdrawsLessThanRequestedWithAirdrop() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 fishAmount = 1e17; // 0.1 ETH as fish_amount

        // Deploy lossy strategy
        MockLossyStrategy _lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(_lossyStrategy), true);

        // Allocate full debt to strategy
        addDebtToStrategy(address(_lossyStrategy), vaultBalance);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(_lossyStrategy));
        uint256 currentDebt = params.currentDebt;

        // Set 10% loss on withdrawal
        uint256 loss = currentDebt / 10;
        uint256 newDebt = 0;
        uint256 difference = currentDebt - loss;
        _lossyStrategy.setWithdrawingLoss(loss);

        // Record initial price per share
        uint256 initialPps = vault.pricePerShare();

        // Airdrop some asset to the vault
        airdropAsset(address(vault), fishAmount);

        // Update debt to 0 (withdraw everything)
        vault.update_debt(address(_lossyStrategy), newDebt, MAX_BPS); // Allow full loss

        // Verify state
        params = vault.strategies(address(_lossyStrategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(asset.balanceOf(address(_lossyStrategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), (vaultBalance - loss + fishAmount));
        assertEq(vault.totalIdle(), initialIdle + difference);
        assertEq(vault.totalDebt(), newDebt);

        // Price per share should decrease due to loss
        assertLt(vault.pricePerShare(), initialPps);
    }

    function testUpdateDebtWithLossyStrategyThatWithdrawsLessThanRequestedWithAirdropAndMaxLoss() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 fishAmount = 1e17; // 0.1 ETH as fish_amount

        // Deploy lossy strategy
        MockLossyStrategy _lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(_lossyStrategy), true);

        // Allocate full debt to strategy
        addDebtToStrategy(address(_lossyStrategy), vaultBalance);

        // Get updated state
        uint256 initialIdle = vault.totalIdle();
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(_lossyStrategy));
        uint256 currentDebt = params.currentDebt;

        // Set 10% loss on withdrawal
        uint256 loss = currentDebt / 10;
        uint256 newDebt = 0;
        uint256 difference = currentDebt - loss;
        _lossyStrategy.setWithdrawingLoss(loss);

        // Record initial price per share
        uint256 initialPps = vault.pricePerShare();

        // Airdrop some asset to the vault
        airdropAsset(address(vault), fishAmount);

        // With 0 max loss should revert
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.update_debt(address(_lossyStrategy), newDebt, 0);

        // Up to the loss percent should revert (999 bps < 1000 bps needed)
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.update_debt(address(_lossyStrategy), newDebt, 999);

        // With sufficient max loss should succeed
        vault.update_debt(address(_lossyStrategy), newDebt, 1000);

        // Verify state
        params = vault.strategies(address(_lossyStrategy));
        assertEq(params.currentDebt, newDebt);
        assertEq(asset.balanceOf(address(_lossyStrategy)), newDebt);
        assertEq(asset.balanceOf(address(vault)), (vaultBalance - loss + fishAmount));
        assertEq(vault.totalIdle(), initialIdle + difference);
        assertEq(vault.totalDebt(), newDebt);

        // Price per share should decrease due to loss
        assertLt(vault.pricePerShare(), initialPps);
    }

    // Helper functions

    function seedVaultWithFunds(uint256 amount1, uint256 amount2) internal {
        // Mint tokens
        asset.mint(gov, amount1);
        asset.mint(gov, amount2);

        // Deposit into vault
        asset.approve(address(vault), amount1);
        vault.deposit(amount1, gov);

        asset.approve(address(vault), amount2);
        vault.deposit(amount2, gov);
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        // First set max debt
        vault.update_max_debt_for_strategy(strategyAddress, type(uint256).max);
        // Then update debt
        vault.update_debt(strategyAddress, amount, 0);
    }

    // Helper to airdrop assets
    function airdropAsset(address recipient, uint256 amount) internal {
        asset.mint(recipient, amount);
    }
}
