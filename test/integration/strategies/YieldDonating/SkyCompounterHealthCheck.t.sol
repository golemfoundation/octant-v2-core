// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { SkyCompounderTestConfig } from "../config/SkyCompounderTestConfig.sol";

/// @title SkyCompounder Health Check Test
/// @author mil0x
/// @notice Unit tests for the BaseHealthCheck functionality in SkyCompounder strategy
contract SkyCompounterHealthCheckTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    SkyCompounderStrategy public strategy;
    SkyCompounderStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return SkyCompounderTestConfig.USDS;
    }

    function _strategyName() internal pure override returns (string memory) {
        return "SkyCompounder Health Check Test";
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
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
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
        vm.label(address(strategy), "SkyCompounder");
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(SkyCompounderTestConfig.USDS, "USDS Token");
        vm.label(SkyCompounderTestConfig.STAKING, "Sky Staking");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
    }

    function setUp() public {
        _baseSetUp();
    }

    // ========== HEALTH CHECK TESTS ==========

    /// @notice Test the default health check parameters
    function testDefaultHealthCheckParams() public view {
        assertTrue(strategy.doHealthCheck(), "Health check should be enabled by default");
        assertEq(strategy.profitLimitRatio(), 10000, "Default profit limit ratio should be 100%");
        assertEq(strategy.lossLimitRatio(), 0, "Default loss limit ratio should be 0%");
    }

    /// @notice Test setting health check parameters
    function testSetHealthCheckParams() public {
        vm.startPrank(management);
        strategy.setProfitLimitRatio(5000); // 50%
        strategy.setLossLimitRatio(1000); // 10%
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        assertEq(strategy.profitLimitRatio(), 5000, "Profit limit ratio should be updated to 50%");
        assertEq(strategy.lossLimitRatio(), 1000, "Loss limit ratio should be updated to 10%");
        assertFalse(strategy.doHealthCheck(), "Health check should be turned off");

        // Test that unauthorized users cannot change parameters
        vm.startPrank(user);
        vm.expectRevert();
        strategy.setProfitLimitRatio(2000);

        vm.expectRevert();
        strategy.setLossLimitRatio(500);

        vm.expectRevert();
        strategy.setDoHealthCheck(true);
        vm.stopPrank();
    }

    /// @notice Test profit within limits passes health check
    function testProfitWithinLimits() public {
        vm.startPrank(management);
        strategy.setProfitLimitRatio(2000); // 20%
        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate profit (10% - within the 20% limit)
        uint256 profitAmount = depositAmount / 10;
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertEq(profit, profitAmount, "Profit should match airdropped amount");
        assertEq(loss, 0, "Loss should be zero");
    }

    /// @notice Test profit exceeding limits fails health check
    function testProfitExceedingLimits() public {
        vm.startPrank(management);
        strategy.setProfitLimitRatio(500); // 5%
        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate profit (10% - exceeds the 5% limit)
        uint256 profitAmount = depositAmount / 10;
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        vm.startPrank(keeper);
        vm.expectRevert("healthCheck");
        vault.report();
        vm.stopPrank();
    }

    /// @notice Test loss within limits passes health check
    function testLossWithinLimits() public {
        vm.startPrank(management);
        strategy.setLossLimitRatio(1000); // 10%
        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate loss (5% - within the 10% limit)
        uint256 lossAmount = depositAmount / 20;

        // Manipulate the staked balance
        uint256 currentStakedBalance = strategy.balanceOfStake();
        uint256 expectedAfterLoss = currentStakedBalance - lossAmount;

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(expectedAfterLoss)
        );

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false); // Don't check exact loss amount
        emit Reported(0, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertEq(profit, 0, "Profit should be zero");
        assertApproxEqAbs(loss, lossAmount, 100, "Loss should approximately match simulated amount");
    }

    /// @notice Test loss exceeding limits fails health check
    function testLossExceedingLimits() public {
        vm.startPrank(management);
        strategy.setLossLimitRatio(500); // 5%
        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate loss (10% - exceeds the 5% limit)
        uint256 lossAmount = depositAmount / 10;

        uint256 currentStakedBalance = strategy.balanceOfStake();
        uint256 expectedAfterLoss = currentStakedBalance - lossAmount;

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(expectedAfterLoss)
        );

        vm.startPrank(keeper);
        vm.expectRevert("healthCheck");
        vault.report();
        vm.stopPrank();
    }

    /// @notice Test disabled health check allows any profit/loss
    function testDisabledHealthCheck() public {
        vm.startPrank(management);
        strategy.setProfitLimitRatio(100); // 1%
        strategy.setLossLimitRatio(100); // 1%
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate excessive profit (20% - would exceed the 1% limit)
        uint256 profitAmount = depositAmount / 5;
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertEq(profit, profitAmount, "Profit should match airdropped amount");
        assertEq(loss, 0, "Loss should be zero");

        // Verify health check was automatically re-enabled
        assertTrue(strategy.doHealthCheck(), "Health check should be automatically re-enabled");
    }

    /// @notice Test profit edge cases
    function testProfitEdgeCases() public {
        vm.startPrank(management);

        // Test profit limit ratio cannot be zero
        vm.expectRevert("!zero profit");
        strategy.setProfitLimitRatio(0);

        // Test profit limit ratio cannot exceed uint16 max
        vm.expectRevert("!too high");
        strategy.setProfitLimitRatio(uint256(type(uint16).max) + 1);

        // Valid value should work
        strategy.setProfitLimitRatio(1); // 0.01%
        assertEq(strategy.profitLimitRatio(), 1, "Profit limit ratio should be updated to 0.01%");
        vm.stopPrank();
    }

    /// @notice Test loss edge cases
    function testLossEdgeCases() public {
        vm.startPrank(management);

        // Test loss limit ratio cannot be 100% or higher
        vm.expectRevert("!loss limit");
        strategy.setLossLimitRatio(10000); // 100%

        // Valid value should work
        strategy.setLossLimitRatio(9999); // 99.99%
        assertEq(strategy.lossLimitRatio(), 9999, "Loss limit ratio should be updated to 99.99%");
        vm.stopPrank();
    }
}
