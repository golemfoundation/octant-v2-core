// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

/**
 * @title IFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for the factory that deployed the vault
 * @dev Used to query protocol fee configuration
 */
interface IFactory {
    /// @notice Get the protocol fee configuration
    /// @return feeBps Protocol fee in basis points (10000 = 100%)
    /// @return feeRecipient Address receiving protocol fees
    /// @dev Returns (0, address(0)) if no protocol fee configured
    function protocolFeeConfig() external view returns (uint16 feeBps, address feeRecipient);
}
