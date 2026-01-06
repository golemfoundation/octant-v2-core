// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { BaseYieldSkimmingHealthCheck } from "src/strategies/periphery/BaseYieldSkimmingHealthCheck.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @title Mock contract that inherits from BaseYieldSkimmingHealthCheck for testing
contract YieldSkimmingHealthCheckLogic is BaseYieldSkimmingHealthCheck {
    uint256 public currentExchangeRateStored = 1e18;
    uint256 public exchangeRateDecimalsStored = 18;
    uint256 public lastRateRayStored = 1e27;
    uint256 public totalUserDebtStored;
    uint256 public dragonRouterDebtStored;

    constructor(
        address _asset,
        address _management,
        address _tokenizedStrategy
    )
        BaseYieldSkimmingHealthCheck(
            _asset,
            "Test Health Check",
            _management,
            address(0x2), // keeper
            address(0x3), // emergencyAdmin
            address(0x4), // donationAddress
            true, // enableBurning
            _tokenizedStrategy
        )
    {}

    // Test helpers
    function setCurrentExchangeRate(uint256 _rate, uint256 _decimals) external {
        currentExchangeRateStored = _rate;
        exchangeRateDecimalsStored = _decimals;
    }

    function setLastRateRay(uint256 _rate) external {
        lastRateRayStored = _rate;
    }

    // Implement IYieldSkimmingStrategy interface (BaseYieldSkimmingHealthCheck calls these)
    function getCurrentExchangeRate() external view returns (uint256) {
        return currentExchangeRateStored;
    }

    function getLastRateRay() external view returns (uint256) {
        return lastRateRayStored;
    }

    function decimalsOfExchangeRate() external view returns (uint256) {
        return exchangeRateDecimalsStored;
    }

    function isVaultInsolvent() external pure returns (bool) {
        return false;
    }

    // Expose the internal _executeHealthCheck for testing
    function testExecuteHealthCheck(uint256 _totalAssets) external {
        _executeHealthCheck(_totalAssets);
    }

    // Required BaseStrategy implementations
    function _deployFunds(uint256) internal override {
        // No-op for testing
    }

    function _freeFunds(uint256) internal override {
        // No-op for testing
    }

    function _harvestAndReport() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/// @title Unit tests for BaseYieldSkimmingHealthCheck
contract BaseYieldSkimmingHealthCheckTest is Test {
    YieldSkimmingHealthCheckLogic public logic;
    MockERC20 public asset;
    YieldSkimmingTokenizedStrategy public tokenizedStrategy;
    address public management = address(0x1);

    function setUp() public {
        asset = new MockERC20(18);
        tokenizedStrategy = new YieldSkimmingTokenizedStrategy();
        logic = new YieldSkimmingHealthCheckLogic(address(asset), management, address(tokenizedStrategy));
        vm.label(address(logic), "HealthCheckLogic");
        vm.label(address(asset), "Asset");
    }

    /// @notice Test getCurrentRateRay with different decimal scenarios
    function testGetCurrentRateRay_DifferentDecimals() public {
        // Test with 18 decimals (convert up to RAY)
        logic.setCurrentExchangeRate(1e18, 18);
        assertEq(logic.getCurrentRateRay(), 1e27, "18 decimals should convert correctly");

        // Test with less decimals (e.g., 6)
        logic.setCurrentExchangeRate(2e6, 6);
        assertEq(logic.getCurrentRateRay(), 2e27, "6 decimals should convert correctly");

        // Test with more decimals (e.g., 36)
        logic.setCurrentExchangeRate(3e36, 36);
        assertEq(logic.getCurrentRateRay(), 3e27, "36 decimals should convert correctly");

        // Test with exactly 27 decimals (RAY)
        logic.setCurrentExchangeRate(4e27, 27);
        assertEq(logic.getCurrentRateRay(), 4e27, "27 decimals should return unchanged");
    }

    /// @notice Test getCurrentRateRay with edge cases
    function testGetCurrentRateRay_EdgeCases() public {
        // Test with very small rate
        logic.setCurrentExchangeRate(1, 0);
        assertEq(logic.getCurrentRateRay(), 1e27, "0 decimals with rate 1 should convert correctly");

        // Test with large rate and small decimals
        logic.setCurrentExchangeRate(1e9, 9);
        assertEq(logic.getCurrentRateRay(), 1e27, "Large rate with 9 decimals should convert correctly");

        // Test precision preservation
        logic.setCurrentExchangeRate(123456789, 6);
        assertEq(logic.getCurrentRateRay(), 123456789e21, "Should preserve precision during conversion");
    }

    /// @notice Test _executeHealthCheck with profit within limits
    function testExecuteHealthCheck_ProfitWithinLimits() public {
        // Set up initial state
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(1.1e18, 18); // 10% increase

        // Set profit limit to 20%
        vm.prank(management);
        logic.setProfitLimitRatio(2000); // 20%

        // Should not revert
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test _executeHealthCheck with profit exceeding limits
    function testExecuteHealthCheck_ProfitExceedingLimits() public {
        // Set up initial state
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(1.3e18, 18); // 30% increase

        // Set profit limit to 20%
        vm.prank(management);
        logic.setProfitLimitRatio(2000); // 20%

        // Should revert
        vm.expectRevert("!profit");
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test _executeHealthCheck with loss within limits
    function testExecuteHealthCheck_LossWithinLimits() public {
        // Set up initial state
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(0.95e18, 18); // 5% decrease

        // Set loss limit to 10%
        vm.prank(management);
        logic.setLossLimitRatio(1000); // 10%

        // Should not revert
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test _executeHealthCheck with loss exceeding limits
    function testExecuteHealthCheck_LossExceedingLimits() public {
        // Set up initial state
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(0.85e18, 18); // 15% decrease

        // Set loss limit to 10%
        vm.prank(management);
        logic.setLossLimitRatio(1000); // 10%

        // Should revert
        vm.expectRevert("!loss");
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test _executeHealthCheck with health check disabled
    function testExecuteHealthCheck_Disabled() public {
        // Disable health check
        vm.prank(management);
        logic.setDoHealthCheck(false);

        // Set up extreme loss that would normally fail
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(0.5e18, 18); // 50% decrease

        // Set loss limit to 10%
        vm.prank(management);
        logic.setLossLimitRatio(1000); // 10%

        // Should not revert despite extreme loss
        logic.testExecuteHealthCheck(1000e18);

        // Health check should be re-enabled
        assertTrue(logic.doHealthCheck(), "Health check should be re-enabled after execution");
    }

    /// @notice Test _executeHealthCheck with no change in rates
    function testExecuteHealthCheck_NoChange() public {
        // Set up identical rates
        logic.setLastRateRay(1e27); // 1:1 rate
        logic.setCurrentExchangeRate(1e18, 18); // 1:1 rate

        // Should not revert
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test profit and loss limit setters
    function testSetLimits() public {
        vm.startPrank(management);

        // Valid profit limit
        logic.setProfitLimitRatio(5000);
        assertEq(logic.profitLimitRatio(), 5000, "Profit limit should be updated");

        // Zero profit limit should fail
        vm.expectRevert("!zero profit");
        logic.setProfitLimitRatio(0);

        // Too high profit limit should fail
        vm.expectRevert("!too high");
        logic.setProfitLimitRatio(type(uint256).max);

        // Test loss limit
        logic.setLossLimitRatio(2000);
        assertEq(logic.lossLimitRatio(), 2000, "Loss limit should be updated");

        // Loss limit at or above 100% should fail
        vm.expectRevert("!loss limit");
        logic.setLossLimitRatio(10000);

        vm.stopPrank();
    }

    /// @notice Test health check toggle
    function testHealthCheckToggle() public {
        // Initially enabled
        assertTrue(logic.doHealthCheck(), "Should be enabled by default");

        vm.startPrank(management);

        // Disable
        logic.setDoHealthCheck(false);
        assertFalse(logic.doHealthCheck(), "Should be disabled");

        // Enable
        logic.setDoHealthCheck(true);
        assertTrue(logic.doHealthCheck(), "Should be enabled");

        vm.stopPrank();
    }

    /// @notice Test edge case with different decimal rates in health check
    function testExecuteHealthCheck_DifferentDecimalRates() public {
        // Set last rate in RAY (27 decimals)
        logic.setLastRateRay(2e27); // Rate of 2

        // Set current rate with 6 decimals
        logic.setCurrentExchangeRate(2.2e6, 6); // 10% increase

        // Set profit limit to 20%
        vm.prank(management);
        logic.setProfitLimitRatio(2000); // 20%

        // Should not revert as 10% < 20%
        logic.testExecuteHealthCheck(1000e18);

        // Now set a rate that exceeds the limit
        logic.setCurrentExchangeRate(2.5e6, 6); // 25% increase

        // Should revert as 25% > 20%
        vm.expectRevert("!profit");
        logic.testExecuteHealthCheck(1000e18);
    }

    /// @notice Test access control on management functions
    function testAccessControl() public {
        address unauthorized = address(0x999);

        vm.startPrank(unauthorized);

        vm.expectRevert(); // Should revert with management access error
        logic.setProfitLimitRatio(1000);

        vm.expectRevert(); // Should revert with management access error
        logic.setLossLimitRatio(1000);

        vm.expectRevert(); // Should revert with management access error
        logic.setDoHealthCheck(false);

        vm.stopPrank();
    }

    /// @notice Test zero rate scenarios
    function testGetCurrentRateRay_ZeroRate() public {
        // Test zero rate with different decimals
        logic.setCurrentExchangeRate(0, 18);
        assertEq(logic.getCurrentRateRay(), 0, "Zero rate should remain zero");

        logic.setCurrentExchangeRate(0, 6);
        assertEq(logic.getCurrentRateRay(), 0, "Zero rate with 6 decimals should remain zero");
    }

    /// @notice Test extreme decimal differences
    function testGetCurrentRateRay_ExtremeDecimals() public {
        // Test with 1 decimal
        logic.setCurrentExchangeRate(15, 1); // 1.5
        assertEq(logic.getCurrentRateRay(), 15e26, "1 decimal should convert correctly");

        // Test with 50 decimals (higher than RAY)
        logic.setCurrentExchangeRate(5e50, 50);
        assertEq(logic.getCurrentRateRay(), 5e27, "50 decimals should convert correctly");
    }
}
