// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

// Global constants and enums used across Octant contracts

// ══════════════════════════════════════════════════════════════════════════════
// SENTINEL VALUES
// ══════════════════════════════════════════════════════════════════════════════

// Sentinel value representing native ETH (address(0) for ETH instead of ERC20)
address constant NATIVE_TOKEN = address(0);

// ══════════════════════════════════════════════════════════════════════════════
// EVM / PROTOCOL CONSTANTS
// ══════════════════════════════════════════════════════════════════════════════

// EIP-7825 per-transaction gas limit (2^24 = 16,777,216)
// Used for gas profiling DAO proposals to ensure they fit within limits
uint256 constant EIP_7825_TX_GAS_LIMIT = 16_777_216;

// ══════════════════════════════════════════════════════════════════════════════
// MAINNET TOKEN ADDRESSES
// ══════════════════════════════════════════════════════════════════════════════

// USDC token address on Ethereum mainnet
address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// ══════════════════════════════════════════════════════════════════════════════
// OCTANT DEPLOYED CONTRACTS (MAINNET)
// ══════════════════════════════════════════════════════════════════════════════

// Morpho Compounder Strategy Factory on Ethereum mainnet (V1 - no symbol param)
// DEPRECATED: Use MORPHO_STRATEGY_FACTORY_V2_MAINNET for new deployments
address constant MORPHO_STRATEGY_FACTORY_MAINNET = 0x052d20B0e0b141988bD32772C735085e45F357c1;

// Morpho Compounder Strategy Factory V2 on Ethereum mainnet (with symbol param)
// Deployed 2025-01-22: https://etherscan.io/tx/0x21da599d0259e3d4caf6f0510598630a66a290099afb105a43b0c2a4d96e7c08
address constant MORPHO_STRATEGY_FACTORY_V2_MAINNET = 0xd8Df22cB3c3876487961aC2500889664632674d7;

// ══════════════════════════════════════════════════════════════════════════════
// EXTERNAL PROTOCOL ADDRESSES (MAINNET)
// ══════════════════════════════════════════════════════════════════════════════

// Yearn TokenizedStrategy singleton on Ethereum mainnet (yield-donating variant, V1 - no symbol param)
// DEPRECATED: Use YIELD_DONATING_TOKENIZED_STRATEGY_V2_MAINNET for new deployments
address constant YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET = 0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c;

// YieldDonatingTokenizedStrategy V2 on Ethereum mainnet (with symbol param)
// Deployed 2025-01-22: https://etherscan.io/tx/0xa8b239d1302d650cd0dc2c3b0a2b9f1bdbb85d24e01d666f7b55c6cef76a87c4
address constant YIELD_DONATING_TOKENIZED_STRATEGY_V2_MAINNET = 0xea648c313b497fECfBC629e73cB61Db34181F067;

// Gnosis Safe MultiSendCallOnly canonical deployment on Ethereum mainnet
// Used for batching multiple transactions in a single Safe execution
address constant SAFE_MULTISEND_MAINNET = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;

// ══════════════════════════════════════════════════════════════════════════════
// ENUMS
// ══════════════════════════════════════════════════════════════════════════════

/**
 * @notice Access control modes for address set validation
 * @dev Used by LinearAllowanceExecutor and RegenStaker
 */
enum AccessMode {
    NONE, // No access control (permissionless)
    ALLOWSET, // Only addresses in allowset are permitted
    BLOCKSET // All addresses except those in blockset are permitted
}
