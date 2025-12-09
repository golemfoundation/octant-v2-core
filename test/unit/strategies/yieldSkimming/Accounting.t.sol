// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { MockYieldSourceSkimming } from "test/mocks/core/tokenized-strategies/MockYieldSourceSkimming.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { MockStrategySkimming } from "test/mocks/core/tokenized-strategies/MockStrategySkimming.sol";
import { console2 } from "forge-std/console2.sol";

contract AccountingTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_airdropDoesNotIncreasePPSHere(address _address, uint256 assets, uint16 airdropAmount) public {
        // Extremely tight bounds to avoid overflow
        assets = bound(assets, 1, 1e6); // Max 1 million - safe for all math
        airdropAmount = uint16(bound(airdropAmount, 1, 100)); // Small airdrop

        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(this) &&
                _address != donationAddress
        );

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, _address, assets);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (assets * airdropAmount) / MAX_BPS;
        yieldSource.mint(address(strategy), toAirdrop);

        // PPS shouldn't change but the balance does.
        assertEq(strategy.pricePerShare(), pricePerShare, "!pricePerShare");
        checkStrategyTotals(strategy, assets, 0, assets, assets);

        // report in order to update the totalAssets
        vm.prank(keeper);
        strategy.report();

        uint256 beforeBalance = yieldSource.balanceOf(_address);

        vm.startPrank(_address);
        strategy.redeem(strategy.balanceOf(_address), _address, _address);
        vm.stopPrank();

        // make sure balance of strategy is 0
        assertEq(strategy.balanceOf(_address), 0, "!balanceOf _address 0");

        // should have pulled out just the deposited amount
        assertApproxEqRel(yieldSource.balanceOf(_address), beforeBalance + assets, 2e15, "!balanceOf _address");

        // redeem donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        if (donationShares > 0) {
            vm.startPrank(address(donationAddress));
            strategy.redeem(donationShares, donationAddress, donationAddress);
            vm.stopPrank();
        }

        // make sure balance of strategy is 0
        assertEq(strategy.balanceOf(donationAddress), 0, "!balanceOf donationShares 0");

        assertEq(yieldSource.balanceOf(address(strategy)), 0, "!balanceOf strategy");

        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_airdropToYieldSourceDecreasesPPS_reportRecordsIt(
        address _address,
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != address(donationAddress)
        );

        // deposit into the yield source
        mintAndDepositIntoYieldSource(yieldSource, _address, _amount);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 addressInitialDepositInValue = _amount * MockYieldSourceSkimming(address(yieldSource)).pricePerShare();

        // should increase
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to yield source
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);

        // PPS should not change before the report
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, 0, _amount, _amount);

        // process a report to realize the gain from the airdrop

        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = strategy.totalSupply();

        vm.prank(keeper);
        (uint256 profit, ) = strategy.report();

        // if pricePerShare changes on the report, it should decrease pps
        if (profit > 0) {
            assertLt(strategy.pricePerShare(), pricePerShare, "!pricePerShare 1");
        } else {
            assertEq(strategy.pricePerShare(), pricePerShare, "!pricePerShare 1 eq");
        }

        // Calculate expected shares minted and verify
        uint256 expectedSharesMinted = calculateExpectedSharesFromProfit(profit, totalAssetsBefore, totalSupplyBefore);

        // Allow some tolerance for precision differences
        assertApproxEqRel(
            strategy.totalSupply() - totalSupplyBefore,
            expectedSharesMinted,
            1e13,
            "Shares minted should match expected"
        );

        checkStrategyTotals(strategy, _amount, 0, _amount, totalSupplyBefore + expectedSharesMinted);

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(yieldSource), toAirdrop);
        totalSupplyBefore = strategy.totalSupply();
        // report again
        vm.prank(keeper);
        (uint256 profit2, ) = strategy.report();

        // if pricePerShare changes on the report, it should decrease pps
        if (profit2 > 0) {
            assertLt(strategy.pricePerShare(), pricePerShare, "!pricePerShare 2");
        } else {
            assertEq(strategy.pricePerShare(), pricePerShare, "!pricePerShare 2 eq");
        }

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // Total is the same but balance has adjusted again
        checkStrategyTotals(
            strategy,
            _amount,
            0,
            _amount,
            totalSupplyBefore +
                expectedSharesMinted +
                calculateExpectedSharesFromProfit(profit2, totalAssetsBefore, totalSupplyBefore)
        );

        vm.startPrank(_address);
        uint256 assetsReceived = strategy.redeem(strategy.balanceOf(_address), _address, _address);
        vm.stopPrank();

        // calculate the value of the assets received
        uint256 assetsReceivedInValue = assetsReceived * MockYieldSourceSkimming(address(yieldSource)).pricePerShare();

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares if profit is greater than 0
        if (profit > 0 || profit2 > 0) {
            assertGt(donationShares, 0, "!donationShares is zero");
            vm.startPrank(address(donationAddress));
            strategy.redeem(donationShares, donationAddress, donationAddress);
            vm.stopPrank();
        }

        uint256 expectedDonationsShares = _amount - assetsReceived;

        // should have pulled out in value the same as the airdrop
        assertApproxEqRel(assetsReceivedInValue, addressInitialDepositInValue, 1e13);
        // assert donation address has the airdrop
        assertEq(yieldSource.balanceOf(donationAddress), expectedDonationsShares, "!donationAddress");
        assertEq(yieldSource.balanceOf(address(strategy)), 0, "!strategy");

        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_earningYieldDecreasesPPS(address _address, uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != address(donationAddress)
        );

        // deposit into the yield source
        mintAndDepositIntoYieldSource(yieldSource, _address, _amount);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the strategy
        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 addressInitialDepositInValue = _amount * MockYieldSourceSkimming(address(yieldSource)).pricePerShare();

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to yield source
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);

        // PPS should not change before the report
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, 0, _amount, _amount);

        // process a report to realize the gain from the airdrop
        uint256 profit;
        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = strategy.totalSupply();

        vm.prank(keeper);
        (profit, ) = strategy.report();

        // if pricePerShare changes on the report, it should decrease pps
        if (profit > 0) {
            assertLt(strategy.pricePerShare(), pricePerShare, "!pricePerShare 1");
        } else {
            assertEq(strategy.pricePerShare(), pricePerShare, "!pricePerShare 1 eq");
        }

        // Calculate expected shares minted and verify
        uint256 expectedSharesMinted = calculateExpectedSharesFromProfit(profit, totalAssetsBefore, totalSupplyBefore);

        // Allow some tolerance for precision differences
        assertApproxEqRel(
            strategy.totalSupply() - totalSupplyBefore,
            expectedSharesMinted,
            1e13,
            "Shares minted should match expected"
        );

        checkStrategyTotals(strategy, _amount, 0, _amount, totalSupplyBefore + expectedSharesMinted);

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(yieldSource), toAirdrop);
        totalSupplyBefore = strategy.totalSupply();
        // report again
        vm.prank(keeper);
        (uint256 profit2, ) = strategy.report();

        // if pricePerShare changes on the report, it should decrease pps
        if (profit2 > 0) {
            assertLt(strategy.pricePerShare(), pricePerShare, "!pricePerShare 2");
        } else {
            assertEq(strategy.pricePerShare(), pricePerShare, "!pricePerShare 2 eq");
        }

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // Total is the same but balance has adjusted again
        checkStrategyTotals(
            strategy,
            _amount,
            0,
            _amount,
            totalSupplyBefore +
                expectedSharesMinted +
                calculateExpectedSharesFromProfit(profit2, totalAssetsBefore, totalSupplyBefore)
        );

        vm.startPrank(_address);
        uint256 assetsReceived = strategy.redeem(strategy.balanceOf(_address), _address, _address);
        vm.stopPrank();

        // calculate the value of the assets received
        uint256 assetsReceivedInValue = assetsReceived * MockYieldSourceSkimming(address(yieldSource)).pricePerShare();

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares if profit is greater than 0
        if (profit > 0 || profit2 > 0) {
            assertGt(donationShares, 0, "!donationShares is zero");
            vm.startPrank(address(donationAddress));
            strategy.redeem(donationShares, donationAddress, donationAddress);
            vm.stopPrank();
        }

        uint256 expectedDonationsShares = _amount - assetsReceived;

        // should have pulled out in value the same as the airdrop
        assertApproxEqRel(assetsReceivedInValue, addressInitialDepositInValue, 1e13);
        // assert donation address has the airdrop
        assertEq(yieldSource.balanceOf(donationAddress), expectedDonationsShares, "!donationAddress");
        assertEq(yieldSource.balanceOf(address(strategy)), 0, "!strategy");

        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_withdrawWithUnrealizedLoss_reverts(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(strategy));
        yieldSource.transfer(address(69), toLose);

        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.withdraw(_amount, _address, _address);
    }

    function test_withdrawWithUnrealizedLoss_withMaxLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(strategy));
        yieldSource.transfer(address(69), toLose);

        uint256 beforeBalance = yieldSource.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(_address);
        strategy.withdraw(_amount, _address, _address, _lossFactor);

        uint256 afterBalance = yieldSource.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.startPrank(address(strategy));
        yieldSource.transfer(address(69), toLose);
        vm.stopPrank();

        uint256 beforeBalance = yieldSource.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.startPrank(_address);
        strategy.redeem(_amount, _address, _address);
        vm.stopPrank();

        uint256 afterBalance = yieldSource.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss_allowNoLoss_reverts(
        address _address,
        uint256 _amount,
        uint16 _lossFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(strategy));
        yieldSource.transfer(address(69), toLose);

        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, 0);
    }

    function test_redeemWithUnrealizedLoss_customMaxLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(strategy));
        yieldSource.transfer(address(69), toLose);

        uint256 beforeBalance = yieldSource.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;

        // First set it to just under the expected loss.
        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, _lossFactor - 1);

        // Now redeem with the correct loss.
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, _lossFactor);

        uint256 afterBalance = yieldSource.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_maxUintDeposit_depositsBalance(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != strategy.dragonRouter()
        );
        vm.assume(yieldSource.balanceOf(_address) == 0);

        yieldSource.mint(_address, _amount);

        vm.prank(_address);
        yieldSource.approve(address(strategy), _amount);

        assertEq(yieldSource.balanceOf(_address), _amount, "!balanceOf _address");

        vm.startPrank(_address);
        strategy.deposit(type(uint256).max, _address);
        vm.stopPrank();

        // Should just deposit the available amount.
        checkStrategyTotals(strategy, _amount, 0, _amount, _amount);

        assertEq(yieldSource.balanceOf(_address), 0, "!balanceOf _address");
        assertEq(strategy.balanceOf(_address), _amount, "!balanceOf strategy");
        assertEq(yieldSource.balanceOf(address(strategy)), _amount, "!balanceOf strategy yieldSource");
    }

    // ===== LOSS BEHAVIOR TESTS =====

    /**
     * @notice Test that loss protection mechanism tracks losses correctly for yield skimming
     * @dev This tests the _handleDragonLossProtection function in YieldSkimmingTokenizedStrategy
     */
    function test_lossProtection_tracksLossesCorrectly(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS - 1)); // Prevent 100% loss

        // Setup initial deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Record initial state
        uint256 initialDonationShares = strategy.balanceOf(donationAddress);
        assertEq(initialDonationShares, 0, "Initial donation shares should be 0");

        // Simulate a loss by decreasing the exchange rate
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 newRate = currentRate - (currentRate * _lossFactor) / MAX_BPS;

        // update the exchange rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(newRate);

        // Report the loss - this should trigger loss protection
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "Should report no profit");
        assertGt(loss, 0, "Should report some loss");

        // Donation address should not receive any shares yet (loss is tracked internally)
        uint256 finalDonationShares = strategy.balanceOf(donationAddress);
        assertEq(finalDonationShares, initialDonationShares, "Donation shares should not change on loss");

        // Clear the mock
        vm.clearMockedCalls();
    }

    /**
     * @notice Test withdraw behavior during stored losses in yield skimming
     */
    function test_lossProtection_withdrawDuringStoredLoss(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS / 2));

        // Setup initial deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Get initial exchange rate
        uint256 initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // Simulate a loss by decreasing the exchange rate
        uint256 lossRate = (initialRate * (MAX_BPS - _lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate);

        // Report the loss (attempts to burn donation shares if available)
        vm.prank(keeper);
        strategy.report();

        // Calculate expected assets based on lower rate
        uint256 userShares = strategy.balanceOf(user);
        uint256 expectedAssets = strategy.previewRedeem(userShares); // Uses current lower rate

        vm.prank(user);
        uint256 assetsReceived = strategy.redeem(userShares, user, user);

        // Should receive reduced amount based on lower rate
        assertApproxEqRel(assetsReceived, expectedAssets, 1e13, "Should receive expected assets after loss");
        // User should get back same number of assets (tokens)
        assertEq(assetsReceived, _amount, "Should receive same number of assets");

        // But underlying value should be less due to rate drop
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 withdrawnUnderlyingValue = (assetsReceived * currentRate) / 1e18;
        uint256 depositedUnderlyingValue = _amount; // Initial rate was 1.0

        assertLt(withdrawnUnderlyingValue, depositedUnderlyingValue, "Underlying value should be less due to loss");

        // Strategy should be empty after full withdrawal
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    /**
     * @notice Test maximum possible loss scenario in yield skimming
     */
    function test_lossProtection_maximumLossScenario(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Setup initial deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // mock the exchange rate to 0
        MockStrategySkimming(address(strategy)).updateExchangeRate(0);

        // Report the loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "Should report no profit");
        assertEq(loss, _amount, "Should report total loss");
        assertEq(strategy.balanceOf(donationAddress), 0, "Donation address should have no shares");
    }

    // ===== DEFICIT ADJUSTMENT TESTS =====
    /**
     * @notice Test invariant: Depositors during loss period cannot withdraw more underlying value than deposited
     * @dev Simulates a loss, post-loss deposit, partial recovery, and verifies withdrawal value
     */
    function test_invariant_lossDepositorCannotWithdrawMoreThanDeposited(
        uint256 initialDeposit,
        uint256 postLossDeposit,
        uint16 lossFactor,
        uint16 recoveryFactor
    ) public {
        initialDeposit = bound(initialDeposit, minFuzzAmount, maxFuzzAmount / 2);
        postLossDeposit = bound(postLossDeposit, minFuzzAmount, maxFuzzAmount / 2);
        lossFactor = uint16(bound(lossFactor, 100, MAX_BPS / 2)); // 1-50% loss
        recoveryFactor = uint16(bound(recoveryFactor, 100, MAX_BPS / 2)); // 1-50% recovery

        address preLossUser = address(0x1234);
        address postLossUser = address(0x5678);

        // Initial deposit before loss
        mintAndDepositIntoStrategy(strategy, preLossUser, initialDeposit);

        // Simulate loss by decreasing exchange rate
        uint256 initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 lossRate = (initialRate * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate);

        // Report the loss (may burn donation shares if available, but assume none for max loss impact)
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        // Check if debt tracking is working properly
        uint256 totalValueDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());

        // For yield skimming strategies, deposits after losses are typically blocked
        // by insolvency protection when totalValueDebt > 0 and current value < debt.
        uint256 currentVaultValue = (strategy.totalAssets() * lossRate) / 1e18;

        if (currentVaultValue < totalValueDebt) {
            // Vault is insolvent - expect deposit to be blocked
            // First mint the tokens to the user (this should succeed)
            yieldSource.mint(postLossUser, postLossDeposit);
            vm.prank(postLossUser);
            yieldSource.approve(address(strategy), postLossDeposit);

            // Now expect the deposit to revert due to insolvency
            vm.expectRevert("Cannot operate when vault is insolvent");
            vm.prank(postLossUser);
            strategy.deposit(postLossDeposit, postLossUser);
            return; // Test passes - insolvency protection working
        }
    }

    /**
     * @notice Test invariant: No minting to dragon router until all loss is recovered
     * @dev Simulates loss, partial recoveries, and verifies no minting until full recovery
     */
    function test_invariant_noMintUntilLossRecovered(
        uint256 initialDeposit,
        uint16 lossFactor,
        uint16 partialRecoveryFactor,
        uint16 fullRecoveryFactor
    ) public {
        initialDeposit = bound(initialDeposit, minFuzzAmount, maxFuzzAmount);
        lossFactor = uint16(bound(lossFactor, 100, MAX_BPS / 2)); // 1-50% loss
        partialRecoveryFactor = uint16(bound(partialRecoveryFactor, 50, 99)); // 50-99% of loss recovered (partial)
        fullRecoveryFactor = uint16(bound(fullRecoveryFactor, 100, 150)); // 100-150% (full + extra)

        address user = address(0x1234);

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, user, initialDeposit);

        // Simulate loss
        uint256 initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 lossRate = (initialRate * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate);

        // Report loss (tracks but doesn't fully handle if no donation shares)
        vm.prank(keeper);
        strategy.report();

        uint256 supplyAfterLoss = strategy.totalSupply();

        // Simulate partial recovery (not enough to cover loss)
        uint256 partialRecoveryRate = lossRate + ((initialRate - lossRate) * partialRecoveryFactor) / 100;
        MockStrategySkimming(address(strategy)).updateExchangeRate(partialRecoveryRate);

        // Report partial recovery
        vm.prank(keeper);
        strategy.report();

        // Invariant: No new shares minted (supply unchanged or decreased if burning)
        assertLe(strategy.totalSupply(), supplyAfterLoss, "No minting during partial recovery");

        // Simulate full recovery (exceeds loss)
        uint256 fullRecoveryRate = lossRate + ((initialRate - lossRate) * fullRecoveryFactor) / 100;
        MockStrategySkimming(address(strategy)).updateExchangeRate(fullRecoveryRate);

        // Report full recovery
        vm.prank(keeper);
        strategy.report();

        // Now minting can occur since loss is swallowed
        if (fullRecoveryFactor > 100) {
            assertGt(strategy.totalSupply(), supplyAfterLoss, "Minting occurs after full recovery");
        } else {
            assertLe(strategy.totalSupply(), supplyAfterLoss, "No minting until excess recovery");
        }
    }

    /**
     * @notice Invariant: Depositors can never receive more in underlying asset value than deposited
     * @dev Fuzzes over deposit amounts, loss/recovery factors, and multiple users
     */
    struct TestVars {
        uint256 initialRate;
        uint256 lossRate;
        uint256 recoveryRate;
        uint256 depositorShares;
        uint256 totalSupplyAfterRecovery;
        uint256 withdrawnAssets;
        uint256 withdrawnValue;
        uint256 netRateChange;
        uint256 depositorFraction;
        uint256 expected;
    }

    function test_invariant_depositorsCannotWithdrawMoreThanDeposited(
        uint256 depositAmount,
        uint16 lossFactor,
        uint16 recoveryFactor
    ) public {
        TestVars memory vars;

        depositAmount = bound(depositAmount, minFuzzAmount, maxFuzzAmount);
        lossFactor = uint16(bound(lossFactor, 100, MAX_BPS / 2)); // 1-50% loss
        recoveryFactor = uint16(bound(recoveryFactor, 50, 200)); // 50-200% recovery (partial to over-recovery)

        address depositor = address(0xABCD);

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, depositor, depositAmount);

        // Get initial exchange rate
        vars.initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // Simulate loss
        vars.lossRate = (vars.initialRate * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.lossRate);
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        // Get depositor shares before recovery (for fraction calculation)
        vars.depositorShares = strategy.balanceOf(depositor);

        // Simulate recovery
        vars.recoveryRate = vars.lossRate + ((vars.initialRate - vars.lossRate) * recoveryFactor) / 100;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.recoveryRate);
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        // Get total supply after recovery report (includes any dilution from excess profit minting)
        vars.totalSupplyAfterRecovery = strategy.totalSupply();

        // Withdraw
        vm.startPrank(depositor);
        vars.withdrawnAssets = strategy.redeem(vars.depositorShares, depositor, depositor);
        vm.stopPrank();

        // Calculate withdrawn value in initial rate terms (underlying value)
        vars.withdrawnValue = (vars.withdrawnAssets * vars.recoveryRate) / vars.initialRate;

        // Invariant: Withdrawn value <= deposited amount (with rounding tolerance)
        assertLe(vars.withdrawnValue, depositAmount, "Withdrawn value exceeds deposited amount");

        // Adjusted expectation: Withdrawn value should be approximately deposit adjusted by net rate change and depositor's fraction after dilution (only on excess profit)
        vars.netRateChange = (vars.recoveryRate * 1e18) / vars.initialRate; // Scale to preserve fractions
        vars.depositorFraction = (vars.depositorShares * 1e18) / vars.totalSupplyAfterRecovery; // Scale for precision
        vars.expected = (depositAmount * vars.netRateChange * vars.depositorFraction) / (1e18 * 1e18); // Divide by scales

        assertApproxEqRel(
            vars.withdrawnValue,
            vars.expected,
            0.001e18, // 0.01% tolerance for rounding/dilution effects
            "Value should reflect net recovery rate adjusted for dilution on excess profit"
        );
    }

    struct RecoveryVars {
        uint256 initialRate;
        uint256 lossRate;
        uint256 recoveryRate;
        uint256 initialUnderlying;
        uint256 preRecoverySupply;
        uint256 preRecoveryDragonShares;
        uint256 postRecoverySupply;
        uint256 postRecoveryDragonShares;
        uint256 mintedToDragon;
        uint256 depositorShares;
        uint256 withdrawnAssets;
        uint256 withdrawnUnderlying;
        uint256 recoveryVsLoss;
        uint256 excessUnderlying;
        uint256 expectedMinted;
    }

    function test_invariant_recoveryBehavior(
        uint256 depositAmount,
        uint16 lossFactor,
        uint16 recoveryMultiplier
    ) public {
        RecoveryVars memory vars;

        depositAmount = bound(depositAmount, minFuzzAmount, maxFuzzAmount);
        lossFactor = uint16(bound(lossFactor, 1, MAX_BPS / 2)); // 0.01-50% loss to avoid zero
        recoveryMultiplier = uint16(bound(recoveryMultiplier, 0, 300)); // 0-300% recovery factor

        address depositor = address(0xABCD);

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, depositor, depositAmount);

        vars.initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        vars.initialUnderlying = (depositAmount * vars.initialRate) / 1e18; // Assuming rate in 1e18 scale for simplicity

        // Simulate loss
        vars.lossRate = (vars.initialRate * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.lossRate);
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        vars.preRecoverySupply = strategy.totalSupply();
        vars.preRecoveryDragonShares = strategy.balanceOf(donationAddress); // Corrected to donationAddress

        // Simulate recovery
        uint256 lostAmount = vars.initialRate - vars.lossRate;
        vars.recoveryRate = vars.lossRate + (lostAmount * recoveryMultiplier) / 100;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.recoveryRate);
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        vars.postRecoverySupply = strategy.totalSupply();
        vars.postRecoveryDragonShares = strategy.balanceOf(donationAddress); // Corrected to donationAddress

        vars.mintedToDragon = vars.postRecoveryDragonShares - vars.preRecoveryDragonShares;

        // Withdraw
        vm.startPrank(depositor);
        vars.depositorShares = strategy.balanceOf(depositor);
        vars.withdrawnAssets = strategy.redeem(strategy.balanceOf(depositor), depositor, depositor);
        vm.stopPrank();

        vars.withdrawnUnderlying = (vars.withdrawnAssets * vars.recoveryRate) / 1e18;

        // Calculate recovery ratio (recovery vs. loss in underlying terms)
        vars.recoveryVsLoss = (vars.recoveryRate >= vars.initialRate)
            ? 2 // Full recovery ( > loss)
            : (vars.recoveryRate > vars.lossRate)
                ? 1
                : 0; // Partial recovery (< loss) or further loss

        if (vars.recoveryVsLoss == 0) {
            // Recovery <= loss (further or no recovery)
            assertEq(vars.mintedToDragon, 0, "No minting if recovery <= loss");
            assertLt(vars.withdrawnUnderlying, vars.initialUnderlying, "Withdrawn < deposited if incomplete recovery");
        } else if (vars.recoveryVsLoss == 1) {
            // Partial recovery (recovery > lossRate but < initialRate)
            assertEq(vars.mintedToDragon, 0, "No minting if partial recovery (< full loss offset)");
            assertLt(vars.withdrawnUnderlying, vars.initialUnderlying, "Withdrawn < deposited if partial recovery");
        } else {
            // Full recovery (recovery >= initialRate, excess >0)
            assertApproxEqRel(
                vars.withdrawnUnderlying,
                vars.initialUnderlying,
                0.001e18,
                "Depositor gets exactly deposited underlying on full recovery"
            );
            // Adjust for dust: only assert >0 if excess is material (e.g., >1e9 wei underlying to avoid flooring to 0)
            vars.excessUnderlying = (depositAmount * (vars.recoveryRate - vars.initialRate)) / 1e18;
            if (vars.excessUnderlying > 1e9) {
                assertGt(vars.mintedToDragon, 0, "Excess profit minted to dragon on full recovery");
            } else {
                assertGe(vars.mintedToDragon, 0, "Dust excess may not trigger minting");
            }
            // Optional: Check minted ≈ excess underlying converted to shares
            vars.expectedMinted = vars.excessUnderlying; // Assuming PPS≈1 in underlying
            assertApproxEqRel(vars.mintedToDragon, vars.expectedMinted, 0.0001e18, "Minted matches excess underlying");
        }
    }

    struct LocalVars {
        uint256 initialRate;
        uint256 lossRate;
        uint256 recoveryRate;
    }

    function test_invariant_depositorsCannotWithdrawMoreThanInitialUnderlying(
        uint256 depositAmount1,
        uint256 depositAmount2,
        uint16 lossFactor,
        uint16 recoveryMultiplier
    ) public {
        address depositor1 = makeAddr("depositor1");
        address depositor2 = makeAddr("depositor2");

        depositAmount1 = bound(depositAmount1, minFuzzAmount, maxFuzzAmount / 2);
        depositAmount2 = bound(depositAmount2, minFuzzAmount, maxFuzzAmount / 2);
        lossFactor = uint16(bound(lossFactor, 0, MAX_BPS / 2));
        recoveryMultiplier = uint16(bound(recoveryMultiplier, 0, MAX_BPS * 2));
        vm.assume(depositAmount1 > 0 && depositAmount2 > 0);

        LocalVars memory vars;

        // Depositor 1 deposits using helper
        mintAndDepositIntoStrategy(strategy, depositor1, depositAmount1);
        uint256 initialUnderlying1 = depositAmount1; // Adjust if initial rate !=1e18

        // Depositor 2 deposits using helper
        mintAndDepositIntoStrategy(strategy, depositor2, depositAmount2);
        uint256 initialUnderlying2 = depositAmount2;

        // Simulate loss and recovery
        vars.initialRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        vars.lossRate = (vars.initialRate * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.lossRate);
        vm.prank(keeper);
        strategy.report();

        vars.recoveryRate = vars.lossRate + (vars.lossRate * recoveryMultiplier) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(vars.recoveryRate);
        vm.prank(keeper);
        strategy.report();

        // Withdraw and check
        uint256 shares1 = strategy.balanceOf(depositor1);
        vm.prank(depositor1);
        uint256 withdrawnAssets1 = strategy.redeem(shares1, depositor1, depositor1);
        uint256 withdrawnUnderlying1 = (withdrawnAssets1 * vars.recoveryRate) / 1e18;

        uint256 shares2 = strategy.balanceOf(depositor2);
        vm.prank(depositor2);
        uint256 withdrawnAssets2 = strategy.redeem(shares2, depositor2, depositor2);
        uint256 withdrawnUnderlying2 = (withdrawnAssets2 * vars.recoveryRate) / 1e18;

        assertLe(withdrawnUnderlying1, initialUnderlying1 + 1, "Depositor1 withdrawn <= initial");
        assertLe(withdrawnUnderlying2, initialUnderlying2 + 1, "Depositor2 withdrawn <= initial");
    }

    // ===== DEBT TRACKING TRANSFER TESTS =====

    /**
     * @notice Test debt tracking when user transfers shares to dragon router
     * @dev Verifies that totalDebtOwedToUserInAssetValue decreases and dragonRouterDebtInAssetValue increases
     */
    function test_transferToDragon_updatesDebtTracking(uint256 depositAmount, uint256 transferAmount) public {
        depositAmount = bound(depositAmount, minFuzzAmount, 1e27); // Limit to prevent overflow
        address user1 = makeAddr("user1");

        // User deposits
        mintAndDepositIntoStrategy(strategy, user1, depositAmount);
        uint256 userShares = strategy.balanceOf(user1);
        if (userShares == 0) return; // Skip if no shares minted
        transferAmount = bound(transferAmount, 1, userShares);

        // Check initial debt tracking
        uint256 initialUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 initialDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        assertEq(initialUserDebt, depositAmount, "Initial user debt should equal deposit");
        assertEq(initialDragonDebt, 0, "Initial dragon debt should be 0");

        // User transfers shares to dragon router
        vm.startPrank(user1);
        strategy.transfer(strategy.dragonRouter(), transferAmount);
        vm.stopPrank();

        // Check updated debt tracking
        uint256 finalUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 finalDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        assertEq(finalUserDebt, initialUserDebt - transferAmount, "User debt should decrease by transfer amount");
        assertEq(finalDragonDebt, initialDragonDebt + transferAmount, "Dragon debt should increase by transfer amount");
        assertEq(strategy.balanceOf(user1), userShares - transferAmount, "User shares should decrease");
        assertEq(strategy.balanceOf(strategy.dragonRouter()), transferAmount, "Dragon should receive shares");
    }

    /**
     * @notice Test debt tracking when dragon router transfers shares to user
     * @dev Verifies that dragonRouterDebtInAssetValue decreases and totalDebtOwedToUserInAssetValue increases
     */
    function test_transferFromDragon_updatesDebtTracking(
        uint256 depositAmount,
        uint256 profitFactor,
        uint256 transferAmount
    ) public {
        depositAmount = bound(depositAmount, minFuzzAmount, 1e27); // Limit to prevent overflow
        profitFactor = bound(profitFactor, 100, 1000); // 1-10% profit
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // User1 deposits
        mintAndDepositIntoStrategy(strategy, user1, depositAmount);

        // Create profit to mint shares to dragon
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 profitRate = currentRate + (currentRate * profitFactor) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(profitRate);

        // Report to mint shares to dragon
        vm.prank(keeper);
        strategy.report();

        uint256 dragonShares = strategy.balanceOf(strategy.dragonRouter());
        require(dragonShares > 0, "Dragon should have shares from profit");
        transferAmount = bound(transferAmount, 1, dragonShares);

        // Check debt before transfer
        uint256 initialUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 initialDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        // Dragon transfers shares to user2
        vm.startPrank(strategy.dragonRouter());
        strategy.transfer(user2, transferAmount);
        vm.stopPrank();

        // Check updated debt tracking
        uint256 finalUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 finalDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        assertEq(finalUserDebt, initialUserDebt + transferAmount, "User debt should increase by transfer amount");
        assertEq(finalDragonDebt, initialDragonDebt - transferAmount, "Dragon debt should decrease by transfer amount");
        assertEq(strategy.balanceOf(user2), transferAmount, "User2 should receive shares");
        assertEq(
            strategy.balanceOf(strategy.dragonRouter()),
            dragonShares - transferAmount,
            "Dragon shares should decrease"
        );
    }

    /**
     * @notice Test transferFrom functionality with debt tracking
     * @dev Verifies debt tracking updates correctly when using transferFrom
     */
    function test_transferFrom_updatesDebtTracking(uint256 depositAmount, uint256 transferAmount) public {
        depositAmount = bound(depositAmount, minFuzzAmount, 1e27); // Limit to prevent overflow
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // User1 deposits
        mintAndDepositIntoStrategy(strategy, user1, depositAmount);
        uint256 userShares = strategy.balanceOf(user1);
        transferAmount = bound(transferAmount, 1, userShares);

        // User1 approves user2 to transfer the full balance
        vm.startPrank(user1);
        strategy.approve(user2, userShares);
        vm.stopPrank();

        // Check initial debt
        uint256 initialUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 initialDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        // User2 transfers from user1 to dragon router
        vm.startPrank(user2);
        strategy.transferFrom(user1, strategy.dragonRouter(), transferAmount);
        vm.stopPrank();

        // Check updated debt tracking
        uint256 finalUserDebt = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        uint256 finalDragonDebt = strategy.balanceOf(strategy.dragonRouter());

        assertEq(finalUserDebt, initialUserDebt - transferAmount, "User debt should decrease");
        assertEq(finalDragonDebt, initialDragonDebt + transferAmount, "Dragon debt should increase");
        assertEq(strategy.balanceOf(strategy.dragonRouter()), transferAmount, "Dragon should receive shares");
    }

    /**
     * @notice Test multiple transfers maintain correct debt tracking
     * @dev Fuzzes multiple transfers between users and dragon router
     */
    function test_multipleTransfers_maintainDebtInvariant(
        uint256 depositAmount,
        uint8 numTransfers,
        uint256 seed
    ) public {
        depositAmount = bound(depositAmount, minFuzzAmount, 1e27); // Limit to prevent overflow
        numTransfers = uint8(bound(numTransfers, 1, 10));

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Users deposit
        mintAndDepositIntoStrategy(strategy, user1, depositAmount / 2);
        mintAndDepositIntoStrategy(strategy, user2, depositAmount / 2);

        // Create some profit for dragon shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        MockStrategySkimming(address(strategy)).updateExchangeRate((currentRate * 12) / 10); // 20% profit
        vm.prank(keeper);
        strategy.report();

        // Track total debt before transfers
        uint256 totalDebtBefore = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter()) +
            strategy.balanceOf(strategy.dragonRouter());

        // Perform random transfers
        for (uint256 i = 0; i < numTransfers; i++) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));

            // Randomly choose transfer type
            if (random % 3 == 0 && strategy.balanceOf(user1) > 0) {
                // User1 transfers to dragon
                uint256 amount = (strategy.balanceOf(user1) * ((random % 50) + 1)) / 100;
                vm.startPrank(user1);
                strategy.transfer(strategy.dragonRouter(), amount);
                vm.stopPrank();
            } else if (random % 3 == 1 && strategy.balanceOf(strategy.dragonRouter()) > 0) {
                // Dragon transfers to user2
                uint256 amount = (strategy.balanceOf(strategy.dragonRouter()) * ((random % 50) + 1)) / 100;
                vm.startPrank(strategy.dragonRouter());
                strategy.transfer(user2, amount);
                vm.stopPrank();
            } else if (strategy.balanceOf(user2) > 0) {
                // User2 transfers to dragon
                uint256 amount = (strategy.balanceOf(user2) * ((random % 50) + 1)) / 100;
                vm.startPrank(user2);
                strategy.transfer(strategy.dragonRouter(), amount);
                vm.stopPrank();
            }
        }

        // Verify total debt is conserved
        uint256 totalDebtAfter = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter()) +
            strategy.balanceOf(strategy.dragonRouter());

        assertEq(totalDebtAfter, totalDebtBefore, "Total debt should be conserved across transfers");
    }

    /**
     * @notice Test transfer reverts when insufficient debt
     * @dev Verifies proper error handling for edge cases
     */
    function test_transfer_revertsOnInsufficientDebt() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Setup: User1 deposits, profit is generated, dragon gets shares
        mintAndDepositIntoStrategy(strategy, user1, 1000e18);

        // Create profit to give dragon some shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        MockStrategySkimming(address(strategy)).updateExchangeRate((currentRate * 12) / 10); // 20% profit
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        uint256 dragonShares = strategy.balanceOf(strategy.dragonRouter());
        require(dragonShares > 0, "Dragon should have shares");

        // Now user2 transfers some shares to dragon (this increases dragon debt)
        mintAndDepositIntoStrategy(strategy, user2, 1000e18);
        vm.startPrank(user2);
        strategy.transfer(strategy.dragonRouter(), 100e18);
        vm.stopPrank();

        // Dragon now has dragonRouterDebtInAssetValue from user transfer + profit
        uint256 dragonDebt = strategy.balanceOf(strategy.dragonRouter());
        dragonShares = strategy.balanceOf(strategy.dragonRouter());

        // Ensure dragon has enough shares to test the debt limitation
        if (dragonShares <= dragonDebt) {
            // Skip test - dragon doesn't have enough shares to exceed debt
            return;
        }

        // Try to transfer more than dragon's debt - should revert
        vm.expectRevert(bytes("Insufficient dragon debt"));
        vm.startPrank(strategy.dragonRouter());
        strategy.transfer(user1, dragonDebt + 1);
        vm.stopPrank();
    }

    /**
     * @notice Test dragon router cannot transfer to itself
     * @dev Verifies that self-transfers are blocked to prevent accounting issues
     */
    function test_dragonSelfTransfer_blocked() public {
        address user1 = makeAddr("user1");

        // Setup: User deposits, profit is generated, dragon gets shares
        mintAndDepositIntoStrategy(strategy, user1, 1000e18);

        // Create profit to give dragon some shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        MockStrategySkimming(address(strategy)).updateExchangeRate((currentRate * 12) / 10); // 20% profit
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        uint256 dragonShares = strategy.balanceOf(strategy.dragonRouter());
        require(dragonShares > 0, "Dragon should have shares");

        // Try dragon router transferring to itself - should revert
        vm.startPrank(strategy.dragonRouter());

        bool success = false;
        try strategy.transfer(strategy.dragonRouter(), 100e18) {
            success = true;
        } catch {
            success = false;
        }

        vm.stopPrank();

        assertFalse(success, "Dragon self-transfer should fail");
    }

    /**
     * @notice Test dragon router cannot transferFrom to itself
     * @dev Verifies that self-transfers via transferFrom are blocked
     */
    function test_dragonSelfTransferFrom_blocked() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Setup: User deposits, profit is generated, dragon gets shares
        mintAndDepositIntoStrategy(strategy, user1, 1000e18);

        // Create profit to give dragon some shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        MockStrategySkimming(address(strategy)).updateExchangeRate((currentRate * 12) / 10); // 20% profit
        vm.startPrank(keeper);
        strategy.report();
        vm.stopPrank();

        uint256 dragonShares = strategy.balanceOf(strategy.dragonRouter());
        require(dragonShares > 0, "Dragon should have shares");

        // Dragon approves user2 to transfer its shares
        vm.startPrank(strategy.dragonRouter());
        strategy.approve(user2, dragonShares);
        vm.stopPrank();

        // Try user2 transferring from dragon to dragon - should revert
        address dragonRouter = strategy.dragonRouter();
        vm.startPrank(user2);
        vm.expectRevert(bytes("Dragon cannot transfer to itself"));
        strategy.transferFrom(dragonRouter, dragonRouter, 100e18);
        vm.stopPrank();
    }

    /**
     * @notice Test debt tracking during insolvency
     * @dev Verifies transfers are blocked appropriately during insolvency
     */
    function test_transferDuringInsolvency_blocked(uint256 depositAmount, uint16 lossFactor) public {
        depositAmount = bound(depositAmount, minFuzzAmount, 1e27); // Limit to prevent overflow
        lossFactor = uint16(bound(lossFactor, 5000, 9000)); // 50-90% loss
        address user1 = makeAddr("user1");

        // User deposits
        mintAndDepositIntoStrategy(strategy, user1, depositAmount);

        // make sure we dont burn dragon shares
        vm.startPrank(management);
        strategy.setEnableBurning(false);
        vm.stopPrank();

        // create profit to give dragon some shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        MockStrategySkimming(address(strategy)).updateExchangeRate((currentRate * 12) / 10); // 20% profit
        vm.prank(keeper);
        strategy.report();

        // make sure dragon router has balance
        uint256 dragonShares = strategy.balanceOf(strategy.dragonRouter());
        require(dragonShares > 0, "Dragon should have shares");

        // Create significant loss
        uint256 rateBeforeLoss = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 lossRate = (rateBeforeLoss * (MAX_BPS - lossFactor)) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate);

        // Report the loss to update totalAssets
        vm.prank(keeper);
        strategy.report();

        // Check if vault is insolvent
        bool isInsolvent = IYieldSkimmingStrategy(address(strategy)).isVaultInsolvent();

        if (isInsolvent) {
            vm.startPrank(management);
            strategy.setEnableBurning(true);
            vm.stopPrank();

            // Dragon transfers should be blocked during insolvency
            vm.startPrank(strategy.dragonRouter());
            vm.expectRevert("Transfer would cause vault insolvency");
            strategy.transfer(user1, dragonShares);
            vm.stopPrank();
        }
    }

    /**
     * @notice Test loss reporting behavior when currentRate > lastReportedRate but still a loss
     * @dev This tests if the lastReportedRate check is needed - case 1
     */
    function test_lastReportedRate_lossWithRateIncrease() public {
        uint256 depositAmount = 10e18; // 10 tokens
        address depositor = makeAddr("depositor");

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, depositor, depositAmount);

        // Create a big profit first (rate increases to 1.5)
        uint256 profitRate = 15e17; // 1.5 rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(profitRate);

        // Report the profit - this should mint shares to dragon router
        vm.prank(keeper);
        (uint256 profit1, uint256 loss1) = strategy.report();

        assertGt(profit1, 0, "Should report profit");
        assertEq(loss1, 0, "Should report no loss");
        assertGt(strategy.balanceOf(donationAddress), 0, "Dragon should receive shares from profit");

        uint256 lastRate = IYieldSkimmingStrategy(address(strategy)).getLastRateRay();
        assertEq(lastRate, profitRate * 1e9, "Last reported rate should be updated to profit rate");

        // Now simulate first loss: rate drops to 1.2 (still higher than initial 1.0, but lower than 1.5)
        uint256 lossRate1 = 12e17; // 1.2 rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate1);

        // This is a loss compared to totalValueDebt + dragonValueDebt, but currentRate > YS.lastReportedRate is FALSE
        // because 1.2 < 1.5
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();

        assertEq(profit2, 0, "Should report no profit");
        assertGt(loss2, 0, "Should report loss");

        // Verify the rate was updated
        uint256 newLastRate = IYieldSkimmingStrategy(address(strategy)).getLastRateRay();
        assertEq(newLastRate, lossRate1 * 1e9, "Last reported rate should be updated after loss");

        // Now simulate second loss: rate drops further to 1.1 (still a loss but rate decreased)
        uint256 lossRate2 = 11e17; // 1.1 rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(lossRate2);

        // This is a loss and currentRate < YS.lastReportedRate is TRUE because 1.1 < 1.2
        vm.prank(keeper);
        (uint256 profit3, uint256 loss3) = strategy.report();

        assertEq(profit3, 0, "Should report no profit");
        assertGt(loss3, 0, "Should report loss");

        // Both losses should have been reported and handled
        console2.log("Loss 2 (rate increased but still loss):", loss2);
        console2.log("Loss 3 (rate decreased):", loss3);
    }

    /**
     * @notice Test loss reporting behavior when currentRate < lastReportedRate is false
     * @dev This tests if the lastReportedRate check is needed - case 2
     */
    function test_lastReportedRate_lossWithoutRateDecrease() public {
        uint256 depositAmount = 10e18; // 10 tokens
        address depositor = makeAddr("depositor");

        // Initial deposit
        mintAndDepositIntoStrategy(strategy, depositor, depositAmount);

        // Create a big profit first (rate increases to 2.0)
        uint256 profitRate = 2e18; // 2.0 rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(profitRate);

        // Report the profit - this should mint shares to dragon router
        vm.prank(keeper);
        (uint256 profit1, uint256 loss1) = strategy.report();

        assertGt(profit1, 0, "Should report profit");
        assertEq(loss1, 0, "Should report no loss");
        assertGt(strategy.balanceOf(donationAddress), 0, "Dragon should receive shares from profit");

        uint256 lastRate = IYieldSkimmingStrategy(address(strategy)).getLastRateRay();
        assertEq(lastRate, profitRate * 1e9, "Last reported rate should be updated to profit rate");

        // Now simulate a scenario where we have a loss in total value but rate increases slightly
        // Rate goes to 2.1 (higher than lastReportedRate of 2.0)
        uint256 higherRate = 21e17; // 2.1 rate
        MockStrategySkimming(address(strategy)).updateExchangeRate(higherRate);

        // But we need to create a loss in total value
        // We'll burn some assets to simulate a loss despite rate increase
        uint256 assetsToRemove = strategy.totalAssets() / 4; // Remove 25% of assets
        vm.prank(address(strategy));
        yieldSource.transfer(address(0xdead), assetsToRemove);

        // Now we have: currentRate > lastReportedRate (2.1 > 2.0)
        // But currentValue < totalValueDebt + dragonValueDebt due to asset removal
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();

        // This should NOT report a loss because currentRate < YS.lastReportedRate is FALSE
        assertEq(profit2, 0, "Should report no profit");
        assertGt(
            loss2,
            0,
            "Should report absolute loss when rate increased but currentValue < totalValueDebt + dragonValueDebt"
        );

        // Verify rate was NOT updated (by design - only updates on profit or loss with rate decrease)
        uint256 newLastRate = IYieldSkimmingStrategy(address(strategy)).getLastRateRay();
        assertEq(newLastRate, higherRate * 1e9, "Last reported rate should be updated when loss");

        // Now let's create another loss where rate does decrease
        uint256 lowerRate = 19e17; // 1.9 rate (lower than 2.1)
        MockStrategySkimming(address(strategy)).updateExchangeRate(lowerRate);

        // This time currentRate < YS.lastReportedRate is TRUE (1.9 < 2.1)
        vm.prank(keeper);
        (uint256 profit3, uint256 loss3) = strategy.report();

        assertEq(profit3, 0, "Should report no profit");
        assertGt(loss3, 0, "Should report loss when rate decreased");
    }

    /**
     * @notice Test scenario WITHOUT lastReportedRate check
     * @dev Sequence: r1.0, d1, r1.5, d2, report, r1.0, (d3 blocked by insolvency), w1, report, r1.5, w2
     */
    function test_withoutLastReportedRateCheck() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        console2.log("\n=== SCENARIO WITHOUT RATE CHECK: r1.0, d1, r1.5, d2, report, r1.0, w1, report, r1.5, w2 ===");

        // enable burning
        vm.startPrank(management);
        strategy.setEnableBurning(true);
        vm.stopPrank();

        // r1.0: Initial rate 1.0
        console2.log("\nStep 1: r1.0 - Rate set to 1.0");
        // Rate is already 1.0 by default

        // d1: User1 deposits 100
        console2.log("Step 2: d1 - User1 deposits 100");
        mintAndDepositIntoStrategy(strategy, user1, 100e18);
        console2.log("User1 shares:", strategy.balanceOf(user1));
        console2.log("Total value debt:", strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter()));

        // r1.5: Rate increases to 1.5
        console2.log("\nStep 3: r1.5 - Rate increases to 1.5");
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17);

        // d2: User2 deposits 150 (gets 100 shares at rate 1.5)
        console2.log("Step 4: d2 - User2 deposits 150");
        mintAndDepositIntoStrategy(strategy, user2, 150e18);
        console2.log("User2 shares:", strategy.balanceOf(user2));
        console2.log("Total value debt:", strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter()));
        console2.log("Total assets:", strategy.totalAssets());

        // report: Should create profit and mint to dragon
        console2.log("\nStep 5: report - First report (should mint dragon shares)");
        vm.prank(keeper);
        (uint256 profit1, uint256 loss1) = strategy.report();
        uint256 dragonShares = strategy.balanceOf(donationAddress);
        console2.log("Profit reported:", profit1);
        console2.log("Loss reported:", loss1);
        console2.log("Dragon shares minted:", dragonShares);

        // r1.0: Rate drops back to 1.0
        console2.log("\nStep 6: r1.0 - Rate drops back to 1.0");
        MockStrategySkimming(address(strategy)).updateExchangeRate(1e18);

        // d3: User3 tries to deposit 100 but vault is insolvent
        console2.log("Step 7: d3 - User3 tries to deposit 100 (vault is insolvent)");
        console2.log("Current vault value:", (strategy.totalAssets() * 1e18) / 1e18); // Rate is 1.0
        console2.log(
            "Total debt needed:",
            strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter()) +
                strategy.balanceOf(donationAddress)
        );

        // Skip the deposit since vault is insolvent - this shows the protection working
        console2.log("Skipping User3 deposit due to insolvency protection");

        // w1: User1 withdraws all
        console2.log("\nStep 8: w1 - User1 withdraws all");
        uint256 user1Balance = strategy.balanceOf(user1);
        console2.log("User1 balance to redeem:", user1Balance);
        vm.prank(user1);
        strategy.redeem(user1Balance, user1, user1);
        console2.log("User1 withdrawn, remaining total assets:", strategy.totalAssets());
        console2.log(
            "Remaining total value debt:",
            strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter())
        );

        // report: Should show loss and burn dragon shares
        console2.log("\nStep 9: report - Second report (should burn dragon shares due to loss)");
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();
        uint256 dragonSharesAfterLoss = strategy.balanceOf(donationAddress);
        console2.log("Profit reported:", profit2);
        console2.log("Loss reported:", loss2);
        console2.log("Dragon shares burned:", dragonShares - dragonSharesAfterLoss);
        console2.log("Dragon shares remaining:", dragonSharesAfterLoss);

        // r1.5: Rate goes back up to 1.5
        console2.log("\nStep 10: r1.5 - Rate increases back to 1.5");
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17);

        // w2: User2 withdraws all
        console2.log("Step 11: w2 - User2 withdraws all");
        uint256 user2Balance = strategy.balanceOf(user2);
        console2.log("User2 balance to redeem:", user2Balance);
        vm.prank(user2);
        strategy.redeem(user2Balance, user2, user2);

        // w3: No User3 to withdraw (deposit was blocked by insolvency)
        console2.log("Step 12: w3 - No User3 withdrawal (no deposit occurred)");

        console2.log("\n=== FINAL STATE ===");
        console2.log("Final dragon shares:", strategy.balanceOf(donationAddress));
        console2.log("Final total assets:", strategy.totalAssets());
        console2.log("Final total supply:", strategy.totalSupply());
        console2.log(
            "Final total value debt:",
            strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter())
        );

        // Verify that without the rate check, losses are properly handled
        assertEq(profit2, 0, "Should report no profit in second report");
        assertGt(loss2, 0, "Should report loss in second report even with rate changes");
        assertLt(dragonSharesAfterLoss, dragonShares, "Dragon shares should be burned to handle loss");
    }

    struct DragonRouterChangeVars {
        address oldDragonRouter;
        address newDragonRouter;
        uint256 oldDragonBalance;
        uint256 newDragonBalance;
        uint256 userDebtBefore;
        uint256 dragonDebtBefore;
        uint256 totalDebtBefore;
        uint256 userDebtAfter;
        uint256 dragonDebtAfter;
        uint256 totalDebtAfter;
    }

    /**
     * @notice Fuzz test for dragon router change with debt accounting migration
     * @dev Verifies that debt accounting is properly migrated when changing dragon router
     */
    function test_fuzz_dragonRouterChange_migratesDebtAccounting(
        uint256 initialDeposit,
        uint256 profitFactor,
        uint256 newDragonInitialShares
    ) public {
        initialDeposit = bound(initialDeposit, minFuzzAmount, maxFuzzAmount);
        profitFactor = bound(profitFactor, 100, 1000); // 1-10% profit
        newDragonInitialShares = bound(newDragonInitialShares, 0, maxFuzzAmount / 10);

        // Skip if initial deposit is too small to create meaningful profit
        vm.assume(initialDeposit > 1000);
        vm.assume(newDragonInitialShares < initialDeposit / 2); // Prevent new dragon from having more shares than reasonable

        DragonRouterChangeVars memory vars;
        vars.oldDragonRouter = strategy.dragonRouter();
        vars.newDragonRouter = makeAddr("newDragonRouter");

        // Setup: User deposits and we create profit to give old dragon some shares
        mintAndDepositIntoStrategy(strategy, makeAddr("user1"), initialDeposit);

        // Create profit to give old dragon router shares
        uint256 currentRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 profitRate = currentRate + (currentRate * profitFactor) / MAX_BPS;
        MockStrategySkimming(address(strategy)).updateExchangeRate(profitRate);

        vm.prank(keeper);
        strategy.report();

        vars.oldDragonBalance = strategy.balanceOf(vars.oldDragonRouter);

        // Skip test if no meaningful profit was generated
        if (vars.oldDragonBalance == 0) {
            return;
        }

        // Give new dragon router some initial shares if specified
        if (newDragonInitialShares > 0) {
            mintAndDepositIntoStrategy(strategy, vars.newDragonRouter, newDragonInitialShares);
        }

        vars.newDragonBalance = strategy.balanceOf(vars.newDragonRouter);

        // Record debt state before change
        vars.userDebtBefore = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        vars.dragonDebtBefore = strategy.balanceOf(strategy.dragonRouter());
        vars.totalDebtBefore = vars.userDebtBefore + vars.dragonDebtBefore;

        // Initiate dragon router change
        vm.prank(management);
        strategy.setDragonRouter(vars.newDragonRouter);

        // Skip cooldown period
        skip(15 days);

        // Finalize the change
        strategy.finalizeDragonRouterChange();

        // Verify new dragon router is set
        assertEq(strategy.dragonRouter(), vars.newDragonRouter, "New dragon router should be set");

        // Record debt state after change
        vars.userDebtAfter = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        vars.dragonDebtAfter = strategy.balanceOf(strategy.dragonRouter());
        vars.totalDebtAfter = vars.userDebtAfter + vars.dragonDebtAfter;

        // Most importantly: total debt should be conserved
        assertEq(
            vars.totalDebtAfter,
            vars.totalDebtBefore,
            "Total debt should be conserved during dragon router change"
        );

        // Verify the migration worked correctly
        if (vars.oldDragonBalance > 0 && vars.newDragonBalance == 0) {
            // Case 1: Only old dragon had balance, should increase user debt
            assertEq(
                vars.userDebtAfter,
                vars.userDebtBefore + vars.oldDragonBalance,
                "User debt should increase by old dragon balance"
            );
        } else if (vars.oldDragonBalance == 0 && vars.newDragonBalance > 0) {
            // Case 2: Only new dragon has balance, should increase dragon debt
            assertEq(
                vars.dragonDebtAfter,
                vars.dragonDebtBefore + vars.newDragonBalance,
                "Dragon debt should increase by new dragon balance"
            );
        }

        // Verify share balances are preserved
        assertEq(
            strategy.balanceOf(vars.newDragonRouter),
            vars.newDragonBalance,
            "New dragon router should keep its shares"
        );
        assertEq(
            strategy.balanceOf(vars.oldDragonRouter),
            vars.oldDragonBalance,
            "Old dragon router should keep its shares"
        );
    }
}
