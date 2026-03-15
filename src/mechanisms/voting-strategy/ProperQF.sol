// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Quant, UintQuantizationLib as QuantLib } from "uint-quantization-lib/src/UintQuantizationLib.sol";

/**
 * @title Proper Quadratic Funding (QF) math and tallying
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Incremental QF tallying utilities with alpha-weighted quadratic/linear funding.
 * @dev Provides storage isolation via deterministic slot, input validation helpers,
 *      and funding aggregation with well-defined rounding behavior.
 *
 *      Storage packing: each project occupies exactly 1 slot (256 bits):
 *        sumContributions : uint128, shift=32 (lossy quantization via UintQuantizationLib)
 *        sumSquareRoots   : uint128, shift=0  (lossless, no quantization)
 *
 *      sumContributions quantization (CONTRIBUTIONS_SCHEME):
 *        encode: stored = value >> 32  (floors to nearest step)
 *        decode: value  = stored << 32
 *        step   = 2^32 = 4,294,967,296 wei (~4.3 nanotoken at 18 decimals)
 *        max    = (2^128 - 1) << 32    (~1.46e48 wei = ~1.46e30 tokens at 18 decimals)
 *
 *        Contribution values entering ProperQF are quadratic costs (weight^2) in the
 *        18-decimal-normalized voting-power space (see QuadraticVotingMechanism
 *        ._normalizeToDecimals). Since voting power is always normalized to 18 decimals
 *        regardless of the underlying asset, the step size of ~4.3 nanotoken applies
 *        uniformly. Minimum contribution >= stepSize (2^32), enforced by the
 *        BelowMinStep guard (from UintQuantizationLib) in _processVoteUnchecked.
 *        Minimum weight = sqrt(step) = 2^16 = 65536, enforced upstream by
 *        QuadraticVotingMechanism (weight >= MIN_VOTE_WEIGHT, weight % MIN_VOTE_WEIGHT == 0).
 *
 *        Per-project sumContributions readback is lossy (floored to step boundary).
 *        Global totalLinearSum stays exact: the delta update pattern in
 *        _processVoteUnchecked computes (old - decoded + (decoded + contribution)),
 *        so the quantization errors cancel.
 *
 *      sumSquareRoots: stored as uint128, no quantization.
 *        The uint128 ceiling matches the arithmetic constraint: sumSquareRoots is
 *        squared on-chain (sumSR * sumSR), which overflows uint256 at 2^128.
 *        Overflow protection comes from Solidity 0.8's checked uint128() downcast
 *        in _writeProject (defense-in-depth; the squaring catches it first).
 */
abstract contract ProperQF {
    using Math for uint256;

    /// @notice Quantization scheme for sumContributions: stored as uint128, shift=32.
    /// @dev Contributions are quadratic costs (weight^2) in 18-decimal-normalized voting-power
    ///      space (see QuadraticVotingMechanism._normalizeToDecimals), so these bounds hold
    ///      uniformly regardless of the underlying asset's native decimals.
    ///      Step size: 2^32 ~= 4.3e9 wei (~4.3 nanotoken) : floor-rounding error per encode.
    ///      Max value: (2^128 - 1) << 32 ~= 1.46e48 wei (~1.46e30 tokens).
    ///      Global sums (totalLinearSum) stay exact because quantization errors cancel in the
    ///      delta update pattern of _processVoteUnchecked; only per-project readback is lossy.
    /// Equivalent to QuantLib.create(32, 128); constant required to avoid immutable bloat.
    /// Cross-validated by Kontrol proof P7 (testProductionSchemeConsistency).
    Quant internal constant CONTRIBUTIONS_SCHEME = Quant.wrap(uint16((128 << 8) | 32));

    /// @dev sumSquareRoots is stored as uint128 with no quantization.
    ///      Max value: 2^128 - 1 ~= 3.40e38.
    ///      The uint128 ceiling matches the arithmetic constraint: sumSquareRoots is squared
    ///      on-chain (sumSR * sumSR), which overflows uint256 at 2^128.
    ///      Overflow protection comes from Solidity 0.8's checked uint128() downcast in _writeProject.

    // Custom Errors
    error ContributionMustBePositive();
    error VoteWeightMustBePositive();
    error VoteWeightOverflow(); // Keep for backward compatibility in tests
    error SquareRootTooLarge();
    error VoteWeightOutsideTolerance();
    error QuadraticSumUnderflow();
    error LinearSumUnderflow();
    error DenominatorMustBePositive();
    error AlphaMustBeLessOrEqualToOne();
    error UnsupportedInputDecimals(uint8 provided, uint8 expected);

    /// @notice Expected decimal precision for all contribution/voting-power inputs.
    /// @dev CONTRIBUTIONS_SCHEME's step size (2^32 ~= 4.3 nanotoken) and MIN_VOTE_WEIGHT (2^16)
    ///      are calibrated for 18-decimal-normalized values. Feeding lower-precision inputs
    ///      (e.g., raw 6-decimal USDC) would cause the step to silently swallow entire contributions.
    uint8 internal constant INPUT_DECIMALS = 18;

    /// @notice Storage slot for ProperQF storage (ERC-7201 namespaced storage)
    /// @dev https://eips.ethereum.org/EIPS/eip-7201
    bytes32 private constant STORAGE_SLOT =
        bytes32(uint256(keccak256(abi.encode(uint256(keccak256(bytes("proper.qf.storage"))) - 1))) & ~uint256(0xff));

    /// @notice Per-project aggregated sums (public return type, decoded)
    struct Project {
        /// @notice Sum of contributions for this project (asset base units, lossy: floored to CONTRIBUTIONS_STEP)
        uint256 sumContributions;
        /// @notice Sum of square roots of all contributions (dimensionless)
        uint256 sumSquareRoots;
    }

    /// @notice Packed per-project storage: 128 + 128 = 256 bits = 1 slot
    struct PackedProject {
        /// @notice Sum of contributions, quantized: stored = value >> 32
        uint128 sumContributions;
        /// @notice Sum of square roots, stored without quantization (ceiling matches squaring constraint)
        uint128 sumSquareRoots;
    }

    /// @notice Main storage struct containing all mutable state for ProperQF
    struct ProperQFStorage {
        /// @notice Mapping of project IDs to packed project data (1 slot each)
        mapping(uint256 => PackedProject) projects;
        /// @notice Numerator for alpha (dimensionless; 1.0 = denominator)
        uint256 alphaNumerator;
        /// @notice Denominator for alpha (must be > 0)
        uint256 alphaDenominator;
        /// @notice Sum of all quadratic terms across projects (dimensionless squared weights)
        uint256 totalQuadraticSum;
        /// @notice Sum of all linear contributions across projects (asset base units)
        uint256 totalLinearSum;
        /// @notice Alpha-weighted total funding across all projects (asset base units)
        /// @dev Uses uint256 for precision in calculations
        uint256 totalFunding;
    }

    /// @notice Emitted when alpha parameters are updated
    /// @param oldNumerator Previous alpha numerator
    /// @param oldDenominator Previous alpha denominator
    /// @param newNumerator New alpha numerator
    /// @param newDenominator New alpha denominator
    event AlphaUpdated(uint256 oldNumerator, uint256 oldDenominator, uint256 newNumerator, uint256 newDenominator);

    /// @notice Constructor validates input decimal precision and initializes default alpha values.
    /// @param inputDecimals Must be 18. Forces inheritors to explicitly acknowledge the
    ///        decimal precision that CONTRIBUTIONS_SCHEME and MIN_VOTE_WEIGHT are calibrated for.
    constructor(uint8 inputDecimals) {
        if (inputDecimals != INPUT_DECIMALS) revert UnsupportedInputDecimals(inputDecimals, INPUT_DECIMALS);
        ProperQFStorage storage s = _getProperQFStorage();
        s.alphaNumerator = 10000; // Default alpha = 1.0 (10000/10000)
        s.alphaDenominator = 10000;
    }

    /// @notice Get the storage struct from the predefined slot
    /// @return s Storage struct containing all mutable state for ProperQF
    function _getProperQFStorage() internal pure returns (ProperQFStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Returns project aggregated sums (decoded from packed storage)
    /// @param projectId ID of the project to query
    function projects(uint256 projectId) public view returns (Project memory) {
        (uint256 sumC, uint256 sumSR) = _readProject(projectId);
        return Project({ sumContributions: sumC, sumSquareRoots: sumSR });
    }

    /// @notice Returns alpha numerator
    function alphaNumerator() public view returns (uint256) {
        return _getProperQFStorage().alphaNumerator;
    }

    /// @notice Returns alpha denominator
    function alphaDenominator() public view returns (uint256) {
        return _getProperQFStorage().alphaDenominator;
    }

    /// @notice Returns total quadratic sum across all projects
    function totalQuadraticSum() public view returns (uint256) {
        return _getProperQFStorage().totalQuadraticSum;
    }

    /// @notice Returns total linear sum across all projects
    function totalLinearSum() public view returns (uint256) {
        return _getProperQFStorage().totalLinearSum;
    }

    /// @notice Returns alpha-weighted total funding across all projects
    function totalFunding() public view returns (uint256) {
        return _getProperQFStorage().totalFunding;
    }

    /**
     * @notice Process a vote and update the tally for the voting strategy
     * @dev Implements incremental update quadratic funding algorithm with validations:
     *      - contribution > 0 (asset base units)
     *      - voteWeight > 0 and voteWeight^2 == contribution within 10% tolerance
     *
     *      WARNING: This function does NOT enforce weight alignment to MIN_VOTE_WEIGHT.
     *      Per-project sumContributions readback is lossy (floored to CONTRIBUTIONS_STEP)
     *      unless the caller guarantees contribution is step-aligned (i.e., contribution %
     *      CONTRIBUTIONS_SCHEME.stepSize() == 0). In production, QuadraticVotingMechanism
     *      enforces alignment via weight % MIN_VOTE_WEIGHT == 0 before calling
     *      _processVoteUnchecked. Direct callers of _processVote must be aware of lossy
     *      per-project readback if alignment is not enforced externally.
     * @param projectId ID of project to update
     * @param contribution Contribution to add in asset base units
     * @param voteWeight Square root of contribution (dimensionless)
     */
    function _processVote(uint256 projectId, uint256 contribution, uint256 voteWeight) internal virtual {
        if (contribution == 0) revert ContributionMustBePositive();
        if (voteWeight == 0) revert VoteWeightMustBePositive();

        uint256 voteWeightSquared = voteWeight * voteWeight; // Reverts on overflow in Solidity 0.8+
        if (voteWeightSquared > contribution) revert SquareRootTooLarge();

        // 10% tolerance, asymmetric: voteWeight can be lower than actualSqrt, but not higher
        uint256 actualSqrt = contribution.sqrt();
        uint256 tolerance = actualSqrt / 10;
        if (voteWeight < actualSqrt - tolerance || voteWeight > actualSqrt) {
            revert VoteWeightOutsideTolerance();
        }

        _processVoteUnchecked(projectId, contribution, voteWeight);
    }

    /**
     * @notice Process vote without full validation - only enforces the quantization minimum.
     * @dev Skips sqrt-tolerance checks for gas optimization when caller guarantees correctness.
     *      Enforces contribution >= CONTRIBUTIONS_SCHEME.stepSize() to prevent silent zeroing
     *      of per-project sumContributions due to floor quantization.
     *      Delta update pattern ensures totalLinearSum stays exact despite lossy per-project storage.
     * @param projectId ID of project to update
     * @param contribution Contribution amount (must be >= CONTRIBUTIONS_SCHEME.stepSize())
     * @param voteWeight Vote weight (dimensionless; sqrt of contribution)
     */
    function _processVoteUnchecked(uint256 projectId, uint256 contribution, uint256 voteWeight) internal {
        CONTRIBUTIONS_SCHEME.requireMinStep(contribution);

        ProperQFStorage storage s = _getProperQFStorage();
        (uint256 oldSumContributions, uint256 oldSumSquareRoots) = _readProject(projectId);

        uint256 newSumSquareRoots = oldSumSquareRoots + voteWeight;
        uint256 newSumContributions = oldSumContributions + contribution;

        uint256 oldQuadraticFunding = oldSumSquareRoots * oldSumSquareRoots;
        uint256 newQuadraticFunding = newSumSquareRoots * newSumSquareRoots;

        if (s.totalQuadraticSum < oldQuadraticFunding) revert QuadraticSumUnderflow();
        if (s.totalLinearSum < oldSumContributions) revert LinearSumUnderflow();

        s.totalQuadraticSum = s.totalQuadraticSum - oldQuadraticFunding + newQuadraticFunding;
        s.totalLinearSum = s.totalLinearSum - oldSumContributions + newSumContributions;

        _writeProject(projectId, newSumContributions, newSumSquareRoots);

        s.totalFunding = _calculateWeightedTotalFunding();
    }

    /**
     * @notice Calculate alpha-weighted total funding across all projects
     * @dev Rounding: per-project integer division makes sum(project funding) ≤ totalFunding.
     *      Discrepancy ε is bounded: 0 ≤ ε ≤ 2(|P|-1) where |P| is number of projects.
     *      This dust ensures no over-allocation; all funds are still fully distributed.
     * @return totalFunding_ Weighted total funding across all projects (asset base units)
     */
    function _calculateWeightedTotalFunding() internal view returns (uint256) {
        ProperQFStorage storage s = _getProperQFStorage();
        uint256 weightedQuadratic = (s.totalQuadraticSum * s.alphaNumerator) / s.alphaDenominator;
        uint256 weightedLinear = (s.totalLinearSum * (s.alphaDenominator - s.alphaNumerator)) / s.alphaDenominator;
        return weightedQuadratic + weightedLinear;
    }

    /**
     * @notice Return current funding metrics for a specific project
     * @dev Aggregates sums and computes alpha-weighted components on-demand.
     * @param projectId ID of project to tally
     * @return sumContributions Total sum of contributions (asset base units)
     * @return sumSquareRoots Sum of square roots of contributions (dimensionless)
     * @return quadraticFunding Alpha-weighted quadratic funding: ⌊α × S_j²⌋ (asset base units)
     * @return linearFunding Alpha-weighted linear funding: ⌊(1-α) × Sum_j⌋ (asset base units)
     * @dev Rounding: sum of per-project funding ≤ totalFunding() with small bounded dust ε.
     */
    function getTally(
        uint256 projectId
    )
        public
        view
        returns (uint256 sumContributions, uint256 sumSquareRoots, uint256 quadraticFunding, uint256 linearFunding)
    {
        ProperQFStorage storage s = _getProperQFStorage();
        (uint256 sumC, uint256 sumSR) = _readProject(projectId);

        uint256 rawQuadraticFunding = sumSR * sumSR;

        return (
            sumC,
            sumSR,
            (rawQuadraticFunding * s.alphaNumerator) / s.alphaDenominator,
            (sumC * (s.alphaDenominator - s.alphaNumerator)) / s.alphaDenominator
        );
    }

    // ── Pack/unpack helpers ──────────────────────────────────────────────

    /// @notice Decode packed project storage into full-width uint256 values
    function _readProject(uint256 projectId) internal view returns (uint256 sumContributions, uint256 sumSquareRoots) {
        PackedProject storage packed = _getProperQFStorage().projects[projectId];
        sumContributions = CONTRIBUTIONS_SCHEME.decode(uint256(packed.sumContributions));
        sumSquareRoots = uint256(packed.sumSquareRoots);
    }

    /// @notice Encode and store full-width values into packed project storage
    /// @dev sumContributions: reverts with Overflow(value, max) if it exceeds CONTRIBUTIONS_SCHEME.max().
    ///      sumSquareRoots: reverts via Solidity 0.8 checked downcast if it exceeds type(uint128).max.
    function _writeProject(uint256 projectId, uint256 sumContributions, uint256 sumSquareRoots) internal {
        _getProperQFStorage().projects[projectId] = PackedProject({
            sumContributions: uint128(CONTRIBUTIONS_SCHEME.encode(sumContributions)),
            sumSquareRoots: uint128(sumSquareRoots)
        });
    }

    /**
     * @notice Set alpha parameter determining ratio between quadratic and linear funding
     * @param newNumerator Numerator of new alpha (0 ≤ numerator ≤ denominator)
     * @param newDenominator Denominator of new alpha (> 0)
     */
    function _setAlpha(uint256 newNumerator, uint256 newDenominator) internal {
        if (newDenominator == 0) revert DenominatorMustBePositive();
        if (newNumerator > newDenominator) revert AlphaMustBeLessOrEqualToOne();

        ProperQFStorage storage s = _getProperQFStorage();

        uint256 oldNumerator = s.alphaNumerator;
        uint256 oldDenominator = s.alphaDenominator;

        s.alphaNumerator = newNumerator;
        s.alphaDenominator = newDenominator;

        // Recalculate total funding with new alpha
        s.totalFunding = _calculateWeightedTotalFunding();

        emit AlphaUpdated(oldNumerator, oldDenominator, newNumerator, newDenominator);
    }

    /**
     * @notice Get current alpha ratio components
     * @return numerator Current alpha numerator
     * @return denominator Current alpha denominator
     */
    function getAlpha() public view returns (uint256, uint256) {
        ProperQFStorage storage s = _getProperQFStorage();
        return (s.alphaNumerator, s.alphaDenominator);
    }

    /**
     * @notice Calculate optimal alpha for 1:1 shares-to-assets ratio given fixed matching pool amount
     * @dev Solve α where: α × totalQuadraticSum + (1−α) × totalLinearSum = totalUserDeposits + matchingPoolAmount
     * @param matchingPoolAmount Matching pool amount (asset base units)
     * @param quadraticSum Total quadratic sum across all proposals (dimensionless)
     * @param linearSum Total linear sum across all proposals (asset base units)
     * @param totalUserDeposits Total user deposits in the mechanism (asset base units)
     * @return optimalAlphaNumerator Calculated alpha numerator
     * @return optimalAlphaDenominator Calculated alpha denominator
     */
    function _calculateOptimalAlpha(
        uint256 matchingPoolAmount,
        uint256 quadraticSum,
        uint256 linearSum,
        uint256 totalUserDeposits
    ) internal pure returns (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) {
        if (quadraticSum <= linearSum) {
            // No quadratic funding benefit, set alpha to 0
            optimalAlphaNumerator = 0;
            optimalAlphaDenominator = 1;
            return (optimalAlphaNumerator, optimalAlphaDenominator);
        }

        uint256 totalAssetsAvailable = totalUserDeposits + matchingPoolAmount;
        uint256 quadraticAdvantage = quadraticSum - linearSum;

        // We want: α × quadraticSum + (1-α) × linearSum = totalAssetsAvailable
        // Solving for α: α × (quadraticSum - linearSum) = totalAssetsAvailable - linearSum
        // Therefore: α = (totalAssetsAvailable - linearSum) / (quadraticSum - linearSum)

        if (totalAssetsAvailable <= linearSum) {
            // Not enough assets even for linear funding, set alpha to 0
            optimalAlphaNumerator = 0;
            optimalAlphaDenominator = 1;
        } else {
            uint256 numerator = totalAssetsAvailable - linearSum;

            if (numerator >= quadraticAdvantage) {
                // Enough assets for full quadratic funding
                optimalAlphaNumerator = 1;
                optimalAlphaDenominator = 1;
            } else {
                // Calculate fractional alpha
                optimalAlphaNumerator = numerator;
                optimalAlphaDenominator = quadraticAdvantage;
            }
        }
    }
}
