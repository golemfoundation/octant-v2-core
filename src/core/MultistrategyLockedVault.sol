// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MultistrategyLockedVault
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
 *    - Use `getTransferableShares()` to check available balance for transfers
 *
 * 4. **Withdrawal Rules:**
 *    - Users can only withdraw shares if they have active custody
 *    - Withdrawal amount cannot exceed remaining custodied shares
 *    - Multiple partial withdrawals are allowed from the same custody
 *    - New rage quit required after custody is fully withdrawn
 *    - `maxWithdraw()` and `maxRedeem()` return 0 if no custody or still in cooldown
 *
 * 5. **Utility Functions:**
 *    - `getTransferableShares(user)`: Returns shares available for transfer
 *    - `getRageQuitableShares(user)`: Returns shares available for rage quit initiation
 *    - `custodyInfo(user)`: Returns custody details (locked shares, unlock time)
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
 * 3. `getTransferableShares(user)` returns 500, `getRageQuitableShares(user)` returns 0
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
 * **Scenario C - Utility Function Usage:**
 * 1. User has 1000 shares, no active rage quit
 * 2. `getTransferableShares(user)` returns 1000
 * 3. `getRageQuitableShares(user)` returns 1000
 * 4. User initiates rage quit for 400 shares
 * 5. `getTransferableShares(user)` returns 600
 * 6. `getRageQuitableShares(user)` returns 0 (already has active rage quit)
 */
contract MultistrategyLockedVault is MultistrategyVault, IMultistrategyLockedVault {
    // Mapping of user address to their custody info
    mapping(address => CustodyInfo) public custodyInfo;

    // Regen governance address
    address public regenGovernance;

    // Cooldown period for rage quit
    uint256 public rageQuitCooldownPeriod;

    // Two-step rage quit cooldown period change variables
    uint256 public pendingRageQuitCooldownPeriod;
    uint256 public rageQuitCooldownPeriodChangeTimestamp;

    // Constants
    uint256 public constant INITIAL_RAGE_QUIT_COOLDOWN_PERIOD = 7 days;
    uint256 public constant RANGE_MINIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 1 days;
    uint256 public constant RANGE_MAXIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 30 days;
    uint256 public constant RAGE_QUIT_COOLDOWN_CHANGE_DELAY = 14 days;

    /**
     * @dev Modifier to restrict access to regen governance only
     * @custom:modifier Reverts with NotRegenGovernance if caller is not regen governance
     */
    modifier onlyRegenGovernance() {
        if (msg.sender != regenGovernance) revert NotRegenGovernance();
        _;
    }

    /**
     * @notice Initialize the locked vault with custody mechanism
     * @param _asset Address of the underlying asset token
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _roleManager Address that manages vault roles (also becomes regen governance)
     * @param _profitMaxUnlockTime Maximum time for profit unlocking
     * @dev Initializes both the base MultistrategyVault and locked vault features:
     *      - Sets initial rage quit cooldown period to 7 days
     *      - Configures _roleManager as the regen governance address
     *      - Inherits all base vault initialization (roles, asset, etc.)
     * @custom:initializer Can only be called once during deployment
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
     * @notice Propose a new rage quit cooldown period
     * @param _rageQuitCooldownPeriod New cooldown period for rage quit
     * @dev Starts a grace period allowing users to rage quit under current terms
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
     * @notice Finalize the rage quit cooldown period change after the grace period
     * @dev Can only be called after the grace period has elapsed
     */
    function finalizeRageQuitCooldownPeriodChange() external onlyRegenGovernance {
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
     * @notice Cancel a pending rage quit cooldown period change
     * @dev Can only be called by governance during the grace period
     */
    function cancelRageQuitCooldownPeriodChange() external onlyRegenGovernance {
        if (pendingRageQuitCooldownPeriod == 0) {
            revert NoPendingRageQuitCooldownPeriodChange();
        }

        pendingRageQuitCooldownPeriod = 0;
        rageQuitCooldownPeriodChangeTimestamp = 0;

        emit PendingRageQuitCooldownPeriodChange(0, 0);
    }

    /**
     * @notice Get the pending rage quit cooldown period if any
     * @return The pending cooldown period (0 if none)
     */
    function getPendingRageQuitCooldownPeriod() external view returns (uint256) {
        return pendingRageQuitCooldownPeriod;
    }

    /**
     * @notice Get the timestamp when rage quit cooldown period change was initiated
     * @return Timestamp of the change initiation (0 if none)
     */
    function getRageQuitCooldownPeriodChangeTimestamp() external view returns (uint256) {
        return rageQuitCooldownPeriodChangeTimestamp;
    }

    /**
     * @notice Initiate rage quit process by placing specific shares in custody
     * @param shares Number of shares to lock for rage quit (must not exceed balance)
     * @dev Creates custody for specified shares with current cooldown period:
     *      - Shares are locked and become non-transferable
     *      - Custody tracks locked amount and unlock timestamp
     *      - Cannot initiate if user already has active custody
     *      - Uses current cooldown period (not pending changes)
     * @custom:security Prevents cooldown bypass through share transfers
     */
    function initiateRageQuit(uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidShareAmount();
        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < shares) revert InsufficientBalance();

        CustodyInfo storage custody = custodyInfo[msg.sender];

        // Check if user already has shares in custody
        if (custody.lockedShares > 0) {
            revert RageQuitAlreadyInitiated();
        }

        // Available shares = total balance - already locked shares
        uint256 availableShares = userBalance - custody.lockedShares;
        if (availableShares < shares) revert InsufficientAvailableShares();

        // Lock the shares in custody
        custody.lockedShares = shares;
        custody.unlockTime = block.timestamp + rageQuitCooldownPeriod;

        emit RageQuitInitiated(msg.sender, shares, custody.unlockTime);
    }

    /**
     * @notice Override withdrawal functions to handle custodied shares
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata strategiesArray
    ) public override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        uint256 shares = _convertToShares(assets, Rounding.ROUND_UP);
        _processCustodyWithdrawal(owner, shares);
        _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, strategiesArray);
        return shares;
    }

    /**
     * @notice Override redeem function to handle custodied shares
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata strategiesArray
    ) public override(MultistrategyVault, IMultistrategyVault) nonReentrant returns (uint256) {
        _processCustodyWithdrawal(owner, shares);
        uint256 assets = _convertToAssets(shares, Rounding.ROUND_DOWN);
        // Always return the actual amount of assets withdrawn.
        return _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, strategiesArray);
    }

    /**
     * @notice Set the regen governance address that can manage rage quit parameters
     * @param _regenGovernance New address to become regen governance
     * @dev Regen governance has exclusive control over:
     *      - Proposing rage quit cooldown period changes
     *      - Cancelling pending cooldown period changes
     * @custom:governance Only current regen governance can call this function
     */
    function setRegenGovernance(address _regenGovernance) external override onlyRegenGovernance {
        if (_regenGovernance == address(0)) revert InvalidGovernanceAddress();

        address oldGovernance = regenGovernance;
        regenGovernance = _regenGovernance;
        emit RegenGovernanceChanged(oldGovernance, _regenGovernance);
    }

    /**
     * @notice Process withdrawal of shares from custody during withdraw/redeem operations
     * @param owner Address of the share owner attempting withdrawal
     * @param shares Number of shares being withdrawn/redeemed
     * @dev Internal function that enforces custody withdrawal rules:
     *      - Owner must have active custody (lockedShares > 0)
     *      - Shares must still be locked (current time < unlockTime)
     *      - Withdrawal amount cannot exceed remaining custodied shares
     *      - Updates custody state by reducing locked shares
     *      - Clears custody when all locked shares are withdrawn
     * @custom:security Prevents unauthorized withdrawals and custody bypass
     */
    function _processCustodyWithdrawal(address owner, uint256 shares) internal {
        CustodyInfo storage custody = custodyInfo[owner];

        // Check if there are custodied shares
        if (custody.lockedShares == 0) {
            revert NoCustodiedShares();
        }

        // Ensure cooldown period has passed
        if (block.timestamp < custody.unlockTime) {
            revert SharesStillLocked();
        }

        // Ensure user has sufficient balance
        uint256 userBalance = balanceOf(owner);
        if (userBalance < shares) {
            revert InsufficientBalance();
        }

        // Can only withdraw up to locked amount
        if (shares > custody.lockedShares) {
            revert ExceedsCustodiedAmount();
        }

        // Reduce locked shares by withdrawn amount
        custody.lockedShares -= shares;

        // If all custodied shares withdrawn, reset custody info
        if (custody.lockedShares == 0) {
            delete custodyInfo[owner];
        }
    }

    /**
     * @notice Override ERC20 transfer to enforce custody transfer restrictions
     * @param sender_ Address attempting to send shares
     * @param receiver_ Address that would receive shares
     * @param amount_ Number of shares being transferred
     * @dev Implements custody-based transfer restrictions:
     *      - Calculates available shares (total balance - locked shares)
     *      - Prevents transfer if amount exceeds available shares
     *      - Allows normal transfers for non-custodied shares
     *      - Critical security feature preventing rage quit cooldown bypass
     * @custom:security Prevents users from bypassing cooldown by transferring locked shares
     */
    function _transfer(address sender_, address receiver_, uint256 amount_) internal override {
        // Check if sender has locked shares that would prevent this transfer
        CustodyInfo memory custody = custodyInfo[sender_];

        if (custody.lockedShares > 0) {
            uint256 senderBalance = balanceOf(sender_);
            uint256 availableShares = senderBalance - custody.lockedShares;

            // Revert if trying to transfer more than available shares
            if (amount_ > availableShares) {
                revert TransferExceedsAvailableShares();
            }
        }

        // Call parent implementation
        super._transfer(sender_, receiver_, amount_);
    }


    /**
     * @notice Cancel rage quit and unlock custodied shares
     */
    function cancelRageQuit() external {
        CustodyInfo storage custody = custodyInfo[msg.sender];

        if (custody.lockedShares == 0) {
            revert NoActiveRageQuit();
        }

        // Clear custody info
        uint256 freedShares = custody.lockedShares;
        delete custodyInfo[msg.sender];

        emit RageQuitCancelled(msg.sender, freedShares);
    }

    /**
     * @notice Get the maximum amount of assets that can be withdrawn by an owner
     * @param owner_ The address that owns the shares
     * @param maxLoss_ Custom max_loss if any
     * @param strategiesArray_ Custom strategies queue if any
     * @return The maximum amount of assets that can be withdrawn
     * @dev This override accounts for custody constraints - returns 0 if:
     *      - Custody is still in cooldown period
     *      - Otherwise returns min of parent calculation and custodied shares in asset terms
     */
    function maxWithdraw(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        CustodyInfo memory custody = custodyInfo[owner_];
        if (block.timestamp < custody.unlockTime) {
            return 0;
        }

        // Get the max from parent implementation
        uint256 parentMax = _maxWithdraw(owner_, maxLoss_, strategiesArray_);

        // Convert custodied shares to assets
        uint256 custodyAssets = _convertToAssets(custody.lockedShares, Rounding.ROUND_DOWN);

        // Return minimum of parent max and custody limit
        return Math.min(parentMax, custodyAssets);
    }

    /**
     * @notice Get the maximum amount of shares that can be redeemed by an owner
     * @param owner_ The address that owns the shares
     * @param maxLoss_ Custom max_loss if any
     * @param strategiesArray_ Custom strategies queue if any
     * @return The maximum amount of shares that can be redeemed
     * @dev This override accounts for custody constraints - returns 0 if:
     *      - Custody is still in cooldown period
     *      - Otherwise returns min of balance and custodied shares
     */
    function maxRedeem(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) external view override(MultistrategyVault, IMultistrategyVault) returns (uint256) {
        CustodyInfo memory custody = custodyInfo[owner_];

        if (block.timestamp < custody.unlockTime) {
            return 0;
        }

        // Get max shares from parent calculation
        uint256 parentMax = Math.min(
            _convertToShares(_maxWithdraw(owner_, maxLoss_, strategiesArray_), Rounding.ROUND_DOWN),
            balanceOf(owner_)
        );

        // Get custody info to determine locked shares
        uint256 lockedShares = custody.lockedShares;

        // Return minimum of parent max and custody limit
        return Math.min(parentMax, lockedShares);
    }

    /**
     * @notice Get the amount of shares that can be transferred by a user
     * @param user The address to check transferable shares for
     * @return The amount of shares available for transfer (not locked in custody)
     * @dev Returns total balance minus shares currently locked in custody
     */
    function getTransferableShares(address user) external view returns (uint256) {
        uint256 totalShares = balanceOf(user);
        uint256 lockedShares = custodyInfo[user].lockedShares;
        return totalShares - lockedShares;
    }

    /**
     * @notice Get the amount of shares available for rage quit initiation
     * @param user The address to check rage quitable shares for
     * @return The amount of shares available for initiating rage quit
     * @dev Returns 0 if user already has active custody, otherwise returns full balance
     */
    function getRageQuitableShares(address user) external view returns (uint256) {
        // If user already has active custody, they cannot initiate new rage quit
        if (custodyInfo[user].lockedShares > 0) {
            return 0;
        }
        // Otherwise, they can rage quit all their shares
        return balanceOf(user);
    }
}
