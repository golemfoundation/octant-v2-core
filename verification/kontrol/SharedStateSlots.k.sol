// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// SharedStateSlots: Corrected storage slot constants for TokenizedStrategy (StrategyData struct)
// BASE_STRATEGY_STORAGE uses ERC-7201 namespaced storage:
//   keccak256(abi.encode(uint256(keccak256("octant.tokenized.strategy.storage")) - 1)) & ~bytes32(uint256(0xff))
//   = 0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba00
//
// StrategyData struct field layout (relative to base):
//   +0  mapping(address => uint256) nonces
//   +1  mapping(address => uint256) balances
//   +2  mapping(address => mapping(address => uint256)) allowances
//   +3  ERC20 asset (address, 20 bytes)
//   +4  string name
//   +5  string symbol
//   +6  bytes32 cachedDomainSeparator
//   +7  uint256 cachedChainId
//   +8  uint256 totalSupply
//   +9  uint256 totalAssets
//   +10 address keeper (20 bytes) | uint96 lastReport (12 bytes)
//   +11 address management
//   +12 address pendingManagement
//   +13 address emergencyAdmin
//   +14 address dragonRouter
//   +15 address pendingDragonRouter (20 bytes) | uint96 dragonRouterChangeTimestamp (12 bytes)
//   +16 uint8 decimals | uint8 entered | bool shutdown | bool enableBurning

// ============================================
// TokenizedStrategy base (TS_) constants
// ============================================

uint256 constant TS_BASE = uint256(0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba00);

// Mapping roots
uint256 constant TS_NONCES_SLOT = TS_BASE + 0;
uint256 constant TS_BALANCES_SLOT = TS_BASE + 1;
uint256 constant TS_ALLOWANCES_SLOT = TS_BASE + 2;

// Simple value slots
uint256 constant TS_ASSET_SLOT = TS_BASE + 3;
uint256 constant TS_NAME_SLOT = TS_BASE + 4;
uint256 constant TS_SYMBOL_SLOT = TS_BASE + 5;
uint256 constant TS_CACHED_DOMAIN_SEPARATOR_SLOT = TS_BASE + 6;
uint256 constant TS_CACHED_CHAIN_ID_SLOT = TS_BASE + 7;
uint256 constant TS_TOTAL_SUPPLY_SLOT = TS_BASE + 8;
uint256 constant TS_TOTAL_ASSETS_SLOT = TS_BASE + 9;

// Packed: keeper (address, 20 bytes) + lastReport (uint96, 12 bytes)
uint256 constant TS_KEEPER_SLOT = TS_BASE + 10;
uint256 constant TS_LAST_REPORT_OFFSET = 20;
uint256 constant TS_LAST_REPORT_WIDTH = 12;

uint256 constant TS_MANAGEMENT_SLOT = TS_BASE + 11;
uint256 constant TS_PENDING_MANAGEMENT_SLOT = TS_BASE + 12;
uint256 constant TS_EMERGENCY_ADMIN_SLOT = TS_BASE + 13;
uint256 constant TS_DRAGON_ROUTER_SLOT = TS_BASE + 14;

// Packed: pendingDragonRouter (address, 20 bytes) + dragonRouterChangeTimestamp (uint96, 12 bytes)
uint256 constant TS_PENDING_DRAGON_ROUTER_SLOT = TS_BASE + 15;

// Packed flags slot: decimals (1 byte) | entered (1 byte) | shutdown (1 byte) | enableBurning (1 byte)
uint256 constant TS_FLAGS_SLOT = TS_BASE + 16;
uint256 constant TS_DECIMALS_OFFSET = 0;
uint256 constant TS_DECIMALS_WIDTH = 1;
uint256 constant TS_ENTERED_OFFSET = 1;
uint256 constant TS_ENTERED_WIDTH = 1;
uint256 constant TS_SHUTDOWN_OFFSET = 2;
uint256 constant TS_SHUTDOWN_WIDTH = 1;
uint256 constant TS_ENABLE_BURNING_OFFSET = 3;
uint256 constant TS_ENABLE_BURNING_WIDTH = 1;

// ============================================
// YieldSkimming-specific (YS_) constants
// ============================================
// Storage at keccak256(abi.encode(uint256(keccak256("octant.yieldSkimming.exchangeRate")) - 1)) & ~bytes32(uint256(0xff))
// = 0x66b3d9d1383d5ce25503fdc2e0f4d387777e50a9b5be65141986eec7395fef00

uint256 constant YS_BASE = uint256(0x66b3d9d1383d5ce25503fdc2e0f4d387777e50a9b5be65141986eec7395fef00);

uint256 constant YS_TOTAL_DEBT_OWED_TO_USER_SLOT = YS_BASE + 0;
uint256 constant YS_LAST_REPORTED_RATE_SLOT = YS_BASE + 1;
uint256 constant YS_DRAGON_ROUTER_DEBT_SLOT = YS_BASE + 2;

// ============================================
// BaseHealthCheck / BaseYieldSkimmingHealthCheck (HC_) constants
// ============================================
// Regular storage slot 0 (NOT in the StrategyData struct)
// Layout: doHealthCheck (1 byte, off 0) | _profitLimitRatio (2 bytes, off 1) | _lossLimitRatio (2 bytes, off 3)

uint256 constant HC_SLOT = 0;
uint256 constant HC_DO_HEALTH_CHECK_OFFSET = 0;
uint256 constant HC_DO_HEALTH_CHECK_WIDTH = 1;
uint256 constant HC_PROFIT_LIMIT_RATIO_OFFSET = 1;
uint256 constant HC_PROFIT_LIMIT_RATIO_WIDTH = 2;
uint256 constant HC_LOSS_LIMIT_RATIO_OFFSET = 3;
uint256 constant HC_LOSS_LIMIT_RATIO_WIDTH = 2;

// ============================================
// MockSimpleStrategy (MOCK_) constants
// ============================================
// Regular storage (slot 1 for mock nextTotalAssets, since slot 0 is health check)

uint256 constant MOCK_NEXT_TOTAL_ASSETS_SLOT = 1;

// MockSimpleYieldSkimmingStrategy additional slots
uint256 constant MOCK_YS_EXCHANGE_RATE_SLOT = 2;
uint256 constant MOCK_YS_EXCHANGE_RATE_DECIMALS_SLOT = 3;

// ============================================
// TestERC20 (OZ ERC20 v5) constants
// ============================================
uint256 constant ERC20_BALANCES_SLOT = 0;

// ============================================
// ReentrancyGuard (OZ v5.3.0, plain storage slot 0)
// ============================================
// YieldForwarder / SwappingYieldForwarder inherit ReentrancyGuard
// which stores _status at slot 0 (NOT ERC-7201 namespaced)
uint256 constant RG_STATUS_SLOT = 0;
uint256 constant RG_NOT_ENTERED = 1;

// ============================================
// MockForwarderStrategy (MFS_) constants
// ============================================
// Plain storage slots for the mock strategy used in YieldForwarder Kontrol proofs
uint256 constant MFS_SHARE_BALANCE_SLOT = 0;
uint256 constant MFS_REDEEM_RETURN_SLOT = 1;
uint256 constant MFS_ASSET_SLOT = 2;
uint256 constant MFS_LAST_RECEIVER_SLOT = 3;
uint256 constant MFS_LAST_SHARES_SLOT = 4;
uint256 constant MFS_LAST_REPORT_CALLER_SLOT = 5;
uint256 constant MFS_EXPECTED_BALANCE_OF_ACCOUNT_SLOT = 6;
uint256 constant MFS_LAST_OWNER_SLOT = 7;
uint256 constant MFS_LAST_MAX_LOSS_SLOT = 8;
uint256 constant MFS_MAX_REDEEM_SLOT = 9;
uint256 constant MFS_CONVERT_TO_ASSETS_SLOT = 10;

// ============================================
// MockForwarderSwapper (MSWP_) constants
// ============================================
// Plain storage slots for the mock swapper used in SwappingYieldForwarder Kontrol proofs
uint256 constant MSWP_RETURN_SLOT = 0;
uint256 constant MSWP_LAST_RECEIVER_SLOT = 1;
uint256 constant MSWP_LAST_TOKEN_IN_SLOT = 2;
uint256 constant MSWP_LAST_TOKEN_OUT_SLOT = 3;
uint256 constant MSWP_LAST_AMOUNT_IN_SLOT = 4;
uint256 constant MSWP_LAST_MIN_AMOUNT_OUT_SLOT = 5;
