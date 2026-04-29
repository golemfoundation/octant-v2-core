// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { MockStrategy as MockBaseStrategy } from "test/mocks/core/MockBaseStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { BaseStrategy } from "src/core/BaseStrategy.sol";
import { SeedHelpers } from "test/unit/strategies/yieldDonating/utils/SeedHelpers.sol";

/// @title BaseStrategy Branch Coverage Tests
/// @notice Covers untested branches in BaseStrategy (onlySelf, hook functions, view defaults)
contract BaseStrategyBranchCoverageTest is SeedHelpers {
    MockBaseStrategy strategy;
    MockERC20 asset;
    MockYieldSource yieldSource;
    YieldDonatingTokenizedStrategy implementation;

    address management;

    function setUp() public {
        management = address(this);
        asset = new MockERC20(18);
        yieldSource = new MockYieldSource(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();
        strategy = new MockBaseStrategy(address(asset), address(yieldSource), address(implementation));
        _seedMinimumPosition(address(strategy), asset, management);
    }

    // --- onlySelf modifier: external calls revert ---

    function test_deployFunds_externalCall_reverts() public {
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.deployFunds(1e18);
    }

    function test_freeFunds_externalCall_reverts() public {
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.freeFunds(1e18);
    }

    function test_harvestAndReport_externalCall_reverts() public {
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.harvestAndReport();
    }

    function test_tendThis_externalCall_reverts() public {
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.tendThis(1e18);
    }

    function test_shutdownWithdraw_externalCall_reverts() public {
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.shutdownWithdraw(1e18);
    }

    // --- Default view functions ---

    function test_availableDepositLimit_returnsMaxUint() public view {
        assertEq(strategy.availableDepositLimit(address(0)), type(uint256).max);
    }

    function test_availableWithdrawLimit_returnsMaxUint() public view {
        assertEq(strategy.availableWithdrawLimit(address(0)), type(uint256).max);
    }

    function test_tendTrigger_returnsFalseByDefault() public view {
        (bool shouldTend, ) = strategy.tendTrigger();
        assertFalse(shouldTend);
    }

    function test_tendTrigger_returnsTrueWhenSet() public {
        strategy.setTrigger(true);
        (bool shouldTend, bytes memory callData) = strategy.tendTrigger();
        assertTrue(shouldTend);
        assertEq(callData, abi.encodeWithSelector(ITokenizedStrategy.tend.selector));
    }

    // --- TOKENIZED_STRATEGY_ADDRESS immutable ---

    function test_tokenizedStrategyAddress_isSet() public view {
        assertEq(strategy.TOKENIZED_STRATEGY_ADDRESS(), address(implementation));
    }

    // --- onlyManagement modifier via mock helper ---

    function test_onlyLetManagers_asManagement_succeeds() public {
        // address(this) is management
        strategy.onlyLetManagers();
        assertTrue(strategy.managed());
    }

    function test_onlyLetManagers_nonManagement_reverts() public {
        vm.prank(address(0x99));
        vm.expectRevert("!management");
        strategy.onlyLetManagers();
    }

    // --- onlyKeepers modifier via mock helper ---

    function test_onlyLetKeepersIn_asKeeper_succeeds() public {
        // address(this) is keeper (set in MockBaseStrategy constructor)
        strategy.onlyLetKeepersIn();
        assertTrue(strategy.kept());
    }

    function test_onlyLetKeepersIn_nonKeeper_reverts() public {
        vm.prank(address(0x99));
        vm.expectRevert("!keeper");
        strategy.onlyLetKeepersIn();
    }

    // --- onlyEmergencyAuthorized modifier via mock helper ---

    function test_onlyLetEmergencyAdminsIn_asEmergencyAdmin_succeeds() public {
        // address(this) is emergencyAdmin (set in MockBaseStrategy constructor)
        strategy.onlyLetEmergencyAdminsIn();
        assertTrue(strategy.emergentizated());
    }

    function test_onlyLetEmergencyAdminsIn_nonEmergencyAdmin_reverts() public {
        vm.prank(address(0x99));
        vm.expectRevert("!emergency authorized");
        strategy.onlyLetEmergencyAdminsIn();
    }

    // --- _tend default is a no-op (ensure no revert) ---

    function test_tend_callsInternalTend_succeeds() public {
        // Deposit some funds first so there's something idle
        asset.mint(address(this), 10e18);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, address(this));

        // Tend should not revert
        ITokenizedStrategy(address(strategy)).tend();
    }

    // --- _emergencyWithdraw called via emergencyWithdraw ---

    function test_emergencyWithdraw_callsInternal_succeeds() public {
        // Deposit funds first
        asset.mint(address(this), 10e18);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, address(this));

        // Shutdown required before emergencyWithdraw
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        // Should call _emergencyWithdraw without revert
        ITokenizedStrategy(address(strategy)).emergencyWithdraw(5e18);
    }

    // --- fallback delegatecall to TokenizedStrategy ---

    function test_fallback_delegatesToTokenizedStrategy() public view {
        // Calling any ITokenizedStrategy function goes through fallback
        // name() is defined in TokenizedStrategy, not BaseStrategy
        string memory name = ITokenizedStrategy(address(strategy)).name();
        assertEq(keccak256(bytes(name)), keccak256(bytes("Test Strategy")));
    }
}

/// @title Mock strategy that does NOT override _tendTrigger, exercising the default implementation
contract MockStrategyDefaultTend is BaseStrategy {
    constructor(
        address _asset,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _asset,
            "DefaultTend Strategy",
            "tsDT",
            msg.sender,
            msg.sender,
            msg.sender,
            msg.sender,
            false,
            _tokenizedStrategyAddress
        )
    {}

    function _deployFunds(uint256) internal override {}
    function _freeFunds(uint256) internal override {}
    function _harvestAndReport() internal view override returns (uint256) {
        return ITokenizedStrategy(address(this)).totalAssets();
    }
    function _emergencyWithdraw(uint256) internal override {}
}

/// @title Tests for the default _tendTrigger implementation in BaseStrategy
contract BaseStrategyDefaultTendTriggerTest is SeedHelpers {
    MockStrategyDefaultTend strategyDefaultTend;
    MockERC20 asset2;
    YieldDonatingTokenizedStrategy implementation2;

    function setUp() public {
        asset2 = new MockERC20(18);
        implementation2 = new YieldDonatingTokenizedStrategy();
        strategyDefaultTend = new MockStrategyDefaultTend(address(asset2), address(implementation2));
    }

    /// @notice Default _tendTrigger returns false (BaseStrategy line 329-331)
    function test_tendTrigger_defaultImplementation_returnsFalse() public view {
        (bool shouldTend, bytes memory callData) = strategyDefaultTend.tendTrigger();
        assertFalse(shouldTend, "Default _tendTrigger should return false");
        assertEq(callData, abi.encodeWithSelector(ITokenizedStrategy.tend.selector));
    }

    /// @notice Default _tend is a no-op (BaseStrategy line 321) - exercise via tendThis
    function test_tend_defaultImplementation_noOp() public {
        // Call tendThis as the strategy itself (simulating delegatecall context)
        vm.prank(address(strategyDefaultTend));
        strategyDefaultTend.tendThis(0);
    }
}
