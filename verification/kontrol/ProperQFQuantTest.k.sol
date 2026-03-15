// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { KontrolTest } from "verification/kontrol/KontrolTest.k.sol";
import { ProperQFProofHarness, ProperQFConcrete } from "verification/kontrol/ProperQFProofHarness.k.sol";

/// @title ProperQFQuantTest
/// @notice Kontrol formal verification proofs for ProperQF quantization invariants.
/// @dev Proves 12 properties of the PackedProject storage layout introduced in PR 400:
///      P1: Aligned weights produce step-aligned contributions (lossless per-project storage)
///      P2: Encode/decode round-trips are exact for step-aligned values (symbolic)
///      P2b: Round-trip boundary cases for value == 0 and value == schemeMax (concrete)
///      P3: Delta update pattern preserves exact global sums despite lossy per-project storage
///      P4: sumSquareRoots^2 fits in uint256 when sumSR <= type(uint128).max
///      P5: MIN_VOTE_WEIGHT^2 == stepSize (calibration)
///      P6: Storage ceilings provide massive headroom over realistic accumulated totals
///      P7: Production ProperQF encode/decode matches harness scheme (drift guard)
///      P8: Production MIN_VOTE_WEIGHT matches harness constant (drift guard)
///      P9: Packed storage halves do not interfere; sumSquareRoots round-trips losslessly
///      P10: _processVoteUnchecked preserves totalLinearSum exactly via production storage
///      P11: Live caps (max weight = sqrt(MAX_SAFE_VALUE)) cannot overflow packed storage
contract ProperQFQuantTest is KontrolTest {
    ProperQFProofHarness qf;
    ProperQFConcrete prod;

    function setUp() public {
        qf = new ProperQFProofHarness();
        prod = new ProperQFConcrete();
    }

    /// @notice P1: weight % MIN_VOTE_WEIGHT == 0 implies weight^2 % stepSize == 0
    /// @dev Mathematically: weight = k * 2^16 => weight^2 = k^2 * 2^32 = k^2 * stepSize.
    ///      Kontrol verifies this holds within EVM uint256 arithmetic for all valid weights.
    ///      Uses multiplicative form (k * minW) to make alignment structural, avoiding
    ///      K framework limitations with symbolic bitmask/modulo constraints.
    function testAlignmentInvariant(uint256 k) public view {
        uint256 minW = qf.MIN_VOTE_WEIGHT();
        uint256 step = qf.stepSize();

        // Preconditions: k > 0, weight = k * minW fits in uint128
        vm.assume(k > 0);
        vm.assume(k <= type(uint128).max / minW);

        uint256 weight = k * minW;
        uint256 contribution = weight * weight;

        // Property: contribution is step-aligned (lossless encode)
        assert(contribution % step == 0);
    }

    /// @notice P2: decode(encode(value)) == value for step-aligned values within range
    /// @dev Encode right-shifts by 32, decode left-shifts by 32. For step-aligned values,
    ///      the right-shift discards only zeros, so the round-trip is lossless.
    ///      Relies on K lemma quant-decode-encode for symbolic #buf/#asWord simplification.
    function testLosslessRoundTrip(uint256 value) public view {
        uint256 step = qf.stepSize();
        uint256 max_ = qf.schemeMax();

        // Preconditions: step-aligned and within representable range
        vm.assume(value % step == 0);
        vm.assume(value <= max_);

        uint256 encoded = qf.encode(value);
        uint256 decoded = qf.decode(encoded);

        // Property: round-trip is lossless
        assert(decoded == value);
    }

    /// @notice P2b: concrete boundary cases for round-trip (value == 0 and value == schemeMax)
    /// @dev Completes P2 coverage for the two boundary values excluded from the symbolic proof.
    function testLosslessRoundTripBoundaries() public view {
        uint256 max_ = qf.schemeMax();

        // Zero: default storage readback
        assert(qf.decode(qf.encode(0)) == 0);

        // schemeMax: exact upper boundary
        assert(qf.decode(qf.encode(max_)) == max_);
    }

    /// @notice P3: decoded delta equals true delta for step-aligned values
    /// @dev Guarantees the delta update pattern in _processVoteUnchecked accumulates
    ///      no quantization error in totalLinearSum. Follows from P2 but exists to make
    ///      the reasoning explicit and machine-checked.
    function testDeltaCancellation(uint256 oldSum, uint256 contribution) public view {
        uint256 step = qf.stepSize();
        uint256 max_ = qf.schemeMax();

        // Preconditions: both values are step-aligned
        vm.assume(oldSum % step == 0);
        vm.assume(contribution % step == 0);
        vm.assume(oldSum <= max_);
        vm.assume(contribution > 0);
        // Prevent checked-arithmetic overflow before the assume on newSum can fire
        vm.assume(contribution <= max_ - oldSum);

        uint256 newSum = oldSum + contribution;
        vm.assume(newSum <= max_);

        // Property: decoded delta equals true delta
        uint256 decodedOld = qf.decode(qf.encode(oldSum));
        uint256 decodedNew = qf.decode(qf.encode(newSum));
        assert(decodedNew - decodedOld == newSum - oldSum);
    }

    /// @notice P4: sumSR^2 fits in uint256 when sumSR <= type(uint128).max
    /// @dev Validates the uint128 storage ceiling for sumSquareRoots.
    ///      (2^128 - 1)^2 = 2^256 - 2^129 + 1 <= type(uint256).max.
    ///      If the checked multiplication succeeds (no revert), the property holds.
    function testSquaringBoundary(uint256 sumSR) public pure {
        vm.assume(sumSR <= type(uint128).max);

        // Checked multiplication: reverts on overflow in Solidity 0.8+.
        // If symbolic execution reaches the assert, no overflow occurred.
        uint256 squared = sumSR * sumSR;

        // Explicit no-overflow witness
        assert(sumSR == 0 || squared / sumSR == sumSR);
    }

    /// @notice P5: MIN_VOTE_WEIGHT^2 == CONTRIBUTIONS_SCHEME.stepSize()
    /// @dev Verifies the minimum weight exactly matches the quantization step.
    ///      2^16 * 2^16 = 2^32 = stepSize.
    function testMinWeightCalibration() public view {
        uint256 minW = qf.MIN_VOTE_WEIGHT();
        uint256 step = qf.stepSize();

        assert(minW * minW == step);
    }

    /// @notice P6: storage ceilings accommodate >= 2^32 max-size votes per project
    /// @dev Computes headroom as schemeMax / maxSingleContribution and
    ///      uint128.max / sqrt(maxSingleContribution). Both exceed 2^32,
    ///      proving that even 4 billion maximum-size voters per project
    ///      cannot exhaust the storage ceilings.
    function testHeadroomSufficiency() public view {
        uint256 max_ = qf.schemeMax();

        // Contributions headroom: schemeMax / ETH_UPPER_BOUND
        // ETH_UPPER_BOUND = 2^96 (per-voter cap from existing Kontrol proofs)
        uint256 contributionsHeadroom = max_ / ETH_UPPER_BOUND;
        assert(contributionsHeadroom >= 2 ** 32);

        // SquareRoots headroom: uint128.max / sqrt(ETH_UPPER_BOUND)
        // sqrt(2^96) = 2^48
        uint256 sqrtUpperBound = 2 ** 48;
        uint256 squareRootsHeadroom = type(uint128).max / sqrtUpperBound;
        assert(squareRootsHeadroom >= 2 ** 32);
    }

    /// @notice P7: production ProperQF._writeProject/_readProject round-trip matches
    ///         the harness's encode/decode for all step-aligned values.
    /// @dev Guards against constant drift: if ProperQF's private CONTRIBUTIONS_SCHEME
    ///      parameters change without updating the harness, this proof fails.
    ///      Tests the actual storage path (write to packed mapping slot, read back).
    function testProductionSchemeConsistency(uint256 value) public {
        uint256 step = qf.stepSize();
        uint256 max_ = qf.schemeMax();

        // Preconditions: step-aligned and within representable range
        vm.assume(value % step == 0);
        vm.assume(value <= max_);

        // Write through production _writeProject, read back through production _readProject
        prod.writeProject(0, value, 0);
        (uint256 prodReadback, ) = prod.readProject(0);

        // Harness encode/decode
        uint256 harnessResult = qf.decode(qf.encode(value));

        // Property: production storage path matches harness scheme
        assert(prodReadback == harnessResult);
        // Both should be lossless for step-aligned values
        assert(prodReadback == value);
    }

    // ── End-to-end gap-closing proofs ────────────────────────────────────

    /// @notice P8: PROD_MIN_VOTE_WEIGHT == harness MIN_VOTE_WEIGHT
    /// @dev Compares the harness's duplicated production constant against its own
    ///      MIN_VOTE_WEIGHT. This does NOT read QVM.MIN_VOTE_WEIGHT directly (deploying
    ///      QVM in the proof is impractical). The duplicated constant must be kept in sync
    ///      manually; see the cross-reference comment in QuadraticVotingMechanism.sol.
    ///      Combined with P5 (MIN_VOTE_WEIGHT^2 == stepSize), this ensures that IF the
    ///      constants are in sync, the weight gate produces step-aligned contributions.
    function testProdMinVoteWeightMatchesHarness() public view {
        assert(prod.PROD_MIN_VOTE_WEIGHT() == qf.MIN_VOTE_WEIGHT());
    }

    /// @notice P9: packed storage halves do not interfere; sumSquareRoots round-trips losslessly
    /// @dev Writes both halves with nonzero values, reads back, and verifies each half
    ///      is independent. Closes the gap where P7 only tested sumSR = 0.
    function testPackedSlotIndependence(uint256 sumC, uint256 sumSR) public {
        uint256 step = qf.stepSize();
        uint256 max_ = qf.schemeMax();

        // Preconditions: valid packed values
        vm.assume(sumC % step == 0);
        vm.assume(sumC <= max_);
        vm.assume(sumSR <= type(uint128).max);

        prod.writeProject(0, sumC, sumSR);
        (uint256 readC, uint256 readSR) = prod.readProject(0);

        // sumContributions round-trips (lossy encode/decode, but exact for aligned values)
        assert(readC == sumC);
        // sumSquareRoots round-trips losslessly (no quantization)
        assert(readSR == sumSR);
    }

    /// @notice P10: _processVoteUnchecked preserves totalLinearSum exactly
    /// @dev Exercises the production storage path end-to-end: writes initial state,
    ///      calls processVoteUnchecked, verifies totalLinearSum == contribution.
    ///      This proves the delta update pattern cancels quantization error in the
    ///      live code path, not just in the harness encode/decode identity (P3).
    ///      Uses multiplicative form (k * minW) for structural alignment.
    ///      Bounds k to uint32 so weight fits in uint48 and weight^2 fits in uint96,
    ///      keeping all intermediate values well within uint128 to avoid K framework
    ///      overflow-check branches on symbolic #buf constructions.
    function testProcessVoteLinearSumExact(uint256 k) public {
        uint256 minW = qf.MIN_VOTE_WEIGHT();

        // Preconditions: k > 0 and small enough that weight^2 fits easily
        vm.assume(k > 0);
        vm.assume(k <= type(uint32).max);

        uint256 weight = k * minW;
        uint256 contribution = weight * weight;

        // Process a single vote on a fresh project (totalLinearSum starts at 0)
        prod.processVoteUnchecked(0, contribution, weight);

        // Property: totalLinearSum == contribution (exact, no quantization error)
        assert(prod.getTotalLinearSum() == contribution);

        // Also verify totalQuadraticSum == weight^2 (which equals contribution for first vote)
        // totalQuadraticSum = newSumSR^2 = weight^2 = contribution
        assert(prod.getTotalQuadraticSum() == weight * weight);
    }

    /// @notice P11: live caps cannot overflow packed storage ceilings
    /// @dev QVM enforces weight^2 <= votingPower <= MAX_SAFE_VALUE (uint128.max),
    ///      so the effective max weight is floor(sqrt(MAX_SAFE_VALUE)) = 2^64 - 1.
    ///      Max contribution = (2^64-1)^2 ~= 2^128, well within schemeMax ~= 2^160.
    ///      Proves massive headroom: >= 2^32 max-size votes fit per project.
    function testLiveCapsHeadroom() public view {
        uint256 max_ = qf.schemeMax();

        // Effective max weight: floor(sqrt(MAX_SAFE_VALUE))
        // MAX_SAFE_VALUE = uint128.max, sqrt(uint128.max) = uint64.max
        uint256 maxWeight = type(uint64).max;
        uint256 maxContribution = maxWeight * maxWeight;

        // Single max-size vote fits in sumContributions
        assert(maxContribution <= max_);

        // maxWeight fits in sumSquareRoots (uint128)
        assert(maxWeight <= type(uint128).max);

        // Headroom: how many max-size votes fit before overflow
        uint256 contributionsHeadroom = max_ / maxContribution;
        assert(contributionsHeadroom >= 2 ** 32);

        uint256 sqrtHeadroom = type(uint128).max / maxWeight;
        assert(sqrtHeadroom >= 2 ** 32);
    }
}
