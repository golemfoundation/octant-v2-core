// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { OctantRegistry } from "src/registry/OctantRegistry.sol";
import { IOctantRegistry } from "src/interfaces/IOctantRegistry.sol";
import { RegistryManifest } from "src/registry/RegistryManifest.sol";

contract RegistryTarget {}

contract OctantRegistryTest is Test {
    OctantRegistry public registry;

    address public owner;
    address public stranger;
    address public targetA;
    address public targetB;
    address public targetC;

    bytes32 internal constant KEY_A = "AAVE_V3_STRATEGY_FACTORY";
    bytes32 internal constant KEY_B = "SPARK_STRATEGY_FACTORY";
    bytes32 internal constant KEY_C = "LIDO_STRATEGY_FACTORY";
    bytes32 internal constant COMPATIBILITY_VERSION = "3.0.4";

    event EntryPublished(
        bytes32 indexed key,
        address indexed addr,
        address indexed previousAddr,
        IOctantRegistry.EntryType entryType,
        IOctantRegistry.EntryStatus status,
        uint64 epoch,
        uint32 bump,
        bytes32 compatibilityVersion,
        bytes32 runtimeCodeHash
    );
    event BatchPublished(uint64 indexed epoch, bytes32 indexed manifestHash, string releaseLabel);
    event SuccessorSet(address indexed successor, uint64 indexed epoch);

    function setUp() public {
        owner = makeAddr("owner");
        stranger = makeAddr("stranger");
        targetA = address(new RegistryTarget());
        targetB = address(new RegistryTarget());
        targetC = address(new RegistryTarget());
        registry = new OctantRegistry(owner);
    }

    function test_publishBatch_CreatesEntryAndEpochMetadata() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.ACTIVE,
            COMPATIBILITY_VERSION
        );
        bytes32 expectedManifest = RegistryManifest.hash(block.chainid, address(registry), 0, updates, "1.3.0");

        vm.expectEmit(true, true, true, true);
        emit EntryPublished(
            KEY_A,
            targetA,
            address(0),
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.ACTIVE,
            1,
            1,
            COMPATIBILITY_VERSION,
            targetA.codehash
        );
        vm.expectEmit(true, true, true, true);
        emit BatchPublished(1, expectedManifest, "1.3.0");

        // Act
        vm.prank(owner);
        registry.publishBatch(0, updates, "1.3.0");

        // Assert
        assertEq(registry.getAddress(KEY_A), targetA, "active address mismatch");
        assertEq(registry.tryGetAddress(KEY_A), targetA, "tryGetAddress mismatch");
        assertEq(registry.count(), 1, "known-key count mismatch");
        assertEq(registry.keyAt(0), KEY_A, "enumerated key mismatch");
        assertEq(registry.epoch(), 1, "epoch mismatch");
        assertEq(registry.manifestHash(), expectedManifest, "manifest hash mismatch");
        assertEq(registry.releaseLabel(), "1.3.0", "release label mismatch");

        IOctantRegistry.Entry memory entry = registry.getEntry(KEY_A);
        assertEq(entry.addr, targetA, "entry address mismatch");
        assertEq(entry.updatedAt, uint64(block.timestamp), "entry timestamp mismatch");
        assertEq(entry.bump, 1, "initial bump mismatch");
        assertEq(entry.epoch, 1, "entry epoch mismatch");
        assertEq(uint8(entry.entryType), uint8(IOctantRegistry.EntryType.FACTORY), "entry type mismatch");
        assertEq(uint8(entry.status), uint8(IOctantRegistry.EntryStatus.ACTIVE), "entry status mismatch");
        assertEq(entry.compatibilityVersion, COMPATIBILITY_VERSION, "compatibility version mismatch");
        assertEq(entry.runtimeCodeHash, targetA.codehash, "runtime code hash mismatch");
    }

    function test_publishBatch_ManifestBindsExactPublicationInputs() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);
        bytes32 expectedManifest = RegistryManifest.hash(block.chainid, address(registry), 0, updates, "1.3.0");
        bytes32 otherChainManifest = RegistryManifest.hash(block.chainid + 1, address(registry), 0, updates, "1.3.0");
        bytes32 otherRegistryManifest = RegistryManifest.hash(block.chainid, address(this), 0, updates, "1.3.0");
        bytes32 otherEpochManifest = RegistryManifest.hash(block.chainid, address(registry), 1, updates, "1.3.0");
        bytes32 otherLabelManifest = RegistryManifest.hash(block.chainid, address(registry), 0, updates, "1.3.1");
        IOctantRegistry.Update[] memory otherUpdates = _singleActiveUpdate(KEY_A, targetB);
        bytes32 otherUpdatesManifest = RegistryManifest.hash(
            block.chainid,
            address(registry),
            0,
            otherUpdates,
            "1.3.0"
        );

        // Act
        vm.prank(owner);
        registry.publishBatch(0, updates, "1.3.0");

        // Assert
        assertEq(registry.manifestHash(), expectedManifest, "canonical manifest mismatch");
        assertNotEq(registry.manifestHash(), otherChainManifest, "manifest must bind chain");
        assertNotEq(registry.manifestHash(), otherRegistryManifest, "manifest must bind registry");
        assertNotEq(registry.manifestHash(), otherEpochManifest, "manifest must bind epoch");
        assertNotEq(registry.manifestHash(), otherLabelManifest, "manifest must bind release label");
        assertNotEq(registry.manifestHash(), otherUpdatesManifest, "manifest must bind updates");
    }

    function test_publishBatch_UpdatesAddressAndAllowsSameCompatibilityVersion() public {
        // Arrange
        _publish(
            _singleUpdate(
                KEY_A,
                targetA,
                IOctantRegistry.EntryType.FACTORY,
                IOctantRegistry.EntryStatus.ACTIVE,
                COMPATIBILITY_VERSION
            ),
            "1.3.0"
        );
        vm.warp(block.timestamp + 100);

        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetB,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.ACTIVE,
            COMPATIBILITY_VERSION
        );

        // Act
        vm.prank(owner);
        registry.publishBatch(1, updates, "1.3.1");

        // Assert
        IOctantRegistry.Entry memory entry = registry.getEntry(KEY_A);
        assertEq(entry.addr, targetB, "updated address mismatch");
        assertEq(entry.updatedAt, uint64(block.timestamp), "updated timestamp mismatch");
        assertEq(entry.bump, 2, "updated bump mismatch");
        assertEq(entry.epoch, 2, "updated epoch mismatch");
        assertEq(entry.compatibilityVersion, COMPATIBILITY_VERSION, "compatibility version should be reusable");
        assertEq(registry.count(), 1, "address replacement should not add a key");
    }

    function test_publishBatch_PublishesMultipleEntriesAtomically() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _threeActiveUpdates();

        // Act
        _publish(updates, "1.3.0");

        // Assert
        assertEq(registry.count(), 3, "known-key count mismatch");
        assertEq(registry.epoch(), 1, "batch should use one epoch");
        assertEq(registry.getAddress(KEY_A), targetA, "KEY_A address mismatch");
        assertEq(registry.getAddress(KEY_B), targetB, "KEY_B address mismatch");
        assertEq(registry.getAddress(KEY_C), targetC, "KEY_C address mismatch");
    }

    function test_publishBatch_RevertsForStaleEpoch() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_B, targetB);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__StaleEpoch.selector, uint64(0), uint64(1))
        );
        registry.publishBatch(0, updates, "1.3.1");
    }

    function test_publishBatch_RevertsForDuplicateKeyAndRollsBackEpoch() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = new IOctantRegistry.Update[](2);
        updates[0] = _activeUpdate(KEY_A, targetA);
        updates[1] = _activeUpdate(KEY_A, targetB);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__DuplicateKey.selector, KEY_A));
        registry.publishBatch(0, updates, "1.3.0");

        assertEq(registry.epoch(), 0, "reverted batch must not advance epoch");
        assertEq(registry.count(), 0, "reverted batch must not retain keys");
    }

    function test_publishBatch_RevertsForEmptyBatch() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = new IOctantRegistry.Update[](0);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__EmptyBatch.selector);
        registry.publishBatch(0, updates, "1.3.0");
    }

    function test_publishBatch_RevertsForInvalidReleaseLabelLength() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);

        // Act and assert: empty
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidReleaseLabelLength.selector, uint256(0))
        );
        registry.publishBatch(0, updates, "");

        // Act and assert: too long
        string memory longLabel = new string(65);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidReleaseLabelLength.selector, uint256(65))
        );
        registry.publishBatch(0, updates, longLabel);
    }

    function test_publishBatch_RevertsForInvalidKeys() public {
        // Arrange
        IOctantRegistry.Update[] memory emptyKeyUpdate = _singleActiveUpdate(bytes32(0), targetA);
        IOctantRegistry.Update[] memory lowercaseKeyUpdate = _singleActiveUpdate(bytes32("invalid"), targetA);
        bytes32 embeddedPaddingKey = hex"4141004200000000000000000000000000000000000000000000000000000000";
        IOctantRegistry.Update[] memory paddedKeyUpdate = _singleActiveUpdate(embeddedPaddingKey, targetA);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__EmptyKey.selector);
        registry.publishBatch(0, emptyKeyUpdate, "1.3.0");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidKey.selector, bytes32("invalid"))
        );
        registry.publishBatch(0, lowercaseKeyUpdate, "1.3.0");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidKey.selector, embeddedPaddingKey)
        );
        registry.publishBatch(0, paddedKeyUpdate, "1.3.0");
    }

    function test_publishBatch_RevertsForInvalidCompatibilityVersion() public {
        // Arrange
        bytes32 invalidVersion = bytes32(uint256(1) << 248);
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.ACTIVE,
            invalidVersion
        );

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidCompatibilityVersion.selector, invalidVersion)
        );
        registry.publishBatch(0, updates, "1.3.0");
    }

    function test_publishBatch_RevertsForZeroOrCodelessAddress() public {
        // Arrange
        IOctantRegistry.Update[] memory zeroAddressUpdate = _singleActiveUpdate(KEY_A, address(0));
        address eoa = makeAddr("eoa");
        IOctantRegistry.Update[] memory eoaUpdate = _singleActiveUpdate(KEY_A, eoa);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__ZeroAddress.selector);
        registry.publishBatch(0, zeroAddressUpdate, "1.3.0");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__NotAContract.selector, eoa));
        registry.publishBatch(0, eoaUpdate, "1.3.0");
    }

    function test_publishBatch_RevertsForUnsetTypeOrStatus() public {
        // Arrange
        IOctantRegistry.Update[] memory unsetTypeUpdate = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.UNSET,
            IOctantRegistry.EntryStatus.ACTIVE,
            bytes32(0)
        );
        IOctantRegistry.Update[] memory unsetStatusUpdate = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.UNSET,
            bytes32(0)
        );

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__InvalidEntryType.selector);
        registry.publishBatch(0, unsetTypeUpdate, "1.3.0");

        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__InvalidEntryStatus.selector);
        registry.publishBatch(0, unsetStatusUpdate, "1.3.0");
    }

    function test_publishBatch_RevertsWhenNewEntryIsInactive() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.DEPRECATED,
            bytes32(0)
        );

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__NewEntryMustBeActive.selector, KEY_A));
        registry.publishBatch(0, updates, "1.3.0");
    }

    function test_publishBatch_RevertsWhenEntryTypeChanges() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetB,
            IOctantRegistry.EntryType.CONTRACT,
            IOctantRegistry.EntryStatus.ACTIVE,
            bytes32(0)
        );

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOctantRegistry.OctantRegistry__EntryTypeMismatch.selector,
                KEY_A,
                IOctantRegistry.EntryType.FACTORY,
                IOctantRegistry.EntryType.CONTRACT
            )
        );
        registry.publishBatch(1, updates, "1.3.1");
    }

    function test_publishBatch_RevertsWhenInactiveUpdateChangesAddress() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetB,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.DISABLED,
            bytes32(0)
        );

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InactiveAddressChange.selector, KEY_A));
        registry.publishBatch(1, updates, "1.3.1");
    }

    function test_publishBatch_RevertsForNoOpAndRollsBackMetadata() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);
        _publish(updates, "1.3.0");
        bytes32 initialManifest = registry.manifestHash();

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__NoEntryChange.selector, KEY_A));
        registry.publishBatch(1, updates, "1.3.1");

        assertEq(registry.epoch(), 1, "no-op revert must preserve epoch");
        assertEq(registry.manifestHash(), initialManifest, "no-op revert must preserve manifest");
        assertEq(registry.releaseLabel(), "1.3.0", "no-op revert must preserve label");
    }

    function test_publishBatch_DeprecatesWithoutDeletingHistoryMetadata() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        IOctantRegistry.Update[] memory updates = _singleUpdate(
            KEY_A,
            targetA,
            IOctantRegistry.EntryType.FACTORY,
            IOctantRegistry.EntryStatus.DEPRECATED,
            bytes32(0)
        );

        // Act
        vm.warp(block.timestamp + 100);
        _publish(updates, "1.3.1");

        // Assert
        IOctantRegistry.Entry memory entry = registry.getEntry(KEY_A);
        assertEq(entry.addr, targetA, "deprecated entry should retain address");
        assertEq(entry.bump, 2, "deprecation should increment bump");
        assertEq(entry.epoch, 2, "deprecation epoch mismatch");
        assertEq(uint8(entry.status), uint8(IOctantRegistry.EntryStatus.DEPRECATED), "status mismatch");
        assertEq(registry.count(), 1, "deprecated key should remain enumerable");
        assertEq(registry.tryGetAddress(KEY_A), address(0), "deprecated key must not resolve through try getter");

        vm.expectRevert(
            abi.encodeWithSelector(
                IOctantRegistry.OctantRegistry__KeyNotActive.selector,
                KEY_A,
                IOctantRegistry.EntryStatus.DEPRECATED
            )
        );
        registry.getAddress(KEY_A);
    }

    function test_publishBatch_ReactivatesEntryWithoutResettingBump() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        _publish(
            _singleUpdate(
                KEY_A,
                targetA,
                IOctantRegistry.EntryType.FACTORY,
                IOctantRegistry.EntryStatus.DISABLED,
                bytes32(0)
            ),
            "1.3.1"
        );

        // Act
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.2");

        // Assert
        IOctantRegistry.Entry memory entry = registry.getEntry(KEY_A);
        assertEq(entry.bump, 3, "reactivation must preserve monotonic bump");
        assertEq(entry.epoch, 3, "reactivation epoch mismatch");
        assertEq(uint8(entry.status), uint8(IOctantRegistry.EntryStatus.ACTIVE), "reactivation status mismatch");
        assertEq(registry.getAddress(KEY_A), targetA, "reactivated key should resolve");
        assertEq(registry.count(), 1, "reactivation must not duplicate key");
    }

    function test_publishBatch_RevertsForNonOwner() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);

        // Act and assert
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.publishBatch(0, updates, "1.3.0");
    }

    function test_getters_RevertForUnknownKeyOrIndex() public {
        // Act and assert
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__KeyNotFound.selector, KEY_A));
        registry.getAddress(KEY_A);

        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__KeyNotFound.selector, KEY_A));
        registry.getEntry(KEY_A);

        assertEq(registry.tryGetAddress(KEY_A), address(0), "unknown key should return zero");

        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__IndexOutOfBounds.selector, 0, 0));
        registry.keyAt(0);
    }

    function test_setSuccessorOnce_FreezesRegistry() public {
        // Arrange
        _publish(_singleActiveUpdate(KEY_A, targetA), "1.3.0");
        OctantRegistry successor = new OctantRegistry(owner);

        vm.expectEmit(true, true, true, true);
        emit SuccessorSet(address(successor), 1);

        // Act
        vm.prank(owner);
        registry.setSuccessorOnce(1, address(successor));

        // Assert
        assertEq(registry.getSuccessor(), address(successor), "successor mismatch");

        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_B, targetB);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__AlreadySuperseded.selector, address(successor))
        );
        registry.publishBatch(1, updates, "1.3.1");
    }

    function test_setSuccessorOnce_RevertsForInvalidTargets() public {
        // Arrange
        address eoa = makeAddr("successorEoa");
        address nonRegistryContract = address(new RegistryTarget());

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidSuccessor.selector, address(0)));
        registry.setSuccessorOnce(0, address(0));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidSuccessor.selector, address(registry))
        );
        registry.setSuccessorOnce(0, address(registry));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidSuccessor.selector, eoa));
        registry.setSuccessorOnce(0, eoa);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidSuccessor.selector, nonRegistryContract)
        );
        registry.setSuccessorOnce(0, nonRegistryContract);
    }

    function test_setSuccessorOnce_RevertsForSupersededSuccessorCycle() public {
        // Arrange
        OctantRegistry successor = new OctantRegistry(owner);
        vm.prank(owner);
        registry.setSuccessorOnce(0, address(successor));

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__InvalidSuccessor.selector, address(registry))
        );
        successor.setSuccessorOnce(0, address(registry));
    }

    function test_setSuccessorOnce_RevertsForStaleEpochOrNonOwner() public {
        // Arrange
        OctantRegistry successor = new OctantRegistry(owner);

        // Act and assert
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IOctantRegistry.OctantRegistry__StaleEpoch.selector, uint64(1), uint64(0))
        );
        registry.setSuccessorOnce(1, address(successor));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setSuccessorOnce(0, address(successor));
    }

    function test_renounceOwnership_IsDisabled() public {
        // Act and assert
        vm.prank(owner);
        vm.expectRevert(IOctantRegistry.OctantRegistry__OwnershipRenunciationDisabled.selector);
        registry.renounceOwnership();
    }

    function test_Ownable2Step_Handover() public {
        // Arrange
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);

        assertEq(registry.owner(), owner, "owner should remain until acceptance");
        assertEq(registry.pendingOwner(), newOwner, "pending owner mismatch");

        // Act
        vm.prank(newOwner);
        registry.acceptOwnership();

        // Assert
        assertEq(registry.owner(), newOwner, "new owner mismatch");

        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registry.publishBatch(0, updates, "1.3.0");

        vm.prank(newOwner);
        registry.publishBatch(0, updates, "1.3.0");
        assertEq(registry.getAddress(KEY_A), targetA, "new owner should publish");
    }

    function test_supportsInterface_ReportsRegistryAndERC165() public view {
        assertTrue(
            registry.supportsInterface(type(IOctantRegistry).interfaceId),
            "registry interface should be supported"
        );
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId), "ERC165 should be supported");
        assertFalse(registry.supportsInterface(0xffffffff), "invalid interface should not be supported");
    }

    function test_API_VERSION_IsIndependentFromReleaseLabel() public {
        // Arrange
        IOctantRegistry.Update[] memory updates = _singleActiveUpdate(KEY_A, targetA);

        // Act
        _publish(updates, "octant-v1.3.0");

        // Assert
        assertEq(registry.API_VERSION(), "1.0.0", "registry API version mismatch");
        assertEq(registry.releaseLabel(), "octant-v1.3.0", "release label mismatch");
    }

    function _publish(IOctantRegistry.Update[] memory updates, string memory label) internal {
        uint64 expectedEpoch = registry.epoch();
        vm.prank(owner);
        registry.publishBatch(expectedEpoch, updates, label);
    }

    function _singleActiveUpdate(
        bytes32 key,
        address addr
    ) internal pure returns (IOctantRegistry.Update[] memory updates) {
        return
            _singleUpdate(key, addr, IOctantRegistry.EntryType.FACTORY, IOctantRegistry.EntryStatus.ACTIVE, bytes32(0));
    }

    function _singleUpdate(
        bytes32 key,
        address addr,
        IOctantRegistry.EntryType entryType,
        IOctantRegistry.EntryStatus status,
        bytes32 compatibilityVersion
    ) internal pure returns (IOctantRegistry.Update[] memory updates) {
        updates = new IOctantRegistry.Update[](1);
        updates[0] = IOctantRegistry.Update({
            key: key,
            addr: addr,
            entryType: entryType,
            status: status,
            compatibilityVersion: compatibilityVersion
        });
    }

    function _activeUpdate(bytes32 key, address addr) internal pure returns (IOctantRegistry.Update memory update) {
        return
            IOctantRegistry.Update({
                key: key,
                addr: addr,
                entryType: IOctantRegistry.EntryType.FACTORY,
                status: IOctantRegistry.EntryStatus.ACTIVE,
                compatibilityVersion: bytes32(0)
            });
    }

    function _threeActiveUpdates() internal view returns (IOctantRegistry.Update[] memory updates) {
        updates = new IOctantRegistry.Update[](3);
        updates[0] = _activeUpdate(KEY_A, targetA);
        updates[1] = _activeUpdate(KEY_B, targetB);
        updates[2] = _activeUpdate(KEY_C, targetC);
    }
}
