// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IMultistrategyVault } from "./IMultistrategyVault.sol";

interface IMultistrategyLockedVault is IMultistrategyVault {
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

    // Events
    event RageQuitInitiated(address indexed user, uint256 shares, uint256 unlockTime);
    event RageQuitCooldownPeriodChanged(uint256 oldPeriod, uint256 newPeriod);
    event PendingRageQuitCooldownPeriodChange(uint256 newPeriod, uint256 effectiveTimestamp);
    event RageQuitCancelled(address indexed user, uint256 freedShares);

    // Storage for lockup information per user
    struct LockupInfo {
        uint256 lockupTime; // When the lockup started
        uint256 unlockTime; // When shares become fully unlocked
    }

    // Custody struct to track locked shares during rage quit
    struct CustodyInfo {
        uint256 lockedShares; // Amount of shares locked for rage quit
        uint256 unlockTime; // When the shares can be withdrawn
    }

    function initiateRageQuit(uint256 shares) external;
    function proposeRageQuitCooldownPeriodChange(uint256 _rageQuitCooldownPeriod) external;
    function finalizeRageQuitCooldownPeriodChange() external;
    function cancelRageQuitCooldownPeriodChange() external;
    function getPendingRageQuitCooldownPeriod() external view returns (uint256);
    function getRageQuitCooldownPeriodChangeTimestamp() external view returns (uint256);
    function setRegenGovernance(address _regenGovernance) external;
    function cancelRageQuit() external;
    function getCustodyInfo(address user) external view returns (uint256 lockedShares, uint256 unlockTime);

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
