// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// YDStateSlots: Storage slot constants for TokenizedStrategy (StrategyData struct)
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
//   +6  uint256 totalSupply
//   +7  uint256 totalAssets
//   +8  address keeper (20 bytes) | uint96 lastReport (12 bytes)
//   +9  address management
//   +10 address pendingManagement
//   +11 address emergencyAdmin
//   +12 address dragonRouter
//   +13 address pendingDragonRouter (20 bytes) | uint96 dragonRouterChangeTimestamp (12 bytes)
//   +14 uint8 decimals | uint8 entered | bool shutdown | bool enableBurning

uint256 constant YD_BASE = uint256(0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba00);

// Mapping roots
uint256 constant YD_NONCES_SLOT = YD_BASE + 0;
uint256 constant YD_BALANCES_SLOT = YD_BASE + 1;
uint256 constant YD_ALLOWANCES_SLOT = YD_BASE + 2;

// Simple value slots
uint256 constant YD_ASSET_SLOT = YD_BASE + 3;
uint256 constant YD_NAME_SLOT = YD_BASE + 4;
uint256 constant YD_SYMBOL_SLOT = YD_BASE + 5;
uint256 constant YD_TOTAL_SUPPLY_SLOT = YD_BASE + 6;
uint256 constant YD_TOTAL_ASSETS_SLOT = YD_BASE + 7;

// Packed: keeper (address, 20 bytes) + lastReport (uint96, 12 bytes)
uint256 constant YD_KEEPER_SLOT = YD_BASE + 8;
uint256 constant YD_LAST_REPORT_OFFSET = 20;
uint256 constant YD_LAST_REPORT_WIDTH = 12;

uint256 constant YD_MANAGEMENT_SLOT = YD_BASE + 9;
uint256 constant YD_PENDING_MANAGEMENT_SLOT = YD_BASE + 10;
uint256 constant YD_EMERGENCY_ADMIN_SLOT = YD_BASE + 11;
uint256 constant YD_DRAGON_ROUTER_SLOT = YD_BASE + 12;

// Packed: pendingDragonRouter (address, 20 bytes) + dragonRouterChangeTimestamp (uint96, 12 bytes)
uint256 constant YD_PENDING_DRAGON_ROUTER_SLOT = YD_BASE + 13;

// Packed flags slot: decimals (1 byte) | entered (1 byte) | shutdown (1 byte) | enableBurning (1 byte)
uint256 constant YD_FLAGS_SLOT = YD_BASE + 14;
uint256 constant YD_DECIMALS_OFFSET = 0;
uint256 constant YD_DECIMALS_WIDTH = 1;
uint256 constant YD_ENTERED_OFFSET = 1;
uint256 constant YD_ENTERED_WIDTH = 1;
uint256 constant YD_SHUTDOWN_OFFSET = 2;
uint256 constant YD_SHUTDOWN_WIDTH = 1;
uint256 constant YD_ENABLE_BURNING_OFFSET = 3;
uint256 constant YD_ENABLE_BURNING_WIDTH = 1;

// BaseHealthCheck regular storage (slot 0 — NOT in the StrategyData struct)
// Layout: doHealthCheck (1 byte, off 0) | _profitLimitRatio (2 bytes, off 1) | _lossLimitRatio (2 bytes, off 3)
uint256 constant YD_HC_SLOT = 0;
uint256 constant YD_HC_DO_HEALTH_CHECK_OFFSET = 0;
uint256 constant YD_HC_DO_HEALTH_CHECK_WIDTH = 1;
uint256 constant YD_HC_PROFIT_LIMIT_RATIO_OFFSET = 1;
uint256 constant YD_HC_PROFIT_LIMIT_RATIO_WIDTH = 2;
uint256 constant YD_HC_LOSS_LIMIT_RATIO_OFFSET = 3;
uint256 constant YD_HC_LOSS_LIMIT_RATIO_WIDTH = 2;

// MockSimpleStrategy regular storage
uint256 constant YD_MOCK_NEXT_TOTAL_ASSETS_SLOT = 1;
