// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";
import { DeployedAddresses } from "../helpers/DeployedAddresses.sol";

import { OctantRegistry } from "src/registry/OctantRegistry.sol";
import { RegistryKeys } from "src/registry/RegistryKeys.sol";
import { RegistryManifest } from "src/registry/RegistryManifest.sol";
import { IOctantRegistry } from "src/interfaces/IOctantRegistry.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/**
 * @title DeployAaveSparkLidoFactories
 * @author Golem Foundation
 * @notice Deploys OctantRegistry, four strategy factories, and the fresh 1.1.0 YieldSkimming
 *         and YieldDonating singletons across two Safe transactions with sequential nonces
 * @dev Each batch deploys through CREATE2 and atomically publishes the deployed addresses,
 *      with a deterministic manifest hash binding the chain, registry, expected epoch,
 *      release label, and updates.
 *
 *      Generation model: canonical keys always point at the LATEST deployment of each kind;
 *      superseded generations keep versioned keys (*_V1, *_V2 in deployment order) so the
 *      registry reflects the complete production history. Legacy entries register ACTIVE in
 *      epoch 1 (new keys must start ACTIVE) and are flipped to DEPRECATED in epoch 2 - a
 *      discovery signal only; the contracts themselves are untouched.
 *
 *      Two batches because of the EIP-7825 per-transaction gas cap (16,777,216): code
 *      deposits alone are ~16.9M across the seven contracts, so one transaction carrying
 *      all deployments plus the publications cannot fit.
 *        - Batch 1 (~13.5M): OctantRegistry + 4 factories + publishBatch epoch 0->1
 *          (22 entries: new factories, latest 11022026-generation backfill, and the
 *          superseded generations under *_V1 / *_V2 keys)
 *        - Batch 2 (~8.6M): fresh 1.1.0 YieldSkimming (~20KB) and YieldDonating (~16KB)
 *          singletons + publishBatch epoch 1->2 (canonical singleton keys with
 *          compatibility "1.1.0", plus DEPRECATED flips for all 7 legacy entries)
 *      Batch 2's expectedEpoch=1 means it can only execute after batch 1 - out-of-order
 *      execution reverts. Both proposals are created in one script run.
 *
 *      The factories embed Ethereum mainnet protocol addresses, so execution is restricted
 *      to chain id 1. Mainnet forks retain chain id 1 and remain supported for simulation.
 */
contract DeployAaveSparkLidoFactories is DeployedAddresses, BatchScript {
    bytes32 public constant OCTANT_REGISTRY_SALT = keccak256("OCTANT_REGISTRY_22072026");
    bytes32 public constant AAVE_V3_FACTORY_SALT = keccak256("AAVE_V3_STRATEGY_FACTORY_21072026");
    bytes32 public constant SPARK_FACTORY_SALT = keccak256("SPARK_STRATEGY_FACTORY_21072026");
    bytes32 public constant LIDO_FACTORY_SALT = keccak256("LIDO_STRATEGY_FACTORY_21072026");
    bytes32 public constant ROCKET_POOL_FACTORY_SALT = keccak256("ROCKET_POOL_STRATEGY_FACTORY_21072026");
    bytes32 public constant YIELD_SKIMMING_SINGLETON_SALT = keccak256("OCTANT_YIELD_SKIMMING_STRATEGY_07082026");
    bytes32 public constant YIELD_DONATING_SINGLETON_SALT = keccak256("OCTANT_YIELD_DONATING_STRATEGY_07082026");
    uint64 internal constant INITIAL_REGISTRY_EPOCH = 0;
    uint64 internal constant SINGLETON_REGISTRY_EPOCH = INITIAL_REGISTRY_EPOCH + 1;

    /// @dev apiVersion() of the already-deployed 1.0.0-era singletons (mainnet backfill)
    bytes32 internal constant COMPAT_VERSION_1_0_0 = "1.0.0";
    /// @dev apiVersion() of the singletons deployed by this batch (v2-core release 1.3.0)
    bytes32 internal constant COMPAT_VERSION_1_1_0 = "1.1.0";

    // First-generation mainnet deployments (05112025 batch, block 23784110). Superseded by
    // the 11022026 batch now held in DeployedAddresses, but registered under *_V1 keys so
    // the registry reflects the complete production history.
    address internal constant LEGACY_V1_PAYMENT_SPLITTER_FACTORY = 0x5711765E0756B45224fc1FdA1B41ab344682bBcb;
    address internal constant LEGACY_V1_SKY_COMPOUNDER_FACTORY = 0xbe5352d0eCdB13D9f74c244B634FdD729480Bb6F;
    address internal constant LEGACY_V1_MORPHO_COMPOUNDER_FACTORY = 0x052d20B0e0b141988bD32772C735085e45F357c1;
    address internal constant LEGACY_V1_YEARN_V3_STRATEGY_FACTORY = 0x6D8c4E4A158083E30B53ba7df3cFB885fC096fF6;
    address internal constant LEGACY_V1_YIELD_DONATING_STRATEGY = 0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c;

    address public octantRegistry;
    address public aaveV3Factory;
    address public sparkFactory;
    address public lidoFactory;
    address public rocketPoolFactory;
    address public yieldSkimmingSingleton;
    address public yieldDonatingSingleton;
    address public safe;

    string public registryReleaseLabel;
    bytes32 public registryManifestHash;
    bytes32 public singletonManifestHash;

    bytes32[] internal registeredKeys;
    address[] internal registeredAddrs;
    IOctantRegistry.EntryType[] internal registeredTypes;
    bytes32[] internal registeredCompatVersions;

    // Superseded-generation entries: registered ACTIVE in epoch 1 (new keys must start
    // ACTIVE), then flipped to DEPRECATED by the epoch-2 publication in batch 2.
    bytes32[] internal legacyKeys;
    address[] internal legacyAddrs;
    IOctantRegistry.EntryType[] internal legacyTypes;
    bytes32[] internal legacyCompatVersions;

    error DeployFactories__UnsupportedChain(uint256 chainId);
    error DeployFactories__FactoriesNotStaged();
    error DeployFactories__RegistryEntryMismatch(bytes32 key);
    error DeployFactories__RegistryMetadataMismatch(bytes32 key);
    error DeployFactories__RegistryEpochMismatch();
    error DeployFactories__RegistryManifestMismatch();
    error DeployFactories__RegistryReleaseLabelMismatch();

    function setUp() public {
        safe = _loadSafeAddress();
        registryReleaseLabel = vm.parseJsonString(vm.readFile("package.json"), ".version");

        console.log("Using Safe:", safe);
        console.log("Registry release label:", registryReleaseLabel);
    }

    function run() public isBatch(safe) {
        require(block.chainid == 1, DeployFactories__UnsupportedChain(block.chainid));

        _calculateExpectedAddresses();

        // Safe transaction 1 (nonce n): registry + factories + epoch-1 publication.
        // Adding the ~36KB of singleton runtime code here would push the transaction
        // past the EIP-7825 16,777,216 gas cap, hence the second batch below.
        _addRegistryDeployment();
        _addFactoryDeployments();
        _addRegistryPublication();
        _assertRegistrations();
        executeBatch(true);

        // Safe transaction 2 (nonce n+1): fresh 1.1.0 singletons + epoch-2 publication.
        // Internally atomic like batch 1; expectedEpoch = 1 makes it executable only
        // after batch 1, so out-of-order execution reverts instead of corrupting state.
        _startNewBatch();
        _addSingletonDeployment();
        _addSingletonPublication();
        _assertSingletonRegistration();
        executeBatch(true);

        _logDeploymentSummary();
    }

    function _calculateExpectedAddresses() internal {
        octantRegistry = _computeCreate2AddressViaFactory(OCTANT_REGISTRY_SALT, keccak256(_registryCreationCode()));
        aaveV3Factory = _computeCreate2AddressViaFactory(
            AAVE_V3_FACTORY_SALT,
            keccak256(type(AaveV3StrategyFactory).creationCode)
        );
        sparkFactory = _computeCreate2AddressViaFactory(
            SPARK_FACTORY_SALT,
            keccak256(type(SparkStrategyFactory).creationCode)
        );
        lidoFactory = _computeCreate2AddressViaFactory(
            LIDO_FACTORY_SALT,
            keccak256(type(LidoStrategyFactory).creationCode)
        );
        rocketPoolFactory = _computeCreate2AddressViaFactory(
            ROCKET_POOL_FACTORY_SALT,
            keccak256(type(RocketPoolStrategyFactory).creationCode)
        );
        yieldSkimmingSingleton = _computeCreate2AddressViaFactory(
            YIELD_SKIMMING_SINGLETON_SALT,
            keccak256(type(YieldSkimmingTokenizedStrategy).creationCode)
        );
        yieldDonatingSingleton = _computeCreate2AddressViaFactory(
            YIELD_DONATING_SINGLETON_SALT,
            keccak256(type(YieldDonatingTokenizedStrategy).creationCode)
        );
    }

    function _registryCreationCode() internal view returns (bytes memory) {
        return abi.encodePacked(type(OctantRegistry).creationCode, abi.encode(safe));
    }

    function _addRegistryDeployment() internal {
        console.log("\n=== SINGLE BATCH: Registry + AaveV3/Spark/Lido/RocketPool Factories ===\n");
        _addCreate2Deployment(OCTANT_REGISTRY_SALT, _registryCreationCode());
        console.log("- OctantRegistry:", octantRegistry);
    }

    function _addFactoryDeployments() internal {
        _addCreate2Deployment(AAVE_V3_FACTORY_SALT, type(AaveV3StrategyFactory).creationCode);
        _addCreate2Deployment(SPARK_FACTORY_SALT, type(SparkStrategyFactory).creationCode);
        _addCreate2Deployment(LIDO_FACTORY_SALT, type(LidoStrategyFactory).creationCode);
        _addCreate2Deployment(ROCKET_POOL_FACTORY_SALT, type(RocketPoolStrategyFactory).creationCode);

        console.log("- AaveV3StrategyFactory:", aaveV3Factory);
        console.log("- SparkStrategyFactory:", sparkFactory);
        console.log("- LidoStrategyFactory:", lidoFactory);
        console.log("- RocketPoolStrategyFactory:", rocketPoolFactory);
    }

    function _addRegistryPublication() internal {
        _stageEntry(RegistryKeys.AAVE_V3_STRATEGY_FACTORY, aaveV3Factory, IOctantRegistry.EntryType.FACTORY);
        _stageEntry(RegistryKeys.SPARK_STRATEGY_FACTORY, sparkFactory, IOctantRegistry.EntryType.FACTORY);
        _stageEntry(RegistryKeys.LIDO_STRATEGY_FACTORY, lidoFactory, IOctantRegistry.EntryType.FACTORY);
        _stageEntry(RegistryKeys.ROCKET_POOL_STRATEGY_FACTORY, rocketPoolFactory, IOctantRegistry.EntryType.FACTORY);

        ContractAddresses memory production = getMainnetAddresses();
        _stageEntry(
            RegistryKeys.PAYMENT_SPLITTER_FACTORY,
            production.paymentSplitterFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        _stageEntry(
            RegistryKeys.SKY_COMPOUNDER_FACTORY,
            production.skyCompounderStrategyFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        _stageEntry(
            RegistryKeys.MORPHO_COMPOUNDER_FACTORY,
            production.morphoCompounderStrategyFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        _stageEntry(
            RegistryKeys.EARNING_POWER_CALCULATOR_FACTORY,
            production.regenEarningPowerCalculatorFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        _stageEntry(
            RegistryKeys.REGEN_STAKER_FACTORY,
            production.regenStakerFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        // Deployed 1.0.0-era YieldDonating singletons keep versioned keys so batch 2 can
        // hand the canonical key to the fresh 1.1.0 deployment: V1 = 05112025 batch,
        // V2 = 11022026 batch (the latest existing implementation).
        _stageLegacyEntry(
            RegistryKeys.YIELD_DONATING_STRATEGY_V1,
            LEGACY_V1_YIELD_DONATING_STRATEGY,
            IOctantRegistry.EntryType.CONTRACT,
            COMPAT_VERSION_1_0_0
        );
        _stageLegacyEntry(
            RegistryKeys.YIELD_DONATING_STRATEGY_V2,
            production.yieldDonatingTokenizedStrategy,
            IOctantRegistry.EntryType.CONTRACT,
            COMPAT_VERSION_1_0_0
        );

        // First-generation factories (05112025 batch) and the superseded 11022026 Lido
        // factory keep *_V1 keys; canonical keys carry the latest generation.
        _stageLegacyEntry(
            RegistryKeys.PAYMENT_SPLITTER_FACTORY_V1,
            LEGACY_V1_PAYMENT_SPLITTER_FACTORY,
            IOctantRegistry.EntryType.FACTORY,
            bytes32(0)
        );
        _stageLegacyEntry(
            RegistryKeys.SKY_COMPOUNDER_FACTORY_V1,
            LEGACY_V1_SKY_COMPOUNDER_FACTORY,
            IOctantRegistry.EntryType.FACTORY,
            bytes32(0)
        );
        _stageLegacyEntry(
            RegistryKeys.MORPHO_COMPOUNDER_FACTORY_V1,
            LEGACY_V1_MORPHO_COMPOUNDER_FACTORY,
            IOctantRegistry.EntryType.FACTORY,
            bytes32(0)
        );
        _stageLegacyEntry(
            RegistryKeys.YEARN_V3_STRATEGY_FACTORY_V1,
            LEGACY_V1_YEARN_V3_STRATEGY_FACTORY,
            IOctantRegistry.EntryType.FACTORY,
            bytes32(0)
        );
        _stageLegacyEntry(
            RegistryKeys.LIDO_STRATEGY_FACTORY_V1,
            production.lidoStrategyFactory,
            IOctantRegistry.EntryType.FACTORY,
            bytes32(0)
        );
        _stageEntry(
            RegistryKeys.YEARN_V3_STRATEGY_FACTORY,
            production.yearnV3StrategyFactory,
            IOctantRegistry.EntryType.FACTORY
        );
        _stageEntry(RegistryKeys.ADDRESS_SET_FACTORY, production.addressSetFactory, IOctantRegistry.EntryType.FACTORY);
        _stageEntry(RegistryKeys.STAKER_ALLOWSET, production.stakerAllowset, IOctantRegistry.EntryType.CONTRACT);
        _stageEntry(RegistryKeys.STAKER_BLOCKSET, production.stakerBlockset, IOctantRegistry.EntryType.CONTRACT);
        _stageEntry(
            RegistryKeys.ALLOCATION_MECHANISM_ALLOWSET,
            production.allocationMechanismAllowset,
            IOctantRegistry.EntryType.CONTRACT
        );
        _stageEntry(
            RegistryKeys.REGEN_EARNING_POWER_CALCULATOR,
            production.regenEarningPowerCalculator,
            IOctantRegistry.EntryType.CONTRACT
        );

        IOctantRegistry.Update[] memory updates = _buildRegistryUpdates();
        registryManifestHash = RegistryManifest.hash(
            block.chainid,
            octantRegistry,
            INITIAL_REGISTRY_EPOCH,
            updates,
            registryReleaseLabel
        );
        _addRegistryPublication(octantRegistry, INITIAL_REGISTRY_EPOCH, updates, registryReleaseLabel);

        console.log("- Registry entries staged:", registeredKeys.length);
        console.logBytes32(registryManifestHash);
    }

    function _stageEntry(bytes32 key, address addr, IOctantRegistry.EntryType entryType) internal {
        _stageEntry(key, addr, entryType, bytes32(0));
    }

    /// @dev Stages a superseded-generation entry: published ACTIVE in epoch 1 and recorded
    ///      for the epoch-2 DEPRECATED flip in batch 2. Skips zero addresses.
    function _stageLegacyEntry(
        bytes32 key,
        address addr,
        IOctantRegistry.EntryType entryType,
        bytes32 compatibilityVersion
    ) internal {
        if (addr == address(0)) return;

        _stageEntry(key, addr, entryType, compatibilityVersion);
        legacyKeys.push(key);
        legacyAddrs.push(addr);
        legacyTypes.push(entryType);
        legacyCompatVersions.push(compatibilityVersion);
    }

    function _stageEntry(
        bytes32 key,
        address addr,
        IOctantRegistry.EntryType entryType,
        bytes32 compatibilityVersion
    ) internal {
        if (addr == address(0)) return;

        registeredKeys.push(key);
        registeredAddrs.push(addr);
        registeredTypes.push(entryType);
        registeredCompatVersions.push(compatibilityVersion);
    }

    function _buildRegistryUpdates() internal view returns (IOctantRegistry.Update[] memory updates) {
        uint256 entriesLength = registeredKeys.length;
        updates = new IOctantRegistry.Update[](entriesLength);
        for (uint256 i = 0; i < entriesLength; ++i) {
            updates[i] = IOctantRegistry.Update({
                key: registeredKeys[i],
                addr: registeredAddrs[i],
                entryType: registeredTypes[i],
                status: IOctantRegistry.EntryStatus.ACTIVE,
                compatibilityVersion: registeredCompatVersions[i]
            });
        }
    }

    function _addSingletonDeployment() internal {
        console.log("\n=== SECOND BATCH: YieldSkimming + YieldDonating singletons ===\n");
        _addCreate2Deployment(YIELD_SKIMMING_SINGLETON_SALT, type(YieldSkimmingTokenizedStrategy).creationCode);
        console.log("- YieldSkimmingTokenizedStrategy:", yieldSkimmingSingleton);
        _addCreate2Deployment(YIELD_DONATING_SINGLETON_SALT, type(YieldDonatingTokenizedStrategy).creationCode);
        console.log("- YieldDonatingTokenizedStrategy:", yieldDonatingSingleton);
    }

    /// @dev Epoch-2 publication: both fresh 1.1.0 singletons become the canonical keys and
    ///      every superseded-generation entry (registered ACTIVE in epoch 1, since new keys
    ///      must start ACTIVE) is flipped to DEPRECATED - a discovery signal only.
    function _addSingletonPublication() internal {
        uint256 legacyCount = legacyKeys.length;
        IOctantRegistry.Update[] memory updates = new IOctantRegistry.Update[](2 + legacyCount);
        updates[0] = IOctantRegistry.Update({
            key: RegistryKeys.YIELD_SKIMMING_STRATEGY,
            addr: yieldSkimmingSingleton,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.ACTIVE,
            compatibilityVersion: COMPAT_VERSION_1_1_0
        });
        updates[1] = IOctantRegistry.Update({
            key: RegistryKeys.YIELD_DONATING_STRATEGY,
            addr: yieldDonatingSingleton,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.ACTIVE,
            compatibilityVersion: COMPAT_VERSION_1_1_0
        });
        for (uint256 i = 0; i < legacyCount; ++i) {
            updates[2 + i] = IOctantRegistry.Update({
                key: legacyKeys[i],
                addr: legacyAddrs[i],
                entryType: legacyTypes[i],
                status: IOctantRegistry.EntryStatus.DEPRECATED,
                compatibilityVersion: legacyCompatVersions[i]
            });
        }

        singletonManifestHash = RegistryManifest.hash(
            block.chainid,
            octantRegistry,
            SINGLETON_REGISTRY_EPOCH,
            updates,
            registryReleaseLabel
        );
        _addRegistryPublication(octantRegistry, SINGLETON_REGISTRY_EPOCH, updates, registryReleaseLabel);
        console.logBytes32(singletonManifestHash);
    }

    function _assertSingletonRegistration() internal view {
        IOctantRegistry registry = IOctantRegistry(octantRegistry);

        _assertActiveSingleton(registry, RegistryKeys.YIELD_SKIMMING_STRATEGY, yieldSkimmingSingleton);
        _assertActiveSingleton(registry, RegistryKeys.YIELD_DONATING_STRATEGY, yieldDonatingSingleton);

        // Every superseded generation keeps its address but no longer resolves as active
        uint256 legacyCount = legacyKeys.length;
        for (uint256 i = 0; i < legacyCount; ++i) {
            bytes32 key = legacyKeys[i];
            IOctantRegistry.Entry memory legacy = registry.getEntry(key);
            require(legacy.addr == legacyAddrs[i], DeployFactories__RegistryEntryMismatch(key));
            require(
                legacy.status == IOctantRegistry.EntryStatus.DEPRECATED &&
                    legacy.entryType == legacyTypes[i] &&
                    legacy.compatibilityVersion == legacyCompatVersions[i] &&
                    registry.tryGetAddress(key) == address(0),
                DeployFactories__RegistryMetadataMismatch(key)
            );
        }

        require(registry.epoch() == SINGLETON_REGISTRY_EPOCH + 1, DeployFactories__RegistryEpochMismatch());
        require(registry.manifestHash() == singletonManifestHash, DeployFactories__RegistryManifestMismatch());
    }

    function _assertActiveSingleton(IOctantRegistry registry, bytes32 key, address expected) internal view {
        IOctantRegistry.Entry memory entry = registry.getEntry(key);
        require(entry.addr == expected, DeployFactories__RegistryEntryMismatch(key));
        require(
            entry.entryType == IOctantRegistry.EntryType.CONTRACT &&
                entry.status == IOctantRegistry.EntryStatus.ACTIVE &&
                entry.compatibilityVersion == COMPAT_VERSION_1_1_0 &&
                entry.runtimeCodeHash == expected.codehash,
            DeployFactories__RegistryMetadataMismatch(key)
        );
    }

    function _assertRegistrations() internal view {
        require(registeredKeys.length >= 4, DeployFactories__FactoriesNotStaged());

        IOctantRegistry registry = IOctantRegistry(octantRegistry);
        uint256 entriesLength = registeredKeys.length;
        for (uint256 i = 0; i < entriesLength; ++i) {
            bytes32 key = registeredKeys[i];
            IOctantRegistry.Entry memory entry = registry.getEntry(key);
            require(entry.addr == registeredAddrs[i], DeployFactories__RegistryEntryMismatch(key));
            require(
                entry.entryType == registeredTypes[i] &&
                    entry.status == IOctantRegistry.EntryStatus.ACTIVE &&
                    entry.compatibilityVersion == registeredCompatVersions[i] &&
                    entry.runtimeCodeHash == registeredAddrs[i].codehash,
                DeployFactories__RegistryMetadataMismatch(key)
            );
        }

        require(registry.epoch() == INITIAL_REGISTRY_EPOCH + 1, DeployFactories__RegistryEpochMismatch());
        require(registry.manifestHash() == registryManifestHash, DeployFactories__RegistryManifestMismatch());
        require(
            keccak256(bytes(registry.releaseLabel())) == keccak256(bytes(registryReleaseLabel)),
            DeployFactories__RegistryReleaseLabelMismatch()
        );
    }

    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 7 (two Safe transactions, sequential nonces)");
        console.log("  OctantRegistry:", octantRegistry);
        console.log("  AaveV3StrategyFactory:", aaveV3Factory);
        console.log("  SparkStrategyFactory:", sparkFactory);
        console.log("  LidoStrategyFactory:", lidoFactory);
        console.log("  RocketPoolStrategyFactory:", rocketPoolFactory);
        console.log("  YieldSkimmingTokenizedStrategy (1.1.0):", yieldSkimmingSingleton);
        console.log("  YieldDonatingTokenizedStrategy (1.1.0):", yieldDonatingSingleton);
        console.log("Batch 1 (epoch 1) entries:", registeredKeys.length);
        console.logBytes32(registryManifestHash);
        console.log("Batch 2 (epoch 2) updates:", 2 + legacyKeys.length);
        console.log("  (YSS + YDS active 1.1.0; legacy generations deprecated:", legacyKeys.length, ")");
        console.logBytes32(singletonManifestHash);
        console.log("Registry release label:", registryReleaseLabel);
        console.log("\nBoth batch transactions were sent to the Safe backend for signing.");
        console.log("Execute them in nonce order; batch 2 reverts unless batch 1 executed first.");
        console.log("==========================\n");
    }
}
