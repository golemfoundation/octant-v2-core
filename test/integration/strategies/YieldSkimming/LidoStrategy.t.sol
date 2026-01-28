// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { BaseYieldSkimmingIntegrationTest } from "./base/BaseYieldSkimmingIntegrationTest.sol";
import { LidoTestConfig } from "../config/LidoTestConfig.sol";

/// @title Lido Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the Lido strategy using a mainnet fork
contract LidoStrategyTest is BaseYieldSkimmingIntegrationTest {
    // ========== STATE VARIABLES ==========

    LidoStrategy public lidoStrategy;
    LidoStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return LidoTestConfig.WSTETH;
    }

    function _strategyName() internal pure override returns (string memory) {
        return LidoTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return LidoTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return LidoTestConfig.INITIAL_DEPOSIT;
    }

    function _strategy() internal view override returns (address) {
        return address(lidoStrategy);
    }

    function _exchangeRateSelector() internal pure override returns (string memory) {
        return LidoTestConfig.EXCHANGE_RATE_SELECTOR;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(LidoTestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new LidoStrategyFactory();

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

        lidoStrategy = LidoStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(lidoStrategy), "Lido");
        vm.label(address(factory), "LidoStrategyFactory");
        vm.label(LidoTestConfig.WSTETH, "WSTETH");
        vm.label(LidoTestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
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

    function testInitializationLido() public view {
        _testInitialization();
    }

    function testDepositLido() public {
        _testDeposit(100e18);
    }

    function testFuzzDepositLido(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawPercentage) public {
        _testFuzzWithdraw(depositAmount, withdrawPercentage);
    }

    function testFuzzHarvestWithProfitLido(uint256 depositAmount, uint256 profitPercentage) public {
        _testFuzzHarvestWithProfit(depositAmount, profitPercentage);
    }

    function testMultipleUserProfitDistributionLido() public {
        _testMultipleUserProfitDistribution();
    }

    function testHarvestLido() public {
        _testHarvest(100e18);
    }

    function testFuzzEmergencyExit(uint256 depositAmount) public {
        _testFuzzEmergencyExit(depositAmount);
    }

    function testFuzzExchangeRateTrackingLido(uint256 depositAmount, uint256 exchangeRateIncreasePercentage) public {
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

    function testFuzzHarvestWithLossLido(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) public {
        _testFuzzHarvestWithLoss(depositAmount, profitPercentage, lossPercentage);
    }

    function testLossExceedingDonationSharesLido() public {
        _testLossExceedingDonationShares();
    }

    function testConsecutiveLossesLido() public {
        _testConsecutiveLosses();
    }

    function testLossWithZeroDonationSharesLido() public {
        _testLossWithZeroDonationShares();
    }

    function testFuzzConsecutiveLossesLido(
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
