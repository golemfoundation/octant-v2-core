// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract HarnessProperQF is ProperQF(18) {
    // Custom Errors
    error AlphaMustBeLEQOne();
    error PercentageMustBeLEQ100();

    // Expose internal functions for testing
    function exposed_sqrt(uint256 x) public pure returns (uint256) {
        return Math.sqrt(x);
    }

    function exposed_processVote(uint256 projectId, uint256 contribution, uint256 voteWeight) public {
        ProperQF._processVote(projectId, contribution, voteWeight);
    }

    /**
     * @notice Exposes the internal _setAlpha function for testing
     * @param newNumerator The numerator of the new alpha value
     * @param newDenominator The denominator of the new alpha value
     */
    function exposed_setAlpha(uint256 newNumerator, uint256 newDenominator) public {
        ProperQF._setAlpha(newNumerator, newDenominator);
    }

    /**
     * @notice Exposes a function to set alpha using a decimal value for testing convenience
     * @param alphaAsDecimal The alpha value as a decimal (e.g., 0.6e18 for 0.6)
     * @dev Converts the decimal input to the internal fraction representation
     */
    function exposed_setAlphaDecimal(uint256 alphaAsDecimal) public {
        if (alphaAsDecimal > 1e18) revert AlphaMustBeLEQOne();
        uint256 newNumerator = alphaAsDecimal;
        uint256 newDenominator = 1e18;
        ProperQF._setAlpha(newNumerator, newDenominator);
    }

    /**
     * @notice Exposes a function to set alpha using percentage for testing convenience
     * @param percentage The alpha value as a percentage (e.g., 60 for 0.6)
     * @dev Converts the percentage input to the internal fraction representation
     */
    function exposed_setAlphaPercentage(uint256 percentage) public {
        if (percentage > 100) revert PercentageMustBeLEQ100();
        uint256 newNumerator = percentage;
        uint256 newDenominator = 100;
        ProperQF._setAlpha(newNumerator, newDenominator);
    }

    /// @notice Exposes the internal _calculateOptimalAlpha function for testing
    function exposed_calculateOptimalAlpha(
        uint256 matchingPoolAmount,
        uint256 quadraticSum,
        uint256 linearSum,
        uint256 totalUserDeposits
    ) public pure returns (uint256, uint256) {
        return ProperQF._calculateOptimalAlpha(matchingPoolAmount, quadraticSum, linearSum, totalUserDeposits);
    }

    /// @notice Exposes _processVoteUnchecked for testing underflow guards
    function exposed_processVoteUnchecked(uint256 projectId, uint256 contribution, uint256 voteWeight) public {
        ProperQF._processVoteUnchecked(projectId, contribution, voteWeight);
    }

    /// @notice Directly set totalQuadraticSum for testing underflow scenarios
    function setTotalQuadraticSum(uint256 value) public {
        ProperQFStorage storage s = _getProperQFStorage();
        s.totalQuadraticSum = value;
    }

    /// @notice Directly set totalLinearSum for testing underflow scenarios
    function setTotalLinearSum(uint256 value) public {
        ProperQFStorage storage s = _getProperQFStorage();
        s.totalLinearSum = value;
    }

    /// @notice Directly set project data for testing (encodes into packed storage)
    function setProject(uint256 projectId, uint256 sumContributions, uint256 sumSquareRoots) public {
        _writeProject(projectId, sumContributions, sumSquareRoots);
    }
}
