// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { PrivilegedYieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/PrivilegedYieldDonatingTokenizedStrategy.sol";
import { BasePrivilegedYieldDonatingIntegrationTest } from "./base/BasePrivilegedYieldDonatingIntegrationTest.sol";
import { IPrivilegedStrategy } from "../base/BasePrivilegedIntegrationTest.sol";
import { SkyCompounderTestConfig } from "../config/SkyCompounderTestConfig.sol";

/// @title Privileged SkyCompounder Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the privileged yield donating SkyCompounder strategy
contract PrivilegedSkyCompounderStrategyTest is BasePrivilegedYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    SkyCompounderStrategy public strategy;
    SkyCompounderStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return SkyCompounderTestConfig.USDS;
    }

    function _strategyName() internal pure override returns (string memory) {
        return SkyCompounderTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return SkyCompounderTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure override returns (address) {
        return SkyCompounderTestConfig.STAKING;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return SkyCompounderTestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        // Use PrivilegedYieldDonatingTokenizedStrategy instead of regular YieldDonatingTokenizedStrategy
        implementation = new PrivilegedYieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_PRIVILEGED_YIELD_DONATING_STRATEGY_V1")
        }();
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new SkyCompounderStrategyFactory();

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

        strategy = SkyCompounderStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "PrivilegedSkyCompounder");
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(SkyCompounderTestConfig.USDS, "USDS Token");
        vm.label(SkyCompounderTestConfig.STAKING, "Sky Staking");
        vm.label(SkyCompounderTestConfig.WETH, "WETH");
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

    // ========== BASE YIELD DONATING TESTS (with privileged user) ==========

    function testInitializationPrivilegedSky() public view {
        _testInitialization();
        assertEq(strategy.staking(), SkyCompounderTestConfig.STAKING, "Staking address incorrect");
    }

    function testFuzzDepositPrivilegedSky(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawPrivilegedSky(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    function testHarvestWithProfitPrivilegedSky() public {
        uint256 depositAmount = 100e18;
        uint256 profitAmount = 10e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();

        skip(1 days);
        vm.roll(block.number + 6500);

        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertGe(profit, profitAmount, "Profit should be at least the airdropped amount");
        assertEq(loss, 0, "There should be no loss");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertGe(totalAssetsAfter, totalAssetsBefore + profitAmount, "Total assets should include profit");
    }

    function testMultipleUserProfitDistributionPrivilegedSky() public {
        // Make user2 privileged for this test
        address user2 = address(0x5678);
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);

        _testMultipleUserProfitDistribution();
    }

    function testEmergencyExitPrivilegedSky() public {
        _testEmergencyExit(5000e18);
    }
}
