// SPDX-License-Identifier: AGPL-3.0-only
// This contract inherits from IAccessControlledEarningPowerCalculator by [Golem Foundation](https://golem.foundation)
// IAccessControlledEarningPowerCalculator is licensed under AGPL-3.0-only.
// Users of this contract should ensure compliance with the AGPL-3.0-only license terms of the inherited IAccessControlledEarningPowerCalculator contract.

pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IAccessControlledEarningPowerCalculator } from "src/regen/interfaces/IAccessControlledEarningPowerCalculator.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessMode } from "src/constants.sol";

/**
 * @title RegenEarningPowerCalculator
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Calculates staking earning power with access control
 * @dev Linear earning power calculation with access control gates
 *
 *      EARNING POWER FORMULA:
 *      earningPower = min(stakedAmount, type(uint96).max)
 *
 *      ACCESS CONTROL MODES:
 *      - NONE: Everyone has access (permissionless)
 *      - ALLOWSET: Only addresses in allowset
 *      - BLOCKSET: All except addresses in blockset
 *
 *      BEHAVIOR:
 *      - If user has access: earningPower = staked amount (capped at uint96 max)
 *      - If user lacks access: earningPower = 0 (no rewards)
 *
 *      BUMP QUALIFICATION:
 *      User qualifies for earning power bump when:
 *      - Access status changes (added/removed from set)
 *      - Staked amount changes
 *      - Old earning power ≠ new earning power
 *
 * @custom:security Access control determines reward eligibility
 */
contract RegenEarningPowerCalculator is IAccessControlledEarningPowerCalculator, Ownable, ERC165 {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The allowset contract that determines which addresses are eligible to earn power (ALLOWSET mode)
    /// @dev Active only when accessMode == AccessMode.ALLOWSET
    IAddressSet public override allowset;

    /// @notice The blockset contract that determines which addresses are blocked from earning (BLOCKSET mode)
    /// @dev Active only when accessMode == AccessMode.BLOCKSET
    IAddressSet public blockset;

    /// @notice Current access mode for earning power
    /// @dev Determines which address set is active
    AccessMode public accessMode;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when blockset is updated
    event BlocksetAssigned(IAddressSet indexed blockset);

    /// @notice Emitted when access mode is changed
    event AccessModeSet(AccessMode indexed mode);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initializes the RegenEarningPowerCalculator with access control configuration
     * @dev Sets all address sets and access mode during deployment
     *      NOTE: AccessMode determines which address set is active, not address(0) checks
     * @param _owner Address that will own this contract
     * @param _allowset Allowset contract address (active in ALLOWSET mode)
     * @param _blockset Blockset contract address (active in BLOCKSET mode)
     * @param _accessMode Initial access mode (NONE, ALLOWSET, or BLOCKSET)
     */
    constructor(address _owner, IAddressSet _allowset, IAddressSet _blockset, AccessMode _accessMode) Ownable(_owner) {
        allowset = _allowset;
        blockset = _blockset;
        accessMode = _accessMode;
        emit AllowsetAssigned(_allowset);
        emit BlocksetAssigned(_blockset);
        emit AccessModeSet(_accessMode);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Check if staker has access based on current access mode
     * @dev Internal helper to centralize access control logic
     *
     *      ACCESS LOGIC:
     *      - NONE: Always returns true
     *      - ALLOWSET: Returns allowset.contains(staker)
     *      - BLOCKSET: Returns !blockset.contains(staker)
     * @param staker Address to check
     * @return hasAccess True if staker has access to earn rewards
     */
    function _hasAccess(address staker) internal view returns (bool hasAccess) {
        if (accessMode == AccessMode.ALLOWSET) {
            return allowset.contains(staker);
        } else if (accessMode == AccessMode.BLOCKSET) {
            return !blockset.contains(staker);
        }
        return true;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Returns the earning power of a staker
     * @dev Earning power = staked amount (capped at uint96 max) if has access, else 0
     *
     *      FORMULA:
     *      - Has access: min(stakedAmount, type(uint96).max)
     *      - No access: 0
     * @param stakedAmount Amount of staked tokens in token base units
     * @param staker Address of staker
     * @return earningPower Calculated earning power (0 if no access)
     */
    function getEarningPower(
        uint256 stakedAmount,
        address staker,
        address /*_delegatee*/
    ) external view override returns (uint256 earningPower) {
        if (!_hasAccess(staker)) {
            return 0;
        }
        return Math.min(stakedAmount, uint256(type(uint96).max));
    }

    /**
     * @notice Returns the new earning power and bump qualification status
     * @dev Calculates new earning power based on access control and staked amount
     *      A staker qualifies for a bump whenever their earning power changes
     *
     *      BUMP QUALIFICATION CONDITIONS:
     *      - Access status changed (added/removed from set)
     *      - Staked amount changed
     *      - Any change where: newEarningPower ≠ oldEarningPower
     *
     *      This ensures deposits are updated promptly when access status changes.
     * @param stakedAmount Amount of staked tokens in token base units
     * @param staker Address of staker
     * @param oldEarningPower Previous earning power value
     * @return newCalculatedEarningPower New earning power (0 if no access)
     * @return qualifiesForBump True if earning power changed
     */
    function getNewEarningPower(
        uint256 stakedAmount,
        address staker,
        address, // _delegatee - unused
        uint256 oldEarningPower
    ) external view override returns (uint256 newCalculatedEarningPower, bool qualifiesForBump) {
        if (!_hasAccess(staker)) {
            newCalculatedEarningPower = 0;
        } else {
            newCalculatedEarningPower = Math.min(stakedAmount, uint256(type(uint96).max));
        }

        qualifiesForBump = newCalculatedEarningPower != oldEarningPower;
    }

    /**
     * @notice Sets the allowset for the earning power calculator (ALLOWSET mode)
     * @dev Only callable by owner. Use setAccessMode(AccessMode.NONE) to disable access control
     * @param _allowset Allowset contract address to set
     * @custom:security Only owner can modify access control
     */
    function setAllowset(IAddressSet _allowset) public override onlyOwner {
        allowset = _allowset;
        emit AllowsetAssigned(_allowset);
    }

    /**
     * @notice Sets the blockset for the earning power calculator (BLOCKSET mode)
     * @dev Only callable by owner. Use setAccessMode(AccessMode.NONE) to disable access control
     * @param _blockset Blockset contract address to set
     * @custom:security Only owner can modify access control
     */
    function setBlockset(IAddressSet _blockset) public onlyOwner {
        blockset = _blockset;
        emit BlocksetAssigned(_blockset);
    }

    /**
     * @notice Sets the access mode for the earning power calculator
     * @dev Non-retroactive. Existing deposits require bumpEarningPower() to reflect changes
     *      Only callable by owner
     * @param _mode Access mode to set (NONE, ALLOWSET, or BLOCKSET)
     * @custom:security Only owner can change access mode
     * @custom:security Non-retroactive - requires manual bumping to apply to existing deposits
     */
    function setAccessMode(AccessMode _mode) public onlyOwner {
        accessMode = _mode;
        emit AccessModeSet(_mode);
    }

    /**
     * @notice Checks interface support including IAccessControlledEarningPowerCalculator
     * @param interfaceId Interface identifier to check
     * @return supported True if interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool supported) {
        return
            interfaceId == type(IAccessControlledEarningPowerCalculator).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
