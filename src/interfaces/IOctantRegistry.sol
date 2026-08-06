// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IOctantRegistry
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Canonical on-chain discovery registry for Octant production contracts
 * @dev Registry history is represented by indexed events. Current state remains small and
 *      directly queryable, while every publication is tied to one monotonic epoch and a
 *      canonical, contract-computed publication manifest.
 */
interface IOctantRegistry is IERC165 {
    /**
     * @notice Semantic category fixed when a key is first published
     */
    enum EntryType {
        UNSET,
        CONTRACT,
        FACTORY,
        REGISTRY
    }

    /**
     * @notice Current lifecycle state of a registry entry
     * @dev DEPRECATED means intentionally superseded but retained for historical discovery.
     *      DISABLED means explicitly unsupported or unsafe. Neither inactive state controls
     *      the registered contract itself; this registry is a discovery layer only.
     */
    enum EntryStatus {
        UNSET,
        ACTIVE,
        DEPRECATED,
        DISABLED
    }

    /**
     * @notice Current state stored for a registry key
     * @param addr Registered contract address
     * @param updatedAt Timestamp of the latest publication affecting the key
     * @param bump Monotonic per-key publication counter
     * @param epoch Registry epoch that last changed the key
     * @param entryType Semantic category fixed on first publication
     * @param status Current lifecycle status
     * @param compatibilityVersion Optional API compatibility version; zero when unspecified
     * @param runtimeCodeHash Runtime bytecode hash observed at publication
     */
    struct Entry {
        address addr;
        uint64 updatedAt;
        uint32 bump;
        uint64 epoch;
        EntryType entryType;
        EntryStatus status;
        bytes32 compatibilityVersion;
        bytes32 runtimeCodeHash;
    }

    /**
     * @notice One entry change included in an atomic publication
     * @param key Canonical bytes32 short-string key
     * @param addr Contract address to activate or whose status is changing
     * @param entryType Semantic category; immutable after first publication
     * @param status New lifecycle status
     * @param compatibilityVersion Optional API compatibility version; zero when unspecified
     */
    struct Update {
        bytes32 key;
        address addr;
        EntryType entryType;
        EntryStatus status;
        bytes32 compatibilityVersion;
    }

    /**
     * @notice Emitted for every entry changed by a publication
     * @param key Registry key
     * @param addr New contract address
     * @param previousAddr Previously registered address
     * @param entryType Semantic category
     * @param status New lifecycle status
     * @param epoch Registry epoch containing the change
     * @param bump Per-key publication counter
     * @param compatibilityVersion Optional API compatibility version
     * @param runtimeCodeHash Runtime bytecode hash observed at publication
     */
    event EntryPublished(
        bytes32 indexed key,
        address indexed addr,
        address indexed previousAddr,
        EntryType entryType,
        EntryStatus status,
        uint64 epoch,
        uint32 bump,
        bytes32 compatibilityVersion,
        bytes32 runtimeCodeHash
    );

    /**
     * @notice Emitted after all entry changes in an epoch are applied
     * @param epoch New registry epoch
     * @param manifestHash Hash of the complete registry publication manifest
     * @param releaseLabel Human-readable software or deployment release label
     */
    event BatchPublished(uint64 indexed epoch, bytes32 indexed manifestHash, string releaseLabel);

    /**
     * @notice Emitted when this registry is permanently superseded
     * @param successor Successor registry
     * @param epoch Final epoch of this registry
     */
    event SuccessorSet(address indexed successor, uint64 indexed epoch);

    error OctantRegistry__EmptyBatch();
    error OctantRegistry__EmptyKey();
    error OctantRegistry__InvalidKey(bytes32 key);
    error OctantRegistry__InvalidCompatibilityVersion(bytes32 compatibilityVersion);
    error OctantRegistry__InvalidEntryType();
    error OctantRegistry__InvalidEntryStatus();
    error OctantRegistry__NewEntryMustBeActive(bytes32 key);
    error OctantRegistry__EntryTypeMismatch(bytes32 key, EntryType expected, EntryType provided);
    error OctantRegistry__InactiveAddressChange(bytes32 key);
    error OctantRegistry__NoEntryChange(bytes32 key);
    error OctantRegistry__DuplicateKey(bytes32 key);
    error OctantRegistry__ZeroAddress();
    error OctantRegistry__NotAContract(address addr);
    error OctantRegistry__KeyNotFound(bytes32 key);
    error OctantRegistry__KeyNotActive(bytes32 key, EntryStatus status);
    error OctantRegistry__IndexOutOfBounds(uint256 index, uint256 count);
    error OctantRegistry__StaleEpoch(uint64 expected, uint64 actual);
    error OctantRegistry__EpochOverflow();
    error OctantRegistry__BumpOverflow(bytes32 key);
    error OctantRegistry__InvalidReleaseLabelLength(uint256 length);
    error OctantRegistry__AlreadySuperseded(address successor);
    error OctantRegistry__InvalidSuccessor(address successor);
    error OctantRegistry__OwnershipRenunciationDisabled();

    /**
     * @notice Atomically publishes a new registry epoch
     * @param expectedEpoch Current epoch expected by the proposal
     * @param updates Entry changes to publish
     * @param releaseLabel_ Human-readable software or deployment release label
     * @dev The canonical manifest hash is computed from the chain, this registry, the expected
     *      epoch, release label, and complete ordered update array.
     * @custom:security Only callable by the owner while this registry has no successor
     */
    function publishBatch(uint64 expectedEpoch, Update[] calldata updates, string calldata releaseLabel_) external;

    /**
     * @notice Permanently points this registry at its successor and freezes publications
     * @param expectedEpoch Current epoch expected by the proposal
     * @param successor_ Successor registry implementing this interface
     * @custom:security Only callable once by the owner
     */
    function setSuccessorOnce(uint64 expectedEpoch, address successor_) external;

    /**
     * @notice Returns the active address registered for a key
     * @param key Registry key
     * @return Registered contract address
     */
    function getAddress(bytes32 key) external view returns (address);

    /**
     * @notice Returns the active address for a key, or zero when absent or inactive
     * @param key Registry key
     * @return Registered active address or zero
     */
    function tryGetAddress(bytes32 key) external view returns (address);

    /**
     * @notice Returns the complete current state for a known key
     * @param key Registry key
     * @return entry Current entry state
     */
    function getEntry(bytes32 key) external view returns (Entry memory entry);

    /**
     * @notice Returns the number of keys ever published
     * @return Number of known keys
     */
    function count() external view returns (uint256);

    /**
     * @notice Returns a known key by enumeration index
     * @param index Index in the append-only key list
     * @return Registry key
     */
    function keyAt(uint256 index) external view returns (bytes32);

    /**
     * @notice Returns every key ever published
     * @return Append-only known-key list
     * @dev Intended for off-chain callers. Use count and keyAt for bounded on-chain iteration.
     */
    function list() external view returns (bytes32[] memory);

    /**
     * @notice Returns the registry interface implementation version
     * @return Semantic API version, independent of deployment release labels
     */
    function API_VERSION() external view returns (string memory);

    /**
     * @notice Returns the current monotonic registry epoch
     * @return Current epoch
     */
    function epoch() external view returns (uint64);

    /**
     * @notice Returns the manifest hash associated with the current epoch
     * @return Current deployment manifest hash
     */
    function manifestHash() external view returns (bytes32);

    /**
     * @notice Returns the release label associated with the current epoch
     * @return Current human-readable release label
     */
    function releaseLabel() external view returns (string memory);

    /**
     * @notice Returns the successor registry
     * @return Successor address or zero while this registry is current
     */
    function getSuccessor() external view returns (address);
}
