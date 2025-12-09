// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/**
 * @title IHatsEligibility
 * @author Haberdasher Labs; adapted by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for hat eligibility modules
 * @dev Determines if an address is eligible and in good standing for a hat
 * @custom:origin https://github.com/Hats-Protocol/hats-protocol
 */
interface IHatsEligibility {
    /// @notice Returns the status of a wearer for a given hat
    /// @dev If standing is false, eligibility MUST also be false
    /// @param _wearer Address of current or prospective Hat wearer
    /// @param _hatId ID of hat in question
    /// @return eligible Whether the _wearer is eligible to wear the hat
    /// @return standing Whether the _wearer is in good standing
    function getWearerStatus(address _wearer, uint256 _hatId) external view returns (bool eligible, bool standing);
}
