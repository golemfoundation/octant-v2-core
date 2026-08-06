// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IOctantRegistry } from "../interfaces/IOctantRegistry.sol";
import { RegistryManifest } from "./RegistryManifest.sol";

/**
 * @title OctantRegistry
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Canonical on-chain discovery registry for Octant production contracts
 * @dev Production contracts must not resolve runtime dependencies through this registry.
 *      Deployments and their registry publication are bundled in one Safe transaction.
 *
 *      Every successful publication increments a global epoch and records a canonical,
 *      contract-computed commitment to its complete input. Per-key history is available from
 *      EntryPublished events, while current state stays directly queryable. Keys are
 *      append-only and entries use explicit lifecycle states instead of destructive deletion.
 *
 *      This contract intentionally uses migration rather than proxy upgradeability. Setting
 *      a validated successor is irreversible and freezes all future publications.
 */
contract OctantRegistry is IOctantRegistry, Ownable2Step, ERC165 {
    /// @notice Contract API version used by repository semver tooling
    string public constant override API_VERSION = "1.0.0";

    uint256 internal constant MAX_RELEASE_LABEL_LENGTH = 64;

    mapping(bytes32 key => Entry entry) internal _entries;
    bytes32[] internal _keys;

    uint64 internal _epoch;
    bytes32 internal _manifestHash;
    string internal _releaseLabel;
    address internal _successor;

    /**
     * @notice Deploys the registry with an explicit initial owner
     * @param initialOwner Owner of the registry
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IOctantRegistry
    function publishBatch(
        uint64 expectedEpoch,
        Update[] calldata updates,
        string calldata releaseLabel_
    ) external onlyOwner {
        require(_successor == address(0), OctantRegistry__AlreadySuperseded(_successor));
        require(expectedEpoch == _epoch, OctantRegistry__StaleEpoch(expectedEpoch, _epoch));
        require(expectedEpoch != type(uint64).max, OctantRegistry__EpochOverflow());
        require(updates.length != 0, OctantRegistry__EmptyBatch());

        uint256 releaseLabelLength = bytes(releaseLabel_).length;
        require(
            releaseLabelLength != 0 && releaseLabelLength <= MAX_RELEASE_LABEL_LENGTH,
            OctantRegistry__InvalidReleaseLabelLength(releaseLabelLength)
        );

        bytes32 publicationHash = RegistryManifest.hash(
            block.chainid,
            address(this),
            expectedEpoch,
            updates,
            releaseLabel_
        );
        uint64 nextEpoch = expectedEpoch + 1;
        _epoch = nextEpoch;
        _manifestHash = publicationHash;
        _releaseLabel = releaseLabel_;

        uint256 updatesLength = updates.length;
        for (uint256 i = 0; i < updatesLength; ++i) {
            _publishEntry(updates[i], nextEpoch);
        }

        emit BatchPublished(nextEpoch, publicationHash, releaseLabel_);
    }

    /// @inheritdoc IOctantRegistry
    function setSuccessorOnce(uint64 expectedEpoch, address successor_) external onlyOwner {
        require(_successor == address(0), OctantRegistry__AlreadySuperseded(_successor));
        require(expectedEpoch == _epoch, OctantRegistry__StaleEpoch(expectedEpoch, _epoch));
        require(
            successor_ != address(0) && successor_ != address(this) && successor_.code.length != 0,
            OctantRegistry__InvalidSuccessor(successor_)
        );

        (bool supportsInterfaceCallSucceeded, bytes memory supportsInterfaceData) = successor_.staticcall(
            abi.encodeCall(IERC165.supportsInterface, (type(IOctantRegistry).interfaceId))
        );
        require(
            supportsInterfaceCallSucceeded &&
                supportsInterfaceData.length == 32 &&
                abi.decode(supportsInterfaceData, (bool)),
            OctantRegistry__InvalidSuccessor(successor_)
        );

        (bool successorCallSucceeded, bytes memory successorData) = successor_.staticcall(
            abi.encodeCall(IOctantRegistry.getSuccessor, ())
        );
        require(
            successorCallSucceeded && successorData.length == 32 && abi.decode(successorData, (address)) == address(0),
            OctantRegistry__InvalidSuccessor(successor_)
        );

        _successor = successor_;
        emit SuccessorSet(successor_, _epoch);
    }

    /// @inheritdoc IOctantRegistry
    function getAddress(bytes32 key) external view returns (address) {
        Entry storage entry = _entries[key];
        require(entry.bump != 0, OctantRegistry__KeyNotFound(key));
        require(entry.status == EntryStatus.ACTIVE, OctantRegistry__KeyNotActive(key, entry.status));
        return entry.addr;
    }

    /// @inheritdoc IOctantRegistry
    function tryGetAddress(bytes32 key) external view returns (address) {
        Entry storage entry = _entries[key];
        return entry.status == EntryStatus.ACTIVE ? entry.addr : address(0);
    }

    /// @inheritdoc IOctantRegistry
    function getEntry(bytes32 key) external view returns (Entry memory entry) {
        entry = _entries[key];
        require(entry.bump != 0, OctantRegistry__KeyNotFound(key));
    }

    /// @inheritdoc IOctantRegistry
    function count() external view returns (uint256) {
        return _keys.length;
    }

    /// @inheritdoc IOctantRegistry
    function keyAt(uint256 index) external view returns (bytes32) {
        uint256 keysLength = _keys.length;
        require(index < keysLength, OctantRegistry__IndexOutOfBounds(index, keysLength));
        return _keys[index];
    }

    /// @inheritdoc IOctantRegistry
    function list() external view returns (bytes32[] memory) {
        return _keys;
    }

    /// @inheritdoc IOctantRegistry
    function epoch() external view returns (uint64) {
        return _epoch;
    }

    /// @inheritdoc IOctantRegistry
    function manifestHash() external view returns (bytes32) {
        return _manifestHash;
    }

    /// @inheritdoc IOctantRegistry
    function releaseLabel() external view returns (string memory) {
        return _releaseLabel;
    }

    /// @inheritdoc IOctantRegistry
    function getSuccessor() external view returns (address) {
        return _successor;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IOctantRegistry).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Ownership renunciation is disabled; use setSuccessorOnce to freeze this registry
     */
    function renounceOwnership() public pure override {
        require(false, OctantRegistry__OwnershipRenunciationDisabled());
    }

    function _publishEntry(Update calldata update, uint64 nextEpoch) internal {
        bytes32 key = update.key;
        _validateKey(key);
        _validateCompatibilityVersion(update.compatibilityVersion);

        require(update.addr != address(0), OctantRegistry__ZeroAddress());
        require(update.addr.code.length != 0, OctantRegistry__NotAContract(update.addr));
        require(update.entryType != EntryType.UNSET, OctantRegistry__InvalidEntryType());
        require(update.status != EntryStatus.UNSET, OctantRegistry__InvalidEntryStatus());

        Entry storage entry = _entries[key];
        require(entry.epoch != nextEpoch, OctantRegistry__DuplicateKey(key));

        address previousAddr = entry.addr;
        bytes32 runtimeCodeHash = update.addr.codehash;
        if (entry.bump == 0) {
            require(update.status == EntryStatus.ACTIVE, OctantRegistry__NewEntryMustBeActive(key));
            _keys.push(key);
            entry.entryType = update.entryType;
        } else {
            require(
                update.entryType == entry.entryType,
                OctantRegistry__EntryTypeMismatch(key, entry.entryType, update.entryType)
            );
            require(
                update.status == EntryStatus.ACTIVE || update.addr == previousAddr,
                OctantRegistry__InactiveAddressChange(key)
            );
            require(entry.bump != type(uint32).max, OctantRegistry__BumpOverflow(key));
            require(
                update.addr != previousAddr ||
                    update.status != entry.status ||
                    update.compatibilityVersion != entry.compatibilityVersion ||
                    runtimeCodeHash != entry.runtimeCodeHash,
                OctantRegistry__NoEntryChange(key)
            );
        }

        entry.addr = update.addr;
        entry.updatedAt = uint64(block.timestamp);
        entry.bump += 1;
        entry.epoch = nextEpoch;
        entry.status = update.status;
        entry.compatibilityVersion = update.compatibilityVersion;
        entry.runtimeCodeHash = runtimeCodeHash;

        emit EntryPublished(
            key,
            update.addr,
            previousAddr,
            entry.entryType,
            update.status,
            nextEpoch,
            entry.bump,
            update.compatibilityVersion,
            runtimeCodeHash
        );
    }

    function _validateKey(bytes32 key) internal pure {
        require(key != bytes32(0), OctantRegistry__EmptyKey());

        bool encounteredPadding = false;
        for (uint256 i = 0; i < 32; ++i) {
            uint8 character = uint8(key[i]);
            if (character == 0) {
                encounteredPadding = true;
            } else {
                bool isUppercaseLetter = character >= 65 && character <= 90;
                bool isDigit = character >= 48 && character <= 57;
                require(
                    !encounteredPadding && (isUppercaseLetter || isDigit || character == 95),
                    OctantRegistry__InvalidKey(key)
                );
            }
        }
    }

    function _validateCompatibilityVersion(bytes32 compatibilityVersion) internal pure {
        if (compatibilityVersion == bytes32(0)) return;

        bool encounteredPadding = false;
        for (uint256 i = 0; i < 32; ++i) {
            uint8 character = uint8(compatibilityVersion[i]);
            if (character == 0) {
                encounteredPadding = true;
            } else {
                require(
                    !encounteredPadding && character >= 33 && character <= 126,
                    OctantRegistry__InvalidCompatibilityVersion(compatibilityVersion)
                );
            }
        }
    }
}
