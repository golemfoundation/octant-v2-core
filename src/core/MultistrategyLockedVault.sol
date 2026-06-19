// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MultistrategyLockedVault
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice A locked vault with custody-based rage quit mechanism and two-step cooldown period changes
 *
 * @dev This vault implements a secure custody system that prevents rage quit cooldown bypass attacks
 * and provides user protection through a two-step governance process for cooldown period changes.
 *
 * ## Custody Mechanism:
 *
 * 1. **Share Locking During Rage Quit:**
 *    - Users must initiate rage quit for a specific number of shares
 *    - Those shares are placed in custody and cannot be transferred
 *    - Locked shares are tracked separately from the user's transferable balance
 *    - Transfer restrictions prevent bypassing the cooldown period
 *    - Only one active rage quit per user (no multiple concurrent rage quits)
 *
 * 2. **Custody Lifecycle:**
 *    - **Initiation**: User specifies exact number of shares to lock for rage quit
 *    - **Cooldown**: Shares remain locked and non-transferable during cooldown period
 *    - **Unlock**: After cooldown, user can withdraw/redeem up to their custodied amount
 *    - **Withdrawal**: Users can make multiple withdrawals from the same custody
 *    - **Completion**: Custody is cleared when all locked shares are withdrawn
 *
 * 3. **Transfer Restrictions:**
 *    - Users cannot transfer locked shares to other addresses
 *    - Available shares = total balance - locked shares
 *    - Prevents rage quit cooldown bypass through share transfers
 *    - Check `custodyInfo(user).lockedShares` to calculate available balance for transfers
 *
 * 4. **Withdrawal Rules:**
 *    - Users can only withdraw shares if they have active custody
 *    - Withdrawal amount cannot exceed remaining custodied shares
 *    - Multiple partial withdrawals are allowed from the same custody
 *    - New rage quit required after custody is fully withdrawn
 *    - `maxWithdraw()` and `maxRedeem()` return 0 if no custody or still in cooldown
 *
 * 5. **Querying Custody State:**
 *    - `custodyInfo(user)`: Returns custody details (lockedShares, unlockTime)
 *    - Transferable shares = `balanceOf(user) - custodyInfo(user).lockedShares`
 *    - User can initiate rage quit if `custodyInfo(user).lockedShares == 0`
 *
 * ## Two-Step Cooldown Period Changes:
 *
 * 1. **Grace Period Protection:**
 *    - Governance proposes cooldown period changes with 14-day delay
 *    - Users can rage quit under current terms during grace period
 *    - Protects users from unfavorable governance decisions
 *
 * 2. **Change Process:**
 *    - **Propose**: Governance proposes new period, starts grace period
 *    - **Grace Period**: 14 days for users to exit under current terms
 *    - **Finalize**: Anyone can finalize change after grace period
 *    - **Cancel**: Governance can cancel during grace period
 *
 * 3. **User Protection:**
 *    - Users who rage quit before finalization use old cooldown period
 *    - Users who rage quit after finalization use new cooldown period
 *    - No retroactive application of cooldown changes
 *
 * ## Governance:
 *
 * - **Regen Governance**: Has control over rage quit cooldown period changes
 * - **Direct Transfer**: Governance can be transferred immediately (no 2-step process)
 * - **Access Control**: Only regen governance can propose/cancel cooldown changes
 *
 * ## Example Scenarios:
 *
 * **Scenario A - Basic Custody Flow:**
 * 1. User has 1000 shares, initiates rage quit for 500 shares
 * 2. 500 shares locked in custody, 500 shares remain transferable
 * 3. `custodyInfo(user).lockedShares` returns 500, user cannot initiate another rage quit
 * 4. After cooldown, user can withdraw up to 500 shares
 * 5. User withdraws 300 shares, 200 shares remain in custody
 * 6. User can later withdraw remaining 200 shares without new rage quit
 *
 * **Scenario B - Two-Step Cooldown Change:**
 * 1. Current cooldown: 7 days, governance proposes 14 days
 * 2. Grace period: Users have 14 days to rage quit under 7-day terms
 * 3. User A rage quits during grace period → uses 7-day cooldown
 * 4. Change finalized after grace period
 * 5. User B rage quits after finalization → uses 14-day cooldown
 *
 * **Scenario C - Querying Custody State:**
 * 1. User has 1000 shares, no active rage quit
 * 2. `custodyInfo(user).lockedShares` returns 0, transferable = 1000
 * 3. User can initiate rage quit (no active custody)
 * 4. User initiates rage quit for 400 shares
 * 5. `custodyInfo(user).lockedShares` returns 400, transferable = 600
 * 6. User cannot initiate another rage quit (already has active custody)
 */
contract MultistrategyLockedVault is MultistrategyVault, IMultistrategyLockedVault {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Mapping of user addresses to their custody information
    /// @dev Tracks locked shares and unlock timestamp for each user's rage quit
    ///      Only one active custody per user (no concurrent rage quits)
    mapping(address => CustodyInfo) public custodyInfo;

    /// @notice Address of regen governance controlling rage quit parameters
    /// @dev Can propose/cancel rage quit cooldown period changes
    ///      Set during initialize() to the roleManager address
    address public regenGovernance;

    /// @notice Current active cooldown period for rage quits
    /// @dev In seconds. Applied to new rage quits when initiateRageQuit() is called
    ///      Can be changed via two-step process (propose + finalize after grace period)
    uint256 public rageQuitCooldownPeriod;

    /// @notice Pending new cooldown period awaiting finalization
    /// @dev Set to 0 when no change is pending. Non-zero indicates active proposal
    ///      Requires RAGE_QUIT_COOLDOWN_CHANGE_DELAY to elapse before finalization
    uint256 public pendingRageQuitCooldownPeriod;

    /// @notice Timestamp when current cooldown period change was proposed
    /// @dev Unix timestamp in seconds. Used to calculate grace period expiration
    ///      Set to 0 when no change is pending
    uint256 public rageQuitCooldownPeriodChangeTimestamp;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Initial rage quit cooldown period set at deployment
    /// @dev 7 days in seconds. Applied until governance changes it
    uint256 private constant INITIAL_RAGE_QUIT_COOLDOWN_PERIOD = 7 days;

    /// @notice Minimum allowed rage quit cooldown period
    /// @dev 1 day in seconds. Prevents cooldown from being set too short
    uint256 private constant RANGE_MINIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 1 days;

    /// @notice Maximum allowed rage quit cooldown period
    /// @dev 30 days in seconds. Prevents cooldown from being set too long
    uint256 private constant RANGE_MAXIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 30 days;

    /// @notice Grace period delay for cooldown changes
    /// @dev 14 days in seconds. Users have this time to rage quit under old terms
    uint256 private constant RAGE_QUIT_COOLDOWN_CHANGE_DELAY = 14 days;

    /**
     * @dev Modifier to restrict access to regen governance only
     * @custom:modifier Reverts with NotRegenGovernance if caller is not regen governance
     */
    modifier onlyRegenGovernance() {
        if (msg.sender != regenGovernance) revert NotRegenGovernance();
        _;
    }

    /**
     * @notice Initializes the locked vault with custody mechanism
     * @dev Extends MultistrategyVault.initialize() with custody features
     *
     *      INITIALIZATION:
     *      1. Sets initial rage quit cooldown to INITIAL_RAGE_QUIT_COOLDOWN_PERIOD (7 days)
     *      2. Calls parent initialize() for standard vault setup
     *      3. Sets _roleManager as regenGovernance address
     *
     *      DUAL ROLE:
     *      - _roleManager becomes both roleManager AND regenGovernance
     *      - roleManager: Controls vault roles (from parent)
     *      - regenGovernance: Controls rage quit parameters (this contract)
     *
     * @param _asset Address of underlying asset token (cannot be zero)
     * @param _name Human-readable vault token name
     * @param _symbol Vault token symbol ticker
     * @param _roleManager Address for role management AND regen governance
     * @param _profitMaxUnlockTime Profit unlock duration in seconds (0-31556952)
     * @custom:security Can only be called once per deployment
     */
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager, // role manager is also the regen governance address
        uint256 _profitMaxUnlockTime
    ) public override(MultistrategyVault, IMultistrategyVault) {
        rageQuitCooldownPeriod = INITIAL_RAGE_QUIT_COOLDOWN_PERIOD;
        super.initialize(_asset, _name, _symbol, _roleManager, _profitMaxUnlockTime);
        regenGovernance = _roleManager;
    }

    /**
     * @notice Proposes a new rage quit cooldown period (step 1 of 2)
     * @dev Initiates two-step change process with grace period for user protection
     *
     *      VALIDATION:
     *      - Must be within valid range (1-30 days)
     *      - Must differ from current cooldown period
     *
     *      PROCESS:
     *      1. Validates new period is within allowed range
     *      2. Sets pendingRageQuitCooldownPeriod
     *      3. Records proposal timestamp
     *      4. Users have 14 days to rage quit under current terms
     *      5. After 14 days, anyone can finalize the change
     *
     * @param _rageQuitCooldownPeriod New cooldown period in seconds (86400-2592000, i.e., 1-30 days)
     * @custom:security Only callable by regenGovernance
     * @custom:security 14-day grace period protects users from unfavorable changes
     */
    function proposeRageQuitCooldownPeriodChange(uint256 _rageQuitCooldownPeriod) external onlyRegenGovernance {
        if (
            _rageQuitCooldownPeriod < RANGE_MINIMUM_RAGE_QUIT_COOLDOWN_PERIOD ||
            _rageQuitCooldownPeriod > RANGE_MAXIMUM_RAGE_QUIT_COOLDOWN_PERIOD
        ) {
            revert InvalidRageQuitCooldownPeriod();
        }

        if (_rageQuitCooldownPeriod == rageQuitCooldownPeriod) {
            revert InvalidRageQuitCooldownPeriod();
        }

        pendingRageQuitCooldownPeriod = _rageQuitCooldownPeriod;
        rageQuitCooldownPeriodChangeTimestamp = block.timestamp;

        uint256 effectiveTimestamp = block.timestamp + RAGE_QUIT_COOLDOWN_CHANGE_DELAY;
        emit PendingRageQuitCooldownPeriodChange(_rageQuitCooldownPeriod, effectiveTimestamp);
    }

    /**
     * @notice Finalizes the rage quit cooldown period change (step 2 of 2)
     * @dev Permissionless - anyone can call after grace period expires
     *
     *      REQUIREMENTS:
     *      - Must have pending change (pendingRageQuitCooldownPeriod != 0)
     *      - Grace period (14 days) must have elapsed
     *
     *      EFFECTS:
     *      - Updates rageQuitCooldownPeriod to pending value
     *      - Clears pending state
     *      - New rage quits use new cooldown period immediately
     */
    function finalizeRageQuitCooldownPeriodChange() external {
        if (pendingRageQuitCooldownPeriod == 0) {
            revert NoPendingRageQuitCooldownPeriodChange();
        }

        if (block.timestamp < rageQuitCooldownPeriodChangeTimestamp + RAGE_QUIT_COOLDOWN_CHANGE_DELAY) {
            revert RageQuitCooldownPeriodChangeDelayNotElapsed();
        }

        uint256 oldPeriod = rageQuitCooldownPeriod;
        rageQuitCooldownPeriod = pendingRageQuitCooldownPeriod;
        pendingRageQuitCooldownPeriod = 0;
        rageQuitCooldownPeriodChangeTimestamp = 0;

        emit RageQuitCooldownPeriodChanged(oldPeriod, rageQuitCooldownPeriod);
    }

    /**
     * @notice Cancels a pending rage quit cooldown period change
     * @dev Only callable during grace period (before finalization)
     *
     *      REQUIREMENTS:
     *      - Must have pending change
     *      - Grace period must NOT have elapsed yet
     *
     *      EFFECTS:
     *      - Clears all pending change state
     *      - Current cooldown period remains unchanged
     *
     * @custom:security Only callable by regenGovernance
     * @custom:security Cannot cancel after grace period expires
     */
    function cancelRageQuitCooldownPeriodChange() external onlyRegenGovernance {
        uint256 pending = pendingRageQuitCooldownPeriod;
        if (pending == 0) revert NoPendingRageQuitCooldownPeriodChange();

        uint256 proposedAt = rageQuitCooldownPeriodChangeTimestamp;
        if (block.timestamp >= proposedAt + RAGE_QUIT_COOLDOWN_CHANGE_DELAY) {
            revert RageQuitCooldownPeriodChangeDelayElapsed();
        }

        pendingRageQuitCooldownPeriod = 0;
        rageQuitCooldownPeriodChangeTimestamp = 0;

        emit RageQuitCooldownPeriodChangeCancelled(pending, proposedAt, block.timestamp);
    }

    /// @inheritdoc IMultistrategyLockedVault
    function initiateRageQuit(uint256 shares) external {
        if (shares == 0) revert InvalidShareAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientBalance();

        CustodyInfo storage custody = custodyInfo[msg.sender];
        if (custody.lockedShares > 0) revert RageQuitAlreadyInitiated();

        custody.lockedShares = shares;
        unchecked {
            custody.unlockTime = block.timestamp + rageQuitCooldownPeriod;
        }

        emit RageQuitInitiated(msg.sender, shares, custody.unlockTime);
    }

    /// @inheritdoc IMultistrategyLockedVault
    function cancelRageQuit() external {
        CustodyInfo storage custody = custodyInfo[msg.sender];
        if (custody.lockedShares == 0) revert NoActiveRageQuit();

        emit RageQuitCancelled(msg.sender, custody.lockedShares);
        delete custodyInfo[msg.sender];
    }

    // ============================================
    // WITHDRAW / REDEEM (custody-enforced)
    // ============================================

    /// @inheritdoc IMultistrategyVault
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        return _withdrawCustody(assets, receiver, owner, 0, _emptyStrategies());
    }

    /// @inheritdoc IMultistrategyVault
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata strategies
    ) public override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        return _withdrawCustody(assets, receiver, owner, maxLoss, strategies);
    }

    /// @inheritdoc IMultistrategyVault
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        return _redeemCustody(shares, receiver, owner, 10_000, _emptyStrategies());
    }

    /// @inheritdoc IMultistrategyVault
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata strategies
    ) public override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        return _redeemCustody(shares, receiver, owner, maxLoss, strategies);
    }

    // ============================================
    // GOVERNANCE
    // ============================================

    /// @inheritdoc IMultistrategyLockedVault
    function setRegenGovernance(address _regenGovernance) external override onlyRegenGovernance {
        if (_regenGovernance == address(0)) revert InvalidGovernanceAddress();
        address oldGovernance = regenGovernance;
        regenGovernance = _regenGovernance;
        emit RegenGovernanceChanged(oldGovernance, _regenGovernance);
    }

    // ============================================
    // MAX WITHDRAW / MAX REDEEM (custody-aware)
    // ============================================

    /// @inheritdoc IMultistrategyVault
    function maxWithdraw(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategies_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, maxLoss_, strategies_, false);
    }

    /// @inheritdoc IMultistrategyVault
    function maxWithdraw(
        address owner_,
        uint256 maxLoss_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, maxLoss_, _emptyStrategies(), false);
    }

    /// @inheritdoc IMultistrategyVault
    function maxWithdraw(
        address owner_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, 0, _emptyStrategies(), false);
    }

    /// @inheritdoc IMultistrategyVault
    function maxRedeem(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategies_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, maxLoss_, strategies_, true);
    }

    /// @inheritdoc IMultistrategyVault
    function maxRedeem(
        address owner_,
        uint256 maxLoss_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, maxLoss_, _emptyStrategies(), true);
    }

    /// @inheritdoc IMultistrategyVault
    function maxRedeem(
        address owner_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        return _maxCustody(owner_, MAX_BPS, _emptyStrategies(), true);
    }

    // ============================================
    // INTERNALS
    // ============================================

    function _withdrawCustody(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) internal returns (uint256) {
        uint256 shares = _convertToShares(assets, Rounding.ROUND_UP);
        _processCustodyWithdrawal(owner, shares);
        _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, strategies);
        return shares;
    }

    function _redeemCustody(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) internal returns (uint256) {
        _processCustodyWithdrawal(owner, shares);
        uint256 assets = _convertToAssets(shares, Rounding.ROUND_DOWN);
        return _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, strategies);
    }

    function _processCustodyWithdrawal(address owner, uint256 shares) internal {
        CustodyInfo storage custody = custodyInfo[owner];
        if (custody.lockedShares == 0) revert NoCustodiedShares();
        if (block.timestamp < custody.unlockTime) revert SharesStillLocked();
        if (shares > custody.lockedShares) revert ExceedsCustodiedAmount();
        unchecked {
            custody.lockedShares -= shares;
        }
        if (custody.lockedShares == 0) delete custodyInfo[owner];
    }

    function _transfer(address sender_, address receiver_, uint256 amount_) internal override {
        uint256 locked = custodyInfo[sender_].lockedShares;
        if (locked > 0) {
            uint256 available;
            unchecked {
                available = balanceOf(sender_) - locked;
            }
            if (amount_ > available) revert TransferExceedsAvailableShares();
        }
        super._transfer(sender_, receiver_, amount_);
    }

    /// @dev Shared custody-aware max logic. asShares=false returns assets, asShares=true returns shares.
    function _maxCustody(
        address owner_,
        uint256 maxLoss_,
        address[] memory strategies_,
        bool asShares
    ) internal view returns (uint256) {
        CustodyInfo storage c = custodyInfo[owner_];
        if (block.timestamp < c.unlockTime) return 0;
        uint256 mw = _max_withdraw(owner_, maxLoss_, strategies_);
        if (!asShares) return Math.min(mw, _convertToAssets(c.lockedShares, Rounding.ROUND_DOWN));
        return Math.min(Math.min(_convertToShares(mw, Rounding.ROUND_DOWN), balanceOf(owner_)), c.lockedShares);
    }
}
