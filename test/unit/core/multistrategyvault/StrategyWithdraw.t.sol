// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockLockedStrategy } from "test/mocks/core/MockLockedStrategy.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract StrategyWithdrawTest is Test {
    uint256 constant DAY = 86400;
    uint256 constant MAX_BPS = 10000;

    MultistrategyVault vault;
    MockERC20 asset;
    address gov;
    address fish;
    uint256 fishAmount;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyVault vaultImplementation;

    function setUp() public {
        gov = address(this);
        fish = address(0xFE5);
        fishAmount = 1e18; // 1 ETH

        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // add roles
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set deposit limit
        vault.set_deposit_limit(type(uint256).max, false);
    }

    function testWithdrawWithInactiveStrategyReverts() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;

        // Create strategies
        MockYieldStrategy strategy = new MockYieldStrategy(address(asset), address(vault));
        MockYieldStrategy inactiveStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(inactiveStrategy);
        uint256 maxLoss = 0;

        // Deposit assets
        userDeposit(fish, amount);

        // Add active strategy and allocate debt
        vault.add_strategy(address(strategy), true);
        addDebtToStrategy(address(strategy), amount);

        // Try to withdraw using inactive strategy
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);
    }

    function testWithdrawWithLiquidStrategyWithdraws() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;

        // Create strategy
        MockYieldStrategy strategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        uint256 maxLoss = 0;

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(strategy), true);
        addDebtToStrategy(address(strategy), amount);

        // Initial checks
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), amount);
        assertEq(asset.balanceOf(fish), 0);

        // Withdraw
        vm.prank(fish);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);

        // Verify state
        checkVaultEmpty(vault);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(fish), amount);
    }

    function testWithdrawWithMultipleLiquidStrategiesWithdraws() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2;
        uint256 shares = amount;

        // Create strategies
        MockYieldStrategy firstStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockYieldStrategy secondStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(firstStrategy);
        strategies[1] = address(secondStrategy);
        uint256 maxLoss = 0;

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(firstStrategy), true);
        vault.add_strategy(address(secondStrategy), true);
        addDebtToStrategy(address(firstStrategy), amountPerStrategy);
        addDebtToStrategy(address(secondStrategy), amountPerStrategy);

        // Initial checks
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(firstStrategy)), amountPerStrategy);
        assertEq(asset.balanceOf(address(secondStrategy)), amountPerStrategy);
        assertEq(asset.balanceOf(fish), 0);

        // Withdraw
        vm.prank(fish);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);

        // Verify state
        checkVaultEmpty(vault);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(firstStrategy)), 0);
        assertEq(asset.balanceOf(address(secondStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount);
    }

    function testWithdrawLockedFundsWithLockedAndLiquidStrategyReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2;
        uint256 amountToLock = amountPerStrategy / 2;
        uint256 amountToWithdraw = amount;

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLockedStrategy lockedStrategy = new MockLockedStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lockedStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 0;

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lockedStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lockedStrategy), amountPerStrategy);

        // Lock funds in locked strategy
        lockedStrategy.setLockedFunds(amountToLock, DAY);

        // Try to withdraw
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InsufficientAssetsInVault.selector);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);
    }

    function testWithdrawWithLockedAndLiquidStrategyWithdraws() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2;
        uint256 amountToLock = amountPerStrategy / 2;
        uint256 amountToWithdraw = amount - amountToLock;
        uint256 shares = amount - amountToLock;

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLockedStrategy lockedStrategy = new MockLockedStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lockedStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 0;

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lockedStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lockedStrategy), amountPerStrategy);

        // Lock funds in locked strategy
        lockedStrategy.setLockedFunds(amountToLock, DAY);

        // Withdraw
        vm.prank(fish);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), amountToLock);
        assertEq(vault.totalSupply(), amountToLock);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), amountToLock);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lockedStrategy)), amountToLock);
        assertEq(asset.balanceOf(fish), amountToWithdraw);
    }

    function testWithdrawWithLossyStrategyNoMaxLossReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount;
        uint256 amountToLose = amountPerStrategy / 2; // lose half of strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy - removed gov parameter
        lossyStrategy.setLoss(amountToLose);

        // Try to withdraw - should revert due to loss
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);
    }

    function testWithdrawWithLossyStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount;
        uint256 amountToLose = amountPerStrategy / 2; // lose half of strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, MAX_BPS, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amountToWithdraw - amountToLose);
    }

    function testRedeemWithLossyStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount;
        uint256 amountToLose = amountPerStrategy / 2; // lose half of strategy

        // Create lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        uint256 sharesToRedeem = vault.balanceOf(fish);

        // Redeem with loss
        vm.prank(fish);
        vault.redeem(sharesToRedeem, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
    }

    function testWithdrawWithFullLossStrategyWithdrawsNone() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount;
        uint256 amountToLose = amountPerStrategy; // lose all of strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with full loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), 0); // Fish receives nothing
    }

    function testRedeemWithFullLossStrategyWithdrawsNone() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount;
        uint256 amountToLose = amountPerStrategy; // lose all of strategy
        uint256 shares = amount;

        // Create lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy (remove gov parameter)
        lossyStrategy.setLoss(amountToLose);

        // Redeem with full loss
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), 0); // Fish receives nothing due to full loss
    }

    function testWithdrawWithLossyAndLiquidStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of lossy strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create strategies but switch the order compared to previous test
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(liquidStrategy); // Liquid first
        strategies[1] = address(lossyStrategy); // Lossy second
        uint256 maxLoss = 2500; // Allow up to 25% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
    }

    function testRedeemWithFullLossyAndLiquidStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy; // lose entire lossy strategy
        uint256 shares = amount;

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Redeem with partial loss
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
    }

    function testWithdrawWithLiquidAndLossyStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // loss only half of lossy strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create strategies but switch the order compared to previous test
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(liquidStrategy); // Liquid first
        strategies[1] = address(lossyStrategy); // Lossy second
        uint256 maxLoss = 2500; // Allow up to 25% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
    }

    function testRedeemWithLiquidAndFullLossyStrategyWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy; // lose all of lossy strategy
        uint256 shares = amount;

        // Create strategies - in this test liquid is first, then lossy
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(liquidStrategy);
        strategies[1] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Redeem with partial loss
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
    }

    function testWithdrawWithLiquidAndLossyStrategyThatLossesWhileWithdrawingNoMaxLossReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(liquidStrategy);
        strategies[1] = address(lossyStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set withdrawing loss in lossy strategy (this happens during redeem)
        lossyStrategy.setWithdrawingLoss(amountToLose);

        // Try to withdraw - should revert due to loss
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);
    }

    function testWithdrawWithLiquidAndLossyStrategyThatLossesWhileWithdrawingWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToWithdraw = amount; // withdraw full deposit

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(liquidStrategy);
        strategies[1] = address(lossyStrategy);
        uint256 maxLoss = 2500; // Allow up to 25% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set withdrawing loss in lossy strategy
        lossyStrategy.setWithdrawingLoss(amountToLose);

        // Withdraw with loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
    }

    function testRedeemHalfOfAssetsFromLossyStrategyThatLossesWhileWithdrawingWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 4; // lose quarter of lossy strategy
        uint256 amountToWithdraw = amount / 2; // withdraw half deposit
        uint256 shares = amount / 2; // redeem half shares

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set withdrawing loss in lossy strategy
        lossyStrategy.setWithdrawingLoss(amountToLose);

        // Redeem half with loss
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalSupply(), amount / 2); // Half shares remain
        assertEq(vault.totalDebt(), amount - amountToWithdraw); // Remaining debt
        assertEq(asset.balanceOf(address(vault)), vault.totalIdle());
        assertEq(asset.balanceOf(address(liquidStrategy)), amountPerStrategy);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(asset.balanceOf(fish), amountToWithdraw - amountToLose);
    }

    function testRedeemHalfOfAssetsFromLossyStrategyThatLossesWhileWithdrawingCustomMaxLossReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half of amount per strategy
        uint256 amountToLose = amountPerStrategy / 4; // loss only quarter of strategy
        uint256 shares = amount / 2; // redeem half shares

        // Create strategies
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set withdrawing loss in lossy strategy
        lossyStrategy.setWithdrawingLoss(amountToLose);

        // Try to redeem with no allowed loss - should revert
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.redeem(shares, fish, fish, maxLoss, strategies);
    }

    function testWithdrawFromLossyStrategyWithUnrealisedLosses() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount; // deposit all of amount to strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of strategy
        uint256 amountToWithdraw = amount;

        // Create strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy (unrealized loss)
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(lossyStrategy.totalAssets(), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
        assertEq(vault.balanceOf(fish), 0);
    }

    function testRedeemFromLossyStrategyWithUnrealisedLosses() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount; // deposit all of amount to strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of strategy
        uint256 shares = amount;
        uint256 amountToRedeem = shares;

        // Create strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set loss in lossy strategy (unrealized loss)
        lossyStrategy.setLoss(amountToLose);

        // Redeem with loss
        vm.prank(fish);
        vault.redeem(amountToRedeem, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(lossyStrategy.totalAssets(), 0);
        assertEq(asset.balanceOf(fish), amount - amountToLose);
        assertEq(vault.balanceOf(fish), 0);
    }

    function testWithdrawFromLossyStrategyWithUnrealisedLossesAndMaxRedeem() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 amountToLose = amountPerStrategy / 4; // lose 1/4 of lossy strategy
        uint256 amountToLock = (amountPerStrategy - amountToLose) / 2; // lock half of what's left
        uint256 amountToWithdraw = (amount * 3) / 4; // withdraw 75% of total
        uint256 shares = amountToWithdraw;

        // Create strategies
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        vault.add_strategy(address(liquidStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);

        // Set loss and locked funds in lossy strategy
        lossyStrategy.setLoss(amountToLose);
        lossyStrategy.setLockedFunds(amountToLock);

        // Try to redeem with no loss allowed (should revert)
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.redeem(shares, fish, fish, 0, strategies);

        // Now redeem with max loss allowed
        vm.prank(fish);
        vault.redeem(shares, fish, fish, 10000, strategies);

        // Verify state
        assertEq(vault.totalAssets(), amount - amountToWithdraw);
        assertEq(vault.totalSupply(), amount - amountToWithdraw);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), amount - amountToWithdraw);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(lossyStrategy.totalAssets(), amountToLock);
        assertEq(asset.balanceOf(address(liquidStrategy)), 0);
        assertEq(liquidStrategy.totalAssets(), 0);
        assertEq(asset.balanceOf(fish), amountToWithdraw - (amountToLose / 2));
        assertEq(vault.balanceOf(fish), amount - amountToWithdraw);
    }

    function testWithdrawFromLossyStrategyWithUnrealisedLossesFullStrategy() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount; // deposit all to strategy
        uint256 amountToLose = amountPerStrategy; // lose ALL funds in strategy
        uint256 amountToWithdraw = amount;

        // Create strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set 100% loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with full loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(lossyStrategy.totalAssets(), 0);
        assertEq(asset.balanceOf(fish), 0); // User gets nothing due to 100% loss
        assertEq(vault.balanceOf(fish), 0);
    }

    function testRedeemFromLossyStrategyWithUnrealisedLossesAllOfStrategy() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount; // deposit all to strategy
        uint256 amountToLose = amountPerStrategy; // lose ALL funds in strategy
        uint256 shares = amount;
        uint256 amountToRedeem = shares;

        // Create strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](1);
        strategies[0] = address(lossyStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategy and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);

        // Set 100% loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Redeem with full loss
        vm.prank(fish);
        vault.redeem(amountToRedeem, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(lossyStrategy)), 0);
        assertEq(lossyStrategy.totalAssets(), 0);
        assertEq(asset.balanceOf(fish), 0); // User gets 0 due to complete loss
        assertEq(vault.balanceOf(fish), 0);
    }

    function testWithdrawHalfOfStrategyAssetsFromLossyStrategyWithUnrealisedLossesNoMaxFeeReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToWithdraw = amount / 4; // withdraw 1/4 (half of strategy debt)

        // Create strategies
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        vault.add_strategy(address(liquidStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Try to withdraw with no allowed loss - should revert
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);
    }

    function testWithdrawHalfOfStrategyAssetsFromLossyStrategyWithUnrealisedLossesWithdrawsLessThanDeposited() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToWithdraw = amount / 4; // withdraw 1/4 (half of strategy debt)

        // Create strategies
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 5000; // Allow up to 50% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        vault.add_strategy(address(liquidStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        lossyStrategy.setLoss(amountToLose);

        // Withdraw with acceptable loss
        vm.prank(fish);
        vault.withdraw(amountToWithdraw, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), amount - amountToWithdraw);
        assertEq(vault.totalSupply(), amount - amountToWithdraw);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), amount - amountToWithdraw);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), amountPerStrategy);
        assertEq(lossyStrategy.totalAssets(), amountPerStrategy - amountToLose - amountToLose / 2); // withdrawn from strategy
        assertEq(asset.balanceOf(fish), amountToWithdraw - amountToLose / 2); // it only takes half loss
        assertEq(vault.balanceOf(fish), amount - amountToWithdraw);
    }

    function testRedeemHalfOfStrategyAssetsFromLockedLossyStrategyWithUnrealisedLossesWithdrawsLessThanDeposited()
        public
    {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToLock = (amountToLose * 9) / 10; // Lock 90% of what's remaining
        uint256 amountToWithdraw = amount / 4; // withdraw 1/4 (half of strategy debt)
        uint256 shares = amount / 4; // redeem 1/4 of shares

        // Calculate expected values
        uint256 expectedLockedOut = (amountToLose * 1) / 10; // 0.025 ETH (unlocked portion)
        uint256 expectedLockedLoss = expectedLockedOut; // 0.025 ETH (loss on unlocked portion)
        uint256 expectedLiquidOut = amountToWithdraw - expectedLockedOut - expectedLockedLoss; // 0.2 ETH

        // Create strategies
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 10000; // Allow up to 100% loss

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        vault.add_strategy(address(liquidStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);

        // Set loss in lossy strategy
        vm.prank(address(lossyStrategy));
        lossyStrategy.setLoss(amountToLose);

        // Lock funds in lossy strategy
        lossyStrategy.setLockedFunds(amountToLock);

        // Redeem with max loss
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify state exactly as expected
        assertEq(vault.totalAssets(), amount - amountToWithdraw);
        assertEq(vault.totalSupply(), amount - shares);

        // The most important assertion - don't enforce totalIdle until fixed
        assertEq(vault.totalIdle(), 0);

        // Check total debt - this is what's really failing
        assertEq(vault.totalDebt(), amount - amountToWithdraw);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(liquidStrategy)), amountPerStrategy - expectedLiquidOut);
        assertEq(asset.balanceOf(address(lossyStrategy)), amountPerStrategy - amountToLose - expectedLockedOut);
        assertEq(asset.balanceOf(fish), amountToWithdraw - expectedLockedLoss);
        assertEq(vault.balanceOf(fish), amount - shares);
    }

    function testRedeemHalfOfStrategyAssetsFromLockedLossyStrategyWithUnrealisedLossesCustomMaxLossReverts() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 amountToLose = amountPerStrategy / 2; // lose half of lossy strategy
        uint256 amountToLock = (amountToLose * 9) / 10; // Lock 90% of what's remaining
        uint256 shares = amount / 4; // redeem 1/4 of shares

        // Create strategies
        MockLockedStrategy lossyStrategy = new MockLockedStrategy(address(asset), address(vault));
        MockYieldStrategy liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(lossyStrategy);
        strategies[1] = address(liquidStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(lossyStrategy), true);
        vault.add_strategy(address(liquidStrategy), true);
        addDebtToStrategy(address(lossyStrategy), amountPerStrategy);
        addDebtToStrategy(address(liquidStrategy), amountPerStrategy);

        // Simulate loss by transferring out funds
        vm.prank(address(lossyStrategy));
        asset.transfer(gov, amountToLose);

        // Lock remaining funds
        lossyStrategy.setLockedFunds(amountToLock, DAY);

        // Try to redeem with no allowed loss - should revert
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.TooMuchLoss.selector);
        vault.redeem(shares, fish, fish, maxLoss, strategies);
    }

    function testWithdrawWithMultipleLiquidStrategiesMoreAssetsThanDebtWithdraws() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 shares = amount; // withdraw all

        // Create strategies
        MockYieldStrategy firstStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockYieldStrategy secondStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(firstStrategy);
        strategies[1] = address(secondStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Add profit amount slightly more than half the total (to ensure it can serve full withdrawal)
        uint256 profit = amountPerStrategy + 1;

        // Deposit assets
        userDeposit(fish, amount);

        // Add strategies and allocate debt
        vault.add_strategy(address(firstStrategy), true);
        vault.add_strategy(address(secondStrategy), true);
        addDebtToStrategy(address(firstStrategy), amountPerStrategy);
        addDebtToStrategy(address(secondStrategy), amountPerStrategy);

        // Airdrop profit to first strategy
        asset.mint(gov, fishAmount);
        vm.prank(gov);
        asset.transfer(address(firstStrategy), profit);

        // Report profit
        vm.prank(gov);
        firstStrategy.report();

        // Withdraw full amount
        vm.prank(fish);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);

        // Verify state
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalIdle(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(firstStrategy.totalAssets(), profit);
        assertEq(asset.balanceOf(address(firstStrategy)), profit);
        assertEq(asset.balanceOf(address(secondStrategy)), 0);
        assertEq(asset.balanceOf(fish), amount);

        // Check that vault is empty
        checkVaultEmpty(vault);
    }

    function testWithdrawWithCustomQueueAndUseDefaultQueueOverrides() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 shares = amount / 2; // withdraw half

        // Create strategies
        MockYieldStrategy firstStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockYieldStrategy secondStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(firstStrategy);
        strategies[1] = address(secondStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add required role for default queue management
        vault.add_role(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);

        // Add strategies and allocate debt
        vault.add_strategy(address(firstStrategy), true);
        vault.add_strategy(address(secondStrategy), true);
        addDebtToStrategy(address(firstStrategy), amountPerStrategy);
        addDebtToStrategy(address(secondStrategy), amountPerStrategy);

        // Set override to true
        vault.set_use_default_queue(true);

        // Set default queue to opposite of the custom one
        address[] memory defaultQueue = new address[](2);
        defaultQueue[0] = address(secondStrategy);
        defaultQueue[1] = address(firstStrategy);
        vault.set_default_queue(defaultQueue);

        // Withdraw half
        vm.prank(fish);
        vault.withdraw(shares, fish, fish, maxLoss, strategies);

        // Verify state - should only have withdrawn from second strategy per the default queue
        assertEq(vault.strategies(address(firstStrategy)).currentDebt, amountPerStrategy);
        assertEq(vault.strategies(address(secondStrategy)).currentDebt, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(firstStrategy)), amountPerStrategy);
        assertEq(asset.balanceOf(address(secondStrategy)), 0);
        assertEq(asset.balanceOf(fish), shares);
        assertGt(vault.balanceOf(fish), 0);
    }

    function testRedeemWithCustomQueueAndUseDefaultQueueOverrides() public {
        uint256 amount = fishAmount;
        uint256 amountPerStrategy = amount / 2; // deposit half to each strategy
        uint256 shares = amount / 2; // redeem half

        // Create strategies
        MockYieldStrategy firstStrategy = new MockYieldStrategy(address(asset), address(vault));
        MockYieldStrategy secondStrategy = new MockYieldStrategy(address(asset), address(vault));
        address[] memory strategies = new address[](2);
        strategies[0] = address(firstStrategy);
        strategies[1] = address(secondStrategy);
        uint256 maxLoss = 0; // No loss allowed

        // Deposit assets
        userDeposit(fish, amount);

        // Add required role for queue management
        vault.add_role(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);

        // Add strategies and allocate debt
        vault.add_strategy(address(firstStrategy), true);
        vault.add_strategy(address(secondStrategy), true);
        addDebtToStrategy(address(firstStrategy), amountPerStrategy);
        addDebtToStrategy(address(secondStrategy), amountPerStrategy);

        // Set override to true
        vault.set_use_default_queue(true);

        // Set default queue to opposite of the custom one
        address[] memory defaultQueue = new address[](2);
        defaultQueue[0] = address(secondStrategy);
        defaultQueue[1] = address(firstStrategy);
        vault.set_default_queue(defaultQueue);

        // Redeem half using redeem instead of withdraw
        vm.prank(fish);
        vault.redeem(shares, fish, fish, maxLoss, strategies);

        // Verify the same state as withdraw
        MultistrategyVault.StrategyParams memory firstParams = vault.strategies(address(firstStrategy));
        MultistrategyVault.StrategyParams memory secondParams = vault.strategies(address(secondStrategy));

        assertEq(firstParams.currentDebt, amountPerStrategy);
        assertEq(secondParams.currentDebt, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(address(firstStrategy)), amountPerStrategy);
        assertEq(asset.balanceOf(address(secondStrategy)), 0);
        assertEq(asset.balanceOf(fish), shares);
        assertGt(vault.balanceOf(fish), 0);
    }

    function testWithdrawWithMaxLossTooHighReverts() public {
        uint256 amount = fishAmount;
        uint256 maxLoss = 10001; // Exceeds MAX_BPS (10000)

        // Deposit assets
        userDeposit(fish, amount);

        // Try to withdraw with max loss too high - should revert
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.MaxLossExceeded.selector);
        vault.withdraw(amount, fish, fish, maxLoss, new address[](0));
    }

    function testRedeemWithMaxLossTooHighReverts() public {
        uint256 shares = fishAmount;
        uint256 maxLoss = 10001; // Exceeds MAX_BPS (10000)

        // Deposit assets
        userDeposit(fish, shares);

        // Try to redeem with max loss too high - should revert
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.MaxLossExceeded.selector);
        vault.redeem(shares, fish, fish, maxLoss, new address[](0));
    }

    // Helper functions
    function userDeposit(address user, uint256 amount) internal {
        // Mint tokens
        asset.mint(user, amount);

        // Deposit into vault
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        // First set max debt
        vault.update_max_debt_for_strategy(strategyAddress, type(uint256).max);
        // Then update debt
        vault.update_debt(strategyAddress, amount, 0);
    }

    function checkVaultEmpty(MultistrategyVault _vault) internal view {
        assertEq(_vault.totalAssets(), 0);
        assertEq(_vault.totalSupply(), 0);
        assertEq(_vault.totalIdle(), 0);
        assertEq(_vault.totalDebt(), 0);
    }
}
