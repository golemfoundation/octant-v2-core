// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.18;

import { MockYieldSource } from "../core/MockYieldSource.sol";
import { DragonBaseStrategy, ERC20 } from "src/zodiac-core/vaults/DragonBaseStrategy.sol";
import { Module } from "zodiac/core/Module.sol";
import "forge-std/Test.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract MockStrategy is Module, DragonBaseStrategy {
    address public yieldSource;
    bool public trigger;
    bool public managed;
    bool public kept;
    bool public emergentizated;

    /// @dev Initialize function, will be triggered when a new proxy is deployed
    /// @dev owner of this module will the safe multisig that calls setUp function
    /// @param initializeParams Parameters of initialization encoded
    function setUp(bytes memory initializeParams) public override initializer {
        (address _owner, bytes memory data) = abi.decode(initializeParams, (address, bytes));

        (
            address _tokenizedStrategyImplementation,
            address _asset,
            address _yieldSource,
            address _management,
            address _keeper,
            address _dragonRouter,
            uint256 _maxReportDelay,
            string memory _name,
            address _regenGovernance
        ) = abi.decode(data, (address, address, address, address, address, address, uint256, string, address));

        __Ownable_init(msg.sender);
        __BaseStrategy_init(
            _tokenizedStrategyImplementation,
            _asset,
            _owner,
            _management,
            _keeper,
            _dragonRouter,
            _maxReportDelay,
            _name,
            _regenGovernance
        );

        yieldSource = _yieldSource;
        if (_asset != NATIVE_TOKEN) ERC20(_asset).approve(_yieldSource, type(uint256).max);

        setAvatar(_owner);
        setTarget(_owner);
        transferOwnership(_owner);
    }

    function _deployFunds(uint256 _amount) internal override {
        if (address(asset) == NATIVE_TOKEN) MockYieldSource(yieldSource).deposit{ value: _amount }(_amount);
        else MockYieldSource(yieldSource).deposit(_amount);
    }

    function _freeFunds(uint256 _amount) internal override {
        MockYieldSource(yieldSource).withdraw(_amount);
    }

    function _harvestAndReport() internal override returns (uint256) {
        uint256 amount = 0.1 ether;
        MockYieldSource(yieldSource).simulateHarvestRewards(amount);
        uint256 balance = address(asset) == NATIVE_TOKEN
            ? address(this).balance
            : ERC20(asset).balanceOf(address(this));
        return MockYieldSource(yieldSource).balance() + balance;
    }

    function _tend(uint256 /*_idle*/) internal override {
        uint256 balance = address(asset) == NATIVE_TOKEN
            ? address(this).balance
            : ERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            if (address(asset) == NATIVE_TOKEN) {
                MockYieldSource(yieldSource).deposit{ value: balance }(balance);
                return;
            }
            MockYieldSource(yieldSource).deposit(balance);
        }
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        MockYieldSource(yieldSource).withdraw(_amount);
    }

    function _tendTrigger() internal view override returns (bool) {
        return trigger;
    }

    function setTrigger(bool _trigger) external {
        trigger = _trigger;
    }

    function adjustPosition(uint256 _debtOutstanding) external override onlyManagement {
        MockYieldSource(yieldSource).withdraw(_debtOutstanding);
    }

    function liquidatePosition(
        uint256 _amountNeeded
    ) external override onlyManagement returns (uint256 _liquidatedAmount, uint256 _loss) {
        MockYieldSource(yieldSource).withdraw(_amountNeeded);
        return (_amountNeeded, 0);
    }
}
