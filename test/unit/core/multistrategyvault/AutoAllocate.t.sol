// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { Constants } from "test/unit/utils/constants.sol";

contract AutoAllocateTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;
    address gov;
    address fish;
    uint256 fishAmount;

    function setUp() public {
        gov = address(this);
        fish = makeAddr("fish");
        fishAmount = 1e18;
        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set up roles for governance
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set deposit limit
        vm.prank(gov);
        vault.set_deposit_limit(100 ether, true);

        // Create and initialize the strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Add strategy to vault
        vault.add_strategy(address(strategy), true);

        // Give fish some tokens
        asset.mint(fish, fishAmount);
    }

    function testDepositAutoUpdateDebt() public {
        uint256 assets = fishAmount;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), assets * 2);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), assets);
        assertEq(strategy.totalAssets(), assets);
        assertEq(strategy.balanceOf(address(vault)), assets);
        assertEq(vault.strategies(address(strategy)).currentDebt, assets);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testMintAutoUpdateDebt() public {
        uint256 assets = fishAmount;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), assets * 2);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Mint shares
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vault.mint(assets, fish);
        vm.stopPrank();

        // Verify final state after mint
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), assets);
        assertEq(strategy.totalAssets(), assets);
        assertEq(strategy.balanceOf(address(vault)), assets);
        assertEq(vault.strategies(address(strategy)).currentDebt, assets);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtMaxDebt() public {
        uint256 assets = fishAmount;
        uint256 maxDebt = assets / 10;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with limited max debt
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), maxDebt);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertLt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtUpdated(address(strategy), 0, maxDebt);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), assets - maxDebt);
        assertEq(vault.totalDebt(), maxDebt);
        assertEq(strategy.totalAssets(), maxDebt);
        assertEq(strategy.balanceOf(address(vault)), maxDebt);
        assertEq(vault.strategies(address(strategy)).currentDebt, maxDebt);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtMaxDeposit() public {
        uint256 assets = fishAmount;
        uint256 maxDeposit = assets / 10;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with high max debt but limited strategy deposit
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        strategy.setMaxDebt(maxDeposit);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertEq(strategy.maxDeposit(address(vault)), maxDeposit);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtUpdated(address(strategy), 0, maxDeposit);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), assets - maxDeposit);
        assertEq(vault.totalDebt(), maxDeposit);
        assertEq(strategy.totalAssets(), maxDeposit);
        assertEq(strategy.balanceOf(address(vault)), maxDeposit);
        assertEq(vault.strategies(address(strategy)).currentDebt, maxDeposit);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtMaxDepositZero() public {
        uint256 assets = fishAmount;
        uint256 maxDeposit = 0;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with high max debt but zero strategy deposit
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        strategy.setMaxDebt(maxDeposit);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertEq(strategy.maxDeposit(address(vault)), maxDeposit);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets - should not emit DebtUpdated event
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), assets - maxDeposit);
        assertEq(vault.totalDebt(), maxDeposit);
        assertEq(strategy.totalAssets(), maxDeposit);
        assertEq(strategy.balanceOf(address(vault)), maxDeposit);
        assertEq(vault.strategies(address(strategy)).currentDebt, maxDeposit);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtMinIdle() public {
        uint256 assets = fishAmount;
        uint256 minIdle = assets / 10;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with minimum idle requirement
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vault.set_minimum_total_idle(minIdle);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), minIdle);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtUpdated(address(strategy), 0, assets - minIdle);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), minIdle);
        assertEq(vault.totalDebt(), assets - minIdle);
        assertEq(strategy.totalAssets(), assets - minIdle);
        assertEq(strategy.balanceOf(address(vault)), assets - minIdle);
        assertEq(vault.strategies(address(strategy)).currentDebt, assets - minIdle);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtMinIdleNotMet() public {
        uint256 assets = fishAmount;
        uint256 minIdle = assets * 2; // Set min idle higher than deposit

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with high minimum idle requirement
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vault.set_minimum_total_idle(minIdle);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertGt(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), minIdle);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // Deposit assets - expect no debt update since min idle not met
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state after deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), assets);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), assets);
    }

    function testDepositAutoUpdateDebtCurrentDebtMoreThanMaxDebt() public {
        uint256 assets = fishAmount / 2;
        uint256 maxDebt = assets;
        uint256 profit = assets / 10;

        // Verify initial state
        assertEq(vault.autoAllocate(), false);

        // Set up auto-allocate with limited max debt
        vault.set_auto_allocate(true);
        vault.update_max_debt_for_strategy(address(strategy), maxDebt);

        // Verify settings
        assertEq(vault.autoAllocate(), true);
        assertGt(strategy.maxDeposit(address(vault)), assets);
        assertEq(vault.strategies(address(strategy)).maxDebt, assets);
        assertEq(vault.minimumTotalIdle(), 0);

        // Verify initial balances
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(strategy.totalAssets(), 0);
        assertEq(strategy.balanceOf(address(vault)), 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertEq(vault.balanceOf(fish), 0);

        // First deposit
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.DebtUpdated(address(strategy), 0, maxDebt);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify state after first deposit
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), maxDebt);
        assertEq(strategy.totalAssets(), maxDebt);
        assertEq(strategy.balanceOf(address(vault)), maxDebt);
        assertEq(vault.strategies(address(strategy)).currentDebt, maxDebt);
        assertEq(vault.balanceOf(fish), assets);

        // Simulate profit in strategy and report it
        asset.mint(address(strategy), profit);
        strategy.report();
        vault.process_report(address(strategy));

        // Verify debt is now greater than max debt
        assertGt(vault.strategies(address(strategy)).currentDebt, vault.strategies(address(strategy)).maxDebt);

        // Second deposit - should not update debt
        vm.startPrank(fish);
        asset.approve(address(vault), assets);
        vault.deposit(assets, fish);
        vm.stopPrank();

        // Verify final state
        assertEq(vault.totalAssets(), assets * 2 + profit);
        assertEq(vault.totalIdle(), assets);
        assertEq(vault.totalDebt(), maxDebt + profit);
        assertEq(strategy.totalAssets(), maxDebt + profit);
        assertEq(vault.strategies(address(strategy)).currentDebt, maxDebt + profit);
        assertGt(vault.balanceOf(fish), assets); // Should be greater due to profit
    }
}
