// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseSparkVaultStrategyTest } from "../BaseSparkVaultStrategy.t.sol";

/// @title Spark WETH Vault Strategy Test
/// @author Octant
/// @notice Integration tests for GenericERC4626 strategy with SparkDAO WETH vault
contract SparkWETHVaultStrategyTest is BaseSparkVaultStrategyTest {
    /// @notice Returns the Spark WETH vault address
    function getSparkVault() internal pure override returns (address) {
        return 0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f; // Spark WETH vault
    }

    /// @notice Returns the WETH token address
    function getAsset() internal pure override returns (address) {
        return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH token
    }

    /// @notice Returns the asset name for labeling
    function getAssetName() internal pure override returns (string memory) {
        return "WETH";
    }

    /// @notice Returns the initial deposit amount (100 WETH with 18 decimals)
    function getInitialDeposit() internal pure override returns (uint256) {
        return 100e18; // 100 WETH
    }

    /// @notice Returns a different asset for validation testing (USDC)
    function getWrongAsset() internal pure override returns (address) {
        return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    }
}
