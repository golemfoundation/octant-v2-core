// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

/**
 * @title Octant Multistrategy Locked Vault Interface
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Extends the base multistrategy vault with share lockups and a user-driven rage-quit flow.
 * @dev Enables users to initiate a rage quit that locks their shares for a cooldown period before
 *      withdrawal. Governance (regen governance) can update the cooldown via a two-step change with
 *      a time delay. Integrations should account for custodied (locked) shares versus available shares.
 *
 *      Extends Yearn V3 Multistrategy Vault with Octant-specific lockup functionality.
 */
interface IMultistrategyLockedVault is IMultistrategyVault {
    /**
     * @notice Storage for lockup information per user
     * @param lockupTime Timestamp when lockup started in seconds
     * @param unlockTime Timestamp when shares become fully unlocked in seconds
     */
    struct LockupInfo {
        uint256 lockupTime;
        uint256 unlockTime;
    }

    /**
     * @notice Custody struct to track locked shares during rage quit
     * @param lockedShares Amount of vault shares locked for rage quit
     * @param unlockTime Timestamp when shares can be withdrawn in seconds
     */
    struct CustodyInfo {
        uint256 lockedShares;
        uint256 unlockTime;
    }

    // Events
    /// @notice Emitted when a user initiates rage quit
    /// @param user User who initiated rage quit
    /// @param shares Amount of shares locked for rage quit
    /// @param unlockTime Timestamp when shares can be withdrawn
    event RageQuitInitiated(address indexed user, uint256 shares, uint256 unlockTime);
    /// @notice Emitted when rage quit cooldown period is changed
    /// @param oldPeriod Previous cooldown period in seconds
    /// @param newPeriod New cooldown period in seconds
    event RageQuitCooldownPeriodChanged(uint256 oldPeriod, uint256 newPeriod);
    /// @notice Emitted when a cooldown period change is proposed
    /// @param newPeriod Proposed cooldown period in seconds
    /// @param effectiveTimestamp Timestamp when change can be finalized
    event PendingRageQuitCooldownPeriodChange(uint256 newPeriod, uint256 effectiveTimestamp);
    /// @notice Emitted when a pending cooldown period change is cancelled
    /// @param pendingPeriod Period that was pending in seconds
    /// @param proposedAt Timestamp when change was proposed
    /// @param cancelledAt Timestamp when change was cancelled
    event RageQuitCooldownPeriodChangeCancelled(uint256 pendingPeriod, uint256 proposedAt, uint256 cancelledAt);
    /// @notice Emitted when user cancels their active rage quit
    /// @param user User who cancelled rage quit
    /// @param freedShares Amount of shares unlocked
    event RageQuitCancelled(address indexed user, uint256 freedShares);
    /// @notice Emitted when regen governance address is changed
    /// @param previousGovernance Previous governance address
    /// @param newGovernance New governance address
    event RegenGovernanceChanged(address indexed previousGovernance, address indexed newGovernance);

    // Add necessary error definitions
    error InvalidRageQuitCooldownPeriod();
    error SharesStillLocked();
    error RageQuitAlreadyInitiated();
    error NoSharesToRageQuit();
    error NotRegenGovernance();
    error InvalidShareAmount();
    error InsufficientBalance();
    error InsufficientAvailableShares();
    error ExceedsCustodiedAmount();
    error NoCustodiedShares();
    error NoActiveRageQuit();
    error TransferExceedsAvailableShares();
    error NoPendingRageQuitCooldownPeriodChange();
    error RageQuitCooldownPeriodChangeDelayNotElapsed();
    error RageQuitCooldownPeriodChangeDelayElapsed();
    error InvalidGovernanceAddress();

    function initiateRageQuit(uint256 shares) external;

    /**
     * @notice Proposes a new rage quit cooldown period
     * @dev Starts a pending change which must later be finalized after the delay elapses
     * @param _rageQuitCooldownPeriod Cooldown period in seconds
     * @custom:security Only regen governance
     */
    function proposeRageQuitCooldownPeriodChange(uint256 _rageQuitCooldownPeriod) external;

    /**
     * @notice Finalizes a previously proposed rage quit cooldown period change after the delay
     * @custom:security Only regen governance
     */
    function finalizeRageQuitCooldownPeriodChange() external;

    /**
     * @notice Cancels a pending rage quit cooldown period change
     * @custom:security Only regen governance
     */
    function cancelRageQuitCooldownPeriodChange() external;

    /**
     * @notice Sets the regen governance address authorized to manage rage quit parameters.
     * @param _regenGovernance The new regen governance address.
     */
    function setRegenGovernance(address _regenGovernance) external;

    /**
     * @notice Cancels an active rage quit for the caller and frees any locked shares.
     */
    function cancelRageQuit() external;

    /**
     * @notice Get the amount of shares that can be transferred by a user
     * @param user The address to check transferable shares for
     * @return The amount of shares available for transfer (not locked in custody)
     */
    function getTransferableShares(address user) external view returns (uint256);

    /**
     * @notice Get the amount of shares available for rage quit initiation
     * @param user The address to check rage quitable shares for
     * @return The amount of shares available for initiating rage quit
     */
    function getRageQuitableShares(address user) external view returns (uint256);
}
