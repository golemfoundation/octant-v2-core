// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { MockAccountant } from "test/mocks/core/MockAccountant.sol";

contract ProfitableStrategyFlowTest is Test {
    // Define structs to avoid stack too deep error
    struct TestVars {
        address user1;
        address user2;
        uint256 depositAmount;
        uint256 firstProfit;
        uint256 secondProfit;
        uint256 totalFee;
        uint256 minTotalIdle;
        uint256 pps;
        uint256 assetsBeforeProfit;
        uint256 user1InitialBalance;
        uint256 user2InitialBalance;
        uint256 user1Withdraw;
        uint256 initialTotalAssets;
        uint256 initialTotalSupply;
        uint256 newDebt;
        uint256 performanceFee;
    }

    MultistrategyVault public vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MultistrategyVaultFactory public vaultFactory;
    MultistrategyVault public vaultImplementation;
    MockAccountant public accountant;

    address gov;
    address fish;
    address bunny;
    address whale;
    address strategist;

    uint256 fishAmount = 10_000e18;
    uint256 constant MAX_BPS = 10_000; // 100% in basis points
    uint256 constant MAX_INT = type(uint256).max;

    uint256 initialTimestamp;

    function setUp() public {
        gov = address(0x1);
        fish = address(0x2);
        bunny = address(0x3);
        whale = address(0x4);
        strategist = address(0x5);

        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);
        asset.mint(whale, 1_000_000e18);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Factory", address(vaultImplementation), gov);

        initialTimestamp = block.timestamp;
    }

    function testProfitableStrategyFlow() public {
        TestVars memory vars;
        vars.performanceFee = 1_000; // 10%

        vars.user1 = fish;
        vars.user2 = bunny;
        vars.depositAmount = fishAmount;
        vars.firstProfit = vars.depositAmount / 4;
        vars.secondProfit = vars.depositAmount / 2;

        // Create vault & accountant
        _createVault();
        accountant = new MockAccountant(address(vault));
        vm.prank(gov);
        vault.set_accountant(address(accountant));

        // Set performance fee
        accountant.setFees(address(strategy), 0, vars.performanceFee, 0);

        vars.user1InitialBalance = asset.balanceOf(vars.user1);
        // user_1 (fish) deposit assets to vault
        _userDeposit(vars.user1, vars.depositAmount);

        assertEq(vault.balanceOf(vars.user1), vars.depositAmount, "User1 should have 1:1 shares");
        assertEq(vault.pricePerShare() / 10 ** asset.decimals(), 1, "Price per share should be 1:1");

        vars.initialTotalAssets = vault.totalAssets();
        vars.initialTotalSupply = vault.totalSupply();

        _addDebtToStrategy(address(strategy), vars.depositAmount);

        assertEq(vault.totalAssets(), vars.depositAmount, "Vault total assets should match deposit");
        assertEq(
            vault.strategies(address(strategy)).currentDebt,
            vars.depositAmount,
            "Strategy debt should match deposit"
        );
        assertEq(strategy.totalAssets(), vars.depositAmount, "Strategy assets should match deposit");

        // Simulate first profit on strategy
        vars.totalFee = (vars.firstProfit * vars.performanceFee) / MAX_BPS;
        vm.prank(whale);
        asset.transfer(address(strategy), vars.firstProfit);

        // Report profit
        vm.prank(gov);
        strategy.report(); // This is needed to update strategy's internal accounting

        vm.prank(gov);
        (uint256 gain, uint256 loss) = vault.process_report(address(strategy));

        assertEq(gain, vars.firstProfit, "Reported gain should match first profit");
        assertEq(loss, 0, "Should have no loss");
        assertApproxEqAbs(
            vault.totalAssets(),
            vars.depositAmount + vars.firstProfit,
            1e13,
            "Total assets should include profit"
        );

        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(address(accountant))),
            vars.totalFee,
            1e13,
            "Accountant should have fees"
        );

        // Fast forward time to allow profits to unlock
        vm.warp(initialTimestamp + 7 days);

        vars.pps = vault.pricePerShare();

        // User2 deposits
        _airdropAsset(vars.user2, vars.depositAmount);
        vars.user2InitialBalance = asset.balanceOf(vars.user2);
        _userDeposit(vars.user2, vars.depositAmount);

        assertEq(vault.totalIdle(), vars.depositAmount, "Idle should equal user2's deposit");

        // Increase max debt for strategy to allow more deposits
        vm.startPrank(gov);
        vault.update_max_debt_for_strategy(address(strategy), strategy.totalAssets() + vars.depositAmount);
        vm.stopPrank();

        // Add debt for user2's deposit
        _addDebtToStrategy(address(strategy), strategy.totalAssets() + vars.depositAmount);

        assertEq(vault.totalIdle(), 0, "Idle should be 0 after adding debt");

        // Generate second profit
        vm.prank(whale);
        asset.transfer(address(strategy), vars.secondProfit);

        vars.assetsBeforeProfit = vault.totalAssets();

        // Report second profit
        vm.prank(gov);
        strategy.report(); // Update strategy's internal accounting

        vm.prank(gov);
        (gain, loss) = vault.process_report(address(strategy));

        assertEq(gain, vars.secondProfit, "Reported gain should match second profit");
        assertEq(loss, 0, "Should have no loss");
        assertApproxEqAbs(
            vault.totalAssets(),
            vars.assetsBeforeProfit + vars.secondProfit,
            1e13,
            "Total assets should include second profit"
        );

        // Users deposited same amount, but should have different shares due to PPS
        assertTrue(
            vault.balanceOf(vars.user1) > vault.balanceOf(vars.user2),
            "User1 should have more shares than User2"
        );

        // Set minimum total idle
        vars.minTotalIdle = vars.depositAmount / 2;
        vm.prank(gov);
        vault.set_minimum_total_idle(vars.minTotalIdle);

        // Update debt to respect minimum idle
        vars.newDebt = strategy.totalAssets() - vars.depositAmount / 4;
        _addDebtToStrategy(address(strategy), vars.newDebt);

        assertEq(vault.totalIdle(), vars.minTotalIdle, "Idle should match minimum");
        assertTrue(
            vault.strategies(address(strategy)).currentDebt != vars.newDebt,
            "Strategy should not have desired debt due to minimum idle"
        );

        // User1 withdraws some assets
        vars.user1Withdraw = vault.totalIdle();

        vm.prank(vars.user1);
        vault.withdraw(vars.user1Withdraw, vars.user1, vars.user1, 0, new address[](0));

        assertApproxEqAbs(vault.totalIdle(), 0, 1, "Idle should be close to 0 after withdrawal");

        // Try to update debt again
        vars.newDebt = strategy.totalAssets() - vars.depositAmount / 4;
        _addDebtToStrategy(address(strategy), vars.newDebt);

        assertEq(vault.totalIdle(), vars.minTotalIdle, "Idle should match minimum again");

        // Fast forward time to fully unlock profits
        vm.warp(initialTimestamp + 10 days);

        // Verify total assets
        assertApproxEqAbs(
            vault.totalAssets(),
            2 * vars.depositAmount + vars.firstProfit + vars.secondProfit - vars.user1Withdraw,
            1e13,
            "Total assets should reflect all transactions"
        );

        // User1 redeems all remaining shares
        address[] memory withdrawalQueue = new address[](1);
        withdrawalQueue[0] = address(strategy);

        vm.startPrank(vars.user1);
        vault.redeem(vault.balanceOf(vars.user1), vars.user1, vars.user1, 0, withdrawalQueue);
        vm.stopPrank();

        assertApproxEqAbs(vault.balanceOf(vars.user1), 0, 1, "User1 should have no shares left");
        assertTrue(
            asset.balanceOf(vars.user1) > vars.user1InitialBalance,
            "User1 should have more assets than initial"
        );

        // User2 redeems all shares
        vm.startPrank(vars.user2);
        vault.redeem(vault.balanceOf(vars.user2), vars.user2, vars.user2, 0, new address[](0));
        vm.stopPrank();

        assertApproxEqAbs(vault.balanceOf(vars.user2), 0, 1, "User2 should have no shares left");
        assertTrue(
            asset.balanceOf(vars.user2) > vars.user2InitialBalance,
            "User2 should have more assets than initial"
        );

        // Fast forward more time
        vm.warp(initialTimestamp + 24 days);

        // Empty the strategy and revoke it
        _addDebtToStrategy(address(strategy), 0);

        assertEq(strategy.totalAssets(), 0, "Strategy should have no assets");
        assertEq(vault.strategies(address(strategy)).currentDebt, 0, "Strategy should have no debt");

        vm.prank(gov);
        vault.revoke_strategy(address(strategy));

        assertEq(vault.strategies(address(strategy)).activation, 0, "Strategy should be deactivated");
    }

    function _createVault() internal {
        vm.startPrank(gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));

        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);

        strategy = _createStrategy();

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), fishAmount);
        vm.stopPrank();
    }

    function _createStrategy() internal returns (MockYieldStrategy) {
        return new MockYieldStrategy(address(asset), address(vault));
    }

    function _userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        vm.prank(gov);
        vault.update_debt(strategyAddress, amount, 0);
    }

    function _airdropAsset(address to, uint256 amount) internal {
        vm.prank(gov);
        asset.mint(to, amount);
    }
}
