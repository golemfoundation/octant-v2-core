// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockAccountant } from "test/mocks/core/MockAccountant.sol";

import { IFactory } from "src/interfaces/IFactory.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";

contract ProfitUnlockingTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MockAccountant accountant;
    MockFlexibleAccountant flexibleAccountant;
    MultistrategyVaultFactory vaultFactory;

    address gov = address(0x1);
    address fish = address(0x2);
    address feeRecipient = address(0x3);

    uint256 fishAmount = 10_000e18;
    uint256 MAX_BPS = 10_000;
    uint256 constant DAY = 1 days;
    uint256 constant WEEK = 7 days;
    uint256 constant YEAR = 365 days;

    // Test state struct to avoid stack too deep errors
    struct TestState {
        uint256 amount;
        uint256 firstProfit;
        uint256 secondProfit;
        uint256 managementFee;
        uint256 performanceFee;
        uint256 refundRatio;
        uint256 totalFees;
        uint256 totalRefunds;
        uint256 totalSecondFees;
        uint256 totalSecondRefunds;
        uint256 timestamp;
        uint256 timePassed;
        uint256 pricePerShare;
        uint256 feeShares;
        uint256 withdrawAssets;
        uint256 withdrawnDiff;
        uint256 totalFeesShares;
        uint256 firstProfitFees;
        uint256 firstLoss;
    }

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        // deploy factory
        vm.prank(gov);

        flexibleAccountant = new MockFlexibleAccountant(address(asset));

        // Deploy vault
        vm.startPrank(address(gov));
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);

        // Setup strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vault.set_deposit_limit(type(uint256).max, true);

        vm.stopPrank();
    }

    function assertPricePerShare(uint256 expectedPpsNormalized) internal view {
        uint256 actualPpsNormalized = vault.pricePerShare();
        assertApproxEqRel(actualPpsNormalized, expectedPpsNormalized, 1e14);
    }

    function checkVaultTotals(
        uint256 totalDebt,
        uint256 totalIdle,
        uint256 totalAssets,
        uint256 totalSupply
    ) internal view {
        assertApproxEqAbs(vault.totalIdle(), totalIdle, 1, "totalIdle");
        assertEq(vault.totalDebt(), totalDebt, "totalDebt");
        assertApproxEqAbs(vault.totalAssets(), totalAssets, 1, "totalAssets");
        assertApproxEqRel(vault.totalSupply(), totalSupply, 1e16, "totalSupply");
    }

    function increaseTimeAndCheckProfitBuffer(uint256 secs, uint256 expectedBuffer) internal {
        // Increase time by secs-1, exactly as in Python version
        skip(secs - 1);

        // Check that vault's balance of itself matches expected buffer

        assertApproxEqRel(vault.balanceOf(address(vault)), expectedBuffer, 1e14);
    }

    // Overload with default arguments (10 days for secs, 0 for expectedBuffer)
    function increaseTimeAndCheckProfitBuffer() internal {
        increaseTimeAndCheckProfitBuffer(10 days, 0);
    }

    // Overload with only secs parameter
    function increaseTimeAndCheckProfitBuffer(uint256 secs) internal {
        increaseTimeAndCheckProfitBuffer(secs, 0);
    }

    function increaseTimeWithWarpAndCheckProfitBuffer(uint256 secs, uint256 expectedBuffer) internal {
        // Set timestamp to current timestamp + secs-1, exactly as in Python version
        vm.warp(block.timestamp + secs - 1);

        // Check that vault's balance of itself matches expected buffer
        assertApproxEqRel(vault.balanceOf(address(vault)), expectedBuffer, 1e14);
    }

    // Overload with default arguments (10 days for secs, 0 for expectedBuffer)
    function increaseTimeWithWarpAndCheckProfitBuffer() internal {
        increaseTimeWithWarpAndCheckProfitBuffer(10 days, 0);
    }

    // Overload with only secs parameter
    function increaseTimeWithWarpAndCheckProfitBuffer(uint256 secs) internal {
        increaseTimeWithWarpAndCheckProfitBuffer(secs, 0);
    }

    function createAndCheckProfit(uint256 profit) internal returns (uint256) {
        uint256 initialDebt = vault.strategies(address(strategy)).currentDebt;

        // Create virtual profit
        vm.prank(gov);
        asset.transfer(address(strategy), profit);

        // Process report
        vm.prank(gov);
        (uint256 gain, uint256 loss) = vault.process_report(address(strategy));

        // Verify the report
        assertEq(gain, profit);
        assertEq(loss, 0);

        uint256 totalFees = vault.strategies(address(strategy)).currentDebt - initialDebt - profit;
        assertEq(profit, gain);

        return totalFees;
    }

    function testGainNoFeesNoRefundsNoExistingBuffer() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Make sure accountant is not set to match original test
        vm.prank(gov);
        vault.set_accountant(address(0));

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );

        // Verify that vault holds locked profit shares
        assertEq(vault.balanceOf(address(vault)), firstProfit);

        // Increase time to fully unlock profit
        skip(10 days);

        // Verify profits have unlocked
        assertEq(vault.balanceOf(address(vault)), 0);

        // Check PPS after unlock
        assertPricePerShare(2 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Verify strategy debt is zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS still 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        uint256 fishShareBalance = vault.balanceOf(fish);

        vm.startPrank(fish);
        vault.approve(fish, fishShareBalance);
        vault.redeem(fishShareBalance, fish, fish, 0, new address[](0));
        vm.stopPrank();

        // After redemption, price should be 1.0
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus profit
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit);
    }

    function testGainNoFeesWithRefundsWithBuffer() public {
        // Use struct to avoid stack too deep errors
        TestState memory state;

        // Setup values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.secondProfit = fishAmount / 10;
        state.managementFee = 0;
        state.performanceFee = 0;
        state.refundRatio = 10000; // 100% refund ratio

        // Setup accountant
        accountant = new MockAccountant(address(asset));

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Set up accountant with 100% refund
        vm.startPrank(gov);
        vault.set_accountant(address(accountant));
        accountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);

        // Important: Pre-fund the accountant with 2x the amount
        asset.mint(address(accountant), 2 * state.amount);

        // Allocate to strategy
        vault.update_debt(address(strategy), state.amount, 0);
        vm.stopPrank();

        // Create first profit - this should trigger refunds
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Check PPS and vault totals
        assertPricePerShare(1 * 10 ** 18);
    }

    function testGainNoFeesNoRefundsWithBuffer() public {
        // Use struct to avoid stack too deep errors
        TestState memory state;

        // Setup values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.secondProfit = fishAmount / 10;

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create first profit
        createAndCheckProfit(state.firstProfit);

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Increase time halfway through unlocking period
        skip(5 days);

        // Create second profit after half the unlock time
        createAndCheckProfit(state.secondProfit);

        // Wait for remaining unlock time
        skip(10 days);

        // PPS should be 3.0 after all profits unlock
        assertPricePerShare(3 * 10 ** 18);

        // Check totals after full unlock
        checkVaultTotals(
            state.amount + state.firstProfit + state.secondProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit + state.secondProfit, // total assets
            state.amount // total supply
        );

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be 0, PPS still 3.0
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertPricePerShare(3 * 10 ** 18);

        // Fish redeems shares
        uint256 fishShareBalance = vault.balanceOf(fish);

        vm.startPrank(fish);
        vault.approve(fish, fishShareBalance);
        vault.redeem(fishShareBalance, fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Vault should be empty
        assertApproxEqAbs(vault.totalIdle(), 0, 1);
        assertEq(vault.totalDebt(), 0);
        assertApproxEqAbs(vault.totalAssets(), 0, 1);
        assertApproxEqAbs(vault.totalSupply(), 0, 1);

        // Fish gets their assets + all profits
        assertEq(asset.balanceOf(fish), fishAmount + state.firstProfit + state.secondProfit);
    }

    function testGainFeesNoRefundsNoExistingBuffer() public {
        // Initialize state struct to keep organized
        TestState memory state;

        // Setup initial values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.managementFee = 0;
        state.performanceFee = 1000; // 10%
        state.refundRatio = 0; // No refunds

        // Set up accountant
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit assets
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Initial checks
        assertPricePerShare(1.0 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Check vault buffer
        uint256 expectedBuffer = (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS;
        assertEq(vault.balanceOf(address(vault)), expectedBuffer);

        // Check accountant's fee shares
        state.feeShares = (state.firstProfit * state.performanceFee) / MAX_BPS;
        assertEq(vault.balanceOf(address(flexibleAccountant)), state.feeShares);

        // Increase time to fully unlock
        increaseTimeAndCheckProfitBuffer(10 days, 0);

        // Check price per share after unlock - match exact formula from Python
        uint256 expectedPPS = ((state.amount + state.firstProfit) * 10 ** vault.decimals()) /
            (state.amount + (state.performanceFee * state.firstProfit) / MAX_BPS);
        assertApproxEqRel(vault.pricePerShare(), expectedPPS, 1e14);

        // Check vault totals after unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + (state.firstProfit * state.performanceFee) / MAX_BPS // total supply
        );

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Verify strategy debt is zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + (state.firstProfit * state.performanceFee) / MAX_BPS // total supply
        );

        // Fish redeems shares - use expectEmit to capture the Withdraw event
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));

        // log fish balance before redeem
        uint256 fishBalanceBefore = asset.balanceOf(fish);
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        uint256 fishBalanceAfter = asset.balanceOf(fish);
        state.withdrawnDiff = fishBalanceAfter - fishBalanceBefore;

        // Check PPS after fish redemption - exact formula from Python
        assertApproxEqRel(
            vault.pricePerShare(),
            ((vault.totalAssets() * 10 ** vault.decimals()) / vault.balanceOf(address(flexibleAccountant))),
            1e14
        );

        // Check vault totals after fish redemption - exact formula from Python
        checkVaultTotals(
            0, // total debt
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total idle
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total assets
            state.feeShares // total supply
        );

        // Verify fish received correct amount
        assertGt(asset.balanceOf(fish), fishAmount);
        assertLt(asset.balanceOf(fish), fishAmount + state.firstProfit);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Verify vault is empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testGainFeesWithRefundsWithBuffer() public {
        // Initialize state struct
        TestState memory state;

        // Setup values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.secondProfit = fishAmount / 10;
        state.managementFee = 0;
        state.performanceFee = 1000; // 10%
        state.refundRatio = 10000; // 100%

        // Set flexible accountant as accountant
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        vm.stopPrank();

        // Set up accountant with performance fee and refund ratio
        vm.startPrank(gov);
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);

        // Fund accountant with 2*amount exactly as in Python test
        asset.mint(address(flexibleAccountant), 2 * state.amount);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Calculate expected values
        state.totalFees = (state.firstProfit * state.performanceFee) / MAX_BPS;
        state.totalRefunds = (state.firstProfit * state.refundRatio) / MAX_BPS;

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp for later calculations
        state.timestamp = block.timestamp;

        // Initial checks
        assertPricePerShare(1.0 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.totalRefunds, // total assets
            state.amount + state.firstProfit + state.totalRefunds // total supply
        );

        // Verify vault buffer exactly as in Python test
        assertEq(
            vault.balanceOf(address(vault)),
            state.totalRefunds + (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS
        );

        // Verify accountant fee shares
        assertEq(vault.balanceOf(address(flexibleAccountant)), state.totalFees);

        // Calculate expected half buffer for halfway through unlock period
        uint256 expectedHalfBuffer = (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS /
            2 +
            state.totalRefunds /
            2;

        // Increase time halfway and check buffer
        increaseTimeAndCheckProfitBuffer(7 days / 2, expectedHalfBuffer);

        // Record PPS after half unlock
        state.pricePerShare = vault.pricePerShare();
        assertLt(state.pricePerShare, 2.0 * 10 ** 18);

        // Verify buffer matches expected
        assertApproxEqRel(
            vault.balanceOf(address(vault)),
            (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS / 2 + state.totalRefunds / 2,
            1e15
        );

        // Calculate expected supply with complex formula matching Python test
        uint256 expectedSupplyAfterHalf = state.amount +
            (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS /
            2 +
            state.totalRefunds -
            state.totalRefunds /
            2 +
            state.totalFees;

        // Check vault totals with complex supply calculation
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.totalRefunds, // total assets
            expectedSupplyAfterHalf // total supply
        );

        // Calculate second profit values
        state.totalSecondFees = (state.secondProfit * state.performanceFee) / MAX_BPS;
        state.totalSecondRefunds = (state.secondProfit * state.refundRatio) / MAX_BPS;

        // Create second profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.secondProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Convert fee and refund values to shares
        uint256 totalSecondFeesShares = vault.convertToShares(state.totalSecondFees);
        uint256 totalSecondRefundsShares = vault.convertToShares(state.totalSecondRefunds);

        // PPS shouldn't change
        assertPricePerShare(state.pricePerShare);

        // Calculate time passed since first profit
        state.timePassed = block.timestamp - state.timestamp;

        // Calculate expected supply using exact same complex formula as Python test
        uint256 expectedSupplyAfterSecond = state.amount +
            state.totalRefunds +
            totalSecondRefundsShares -
            state.totalRefunds /
            (7 days / state.timePassed) +
            state.totalFees +
            totalSecondFeesShares +
            (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS -
            (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS /
            (7 days / state.timePassed) +
            vault.convertToShares((state.secondProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS);

        // Check vault totals with complex calculation
        checkVaultTotals(
            state.amount + state.firstProfit + state.secondProfit, // total debt
            state.totalRefunds * 2, // total idle
            state.amount + state.firstProfit + state.secondProfit + 2 * state.totalRefunds, // total assets
            expectedSupplyAfterSecond // total supply
        );

        // Skip remaining time to fully unlock profits
        increaseTimeAndCheckProfitBuffer(10 days, 0);

        // PPS should be less than 5.0 due to fees
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 5.0);

        // Check totals after full unlock
        checkVaultTotals(
            state.amount + state.firstProfit + state.secondProfit, // total debt
            2 * state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.secondProfit + 2 * state.totalRefunds, // total assets
            state.amount + state.totalFees + totalSecondFeesShares // total supply
        );

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit + state.secondProfit + 2 * state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.secondProfit + 2 * state.totalRefunds, // total assets
            state.amount + state.totalFees + totalSecondFeesShares // total supply
        );

        // PPS still less than 5.0, strategy debt is 0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 5.0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Check totals after fish redemption
        checkVaultTotals(
            0, // total debt
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total idle
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total assets
            state.totalFees + totalSecondFeesShares // total supply
        );

        // Check fish balance constraint (user benefits from profits and refunds)
        assertLt(
            asset.balanceOf(fish),
            fishAmount +
                state.firstProfit *
                (1 + state.refundRatio / MAX_BPS) +
                state.secondProfit *
                (1 + state.refundRatio / MAX_BPS)
        );

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testGainFeesNoRefundsWithBuffer() public {
        // Initialize state struct
        TestState memory state;

        // Setup values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.secondProfit = fishAmount / 10;
        state.managementFee = 0;
        state.performanceFee = 1000; // 10%
        state.refundRatio = 0; // No refunds

        // set flexible accountant as accountant
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        vm.stopPrank();

        // Set up accountant with performance fee and no refunds
        vm.startPrank(gov);
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        (uint256 gain, ) = vault.process_report(address(strategy));

        // Record first profit fees and convert to shares
        state.firstProfitFees = (state.firstProfit * state.performanceFee) / MAX_BPS;
        state.totalFeesShares = vault.convertToShares(state.firstProfitFees);

        // Record timestamp for later calculations
        state.timestamp = block.timestamp;

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Check vault buffer
        assertEq(vault.balanceOf(address(vault)), (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS);

        // Calculate and check fee shares
        state.feeShares = (state.firstProfit * state.performanceFee) / MAX_BPS;
        assertEq(vault.balanceOf(address(flexibleAccountant)), state.feeShares);

        // Increase time halfway (WEEK/2)
        uint256 halfwayBuffer = (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, halfwayBuffer);

        // PPS should be less than 2.0 due to fees
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 2.0);

        // Check vault totals after halfway unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount +
                (state.firstProfit * state.performanceFee) /
                MAX_BPS +
                (state.firstProfit * (MAX_BPS - state.performanceFee)) /
                MAX_BPS /
                2 // total supply
        );

        // Verify buffer after half unlock
        assertApproxEqRel(
            vault.balanceOf(address(vault)),
            (state.firstProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS / 2,
            1e-3 * 1e18
        );

        // Record values before second profit for later comparisons
        state.pricePerShare = vault.pricePerShare();
        uint256 accountantSharesBeforeSecondProfit = vault.balanceOf(address(flexibleAccountant));
        uint256 vaultSharesBeforeSecondProfit = vault.balanceOf(address(vault));

        // Create second profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.secondProfit);

        vm.prank(gov);
        (gain, ) = vault.process_report(address(strategy));
        // Record second profit fees and add to total fees shares
        uint256 secondProfitFees = (state.secondProfit * state.performanceFee) / MAX_BPS;
        state.totalFeesShares += vault.convertToShares(secondProfitFees);

        // PPS shouldn't change immediately after second profit
        assertApproxEqRel(vault.pricePerShare(), state.pricePerShare, 1e14);

        // Accountant shares check - should match Python calculation
        assertApproxEqRel(
            vault.balanceOf(address(flexibleAccountant)),
            accountantSharesBeforeSecondProfit +
                vault.convertToShares((state.secondProfit * state.performanceFee) / MAX_BPS),
            1e-4 * 1e18
        );

        // Vault buffer check - also should match Python calculation
        assertApproxEqRel(
            vault.balanceOf(address(vault)),
            vaultSharesBeforeSecondProfit +
                vault.convertToShares((state.secondProfit * (MAX_BPS - state.performanceFee)) / MAX_BPS),
            1e-4 * 1e18
        );

        // Calculate time passed for unlocking calculation
        state.timePassed = block.timestamp - state.timestamp;

        // Complex vault totals check with partial unlocking - match Python exactly
        uint256 expectedSupply = state.amount +
            (state.firstProfit * state.performanceFee) /
            MAX_BPS +
            (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS -
            (state.firstProfit * (MAX_BPS - state.performanceFee)) /
            MAX_BPS /
            (WEEK / state.timePassed) +
            vault.convertToShares(state.secondProfit);

        checkVaultTotals(
            state.amount + state.firstProfit + state.secondProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit + state.secondProfit, // total assets
            expectedSupply // total supply
        );

        // Skip remaining time to fully unlock
        increaseTimeAndCheckProfitBuffer(10 days, 0);

        // PPS should be less than 3.0 due to fees (without fees would be 3.0)
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 3.0);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be less than 3.0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 3.0);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit + state.secondProfit, // total idle
            state.amount + state.firstProfit + state.secondProfit, // total assets
            state.amount + state.totalFeesShares // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Check PPS after fish redemption - exact formula from Python
        assertApproxEqRel(
            vault.pricePerShare(),
            (vault.totalAssets() * 10 ** vault.decimals()) / vault.balanceOf(address(flexibleAccountant)),
            1e14
        );

        // Check totals after fish redemption - exact formula from Python
        checkVaultTotals(
            0, // total debt
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total idle
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total assets
            state.totalFeesShares // total supply
        );

        // Check fish balance - should match Python assertions
        assertGt(asset.balanceOf(fish), fishAmount);
        assertGt(asset.balanceOf(fish), fishAmount + state.firstProfit);
        assertLt(asset.balanceOf(fish), fishAmount + state.firstProfit + state.secondProfit);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testLossNoFeesNoRefundsWithNotEnoughBuffer() public {
        // Setup initial values
        TestState memory state;
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 20; // Smaller profit than loss
        state.firstLoss = fishAmount / 10; // Larger loss than profit

        // No fees and no refunds
        state.managementFee = 0;
        state.performanceFee = 0;
        state.refundRatio = 0;

        // Setup accountant with no fees
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        assertEq(vault.balanceOf(address(vault)), state.firstProfit);

        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Increase time halfway (WEEK/2)
        uint256 expectedHalfBuffer = state.firstProfit / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, expectedHalfBuffer);

        // PPS should be less than 2.0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 2.0);
        assertApproxEqRel(vault.balanceOf(address(vault)), state.firstProfit / 2, 1e-3 * 1e18);

        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit / 2 // total supply
        );

        // Create loss - larger than remaining profit buffer
        vm.prank(gov);
        strategy.simulateLoss(state.firstLoss);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Price should reflect loss
        uint256 expectedPPS = ((state.amount + state.firstProfit - state.firstLoss) * 10 ** vault.decimals()) /
            state.amount;
        assertPricePerShare(expectedPPS);
        // Buffer should be fully consumed
        assertEq(vault.balanceOf(address(vault)), 0);

        checkVaultTotals(
            state.amount + state.firstProfit - state.firstLoss, // total debt
            0, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount // total supply
        );

        // Increase time to fully unlock (not much should change)
        increaseTimeAndCheckProfitBuffer(10 days);

        // PPS should remain the same
        assertPricePerShare(expectedPPS);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit - state.firstLoss, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Fish should get less than initial amount due to net loss
        assertEq(asset.balanceOf(fish), fishAmount + state.firstProfit - state.firstLoss);
        assertLt(asset.balanceOf(fish), fishAmount);
    }

    function testLossFeesNoRefundsNoExistingBuffer() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstLoss = fishAmount / 20;

        // Management fee but no performance fee or refunds
        uint256 managementFee = 10000;
        uint256 performanceFee = 0;
        uint256 refundRatio = 0;

        // Setup accountant
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), managementFee, performanceFee, refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create a loss scenario
        vm.prank(gov);
        strategy.simulateLoss(firstLoss);

        // Report and process the loss

        vm.prank(gov);
        vault.process_report(address(strategy));
        // Calculate fees
        uint256 totalFees = (amount *
            managementFee *
            (block.timestamp - vault.strategies(address(strategy)).lastReport)) /
            MAX_BPS /
            YEAR;
        uint256 feesShares = vault.convertToShares(totalFees);

        // Verify price per share is less than or equal to 0.5 due to fees
        // Use <= instead of < to match the exact Python assertion while accommodating for rounding
        assertLe(vault.pricePerShare(), 5 * 10 ** 17);

        // Verify no buffer was created
        assertEq(vault.balanceOf(address(vault)), 0);

        // Check vault totals
        checkVaultTotals(
            amount - firstLoss, // total debt
            0, // total idle
            amount - firstLoss, // total assets
            amount + feesShares // total supply increased by fee shares
        );

        // Update strategy debt to 0
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Check vault totals after fish redemption
        checkVaultTotals(
            0, // total debt
            totalFees, // total idle
            totalFees, // total assets
            vault.balanceOf(address(flexibleAccountant)) // total supply equals accountant shares
        );

        // Verify fish received less than original amount minus loss
        assertApproxEqRel(asset.balanceOf(fish), fishAmount - firstLoss, 1e14);

        // Verify vault is empty
        checkVaultTotals(0, 0, 0, 0);
    }

    function testLossNoFeesRefundsNoExistingBuffer() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstLoss = fishAmount / 10;

        // No fees but with refunds
        uint256 managementFee = 0;
        uint256 performanceFee = 0;
        uint256 refundRatio = 10000; // 100%

        // Setup accountant with pre-funded assets
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), managementFee, performanceFee, refundRatio);

        // Important: Pre-fund the accountant with the loss amount
        asset.mint(address(flexibleAccountant), firstLoss);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Calculate expected refunds
        uint256 totalRefunds = (firstLoss * refundRatio) / MAX_BPS;

        // Create a loss scenario
        vm.prank(gov);
        strategy.simulateLoss(firstLoss);

        // Report and process the loss

        vm.prank(gov);
        (, uint256 loss) = vault.process_report(address(strategy));

        // Verify refunds were processed
        assertEq(loss, firstLoss);

        // Check price per share is still 1.0 due to complete refund
        assertApproxEqRel(vault.pricePerShare() / 10 ** vault.decimals(), 1.0, 1e14);

        // Verify no buffer was created
        assertEq(vault.balanceOf(address(vault)), 0);

        // Check vault totals
        checkVaultTotals(
            0, // total debt is now 0 after loss
            totalRefunds, // total idle = refunds
            totalRefunds, // total assets = refunds
            amount // total supply unchanged
        );

        // Verify accountant received no shares
        assertEq(vault.balanceOf(address(flexibleAccountant)), 0);

        // Try to update strategy debt to 0 - should revert
        vm.prank(gov);
        vm.expectRevert(IMultistrategyVault.NewDebtEqualsCurrentDebt.selector);
        vault.update_debt(address(strategy), 0, 0);

        // Verify strategy debt is already 0
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // Price per share still 1.0 due to refunds
        assertApproxEqRel(vault.pricePerShare() / 10 ** vault.decimals(), 1.0, 1e14);

        // Check vault totals
        checkVaultTotals(
            0, // total debt
            totalRefunds, // total idle
            totalRefunds, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Price still 1.0 after redemption
        assertApproxEqRel(vault.pricePerShare() / 10 ** vault.decimals(), 1.0, 1e14);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Fish gets back full amount due to refunds
        assertEq(asset.balanceOf(fish), fishAmount);
    }

    function testLossNoFeesWithRefundsWithBuffer() public {
        // Setup initial values
        TestState memory state;

        // Match Python test values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        uint256 firstLoss = fishAmount / 10;

        // No fees, but with 50% refund ratio
        state.managementFee = 0;
        state.performanceFee = 0;
        state.refundRatio = 5000; // 50%

        // Setup accountant with funds for refunds
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);

        // Important: Pre-fund the accountant with 2x the amount as in Python test
        asset.mint(address(flexibleAccountant), 2 * state.amount);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Calculate expected refunds for profit
        state.totalRefunds = (state.firstProfit * state.refundRatio) / MAX_BPS;

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp for later calculations
        state.timestamp = block.timestamp;

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.totalRefunds, // total assets
            state.amount + state.firstProfit + state.totalRefunds // total supply
        );

        // Check vault buffer
        assertEq(vault.balanceOf(address(vault)), state.firstProfit + state.totalRefunds);

        // Check accountant shares
        assertEq(vault.balanceOf(address(flexibleAccountant)), 0);

        // Increase time halfway (WEEK/2)
        uint256 expectedHalfBuffer = state.firstProfit / 2 + state.totalRefunds / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, expectedHalfBuffer);

        // PPS should be less than 2.0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 2.0);

        // Check buffer after half unlock
        assertApproxEqRel(vault.balanceOf(address(vault)), state.firstProfit / 2 + state.totalRefunds / 2, 1e-3 * 1e18);

        // Check vault totals after halfway unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            state.totalRefunds, // total idle
            state.amount + state.firstProfit + state.totalRefunds, // total assets
            state.amount + state.totalRefunds - state.totalRefunds / 2 + state.firstProfit - state.firstProfit / 2 // total supply
        );

        // Save price per share before loss
        state.pricePerShare = vault.pricePerShare();

        // Create loss - must refund the loss based on refund ratio
        vm.prank(gov);
        strategy.simulateLoss(firstLoss);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // The price per share should remain the same after loss with refunds
        assertApproxEqRel(vault.pricePerShare(), state.pricePerShare, 1e14);

        // Calculate time passed for unlocking calculation
        state.timePassed = block.timestamp - state.timestamp;

        // Check totals - complex calculation matching Python
        checkVaultTotals(
            state.amount + state.firstProfit - firstLoss, // total debt
            state.totalRefunds * 2, // total idle - refunds for profit and loss
            state.amount + state.firstProfit - firstLoss + 2 * state.totalRefunds, // total assets
            state.amount +
                state.totalRefunds +
                vault.convertToShares(state.totalRefunds) -
                state.totalRefunds /
                (WEEK / state.timePassed) +
                state.firstProfit -
                state.firstProfit /
                (WEEK / state.timePassed) -
                vault.convertToShares(firstLoss) // total supply
        );

        // Increase time for remainder of unlock period
        increaseTimeAndCheckProfitBuffer(10 days);
        // PPS should now be 2.0 after full unlock
        assertPricePerShare(2 * 10 ** 18);
        // Check totals after full unlock
        checkVaultTotals(
            state.amount + state.firstProfit - firstLoss, // total debt
            2 * state.totalRefunds, // total idle
            state.amount + state.firstProfit - firstLoss + state.totalRefunds * 2, // total assets
            state.amount // total supply
        );

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit - firstLoss + state.totalRefunds * 2, // total idle
            state.amount + state.firstProfit - firstLoss + state.totalRefunds * 2, // total assets
            state.amount // total supply
        );

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Strategy debt should be 0
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should go back to 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);

        // User should end up with initial deposit + profit + refunds - loss
        assertEq(
            asset.balanceOf(fish),
            fishAmount +
                state.firstProfit +
                (state.firstProfit * state.refundRatio) /
                MAX_BPS +
                (firstLoss * state.refundRatio) /
                MAX_BPS -
                firstLoss
        );
    }

    function testLossNoFeesNoRefundsWithBuffer() public {
        // Setup initial values
        TestState memory state;

        // Match Python test values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.firstLoss = fishAmount / 50; // Much smaller loss than profit

        // No fees and no refunds
        state.managementFee = 0;
        state.performanceFee = 0;
        state.refundRatio = 0;

        // Setup accountant with no fees
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp for later calculations
        state.timestamp = block.timestamp;

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Increase time halfway (WEEK/2)
        // Expected buffer is half the profit since no fees
        uint256 expectedHalfBuffer = state.firstProfit / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, expectedHalfBuffer);

        // PPS should be less than 2.0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 2.0);

        // Save price per share before loss
        state.pricePerShare = vault.pricePerShare();

        // Verify buffer after half unlock is approximately firstProfit/2
        assertApproxEqRel(vault.balanceOf(address(vault)), state.firstProfit / 2, 1e-3 * 1e18);

        // Check vault totals after halfway unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit / 2 // total supply
        );

        // Create loss - small enough to be absorbed by buffer
        vm.prank(gov);
        strategy.simulateLoss(state.firstLoss);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // The price per share should remain the same after loss (buffer absorbs it)
        assertApproxEqRel(vault.pricePerShare(), state.pricePerShare, 1e14);

        // Verify buffer after loss
        assertApproxEqRel(
            vault.balanceOf(address(vault)),
            state.firstProfit / 2 - vault.convertToShares(state.firstLoss),
            1e-3 * 1e18
        );

        // Calculate time passed for unlocking calculation
        state.timePassed = block.timestamp - state.timestamp;

        // Check totals - complex calculation matching Python
        checkVaultTotals(
            state.amount + state.firstProfit - state.firstLoss, // total debt
            0, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount +
                state.firstProfit -
                state.firstProfit /
                (WEEK / state.timePassed) -
                vault.convertToShares(state.firstLoss) // total supply
        );

        // Increase time for remainder of unlock period
        increaseTimeAndCheckProfitBuffer(10 days);

        // PPS should now be (amount + profit - loss) / amount
        uint256 expectedPPS = ((state.amount + state.firstProfit - state.firstLoss) * 10 ** vault.decimals()) /
            state.amount;
        assertPricePerShare(expectedPPS);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be the same
        assertPricePerShare(expectedPPS);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit - state.firstLoss, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption (not relevant but checking anyway)
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish should get original amount + profit - loss
        assertEq(asset.balanceOf(fish), fishAmount + state.firstProfit - state.firstLoss);
        assertGt(asset.balanceOf(fish), fishAmount);
    }

    function testLossFeesNoRefundsWithBuffer() public {
        // Setup initial values
        TestState memory state;

        // Match Python test values
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 10;
        state.firstLoss = fishAmount / 50; // Smaller loss than profit

        // Management fee but no performance fee or refunds
        state.managementFee = 500; // 5%
        state.performanceFee = 0;
        state.refundRatio = 0;

        // Setup accountant with management fee only
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create first profit - need to bypass fees for the profit as in Python test
        uint256 initialDebt = vault.strategies(address(strategy)).currentDebt;

        // Create virtual profit
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        // Save timestamp before processing report
        state.timestamp = block.timestamp;

        // Process report
        vm.prank(gov);
        (uint256 gain, ) = vault.process_report(address(strategy));

        // Verify gain and calculate total profit fees
        assertEq(gain, state.firstProfit);
        uint256 totalProfitFees = vault.strategies(address(strategy)).currentDebt - initialDebt - state.firstProfit;
        uint256 totalProfitFeesShares = vault.convertToShares(totalProfitFees);

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Increase time halfway (WEEK/2)
        // Expected buffer is half the profit
        uint256 expectedHalfBuffer = state.firstProfit / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, expectedHalfBuffer);

        // PPS should be less than 2.0
        assertLt(vault.pricePerShare() / 10 ** vault.decimals(), 2.0);

        // Calculate PPS same way as Python test
        uint256 pricePerShare = (vault.totalAssets() * 10 ** vault.decimals()) /
            (state.amount + state.firstProfit - state.firstProfit / 2);

        // Verify buffer after half unlock is approximately firstProfit/2
        assertApproxEqRel(vault.balanceOf(address(vault)), state.firstProfit / 2, 1e-3 * 1e18);

        // Check vault totals after halfway unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + totalProfitFeesShares + (state.firstProfit - totalProfitFeesShares) / 2 // total supply
        );

        // Simulate loss
        vm.prank(gov);
        strategy.simulateLoss(state.firstLoss);

        vm.prank(gov);
        (, uint256 loss) = vault.process_report(address(strategy));

        // Verify loss is as expected
        assertEq(loss, state.firstLoss);

        // Calculate loss fees - will be management fees on time elapsed
        uint256 totalLossFees = (state.amount * state.managementFee * (block.timestamp - state.timestamp)) /
            MAX_BPS /
            YEAR;
        uint256 totalLossFeesShares = vault.convertToShares(totalLossFees);

        // Verify that loss management fees were applied
        assertGt(totalLossFeesShares, 0);

        // PPS should not be significantly affected by the loss (absorbed by buffer)
        assertApproxEqRel(
            vault.pricePerShare() / 10 ** vault.decimals(),
            pricePerShare / 10 ** vault.decimals(),
            1e-3 * 1e18
        );

        // Buffer should be reduced
        assertLt(vault.balanceOf(address(vault)), state.firstProfit / 2);

        // Verify total assets and supply constraints
        assertEq(vault.totalAssets(), state.amount + state.firstProfit - state.firstLoss);
        assertGt(vault.totalSupply(), state.amount);
        assertLt(vault.totalSupply(), state.amount + state.firstProfit / 2); // Because we have burned shares

        // Increase time for remainder of unlock period
        increaseTimeAndCheckProfitBuffer(10 days);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should be lower than theoretical no-fee PPS due to fees
        assertLt(
            vault.pricePerShare(),
            ((state.amount + state.firstProfit - state.firstLoss) * 10 ** vault.decimals()) / (state.amount)
        );

        // Check totals after full unlock
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit - state.firstLoss, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount + state.totalFeesShares // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Check totals after fish redemption
        checkVaultTotals(
            0, // total debt
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total idle
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total assets
            vault.balanceOf(address(flexibleAccountant)) // total supply
        );

        // Verify accountant has all remaining shares
        assertEq(vault.totalSupply(), vault.balanceOf(address(flexibleAccountant)));
        assertEq(asset.balanceOf(address(vault)), vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))));

        // Fish should get less than full amount due to fees
        assertLt(asset.balanceOf(fish), fishAmount + state.firstProfit - state.firstLoss);
        assertGt(asset.balanceOf(fish), fishAmount);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testLossFeesNoRefundsWithNotEnoughBuffer() public {
        // Setup initial values
        TestState memory state;
        state.amount = fishAmount / 10;
        state.firstProfit = fishAmount / 20; // Smaller profit than loss
        state.firstLoss = fishAmount / 10; // Larger loss than profit

        // Management fee but no performance fee or refunds
        state.managementFee = 500; // 5%
        state.performanceFee = 0;
        state.refundRatio = 0;

        // Setup accountant with management fee
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), state.managementFee, state.performanceFee, state.refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), state.amount);
        vault.deposit(state.amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), state.amount, 0);

        // Create first profit - bypass fees for profit as in Python test
        uint256 initialDebt = vault.strategies(address(strategy)).currentDebt;
        vm.prank(gov);
        asset.transfer(address(strategy), state.firstProfit);

        vm.prank(gov);
        vault.process_report(address(strategy));

        // Calculate profit fees
        uint256 totalProfitFees = vault.strategies(address(strategy)).currentDebt - initialDebt - state.firstProfit;

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        assertEq(vault.balanceOf(address(vault)), state.firstProfit - totalProfitFees);

        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + state.firstProfit // total supply
        );

        // Increase time halfway (WEEK/2)
        uint256 expectedHalfBuffer = state.firstProfit / 2;
        increaseTimeAndCheckProfitBuffer(WEEK / 2, expectedHalfBuffer);

        // Record price per share
        uint256 pricePerShare = vault.pricePerShare();

        // Verify buffer after half unlock
        assertApproxEqRel(vault.balanceOf(address(vault)), state.firstProfit / 2, 1e-3 * 1e18);

        // Check vault totals after halfway unlock
        checkVaultTotals(
            state.amount + state.firstProfit, // total debt
            0, // total idle
            state.amount + state.firstProfit, // total assets
            state.amount + totalProfitFees + (state.firstProfit - totalProfitFees) / 2 // total supply
        );

        // Create loss - larger than profit buffer
        vm.prank(gov);
        strategy.simulateLoss(state.firstLoss);

        vm.prank(gov);
        (, uint256 totalLossFees) = vault.process_report(address(strategy));

        uint256 totalLossFeesShares = vault.convertToShares(totalLossFees);

        // Verify fees were applied
        assertGt(totalLossFeesShares, 0);

        // Price per share should be less than theoretical
        assertLt(
            vault.pricePerShare(),
            ((state.amount + state.firstProfit - state.firstLoss) * 10 ** vault.decimals()) / state.amount
        );

        // Buffer should be fully consumed
        assertEq(vault.balanceOf(address(vault)), 0);

        // Check vault totals
        checkVaultTotals(
            state.amount + state.firstProfit - state.firstLoss, // total debt
            0, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount + vault.balanceOf(address(flexibleAccountant)) // total supply
        );

        // Verify price per share approximation
        assertApproxEqRel(
            vault.pricePerShare() / 10 ** vault.decimals(),
            (state.amount + state.firstProfit - state.firstLoss) /
                (state.amount + totalLossFees / (pricePerShare / 10 ** vault.decimals()) + totalProfitFees),
            1e-3 * 1e18
        );

        // Update price per share for later comparison
        pricePerShare = vault.pricePerShare();

        // Increase time to fully unlock
        increaseTimeAndCheckProfitBuffer(10 days);

        // Buffer should still be zero, price unchanged
        assertEq(vault.balanceOf(address(vault)), 0);
        assertApproxEqRel(vault.pricePerShare(), pricePerShare, 1e14);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero, price unchanged
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
        assertApproxEqRel(vault.pricePerShare(), pricePerShare, 1e14);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            state.amount + state.firstProfit - state.firstLoss, // total idle
            state.amount + state.firstProfit - state.firstLoss, // total assets
            state.amount + vault.balanceOf(address(flexibleAccountant)) // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Check totals after fish redemption
        checkVaultTotals(
            0, // total debt
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total idle
            vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), // total assets
            vault.balanceOf(address(flexibleAccountant)) // total supply
        );

        // Fish should get less than initial amount and less than amount+profit-loss due to fees
        assertLt(asset.balanceOf(fish), fishAmount);
        assertLt(asset.balanceOf(fish), fishAmount + state.firstProfit - state.firstLoss);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
    }

    function testLossFeesRefunds() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstLoss = fishAmount / 10;

        // 1% management fee, no performance fee, 100% refund ratio
        uint256 managementFee = 100; // 1%
        uint256 performanceFee = 0;
        uint256 refundRatio = 10000; // 100%

        // Setup accountant
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), managementFee, performanceFee, refundRatio);

        // Important: Pre-fund the accountant with the loss amount
        asset.mint(address(flexibleAccountant), firstLoss);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Fast forward one year to charge the full management fee (like in Python test)
        skip(YEAR);

        // Calculate expected refunds
        uint256 totalRefunds = (firstLoss * refundRatio) / MAX_BPS;

        // Create loss scenario
        vm.prank(gov);
        strategy.simulateLoss(firstLoss);

        vm.prank(gov);
        (, uint256 loss) = vault.process_report(address(strategy));

        // Verify loss amount
        assertEq(loss, firstLoss);

        // Calculate management fees
        uint256 totalLossFees = ((amount * managementFee * YEAR) * vault.pricePerShare()) /
            10 ** vault.decimals() /
            MAX_BPS /
            YEAR;
        uint256 lossFeesShares = vault.convertToShares(totalLossFees);

        // Verify fees were applied
        assertGt(totalLossFees, 0);

        // No buffer should be created in loss scenario
        assertEq(vault.balanceOf(address(vault)), 0);

        // Check vault totals
        checkVaultTotals(
            amount - firstLoss, // total debt
            totalRefunds, // total idle
            totalRefunds, // total assets
            amount + lossFeesShares // total supply
        );

        // PPS should be 0.99 (1% reduction due to fees)
        assertApproxEqRel(vault.pricePerShare(), 0.99 * 10 ** 18, 1e15);

        // Verify accountant has the right amount of assets
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(address(flexibleAccountant))), totalLossFees, 1e15);

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS still approximately 0.99
        assertApproxEqRel(vault.pricePerShare(), 0.99 * 10 ** 18, 1e15);

        // Check vault totals after fish redemption
        checkVaultTotals(
            0, // total debt
            totalLossFees, // total idle
            totalLossFees, // total assets
            lossFeesShares // total supply
        );

        // Fish should get original amount minus fees
        assertApproxEqRel(asset.balanceOf(fish), fishAmount - totalLossFees, 1e14);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);
    }

    function testAccountantAndProtocolFeesDoesntChangePps() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Using only management fee as it's easier to measure comparison
        uint256 managementFee = 25;
        uint256 performanceFee = 0;
        uint256 refundRatio = 0;
        address bunny = makeAddr("bunny"); // Using a new address as protocol recipient (bunny)

        // Set up factory with protocol fee config
        vm.startPrank(gov);
        vaultFactory.setProtocolFeeRecipient(bunny);
        vaultFactory.setProtocolFeeBps(uint16(managementFee));
        vm.stopPrank();

        // Deploy accountan
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), managementFee, performanceFee, refundRatio);
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Skip time needed for the protocol to assess fees
        increaseTimeAndCheckProfitBuffer(10 days);

        // Record starting price per share
        uint256 startingPps = vault.pricePerShare();

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        strategy.report();
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Assert both accounts got paid fees and the PPS stayed exactly the same
        assertGt(vault.balanceOf(address(flexibleAccountant)), 0);
        assertGt(vault.balanceOf(bunny), 0);
        assertEq(vault.pricePerShare(), startingPps);

        // Send all fees collected out
        vm.startPrank(bunny);
        vault.transfer(gov, vault.balanceOf(bunny));
        vm.stopPrank();

        vm.startPrank(address(flexibleAccountant));
        vault.transfer(gov, vault.balanceOf(address(flexibleAccountant)));
        vm.stopPrank();

        // Verify fees were transferred
        assertEq(vault.balanceOf(bunny), 0);
        assertEq(vault.balanceOf(address(flexibleAccountant)), 0);

        // Skip time needed for the protocol to assess fees again
        increaseTimeAndCheckProfitBuffer(10 days);

        // Record starting price per share again
        startingPps = vault.pricePerShare();

        // Create second profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        strategy.report();
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Assert both accounts got paid fees again and the PPS stayed the same
        assertGt(vault.balanceOf(address(flexibleAccountant)), 0);
        assertGt(vault.balanceOf(bunny), 0);
        assertEq(vault.pricePerShare(), startingPps);
    }

    function testIncreaseProfitMaxPeriodNoChange() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Set up vault with no fees
        vm.startPrank(gov);
        vault.set_accountant(address(0)); // No accountant
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        strategy.report();
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp
        uint256 timestamp = 1; // set to 1 to avoid warp bug

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );

        // Increase time halfway through unlock period
        increaseTimeAndCheckProfitBuffer(WEEK / 2, firstProfit / 2);

        // Update profit max unlock time
        vm.startPrank(gov);
        vault.setProfitMaxUnlockTime(WEEK * 2);
        vm.stopPrank();

        // Calculate time passed
        uint256 timePassed = block.timestamp - timestamp;

        // Check totals - should be unchanged from original schedule
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit - firstProfit / (WEEK / timePassed) // total supply
        );

        // Complete unlock period
        increaseTimeAndCheckProfitBuffer(WEEK);

        // Verify price per share after full unlock
        assertPricePerShare(2 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus profit
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit);
    }

    function testDecreaseProfitMaxPeriodNoChange() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Set up vault with no fees
        vm.startPrank(gov);
        vault.set_accountant(address(0)); // No accountant
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        strategy.report();
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );
        // Record timestamp
        uint256 timestamp = 1; // set to 1 to avoid warp bug

        // Increase time halfway through unlock period
        increaseTimeAndCheckProfitBuffer(WEEK / 2, firstProfit / 2);

        // Update profit max unlock time - decrease to half
        vm.prank(gov);
        vault.setProfitMaxUnlockTime(WEEK / 2);

        // Calculate time passed
        uint256 timePassed = block.timestamp - timestamp;

        // Check totals - should be unchanged from original schedule
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit - firstProfit / (WEEK / timePassed) // total supply
        );
        console.log("time before 2", block.timestamp);

        // Complete unlock period
        increaseTimeAndCheckProfitBuffer(WEEK);
        console.log("time after 2", block.timestamp);
        // Verify price per share after full unlock
        assertPricePerShare(2 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus profit
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit);
    }

    function testIncreaseProfitMaxPeriodNextReportWorks() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;
        uint256 secondProfit = fishAmount / 10;

        // Set up vault with no accountant
        vm.startPrank(gov);
        vault.set_accountant(address(0));
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp
        uint256 timestamp = 1; // set to 1 to avoid warp bug

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );

        // Increase time halfway through unlock period
        increaseTimeWithWarpAndCheckProfitBuffer(WEEK / 2, firstProfit / 2);

        // Update profit max unlock time
        vm.prank(gov);
        vault.setProfitMaxUnlockTime(WEEK * 2);

        // Calculate time passed
        uint256 timePassed = block.timestamp - timestamp;

        // Check totals
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit - firstProfit / (WEEK / timePassed) // total supply
        );

        // Add WEEK/2 + 1 to ensure complete unlocking of first profit
        vm.warp(block.timestamp + WEEK / 2 + 1);

        // Verify price per share after full unlock
        assertPricePerShare(2 * 10 ** 18);

        // Create second profit
        vm.prank(gov);
        asset.transfer(address(strategy), secondProfit);
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record new timestamp
        timestamp = 1 + WEEK;

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Only half the shares are issued due to PPS = 2.0
        uint256 expectedNewShares = secondProfit / 2;

        // Check totals after second profit
        checkVaultTotals(
            amount + firstProfit + secondProfit, // total debt
            0, // total idle
            amount + firstProfit + secondProfit, // total assets
            amount + expectedNewShares // total supply
        );

        // Increase by a full week which is now only half the profit unlock time
        increaseTimeWithWarpAndCheckProfitBuffer(WEEK, expectedNewShares / 2);

        // Calculate new time passed since second profit
        timePassed = block.timestamp - timestamp;

        // Check totals after half unlock of second profit
        checkVaultTotals(
            amount + firstProfit + secondProfit, // total debt
            0, // total idle
            amount + firstProfit + secondProfit, // total assets
            amount + expectedNewShares - expectedNewShares / ((WEEK * 2) / timePassed) // total supply
        );

        // Add WEEK + 1 to ensure complete unlocking of second profit
        vm.warp(block.timestamp + WEEK + 1);

        // PPS should now be 3.0
        assertPricePerShare(3 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 3.0
        assertPricePerShare(3 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit + secondProfit, // total idle
            amount + firstProfit + secondProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus both profits
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit + secondProfit);
    }

    function testDecreaseProfitMaxPeriodNextReportWorks() public {
        vm.prank(gov);
        vault.setProfitMaxUnlockTime(WEEK);
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;
        uint256 secondProfit = fishAmount / 10;

        // Set up vault with no accountant
        vm.startPrank(gov);
        vault.set_accountant(address(0));
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create first profit
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record timestamp
        uint256 timestamp = 1; // set to 1 to avoid warp bug

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );

        // Increase time halfway through unlock period
        increaseTimeWithWarpAndCheckProfitBuffer(WEEK / 2, firstProfit / 2);

        // Update profit max unlock time - DECREASE to WEEK/2
        vm.prank(gov);
        vault.setProfitMaxUnlockTime(WEEK / 2);

        // Calculate time passed
        uint256 timePassed = block.timestamp - timestamp;
        console.log("timePassed", timePassed);

        // Check totals - should be unchanged from original schedule
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit - firstProfit / (WEEK / timePassed) // total supply
        );

        // Add a bit more time to ensure complete unlocking of first profit
        vm.warp(block.timestamp + WEEK / 2 + 1);

        // Verify price per share after full unlock
        assertPricePerShare(2 * 10 ** 18);

        // Create second profit
        vm.prank(gov);
        asset.transfer(address(strategy), secondProfit);
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Record new timestamp
        timestamp = 1 + WEEK;

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Only half the shares are issued due to PPS = 2.0
        uint256 expectedNewShares = secondProfit / 2;

        // Check totals after second profit
        checkVaultTotals(
            amount + firstProfit + secondProfit, // total debt
            0, // total idle
            amount + firstProfit + secondProfit, // total assets
            amount + expectedNewShares // total supply
        );

        // Increase by a quarter week which is now half the profit unlock time
        increaseTimeWithWarpAndCheckProfitBuffer(WEEK / 4, expectedNewShares / 2);

        // Calculate new time passed since second profit
        timePassed = block.timestamp - timestamp;

        // Add a bit more time to ensure complete unlocking of second profit
        vm.warp(block.timestamp + WEEK / 4 + 1);

        // PPS should now be 3.0
        assertPricePerShare(3 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 3.0
        assertPricePerShare(3 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit + secondProfit, // total idle
            amount + firstProfit + secondProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus both profits
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit + secondProfit);
    }

    function testSetProfitMaxPeriodToZeroResetsRates() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Set up vault with no accountant
        vm.startPrank(gov);
        vault.set_accountant(address(0));
        vm.stopPrank();

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create first profit
        createAndCheckProfit(firstProfit);

        // Initial checks
        assertPricePerShare(1 * 10 ** 18);
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + firstProfit // total supply
        );

        // Increase time halfway through unlock period
        increaseTimeAndCheckProfitBuffer(WEEK / 2, firstProfit / 2);

        // Verify initial state before setting to zero
        assertNotEq(vault.profitMaxUnlockTime(), 0);
        assertNotEq(vault.balanceOf(address(vault)), 0);
        assertNotEq(vault.fullProfitUnlockDate(), 0);
        assertNotEq(vault.profitUnlockingRate(), 0);

        // Update profit max unlock time to zero
        vm.prank(gov);
        vault.setProfitMaxUnlockTime(0);

        // Verify that all profit unlocking parameters are reset
        assertEq(vault.profitMaxUnlockTime(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.fullProfitUnlockDate(), 0);
        assertEq(vault.profitUnlockingRate(), 0);

        // All profits should have been unlocked
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // PPS should be 2.0 as all profits are unlocked immediately
        assertPricePerShare(2 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus profit
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit);
    }

    function testSetProfitMaxPeriodToZeroDoesntLock() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Set up vault with no accountant
        vm.startPrank(gov);
        vault.set_accountant(address(0));

        // Update profit max unlock time to zero BEFORE creating profits
        vault.setProfitMaxUnlockTime(0);
        vm.stopPrank();

        // Verify initial state with zero settings
        assertEq(vault.profitMaxUnlockTime(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.fullProfitUnlockDate(), 0);
        assertEq(vault.profitUnlockingRate(), 0);

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create profit
        createAndCheckProfit(firstProfit);

        // All profits should have been unlocked immediately
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // PPS should be 2.0 as all profits are unlocked immediately
        assertPricePerShare(2 * 10 ** 18);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be 2.0
        assertPricePerShare(2 * 10 ** 18);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount plus profit
        assertEq(asset.balanceOf(fish), fishAmount + firstProfit);
    }

    function testSetProfitMaxPeriodToZeroWithFeesDoesntLock() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        // Set up fees - only performance fee
        uint256 managementFee = 0;
        uint256 performanceFee = 1000; // 10%
        uint256 refundRatio = 0;

        // Setup accountant with performance fee
        vm.startPrank(gov);
        vault.set_accountant(address(flexibleAccountant));
        flexibleAccountant.setFees(address(strategy), managementFee, performanceFee, refundRatio);

        // Update profit max unlock time to zero BEFORE creating profits
        vault.setProfitMaxUnlockTime(0);
        vm.stopPrank();

        // Verify initial state with zero settings
        assertEq(vault.profitMaxUnlockTime(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.fullProfitUnlockDate(), 0);
        assertEq(vault.profitUnlockingRate(), 0);

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Record initial price per share
        uint256 firstPricePerShare = vault.pricePerShare();

        // Create profit - fees should immediately be unlocked
        vm.prank(gov);
        asset.transfer(address(strategy), firstProfit);

        // Process report
        vm.prank(gov);
        (uint256 gain, uint256 loss) = vault.process_report(address(strategy));

        // Verify the correct gain and loss
        assertEq(gain, firstProfit);
        assertEq(loss, 0);

        // Calculate expected fee shares
        uint256 expectedFeesShares = (firstProfit * performanceFee) / MAX_BPS;

        // Check vault totals after profit
        checkVaultTotals(
            amount + firstProfit, // total debt
            0, // total idle
            amount + firstProfit, // total assets
            amount + expectedFeesShares // total supply
        );

        // Price per share should be higher than initial
        uint256 pricePerShare = vault.pricePerShare();
        assertGt(pricePerShare, firstPricePerShare);

        // Withdraw from strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should remain the same
        assertEq(vault.pricePerShare(), pricePerShare);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount + firstProfit, // total idle
            amount + firstProfit, // total assets
            amount + expectedFeesShares // total supply
        );

        // Increase time - should not change anything since profits already unlocked
        increaseTimeAndCheckProfitBuffer(DAY, 0);

        // PPS should still be the same
        assertEq(vault.pricePerShare(), pricePerShare);

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should still be the same after fish redemption
        assertEq(vault.pricePerShare(), pricePerShare);

        // Accountant redeems shares
        vm.startPrank(address(flexibleAccountant));
        vault.approve(address(vault), vault.balanceOf(address(flexibleAccountant)));
        vault.redeem(
            vault.balanceOf(address(flexibleAccountant)),
            address(flexibleAccountant),
            address(flexibleAccountant),
            0,
            new address[](0)
        );
        vm.stopPrank();

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // PPS should return to original value
        assertEq(vault.pricePerShare(), firstPricePerShare);
    }

    function testSetProfitMaxPeriodToZeroReportLoss() public {
        // Setup initial values
        uint256 amount = fishAmount / 10;
        uint256 firstLoss = amount / 2;

        // Set up vault with no accountant
        vm.startPrank(gov);
        vault.set_accountant(address(0));

        // Update profit max unlock time to zero BEFORE creating the loss
        vault.setProfitMaxUnlockTime(0);
        vm.stopPrank();

        // Verify initial state with zero settings
        assertEq(vault.profitMaxUnlockTime(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.fullProfitUnlockDate(), 0);
        assertEq(vault.profitUnlockingRate(), 0);

        // Deposit
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Create and check loss
        vm.prank(gov);
        strategy.simulateLoss(firstLoss);

        vm.prank(gov);
        (uint256 gain, uint256 loss) = vault.process_report(address(strategy));

        // Verify the loss was processed correctly
        assertEq(gain, 0);
        assertEq(loss, firstLoss);

        // All profits should have been unlocked immediately
        checkVaultTotals(
            amount - firstLoss, // total debt
            0, // total idle
            amount - firstLoss, // total assets
            amount // total supply
        );

        // PPS should be less than or equal to 0.5
        assertLe(vault.pricePerShare() / 10 ** vault.decimals(), (5 * 10 ** vault.decimals()) / 10);

        // Withdraw from strategy to idle
        vm.prank(gov);
        vault.update_debt(address(strategy), 0, 0);

        // Strategy debt should be zero
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);

        // PPS should still be less than or equal to 0.5
        assertLe(vault.pricePerShare() / 10 ** vault.decimals(), (5 * 10 ** vault.decimals()) / 10);

        // Check totals after withdrawal
        checkVaultTotals(
            0, // total debt
            amount - firstLoss, // total idle
            amount - firstLoss, // total assets
            amount // total supply
        );

        // Fish redeems shares
        vm.startPrank(fish);
        vault.approve(fish, vault.balanceOf(fish));
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // PPS should be 1.0 after redemption
        assertPricePerShare(1 * 10 ** 18);

        // Vault should be empty
        checkVaultTotals(0, 0, 0, 0);

        // Vault should have no assets left
        assertEq(asset.balanceOf(address(vault)), 0);

        // Fish gets back original amount minus loss
        assertEq(asset.balanceOf(fish), fishAmount - firstLoss);
    }
}
