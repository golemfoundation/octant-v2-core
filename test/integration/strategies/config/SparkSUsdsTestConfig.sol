// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title SparkSUsdsTestConfig
/// @notice Configuration constants for the Spark sUSDS (USDS Savings Rate) strategy integration tests
/// @dev sUSDS is the ERC-4626 savings vault that earns the Sky Savings Rate (SSR).
///      Although deployed by Sky (rebranded MakerDAO), it is surfaced as a "Savings" product in the Spark UI
///      and fits the existing SparkStrategy (ERC4626Strategy + airdrop sweep) without any contract changes.
library SparkSUsdsTestConfig {
    /// @notice USDS token address on mainnet (Sky rebrand of DAI, ERC-20)
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    /// @notice Spark sUSDS savings vault address on mainnet (ERC-4626, earns Sky Savings Rate)
    address internal constant SUSDS_VAULT = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    /// @notice USDT token address on mainnet (used for the constructor asset-mismatch test)
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @notice Tokenized strategy implementation address
    address internal constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    /// @notice USDS decimals
    uint8 internal constant USDS_DECIMALS = 18;

    /// @notice Minimum deposit amount for USDS fuzz tests (1 USDS)
    uint256 internal constant USDS_MIN_DEPOSIT = 1e18;

    /// @notice Maximum deposit amount for USDS fuzz tests (100,000 USDS)
    uint256 internal constant USDS_MAX_DEPOSIT = 100_000e18;

    /// @notice Initial deposit for USDS setup (100,000 USDS)
    uint256 internal constant USDS_INITIAL_DEPOSIT = 100_000e18;

    /// @notice Strategy name for USDS
    string internal constant USDS_STRATEGY_NAME = "Spark sUSDS Donating Strategy";

    /// @notice Strategy symbol for USDS
    string internal constant USDS_STRATEGY_SYMBOL = "osSparkUSDS";

    // ========== TEST-SPECIFIC AMOUNTS ==========

    /// @notice SSR accrual test deposit amount for USDS (10,000 USDS)
    uint256 internal constant USDS_SSR_TEST_DEPOSIT = 10_000e18;

    /// @notice Deposit cap max check amount for USDS (1 billion). sUSDS currently has no on-chain cap,
    ///         so the deposit-cap test is expected to short-circuit and skip when maxDeposit > this bound.
    uint256 internal constant USDS_DEPOSIT_CAP_MAX_CHECK = 1_000_000_000e18;

    /// @notice Deposit cap excess amount for USDS (used only if a finite cap is ever enforced)
    uint256 internal constant USDS_DEPOSIT_CAP_EXCESS = 1_000e18;

    /// @notice Multi-user test first deposit for USDS (5,000 USDS)
    uint256 internal constant USDS_MULTI_USER_DEPOSIT_1 = 5_000e18;

    /// @notice Multi-user test second deposit for USDS (3,000 USDS)
    uint256 internal constant USDS_MULTI_USER_DEPOSIT_2 = 3_000e18;
}
