// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { OctantRegistry } from "src/registry/OctantRegistry.sol";
import { IOctantRegistry } from "src/interfaces/IOctantRegistry.sol";
import { RegistryManifest } from "src/registry/RegistryManifest.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract MockCreate2Deployer {
    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes32 salt = bytes32(data[:32]);
        bytes memory initCode = data[32:];
        address deployed;
        assembly {
            deployed := create2(callvalue(), add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "create2 failed");
        return abi.encodePacked(deployed);
    }
}

contract RegistryBatchFlowTest is Test {
    address public safe;

    bytes32 internal constant REGISTRY_SALT = keccak256("OCTANT_REGISTRY_22072026");
    bytes32 internal constant LIDO_SALT = keccak256("LIDO_STRATEGY_FACTORY_21072026");
    bytes32 internal constant ROCKET_POOL_SALT = keccak256("ROCKET_POOL_STRATEGY_FACTORY_21072026");
    bytes32 internal constant LIDO_KEY = "LIDO_STRATEGY_FACTORY";
    bytes32 internal constant ROCKET_POOL_KEY = "ROCKET_POOL_STRATEGY_FACTORY";
    bytes32 internal constant YS_SINGLETON_SALT = keccak256("OCTANT_YIELD_SKIMMING_STRATEGY_07082026");
    bytes32 internal constant YS_SINGLETON_KEY = "YIELD_SKIMMING_STRATEGY";
    bytes32 internal constant YD_SINGLETON_SALT = keccak256("OCTANT_YIELD_DONATING_STRATEGY_07082026");
    bytes32 internal constant YD_SINGLETON_KEY = "YIELD_DONATING_STRATEGY";
    bytes32 internal constant YD_LEGACY_KEY = "YIELD_DONATING_STRATEGY_V1";

    function setUp() public {
        safe = makeAddr("safe");
        vm.etch(CREATE2_FACTORY, address(new MockCreate2Deployer()).code);
    }

    function test_BatchFlow_DeploysAndPublishesAtomically() public {
        // Arrange: precompute and deploy contracts as the Safe batch does
        bytes memory registryInitCode = abi.encodePacked(type(OctantRegistry).creationCode, abi.encode(safe));
        address expectedRegistry = _computeCreate2AddressViaFactory(REGISTRY_SALT, keccak256(registryInitCode));
        address expectedLido = _computeCreate2AddressViaFactory(
            LIDO_SALT,
            keccak256(type(LidoStrategyFactory).creationCode)
        );
        address expectedRocketPool = _computeCreate2AddressViaFactory(
            ROCKET_POOL_SALT,
            keccak256(type(RocketPoolStrategyFactory).creationCode)
        );

        address deployedRegistry = _deployViaFactory(REGISTRY_SALT, registryInitCode);
        address deployedLido = _deployViaFactory(LIDO_SALT, type(LidoStrategyFactory).creationCode);
        address deployedRocketPool = _deployViaFactory(ROCKET_POOL_SALT, type(RocketPoolStrategyFactory).creationCode);

        assertEq(deployedRegistry, expectedRegistry, "registry CREATE2 address mismatch");
        assertEq(deployedLido, expectedLido, "lido factory CREATE2 address mismatch");
        assertEq(deployedRocketPool, expectedRocketPool, "rocketpool factory CREATE2 address mismatch");

        OctantRegistry registry = OctantRegistry(deployedRegistry);
        assertEq(registry.owner(), safe, "Safe should own the registry");

        IOctantRegistry.Update[] memory updates = new IOctantRegistry.Update[](2);
        updates[0] = _factoryUpdate(LIDO_KEY, expectedLido);
        updates[1] = _factoryUpdate(ROCKET_POOL_KEY, expectedRocketPool);
        bytes32 manifest = RegistryManifest.hash(block.chainid, deployedRegistry, 0, updates, "1.3.0");

        // Act: publish from the Safe in the same logical batch
        vm.prank(safe);
        registry.publishBatch(0, updates, "1.3.0");

        // Assert: addresses and batch metadata describe one atomic state
        assertEq(registry.count(), 2, "registry should hold both factories");
        assertEq(registry.epoch(), 1, "initial publication epoch mismatch");
        assertEq(registry.manifestHash(), manifest, "manifest hash mismatch");
        assertEq(registry.releaseLabel(), "1.3.0", "release label mismatch");

        for (uint256 i = 0; i < updates.length; ++i) {
            IOctantRegistry.Entry memory entry = registry.getEntry(updates[i].key);
            assertEq(entry.addr, updates[i].addr, "registered address mismatch");
            assertEq(entry.runtimeCodeHash, updates[i].addr.codehash, "registered code hash mismatch");
            assertEq(uint8(entry.status), uint8(IOctantRegistry.EntryStatus.ACTIVE), "entry should be active");
        }
    }

    /// @dev Mirrors the production flow: batch 1 (registry + factories + epoch-1 publication)
    ///      then batch 2 (YieldSkimming singleton + epoch-2 publication) at the next Safe nonce.
    ///      Batch 2 must be unexecutable before batch 1 (stale epoch) and atomic after it.
    function test_BatchFlow_SecondBatchDeploysAndPublishesSingletons() public {
        // Batch 1: deploy registry + one factory; the legacy 1.0.0 YieldDonating singleton
        // (stand-in) registers ACTIVE under the versioned key (new keys must start ACTIVE)
        bytes memory registryInitCode = abi.encodePacked(type(OctantRegistry).creationCode, abi.encode(safe));
        OctantRegistry registry = OctantRegistry(_deployViaFactory(REGISTRY_SALT, registryInitCode));
        address deployedLido = _deployViaFactory(LIDO_SALT, type(LidoStrategyFactory).creationCode);
        address legacyYds = address(new YieldDonatingTokenizedStrategy());

        IOctantRegistry.Update[] memory batch1 = new IOctantRegistry.Update[](2);
        batch1[0] = _factoryUpdate(LIDO_KEY, deployedLido);
        batch1[1] = IOctantRegistry.Update({
            key: YD_LEGACY_KEY,
            addr: legacyYds,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.ACTIVE,
            compatibilityVersion: bytes32("1.0.0")
        });

        // Batch 2: fresh 1.1.0 singleton deployments + epoch-2 publication
        address deployedYss = _deployViaFactory(YS_SINGLETON_SALT, type(YieldSkimmingTokenizedStrategy).creationCode);
        address deployedYds = _deployViaFactory(YD_SINGLETON_SALT, type(YieldDonatingTokenizedStrategy).creationCode);
        assertEq(
            deployedYss,
            _computeCreate2AddressViaFactory(
                YS_SINGLETON_SALT,
                keccak256(type(YieldSkimmingTokenizedStrategy).creationCode)
            ),
            "YSS CREATE2 address mismatch"
        );
        assertEq(
            deployedYds,
            _computeCreate2AddressViaFactory(
                YD_SINGLETON_SALT,
                keccak256(type(YieldDonatingTokenizedStrategy).creationCode)
            ),
            "YDS CREATE2 address mismatch"
        );

        IOctantRegistry.Update[] memory batch2 = new IOctantRegistry.Update[](3);
        batch2[0] = IOctantRegistry.Update({
            key: YS_SINGLETON_KEY,
            addr: deployedYss,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.ACTIVE,
            compatibilityVersion: bytes32("1.1.0")
        });
        batch2[1] = IOctantRegistry.Update({
            key: YD_SINGLETON_KEY,
            addr: deployedYds,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.ACTIVE,
            compatibilityVersion: bytes32("1.1.0")
        });
        batch2[2] = IOctantRegistry.Update({
            key: YD_LEGACY_KEY,
            addr: legacyYds,
            entryType: IOctantRegistry.EntryType.CONTRACT,
            status: IOctantRegistry.EntryStatus.DEPRECATED,
            compatibilityVersion: bytes32("1.0.0")
        });

        // Out-of-order execution: batch 2 (expectedEpoch 1) must revert before batch 1 ran
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__StaleEpoch.selector, 1, 0));
        registry.publishBatch(1, batch2, "1.3.0");

        // In-order execution: batch 1 then batch 2
        vm.prank(safe);
        registry.publishBatch(0, batch1, "1.3.0");
        assertEq(registry.tryGetAddress(YD_LEGACY_KEY), legacyYds, "legacy should resolve while sole implementation");

        bytes32 manifest2 = RegistryManifest.hash(block.chainid, address(registry), 1, batch2, "1.3.0");
        vm.prank(safe);
        registry.publishBatch(1, batch2, "1.3.0");

        assertEq(registry.epoch(), 2, "epoch should advance once per batch");
        assertEq(registry.manifestHash(), manifest2, "manifest should reflect the latest batch");

        // Canonical keys point at the fresh 1.1.0 singletons
        IOctantRegistry.Entry memory yss = registry.getEntry(YS_SINGLETON_KEY);
        assertEq(yss.addr, deployedYss, "YSS address mismatch");
        assertEq(yss.compatibilityVersion, bytes32("1.1.0"), "YSS compat version mismatch");
        assertEq(yss.runtimeCodeHash, deployedYss.codehash, "YSS code hash mismatch");
        IOctantRegistry.Entry memory yds = registry.getEntry(YD_SINGLETON_KEY);
        assertEq(yds.addr, deployedYds, "YDS address mismatch");
        assertEq(yds.compatibilityVersion, bytes32("1.1.0"), "YDS compat version mismatch");
        assertEq(registry.tryGetAddress(YD_SINGLETON_KEY), deployedYds, "canonical YDS should resolve as active");

        // Legacy entry is deprecated: address retained, no longer resolves as active
        IOctantRegistry.Entry memory legacy = registry.getEntry(YD_LEGACY_KEY);
        assertEq(legacy.addr, legacyYds, "legacy address must be retained");
        assertEq(uint8(legacy.status), uint8(IOctantRegistry.EntryStatus.DEPRECATED), "legacy should be deprecated");
        assertEq(legacy.compatibilityVersion, bytes32("1.0.0"), "legacy compat version mismatch");
        assertEq(registry.tryGetAddress(YD_LEGACY_KEY), address(0), "deprecated legacy must not resolve");
    }

    function _factoryUpdate(bytes32 key, address addr) internal pure returns (IOctantRegistry.Update memory update) {
        return
            IOctantRegistry.Update({
                key: key,
                addr: addr,
                entryType: IOctantRegistry.EntryType.FACTORY,
                status: IOctantRegistry.EntryStatus.ACTIVE,
                compatibilityVersion: bytes32(0)
            });
    }

    function _computeCreate2AddressViaFactory(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", CREATE2_FACTORY, salt, initCodeHash)))));
    }

    function _deployViaFactory(bytes32 salt, bytes memory creationCode) internal returns (address) {
        vm.prank(safe);
        (bool success, bytes memory result) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
        require(success, "CREATE2 deploy failed");
        address deployed;
        assembly {
            deployed := shr(96, mload(add(result, 32)))
        }
        return deployed;
    }
}
