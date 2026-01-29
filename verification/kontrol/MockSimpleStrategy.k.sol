// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";

/**
 * @title MockSimpleStrategy
 * @notice Minimal strategy for Kontrol formal verification proofs
 * @dev Extends BaseHealthCheck with a controllable _harvestAndReport() return value.
 *      Does not interact with any external yield source — pure accounting mock.
 *      The `nextTotalAssets` field can be set directly or left symbolic via kevm.symbolicStorage().
 */
contract MockSimpleStrategy is BaseHealthCheck {
    /// @notice Value returned by _harvestAndReport(). Set via setNextTotalAssets() or symbolic storage.
    uint256 public nextTotalAssets;

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
        BaseHealthCheck(
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

    function _harvestAndReport() internal view override returns (uint256) {
        return nextTotalAssets;
    }

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal override {}

    function _emergencyWithdraw(uint256) internal override {}
}
