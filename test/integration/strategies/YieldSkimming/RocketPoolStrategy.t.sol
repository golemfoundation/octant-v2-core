// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { RocketPoolStrategy } from "src/strategies/yieldSkimming/RocketPoolStrategy.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { BaseYieldSkimmingIntegrationTest } from "./base/BaseYieldSkimmingIntegrationTest.sol";
import { RocketPoolTestConfig } from "../config/RocketPoolTestConfig.sol";

/// @title RocketPool Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the RocketPool strategy using a mainnet fork
contract RocketPoolStrategyTest is BaseYieldSkimmingIntegrationTest {
    // ========== STATE VARIABLES ==========

    RocketPoolStrategy public rocketPoolStrategy;
    RocketPoolStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return RocketPoolTestConfig.R_ETH;
    }

    function _strategyName() internal pure override returns (string memory) {
        return RocketPoolTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return RocketPoolTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return RocketPoolTestConfig.INITIAL_DEPOSIT;
    }

    function _strategy() internal view override returns (address) {
        return address(rocketPoolStrategy);
    }

    function _exchangeRateSelector() internal pure override returns (string memory) {
        return RocketPoolTestConfig.EXCHANGE_RATE_SELECTOR;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        // RocketPool doesn't need etching - uses implementation directly
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new RocketPoolStrategyFactory();

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        rocketPoolStrategy = RocketPoolStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(rocketPoolStrategy), "RocketPool");
        vm.label(address(factory), "RocketPoolStrategyFactory");
        vm.label(RocketPoolTestConfig.R_ETH, "R_ETH");
        vm.label(RocketPoolTestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
    }

    function setUp() public {
        _baseSetUp();
    }

    // ========== TESTS - Delegating to base implementations ==========

    function testInitializationRocket() public view {
        _testInitialization();
    }

    function testFuzzDepositRocket(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawPercentage) public {
        _testFuzzWithdraw(depositAmount, withdrawPercentage);
    }

    function testFuzzHarvestWithProfitRocket(uint256 depositAmount, uint256 profitPercentage) public {
        _testFuzzHarvestWithProfit(depositAmount, profitPercentage);
    }

    function testMultipleUserProfitDistributionRocket() public {
        _testMultipleUserProfitDistribution();
    }

    function testHarvestRocket() public {
        _testHarvest(100e18);
    }

    function testFuzzEmergencyExit(uint256 depositAmount) public {
        _testFuzzEmergencyExit(depositAmount);
    }

    function testFuzzExchangeRateTrackingRocket(uint256 depositAmount, uint256 exchangeRateIncreasePercentage) public {
        _testFuzzExchangeRateTracking(depositAmount, exchangeRateIncreasePercentage);
    }

    function testgetCurrentExchangeRate() public view {
        _testGetCurrentExchangeRate();
    }

    function testBalanceOfAssetAndShares() public {
        _testBalanceOfAssetAndShares(100e18);
    }

    function testHealthCheckProfitLimitExceeded() public {
        _testHealthCheckProfitLimitExceeded(1000e18);
    }

    function testHealthCheckProfitLimitExceededWhenDoHealthCheckIsFalse() public {
        _testHealthCheckProfitLimitExceededWhenDoHealthCheckIsFalse();
    }

    function testChangeProfitLimitRatio() public {
        _testChangeProfitLimitRatio();
    }

    function testSetDoHealthCheckToFalse() public {
        _testSetDoHealthCheckToFalse();
    }

    function testTendTriggerAlwaysFalse() public view {
        _testTendTriggerAlwaysFalse();
    }

    function testFuzzHarvestWithLossRocket(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) public {
        _testFuzzHarvestWithLoss(depositAmount, profitPercentage, lossPercentage);
    }

    function testLossExceedingDonationSharesRocket() public {
        _testLossExceedingDonationShares();
    }

    function testConsecutiveLossesRocket() public {
        _testConsecutiveLosses();
    }

    function testLossWithZeroDonationSharesRocket() public {
        _testLossWithZeroDonationShares();
    }

    function testFuzzConsecutiveLossesRocket(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 firstLossPercentage,
        uint256 secondLossPercentage
    ) public {
        _testFuzzConsecutiveLosses(depositAmount, profitPercentage, firstLossPercentage, secondLossPercentage);
    }

    function test_profitThenLoss_dragonSharesBurnCorrectly() public {
        _test_profitThenLoss_dragonSharesBurnCorrectly();
    }

    function test_dragonRouterWithdrawal_rateRecovery_userNoLoss() public {
        _test_dragonRouterWithdrawal_rateRecovery_userNoLoss();
    }

    function test_dragonRouterWithdrawal_rateDecline_userLoss() public {
        _test_dragonRouterWithdrawal_rateDecline_userLoss();
    }
}
