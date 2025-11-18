// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { RegenStakerBase } from "../RegenStakerBase.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    // === Constructor ===

    /// @notice Constructor for RegenStakerWithAdvances
    /// @dev Inherits all RegenStakerBase parameters
    /// @param _advanceDiscountBps Initial discount rate for advances (in basis points)
    /// @param _minCommitmentWeeks Minimum commitment duration in weeks
    /// @param _maxCommitmentWeeks Maximum commitment duration in weeks
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
        IAddressSet _allocationMechanismAllowset,
        string memory _eip712Name,
        uint16 _advanceDiscountBps,
        uint32 _minCommitmentWeeks,
        uint32 _maxCommitmentWeeks
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
            _eip712Name
        )
    {
        _validateAdvanceParameters(_advanceDiscountBps, _minCommitmentWeeks, _maxCommitmentWeeks);

        advanceDiscountBps = _advanceDiscountBps;
        minCommitmentWeeks = _minCommitmentWeeks;
        maxCommitmentWeeks = _maxCommitmentWeeks;
        advancesPaused = false;
    }

    // === Public Functions ===

    /// @notice Calculates the advance amount for a given commitment
    /// @dev Pure calculation, no state changes - useful for UI previews
    /// @param user Address of the user
    /// @param commitmentWeeks Duration of commitment in weeks
    /// @return advanceAmount Amount user would receive as advance
    /// @return projectedRewards Projected rewards over commitment period (before discount)
    function calculateAdvance(
        address user,
        uint256 commitmentWeeks
    ) external view returns (uint256 advanceAmount, uint256 projectedRewards) {
        uint256 earningPower = depositorTotalEarningPower[user];

        if (earningPower == 0) {
            return (0, 0);
        }

        projectedRewards = _calculateProjectedRewards(earningPower, commitmentWeeks);
        advanceAmount = _applyDiscount(projectedRewards, advanceDiscountBps);

        return (advanceAmount, projectedRewards);
    }

    /// @notice Calculates penalty for early withdrawal
    /// @dev Returns 0 if commitment period has ended
    /// @param user Address of the user
    /// @return penalty Penalty amount in reward tokens
    function getPenaltyForEarlyExit(address user) external view returns (uint256 penalty) {
        AdvanceInfo storage advance = advances[user];

        if (advance.commitmentEnd <= block.timestamp) {
            return 0;
        }

        return _calculatePenalty(address(0), advance);
    }

    /// @notice Requests an advance on future rewards
    /// @dev Requires user to have earning power and no active commitment
    /// @param commitmentWeeks Duration to commit for (in weeks)
    /// @return advanceAmount Amount of advance given to user
    function requestAdvance(
        uint256 commitmentWeeks
    ) external whenNotPaused nonReentrant returns (uint256 advanceAmount) {
        if (advancesPaused) revert AdvancesPaused();

        // 1. Validate commitment duration
        if (commitmentWeeks < minCommitmentWeeks) {
            revert CommitmentTooShort(commitmentWeeks, minCommitmentWeeks);
        }
        if (commitmentWeeks > maxCommitmentWeeks) {
            revert CommitmentTooLong(commitmentWeeks, maxCommitmentWeeks);
        }

        // 2. Check for existing commitment
        AdvanceInfo storage advance = advances[msg.sender];
        if (advance.commitmentEnd > block.timestamp) {
            revert CommitmentActive(advance.commitmentEnd);
        }

        // 3. Validate earning power
        uint256 earningPower = depositorTotalEarningPower[msg.sender];
        if (earningPower == 0) {
            revert NoEarningPower(msg.sender);
        }

        // 4. Calculate advance
        uint256 projectedRewards = _calculateProjectedRewards(earningPower, commitmentWeeks);
        advanceAmount = _applyDiscount(projectedRewards, advanceDiscountBps);

        // 5. Solvency check
        uint256 maxOutstanding = _getMaxOutstandingAdvances();
        if (totalOutstandingAdvances + advanceAmount > maxOutstanding) {
            revert ExceedsAdvanceCap(totalOutstandingAdvances + advanceAmount, maxOutstanding);
        }

        // 6. Record advance state
        advance.advanceAmount = advanceAmount.toUint96();
        advance.repaidAmount = 0;
        advance.commitmentEnd = uint64(block.timestamp + commitmentWeeks * SECONDS_PER_WEEK);
        advance.earningPowerSnapshot = earningPower.toUint96();

        // 7. Update global state
        totalOutstandingAdvances += advanceAmount;

        // 8. Transfer advance to user
        SafeERC20.safeTransfer(REWARD_TOKEN, msg.sender, advanceAmount);

        emit AdvanceRequested(msg.sender, advanceAmount, advance.commitmentEnd, advanceDiscountBps);

        return advanceAmount;
    }

    /// @notice Updates advance configuration parameters
    /// @dev Only callable by admin
    /// @param _discountBps New discount rate in basis points
    /// @param _minWeeks New minimum commitment duration
    /// @param _maxWeeks New maximum commitment duration
    function setAdvanceParameters(uint16 _discountBps, uint32 _minWeeks, uint32 _maxWeeks) external {
        _revertIfNotAdmin();

        _validateAdvanceParameters(_discountBps, _minWeeks, _maxWeeks);

        advanceDiscountBps = _discountBps;
        minCommitmentWeeks = _minWeeks;
        maxCommitmentWeeks = _maxWeeks;

        emit AdvanceParametersUpdated(_discountBps, _minWeeks, _maxWeeks);
    }

    /// @notice Pauses or unpauses advance requests
    /// @dev Only callable by admin
    /// @param paused True to pause, false to unpause
    function setAdvancesPaused(bool paused) external {
        _revertIfNotAdmin();

        advancesPaused = paused;

        emit AdvancesPausedUpdated(paused);
    }

    // === Internal Functions ===

    /// @notice Validates advance configuration parameters
    function _validateAdvanceParameters(uint16 _discountBps, uint32 _minWeeks, uint32 _maxWeeks) internal pure {
        if (_discountBps < MIN_DISCOUNT_BPS || _discountBps > MAX_DISCOUNT_BPS) {
            revert InvalidDiscountBps(_discountBps);
        }
        if (_minWeeks == 0 || _maxWeeks == 0 || _minWeeks > _maxWeeks) {
            revert InvalidCommitmentRange(_minWeeks, _maxWeeks);
        }
    }

    /// @notice Calculates projected rewards for given earning power and duration
    /// @dev Internal helper for reward projection
    function _calculateProjectedRewards(uint256 earningPower, uint256 commitmentWeeks) internal view returns (uint256) {
        if (totalEarningPower == 0 || scaledRewardRate == 0) {
            return 0;
        }

        uint256 commitmentSeconds = commitmentWeeks * SECONDS_PER_WEEK;

        // Calculate user's share of rewards over commitment period
        // Formula: (userEP / totalEP) × rewardRate × duration
        uint256 userShare = (earningPower * SCALE_FACTOR) / totalEarningPower;
        uint256 rewardPerSecond = scaledRewardRate / SCALE_FACTOR;

        return (userShare * rewardPerSecond * commitmentSeconds) / SCALE_FACTOR;
    }

    /// @notice Applies discount to projected rewards
    function _applyDiscount(uint256 amount, uint256 discountBps) internal pure returns (uint256) {
        return (amount * (BPS_DENOMINATOR - discountBps)) / BPS_DENOMINATOR;
    }

    /// @notice Internal penalty calculation with graduated schedule
    /// @dev Penalty = outstanding × (timeRemaining / totalCommitment)
    function _calculatePenalty(address, AdvanceInfo storage advance) internal view returns (uint256) {
        uint256 outstanding = advance.advanceAmount - advance.repaidAmount;

        if (outstanding == 0) {
            return 0;
        }

        uint256 timeRemaining = advance.commitmentEnd - block.timestamp;

        // Calculate total commitment duration from commitment end
        // This is approximate but avoids storing commitmentStart
        uint256 totalCommitment = maxCommitmentWeeks * SECONDS_PER_WEEK;

        // Graduated penalty: 100% at start → 0% at end
        return (outstanding * timeRemaining) / totalCommitment;
    }

    /// @notice Calculates maximum allowed outstanding advances
    /// @dev Currently set to 10% of total rewards
    function _getMaxOutstandingAdvances() internal view returns (uint256) {
        return totalRewards / 10;
    }

    // === Overridden Functions ===

    /// @notice Overrides parent to deduct advance repayments from claimed rewards
    /// @dev Advances are repaid automatically before user receives rewards
    /// @param _depositId Deposit identifier
    /// @param deposit Deposit storage reference
    /// @param _claimer Address claiming rewards
    /// @return netAmount Amount transferred to user (after advance repayment)
    function _claimReward(
        DepositIdentifier _depositId,
        Deposit storage deposit,
        address _claimer
    ) internal virtual override returns (uint256 netAmount) {
        // 1. Checkpoint rewards (from grandparent Staker logic)
        _checkpointGlobalReward();
        _checkpointReward(deposit);

        uint256 grossAmount = deposit.scaledUnclaimedRewardCheckpoint / SCALE_FACTOR;

        if (grossAmount == 0) {
            return 0;
        }

        // 2. Check for outstanding advances
        AdvanceInfo storage advance = advances[deposit.owner];
        uint256 outstanding = advance.advanceAmount > advance.repaidAmount
            ? advance.advanceAmount - advance.repaidAmount
            : 0;

        uint256 repayment = 0;

        if (outstanding > 0) {
            // 3. Calculate repayment (min of gross amount or outstanding)
            repayment = grossAmount > outstanding ? outstanding : grossAmount;

            // 4. Update advance state
            advance.repaidAmount += repayment.toUint96();
            totalOutstandingAdvances -= repayment;

            emit AdvanceRepaid(deposit.owner, repayment, outstanding - repayment);
        }

        // 5. Calculate net amount after repayment
        netAmount = grossAmount - repayment;

        // 6. Consume rewards and update state
        _consumeRewards(deposit, grossAmount);
        totalClaimedRewards += grossAmount; // Track gross, not net

        // 7. Transfer net amount to claimer
        if (netAmount > 0) {
            SafeERC20.safeTransfer(REWARD_TOKEN, _claimer, netAmount);
        }

        emit RewardClaimed(_depositId, _claimer, netAmount, deposit.earningPower);

        return netAmount;
    }
}
