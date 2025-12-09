// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import { IHatsEligibility } from "src/utils/hats/interfaces/IHatsEligibility.sol";
import { IHatsToggle } from "src/utils/hats/interfaces/IHatsToggle.sol";

/**
 * @title SimpleEligibilityAndToggle
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice A simple pass-through implementation of IHatsEligibility and IHatsToggle
 * @dev Always returns true for both eligibility and toggle checks
 */
contract SimpleEligibilityAndToggle is IHatsEligibility, IHatsToggle {
    /**
     * @notice Always returns true for both eligibility and standing
     * @dev Used for testing and initial setup
     */
    function getWearerStatus(
        address, // wearer
        uint256 // hatId
    ) external pure override returns (bool eligible, bool standing) {
        return (true, true);
    }

    /**
     * @notice Always returns true for hat status
     * @dev Used for testing and initial setup
     */
    function getHatStatus(
        uint256 // hatId
    ) external pure override returns (bool) {
        return true;
    }
}
