// SPDX-License-Identifier: AGPL-3.0-only
// This contract inherits from Staker.sol by [ScopeLift](https://scopelift.co)
// Staker.sol is licensed under AGPL-3.0-only.
// Users of this should ensure compliance with the AGPL-3.0-only license terms of the inherited Staker.sol contract.

pragma solidity ^0.8.0;

// === Base Imports ===

import { RegenStakerBase, Staker, IERC20, DelegationSurrogate, IAddressSet, IEarningPowerCalculator } from "src/regen/RegenStakerBase.sol";
import { AccessMode } from "src/constants.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// === Contract Header ===
/// @title RegenStakerWithoutDelegateSurrogateVotes
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
/// @notice Variant of RegenStakerBase for regular ERC20 tokens without delegation support.
/// @custom:origin https://github.com/ScopeLift/flexible-voting/blob/master/src/Staker.sol
/// @dev Eliminates surrogate pattern; tokens are held directly by this contract.
/// @dev DELEGATION LIMITATION: Delegatee is tracked for compatibility but has no effect on token delegation.
///
/// @dev VARIANT COMPARISON: (See RegenStaker.sol for the delegation variant)
/// ┌─────────────────────────────────────┬─────────────────┬──────────────────────────────────┐
/// │ Feature                             │ RegenStaker     │ RegenStakerWithoutDelegateSurro… │
/// ├─────────────────────────────────────┼─────────────────┼──────────────────────────────────┤
/// │ Delegation Support                  │ ✓ Full Support  │ ✗ No Support                     │
/// │ Surrogate Deployment                │ ✓ Per Delegatee │ ✗ Contract as Surrogate          │
/// │ Token Holder                        │ Surrogates      │ Contract Directly                │
/// │ Voting Capability                   │ ✓ via Surrogate │ ✗ Not Available                  │
/// │ Gas Cost (First Delegatee)          │ Higher          │ Lower                            │
/// │ Integration Complexity              │ Higher          │ Lower                            │
/// └─────────────────────────────────────┴─────────────────┴──────────────────────────────────┘
///
/// @dev VARIANT COMPARISON: See RegenStaker.sol for detailed comparison table.
///
/// @dev KEY DIFFERENCES FROM RegenStaker:
/// - No delegation support: delegatee parameter is informational only
/// - Lower gas costs: no surrogate contract deployment
/// - Simpler integration: contract holds tokens directly
/// - No voting capabilities through delegation
/// - Same security model: both variants use owner-centric allowset authorization
///
/// @dev USE CASE: Choose this variant for simple ERC20 staking without governance requirements.
contract RegenStakerWithoutDelegateSurrogateVotes is RegenStakerBase {
    // === Custom Errors ===
    error DelegationNotSupported();

    // === Constructor ===
    /// @notice Constructor for the RegenStakerWithoutDelegateSurrogateVotes contract.
    /// @param _rewardsToken Token distributed as staking rewards
    /// @param _stakeToken ERC20 token users stake (must implement IERC20Permit)
    /// @param _earningPowerCalculator Contract calculating earning power from stakes
    /// @param _maxBumpTip Maximum tip for earning power bumps in reward token base units
    /// @param _admin Address with admin permissions (TRUSTED)
    /// @param _rewardDuration Duration for reward distribution in seconds
    /// @param _minimumStakeAmount Minimum stake required in stake token base units
    /// @param _stakerAllowset Allowset for ALLOWSET mode (can be address(0))
    /// @param _stakerBlockset Blockset for BLOCKSET mode (can be address(0))
    /// @param _stakerAccessMode Staker access mode (NONE, ALLOWSET, or BLOCKSET)
    /// @param _allocationMechanismAllowset Allowset of approved allocation mechanisms (SECURITY CRITICAL)
    ///      Only audited and trusted allocation mechanisms should be in the allowset.
    ///      Users contribute funds to these mechanisms and may lose funds if mechanisms are malicious.
    constructor(
        IERC20 _rewardsToken,
        IERC20 _stakeToken,
        IEarningPowerCalculator _earningPowerCalculator,
        uint256 _maxBumpTip,
        address _admin,
        uint128 _rewardDuration,
        uint128 _minimumStakeAmount,
        IAddressSet _stakerAllowset,
        IAddressSet _stakerBlockset,
        AccessMode _stakerAccessMode,
        IAddressSet _allocationMechanismAllowset
    )
        RegenStakerBase(
            _rewardsToken,
            _stakeToken,
            _earningPowerCalculator,
            _maxBumpTip,
            _admin,
            _rewardDuration,
            _minimumStakeAmount,
            _stakerAllowset,
            _stakerBlockset,
            _stakerAccessMode,
            _allocationMechanismAllowset,
            "RegenStakerWithoutDelegateSurrogateVotes"
        )
    {}

    // === Overridden Functions ===

    /// @notice Validates sufficient reward token balance and returns the required balance for this variant
    /// @dev Overrides base to include totalStaked for same-token scenarios since stakes are held in main contract
    /// @param _amount Reward amount being added in reward token base units
    /// @return required Required balance including appropriate obligations
    function _validateAndGetRequiredBalance(uint256 _amount) internal view override returns (uint256 required) {
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));
        uint256 carryOverAmount = totalRewards - totalClaimedRewards;

        if (address(REWARD_TOKEN) == address(STAKE_TOKEN)) {
            // Same-token scenario: stakes ARE in main contract, so include totalStaked
            // Accounting: totalStaked + totalRewards - totalClaimedRewards + newAmount
            required = totalStaked + carryOverAmount + _amount;
        } else {
            // Different-token scenario: stakes are separate, only track reward obligations
            // Accounting: totalRewards - totalClaimedRewards + newAmount
            required = carryOverAmount + _amount;
        }

        if (currentBalance < required) {
            revert InsufficientRewardBalance(currentBalance, required);
        }

        return required;
    }

    /// @notice Returns this contract as the "surrogate" since we hold tokens directly
    /// @dev ARCHITECTURE: This variant uses address(this) as surrogate to eliminate delegation complexity
    ///      while maintaining compatibility with base Staker contract logic. This allows reuse of all
    ///      base functionality without deploying separate surrogate contracts.
    /// @dev WARNING: Deviates from standard surrogate pattern. Always returns address(this).
    ///      Integrators expecting separate surrogate contracts will fail. Do not assume external
    ///      surrogate contracts exist when integrating with this variant.
    function surrogates(address /* _delegatee */) public view override returns (DelegationSurrogate) {
        return DelegationSurrogate(address(this));
    }

    /// @notice Returns this contract as the "surrogate" - no separate contracts needed
    /// @dev SIMPLIFICATION: Eliminates need for complex token transfer overrides
    function _fetchOrDeploySurrogate(address /* _delegatee */) internal view override returns (DelegationSurrogate) {
        return DelegationSurrogate(address(this));
    }

    /// @notice Override to support withdrawals when this contract acts as its own surrogate
    /// @dev Since this contract uses address(this) as surrogate, use safeTransfer for contract-to-user paths.
    function _stakeTokenSafeTransferFrom(address _from, address _to, uint256 _value) internal override {
        // Use safeTransfer for withdrawals (contract -> user)
        if (_from == address(this)) {
            SafeERC20.safeTransfer(STAKE_TOKEN, _to, _value);
            return;
        }

        // Default behavior for deposits (user -> contract)
        super._stakeTokenSafeTransferFrom(_from, _to, _value);
    }

    /// @notice Delegation changes are not supported in this variant
    /// @dev Always reverts since this contract doesn't use delegation surrogates - always uses address(this)
    /// @dev Both alterDelegatee() and alterDelegateeOnBehalf() call this internal function
    function _alterDelegatee(Deposit storage, DepositIdentifier, address) internal pure override {
        revert DelegationNotSupported();
    }
}
