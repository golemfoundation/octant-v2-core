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

// Morpho Compounder Strategy Factory on Ethereum mainnet
// Deploys yield-donating strategies targeting Yearn's USDC vault
address constant MORPHO_STRATEGY_FACTORY_MAINNET = 0x052d20B0e0b141988bD32772C735085e45F357c1;

// ══════════════════════════════════════════════════════════════════════════════
// EXTERNAL PROTOCOL ADDRESSES (MAINNET)
// ══════════════════════════════════════════════════════════════════════════════

// Yearn TokenizedStrategy singleton on Ethereum mainnet
// Required parameter for deploying strategies via MorphoCompounderStrategyFactory
address constant YEARN_TOKENIZED_STRATEGY_MAINNET = 0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c;

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
