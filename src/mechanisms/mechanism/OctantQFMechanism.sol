// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { QuadraticVotingMechanism } from "./QuadraticVotingMechanism.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";
import { AllocationConfig, TokenizedAllocationMechanism } from "src/mechanisms/BaseAllocationMechanism.sol";
import { NotInAllowset, InBlockset } from "src/errors.sol";

/// @title Octant Quadratic Funding Mechanism
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
/// @notice Quadratic funding mechanism with configurable signup access control.
/// @dev Extends `QuadraticVotingMechanism` and integrates allowset/blockset access modes
///      to restrict who can register during contribution windows. Owner-only control via
///      underlying `TokenizedAllocationMechanism` ownership checks.
contract OctantQFMechanism is QuadraticVotingMechanism {
    /// @notice Current access mode for signup eligibility (NONE, ALLOWSET, BLOCKSET)
    AccessMode public contributionAccessMode;
    /// @notice Address set used when `contributionAccessMode == ALLOWSET`
    IAddressSet public contributionAllowset;
    /// @notice Address set used when `contributionAccessMode == BLOCKSET`
    IAddressSet public contributionBlockset;

    /// @notice Emitted when the allowset contract is assigned
    /// @param allowset New allowset contract
    event ContributionAllowsetAssigned(IAddressSet indexed allowset);
    /// @notice Emitted when the blockset contract is assigned
    /// @param blockset New blockset contract
    event ContributionBlocksetAssigned(IAddressSet indexed blockset);
    /// @notice Emitted when the contribution access mode is updated
    /// @param mode New access mode (NONE, ALLOWSET, BLOCKSET)
    event AccessModeSet(AccessMode indexed mode);

    /// @notice Construct a new OctantQF mechanism
    /// @param _implementation Address of shared TokenizedAllocationMechanism implementation
    /// @param _config Allocation configuration struct
    /// @param _alphaNumerator Alpha numerator (dimensionless; 1.0 = denominator)
    /// @param _alphaDenominator Alpha denominator (must be > 0)
    /// @param _contributionAllowset Address set used in ALLOWSET mode
    /// @param _contributionBlockset Address set used in BLOCKSET mode
    /// @param _contributionAccessMode Initial access mode (NONE, ALLOWSET, BLOCKSET)
    constructor(
        address _implementation,
        AllocationConfig memory _config,
        uint256 _alphaNumerator,
        uint256 _alphaDenominator,
        IAddressSet _contributionAllowset,
        IAddressSet _contributionBlockset,
        AccessMode _contributionAccessMode
    ) QuadraticVotingMechanism(_implementation, _config, _alphaNumerator, _alphaDenominator) {
        contributionAllowset = _contributionAllowset;
        contributionBlockset = _contributionBlockset;
        contributionAccessMode = _contributionAccessMode;

        emit ContributionAllowsetAssigned(_contributionAllowset);
        emit ContributionBlocksetAssigned(_contributionBlockset);
        emit AccessModeSet(_contributionAccessMode);
    }

    /// @notice Hook to validate user eligibility during signup
    /// @param user Address attempting to register
    /// @return True if registration should proceed
    /// @dev Reverts with specific error messages for unauthorized users
    function _beforeSignupHook(address user) internal view virtual override returns (bool) {
        if (!_isUserAuthorized(user)) {
            if (contributionAccessMode == AccessMode.ALLOWSET) {
                revert NotInAllowset(user);
            } else {
                revert InBlockset(user);
            }
        }
        return true;
    }

    /// @dev Internal helper to check access control without reverting
    /// @param user Address to check
    /// @return True if user passes access control checks, false otherwise
    function _isUserAuthorized(address user) internal view returns (bool) {
        if (contributionAccessMode == AccessMode.ALLOWSET) {
            return contributionAllowset.contains(user);
        } else if (contributionAccessMode == AccessMode.BLOCKSET) {
            return !contributionBlockset.contains(user);
        }
        return true;
    }

    /// @notice Sets the contribution allowset (for ALLOWSET mode)
    /// @param _allowset New allowset contract address
    /// @dev Non-retroactive. Existing voting power is not affected.
    /// @custom:security Only owner via underlying mechanism ownership check
    function setContributionAllowset(IAddressSet _allowset) external {
        require(_tokenizedAllocation().owner() == msg.sender, "Only owner");
        contributionAllowset = _allowset;
        emit ContributionAllowsetAssigned(_allowset);
    }

    /// @notice Sets the contribution blockset (for BLOCKSET mode)
    /// @param _blockset New blockset contract address
    /// @dev Non-retroactive. Existing voting power is not affected.
    /// @custom:security Only owner via underlying mechanism ownership check
    function setContributionBlockset(IAddressSet _blockset) external {
        require(_tokenizedAllocation().owner() == msg.sender, "Only owner");
        contributionBlockset = _blockset;
        emit ContributionBlocksetAssigned(_blockset);
    }

    /// @notice Sets the contribution access mode
    /// @param _mode New access mode (NONE, ALLOWSET, or BLOCKSET)
    /// @dev Only allowed before voting starts or after tally finalization.
    ///      Non-retroactive. Existing voting power is not affected.
    /// @custom:security Only owner via underlying mechanism; blocked during active voting
    function setAccessMode(AccessMode _mode) external {
        TokenizedAllocationMechanism tam = _tokenizedAllocation();
        require(tam.owner() == msg.sender, "Only owner");

        // Safety check: Prevent mode switching during active voting or before finalization
        // This prevents attackers from gaining voting power mid-vote or front-running mode switches
        bool beforeVoting = block.timestamp < tam.votingStartTime();
        bool afterFinalization = tam.tallyFinalized();
        require(
            beforeVoting || afterFinalization,
            "Mode changes only allowed before voting starts or after tally finalization"
        );

        contributionAccessMode = _mode;
        emit AccessModeSet(_mode);
    }

    /// @notice Checks if a user is eligible to signup/contribute based on current access mode
    /// @dev Required for allocation mechanism to be compatible with RegenStaker.
    ///      Used for defense-in-depth checks. Respects contributionAccessMode:
    ///      NONE: always returns true
    ///      ALLOWSET: returns true if user is in contributionAllowset
    ///      BLOCKSET: returns true if user is NOT in contributionBlockset
    /// @param user Address to check
    /// @return canSignup_ True if user can signup, false otherwise
    function canSignup(address user) external view returns (bool) {
        return _isUserAuthorized(user);
    }
}
