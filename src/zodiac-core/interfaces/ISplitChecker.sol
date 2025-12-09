// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title Split Checker Interface
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Validates that a configured split over recipients adheres to required constraints
 *         (e.g., allocation precision, totals, inclusion of OPEX/metapool recipients).
 */
interface ISplitChecker {
    struct Split {
        address[] recipients; // [r1, r2, ..., opexVault, metapool]
        uint256[] allocations; // should be in SPLIT_PRECISION terms
        uint256 totalAllocations; // should be in SPLIT_PRECISION terms
    }

    /// @notice Validates that a split configuration adheres to required constraints
    /// @param split Split configuration containing recipients, allocations, and total
    /// @param opexVault Address of the OPEX vault that must be included
    /// @param metapool Address of the metapool that must be included
    function checkSplit(Split memory split, address opexVault, address metapool) external view;
}
