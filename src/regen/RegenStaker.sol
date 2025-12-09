// SPDX-License-Identifier: AGPL-3.0-only
// This contract inherits from Staker.sol by [ScopeLift](https://scopelift.co)
// Staker.sol is licensed under AGPL-3.0-only.
// Users of this should ensure compliance with the AGPL-3.0-only license terms of the inherited Staker.sol contract.

pragma solidity ^0.8.0;

// === Variant-Specific Imports ===
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { DelegationSurrogateVotes } from "staker/DelegationSurrogateVotes.sol";
import { IERC20Delegates } from "staker/interfaces/IERC20Delegates.sol";

// === Base Imports ===
import { RegenStakerBase, Staker, SafeERC20, IERC20, DelegationSurrogate, IAddressSet, IEarningPowerCalculator } from "src/regen/RegenStakerBase.sol";
import { AccessMode } from "src/constants.sol";

// === Contract Header ===
/**
 * @title RegenStaker
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Staking contract with voting delegation support via surrogates
 * @dev Extends RegenStakerBase to support IERC20Staking tokens with voting/delegation capabilities
 *
 *      VARIANT COMPARISON:
 *      ═══════════════════════════════════
 *      ┌──────────────────────────────┬──────────────┬─────────────────────────┐
 *      │ Feature                      │ RegenStaker  │ Without Surrogate       │
 *      ├──────────────────────────────┼──────────────┼─────────────────────────┤
 *      │ Delegation Support           │ ✓ Full       │ ✗ None                  │
 *      │ Surrogate Pattern            │ ✓ Per User   │ ✗ Contract = Surrogate  │
 *      │ Token Custody                │ Surrogates   │ Contract Directly       │
 *      │ Voting Power                 │ ✓ Delegated  │ ✗ Locked in Contract    │
 *      │ Gas (First Delegatee)        │ ~300k        │ ~100k                   │
 *      │ Gas (Subsequent)             │ ~100k        │ ~100k                   │
 *      │ Complexity                   │ Higher       │ Lower                   │
 *      │ Use Case                     │ Governance   │ Simple Staking          │
 *      └──────────────────────────────┴──────────────┴─────────────────────────┘
 *
 *      DELEGATION MECHANISM:
 *      ═══════════════════════════════════
 *      1. User stakes tokens and specifies delegatee
 *      2. Contract deploys/fetches DelegationSurrogateVotes for that delegatee
 *      3. Tokens transferred to surrogate (not main contract)
 *      4. Surrogate automatically delegates voting power to delegatee
 *      5. Delegatee can use voting power in governance
 *      6. On unstake, tokens withdrawn from surrogate back to user
 *
 *      SURROGATE PATTERN:
 *      - One surrogate per delegatee (not per user)
 *      - Deployed on-demand via CREATE2 (deterministic addresses)
 *      - Surrogates are simple: hold tokens, delegate votes
 *      - Multiple users can share same surrogate (same delegatee)
 *
 *      GAS CONSIDERATIONS:
 *      - First use of delegatee: ~250k-350k gas (deploys surrogate)
 *      - Subsequent uses: ~100k gas (reuses existing surrogate)
 *      - Pre-deploy surrogates for common delegatees during low gas
 *
 *      WHEN TO USE:
 *      - Token: IERC20Staking (ERC20 + staking + delegation)
 *      - Need: Users want to delegate voting power while staked
 *      - Example: GLM token staking with governance delegation
 *
 *      WHEN NOT TO USE:
 *      - Token: Simple ERC20 (no voting)
 *      - Don't need delegation
 *      - Want to minimize gas costs
 *      → Use RegenStakerWithoutDelegateSurrogateVotes instead
 *
 *      SECURITY:
 *      - Surrogates deployed via CREATE2 (deterministic, verifiable)
 *      - Surrogates cannot be controlled by delegatee (just delegation target)
 *      - Tokens safe in surrogates (only contract can withdraw)
 *
 * @custom:security Surrogates deployed deterministically via CREATE2
 * @custom:origin https://github.com/ScopeLift/flexible-voting/blob/master/src/Staker.sol
 */
contract RegenStaker is RegenStakerBase {
    using SafeERC20 for IERC20;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Mapping of delegatee addresses to their surrogate contracts
    /// @dev One surrogate per delegatee, shared by all users delegating to that address
    mapping(address => DelegationSurrogate) private _surrogates;

    /// @notice The voting token interface for delegation operations
    /// @dev Immutable reference to the staking token with voting capabilities
    IERC20Delegates public immutable VOTING_TOKEN;

    // === Constructor ===
    /// @notice Constructor for the RegenStaker contract.
    /// @param _rewardsToken Token used to reward contributors
    /// @param _stakeToken Token used for staking (must implement IERC20Staking and IERC20Permit)
    /// @param _earningPowerCalculator Earning power calculator address
    /// @param _maxBumpTip Maximum bump tip in reward token base units
    /// @param _admin Admin address (TRUSTED)
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
        IERC20Staking _stakeToken,
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
            IERC20(address(_stakeToken)),
            _earningPowerCalculator,
            _maxBumpTip,
            _admin,
            _rewardDuration,
            _minimumStakeAmount,
            _stakerAllowset,
            _stakerBlockset,
            _stakerAccessMode,
            _allocationMechanismAllowset,
            "RegenStaker"
        )
    {
        VOTING_TOKEN = IERC20Delegates(address(_stakeToken));
    }

    // === Events ===
    /// @notice Emitted when a new delegation surrogate is deployed
    /// @param delegatee Address that receives voting power
    /// @param surrogate Address of deployed surrogate contract
    event SurrogateDeployed(address indexed delegatee, address indexed surrogate);

    // === Overridden Functions ===

    function surrogates(address _delegatee) public view override returns (DelegationSurrogate) {
        return _surrogates[_delegatee];
    }

    /**
     * @notice Predicts the deterministic address of a surrogate for a delegatee
     * @dev Uses CREATE2 address calculation (EIP-1014)
     *      Formula: address = last 20 bytes of keccak256(0xff ++ deployer ++ salt ++ initCodeHash)
     *
     *      COMPONENTS:
     *      - deployer: address(this) (RegenStaker contract)
     *      - salt: keccak256(delegatee address)
     *      - initCodeHash: keccak256(DelegationSurrogateVotes creation code + constructor args)
     *
     *      USE CASES:
     *      - Predict address before deployment
     *      - Verify surrogate addresses off-chain
     *      - Pre-fund surrogates before first use
     *
     * @param _delegatee Address that will receive delegated voting power
     * @return predicted Predicted address of the surrogate contract
     */
    function predictSurrogateAddress(address _delegatee) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_delegatee));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(DelegationSurrogateVotes).creationCode, abi.encode(VOTING_TOKEN, _delegatee))
        );

        // EIP-1014: 0xff domain separator
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }

    /**
     * @notice Returns the delegatee that a surrogate delegates to
     * @dev Queries the voting token to check delegation
     *      Returns address(0) if surrogate is invalid or doesn't delegate
     * @param _surrogate Surrogate contract address to query
     * @return delegatee Address receiving the voting power (or address(0))
     */
    function getDelegateeFromSurrogate(address _surrogate) external view returns (address) {
        return VOTING_TOKEN.delegates(_surrogate);
    }

    /**
     * @notice Fetches existing surrogate or deploys new one for a delegatee
     * @dev Core function handling surrogate lifecycle
     *
     *      FLOW:
     *      1. Check if surrogate exists for delegatee
     *      2. If exists: Return existing (cheap, ~5k gas)
     *      3. If not: Deploy new surrogate via CREATE2 (~300k gas)
     *      4. Store surrogate in mapping
     *      5. Emit SurrogateDeployed event
     *
     *      GAS COSTS:
     *      - First use (deploy): ~250k-350k gas
     *      - Subsequent uses (fetch): ~5k gas (SLOAD)
     *
     *      OPTIMIZATION:
     *      Pre-deploy surrogates for common delegatees during low gas periods:
     *      ```solidity
     *      // Off-peak gas optimization
     *      regenStaker._fetchOrDeploySurrogate(popularDelegatee);
     *      ```
     *
     *      CREATE2 BENEFITS:
     *      - Deterministic addresses (can predict before deploy)
     *      - Prevents duplicate surrogates for same delegatee
     *      - Verifiable off-chain
     *
     * @param _delegatee Address that will receive voting power
     * @return _surrogate Address of surrogate contract (existing or newly deployed)
     */
    function _fetchOrDeploySurrogate(address _delegatee) internal override returns (DelegationSurrogate _surrogate) {
        // Check if surrogate already exists
        _surrogate = _surrogates[_delegatee];

        if (address(_surrogate) == address(0)) {
            // Deploy new surrogate via CREATE2
            // Salt = hash of delegatee for deterministic addresses
            // Surrogate constructor automatically delegates to _delegatee
            _surrogate = new DelegationSurrogateVotes{ salt: keccak256(abi.encodePacked(_delegatee)) }(
                VOTING_TOKEN,
                _delegatee
            );

            // Store for future lookups
            _surrogates[_delegatee] = _surrogate;

            emit SurrogateDeployed(_delegatee, address(_surrogate));
        }
        // If exists, return cached surrogate (gas efficient)
    }
}
