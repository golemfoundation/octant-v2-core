// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IAccountant } from "src/interfaces/IAccountant.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockAccountant } from "test/mocks/core/MockAccountant.sol";
import { Constants } from "../../utils/constants.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";
import { MockFaultyAccountant } from "test/mocks/core/MockFaultyAccountant.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";

contract StrategyAccountingTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;

    address gov;
    uint256 constant YEAR = 31_556_952;
    uint256 constant DAY = 86400;

    struct TestVars {
        uint256 vaultBalance;
        uint256 gain;
        uint256 loss;
        uint256 managementFee;
        uint256 performanceFee;
        uint256 refundRatio;
        uint256 refund;
        uint256 initialIdle;
        uint256 ppsBeforeReport;
        uint256 supplyBeforeReport;
    }

    function setUp() public {
        gov = address(this);
        asset = new MockERC20(18);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        // Create and initialize the vault
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set roles for governance - this matches the set_role fixture
        vault.add_role(gov, IMultistrategyVault.Roles.EMERGENCY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // increase max deposit limit
        vault.set_deposit_limit(type(uint256).max, true);

        // Seed vault with funds
        uint256 seedAmount = 1e18;
        asset.mint(gov, seedAmount);
        asset.approve(address(vault), seedAmount);
        vault.deposit(seedAmount, gov);

        // Create and initialize the strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Add strategy to vault
        vault.add_strategy(address(strategy), true);

        // Update max debt for strategy
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        vault.update_debt(strategyAddress, amount, 0);
    }

    function airdropAsset(address recipient, uint256 amount) internal {
        asset.mint(recipient, amount);
    }

    function deployAccountant() internal returns (MockAccountant) {
        MockAccountant accountant = new MockAccountant(address(asset));
        vault.set_accountant(address(accountant));
        return accountant;
    }

    function setFeesForStrategy(
        MockAccountant accountant,
        address strategyAddress,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 refundRatio
    ) internal {
        accountant.setFees(strategyAddress, managementFee, performanceFee, refundRatio);
    }

    // Tests

    function testProcessReportWithInactiveStrategyReverts() public {
        // Create a new strategy that hasn't been added to the vault
        MockYieldStrategy inactiveStrategy = new MockYieldStrategy(address(asset), address(vault));

        // Expect the process report to revert
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.process_report(address(inactiveStrategy));
    }

    function testProcessReportWithGainAndZeroFees() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 gain = newDebt / 2;

        // Add debt to strategy
        addDebtToStrategy(address(strategy), newDebt);

        // Airdrop gain to strategy
        airdropAsset(address(strategy), gain);

        // Record gain
        strategy.report();

        // Get initial debt
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(strategy));
        uint256 initialDebt = strategyParams.currentDebt;

        // Process report
        uint256 snapshotTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), gain, 0, initialDebt + gain, 0, 0, 0);
        vault.process_report(address(strategy));

        // Check updated strategy params
        strategyParams = vault.strategies(address(strategy));
        assertEq(strategyParams.currentDebt, initialDebt + gain);
        assertEq(strategyParams.lastReport, snapshotTimestamp);
    }

    function testProcessReportWithGainAndZeroManagementFees() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 gain = newDebt / 2;
        uint256 managementFee = 0;
        uint256 performanceFee = 5000; // 50% performance fee
        // 1 percent of gain
        uint256 totalFee = (gain * performanceFee) / 10000;
        uint256 refundRatio = 0;

        // Deploy accountant
        MockAccountant accountant = deployAccountant();

        // update protocol fee config
        vaultFactory.setProtocolFeeRecipient(address(accountant));
        vaultFactory.setProtocolFeeBps(uint16(managementFee));

        // Add debt to strategy
        addDebtToStrategy(address(strategy), newDebt);

        // Airdrop gain to strategy
        airdropAsset(address(strategy), gain);

        // Record gain
        strategy.report();

        // Set fees for strategy
        setFeesForStrategy(accountant, address(strategy), managementFee, performanceFee, refundRatio);

        // Get initial debt
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(strategy));
        uint256 initialDebt = strategyParams.currentDebt;

        // Process report
        uint256 snapshotTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), gain, 0, initialDebt + gain, 0, totalFee, 0);
        vault.process_report(address(strategy));

        // Check updated strategy params
        strategyParams = vault.strategies(address(strategy));
        assertEq(strategyParams.currentDebt, initialDebt + gain);
        assertEq(strategyParams.lastReport, snapshotTimestamp);

        // Skip ahead to unlock profits
        skip(14 days);

        // Check accountant balance
        uint256 accountantBalance = vault.balanceOf(address(accountant));
        // get current price of asset
        uint256 currentPrice = vault.convertToAssets(1e18);
        uint256 expectedBalance = (totalFee * currentPrice) / 1e18;
        assertApproxEqRel(vault.convertToAssets(accountantBalance), expectedBalance, 1e13); // 1e-5 relative tolerance
    }

    function testProcessReportWithGainAndZeroPerformanceFees() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 gain = newDebt / 2;

        // Add debt to strategy
        addDebtToStrategy(address(strategy), newDebt);

        // Airdrop gain to strategy
        airdropAsset(address(strategy), gain);

        // Record gain
        strategy.report();

        // Get initial debt
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(strategy));
        uint256 initialDebt = strategyParams.currentDebt;

        // Process report
        uint256 snapshotTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), gain, 0, initialDebt + gain, 0, 0, 0);
        vault.process_report(address(strategy));

        // Check updated strategy params
        strategyParams = vault.strategies(address(strategy));
        assertEq(strategyParams.currentDebt, initialDebt + gain);
        assertEq(strategyParams.lastReport, snapshotTimestamp);
    }

    function testProcessReportWithLoss() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 loss = newDebt / 2;

        // Add debt to strategy
        addDebtToStrategy(address(strategy), newDebt);

        // Simulate a loss by removing funds from the strategy
        strategy.simulateLoss(loss);

        // Record loss
        strategy.report();

        // Get initial debt
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(strategy));
        uint256 initialDebt = strategyParams.currentDebt;

        // Process report
        uint256 snapshotTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), 0, loss, initialDebt - loss, 0, 0, 0);
        vault.process_report(address(strategy));

        // Check updated strategy params
        strategyParams = vault.strategies(address(strategy));
        assertEq(strategyParams.currentDebt, initialDebt - loss);
        assertEq(strategyParams.lastReport, snapshotTimestamp);

        // Check price per share has been reduced by half
        assertApproxEqRel(vault.pricePerShare(), 10 ** vault.decimals() / 2, 1e13);
    }

    function testProcessReportWithLossAndRefunds() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 loss = newDebt / 2;
        uint256 refundRatio = 10000; // 100% refund

        // Deploy accountant
        MockAccountant accountant = deployAccountant();

        // Add debt to strategy
        addDebtToStrategy(address(strategy), newDebt);

        // Simulate a loss by removing funds from the strategy
        strategy.simulateLoss(loss);

        // Set up refund - mint assets to the accountant
        airdropAsset(address(accountant), loss);

        // Set fees with refund ratio
        setFeesForStrategy(accountant, address(strategy), 0, 0, refundRatio);

        // Record loss
        strategy.report();

        // Get initial values
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(strategy));
        uint256 initialDebt = strategyParams.currentDebt;
        uint256 ppsBeforeLoss = vault.pricePerShare();
        uint256 assetsBeforeLoss = vault.totalAssets();
        uint256 supplyBeforeLoss = vault.totalSupply();

        // Process report
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), 0, loss, initialDebt - loss, 0, 0, loss);
        vault.process_report(address(strategy));

        // Due to refunds, these values should remain unchanged
        assertEq(vault.pricePerShare(), ppsBeforeLoss);
        assertEq(vault.totalAssets(), assetsBeforeLoss);
        assertEq(vault.totalSupply(), supplyBeforeLoss);

        // But debt and idle balance should reflect the loss and refund
        assertEq(vault.totalDebt(), newDebt - loss);
        assertEq(vault.totalIdle(), loss);
    }

    function testProcessReportWithLossAndRefundsNotEnoughAsset() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 loss = newDebt / 2;
        uint256 managementFee = 0;
        uint256 performanceFee = 0;
        uint256 refundRatio = 10000; // 100% refund

        // Deploy accountant with only half the needed refund amount
        MockAccountant accountant = deployAccountant();
        uint256 actualRefund = loss / 2;
        airdropAsset(address(accountant), actualRefund);

        // Create a lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(lossyStrategy), true);
        vault.update_max_debt_for_strategy(address(lossyStrategy), type(uint256).max);

        // Set fees with refund ratio
        setFeesForStrategy(accountant, address(lossyStrategy), managementFee, performanceFee, refundRatio);

        // Add debt to strategy
        addDebtToStrategy(address(lossyStrategy), newDebt);

        // Set loss on the strategy
        lossyStrategy.setLoss(loss);

        // Report the loss
        lossyStrategy.report();

        // Get initial values
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(lossyStrategy));
        uint256 initialDebt = strategyParams.currentDebt;
        uint256 ppsBeforeLoss = vault.pricePerShare();
        uint256 assetsBeforeLoss = vault.totalAssets();
        uint256 supplyBeforeLoss = vault.totalSupply();

        // Process report
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(
            address(lossyStrategy),
            0,
            loss,
            initialDebt - loss,
            0,
            0,
            actualRefund
        );
        vault.process_report(address(lossyStrategy));

        // Check the vault state after partial refund
        assertLt(vault.pricePerShare(), ppsBeforeLoss);
        assertEq(vault.totalAssets(), assetsBeforeLoss - (loss - actualRefund));
        assertEq(vault.totalSupply(), supplyBeforeLoss);
        assertEq(vault.totalDebt(), newDebt - loss);
        assertEq(vault.totalIdle(), actualRefund);
    }

    function testProcessReportWithLossAndRefundsNotEnoughAllowance() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;
        uint256 loss = newDebt / 2;
        uint256 managementFee = 0;
        uint256 performanceFee = 0;
        uint256 refundRatio = 10000; // 100% refund

        // Deploy faulty accountant (doesn't approve tokens)
        MockFaultyAccountant accountant = new MockFaultyAccountant(address(asset));
        vault.set_accountant(address(accountant));

        // Mint enough assets for full refund
        airdropAsset(address(accountant), loss);

        // But only approve half
        uint256 actualRefund = loss / 2;
        vm.startPrank(address(accountant));
        asset.approve(address(vault), actualRefund);
        vm.stopPrank();

        // Create a lossy strategy
        MockLossyStrategy lossyStrategy = new MockLossyStrategy(address(asset), address(vault));
        vault.add_strategy(address(lossyStrategy), true);
        vault.update_max_debt_for_strategy(address(lossyStrategy), type(uint256).max);

        // Set fees with refund ratio
        accountant.setFees(address(lossyStrategy), managementFee, performanceFee, refundRatio);

        // Add debt to strategy
        addDebtToStrategy(address(lossyStrategy), newDebt);

        // Set loss on the strategy
        lossyStrategy.setLoss(loss);

        // Report the loss
        lossyStrategy.report();

        // Get initial values
        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(lossyStrategy));
        uint256 initialDebt = strategyParams.currentDebt;
        uint256 ppsBeforeLoss = vault.pricePerShare();
        uint256 assetsBeforeLoss = vault.totalAssets();
        uint256 supplyBeforeLoss = vault.totalSupply();

        // Process report
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(
            address(lossyStrategy),
            0,
            loss,
            initialDebt - loss,
            0,
            0,
            actualRefund
        );
        vault.process_report(address(lossyStrategy));

        // Check the vault state after partial refund due to limited allowance
        assertLt(vault.pricePerShare(), ppsBeforeLoss);
        assertEq(vault.totalAssets(), assetsBeforeLoss - (loss - actualRefund));
        assertEq(vault.totalSupply(), supplyBeforeLoss);
        assertEq(vault.totalDebt(), newDebt - loss);
        assertEq(vault.totalIdle(), actualRefund);
    }

    function testSetAccountantWithAccountant() public {
        // Deploy a new accountant
        MockAccountant accountant = new MockAccountant(address(asset));

        // Set the accountant in the vault
        vault.set_accountant(address(accountant));

        // Verify the accountant was set
        assertEq(vault.accountant(), address(accountant));
    }

    function testProcessReportOnSelfGainAndRefunds() public {
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 gain = vaultBalance / 10;
        uint256 managementFee = 0;
        uint256 performanceFee = 0;
        uint256 refundRatio = 5000; // 50% refund
        uint256 refund = (gain * refundRatio) / 1e4;

        // Deploy flexible accountant
        MockFlexibleAccountant accountant = new MockFlexibleAccountant(address(asset));
        vault.set_accountant(address(accountant));

        // Mint assets to the accountant for refunds
        airdropAsset(address(accountant), gain);

        // Set fees with refund ratio for the vault itself
        accountant.setFees(address(vault), managementFee, performanceFee, refundRatio);

        // Get initial values
        uint256 initialIdle = vault.totalIdle();

        // Airdrop gain to the vault (not yet recorded)
        airdropAsset(address(vault), gain);

        // Verify the vault state before processing
        assertEq(vault.totalIdle(), initialIdle);
        assertEq(asset.balanceOf(address(vault)), initialIdle + gain);

        uint256 ppsBeforeReport = vault.pricePerShare();
        uint256 supplyBeforeReport = vault.totalSupply();

        // Process report on vault itself
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(vault), gain, 0, vaultBalance + gain + refund, 0, 0, refund);
        vault.process_report(address(vault));

        // Verify the vault state after processing
        assertEq(vault.pricePerShare(), ppsBeforeReport);
        assertEq(vault.totalAssets(), vaultBalance + gain + refund);
        assertGt(vault.totalSupply(), supplyBeforeReport);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalIdle(), vaultBalance + gain + refund);
        assertEq(asset.balanceOf(address(vault)), vaultBalance + gain + refund);

        // Skip ahead and verify share price increases
        skip(DAY);
        assertGt(vault.pricePerShare(), ppsBeforeReport);
    }

    function testProcessReportOnSelfLossAndRefunds() public {
        TestVars memory vars;
        vars.vaultBalance = asset.balanceOf(address(vault));
        vars.gain = 0;
        vars.loss = vars.vaultBalance / 10;
        vars.managementFee = 0;
        vars.performanceFee = 0;
        vars.refundRatio = 5000; // 50% refund
        vars.refund = (vars.loss * vars.refundRatio) / 10000;

        // Deploy flexible accountant
        MockFlexibleAccountant accountant = new MockFlexibleAccountant(address(asset));
        vault.set_accountant(address(accountant));

        // Mint assets to the accountant for refunds
        airdropAsset(address(accountant), vars.loss);

        // Set fees with refund ratio for the vault itself
        accountant.setFees(address(vault), vars.managementFee, vars.performanceFee, vars.refundRatio);

        // Get initial values
        vars.initialIdle = vault.totalIdle();

        // Simulate loss in the vault (transfer out funds)
        vm.startPrank(address(vault));
        asset.transfer(gov, vars.loss);
        vm.stopPrank();

        // Verify the vault state before processing
        assertEq(vault.totalIdle(), vars.initialIdle);
        assertEq(asset.balanceOf(address(vault)), vars.initialIdle - vars.loss);

        vars.ppsBeforeReport = vault.pricePerShare();
        vars.supplyBeforeReport = vault.totalSupply();

        // Calculate expected current debt for event
        uint256 expectedCurrentDebt = vars.vaultBalance + vars.refund - vars.loss;

        // Process report on vault itself
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(
            address(vault),
            vars.gain,
            vars.loss,
            expectedCurrentDebt,
            0,
            0,
            vars.refund
        );
        vault.process_report(address(vault));

        // Price per share should decrease after loss
        assertLt(vault.pricePerShare(), vars.ppsBeforeReport);

        // Verify the updated values
        assertEq(vault.totalAssets(), vars.vaultBalance + vars.refund - vars.loss);
        assertEq(vault.totalSupply(), vars.supplyBeforeReport);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalIdle(), vars.vaultBalance + vars.refund - vars.loss);
        assertEq(asset.balanceOf(address(vault)), vars.vaultBalance + vars.refund - vars.loss);
    }
}
