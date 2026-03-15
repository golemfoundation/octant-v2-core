// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Quant, UintQuantizationLib as QuantLib } from "uint-quantization-lib/src/UintQuantizationLib.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";

/// @title ProperQFProofHarness
/// @notice Exposes CONTRIBUTIONS_SCHEME accessors and MIN_VOTE_WEIGHT for Kontrol proofs.
/// @dev Mirrors the scheme from ProperQF (create(32, 128)) and the minimum weight from
///      QuadraticVotingMechanism (1 << 16). Private immutables are duplicated here because
///      ProperQF.CONTRIBUTIONS_SCHEME is not inheritable.
contract ProperQFProofHarness {
    Quant public immutable SCHEME = QuantLib.create(32, 128);
    uint256 public constant MIN_VOTE_WEIGHT = 1 << 16;

    function stepSize() external view returns (uint256) {
        return SCHEME.stepSize();
    }

    function schemeMax() external view returns (uint256) {
        return SCHEME.max();
    }

    function encode(uint256 value) external view returns (uint256) {
        return SCHEME.encode(value);
    }

    function decode(uint256 encoded) external view returns (uint256) {
        return SCHEME.decode(encoded);
    }
}

/// @title ProperQFConcrete
/// @notice Concrete ProperQF inheritor for Kontrol proofs. Exposes internal functions
///         so proofs can exercise the production storage path end-to-end.
contract ProperQFConcrete is ProperQF(18) {
    function writeProject(uint256 id, uint256 sumC, uint256 sumSR) external {
        _writeProject(id, sumC, sumSR);
    }

    function readProject(uint256 id) external view returns (uint256 sumC, uint256 sumSR) {
        return _readProject(id);
    }

    function processVoteUnchecked(uint256 projectId, uint256 contribution, uint256 voteWeight) external {
        _processVoteUnchecked(projectId, contribution, voteWeight);
    }

    function getTotalLinearSum() external view returns (uint256) {
        return totalLinearSum();
    }

    function getTotalQuadraticSum() external view returns (uint256) {
        return totalQuadraticSum();
    }

    /// @notice Duplicated QuadraticVotingMechanism.MIN_VOTE_WEIGHT for Kontrol proofs.
    /// @dev Must be kept in sync with QuadraticVotingMechanism.MIN_VOTE_WEIGHT manually.
    ///      A cross-reference comment in QuadraticVotingMechanism.sol points here.
    ///      P8 asserts this equals the harness MIN_VOTE_WEIGHT above; P5 asserts
    ///      MIN_VOTE_WEIGHT^2 == stepSize. Together they ensure that IF this constant
    ///      matches the production value, the weight gate produces step-aligned contributions.
    ///      Deploying QVM in the proof to read the constant directly is impractical.
    uint256 public constant PROD_MIN_VOTE_WEIGHT = 1 << 16;
}
