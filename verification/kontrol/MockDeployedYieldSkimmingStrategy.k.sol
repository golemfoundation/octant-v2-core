// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { BaseYieldSkimmingHealthCheck } from "src/strategies/periphery/BaseYieldSkimmingHealthCheck.sol";
import { TestERC20 } from "test/kontrol/TestERC20.k.sol";

/**
 * @title MockDeployedYieldSkimmingStrategy
 * @notice YieldSkimming Kontrol mock with deployed-assets accounting.
 * @dev Used for final-withdraw surplus proofs where TokenizedStrategy must call
 *      freeFunds() before the last share can burn.
 */
contract MockDeployedYieldSkimmingStrategy is BaseYieldSkimmingHealthCheck {
    uint256 public nextTotalAssets;
    uint256 public mockExchangeRate;
    uint256 public mockExchangeRateDecimals;
    uint256 public deployedAssets;

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseYieldSkimmingHealthCheck(
            _asset,
            _name,
            _symbol,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    function setNextTotalAssets(uint256 _amount) external {
        nextTotalAssets = _amount;
    }

    function setMockExchangeRate(uint256 _rate) external {
        mockExchangeRate = _rate;
    }

    function setMockExchangeRateDecimals(uint256 _decimals) external {
        mockExchangeRateDecimals = _decimals;
    }

    function setDeployedAssets(uint256 _amount) external {
        deployedAssets = _amount;
    }

    function getCurrentExchangeRate() external view returns (uint256) {
        return mockExchangeRate;
    }

    function decimalsOfExchangeRate() external view returns (uint256) {
        return mockExchangeRateDecimals;
    }

    function _harvestAndReport() internal view override returns (uint256) {
        return nextTotalAssets;
    }

    function _deployFunds(uint256 amount) internal override {
        deployedAssets += amount;
    }

    function _freeFunds(uint256 amount) internal override {
        uint256 freed = amount < deployedAssets ? amount : deployedAssets;
        if (freed == 0) return;

        deployedAssets -= freed;
        TestERC20(address(asset)).mint(address(this), freed);
    }

    function _emergencyWithdraw(uint256) internal override {}
}
