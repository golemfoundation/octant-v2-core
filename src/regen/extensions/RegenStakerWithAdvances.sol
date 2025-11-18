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
    /// @dev Ultra-lean: Packed into 1 storage slot (20 bytes used, 12 bytes available)
    struct AdvanceInfo {
        uint96 outstanding; // Outstanding debt (decreases as repaid) - 12 bytes
        uint64 commitmentEnd; // Timestamp when commitment ends - 8 bytes
        // Total: 20 bytes = 1 SLOT (12 bytes available for future)
    }

    // === Constants ===

    uint256 public constant SECONDS_PER_WEEK = 7 days;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant COMMITMENT_DURATION = 26 weeks; // Fixed 6-month commitment
    uint256 public constant DISCOUNT_BPS = 500; // Fixed 5% discount
    uint256 public constant MAX_ADVANCE_PCT = 50; // Can advance max 50% of projected
    uint256 public constant GLOBAL_CAP_PCT = 10; // Max 10% of uncommitted rewards

    // === State Variables ===

    /// @notice Mapping of user addresses to their advance information
    mapping(address => AdvanceInfo) public advances;

    /// @notice Total outstanding advances across all users
    /// @dev Used for global solvency cap (max 10% of uncommitted rewards)
    uint256 public totalOutstandingAdvances;

    // === Custom Errors ===

    error OutstandingAdvanceExists();
    error NoEarningPower(address user);
    error ExceedsPersonalCap(uint256 requested, uint256 maxAllowed);
    error ExceedsGlobalCap(uint256 requested, uint256 available);

    // === Events ===

    /// @notice Emitted when a user requests an advance
    event AdvanceRequested(address indexed user, uint256 advanceAmount, uint256 commitmentEnd);

    /// @notice Emitted when a user breaks their commitment early
    event CommitmentBroken(address indexed user, uint256 penalty, uint256 timeRemaining);

    /// @notice Emitted when an advance is repaid from rewards
    event AdvanceRepaid(address indexed user, uint256 repayment, uint256 remaining);

    // === Constructor ===

    /// @notice Constructor for RegenStakerWithAdvances
    /// @dev All advance parameters are now constants (no configuration needed)
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
        string memory _eip712Name
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
        // No initialization needed - all parameters are constants
    }

    // === Public Functions ===

    /// @notice Calculates the advance amount for a user
    /// @dev Fixed 26-week commitment with 5% discount
    /// @param user Address of the user
    /// @return advanceAmount Amount user would receive as advance
    /// @return projectedRewards Projected rewards over 26-week period (before discount)
    function calculateAdvance(address user) external view returns (uint256 advanceAmount, uint256 projectedRewards) {
        uint256 earningPower = depositorTotalEarningPower[user];

        if (earningPower == 0) {
            return (0, 0);
        }

        projectedRewards = _calculateProjectedRewards(earningPower, COMMITMENT_DURATION);
        advanceAmount = (projectedRewards * (BPS_DENOMINATOR - DISCOUNT_BPS)) / BPS_DENOMINATOR;

        return (advanceAmount, projectedRewards);
    }

    /// @notice Calculates penalty for early withdrawal
    /// @dev Returns full outstanding if commitment ended, graduated penalty if during commitment
    /// @param user Address of the user
    /// @return penalty Penalty amount in reward tokens
    function getPenaltyForEarlyExit(address user) external view returns (uint256 penalty) {
        AdvanceInfo storage advance = advances[user];

        if (advance.outstanding == 0) {
            return 0;
        }

        if (advance.commitmentEnd <= block.timestamp) {
            // CRITICAL: After commitment ends, still owe full outstanding as penalty
            return advance.outstanding;
        }

        // During commitment: graduated penalty
        uint256 timeRemaining = advance.commitmentEnd - block.timestamp;
        return (advance.outstanding * timeRemaining) / COMMITMENT_DURATION;
    }

    /// @notice Requests an advance on future rewards
    /// @dev Fixed 26-week commitment, 5% discount, capped at 50% of projected rewards
    /// @return advanceAmount Amount of advance given to user
    function requestAdvance() external whenNotPaused nonReentrant returns (uint256 advanceAmount) {
        AdvanceInfo storage advance = advances[msg.sender];

        // 1. Check no existing outstanding advance
        if (advance.outstanding > 0) {
            revert OutstandingAdvanceExists();
        }

        // 2. Validate earning power
        uint256 earningPower = depositorTotalEarningPower[msg.sender];
        if (earningPower == 0) {
            revert NoEarningPower(msg.sender);
        }

        // 3. Calculate advance (fixed 26 weeks, 5% discount)
        uint256 projectedRewards = _calculateProjectedRewards(earningPower, COMMITMENT_DURATION);
        advanceAmount = (projectedRewards * (BPS_DENOMINATOR - DISCOUNT_BPS)) / BPS_DENOMINATOR;

        // 4. Per-user cap: max 50% of projected rewards
        uint256 maxPersonal = (projectedRewards * MAX_ADVANCE_PCT) / 100;
        if (advanceAmount > maxPersonal) {
            revert ExceedsPersonalCap(advanceAmount, maxPersonal);
        }

        // 5. Global solvency cap: max 10% of uncommitted rewards
        uint256 uncommitted = totalRewards - totalClaimedRewards;
        uint256 maxGlobal = (uncommitted * GLOBAL_CAP_PCT) / 100;
        if (totalOutstandingAdvances + advanceAmount > maxGlobal) {
            revert ExceedsGlobalCap(totalOutstandingAdvances + advanceAmount, maxGlobal);
        }

        // 6. Record advance
        advance.outstanding = advanceAmount.toUint96();
        advance.commitmentEnd = uint64(block.timestamp + COMMITMENT_DURATION);
        totalOutstandingAdvances += advanceAmount;

        // 7. Transfer advance to user
        SafeERC20.safeTransfer(REWARD_TOKEN, msg.sender, advanceAmount);

        emit AdvanceRequested(msg.sender, advanceAmount, advance.commitmentEnd);

        return advanceAmount;
    }

    // === Internal Functions ===

    /// @notice Calculates projected rewards for given earning power and duration
    /// @dev Internal helper for reward projection
    function _calculateProjectedRewards(uint256 earningPower, uint256 duration) internal view returns (uint256) {
        if (totalEarningPower == 0 || scaledRewardRate == 0) {
            return 0;
        }

        // Calculate user's share of rewards over commitment period
        // Formula: (userEP / totalEP) × rewardRate × duration
        uint256 userShare = (earningPower * SCALE_FACTOR) / totalEarningPower;
        uint256 rewardPerSecond = scaledRewardRate / SCALE_FACTOR;

        return (userShare * rewardPerSecond * duration) / SCALE_FACTOR;
    }

    /// @notice Calculates maximum allowed outstanding advances
    /// @dev Set to 10% of uncommitted rewards to prevent insolvency
    /// @return Maximum amount that can be advanced across all users
    function _getMaxOutstandingAdvances() internal view returns (uint256) {
        // Use uncommitted rewards (not lifetime totalRewards) to prevent over-advancing
        // Example: If totalRewards=1M but 900K already claimed, only 10K can be advanced (10% of 100K)
        uint256 uncommittedRewards = totalRewards - totalClaimedRewards;
        return uncommittedRewards / 10;
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
    ) internal virtual override whenNotPaused nonReentrant returns (uint256 netAmount) {
        // 1. Checkpoint rewards (from grandparent Staker logic)
        _checkpointGlobalReward();
        _checkpointReward(deposit);

        uint256 grossAmount = deposit.scaledUnclaimedRewardCheckpoint / SCALE_FACTOR;

        if (grossAmount == 0) {
            return 0;
        }

        // 2. Check for outstanding advances
        AdvanceInfo storage advance = advances[deposit.owner];
        uint256 repayment = 0;

        if (advance.outstanding > 0) {
            // 3. Calculate repayment (min of gross amount or outstanding)
            repayment = grossAmount > advance.outstanding ? advance.outstanding : grossAmount;

            // 4. Update advance state
            advance.outstanding -= repayment.toUint96();
            totalOutstandingAdvances -= repayment;

            emit AdvanceRepaid(deposit.owner, repayment, advance.outstanding);

            // 5. Clear commitment if fully repaid (allows early exit)
            if (advance.outstanding == 0) {
                delete advances[deposit.owner];
            }
        }

        // 6. Calculate net amount after repayment
        netAmount = grossAmount - repayment;

        // 7. Consume rewards and update state
        _consumeRewards(deposit, grossAmount);
        totalClaimedRewards += grossAmount; // Track gross, not net

        // 8. Transfer net amount to claimer
        if (netAmount > 0) {
            SafeERC20.safeTransfer(REWARD_TOKEN, _claimer, netAmount);
        }

        emit RewardClaimed(_depositId, _claimer, netAmount, deposit.earningPower);

        return netAmount;
    }

    /// @notice Overrides parent to apply penalties for early commitment breaks
    /// @dev Penalty is deducted from withdrawal amount and redistributed
    /// @param deposit Deposit storage reference
    /// @param _depositId Deposit identifier
    /// @param _amount Amount to withdraw
    function _withdraw(
        Deposit storage deposit,
        DepositIdentifier _depositId,
        uint256 _amount
    ) internal virtual override nonReentrant {
        require(_amount > 0, ZeroOperation());

        // 1. Check for outstanding advances
        AdvanceInfo storage advance = advances[deposit.owner];

        if (advance.outstanding > 0) {
            uint256 penalty = 0;

            if (advance.commitmentEnd > block.timestamp) {
                // 2. During commitment: Calculate graduated penalty
                uint256 timeRemaining = advance.commitmentEnd - block.timestamp;
                penalty = (advance.outstanding * timeRemaining) / COMMITMENT_DURATION;

                // 3. Apply penalty to withdrawal
                uint256 netWithdrawal = _amount > penalty ? _amount - penalty : 0;

                // 4. Redistribute penalty to stakers
                _redistributePenalty(penalty);

                emit CommitmentBroken(deposit.owner, penalty, timeRemaining);

                // 5. Clear commitment and outstanding advance
                totalOutstandingAdvances -= advance.outstanding;
                delete advances[deposit.owner];

                // 6. Execute withdrawal with net amount
                if (netWithdrawal > 0) {
                    super._withdraw(deposit, _depositId, netWithdrawal);
                }

                _revertIfMinimumStakeAmountNotMet(_depositId);
                return;
            } else {
                // CRITICAL: After commitment ends, must still pay full outstanding as penalty
                penalty = advance.outstanding;

                // 3. Apply penalty to withdrawal
                uint256 netWithdrawal = _amount > penalty ? _amount - penalty : 0;

                // 4. Redistribute penalty to stakers
                _redistributePenalty(penalty);

                emit CommitmentBroken(deposit.owner, penalty, 0);

                // 5. Clear outstanding advance
                totalOutstandingAdvances -= advance.outstanding;
                delete advances[deposit.owner];

                // 6. Execute withdrawal with net amount
                if (netWithdrawal > 0) {
                    super._withdraw(deposit, _depositId, netWithdrawal);
                }

                _revertIfMinimumStakeAmountNotMet(_depositId);
                return;
            }
        }

        // 7. Normal withdrawal (no outstanding debt)
        super._withdraw(deposit, _depositId, _amount);
        _revertIfMinimumStakeAmountNotMet(_depositId);
    }

    /// @notice Redistributes penalty to all stakers
    /// @dev Increases reward rate, effectively paying stakers from penalty
    ///
    /// Edge Cases:
    /// - If totalEarningPower == 0 (no stakers): Penalty remains in contract as surplus for future rewards
    /// - If rewardEndTime <= block.timestamp (reward period ended): Penalty remains as surplus
    /// - Both cases are acceptable as the penalty stays in the contract and isn't lost
    ///
    /// @param penalty Amount to redistribute
    function _redistributePenalty(uint256 penalty) internal {
        if (penalty == 0) return;

        // Only redistribute if there are active stakers and an active reward period
        if (totalEarningPower > 0 && rewardEndTime > block.timestamp) {
            uint256 timeRemaining = rewardEndTime - block.timestamp;
            uint256 additionalRate = (penalty * SCALE_FACTOR) / timeRemaining;
            scaledRewardRate += additionalRate;

            // Update total rewards to reflect penalty as new rewards
            totalRewards += penalty;
        }
        // Else: Penalty stays in contract as surplus (acceptable behavior)
    }

    /// @notice Validates contract has sufficient balance for rewards including outstanding advances
    /// @dev Overrides parent to account for advance liabilities
    ///
    /// Formula: required = uncommittedRewards + newRewards + outstandingAdvances
    ///
    /// Why add outstandingAdvances twice?
    /// - uncommittedRewards already includes the gross rewards that will repay advances
    /// - But we need EXTRA reserves because we can't access the advanced tokens (already given to users)
    /// - Think of it as: normal reserves + a separate "advance repayment escrow"
    ///
    /// Example:
    /// - uncommittedRewards = 100 (includes 10 for advance repayment)
    /// - outstandingAdvances = 10 (already paid to users)
    /// - required = 100 + 10 = 110 total in contract
    /// - When user claims: gets 0 (all goes to repayment), contract still has 100 left
    ///
    /// @param _amount New reward amount being added
    /// @return required Total balance required to cover all obligations
    function _validateAndGetRequiredBalance(uint256 _amount) internal view virtual override returns (uint256 required) {
        uint256 currentBalance = REWARD_TOKEN.balanceOf(address(this));

        // Calculate outstanding reward obligations
        uint256 carryOverAmount = totalRewards - totalClaimedRewards;

        // CRITICAL: Outstanding advances are liabilities requiring extra reserves
        required = carryOverAmount + _amount + totalOutstandingAdvances;

        if (currentBalance < required) {
            revert InsufficientRewardBalance(currentBalance, required);
        }

        return required;
    }
}
