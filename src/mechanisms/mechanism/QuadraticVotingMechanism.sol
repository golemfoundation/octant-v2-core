// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { BaseAllocationMechanism, AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Quadratic Voting Mechanism
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Implements quadratic funding using ProperQF algorithm
 * @dev Follows Yearn V3 proxy pattern with ProperQF voting strategy
 *
 *      QUADRATIC FUNDING:
 *      ═══════════════════════════════════
 *      - Cost of voting is quadratic: weight votes costs weight² power
 *      - Prevents whale dominance (expensive to cast many votes)
 *      - Benefits: Small contributors have proportionally more impact
 *
 *      VOTE COST EXAMPLES:
 *      - 10 votes costs 100 voting power (10²)
 *      - 20 votes costs 400 voting power (20²)
 *      - 100 votes costs 10,000 voting power (100²)
 *
 *      ONE-TIME VOTING:
 *      ⚠️  Users can only vote ONCE per proposal
 *      - Vote is final and cannot be changed
 *      - Cannot increase, decrease, or cancel vote
 *      - Additional deposits create new voting power for other proposals
 *      - UI must warn users before voting
 *
 *      VOTING POWER:
 *      - Normalized to 18 decimals regardless of asset decimals
 *      - Linear relationship: 1 asset = 1 voting power (after normalization)
 *      - Each deposit adds to cumulative voting power
 *
 * @custom:security One-time voting prevents manipulation via vote adjustments
 * @custom:security Quadratic cost reduces whale influence
 */
contract QuadraticVotingMechanism is BaseAllocationMechanism, ProperQF {
    // ============================================
    // ERRORS
    // ============================================
    error ZeroAddressCannotPropose();
    error OnlyForVotesSupported();
    error InsufficientVotingPowerForQuadraticCost();

    error AlreadyVoted(address voter, uint256 pid);

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Tracks whether a voter has voted on a specific proposal
    /// @dev Maps pid → voter → hasVoted (prevents double voting)
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /**
     * @notice Initialize QuadraticVotingMechanism with configuration and alpha parameters
     * @dev Called by AllocationMechanismFactory during CREATE2 deployment
     *      Sets up ProperQF algorithm with specified alpha weighting
     * @param _implementation Address of shared TokenizedAllocationMechanism implementation
     * @param _config Configuration struct with mechanism parameters
     * @param _alphaNumerator Alpha numerator (dimensionless ratio, 0 to _alphaDenominator)
     * @param _alphaDenominator Alpha denominator (dimensionless ratio, must be > 0)
     */
    constructor(
        address _implementation,
        AllocationConfig memory _config,
        uint256 _alphaNumerator,
        uint256 _alphaDenominator
    ) BaseAllocationMechanism(_implementation, _config) {
        _setAlpha(_alphaNumerator, _alphaDenominator);
    }

    /**
     * @notice Hook to validate proposer authorization
     * @dev Only keeper or management addresses can create proposals
     *      Prevents spam and maintains curation quality
     * @param proposer Address attempting to create proposal
     * @return authorized True if proposer is keeper or management
     */
    function _beforeProposeHook(address proposer) internal view virtual override returns (bool) {
        if (proposer == address(0)) revert ZeroAddressCannotPropose();

        // Get keeper and management addresses from TokenizedAllocationMechanism
        address keeper = _tokenizedAllocation().keeper();
        address management = _tokenizedAllocation().management();

        // Allow if proposer is either keeper or management
        return proposer == keeper || proposer == management;
    }

    /**
     * @notice Hook to validate proposal exists
     * @param pid Proposal ID to validate
     * @return valid True if proposal exists
     */
    function _validateProposalHook(uint256 pid) internal view virtual override returns (bool) {
        return _proposalExists(pid);
    }

    /**
     * @notice Hook to authorize user registration
     * @dev Allows all users to register, including multiple signups
     *      Each signup adds voting power that can be used on un-voted proposals
     *
     *      IMPORTANT DESIGN CONSIDERATION:
     *      Pure quadratic voting (QV) should restrict to single signups to prevent
     *      double-spending of vote credits. However, quadratic funding (QF) variants
     *      allow multiple signups where users contribute their own funds to increase
     *      voting power. Derived contracts can override to enforce single-signup.
     * @return authorized True (all users can signup)
     */
    function _beforeSignupHook(address) internal virtual override returns (bool) {
        return true;
    }

    /**
     * @notice Hook to calculate voting power from deposit amount
     * @dev Normalizes asset amount to 18 decimals for consistent voting power
     *      1 token (in asset decimals) = 1 voting power (in 18 decimals)
     *
     *      NORMALIZATION EXAMPLES:
     *      - USDC (6 decimals): 1,000,000 (1 USDC) → 1e18 voting power
     *      - WETH (18 decimals): 1e18 (1 WETH) → 1e18 voting power
     *      - WBTC (8 decimals): 100,000,000 (1 WBTC) → 1e18 voting power
     * @param deposit Amount deposited in asset's native decimals
     * @return votingPower Normalized voting power in 18 decimals
     */
    function _getVotingPowerHook(
        address,
        uint256 deposit
    ) internal view virtual override returns (uint256 votingPower) {
        // Get asset decimals
        uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();

        // Convert to 18 decimals for voting power
        if (assetDecimals == 18) {
            return deposit;
        } else if (assetDecimals < 18) {
            // Scale up: multiply by 10^(18 - assetDecimals)
            uint256 scaleFactor = 10 ** (18 - assetDecimals);
            return deposit * scaleFactor;
        } else {
            // Scale down: divide by 10^(assetDecimals - 18)
            uint256 scaleFactor = 10 ** (assetDecimals - 18);
            return deposit / scaleFactor;
        }
    }

    /**
     * @notice Internal helper to normalize token amount to 18 decimals
     * @dev Matches voting power normalization logic in _getVotingPowerHook
     * @param amount Token amount in asset's native decimals
     * @param assetDecimals Decimal places of the asset token
     * @return normalized Amount normalized to 18 decimals
     */
    function _normalizeToDecimals(uint256 amount, uint8 assetDecimals) internal pure returns (uint256 normalized) {
        if (assetDecimals == 18) {
            return amount;
        } else if (assetDecimals < 18) {
            // Scale up: multiply by 10^(18 - assetDecimals)
            uint256 scaleFactor = 10 ** (18 - assetDecimals);
            return amount * scaleFactor;
        } else {
            // Scale down: divide by 10^(assetDecimals - 18)
            uint256 scaleFactor = 10 ** (assetDecimals - 18);
            return amount / scaleFactor;
        }
    }

    /**
     * @notice Hook to process vote with quadratic cost and single-vote enforcement
     * @dev Implements quadratic voting: to cast W votes, you pay W² voting power
     *      Each voter can only vote ONCE per proposal (no adjustments)
     *
     *      QUADRATIC COST FORMULA:
     *      cost = weight × weight
     *
     *      EXAMPLES:
     *      - Cast 10 votes → costs 100 voting power
     *      - Cast 50 votes → costs 2,500 voting power
     *      - Cast 100 votes → costs 10,000 voting power
     *
     *      This makes whale attacks expensive while giving smaller voters
     *      proportionally more influence per token.
     * @param pid Proposal ID to vote on
     * @param voter Address casting the vote
     * @param choice Vote type (must be VoteType.For)
     * @param weight Number of votes to cast (dimensionless)
     * @param oldPower Voter's current voting power (in 18 decimals)
     * @return newPower Remaining voting power after quadratic cost deduction (in 18 decimals)
     * @custom:security Single-vote enforcement prevents manipulation via vote adjustments
     * @custom:security Reverts if voter already voted on this proposal
     */
    function _processVoteHook(
        uint256 pid,
        address voter,
        TokenizedAllocationMechanism.VoteType choice,
        uint256 weight,
        uint256 oldPower
    ) internal virtual override returns (uint256) {
        if (choice != TokenizedAllocationMechanism.VoteType.For) revert OnlyForVotesSupported();

        // Check if voter has already voted on this proposal
        if (hasVoted[pid][voter]) revert AlreadyVoted(voter, pid);

        // Quadratic cost: to vote with weight W, you pay W^2 voting power
        uint256 quadraticCost = weight * weight;

        if (quadraticCost > oldPower) revert InsufficientVotingPowerForQuadraticCost();

        // Use ProperQF's unchecked vote processing since we control the inputs
        // contribution = quadratic cost, voteWeight = actual vote weight
        // We know: quadraticCost = weight^2, so sqrt(quadraticCost) = weight (perfect square root relationship)
        _processVoteUnchecked(pid, quadraticCost, weight);

        // Mark that voter has voted on this proposal
        hasVoted[pid][voter] = true;

        // Return remaining voting power after quadratic cost
        return oldPower - quadraticCost;
    }

    /**
     * @notice Hook to check if proposal meets quorum threshold
     * @dev Quorum based on total funding (quadratic + linear components)
     *      Uses ProperQF formula: F_j = α×(sum_sqrt)² + (1-α)×sum_contributions
     * @param pid Proposal ID to check
     * @return meetsQuorum True if project funding ≥ quorum threshold
     */
    function _hasQuorumHook(uint256 pid) internal view virtual override returns (bool meetsQuorum) {
        // Get the project's funding metrics
        // getTally() returns: alpha-weighted quadratic funding + alpha-weighted linear funding
        (, , uint256 quadraticFunding, uint256 linearFunding) = getTally(pid);

        // Calculate total funding: both components are already alpha-weighted
        // F_j = α × (sum_sqrt)² + (1-α) × sum_contributions
        uint256 projectTotalFunding = quadraticFunding + linearFunding;

        // Project meets quorum if it has minimum funding threshold
        return projectTotalFunding >= _getQuorumShares();
    }

    /**
     * @notice Hook to convert proposal funding into allocation shares
     * @dev Returns total funding amount (quadratic + linear components)
     *      Both components are already alpha-weighted by ProperQF
     * @param pid Proposal ID
     * @return shares Total funding to allocate in share base units
     */
    function _convertVotesToShares(uint256 pid) internal view virtual override returns (uint256 shares) {
        // Get project funding metrics
        // getTally() returns: alpha-weighted quadratic funding + alpha-weighted linear funding
        (, , uint256 quadraticFunding, uint256 linearFunding) = getTally(pid);

        // Calculate total funding: both components are already alpha-weighted
        // F_j = α × (sum_sqrt)² + (1-α) × sum_contributions
        return quadraticFunding + linearFunding;
    }

    /// @notice Allow finalization once voting period ends
    function _beforeFinalizeVoteTallyHook() internal pure virtual override returns (bool) {
        return true;
    }

    /// @notice Get recipient address for proposal
    function _getRecipientAddressHook(uint256 pid) internal view virtual override returns (address) {
        TokenizedAllocationMechanism.Proposal memory proposal = _getProposal(pid);
        if (proposal.recipient == address(0)) revert TokenizedAllocationMechanism.InvalidRecipient(proposal.recipient);
        return proposal.recipient;
    }

    /// @notice Handle custom share distribution - returns false to use default minting
    /// @return handled False to indicate default minting should be used
    /// @return assetsTransferred 0 since no custom distribution is performed
    function _requestCustomDistributionHook(
        address,
        uint256
    ) internal pure virtual override returns (bool handled, uint256 assetsTransferred) {
        // Return false to indicate we want to use the default share minting in TokenizedAllocationMechanism
        // This allows the base implementation to handle the minting via _mint()
        return (false, 0);
    }

    // Note: _availableWithdrawLimit is now inherited from BaseAllocationMechanism
    // The default implementation enforces timelock and grace period boundaries

    /// @notice Calculate total assets including matching pool + user deposits for finalization
    /// @dev This snapshots the total asset balance in the contract during finalize
    /// @return Total assets available for allocation (matching pool + user signup deposits)
    function _calculateTotalAssetsHook() internal view virtual override returns (uint256) {
        // Return current asset balance of the contract
        // This includes both:
        // 1. Matching pool funds (pre-funded in setUp)
        // 2. User deposits from signups
        return asset.balanceOf(address(this));
    }

    /// @notice Get project funding breakdown for a proposal
    /// @param pid Proposal ID
    /// @return sumContributions Total contribution amounts
    /// @return sumSquareRoots Sum of square roots for quadratic calculation
    /// @return quadraticFunding Quadratic funding component
    /// @return linearFunding Linear funding component
    function getProposalFunding(
        uint256 pid
    )
        external
        view
        returns (uint256 sumContributions, uint256 sumSquareRoots, uint256 quadraticFunding, uint256 linearFunding)
    {
        if (!_validateProposalHook(pid)) revert TokenizedAllocationMechanism.InvalidProposal(pid);

        // Return zero funding for cancelled proposals
        if (_tokenizedAllocation().state(pid) == TokenizedAllocationMechanism.ProposalState.Canceled) {
            return (0, 0, 0, 0);
        }

        return getTally(pid);
    }

    /// @notice Set the alpha parameter for quadratic vs linear funding weighting
    /// @param newNumerator Numerator of new alpha value (dimensionless ratio)
    /// @param newDenominator Denominator of new alpha value (dimensionless ratio)
    /// @dev Alpha determines the ratio: F_j = α × (sum_sqrt)² + (1-α) × sum_contributions
    /// @dev Only callable by owner (inherited from BaseAllocationMechanism via TokenizedAllocationMechanism)
    function setAlpha(uint256 newNumerator, uint256 newDenominator) external {
        // Access control: only owner can modify alpha
        require(_tokenizedAllocation().owner() == msg.sender, "Only owner can set alpha");

        // Update alpha using ProperQF's internal function (validates constraints internally)
        _setAlpha(newNumerator, newDenominator);
    }

    /// @notice Calculate optimal alpha for 1:1 shares-to-assets ratio given fixed matching pool amount
    /// @param matchingPoolAmount Fixed amount of matching funds available (in token's native decimals)
    /// @param totalUserDeposits Total user deposits in the mechanism (in token's native decimals)
    /// @return optimalAlphaNumerator Calculated alpha numerator
    /// @return optimalAlphaDenominator Calculated alpha denominator
    /// @dev Internally normalizes amounts to 18 decimals to match quadratic/linear sum calculations
    function calculateOptimalAlpha(
        uint256 matchingPoolAmount,
        uint256 totalUserDeposits
    ) external view returns (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) {
        // Get asset decimals to normalize amounts
        uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();

        // Normalize both amounts to 18 decimals to match quadratic/linear sums
        uint256 normalizedMatchingPool = _normalizeToDecimals(matchingPoolAmount, assetDecimals);
        uint256 normalizedUserDeposits = _normalizeToDecimals(totalUserDeposits, assetDecimals);

        return
            _calculateOptimalAlpha(
                normalizedMatchingPool,
                totalQuadraticSum(),
                totalLinearSum(),
                normalizedUserDeposits
            );
    }

    /**
     * @notice Reject ETH deposits to prevent permanent fund loss
     * @dev Overrides BaseAllocationMechanism's receive() function
     *      This mechanism only supports ERC20 tokens, not native ETH
     * @custom:security Prevents accidental ETH loss
     */
    receive() external payable override {
        revert("ETH not supported - use ERC20 tokens only");
    }
}
