// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.23;

/**
 * @title The Dragon
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for the Dragon contract, the facade to interact with an Octant-based ecosystem
 * @dev Draft interface for high-level integration entry points
 */
interface IDragon {
    /**
     * @notice Returns the dragon token address
     * @return dragonToken Token used as collateral for PG voting rights and rewards
     */
    function getDragonToken() external view returns (address);

    /**
     * @notice Returns the Octant router address
     * @return octantRouter Router for reward routing, transformation, and distribution
     */
    function getOctantRouter() external view returns (address);

    /**
     * @notice Returns the epochs guardian address
     * @return epochsGuardian Guardian defining rules and conditions for capital flows
     */
    function getEpochsGuardian() external view returns (address);
}
