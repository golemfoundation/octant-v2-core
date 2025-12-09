// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/**
 * @title IHatsToggle
 * @author Haberdasher Labs; adapted by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for hat toggle modules
 * @dev Determines if a hat is active/inactive
 * @custom:origin https://github.com/Hats-Protocol/hats-protocol
 */
interface IHatsToggle {
    /**
     * @notice Returns the active status of a hat
     * @param _hatId Hat ID to check status for
     * @return True if hat is active, false if inactive or toggled off
     */
    function getHatStatus(uint256 _hatId) external view returns (bool);
}
