// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseSparkVaultStrategyTest } from "../BaseSparkVaultStrategy.t.sol";

/// @title Spark USDC Vault Strategy Test
/// @author Octant
/// @notice Integration tests for GenericERC4626 strategy with SparkDAO USDC vault
contract SparkUSDCVaultStrategyTest is BaseSparkVaultStrategyTest {
    /// @notice Returns the Spark USDC vault address
    function getSparkVault() internal pure override returns (address) {
        return 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d; // Spark USDC vault
    }

    /// @notice Returns the USDC token address
    function getAsset() internal pure override returns (address) {
        return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC token
    }

    /// @notice Returns the asset name for labeling
    function getAssetName() internal pure override returns (string memory) {
        return "USDC";
    }

    /// @notice Returns the initial deposit amount (100,000 USDC with 6 decimals)
    function getInitialDeposit() internal pure override returns (uint256) {
        return 100000e6; // 100,000 USDC
    }

    /// @notice Returns a different asset for validation testing (USDT)
    function getWrongAsset() internal pure override returns (address) {
        return 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
    }
}
