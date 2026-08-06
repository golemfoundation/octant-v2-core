// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

/**
 * @title RegistryKeys
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Canonical keys used by OctantRegistry publishers and consumers
 */
library RegistryKeys {
    bytes32 internal constant AAVE_V3_STRATEGY_FACTORY = "AAVE_V3_STRATEGY_FACTORY";
    bytes32 internal constant SPARK_STRATEGY_FACTORY = "SPARK_STRATEGY_FACTORY";
    bytes32 internal constant LIDO_STRATEGY_FACTORY = "LIDO_STRATEGY_FACTORY";
    bytes32 internal constant ROCKET_POOL_STRATEGY_FACTORY = "ROCKET_POOL_STRATEGY_FACTORY";
    bytes32 internal constant PAYMENT_SPLITTER_FACTORY = "PAYMENT_SPLITTER_FACTORY";
    bytes32 internal constant PAYMENT_SPLITTER_FACTORY_V1 = "PAYMENT_SPLITTER_FACTORY_V1";
    bytes32 internal constant SKY_COMPOUNDER_FACTORY = "SKY_COMPOUNDER_FACTORY";
    bytes32 internal constant SKY_COMPOUNDER_FACTORY_V1 = "SKY_COMPOUNDER_FACTORY_V1";
    bytes32 internal constant MORPHO_COMPOUNDER_FACTORY = "MORPHO_COMPOUNDER_FACTORY";
    bytes32 internal constant MORPHO_COMPOUNDER_FACTORY_V1 = "MORPHO_COMPOUNDER_FACTORY_V1";
    bytes32 internal constant LIDO_STRATEGY_FACTORY_V1 = "LIDO_STRATEGY_FACTORY_V1";
    bytes32 internal constant YEARN_V3_STRATEGY_FACTORY_V1 = "YEARN_V3_STRATEGY_FACTORY_V1";
    bytes32 internal constant EARNING_POWER_CALCULATOR_FACTORY = "EARNING_POWER_CALCULATOR_FACTORY";
    bytes32 internal constant REGEN_STAKER_FACTORY = "REGEN_STAKER_FACTORY";
    bytes32 internal constant YIELD_DONATING_STRATEGY = "YIELD_DONATING_STRATEGY";
    bytes32 internal constant YIELD_DONATING_STRATEGY_V1 = "YIELD_DONATING_STRATEGY_V1";
    bytes32 internal constant YIELD_DONATING_STRATEGY_V2 = "YIELD_DONATING_STRATEGY_V2";
    bytes32 internal constant YIELD_SKIMMING_STRATEGY = "YIELD_SKIMMING_STRATEGY";
    bytes32 internal constant YEARN_V3_STRATEGY_FACTORY = "YEARN_V3_STRATEGY_FACTORY";
    bytes32 internal constant ADDRESS_SET_FACTORY = "ADDRESS_SET_FACTORY";
    bytes32 internal constant STAKER_ALLOWSET = "STAKER_ALLOWSET";
    bytes32 internal constant STAKER_BLOCKSET = "STAKER_BLOCKSET";
    bytes32 internal constant ALLOCATION_MECHANISM_ALLOWSET = "ALLOCATION_MECHANISM_ALLOWSET";
    bytes32 internal constant REGEN_EARNING_POWER_CALCULATOR = "REGEN_EARNING_POWER_CALCULATOR";
}
