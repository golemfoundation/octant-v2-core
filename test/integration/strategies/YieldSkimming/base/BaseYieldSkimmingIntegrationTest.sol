// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";
import { BaseIntegrationTest } from "../../base/BaseIntegrationTest.sol";
import { TestState, FuzzTestState, ProfitFuzzTestState, ProfitLossTestData, DragonWithdrawalTestData } from "../../base/TestStructs.sol";

/// @title BaseYieldSkimmingIntegrationTest
/// @notice Base contract for all yield skimming strategy integration tests
/// @dev Provides shared test implementations that can be called from concrete test contracts
abstract contract BaseYieldSkimmingIntegrationTest is BaseIntegrationTest {
    using SafeERC20 for ERC20;
    using WadRayMath for uint256;

    // ========== STATE VARIABLES ==========

    /// @notice Implementation of YieldSkimmingTokenizedStrategy
    YieldSkimmingTokenizedStrategy public implementation;

    // ========== ABSTRACT METHODS ==========

    /// @notice Returns the concrete strategy address
    function _strategy() internal view virtual returns (address);

    /// @notice Returns the exchange rate function selector for mocking
    function _exchangeRateSelector() internal view virtual returns (string memory);

    /// @notice Etches the implementation bytecode to the expected address (if needed)
    function _etchImplementation() internal virtual;

    // ========== MOCK HELPERS ==========

    /// @notice Mocks the exchange rate for the underlying asset
    /// @param newRate The new exchange rate to mock
    function _mockExchangeRate(uint256 newRate) internal {
        vm.mockCall(_asset(), abi.encodeWithSignature(_exchangeRateSelector()), abi.encode(newRate));
    }

    /// @notice Clears all mocked calls
    function _clearMocks() internal {
        vm.clearMockedCalls();
    }

    // ========== SHARED TEST IMPLEMENTATIONS ==========

    /// @notice Test that the strategy is properly initialized
    function _testInitialization() internal view {
        assertEq(IERC4626(address(vault)).asset(), _asset(), "Asset address incorrect");
        assertEq(vault.management(), management, "Management address incorrect");
        assertEq(vault.keeper(), keeper, "Keeper address incorrect");
        assertEq(vault.emergencyAdmin(), emergencyAdmin, "Emergency admin incorrect");
        assertGt(
            IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate(),
            0,
            "Exchange rate should be initialized"
        );
    }

    /// @notice Test basic deposit functionality
    /// @param depositAmount Amount to deposit
    function _testDeposit(uint256 depositAmount) internal {
        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );
        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertGt(vault.totalAssets(), 0, "Strategy should have deployed assets");
    }

    /// @notice Fuzz test depositing assets into the strategy
    /// @param depositAmount Amount to deposit (will be bounded)
    function _testFuzzDeposit(uint256 depositAmount) internal {
        depositAmount = bound(depositAmount, 0.01e18, 10000e18);
        airdrop(ERC20(_asset()), user, depositAmount);

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );
        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertGt(vault.totalAssets(), 0, "Strategy should have deployed assets");
    }

    /// @notice Fuzz test withdrawing assets from the strategy
    /// @param depositAmount Amount to deposit (will be bounded)
    /// @param withdrawPercentage Percentage to withdraw (1-100)
    function _testFuzzWithdraw(uint256 depositAmount, uint256 withdrawPercentage) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);
        withdrawPercentage = bound(withdrawPercentage, 1, 100);

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);
        uint256 initialShareBalance = vault.balanceOf(user);

        uint256 sharesToBurn = (vault.balanceOf(user) * withdrawPercentage) / 100;
        uint256 withdrawnAmount = vault.redeem(sharesToBurn, user, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance + withdrawnAmount,
            "User didn't receive correct assets"
        );
        assertEq(vault.balanceOf(user), initialShareBalance - sharesToBurn, "Shares not burned correctly");
    }

    /// @notice Fuzz test harvesting with profit
    /// @param depositAmount Amount to deposit
    /// @param profitPercentage Profit percentage (1-99)
    function _testFuzzHarvestWithProfit(uint256 depositAmount, uint256 profitPercentage) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);
        profitPercentage = bound(profitPercentage, 1, 99);

        ProfitFuzzTestState memory state;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        state.totalAssetsBefore = vault.totalAssets();
        state.initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        state.newExchangeRate = (state.initialExchangeRate * (100 + profitPercentage)) / 100;

        _mockExchangeRate(state.newExchangeRate);

        state.donationAddressBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        _clearMocks();

        assertGt(profit, 0, "Profit should be positive");
        assertEq(loss, 0, "There should be no loss");

        state.donationAddressBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);

        assertGt(
            state.donationAddressBalanceAfter,
            state.donationAddressBalanceBefore,
            "Donation address should have received profit"
        );

        state.totalAssetsAfter = vault.totalAssets();
        assertEq(state.totalAssetsAfter, state.totalAssetsBefore, "Total assets should not change after harvest");

        // Maintain solvency for redemption
        _mockExchangeRate(state.newExchangeRate);

        vm.startPrank(donationAddress);
        state.donationAssetsReceived = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();
        _clearMocks();

        vm.startPrank(user);
        state.sharesToRedeem = vault.balanceOf(user);
        state.assetsReceived = vault.redeem(state.sharesToRedeem, user, user);
        vm.stopPrank();

        assertApproxEqRel(
            state.donationAssetsReceived,
            (depositAmount * profitPercentage) / (100 + profitPercentage),
            0.1e16,
            "Donation address should have received profit"
        );

        assertApproxEqRel(
            state.assetsReceived * state.newExchangeRate,
            depositAmount * state.initialExchangeRate,
            0.1e16,
            "User should receive original deposit"
        );
    }

    /// @notice Test multiple users with fair profit distribution
    function _testMultipleUserProfitDistribution() internal {
        TestState memory state;

        state.user1 = user;
        state.user2 = address(0x5678);
        state.depositAmount1 = 1000e18;
        state.depositAmount2 = 2000e18;

        state.initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();

        vm.startPrank(state.user1);
        vault.deposit(state.depositAmount1, state.user1);
        vm.stopPrank();

        state.newExchangeRate1 = (state.initialExchangeRate * 110) / 100;
        state.donationBalanceBefore1 = ERC20(address(vault)).balanceOf(donationAddress);

        _mockExchangeRate(state.newExchangeRate1);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        state.donationBalanceAfter1 = ERC20(address(vault)).balanceOf(donationAddress);

        assertGt(
            state.donationBalanceAfter1,
            state.donationBalanceBefore1,
            "Donation address should have received profit after first harvest"
        );

        airdrop(ERC20(_asset()), state.user2, state.depositAmount2);

        vm.startPrank(state.user2);
        ERC20(_asset()).approve(address(vault), type(uint256).max);
        vault.deposit(state.depositAmount2, state.user2);
        vm.stopPrank();

        _clearMocks();

        state.newExchangeRate2 = (state.newExchangeRate1 * 105) / 100;
        state.donationBalanceBefore2 = ERC20(address(vault)).balanceOf(donationAddress);

        _mockExchangeRate(state.newExchangeRate2);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        _clearMocks();

        state.donationBalanceAfter2 = ERC20(address(vault)).balanceOf(donationAddress);

        assertGt(
            state.donationBalanceAfter2,
            state.donationBalanceBefore2,
            "Donation address should have received profit after second harvest"
        );

        _mockExchangeRate(state.newExchangeRate2);

        vm.startPrank(donationAddress);
        vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        vm.startPrank(state.user1);
        state.user1Shares = vault.balanceOf(state.user1);
        state.user1Assets = vault.redeem(vault.balanceOf(state.user1), state.user1, state.user1);
        vm.stopPrank();

        vm.startPrank(state.user2);
        state.user2Shares = vault.balanceOf(state.user2);
        state.user2Assets = vault.redeem(vault.balanceOf(state.user2), state.user2, state.user2);
        vm.stopPrank();

        _clearMocks();

        assertApproxEqRel(
            state.user1Assets * state.newExchangeRate2,
            state.depositAmount1 * state.initialExchangeRate,
            0.000001e18,
            "User 1 should receive deposit adjusted for exchange rate change"
        );

        assertApproxEqRel(
            state.user2Assets * state.newExchangeRate2,
            state.depositAmount2 * state.newExchangeRate1,
            0.00001e18,
            "User 2 should receive deposit adjusted for exchange rate change"
        );
    }

    /// @notice Test basic harvest functionality
    /// @param depositAmount Amount to deposit
    function _testHarvest(uint256 depositAmount) internal {
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialAssets = vault.totalAssets();
        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        uint256 newExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 newTotalAssets = vault.totalAssets();

        _mockExchangeRate((newExchangeRate * 11) / 10);

        assertEq(newExchangeRate, initialExchangeRate, "Exchange rate should be updated after harvest");
        assertGe(newTotalAssets, initialAssets, "Total assets should not decrease after harvest");
    }

    /// @notice Fuzz test emergency exit functionality
    /// @param depositAmount Amount to deposit
    function _testFuzzEmergencyExit(uint256 depositAmount) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();
        vault.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(
            assetsReceived,
            depositAmount,
            0.001e18,
            "User should receive approximately original deposit value"
        );
    }

    /// @notice Fuzz test exchange rate tracking and yield calculation
    /// @param depositAmount Amount to deposit
    /// @param exchangeRateIncreasePercentage Percentage increase (1-99)
    function _testFuzzExchangeRateTracking(uint256 depositAmount, uint256 exchangeRateIncreasePercentage) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);
        exchangeRateIncreasePercentage = bound(exchangeRateIncreasePercentage, 1, 99);

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 newExchangeRate = (initialExchangeRate * (100 + exchangeRateIncreasePercentage)) / 100;

        _mockExchangeRate(newExchangeRate);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        _clearMocks();

        assertGt(profit, 0, "Should have captured profit from exchange rate increase");
        assertEq(loss, 0, "Should have no loss");

        uint256 updatedExchangeRate = IYieldSkimmingStrategy(_strategy()).getLastRateRay().rayToWad();

        assertApproxEqRel(
            updatedExchangeRate,
            newExchangeRate,
            0.000001e18,
            "Exchange rate should be updated after harvest"
        );
    }

    /// @notice Test getting the current exchange rate
    function _testGetCurrentExchangeRate() internal view {
        uint256 rate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        assertGt(rate, 0, "Exchange rate should be initialized and greater than zero");
    }

    /// @notice Test balance of asset and shares
    /// @param depositAmount Amount to deposit
    function _testBalanceOfAssetAndShares(uint256 depositAmount) internal {
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssets = vault.totalAssets();
        assertGt(totalAssets, 0, "Total assets should be greater than zero after deposit");
    }

    /// @notice Test health check for profit limit exceeded
    /// @param depositAmount Amount to deposit
    function _testHealthCheckProfitLimitExceeded(uint256 depositAmount) internal {
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 newExchangeRate = (initialExchangeRate * 7) / 3; // 233%
        _mockExchangeRate(newExchangeRate);

        vm.startPrank(keeper);
        vm.expectRevert("!profit");
        vault.report();
        vm.stopPrank();

        _clearMocks();
    }

    /// @notice Test health check when doHealthCheck is false
    function _testHealthCheckProfitLimitExceededWhenDoHealthCheckIsFalse() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setDoHealthCheck(false);
        vm.stopPrank();

        assertEq(strat.doHealthCheck(), false);

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        _mockExchangeRate(initialExchangeRate * 10);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        assertEq(strat.doHealthCheck(), true);
    }

    /// @notice Test change profit limit ratio
    function _testChangeProfitLimitRatio() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setProfitLimitRatio(5000);
        vm.stopPrank();

        assertEq(strat.profitLimitRatio(), 5000);
    }

    /// @notice Test set doHealthCheck to false
    function _testSetDoHealthCheckToFalse() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setDoHealthCheck(false);
        vm.stopPrank();

        assertEq(strat.doHealthCheck(), false);
    }

    /// @notice Test tendTrigger always returns false
    function _testTendTriggerAlwaysFalse() internal view {
        (bool trigger, ) = IBaseStrategy(_strategy()).tendTrigger();
        assertEq(trigger, false, "Tend trigger should always be false");
    }

    /// @notice Fuzz test basic loss scenario with single user
    function _testFuzzHarvestWithLoss(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);
        profitPercentage = bound(profitPercentage, 5, 50);
        lossPercentage = bound(lossPercentage, 1, 19);

        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(2000);
        vm.stopPrank();

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 profitExchangeRate = (initialExchangeRate * (100 + profitPercentage)) / 100;

        _mockExchangeRate(profitExchangeRate);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        _clearMocks();

        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        assertGt(donationSharesBefore, 0, "Donation address should have shares for loss protection");

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 userSharesBefore = vault.balanceOf(user);

        uint256 lossExchangeRate = (profitExchangeRate * (100 - lossPercentage)) / 100;
        _mockExchangeRate(lossExchangeRate);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        _clearMocks();

        assertEq(profit, 0, "Profit should be zero");
        assertGt(loss, 0, "Loss should be positive");

        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertLt(donationSharesAfter, donationSharesBefore, "Donation shares should be burned for loss protection");

        uint256 userSharesAfter = vault.balanceOf(user);
        assertEq(userSharesAfter, userSharesBefore, "User shares should not change due to loss protection");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets should be the same before and after loss");
    }

    /// @notice Test loss scenario where loss exceeds available donation shares
    function _testLossExceedingDonationShares() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(1500);
        vm.stopPrank();

        uint256 depositAmount = 1000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 smallProfitRate = (initialExchangeRate * 1005) / 1000;
        _mockExchangeRate(smallProfitRate);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();
        _clearMocks();

        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        uint256 userSharesBefore = vault.balanceOf(user);

        uint256 largeLossRate = (initialExchangeRate * 90) / 100;
        _mockExchangeRate(largeLossRate);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit, 0, "Should have no profit");
        assertGt(loss, 0, "Should have reported loss");

        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertLt(donationSharesAfter, donationSharesBefore, "Some donation shares should be burned");

        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not be burned");

        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        assertLt(
            assetsReceived * largeLossRate,
            depositAmount * initialExchangeRate,
            "User should receive less due to insufficient loss protection"
        );
    }

    /// @notice Test consecutive loss scenarios
    function _testConsecutiveLosses() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(1500);
        vm.stopPrank();

        uint256 depositAmount = 1000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 profitRate = (initialExchangeRate * 120) / 100;
        _mockExchangeRate(profitRate);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();
        _clearMocks();

        uint256 donationSharesAfterProfit = vault.balanceOf(donationAddress);
        assertGt(donationSharesAfterProfit, 0, "Should have donation shares after profit");

        uint256 firstLossRate = (profitRate * 95) / 100;
        _mockExchangeRate(firstLossRate);

        vm.startPrank(keeper);
        (uint256 profit1, uint256 loss1) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit1, 0, "Should have no profit in first loss");
        assertGt(loss1, 0, "Should have loss in first report");

        uint256 donationSharesAfterFirstLoss = vault.balanceOf(donationAddress);
        assertLt(
            donationSharesAfterFirstLoss,
            donationSharesAfterProfit,
            "Donation shares should decrease after first loss"
        );

        uint256 secondLossRate = (firstLossRate * 95) / 100;
        _mockExchangeRate(secondLossRate);

        vm.startPrank(keeper);
        (uint256 profit2, uint256 loss2) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit2, 0, "Should have no profit in second loss");
        assertGt(loss2, 0, "Should have loss in second report");

        uint256 donationSharesAfterSecondLoss = vault.balanceOf(donationAddress);
        assertLe(
            donationSharesAfterSecondLoss,
            donationSharesAfterFirstLoss,
            "Donation shares should decrease or stay same after second loss"
        );

        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "User should receive some assets");
    }

    /// @notice Test that loss protection works correctly with zero donation shares
    function _testLossWithZeroDonationShares() internal {
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(1000);
        vm.stopPrank();

        uint256 depositAmount = 1000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        assertEq(donationSharesBefore, 0, "Should have no donation shares initially");

        uint256 userSharesBefore = vault.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        uint256 lossRate = (initialExchangeRate * 95) / 100;
        _mockExchangeRate(lossRate);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit, 0, "Should have no profit");
        assertGt(loss, 0, "Should have reported loss");

        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertEq(donationSharesAfter, 0, "Should still have no donation shares");

        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not change");

        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets should be the same before and after loss");

        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        assertLt(
            assetsReceived * lossRate,
            depositAmount * initialExchangeRate,
            "User should receive less due to no loss protection"
        );
    }

    /// @notice Fuzz test consecutive loss scenarios
    function _testFuzzConsecutiveLosses(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 firstLossPercentage,
        uint256 secondLossPercentage
    ) internal {
        depositAmount = bound(depositAmount, 1e18, 10000e18);
        profitPercentage = bound(profitPercentage, 10, 50);
        firstLossPercentage = bound(firstLossPercentage, 1, 10);
        secondLossPercentage = bound(secondLossPercentage, 1, 10);

        FuzzTestState memory state;
        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(2000);
        vm.stopPrank();

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        state.initialExchangeRate = IYieldSkimmingStrategy(_strategy()).getCurrentExchangeRate();
        state.profitRate = (state.initialExchangeRate * (100 + profitPercentage)) / 100;
        _mockExchangeRate(state.profitRate);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();
        _clearMocks();

        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(user)) * state.profitRate,
            depositAmount * state.initialExchangeRate,
            0.01e16,
            "Withdrawable underlying value should match deposit"
        );

        state.donationSharesAfterProfit = vault.balanceOf(donationAddress);
        assertGt(state.donationSharesAfterProfit, 0, "Should have donation shares after profit");

        state.firstLossRate = (state.profitRate * (100 - firstLossPercentage)) / 100;
        _mockExchangeRate(state.firstLossRate);

        vm.startPrank(keeper);
        (uint256 profit1, uint256 loss1) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit1, 0, "Should have no profit in first loss");
        assertGt(loss1, 0, "Should have loss in first report");

        state.donationSharesAfterFirstLoss = vault.balanceOf(donationAddress);
        assertLt(
            state.donationSharesAfterFirstLoss,
            state.donationSharesAfterProfit,
            "Donation shares should decrease after first loss"
        );

        state.secondLossRate = (state.firstLossRate * (100 - secondLossPercentage)) / 100;
        _mockExchangeRate(state.secondLossRate);

        vm.startPrank(keeper);
        (uint256 profit2, uint256 loss2) = vault.report();
        vm.stopPrank();
        _clearMocks();

        assertEq(profit2, 0, "Should have no profit in second loss");
        assertGt(loss2, 0, "Should have loss in second report");

        state.donationSharesAfterSecondLoss = vault.balanceOf(donationAddress);
        assertLe(
            state.donationSharesAfterSecondLoss,
            state.donationSharesAfterFirstLoss,
            "Donation shares should decrease or stay same after second loss"
        );

        vm.startPrank(user);
        state.assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        uint256 initialValue = depositAmount * state.initialExchangeRate;
        uint256 receivedValue = state.assetsReceived * state.secondLossRate;

        if (state.secondLossRate < state.initialExchangeRate) {
            assertLe(receivedValue, initialValue, "User cannot receive more than initial deposit when net loss occurs");
        } else {
            assertApproxEqRel(
                receivedValue,
                initialValue,
                3e16,
                "User should receive about the same as deposit when net gain occurs"
            );
        }
    }

    /// @notice Test profit then loss scenario with proper dragon share burning
    function _test_profitThenLoss_dragonSharesBurnCorrectly() internal {
        ProfitLossTestData memory data;

        data.user1 = makeAddr("user1");
        data.user2 = makeAddr("user2");
        data.depositAmount1 = 100e18;
        data.depositAmount2 = 150e18;
        data.initialRate = 1e18;
        data.increasedRate = (1e18 * 15) / 10;

        airdrop(ERC20(_asset()), data.user1, data.depositAmount1);
        airdrop(ERC20(_asset()), data.user2, data.depositAmount2);

        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(5000);
        vm.stopPrank();

        _mockExchangeRate(data.initialRate);

        vm.startPrank(data.user1);
        ERC20(_asset()).approve(address(vault), data.depositAmount1);
        data.user1Shares = vault.deposit(data.depositAmount1, data.user1);
        vm.stopPrank();

        assertEq(data.user1Shares, data.depositAmount1, "User1 should receive shares at 1:1 rate");
        assertEq(vault.totalAssets(), data.depositAmount1, "Total assets should match deposit");

        _clearMocks();

        _mockExchangeRate(data.increasedRate);

        vm.startPrank(data.user2);
        ERC20(_asset()).approve(address(vault), data.depositAmount2);
        data.user2Shares = vault.deposit(data.depositAmount2, data.user2);
        vm.stopPrank();

        assertEq(data.user2Shares, 225e18, "User2 should receive shares at 1.5x rate");
        assertEq(vault.totalAssets(), 250e18, "Total assets should be 250e18 after both deposits");

        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();
        data.dragonShares = vault.balanceOf(donationAddress);

        assertEq(data.profit1, 33333333333333333333, "Should report expected profit");
        assertEq(data.loss1, 0, "Should report no loss in first report");
        assertEq(data.dragonShares, 50e18, "Dragon shares should be 50e18");
        assertEq(vault.totalSupply(), 375e18, "Total supply should include dragon shares");

        _clearMocks();
        _mockExchangeRate(data.initialRate);

        vm.startPrank(data.user1);
        data.user1Assets = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        assertEq(data.user1Assets, 66666666666666666666, "User1 should receive expected assets");
        assertEq(vault.balanceOf(data.user1), 0, "User1 should have no shares left");

        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();
        data.dragonSharesAfterLoss = vault.balanceOf(donationAddress);

        assertEq(data.profit2, 0, "Should report no profit in second report");
        assertEq(data.loss2, 91666666666666666666, "Should report expected loss");
        assertEq(data.dragonSharesAfterLoss, 0, "All dragon shares should be burned");

        _clearMocks();
        _mockExchangeRate(data.increasedRate);

        vm.startPrank(data.user2);
        data.user2Assets = vault.redeem(vault.balanceOf(data.user2), data.user2, data.user2);
        vm.stopPrank();

        assertEq(IYieldSkimmingStrategy(address(vault)).isVaultInsolvent(), false, "Vault should be solvent");
        assertEq(data.user2Assets, 150e18, "User2 should receive expected assets");
        assertEq(vault.balanceOf(data.user2), 0, "User2 should have no shares left");

        uint256 remainingDragonShares = vault.balanceOf(donationAddress);
        uint256 remainingAssets = vault.totalAssets();

        assertEq(remainingDragonShares, 0, "All dragon shares should be burned");
        assertEq(vault.totalSupply(), 0, "All shares should be withdrawn");
        assertEq(remainingAssets, 33333333333333333334, "Expected remaining assets from uncovered loss");
    }

    /// @notice Test dragon router withdrawal followed by rate recovery - user should have no loss
    function _test_dragonRouterWithdrawal_rateRecovery_userNoLoss() internal {
        DragonWithdrawalTestData memory data;

        data.user1 = makeAddr("user1");
        data.depositAmount = 100e18;
        data.initialRate = 1e18;
        data.increasedRate = (1e18 * 15) / 10;
        data.decreasedRate = 1e18;

        airdrop(ERC20(_asset()), data.user1, data.depositAmount);

        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(5000);
        vm.stopPrank();

        _mockExchangeRate(data.initialRate);

        vm.startPrank(data.user1);
        ERC20(_asset()).approve(address(vault), data.depositAmount);
        data.user1Shares = vault.deposit(data.depositAmount, data.user1);
        vm.stopPrank();

        assertEq(data.user1Shares, 100e18, "User1 should receive shares at 1:1 rate");

        _clearMocks();

        _mockExchangeRate(data.increasedRate);

        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();

        data.dragonSharesAfterProfit = vault.balanceOf(donationAddress);

        assertEq(data.profit1, 33333333333333333333, "Should report expected profit");
        assertEq(data.loss1, 0, "Should report no loss");
        assertEq(data.dragonSharesAfterProfit, 50e18, "Dragon shares should be 50e18");

        vm.startPrank(donationAddress);
        data.dragonAssets = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        assertEq(data.dragonAssets, 33333333333333333333, "Dragon should receive expected assets");
        assertEq(vault.balanceOf(donationAddress), 0, "Dragon should have no shares after withdrawal");

        _clearMocks();

        _mockExchangeRate(data.decreasedRate);

        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();

        assertEq(data.profit2, 0, "Should report no profit");
        assertEq(data.loss2, 33333333333333333333, "Should report expected loss");
        assertEq(vault.balanceOf(donationAddress), 0, "Still no dragon shares to burn");

        _clearMocks();

        _mockExchangeRate(data.increasedRate);

        vm.startPrank(keeper);
        (data.profit3, data.loss3) = vault.report();
        vm.stopPrank();

        assertEq(data.profit3, 0, "Should report no profit (exactly breaks even)");
        assertEq(data.loss3, 0, "Should report no loss");

        vm.startPrank(data.user1);
        data.assetsReceived = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        assertEq(data.assetsReceived, 66666666666666666666, "User should receive expected assets");

        uint256 depositValue = (data.depositAmount * data.initialRate) / 1e18;
        uint256 withdrawValue = (data.assetsReceived * data.increasedRate) / 1e18;
        assertApproxEqAbs(withdrawValue, depositValue, 1e15, "User should have no loss in ETH value terms");
    }

    /// @notice Test dragon router withdrawal followed by rate decline - user should experience loss
    function _test_dragonRouterWithdrawal_rateDecline_userLoss() internal {
        DragonWithdrawalTestData memory data;

        data.user1 = makeAddr("user1");
        data.depositAmount = 100e18;
        data.initialRate = 1e18;
        data.increasedRate = (1e18 * 15) / 10;
        data.decreasedRate = 1e18;
        data.finalRate = (1e18 * 9) / 10;

        airdrop(ERC20(_asset()), data.user1, data.depositAmount);

        IBaseHealthCheck strat = IBaseHealthCheck(_strategy());

        vm.startPrank(management);
        strat.setLossLimitRatio(5000);
        vm.stopPrank();

        _mockExchangeRate(data.initialRate);

        vm.startPrank(data.user1);
        ERC20(_asset()).approve(address(vault), data.depositAmount);
        data.user1Shares = vault.deposit(data.depositAmount, data.user1);
        vm.stopPrank();

        assertEq(data.user1Shares, 100e18, "User1 should receive shares at 1:1 rate");

        _clearMocks();

        _mockExchangeRate(data.increasedRate);

        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();

        data.dragonSharesAfterProfit = vault.balanceOf(donationAddress);

        assertEq(data.profit1, 33333333333333333333, "Should report expected profit");
        assertEq(data.loss1, 0, "Should report no loss");
        assertEq(data.dragonSharesAfterProfit, 50e18, "Dragon shares should be 50e18");

        vm.startPrank(donationAddress);
        data.dragonAssets = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        assertEq(data.dragonAssets, 33333333333333333333, "Dragon should receive expected assets");
        assertEq(vault.balanceOf(donationAddress), 0, "Dragon should have no shares after withdrawal");

        _clearMocks();

        _mockExchangeRate(data.decreasedRate);

        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();

        assertEq(data.profit2, 0, "Should report no profit");
        assertEq(data.loss2, 33333333333333333333, "Should report expected loss");
        assertEq(vault.balanceOf(donationAddress), 0, "Still no dragon shares to burn");

        _clearMocks();

        _mockExchangeRate(data.finalRate);

        vm.startPrank(data.user1);
        data.assetsReceived = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        assertEq(data.assetsReceived, 66666666666666666667, "User should receive expected assets");

        uint256 depositValue = (data.depositAmount * data.initialRate) / 1e18;
        uint256 withdrawValue = (data.assetsReceived * data.finalRate) / 1e18;

        assertLt(withdrawValue, depositValue, "User should receive less ETH value than deposited");

        uint256 actualLoss = depositValue - withdrawValue;
        assertApproxEqAbs(actualLoss, 40e18, 1e15, "User should experience ~40e18 ETH loss (40%)");

        uint256 lossPercentage = (actualLoss * 100) / depositValue;
        assertEq(lossPercentage, 40, "User should experience exactly 40% loss");
    }
}
