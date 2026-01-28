// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { RocketPoolStrategy } from "src/strategies/yieldSkimming/RocketPoolStrategy.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { PrivilegedYieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/PrivilegedYieldSkimmingTokenizedStrategy.sol";
import { BasePrivilegedYieldSkimmingIntegrationTest } from "./base/BasePrivilegedYieldSkimmingIntegrationTest.sol";
import { IPrivilegedStrategy } from "../base/BasePrivilegedIntegrationTest.sol";
import { RocketPoolTestConfig } from "../config/RocketPoolTestConfig.sol";

/// @title Privileged RocketPool Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the privileged yield skimming RocketPool strategy
contract PrivilegedRocketPoolStrategyTest is BasePrivilegedYieldSkimmingIntegrationTest {
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

    function _minDeposit() internal pure override returns (uint256) {
        return RocketPoolTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return RocketPoolTestConfig.MAX_DEPOSIT;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        // Use PrivilegedYieldSkimmingTokenizedStrategy instead of regular YieldSkimmingTokenizedStrategy
        implementation = new PrivilegedYieldSkimmingTokenizedStrategy{
            salt: keccak256("OCT_PRIVILEGED_YIELD_SKIMMING_STRATEGY_V1")
        }();
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
        vm.label(address(rocketPoolStrategy), "PrivilegedRocketPool");
        vm.label(address(factory), "RocketPoolStrategyFactory");
        vm.label(RocketPoolTestConfig.R_ETH, "R_ETH");
        vm.label(RocketPoolTestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
        vm.label(privilegedUser, "Privileged User");
        vm.label(nonPrivilegedUser, "Non-Privileged User");
    }

    function setUp() public {
        _privilegedBaseSetUp();
    }

    // ========== PRIVILEGED ACCESS CONTROL TESTS ==========

    function testSetPrivilegedOnlyManagement() public {
        _testSetPrivilegedOnlyManagement();
    }

    function testSetPrivilegedByManagement() public {
        _testSetPrivilegedByManagement();
    }

    function testSetPrivilegedBatchOnlyManagement() public {
        _testSetPrivilegedBatchOnlyManagement();
    }

    function testSetPrivilegedBatchByManagement() public {
        _testSetPrivilegedBatchByManagement();
    }

    function testDepositRevertsWhenSenderNotPrivileged() public {
        _testDepositRevertsWhenSenderNotPrivileged();
    }

    function testDepositRevertsWhenReceiverNotPrivileged() public {
        _testDepositRevertsWhenReceiverNotPrivileged();
    }

    function testDepositSucceedsWhenBothPrivileged() public {
        _testDepositSucceedsWhenBothPrivileged();
    }

    function testMintRevertsWhenSenderNotPrivileged() public {
        _testMintRevertsWhenSenderNotPrivileged();
    }

    function testMintRevertsWhenReceiverNotPrivileged() public {
        _testMintRevertsWhenReceiverNotPrivileged();
    }

    function testMintSucceedsWhenBothPrivileged() public {
        _testMintSucceedsWhenBothPrivileged();
    }

    function testMaxDepositReturnsZeroForNonPrivileged() public view {
        _testMaxDepositReturnsZeroForNonPrivileged();
    }

    function testMaxDepositReturnsNonZeroForPrivileged() public view {
        _testMaxDepositReturnsNonZeroForPrivileged();
    }

    function testMaxMintReturnsZeroForNonPrivileged() public view {
        _testMaxMintReturnsZeroForNonPrivileged();
    }

    function testMaxMintReturnsNonZeroForPrivileged() public view {
        _testMaxMintReturnsNonZeroForPrivileged();
    }

    function testWithdrawWorksForNonPrivileged() public {
        _testWithdrawWorksForNonPrivileged();
    }

    function testRedeemWorksForNonPrivileged() public {
        _testRedeemWorksForNonPrivileged();
    }

    function testTransferWorksForNonPrivileged() public {
        _testTransferWorksForNonPrivileged();
    }

    function testFuzzPrivilegedDeposit(uint256 depositAmount) public {
        _testFuzzPrivilegedDeposit(depositAmount);
    }

    function testPrivilegedCanDepositToAnotherPrivileged() public {
        _testPrivilegedCanDepositToAnotherPrivileged();
    }

    function testIsPrivilegedViewFunction() public view {
        _testIsPrivilegedViewFunction();
    }

    // ========== BASE YIELD SKIMMING TESTS (with privileged user) ==========

    function testInitializationPrivilegedRocket() public view {
        _testInitialization();
    }

    function testFuzzDepositPrivilegedRocket(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawPrivilegedRocket(uint256 depositAmount, uint256 withdrawPercentage) public {
        _testFuzzWithdraw(depositAmount, withdrawPercentage);
    }

    function testFuzzHarvestWithProfitPrivilegedRocket(uint256 depositAmount, uint256 profitPercentage) public {
        _testFuzzHarvestWithProfit(depositAmount, profitPercentage);
    }

    function testMultipleUserProfitDistributionPrivilegedRocket() public {
        // Make user2 privileged for this test
        address user2 = address(0x5678);
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);

        _testMultipleUserProfitDistribution();
    }

    function testHarvestPrivilegedRocket() public {
        _testHarvest(100e18);
    }

    function testFuzzEmergencyExitPrivilegedRocket(uint256 depositAmount) public {
        _testFuzzEmergencyExit(depositAmount);
    }

    function testFuzzExchangeRateTrackingPrivilegedRocket(
        uint256 depositAmount,
        uint256 exchangeRateIncreasePercentage
    ) public {
        _testFuzzExchangeRateTracking(depositAmount, exchangeRateIncreasePercentage);
    }

    function testGetCurrentExchangeRatePrivilegedRocket() public view {
        _testGetCurrentExchangeRate();
    }

    function testHealthCheckProfitLimitExceededPrivilegedRocket() public {
        _testHealthCheckProfitLimitExceeded(1000e18);
    }

    function testTendTriggerAlwaysFalsePrivilegedRocket() public view {
        _testTendTriggerAlwaysFalse();
    }

    function testFuzzHarvestWithLossPrivilegedRocket(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) public {
        _testFuzzHarvestWithLoss(depositAmount, profitPercentage, lossPercentage);
    }

    function testConsecutiveLossesPrivilegedRocket() public {
        _testConsecutiveLosses();
    }

    function test_profitThenLoss_dragonSharesBurnCorrectlyPrivilegedRocket() public {
        // Make test users privileged
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        vm.startPrank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);
        vm.stopPrank();

        _test_profitThenLoss_dragonSharesBurnCorrectly();
    }

    function test_dragonRouterWithdrawal_rateRecovery_userNoLossPrivilegedRocket() public {
        // Make test user privileged
        address user1 = makeAddr("user1");
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);

        _test_dragonRouterWithdrawal_rateRecovery_userNoLoss();
    }

    function test_dragonRouterWithdrawal_rateDecline_userLossPrivilegedRocket() public {
        // Make test user privileged
        address user1 = makeAddr("user1");
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);

        _test_dragonRouterWithdrawal_rateDecline_userLoss();
    }
}
