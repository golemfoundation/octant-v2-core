// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { RegenStakerBase } from "../RegenStakerBase.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

/// @title RegenStakerWithAdvances
/// @notice Extends RegenStakerBase with advance rewards functionality
/// @dev Users can request future rewards upfront in exchange for guaranteed commitments
abstract contract RegenStakerWithAdvances is RegenStakerBase {
    using SafeCast for uint256;

    // === Structs ===

    /// @notice Information about a user's advance reward commitment
    /// @dev Packed into 2 storage slots for gas efficiency
    struct AdvanceInfo {
        uint96 advanceAmount; // Total advance given
        uint96 repaidAmount; // Amount repaid from rewards
        uint64 commitmentEnd; // Timestamp when commitment ends
        uint96 earningPowerSnapshot; // Earning power at advance time
    }

    // === Constants ===

    uint256 public constant SECONDS_PER_WEEK = 7 days;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MIN_DISCOUNT_BPS = 100; // 1% minimum
    uint256 public constant MAX_DISCOUNT_BPS = 2000; // 20% maximum

    // === State Variables ===

    /// @notice Mapping of user addresses to their advance information
    mapping(address => AdvanceInfo) public advances;

    /// @notice Total outstanding advances across all users
    /// @dev Used for solvency checks
    uint256 public totalOutstandingAdvances;

    /// @notice Discount rate applied to advance calculations in basis points
    /// @dev e.g., 500 = 5% discount from projected rewards
    uint16 public advanceDiscountBps;

    /// @notice Minimum commitment duration in weeks
    uint32 public minCommitmentWeeks;

    /// @notice Maximum commitment duration in weeks
    uint32 public maxCommitmentWeeks;

    /// @notice Whether advance requests are currently paused
    bool public advancesPaused;

    // === Custom Errors ===

    error CommitmentTooShort(uint256 requested, uint256 minimum);
    error CommitmentTooLong(uint256 requested, uint256 maximum);
    error CommitmentActive(uint256 endTime);
    error NoEarningPower(address user);
    error ExceedsAdvanceCap(uint256 requested, uint256 available);
    error AdvancesPaused();
    error InvalidDiscountBps(uint256 bps);
    error InvalidCommitmentRange(uint256 min, uint256 max);

    // === Events ===

    /// @notice Emitted when a user requests an advance
    event AdvanceRequested(address indexed user, uint256 advanceAmount, uint256 commitmentEnd, uint256 discountBps);

    /// @notice Emitted when a user breaks their commitment early
    event CommitmentBroken(address indexed user, uint256 penalty, uint256 timeRemaining);

    /// @notice Emitted when an advance is repaid from rewards
    event AdvanceRepaid(address indexed user, uint256 amount, uint256 remaining);

    /// @notice Emitted when advance parameters are updated
    event AdvanceParametersUpdated(uint16 discountBps, uint32 minWeeks, uint32 maxWeeks);

    /// @notice Emitted when advances are paused or unpaused
    event AdvancesPausedUpdated(bool paused);

    // Constructor and implementation to be added in subsequent tasks
}
