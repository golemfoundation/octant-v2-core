// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { PrivilegedYieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/PrivilegedYieldSkimmingTokenizedStrategy.sol";
import { BasePrivilegedYieldSkimmingIntegrationTest } from "./base/BasePrivilegedYieldSkimmingIntegrationTest.sol";
import { IPrivilegedStrategy } from "../base/BasePrivilegedIntegrationTest.sol";
import { LidoTestConfig } from "../config/LidoTestConfig.sol";

/// @title Privileged Lido Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the privileged yield skimming Lido strategy
contract PrivilegedLidoStrategyTest is BasePrivilegedYieldSkimmingIntegrationTest {
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

    function _minDeposit() internal pure override returns (uint256) {
        return LidoTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return LidoTestConfig.MAX_DEPOSIT;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        // Use PrivilegedYieldSkimmingTokenizedStrategy instead of regular YieldSkimmingTokenizedStrategy
        implementation = new PrivilegedYieldSkimmingTokenizedStrategy{
            salt: keccak256("OCT_PRIVILEGED_YIELD_SKIMMING_STRATEGY_V1")
        }();
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
        vm.label(address(lidoStrategy), "PrivilegedLido");
        vm.label(address(factory), "LidoStrategyFactory");
        vm.label(LidoTestConfig.WSTETH, "WSTETH");
        vm.label(LidoTestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
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

    function testInitializationPrivilegedLido() public view {
        _testInitialization();
    }

    function testDepositPrivilegedLido() public {
        _testDeposit(100e18);
    }

    function testFuzzDepositPrivilegedLido(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawPrivilegedLido(uint256 depositAmount, uint256 withdrawPercentage) public {
        _testFuzzWithdraw(depositAmount, withdrawPercentage);
    }

    function testFuzzHarvestWithProfitPrivilegedLido(uint256 depositAmount, uint256 profitPercentage) public {
        _testFuzzHarvestWithProfit(depositAmount, profitPercentage);
    }

    function testMultipleUserProfitDistributionPrivilegedLido() public {
        // Make user2 privileged for this test
        address user2 = address(0x5678);
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);

        _testMultipleUserProfitDistribution();
    }

    function testHarvestPrivilegedLido() public {
        _testHarvest(100e18);
    }

    function testFuzzEmergencyExitPrivilegedLido(uint256 depositAmount) public {
        _testFuzzEmergencyExit(depositAmount);
    }

    function testFuzzExchangeRateTrackingPrivilegedLido(
        uint256 depositAmount,
        uint256 exchangeRateIncreasePercentage
    ) public {
        _testFuzzExchangeRateTracking(depositAmount, exchangeRateIncreasePercentage);
    }

    function testGetCurrentExchangeRatePrivilegedLido() public view {
        _testGetCurrentExchangeRate();
    }

    function testHealthCheckProfitLimitExceededPrivilegedLido() public {
        _testHealthCheckProfitLimitExceeded(1000e18);
    }

    function testTendTriggerAlwaysFalsePrivilegedLido() public view {
        _testTendTriggerAlwaysFalse();
    }

    function testFuzzHarvestWithLossPrivilegedLido(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) public {
        _testFuzzHarvestWithLoss(depositAmount, profitPercentage, lossPercentage);
    }

    function testConsecutiveLossesPrivilegedLido() public {
        _testConsecutiveLosses();
    }

    function test_profitThenLoss_dragonSharesBurnCorrectlyPrivilegedLido() public {
        // Make test users privileged
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        vm.startPrank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);
        vm.stopPrank();

        _test_profitThenLoss_dragonSharesBurnCorrectly();
    }

    function test_dragonRouterWithdrawal_rateRecovery_userNoLossPrivilegedLido() public {
        // Make test user privileged
        address user1 = makeAddr("user1");
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);

        _test_dragonRouterWithdrawal_rateRecovery_userNoLoss();
    }

    function test_dragonRouterWithdrawal_rateDecline_userLossPrivilegedLido() public {
        // Make test user privileged
        address user1 = makeAddr("user1");
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user1, true);

        _test_dragonRouterWithdrawal_rateDecline_userLoss();
    }
}
