// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { OctantRegistry } from "src/registry/OctantRegistry.sol";
import { IOctantRegistry } from "src/interfaces/IOctantRegistry.sol";

contract InvariantRegistryTarget {}

contract OctantRegistryHandler is Test {
    OctantRegistry public registry;
    address public owner;

    bytes32[] public keyUniverse;
    address[] public targetUniverse;
    mapping(bytes32 key => bool known) public known;
    mapping(bytes32 key => address addr) public lastAddr;
    mapping(bytes32 key => IOctantRegistry.EntryStatus status) public lastStatus;
    mapping(bytes32 key => bytes32 compatibilityVersion) public lastCompatibilityVersion;
    uint256 public knownCount;
    uint256 public publicationCount;

    constructor(OctantRegistry registry_, address owner_) {
        registry = registry_;
        owner = owner_;

        keyUniverse.push("KEY_ALPHA");
        keyUniverse.push("KEY_BRAVO");
        keyUniverse.push("KEY_CHARLIE");
        keyUniverse.push("KEY_DELTA");
        keyUniverse.push("KEY_ECHO");
        keyUniverse.push("KEY_FOXTROT");
        keyUniverse.push("KEY_GOLF");
        keyUniverse.push("KEY_HOTEL");

        for (uint256 i = 0; i < keyUniverse.length; ++i) {
            targetUniverse.push(address(new InvariantRegistryTarget()));
        }
    }

    function universeLength() external view returns (uint256) {
        return keyUniverse.length;
    }

    function publish(uint256 keySeed, uint256 targetSeed, uint256 statusSeed) external {
        bytes32 key = keyUniverse[bound(keySeed, 0, keyUniverse.length - 1)];
        address target = targetUniverse[bound(targetSeed, 0, targetUniverse.length - 1)];
        IOctantRegistry.EntryStatus status = IOctantRegistry.EntryStatus(
            bound(
                statusSeed,
                uint256(IOctantRegistry.EntryStatus.ACTIVE),
                uint256(IOctantRegistry.EntryStatus.DISABLED)
            )
        );

        if (!known[key]) {
            known[key] = true;
            knownCount++;
            status = IOctantRegistry.EntryStatus.ACTIVE;
        } else if (status != IOctantRegistry.EntryStatus.ACTIVE) {
            target = lastAddr[key];
        }

        bytes32 compatibilityVersion = lastCompatibilityVersion[key] == bytes32("1.0.0")
            ? bytes32("1.0.1")
            : bytes32("1.0.0");

        IOctantRegistry.Update[] memory updates = new IOctantRegistry.Update[](1);
        updates[0] = IOctantRegistry.Update({
            key: key,
            addr: target,
            entryType: IOctantRegistry.EntryType.FACTORY,
            status: status,
            compatibilityVersion: compatibilityVersion
        });

        uint64 expectedEpoch = registry.epoch();
        vm.prank(owner);
        registry.publishBatch(expectedEpoch, updates, "INVARIANT");

        lastAddr[key] = target;
        lastStatus[key] = status;
        lastCompatibilityVersion[key] = compatibilityVersion;
        publicationCount++;
    }
}

contract OctantRegistryInvariantTest is Test {
    OctantRegistry public registry;
    OctantRegistryHandler public handler;
    address public owner;

    function setUp() public {
        owner = makeAddr("owner");
        registry = new OctantRegistry(owner);
        handler = new OctantRegistryHandler(registry, owner);
        targetContract(address(handler));
    }

    function invariant_CountMatchesKnownKeys() public view {
        assertEq(registry.count(), handler.knownCount(), "known-key count mismatch");
    }

    function invariant_EpochMatchesSuccessfulPublicationCount() public view {
        assertEq(registry.epoch(), handler.publicationCount(), "epoch must match successful publications");
    }

    function invariant_EnumerationHasNoDuplicatesAndMatchesGhostState() public view {
        uint256 total = registry.count();
        bytes32[] memory seen = new bytes32[](total);
        for (uint256 i = 0; i < total; ++i) {
            bytes32 key = registry.keyAt(i);
            IOctantRegistry.Entry memory entry = registry.getEntry(key);

            assertTrue(handler.known(key), "enumerated key must be known");
            assertEq(entry.addr, handler.lastAddr(key), "entry address mismatch");
            assertEq(uint8(entry.status), uint8(handler.lastStatus(key)), "entry status mismatch");
            assertEq(
                entry.compatibilityVersion,
                handler.lastCompatibilityVersion(key),
                "compatibility version mismatch"
            );
            assertGt(entry.bump, 0, "known entry bump must be positive");
            assertLe(entry.epoch, registry.epoch(), "entry epoch cannot exceed global epoch");
            assertEq(entry.runtimeCodeHash, entry.addr.codehash, "runtime code hash mismatch");

            address expectedResolved = entry.status == IOctantRegistry.EntryStatus.ACTIVE ? entry.addr : address(0);
            assertEq(registry.tryGetAddress(key), expectedResolved, "resolution status mismatch");

            for (uint256 j = 0; j < i; ++j) {
                assertTrue(seen[j] != key, "duplicate enumerated key");
            }
            seen[i] = key;
        }
    }

    function invariant_EveryKnownUniverseKeyIsEnumerable() public view {
        uint256 universe = handler.universeLength();
        for (uint256 i = 0; i < universe; ++i) {
            bytes32 key = handler.keyUniverse(i);
            if (handler.known(key)) {
                IOctantRegistry.Entry memory entry = registry.getEntry(key);
                assertEq(entry.addr, handler.lastAddr(key), "known universe address mismatch");
            } else {
                assertEq(registry.tryGetAddress(key), address(0), "unknown universe key must not resolve");
            }
        }
    }
}
