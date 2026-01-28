// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { ITokenizedStrategy } from "./ITokenizedStrategy.sol";

/**
 * @title IDragonTokenizedStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for dragon mode strategies with voluntary lockups and rage quit
 * @dev Extends ITokenizedStrategy with lockup mechanics and dragon-only deposit controls
 */
interface IDragonTokenizedStrategy is ITokenizedStrategy {
    // DragonTokenizedStrategy storage slot
    struct DragonTokenizedStrategyStorage {
        bool isDragonOnly;
    }
    /**
     * @notice Emitted when a new lockup is set for a user
     * @param user User whose lockup was set
     * @param lockTime Timestamp when lockup was set
     * @param unlockTime Timestamp when shares will be unlocked
     * @param lockedShares Amount of shares locked in share base units
     */
    event NewLockupSet(address indexed user, uint256 lockTime, uint256 unlockTime, uint256 lockedShares);

    /// @notice Emitted when lockup duration is updated
    /// @param lockupDuration New lockup duration in seconds
    event LockupDurationSet(uint256 lockupDuration);
    /// @notice Emitted when rage quit cooldown period is updated
    /// @param rageQuitCooldownPeriod New rage quit cooldown period in seconds
    event RageQuitCooldownPeriodSet(uint256 rageQuitCooldownPeriod);

    /**
     * @notice Emitted when a user initiates rage quit
     * @param user User who initiated rage quit
     * @param unlockTime New unlock time after rage quit (timestamp)
     */
    event RageQuitInitiated(address indexed user, uint256 indexed unlockTime);

    /**
     * @notice Emitted when Dragon-only mode is toggled
     * @param enabled True if Dragon-only mode is enabled, false otherwise
     */
    event DragonModeToggled(bool enabled);

    /**
     * @notice Deposits assets with a lockup period
     * @param assets Amount of assets to deposit in asset base units
     * @param receiver Address to receive the shares
     * @param lockupDuration Lockup duration in seconds
     * @return shares Amount of shares minted in share base units
     */
    function depositWithLockup(
        uint256 assets,
        address receiver,
        uint256 lockupDuration
    ) external payable returns (uint256 shares);

    /**
     * @notice Mints shares with a lockup period
     * @param shares Amount of shares to mint in share base units
     * @param receiver Address to receive the shares
     * @param lockupDuration Lockup duration in seconds
     * @return assets Amount of assets used in asset base units
     */
    function mintWithLockup(
        uint256 shares,
        address receiver,
        uint256 lockupDuration
    ) external payable returns (uint256 assets);

    /**
     * @notice Initiates a rage quit, allowing gradual withdrawal over the cooldown period
     * @dev Sets a cooldown period lockup and enables proportional withdrawals
     */
    function initiateRageQuit() external;

    /**
     * @notice Toggles the Dragon-only mode
     * @param enabled True to enable Dragon-only mode, false to disable
     */
    function toggleDragonMode(bool enabled) external;

    /**
     * @notice Sets the minimum lockup duration
     * @param newDuration New minimum lockup duration in seconds
     */
    function setLockupDuration(uint256 newDuration) external;

    /**
     * @notice Sets the rage quit cooldown period
     * @param newPeriod New rage quit cooldown period in seconds
     */
    function setRageQuitCooldownPeriod(uint256 newPeriod) external;

    /**
     * @notice Indicates if the strategy is in Dragon-only mode
     * @return True if only the operator can deposit/mint, false otherwise
     */
    function isDragonOnly() external view returns (bool);

    /**
     * @notice Returns the amount of unlocked shares for a user
     * @param user User's address
     * @return Amount of shares that can be withdrawn or redeemed in share base units
     */
    function unlockedShares(address user) external view returns (uint256);

    /**
     * @notice Returns the unlock time for a user's locked shares
     * @param user User's address
     * @return Unlock timestamp in seconds
     */
    function getUnlockTime(address user) external view returns (uint256);

    /**
     * @notice Returns detailed information about a user's lockup status
     * @param user Address to check
     * @return unlockTime Timestamp when shares unlock in seconds
     * @return lockedShares Amount of shares that are locked in share base units
     * @return isRageQuit Whether user is in rage quit mode
     * @return totalShares Total shares owned by user in share base units
     * @return withdrawableShares Amount of shares that can be withdrawn now in share base units
     */
    function getUserLockupInfo(
        address user
    )
        external
        view
        returns (
            uint256 unlockTime,
            uint256 lockedShares,
            bool isRageQuit,
            uint256 totalShares,
            uint256 withdrawableShares
        );

    /**
     * @notice Returns the remaining cooldown time in seconds for a user's lock
     * @param user Address to check
     * @return remainingTime Time remaining in seconds until unlock (0 if already unlocked)
     */
    function getRemainingCooldown(address user) external view returns (uint256 remainingTime);

    /**
     * @notice Returns the minimum lockup duration
     * @return Minimum lockup duration in seconds
     */
    function minimumLockupDuration() external view returns (uint256);

    /**
     * @notice Returns the rage quit cooldown period
     * @return Rage quit cooldown period in seconds
     */
    function rageQuitCooldownPeriod() external view returns (uint256);

    /**
     * @notice Returns the regen governance address
     * @return Address of regen governance
     */
    function regenGovernance() external view returns (address);
}
