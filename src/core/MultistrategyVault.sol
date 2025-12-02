/* solhint-disable code-complexity */
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IDepositLimitModule } from "src/core/interfaces/IDepositLimitModule.sol";
import { IWithdrawLimitModule } from "src/core/interfaces/IWithdrawLimitModule.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { IAccountant } from "src/interfaces/IAccountant.sol";
import { IMultistrategyVaultFactory } from "src/factories/interfaces/IMultistrategyVaultFactory.sol";
import { DebtManagementLib } from "src/core/libs/DebtManagementLib.sol";

/**
 * @notice
 *   This MultistrategyVault is based on the original VaultV3.vy Vyper implementation
 *   that has been ported to Solidity. It is designed as a non-opinionated system
 *   to distribute funds of depositors for a specific `asset` into different
 *   opportunities (aka Strategies) and manage accounting in a robust way.
 *
 *   Depositors receive shares (aka vaults tokens) proportional to their deposit amount.
 *   Vault tokens are yield-bearing and can be redeemed at any time to get back deposit
 *   plus any yield generated.
 *
 *   Addresses that are given different permissioned roles by the `roleManager`
 *   are then able to allocate funds as they best see fit to different strategies
 *   and adjust the strategies and allocations as needed, as well as reporting realized
 *   profits or losses.
 *
 *   Strategies are any ERC-4626 compliant contracts that use the same underlying `asset`
 *   as the vault. The vault provides no assurances as to the safety of any strategy
 *   and it is the responsibility of those that hold the corresponding roles to choose
 *   and fund strategies that best fit their desired specifications.
 *
 *   Those holding vault tokens are able to redeem the tokens for the corresponding
 *   amount of underlying asset based on any reported profits or losses since their
 *   initial deposit.
 *
 *   The vault is built to be customized by the management to be able to fit their
 *   specific desired needs. Including the customization of strategies, accountants,
 *   ownership etc.
 */
contract MultistrategyVault is IMultistrategyVault {
    // CONSTANTS
    // The max length the withdrawal queue can be.
    uint256 public constant MAX_QUEUE = 10;
    // 100% in Basis Points.
    uint256 public constant MAX_BPS = 10_000;
    // Extended for profit locking calculations.
    uint256 public constant MAX_BPS_EXTENDED = 1_000_000_000_000;
    // The version of this vault.
    string public constant API_VERSION = "3.0.4";

    // EIP-712 constants
    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PERMIT_TYPE_HASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // STORAGE
    // Underlying token used by the vault.
    address public override asset;
    // Based off the `asset` decimals.
    uint8 public override decimals;
    // Deployer contract used to retrieve the protocol fee config.
    address private _factory;

    // HashMap that records all the strategies that are allowed to receive assets from the vault.
    mapping(address => StrategyParams) internal _strategies;

    // The current default withdrawal queue.
    address[] internal _defaultQueue;
    // Should the vault use the defaultQueue regardless whats passed in.
    bool public useDefaultQueue;
    // Should the vault automatically allocate funds to the first strategy in queue.
    bool public autoAllocate;

    /// ACCOUNTING ///
    // ERC20 - amount of shares per account
    mapping(address => uint256) private _balanceOf;
    // ERC20 - owner -> (spender -> amount)
    mapping(address => mapping(address => uint256)) public override allowance;
    // Total amount of shares that are currently minted including those locked.
    uint256 private _totalSupplyValue;
    // Total amount of assets that has been deposited in strategies.
    uint256 private _totalDebt;
    // Current assets held in the vault contract. Replacing balanceOf(this) to avoid price_per_share manipulation.
    uint256 private _totalIdle;
    // Minimum amount of assets that should be kept in the vault contract to allow for fast, cheap redeems.
    uint256 public override minimumTotalIdle;
    // Maximum amount of tokens that the vault can accept. If totalAssets > depositLimit, deposits will revert.
    uint256 public override depositLimit;

    /// PERIPHERY ///
    // Contract that charges fees and can give refunds.
    address public override accountant;
    // Contract to control the deposit limit.
    address public override depositLimitModule;
    // Contract to control the withdraw limit.
    address public override withdrawLimitModule;

    /// ROLES ///
    // HashMap mapping addresses to their roles
    mapping(address => uint256) public roles;
    // Address that can add and remove roles to addresses.
    address public override roleManager;
    // Temporary variable to store the address of the next roleManager until the role is accepted.
    address public override futureRoleManager;

    // ERC20 - name of the vaults token.
    string public override name;
    // ERC20 - symbol of the vaults token.
    string public override symbol;

    // State of the vault - if set to true, only withdrawals will be available. It can't be reverted.
    bool private _shutdown;
    // The amount of time profits will unlock over.
    uint256 private _profitMaxUnlockTime;
    // The timestamp of when the current unlocking period ends.
    uint256 private _fullProfitUnlockDate;
    // The per second rate at which profit will unlock.
    uint256 private _profitUnlockingRate;
    // Last timestamp of the most recent profitable report.
    uint256 private _lastProfitUpdate;

    // `nonces` track `permit` approvals with signature.
    mapping(address => uint256) public override nonces;

    /// MODIFIERS ///

    // Re-entrancy guard
    bool private _locked;

    modifier nonReentrant() {
        require(!_locked, Reentrancy());
        _locked = true;
        _;
        _locked = false;
    }

    /// CONSTRUCTOR ///
    constructor() {
        // Set `asset` so it cannot be re-initialized.
        asset = address(this);
    }

    /**
     * @notice Initialize a new vault. Sets the asset, name, symbol, and role manager.
     * @param asset_ The address of the asset that the vault will accept.
     * @param name_ The name of the vault token.
     * @param symbol_ The symbol of the vault token.
     * @param roleManager_ The address that can add and remove roles to addresses
     * @param profitMaxUnlockTime_ The amount of time that the profit will be locked for
     */
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address roleManager_,
        uint256 profitMaxUnlockTime_
    ) public virtual override {
        require(asset == address(0), AlreadyInitialized());
        require(asset_ != address(0), ZeroAddress());
        require(roleManager_ != address(0), ZeroAddress());

        asset = asset_;
        // Get the decimals for the vault to use.
        decimals = IERC20Metadata(asset_).decimals();

        // Set the factory as the deployer address.
        _factory = msg.sender;

        // Must be less than one year for report cycles
        require(profitMaxUnlockTime_ <= 31_556_952, ProfitUnlockTimeTooLong());
        _profitMaxUnlockTime = profitMaxUnlockTime_;

        name = name_;
        symbol = symbol_;
        roleManager = roleManager_;
    }

    // SETTERS //
    /**
     * @notice Change the vault name.
     * @dev Can only be called by the Role Manager.
     * @param name_ The new name for the vault.
     */
    function setName(string memory name_) external override {
        require(msg.sender == roleManager, NotAllowed());
        name = name_;
    }

    /**
     * @notice Change the vault symbol.
     * @dev Can only be called by the Role Manager.
     * @param symbol_ The new name for the vault.
     */
    function setSymbol(string memory symbol_) external override {
        require(msg.sender == roleManager, NotAllowed());
        symbol = symbol_;
    }

    /**
     * @notice Set the new accountant address.
     * @param newAccountant_ The new accountant address.
     */
    function setAccountant(address newAccountant_) external override {
        _enforceRole(msg.sender, Roles.ACCOUNTANT_MANAGER);
        accountant = newAccountant_;

        emit UpdateAccountant(newAccountant_);
    }

    /**
     * @notice Set the new default queue array (max 10 strategies)
     * @dev Will check each strategy to make sure it is active. But will not
     *      check that the same strategy is not added twice. maxRedeem and maxWithdraw
     *      return values may be inaccurate if a strategy is added twice.
     * @param newDefaultQueue_ The new default queue array.
     */
    function setDefaultQueue(address[] calldata newDefaultQueue_) external override {
        _enforceRole(msg.sender, Roles.QUEUE_MANAGER);
        require(newDefaultQueue_.length <= MAX_QUEUE, MaxQueueLengthReached());

        // Make sure every strategy in the new queue is active.
        for (uint256 i = 0; i < newDefaultQueue_.length; i++) {
            require(_strategies[newDefaultQueue_[i]].activation != 0, InactiveStrategy());
        }

        // Save the new queue.
        _defaultQueue = newDefaultQueue_;

        emit UpdateDefaultQueue(newDefaultQueue_);
    }

    /**
     * @notice Set a new value for `useDefaultQueue`.
     * @dev If set `True` the default queue will always be
     *      used no matter whats passed in.
     * @param useDefaultQueue_ new value.
     */
    function setUseDefaultQueue(bool useDefaultQueue_) external override {
        _enforceRole(msg.sender, Roles.QUEUE_MANAGER);
        useDefaultQueue = useDefaultQueue_;

        emit UpdateUseDefaultQueue(useDefaultQueue_);
    }

    /**
     * @notice Set new value for `autoAllocate`
     * @dev If `True` every {deposit} and {mint} call will
     *      try and allocate the deposited amount to the strategy
     *      at position 0 of the `defaultQueue` atomically.
     * NOTE: An empty `defaultQueue` will cause deposits to fail.
     * @param autoAllocate_ new value.
     */
    function setAutoAllocate(bool autoAllocate_) external override {
        _enforceRole(msg.sender, Roles.DEBT_MANAGER);
        autoAllocate = autoAllocate_;

        emit UpdateAutoAllocate(autoAllocate_);
    }

    /**
     * @notice Set the new deposit limit.
     * @dev Can not be changed if a depositLimitModule
     *      is set unless the override flag is true or if shutdown.
     * @param depositLimit_ The new deposit limit.
     * @param shouldOverride_ If a `depositLimitModule` already set should be overridden.
     */
    function setDepositLimit(uint256 depositLimit_, bool shouldOverride_) external override {
        require(_shutdown == false, VaultShutdown());
        _enforceRole(msg.sender, Roles.DEPOSIT_LIMIT_MANAGER);

        // If we are overriding the deposit limit module.
        if (shouldOverride_) {
            // Make sure it is set to address 0 if not already.
            if (depositLimitModule != address(0)) {
                depositLimitModule = address(0);
                emit UpdateDepositLimitModule(address(0));
            }
        } else {
            // Make sure the depositLimitModule has been set to address(0).
            require(depositLimitModule == address(0), UsingModule());
        }

        depositLimit = depositLimit_;

        emit UpdateDepositLimit(depositLimit_);
    }

    /**
     * @notice Set a contract to handle the deposit limit.
     * @dev The default `depositLimit` will need to be set to
     *      max uint256 since the module will override it or the override flag
     *      must be set to true to set it to max in 1 tx.
     * @param depositLimitModule_ Address of the module.
     * @param shouldOverride_ If a `depositLimit` already set should be overridden.
     */
    function setDepositLimitModule(address depositLimitModule_, bool shouldOverride_) external override {
        require(_shutdown == false, VaultShutdown());
        _enforceRole(msg.sender, Roles.DEPOSIT_LIMIT_MANAGER);

        // If we are overriding the deposit limit
        if (shouldOverride_) {
            // Make sure it is max uint256 if not already.
            if (depositLimit != type(uint256).max) {
                depositLimit = type(uint256).max;
                emit UpdateDepositLimit(type(uint256).max);
            }
        } else {
            // Make sure the deposit_limit has been set to uint max.
            require(depositLimit == type(uint256).max, UsingDepositLimit());
        }

        depositLimitModule = depositLimitModule_;

        emit UpdateDepositLimitModule(depositLimitModule_);
    }

    /**
     * @notice Set a contract to handle the withdraw limit.
     * @dev This will override the default `maxWithdraw`.
     * @param withdrawLimitModule_ Address of the module.
     */
    function setWithdrawLimitModule(address withdrawLimitModule_) external override {
        _enforceRole(msg.sender, Roles.WITHDRAW_LIMIT_MANAGER);

        withdrawLimitModule = withdrawLimitModule_;

        emit UpdateWithdrawLimitModule(withdrawLimitModule_);
    }

    /**
     * @notice Set the new minimum total idle.
     * @param minimumTotalIdle_ The new minimum total idle.
     */
    function setMinimumTotalIdle(uint256 minimumTotalIdle_) external override {
        _enforceRole(msg.sender, Roles.MINIMUM_IDLE_MANAGER);
        minimumTotalIdle = minimumTotalIdle_;

        emit UpdateMinimumTotalIdle(minimumTotalIdle_);
    }

    /**
     * @notice Set the new profit max unlock time.
     * @dev The time is denominated in seconds and must be less than 1 year.
     *      We only need to update locking period if setting to 0,
     *      since the current period will use the old rate and on the next
     *      report it will be reset with the new unlocking time.
     *
     *      Setting to 0 will cause any currently locked profit to instantly
     *      unlock and an immediate increase in the vaults Price Per Share.
     *
     * @param newProfitMaxUnlockTime_ The new profit max unlock time.
     */
    function setProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime_) external override {
        _enforceRole(msg.sender, Roles.PROFIT_UNLOCK_MANAGER);
        // Must be less than one year for report cycles
        require(newProfitMaxUnlockTime_ <= 31_556_952, ProfitUnlockTimeTooLong());

        // If setting to 0 we need to reset any locked values.
        if (newProfitMaxUnlockTime_ == 0) {
            uint256 shareBalance = _balanceOf[address(this)];
            if (shareBalance > 0) {
                // Burn any shares the vault still has.
                _burnShares(shareBalance, address(this));
            }

            // Reset unlocking variables to 0.
            _profitUnlockingRate = 0;
            _fullProfitUnlockDate = 0;
        }

        _profitMaxUnlockTime = newProfitMaxUnlockTime_;

        emit UpdateProfitMaxUnlockTime(newProfitMaxUnlockTime_);
    }

    // ROLE MANAGEMENT //

    /**
     * @dev Enforces that the sender has the required role
     */
    function _enforceRole(address account_, Roles role_) internal view {
        // Check bit at role position
        require(roles[account_] & (1 << uint256(role_)) != 0, NotAllowed());
    }

    /**
     * @notice Set the roles for an account.
     * @dev This will fully override an accounts current roles
     *      so it should include all roles the account should hold.
     * @param account_ The account to set the role for.
     * @param rolesBitmask_ The roles the account should hold.
     */
    function setRole(address account_, uint256 rolesBitmask_) external override {
        require(msg.sender == roleManager, NotAllowed());
        // Store the enum value directly
        roles[account_] = rolesBitmask_;
        emit RoleSet(account_, rolesBitmask_);
    }

    /**
     * @notice Add a new role/s to an address.
     * @dev This will add a new role/s to the account
     *      without effecting any of the previously held roles.
     * @param account_ The account to add a role to.
     * @param role_ The new role/s to add to account.
     */
    function addRole(address account_, Roles role_) external override {
        require(msg.sender == roleManager, NotAllowed());
        // Add the role with a bitwise OR
        roles[account_] = roles[account_] | (1 << uint256(role_));
        emit RoleSet(account_, roles[account_]);
    }

    /**
     * @notice Remove a role/s from an account.
     * @dev This will leave all other roles for the
     *      account unchanged.
     * @param account_ The account to remove a Role/s from.
     * @param role_ The Role/s to remove.
     */
    function removeRole(address account_, Roles role_) external override {
        require(msg.sender == roleManager, NotAllowed());

        // Bitwise AND with NOT to remove the role
        roles[account_] = roles[account_] & ~(1 << uint256(role_));
        emit RoleSet(account_, roles[account_]);
    }

    /**
     * @notice Step 1 of 2 in order to transfer the
     *      role manager to a new address. This will set
     *      the futureRoleManager. Which will then
     *      need to be accepted by the new manager.
     * @param roleManager_ The new role manager address.
     */
    function transferRoleManager(address roleManager_) external override {
        require(msg.sender == roleManager, NotAllowed());
        futureRoleManager = roleManager_;

        emit UpdateFutureRoleManager(roleManager_);
    }

    /**
     * @notice Accept the role manager transfer.
     */
    function acceptRoleManager() external override {
        require(msg.sender == futureRoleManager, NotFutureRoleManager());
        roleManager = msg.sender;
        futureRoleManager = address(0);

        emit UpdateRoleManager(msg.sender);
    }

    // VAULT STATUS VIEWS

    /**
     * @notice Get if the vault is shutdown.
     * @return Bool representing the shutdown status
     */
    function isShutdown() external view override returns (bool) {
        return _shutdown;
    }

    /**
     * @notice Get the amount of shares that have been unlocked.
     * @return The amount of shares that have been unlocked.
     */
    function unlockedShares() external view override returns (uint256) {
        return _unlockedShares();
    }

    /**
     * @notice Get the price per share (pps) of the vault.
     * @dev This value offers limited precision. Integrations that require
     *      exact precision should use convertToAssets or convertToShares instead.
     * @return The price per share.
     */
    function pricePerShare() external view override returns (uint256) {
        return _convertToAssets(10 ** uint256(decimals), Rounding.ROUND_DOWN);
    }

    /**
     * @notice Get the default queue.
     * @return The default queue.
     */
    function getDefaultQueue() external view returns (address[] memory) {
        return _defaultQueue;
    }

    /// REPORTING MANAGEMENT ///

    function processReport(address strategy_) external nonReentrant returns (uint256, uint256) {
        _enforceRole(msg.sender, Roles.REPORTING_MANAGER);

        // slither-disable-next-line uninitialized-local
        ProcessReportLocalVars memory vars;

        if (strategy_ != address(this)) {
            // Make sure we have a valid strategy.
            require(_strategies[strategy_].activation != 0, InactiveStrategy());

            // Vault assesses profits using 4626 compliant interface.
            // NOTE: It is important that a strategies `convertToAssets` implementation
            // cannot be manipulated or else the vault could report incorrect gains/losses.
            uint256 strategyShares = IERC4626Payable(strategy_).balanceOf(address(this));
            // How much the vaults position is worth.
            vars.strategyTotalAssets = IERC4626Payable(strategy_).convertToAssets(strategyShares);
            // How much the vault had deposited to the strategy.
            vars.currentDebt = _strategies[strategy_].currentDebt;
        } else {
            // Accrue any airdropped `asset` into `total_idle`
            vars.strategyTotalAssets = IERC20(asset).balanceOf(address(this));
            vars.currentDebt = _totalIdle;
        }

        /// Assess Gain or Loss ///

        // Compare reported assets vs. the current debt.
        if (vars.strategyTotalAssets > vars.currentDebt) {
            // We have a gain.
            vars.gain = vars.strategyTotalAssets - vars.currentDebt;
        } else {
            // We have a loss.
            vars.loss = vars.currentDebt - vars.strategyTotalAssets;
        }

        /// Assess Fees and Refunds ///

        // If accountant is not set, fees and refunds remain unchanged.
        vars.accountant = accountant;
        if (vars.accountant != address(0)) {
            (vars.totalFees, vars.totalRefunds) = IAccountant(vars.accountant).report(strategy_, vars.gain, vars.loss);

            if (vars.totalRefunds > 0) {
                // Make sure we have enough approval and enough asset to pull.
                vars.totalRefunds = Math.min(
                    vars.totalRefunds,
                    Math.min(
                        IERC20(asset).balanceOf(vars.accountant),
                        IERC20(asset).allowance(vars.accountant, address(this))
                    )
                );
            }
        }

        // Only need to burn shares if there is a loss or fees.
        if (vars.loss + vars.totalFees > 0) {
            // The amount of shares we will want to burn to offset losses and fees.
            vars.sharesToBurn = _convertToShares(vars.loss + vars.totalFees, Rounding.ROUND_UP);

            // If we have fees then get the proportional amount of shares to issue.
            if (vars.totalFees > 0) {
                // Get the total amount shares to issue for the fees.
                vars.totalFeesShares = (vars.sharesToBurn * vars.totalFees) / (vars.loss + vars.totalFees);

                // Get the protocol fee config for this vault.
                (vars.protocolFeeBps, vars.protocolFeeRecipient) = IMultistrategyVaultFactory(_factory)
                    .protocolFeeConfig(address(this));

                // If there is a protocol fee.
                if (vars.protocolFeeBps > 0) {
                    // Get the percent of fees to go to protocol fees.
                    vars.protocolFeesShares = (vars.totalFeesShares * uint256(vars.protocolFeeBps)) / MAX_BPS;
                }
            }
        }

        // Shares to lock is any amount that would otherwise increase the vaults PPS.
        vars.profitMaxUnlockTimeVar = _profitMaxUnlockTime;
        // Get the amount we will lock to avoid a PPS increase.
        if (vars.gain + vars.totalRefunds > 0 && vars.profitMaxUnlockTimeVar != 0) {
            vars.sharesToLock = _convertToShares(vars.gain + vars.totalRefunds, Rounding.ROUND_DOWN);
        }

        // The total current supply including locked shares.
        vars.currentTotalSupply = _totalSupplyValue;
        // The total shares the vault currently owns. Both locked and unlocked.
        vars.totalLockedShares = _balanceOf[address(this)];
        // Get the desired end amount of shares after all accounting.
        vars.endingSupply = vars.currentTotalSupply + vars.sharesToLock - vars.sharesToBurn - _unlockedShares();

        // If we will end with more shares than we have now.
        if (vars.endingSupply > vars.currentTotalSupply) {
            // Issue the difference.
            _issueShares(vars.endingSupply - vars.currentTotalSupply, address(this));
        }
        // Else we need to burn shares.
        else if (vars.currentTotalSupply > vars.endingSupply) {
            // Can't burn more than the vault owns.
            vars.toBurn = Math.min(vars.currentTotalSupply - vars.endingSupply, vars.totalLockedShares);
            _burnShares(vars.toBurn, address(this));
        }

        // Adjust the amount to lock for this period.
        if (vars.sharesToLock > vars.sharesToBurn) {
            // Don't lock fees or losses.
            vars.sharesToLock = vars.sharesToLock - vars.sharesToBurn;
        } else {
            vars.sharesToLock = 0;
        }

        // Pull refunds
        if (vars.totalRefunds > 0) {
            // Transfer the refunded amount of asset to the vault.
            _safeTransferFrom(asset, vars.accountant, address(this), vars.totalRefunds);
            // Update storage to increase total assets.
            _totalIdle += vars.totalRefunds;
        }

        // Record any reported gains.
        if (vars.gain > 0) {
            // NOTE: this will increase total_assets
            vars.currentDebt = vars.currentDebt + vars.gain;
            if (strategy_ != address(this)) {
                _strategies[strategy_].currentDebt = vars.currentDebt;
                _totalDebt += vars.gain;
            } else {
                // Add in any refunds since it is now idle.
                vars.currentDebt = vars.currentDebt + vars.totalRefunds;
                _totalIdle = vars.currentDebt;
            }
        }
        // Or record any reported loss
        else if (vars.loss > 0) {
            vars.currentDebt = vars.currentDebt - vars.loss;
            if (strategy_ != address(this)) {
                _strategies[strategy_].currentDebt = vars.currentDebt;
                _totalDebt -= vars.loss;
            } else {
                // Add in any refunds since it is now idle.
                vars.currentDebt = vars.currentDebt + vars.totalRefunds;
                _totalIdle = vars.currentDebt;
            }
        }

        // Issue shares for fees that were calculated above if applicable.
        if (vars.totalFeesShares > 0) {
            // Accountant fees are (total_fees - protocol_fees).
            _issueShares(vars.totalFeesShares - vars.protocolFeesShares, vars.accountant);

            // If we also have protocol fees.
            if (vars.protocolFeesShares > 0) {
                _issueShares(vars.protocolFeesShares, vars.protocolFeeRecipient);
            }
        }

        // Update unlocking rate and time to fully unlocked.
        vars.totalLockedShares = _balanceOf[address(this)];
        if (vars.totalLockedShares > 0) {
            vars.fullProfitUnlockDateVar = _fullProfitUnlockDate;
            // Check if we need to account for shares still unlocking.
            if (vars.fullProfitUnlockDateVar > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                vars.previouslyLockedTime =
                    (vars.totalLockedShares - vars.sharesToLock) *
                    (vars.fullProfitUnlockDateVar - block.timestamp);
            }

            // new_profit_locking_period is a weighted average between the remaining time of the previously locked shares and the profit_max_unlock_time
            vars.newProfitLockingPeriod =
                (vars.previouslyLockedTime + vars.sharesToLock * vars.profitMaxUnlockTimeVar) /
                vars.totalLockedShares;
            // Calculate how many shares unlock per second.
            _profitUnlockingRate = (vars.totalLockedShares * MAX_BPS_EXTENDED) / vars.newProfitLockingPeriod;
            // Calculate how long until the full amount of shares is unlocked.
            _fullProfitUnlockDate = block.timestamp + vars.newProfitLockingPeriod;
            // Update the last profitable report timestamp.
            _lastProfitUpdate = block.timestamp;
        } else {
            // NOTE: only setting this to the 0 will turn in the desired effect,
            // no need to update profit_unlocking_rate
            _fullProfitUnlockDate = 0;
        }

        // Record the report of profit timestamp.
        _strategies[strategy_].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss or no profit locking
        if (vars.loss + vars.totalFees > vars.gain + vars.totalRefunds || vars.profitMaxUnlockTimeVar == 0) {
            vars.totalFees = _convertToAssets(vars.totalFeesShares, Rounding.ROUND_DOWN);
        }

        emit StrategyReported(
            strategy_,
            vars.gain,
            vars.loss,
            vars.currentDebt,
            (vars.totalFees * uint256(vars.protocolFeeBps)) / MAX_BPS, // Protocol Fees
            vars.totalFees,
            vars.totalRefunds
        );

        return (vars.gain, vars.loss);
    }

    /**
     * @notice Used for governance to buy bad debt from the vault.
     * @dev This should only ever be used in an emergency in place
     *      of force revoking a strategy in order to not report a loss.
     *      It allows the DEBT_PURCHASER role to buy the strategies debt
     *      for an equal amount of `asset`.
     *
     * @param strategy_ The strategy to buy the debt for
     * @param amount_ The amount of debt to buy from the vault.
     */
    function buyDebt(address strategy_, uint256 amount_) external override nonReentrant {
        _enforceRole(msg.sender, Roles.DEBT_PURCHASER);
        require(_strategies[strategy_].activation != 0, InactiveStrategy());

        // Cache the current debt.
        uint256 currentDebt = _strategies[strategy_].currentDebt;
        uint256 _amount = amount_;

        require(currentDebt > 0, NothingToBuy());
        require(_amount > 0, NothingToBuyWith());

        if (_amount > currentDebt) {
            _amount = currentDebt;
        }

        // We get the proportion of the debt that is being bought and
        // transfer the equivalent shares. We assume this is being used
        // due to strategy issues so won't rely on its conversion rates.
        uint256 shares = (IERC4626Payable(strategy_).balanceOf(address(this)) * _amount) / currentDebt;

        require(shares > 0, CannotBuyZero());

        _safeTransferFrom(asset, msg.sender, address(this), _amount);

        // Lower strategy debt
        uint256 newDebt = currentDebt - _amount;
        _strategies[strategy_].currentDebt = newDebt;

        _totalDebt -= _amount;
        _totalIdle += _amount;

        // log debt change
        emit DebtUpdated(strategy_, currentDebt, newDebt);

        // Transfer the strategies shares out.
        _safeTransfer(strategy_, msg.sender, shares);

        emit DebtPurchased(strategy_, _amount);
    }

    /// STRATEGY MANAGEMENT ///

    /**
     * @notice Add a new strategy.
     * @param newStrategy_ The new strategy to add.
     * @param addToQueue_ Whether to add the strategy to the default queue.
     */
    function addStrategy(address newStrategy_, bool addToQueue_) external override {
        _enforceRole(msg.sender, Roles.ADD_STRATEGY_MANAGER);
        _addStrategy(newStrategy_, addToQueue_);
    }

    /**
     * @notice Revoke a strategy.
     * @param strategy_ The strategy to revoke.
     */
    function revokeStrategy(address strategy_) external override {
        _enforceRole(msg.sender, Roles.REVOKE_STRATEGY_MANAGER);
        _revokeStrategy(strategy_, false);
    }

    /**
     * @notice Force revoke a strategy.
     * @dev The vault will remove the strategy and write off any debt left
     *      in it as a loss. This function is a dangerous function as it can force a
     *      strategy to take a loss. All possible assets should be removed from the
     *      strategy first via updateDebt. If a strategy is removed erroneously it
     *      can be re-added and the loss will be credited as profit. Fees will apply.
     * @param strategy_ The strategy to force revoke.
     */
    function forceRevokeStrategy(address strategy_) external override {
        _enforceRole(msg.sender, Roles.FORCE_REVOKE_MANAGER);
        _revokeStrategy(strategy_, true);
    }

    /**
     * @notice Update the max debt for a strategy.
     * @param strategy_ The strategy to update the max debt for.
     * @param newMaxDebt_ The new max debt for the strategy.
     */
    function updateMaxDebtForStrategy(address strategy_, uint256 newMaxDebt_) external override {
        _enforceRole(msg.sender, Roles.MAX_DEBT_MANAGER);
        require(_strategies[strategy_].activation != 0, InactiveStrategy());
        _strategies[strategy_].maxDebt = newMaxDebt_;

        emit UpdatedMaxDebtForStrategy(msg.sender, strategy_, newMaxDebt_);
    }

    /// DEBT MANAGEMENT ///
    /**
     * @notice Update the debt for a strategy.
     * @dev This function will rebalance the debt of a strategy, either by withdrawing
     *      funds or depositing new funds. Uses a struct to avoid stack too deep errors.
     * @param strategy_ The strategy to update the debt for.
     * @param targetDebt_ The target debt for the strategy.
     * @param maxLoss_ The maximum acceptable loss in basis points.
     * @return The new current debt of the strategy.
     */
    function updateDebt(
        address strategy_,
        uint256 targetDebt_,
        uint256 maxLoss_
    ) external override nonReentrant returns (uint256) {
        _enforceRole(msg.sender, Roles.DEBT_MANAGER);
        return _updateDebt(strategy_, targetDebt_, maxLoss_);
    }

    function _updateDebt(address strategy_, uint256 targetDebt_, uint256 maxLoss_) internal returns (uint256) {
        // Store the old debt before calling library
        uint256 oldDebt = _strategies[strategy_].currentDebt;

        // Call the library to handle all debt management logic
        DebtManagementLib.UpdateDebtResult memory result = DebtManagementLib.updateDebt(
            _strategies,
            _totalIdle,
            _totalDebt,
            strategy_,
            targetDebt_,
            maxLoss_,
            minimumTotalIdle,
            asset,
            _shutdown
        );

        // Update vault storage with results from library
        _totalIdle = result.newTotalIdle;
        _totalDebt = result.newTotalDebt;

        // Emit debt updated event
        emit DebtUpdated(strategy_, oldDebt, result.newDebt);

        return result.newDebt;
    }

    /// EMERGENCY MANAGEMENT ///
    /**
     * @notice Shutdown the vault.
     */
    function shutdownVault() external override {
        _enforceRole(msg.sender, Roles.EMERGENCY_MANAGER);
        require(_shutdown == false, AlreadyShutdown());

        // Shutdown the vault.
        _shutdown = true;

        // Set deposit limit to 0.
        if (depositLimitModule != address(0)) {
            depositLimitModule = address(0);
            emit UpdateDepositLimitModule(address(0));
        }

        depositLimit = 0;
        emit UpdateDepositLimit(0);

        // Add debt manager role to the sender
        roles[msg.sender] = roles[msg.sender] | (1 << uint256(Roles.DEBT_MANAGER));
        // todo might need to emit the combined roles
        emit RoleSet(msg.sender, roles[msg.sender]);

        emit Shutdown();
    }

    /// SHARE MANAGEMENT ///
    /// ERC20 + ERC4626 ///

    /**
     * @notice Deposit assets into the vault.
     * @dev Pass max uint256 to deposit full asset balance.
     * @param assets_ The amount of assets to deposit.
     * @param receiver_ The address to receive the shares.
     * @return The amount of shares minted.
     */
    function deposit(uint256 assets_, address receiver_) external virtual nonReentrant returns (uint256) {
        uint256 amount = assets_;
        // Deposit all if sent with max uint
        if (amount == type(uint256).max) {
            amount = IERC20(asset).balanceOf(msg.sender);
        }

        uint256 shares = _convertToShares(amount, Rounding.ROUND_DOWN);
        _deposit(receiver_, amount, shares);
        return shares;
    }

    /**
     * @notice Mint shares for the receiver.
     * @param shares_ The amount of shares to mint.
     * @param receiver_ The address to receive the shares.
     * @return The amount of assets deposited.
     */
    function mint(uint256 shares_, address receiver_) external virtual nonReentrant returns (uint256) {
        uint256 assets = _convertToAssets(shares_, Rounding.ROUND_UP);
        _deposit(receiver_, assets, shares_);
        return assets;
    }

    /**
     * @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
     * @dev The default behavior is to not allow any loss.
     * @param assets_ The amount of asset to withdraw.
     * @param receiver_ The address to receive the assets.
     * @param owner_ The address who's shares are being burnt.
     * @param maxLoss_ Optional amount of acceptable loss in Basis Points.
     * @param strategiesArray_ Optional array of strategies to withdraw from.
     * @return The amount of shares actually burnt.
     */
    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) public virtual override nonReentrant returns (uint256) {
        uint256 shares = _convertToShares(assets_, Rounding.ROUND_UP);
        _redeem(msg.sender, receiver_, owner_, assets_, shares, maxLoss_, strategiesArray_);
        return shares;
    }

    /**
     * @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
     * @dev The default behavior is to allow losses to be realized.
     * @param shares_ The amount of shares to burn.
     * @param receiver_ The address to receive the assets.
     * @param owner_ The address who's shares are being burnt.
     * @param maxLoss_ Optional amount of acceptable loss in Basis Points.
     * @param strategiesArray_ Optional array of strategies to withdraw from.
     * @return The amount of assets actually withdrawn.
     */
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) public virtual override nonReentrant returns (uint256) {
        uint256 assets = _convertToAssets(shares_, Rounding.ROUND_DOWN);
        // Always return the actual amount of assets withdrawn.
        return _redeem(msg.sender, receiver_, owner_, assets, shares_, maxLoss_, strategiesArray_);
    }

    /**
     * @notice Approve an address to spend the vault's shares.
     * @param spender_ The address to approve.
     * @param amount_ The amount of shares to approve.
     * @return True if the approval was successful.
     */
    function approve(address spender_, uint256 amount_) external override returns (bool) {
        return _approve(msg.sender, spender_, amount_);
    }

    /**
     * @notice Transfer shares to a receiver.
     * @param receiver_ The address to transfer shares to.
     * @param amount_ The amount of shares to transfer.
     * @return True if the transfer was successful.
     */
    function transfer(address receiver_, uint256 amount_) external override returns (bool) {
        require(receiver_ != address(this) && receiver_ != address(0), InvalidReceiver());
        _transfer(msg.sender, receiver_, amount_);
        return true;
    }

    /**
     * @notice Transfer shares from a sender to a receiver.
     * @param sender_ The address to transfer shares from.
     * @param receiver_ The address to transfer shares to.
     * @param amount_ The amount of shares to transfer.
     * @return True if the transfer was successful.
     */
    function transferFrom(address sender_, address receiver_, uint256 amount_) external override returns (bool) {
        require(receiver_ != address(this) && receiver_ != address(0), InvalidReceiver());
        _spendAllowance(sender_, msg.sender, amount_);
        _transfer(sender_, receiver_, amount_);
        return true;
    }

    /**
     * @notice Approve an address to spend the vault's shares with permit.
     * @param owner_ The address to approve from.
     * @param spender_ The address to approve.
     * @param amount_ The amount of shares to approve.
     * @param deadline_ The deadline for the permit.
     * @param v_ The v component of the signature.
     * @param r_ The r component of the signature.
     * @param s_ The s component of the signature.
     * @return True if the approval was successful.
     */
    function permit(
        address owner_,
        address spender_,
        uint256 amount_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external override returns (bool) {
        return _permit(owner_, spender_, amount_, deadline_, v_, r_, s_);
    }

    /**
     * @notice Get the balance of a user.
     * @param addr_ The address to get the balance of.
     * @return The balance of the user.
     */
    function balanceOf(address addr_) public view override returns (uint256) {
        if (addr_ == address(this)) {
            // If the address is the vault, account for locked shares.
            return _balanceOf[addr_] - _unlockedShares();
        }

        return _balanceOf[addr_];
    }

    /**
     * @notice Get the total supply of shares.
     * @return The total supply of shares.
     */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply();
    }

    /**
     * @notice Get the total assets held by the vault.
     * @return The total assets held by the vault.
     */
    function totalAssets() external view override returns (uint256) {
        return _totalAssets();
    }

    /**
     * @notice Get the amount of loose `asset` the vault holds.
     * @return The current total idle.
     */
    function totalIdle() external view override returns (uint256) {
        return _totalIdle;
    }

    /**
     * @notice Get the the total amount of funds invested across all strategies.
     * @return The current total debt.
     */
    function totalDebt() external view override returns (uint256) {
        return _totalDebt;
    }

    /**
     * @notice Convert an amount of assets to shares.
     * @param assets_ The amount of assets to convert.
     * @return The amount of shares.
     */
    function convertToShares(uint256 assets_) external view override returns (uint256) {
        return _convertToShares(assets_, Rounding.ROUND_DOWN);
    }

    /**
     * @notice Preview the amount of shares that would be minted for a deposit.
     * @param assets_ The amount of assets to deposit.
     * @return The amount of shares that would be minted.
     */
    function previewDeposit(uint256 assets_) external view override returns (uint256) {
        return _convertToShares(assets_, Rounding.ROUND_DOWN);
    }

    /**
     * @notice Preview the amount of assets that would be deposited for a mint.
     * @param shares_ The amount of shares to mint.
     * @return The amount of assets that would be deposited.
     */
    function previewMint(uint256 shares_) external view override returns (uint256) {
        return _convertToAssets(shares_, Rounding.ROUND_UP);
    }

    /**
     * @notice Convert an amount of shares to assets.
     * @param shares_ The amount of shares to convert.
     * @return The amount of assets.
     */
    function convertToAssets(uint256 shares_) external view override returns (uint256) {
        return _convertToAssets(shares_, Rounding.ROUND_DOWN);
    }

    /**
     * @notice Get the default queue of strategies.
     * @return The default queue of strategies.
     */
    function defaultQueue() external view override returns (address[] memory) {
        return _defaultQueue;
    }

    /**
     * @notice Get the maximum amount of assets that can be deposited.
     * @param receiver_ The address that will receive the shares.
     * @return The maximum amount of assets that can be deposited.
     */
    function maxDeposit(address receiver_) external view override returns (uint256) {
        return _maxDeposit(receiver_);
    }

    /**
     * @notice Get the maximum amount of shares that can be minted.
     * @param receiver_ The address that will receive the shares.
     * @return The maximum amount of shares that can be minted.
     */
    function maxMint(address receiver_) external view override returns (uint256) {
        uint256 maxDepositAmount = _maxDeposit(receiver_);
        return _convertToShares(maxDepositAmount, Rounding.ROUND_DOWN);
    }

    /**
     * @notice Get the maximum amount of assets that can be withdrawn.
     * @dev Complies to normal 4626 interface and takes custom params.
     * NOTE: Passing in a incorrectly ordered queue may result in
     *       incorrect returns values.
     * @param owner_ The address that owns the shares.
     * @param maxLoss_ Custom max_loss if any.
     * @param strategiesArray_ Custom strategies queue if any.
     * @return The maximum amount of assets that can be withdrawn.
     */
    function maxWithdraw(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) external view virtual override returns (uint256) {
        return _maxWithdraw(owner_, maxLoss_, strategiesArray_);
    }

    /**
     * @notice Get the maximum amount of shares that can be redeemed.
     * @dev Complies to normal 4626 interface and takes custom params.
     * NOTE: Passing in a incorrectly ordered queue may result in
     *       incorrect returns values.
     * @param owner_ The address that owns the shares.
     * @param maxLoss_ Custom max_loss if any.
     * @param strategiesArray_ Custom strategies queue if any.
     * @return The maximum amount of shares that can be redeemed.
     */
    function maxRedeem(
        address owner_,
        uint256 maxLoss_,
        address[] calldata strategiesArray_
    ) external view virtual override returns (uint256) {
        return
            Math.min(
                // Min of the shares equivalent of max_withdraw or the full balance
                _convertToShares(_maxWithdraw(owner_, maxLoss_, strategiesArray_), Rounding.ROUND_DOWN),
                _balanceOf[owner_]
            );
    }

    /**
     * @notice Preview the amount of shares that would be redeemed for a withdraw.
     * @param assets_ The amount of assets to withdraw.
     * @return The amount of shares that would be redeemed.
     */
    function previewWithdraw(uint256 assets_) external view override returns (uint256) {
        return _convertToShares(assets_, Rounding.ROUND_UP);
    }

    /**
     * @notice Preview the amount of assets that would be withdrawn for a redeem.
     * @param shares_ The amount of shares to redeem.
     * @return The amount of assets that would be withdrawn.
     */
    function previewRedeem(uint256 shares_) external view override returns (uint256) {
        return _convertToAssets(shares_, Rounding.ROUND_DOWN);
    }

    /**
     * @notice Address of the factory that deployed the vault.
     * @dev Is used to retrieve the protocol fees.
     * @return Address of the vault factory.
     */
    function FACTORY() external view override returns (address) {
        return _factory;
    }

    /**
     * @notice Get the API version of the vault.
     * @return The API version of the vault.
     */
    function apiVersion() external pure override returns (string memory) {
        return API_VERSION;
    }

    /**
     * @notice Assess the share of unrealised losses that a strategy has.
     * @param strategy_ The address of the strategy.
     * @param assetsNeeded_ The amount of assets needed to be withdrawn.
     * @return The share of unrealised losses that the strategy has.
     */
    function assessShareOfUnrealisedLosses(address strategy_, uint256 assetsNeeded_) external view returns (uint256) {
        uint256 currentDebt = _strategies[strategy_].currentDebt;
        require(currentDebt >= assetsNeeded_, NotEnoughDebt());

        return _assessShareOfUnrealisedLosses(strategy_, currentDebt, assetsNeeded_);
    }

    /**
     * @notice Gets the current time profits are set to unlock over.
     * @return The current profit max unlock time.
     */
    function profitMaxUnlockTime() external view override returns (uint256) {
        return _profitMaxUnlockTime;
    }

    /**
     * @notice Gets the timestamp at which all profits will be unlocked.
     * @return The full profit unlocking timestamp
     */
    function fullProfitUnlockDate() external view override returns (uint256) {
        return _fullProfitUnlockDate;
    }

    /**
     * @notice The per second rate at which profits are unlocking.
     * @dev This is denominated in EXTENDED_BPS decimals.
     * @return The current profit unlocking rate.
     */
    function profitUnlockingRate() external view override returns (uint256) {
        return _profitUnlockingRate;
    }

    /**
     * @notice The timestamp of the last time shares were locked.
     * @return The last profit update.
     */
    function lastProfitUpdate() external view override returns (uint256) {
        return _lastProfitUpdate;
    }

    function assessShareOfUnrealisedLosses(
        address strategy,
        uint256 currentDebt,
        uint256 assetsNeeded
    ) external view returns (uint256) {
        require(currentDebt >= assetsNeeded, NotEnoughDebt());
        return _assessShareOfUnrealisedLosses(strategy, currentDebt, assetsNeeded);
    }

    /**
     * @notice Get the domain separator for EIP-712.
     * @return The domain separator.
     */
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    DOMAIN_TYPE_HASH,
                    keccak256(bytes("Octant Vault")),
                    keccak256(bytes(API_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }

    /**
     * @notice Get the strategy parameters for a given strategy.
     * @param strategy_ The address of the strategy.
     * @return The strategy parameters.
     */
    function strategies(address strategy_) external view returns (StrategyParams memory) {
        return _strategies[strategy_];
    }

    /// SHARE MANAGEMENT ///
    /// ERC20 ///
    /**
     * @dev Spends allowance from owner to spender
     */
    function _spendAllowance(address owner_, address spender_, uint256 amount_) internal {
        // Unlimited approval does nothing (saves an SSTORE)
        uint256 currentAllowance = allowance[owner_][spender_];
        if (currentAllowance < type(uint256).max) {
            require(currentAllowance >= amount_, InsufficientAllowance());
            _approve(owner_, spender_, currentAllowance - amount_);
        }
    }

    /**
     * @dev Transfers tokens from sender to receiver
     */
    function _transfer(address sender_, address receiver_, uint256 amount_) internal virtual {
        uint256 senderBalance = _balanceOf[sender_];
        require(senderBalance >= amount_, InsufficientFunds());
        _balanceOf[sender_] = senderBalance - amount_;
        _balanceOf[receiver_] += amount_;
        emit Transfer(sender_, receiver_, amount_);
    }

    /**
     * @dev Sets approval of spender for owner's tokens
     */
    function _approve(address owner_, address spender_, uint256 amount_) internal returns (bool) {
        allowance[owner_][spender_] = amount_;
        emit Approval(owner_, spender_, amount_);
        return true;
    }

    /**
     * @dev Implementation of the permit function (EIP-2612)
     */
    function _permit(
        address owner_,
        address spender_,
        uint256 amount_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) internal returns (bool) {
        require(owner_ != address(0), InvalidOwner());
        require(deadline_ >= block.timestamp, PermitExpired());
        uint256 nonce = nonces[owner_];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPE_HASH, owner_, spender_, amount_, nonce, deadline_))
            )
        );
        address recoveredAddress = ecrecover(digest, v_, r_, s_);
        require(recoveredAddress != address(0) && recoveredAddress == owner_, InvalidSignature());

        allowance[owner_][spender_] = amount_;
        nonces[owner_] = nonce + 1;
        emit Approval(owner_, spender_, amount_);
        return true;
    }

    /**
     * @dev Burns shares from an account
     */
    function _burnShares(uint256 shares_, address owner_) internal {
        _balanceOf[owner_] -= shares_;
        _totalSupplyValue -= shares_;
        emit Transfer(owner_, address(0), shares_);
    }

    /**
     * @dev Returns the amount of shares that have been unlocked
     */
    function _unlockedShares() internal view returns (uint256) {
        uint256 fullProfitUnlockDateVar = _fullProfitUnlockDate;
        uint256 unlockedSharesAmount = 0;

        if (fullProfitUnlockDateVar > block.timestamp) {
            // If we have not fully unlocked, we need to calculate how much has been.
            unlockedSharesAmount = (_profitUnlockingRate * (block.timestamp - _lastProfitUpdate)) / MAX_BPS_EXTENDED;
        } else if (fullProfitUnlockDateVar != 0) {
            // All shares have been unlocked
            unlockedSharesAmount = _balanceOf[address(this)];
        }

        return unlockedSharesAmount;
    }

    /**
     * @dev Returns the total supply accounting for unlocked shares
     */
    function _totalSupply() internal view returns (uint256) {
        // Need to account for the shares issued to the vault that have unlocked.
        return _totalSupplyValue - _unlockedShares();
    }

    /**
     * @dev Returns the total assets (idle + debt)
     */
    function _totalAssets() internal view returns (uint256) {
        return _totalIdle + _totalDebt;
    }

    /**
     * @dev Converts shares to assets
     */
    function _convertToAssets(uint256 shares_, Rounding rounding_) internal view returns (uint256) {
        if (shares_ == type(uint256).max || shares_ == 0) {
            return shares_;
        }

        uint256 supply = _totalSupply();
        // if totalSupply is 0, price_per_share is 1
        if (supply == 0) {
            return shares_;
        }

        uint256 numerator = shares_ * _totalAssets();
        uint256 amount = numerator / supply;
        // slither-disable-next-line weak-prng
        if (rounding_ == Rounding.ROUND_UP && numerator % supply != 0) {
            amount += 1;
        }

        return amount;
    }

    /**
     * @dev Converts assets to shares
     */
    function _convertToShares(uint256 assets_, Rounding rounding_) internal view returns (uint256) {
        if (assets_ == type(uint256).max || assets_ == 0) {
            return assets_;
        }

        uint256 supply = _totalSupply();

        // if total_supply is 0, price_per_share is 1
        if (supply == 0) {
            return assets_;
        }

        uint256 totalAssetsAmount = _totalAssets();

        // if totalSupply > 0 but totalAssets == 0, price_per_share = 0
        if (totalAssetsAmount == 0) {
            return 0;
        }

        uint256 numerator = assets_ * supply;
        uint256 sharesAmount = numerator / totalAssetsAmount;
        // slither-disable-next-line weak-prng
        if (rounding_ == Rounding.ROUND_UP && numerator % totalAssetsAmount != 0) {
            sharesAmount += 1;
        }

        return sharesAmount;
    }

    /**
     * @dev Issues shares to a recipient
     */
    function _issueShares(uint256 shares_, address recipient_) internal {
        _balanceOf[recipient_] += shares_;
        _totalSupplyValue += shares_;
        emit Transfer(address(0), recipient_, shares_);
    }

    /// ERC4626 ///

    /**
     * @dev Returns the maximum deposit possible for a receiver
     */
    function _maxDeposit(address receiver_) internal view returns (uint256) {
        if (receiver_ == address(0) || receiver_ == address(this)) {
            return 0;
        }

        // If there is a deposit limit module set use that.
        address _depositLimitModule = depositLimitModule;

        if (_depositLimitModule != address(0)) {
            return IDepositLimitModule(_depositLimitModule).availableDepositLimit(receiver_);
        }

        // Else use the standard flow.
        uint256 _depositLimit = depositLimit;
        if (_depositLimit == type(uint256).max) {
            return _depositLimit;
        }

        uint256 _totalAssetsAmount = _totalAssets();
        if (_totalAssetsAmount >= _depositLimit) {
            return 0;
        }

        return _depositLimit - _totalAssetsAmount;
    }

    /**
     * @dev Returns the maximum amount an owner can withdraw
     */
    function _maxWithdraw(
        address owner_,
        uint256 maxLoss_,
        address[] memory strategiesParam_
    ) internal view returns (uint256) {
        // slither-disable-next-line uninitialized-local
        MaxWithdrawVars memory vars;

        // Get the max amount for the owner if fully liquid
        vars.maxAssets = _convertToAssets(_balanceOf[owner_], Rounding.ROUND_DOWN);

        // If there is a withdraw limit module use that
        address _withdrawLimitModule = withdrawLimitModule;
        if (_withdrawLimitModule != address(0)) {
            return
                Math.min(
                    IWithdrawLimitModule(_withdrawLimitModule).availableWithdrawLimit(
                        owner_,
                        maxLoss_,
                        strategiesParam_
                    ),
                    vars.maxAssets
                );
        }

        // See if we have enough idle to service the withdraw
        vars.currentIdle = _totalIdle;
        if (vars.maxAssets > vars.currentIdle) {
            // Track how much we can pull
            vars.have = vars.currentIdle;
            vars.loss = 0;

            // Determine which strategy queue to use
            vars.withdrawalStrategies = strategiesParam_.length != 0 && !useDefaultQueue
                ? strategiesParam_
                : _defaultQueue;

            // Process each strategy in the queue
            for (uint256 i = 0; i < vars.withdrawalStrategies.length; i++) {
                address strategy = vars.withdrawalStrategies[i];
                require(_strategies[strategy].activation != 0, InactiveStrategy());

                uint256 currentDebt = _strategies[strategy].currentDebt;
                // Get the maximum amount the vault would withdraw from the strategy
                uint256 toWithdraw = Math.min(vars.maxAssets - vars.have, currentDebt);

                // Get any unrealized loss for the strategy
                uint256 unrealizedLoss = _assessShareOfUnrealisedLosses(strategy, currentDebt, toWithdraw);

                // See if any limit is enforced by the strategy
                uint256 strategyLimit = IERC4626Payable(strategy).convertToAssets(
                    IERC4626Payable(strategy).maxRedeem(address(this))
                );

                // Adjust accordingly if there is a max withdraw limit
                uint256 realizableWithdraw = toWithdraw - unrealizedLoss;
                if (strategyLimit < realizableWithdraw) {
                    if (unrealizedLoss != 0) {
                        // Lower unrealized loss proportional to the limit
                        unrealizedLoss = (unrealizedLoss * strategyLimit) / realizableWithdraw;
                    }
                    // Still count the unrealized loss as withdrawable
                    toWithdraw = strategyLimit + unrealizedLoss;
                }

                // If 0 move on to the next strategy
                if (toWithdraw == 0) {
                    continue;
                }

                // If there would be a loss with a non-maximum `maxLoss` value
                if (unrealizedLoss > 0 && maxLoss_ < MAX_BPS) {
                    // Check if the loss is greater than the allowed range
                    if (vars.loss + unrealizedLoss > ((vars.have + toWithdraw) * maxLoss_) / MAX_BPS) {
                        // If so use the amounts up till now
                        break;
                    }
                }

                // Add to what we can pull
                vars.have += toWithdraw;

                // If we have all we need break
                if (vars.have >= vars.maxAssets) {
                    break;
                }

                // Add any unrealized loss to the total
                vars.loss += unrealizedLoss;
            }

            // Update the max after going through the queue
            vars.maxAssets = vars.have;
        }

        return vars.maxAssets;
    }

    /**
     * @dev Handles deposit logic
     */
    function _deposit(address recipient_, uint256 assets_, uint256 shares_) internal {
        require(assets_ <= _maxDeposit(recipient_), ExceedDepositLimit());
        require(assets_ > 0, CannotDepositZero());
        require(shares_ > 0, CannotMintZero());

        // Transfer the tokens to the vault first.
        _safeTransferFrom(asset, msg.sender, address(this), assets_);

        // Record the change in total assets.
        _totalIdle += assets_;

        // Issue the corresponding shares for assets.
        _issueShares(shares_, recipient_);

        emit Deposit(msg.sender, recipient_, assets_, shares_);

        // cache the default queue length
        uint256 defaultQueueLength = _defaultQueue.length;

        if (autoAllocate && defaultQueueLength > 0) {
            _updateDebt(_defaultQueue[0], type(uint256).max, 0);
        }
    }

    /**
     * @dev Returns share of unrealized losses
     */
    function _assessShareOfUnrealisedLosses(
        address strategy_,
        uint256 strategyCurrentDebt_,
        uint256 assetsNeeded_
    ) internal view returns (uint256) {
        // The actual amount that the debt is currently worth.
        uint256 vaultShares = IERC4626Payable(strategy_).balanceOf(address(this));
        uint256 strategyAssets = IERC4626Payable(strategy_).convertToAssets(vaultShares);

        // If no losses, return 0
        if (strategyAssets >= strategyCurrentDebt_ || strategyCurrentDebt_ == 0) {
            return 0;
        }

        // Users will withdraw assetsNeeded divided by loss ratio (strategyAssets / strategyCurrentDebt - 1).
        // NOTE: If there are unrealised losses, the user will take his share.
        uint256 numerator = assetsNeeded_ * strategyAssets;
        uint256 usersShareOfLoss = assetsNeeded_ - numerator / strategyCurrentDebt_;

        return usersShareOfLoss;
    }

    /// STRATEGY MANAGEMENT ///
    /**
     * @dev Adds a new strategy
     */
    function _addStrategy(address newStrategy_, bool addToQueue_) internal {
        // Validate the strategy
        require(newStrategy_ != address(0) && newStrategy_ != address(this), StrategyCannotBeZeroAddress());

        // Verify the strategy asset matches the vault's asset
        require(IERC4626Payable(newStrategy_).asset() == asset, InvalidAsset());

        // Check the strategy is not already active
        require(_strategies[newStrategy_].activation == 0, StrategyAlreadyActive());

        // Add the new strategy to the mapping with initialization parameters
        _strategies[newStrategy_] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: 0
        });

        // If requested and there's room, add to the default queue
        if (addToQueue_ && _defaultQueue.length < MAX_QUEUE) {
            _defaultQueue.push(newStrategy_);
        }

        // Emit the strategy changed event
        emit StrategyChanged(newStrategy_, StrategyChangeType.ADDED);
    }

    /**
     * @dev Redeems shares from strategies
     */
    function _redeem(
        address sender_,
        address receiver_,
        address owner_,
        uint256 assets_,
        uint256 shares_,
        uint256 maxLoss_,
        address[] memory strategiesParam_
    ) internal returns (uint256) {
        require(receiver_ != address(0), ZeroAddress());
        require(shares_ > 0, NoSharesToRedeem());
        require(assets_ > 0, NoAssetsToWithdraw());
        require(maxLoss_ <= MAX_BPS, MaxLossExceeded());

        // If there is a withdraw limit module, check the max.
        address _withdrawLimitModule = withdrawLimitModule;
        if (_withdrawLimitModule != address(0)) {
            require(
                assets_ <=
                    IWithdrawLimitModule(_withdrawLimitModule).availableWithdrawLimit(
                        owner_,
                        maxLoss_,
                        strategiesParam_
                    ),
                ExceedWithdrawLimit()
            );
        }

        require(_balanceOf[owner_] >= shares_, InsufficientSharesToRedeem());

        if (sender_ != owner_) {
            _spendAllowance(owner_, sender_, shares_);
        }

        // Initialize our redemption state
        // slither-disable-next-line uninitialized-local
        RedeemState memory state;
        state.requestedAssets = assets_;
        state.currentTotalIdle = _totalIdle;
        state.asset = asset;
        state.currentTotalDebt = _totalDebt;

        // If there are not enough assets in the Vault contract, we try to free
        // funds from strategies.
        if (state.requestedAssets > state.currentTotalIdle) {
            // Determine which strategies to use
            if (strategiesParam_.length != 0 && !useDefaultQueue) {
                state.withdrawalStrategies = strategiesParam_;
            } else {
                state.withdrawalStrategies = _defaultQueue;
            }

            // Calculate how much we need to withdraw from strategies
            state.assetsNeeded = state.requestedAssets - state.currentTotalIdle;

            // Track the previous balance to calculate actual withdrawn amounts
            state.previousBalance = IERC20(state.asset).balanceOf(address(this));

            // Withdraw from each strategy until we have enough
            for (uint256 i = 0; i < state.withdrawalStrategies.length; i++) {
                address strategy = state.withdrawalStrategies[i];

                // Make sure we have a valid strategy
                require(_strategies[strategy].activation != 0, InactiveStrategy());

                // How much the strategy should have
                uint256 currentDebt = _strategies[strategy].currentDebt;

                // What is the max amount to withdraw from this strategy
                uint256 assetsToWithdraw = Math.min(state.assetsNeeded, currentDebt);

                // Cache max withdraw for use if unrealized loss > 0
                uint256 maxWithdrawAmount = IERC4626Payable(strategy).convertToAssets(
                    IERC4626Payable(strategy).maxRedeem(address(this))
                );

                // Check for unrealized losses
                uint256 unrealisedLossesShare = _assessShareOfUnrealisedLosses(strategy, currentDebt, assetsToWithdraw);

                // Handle unrealized losses if any
                if (unrealisedLossesShare > 0) {
                    // If max withdraw is limiting the amount to pull, adjust the portion of
                    // unrealized loss the user should take
                    if (maxWithdrawAmount < assetsToWithdraw - unrealisedLossesShare) {
                        // How much we would want to withdraw
                        uint256 wanted = assetsToWithdraw - unrealisedLossesShare;
                        // Get the proportion of unrealized comparing what we want vs what we can get
                        unrealisedLossesShare = (unrealisedLossesShare * maxWithdrawAmount) / wanted;
                        // Adjust assetsToWithdraw so all future calculations work correctly
                        assetsToWithdraw = maxWithdrawAmount + unrealisedLossesShare;
                    }

                    // User now "needs" less assets to be unlocked (as they took some as losses)
                    assetsToWithdraw -= unrealisedLossesShare;
                    state.requestedAssets -= unrealisedLossesShare;
                    state.assetsNeeded -= unrealisedLossesShare;
                    state.currentTotalDebt -= unrealisedLossesShare;

                    // If max withdraw is 0 and unrealized loss is still > 0, the strategy
                    // likely realized a 100% loss and we need to realize it before moving on
                    if (maxWithdrawAmount == 0 && unrealisedLossesShare > 0) {
                        // Adjust the strategy debt accordingly
                        uint256 newDebt = currentDebt - unrealisedLossesShare;
                        // Update strategies storage
                        _strategies[strategy].currentDebt = newDebt;
                        // Log the debt update
                        emit DebtUpdated(strategy, currentDebt, newDebt);
                    }
                }

                // Adjust based on max withdraw of the strategy
                assetsToWithdraw = Math.min(assetsToWithdraw, maxWithdrawAmount);

                // Can't withdraw 0
                if (assetsToWithdraw == 0) {
                    continue;
                }

                // Withdraw from strategy
                // Need to get shares since we use redeem to be able to take on losses
                uint256 sharesToRedeem = Math.min(
                    // Use previewWithdraw since it should round up
                    IERC4626Payable(strategy).previewWithdraw(assetsToWithdraw),
                    // And check against our actual balance
                    IERC4626Payable(strategy).balanceOf(address(this))
                );

                IERC4626Payable(strategy).redeem(sharesToRedeem, address(this), address(this));
                uint256 postBalance = IERC20(state.asset).balanceOf(address(this));

                // Always check against the real amounts
                uint256 withdrawn = postBalance - state.previousBalance;
                uint256 loss = 0;

                // Check if we redeemed too much
                if (withdrawn > assetsToWithdraw) {
                    // Make sure we don't underflow in debt updates
                    if (withdrawn > currentDebt) {
                        // Can't withdraw more than our debt
                        assetsToWithdraw = currentDebt;
                    } else {
                        // Add the extra to how much we withdrew
                        assetsToWithdraw += (withdrawn - assetsToWithdraw);
                    }
                }
                // If we have not received what we expected, consider the difference a loss
                else if (withdrawn < assetsToWithdraw) {
                    loss = assetsToWithdraw - withdrawn;
                }

                // Strategy's debt decreases by the full amount but total idle increases
                // by the actual amount only (as the difference is considered lost)
                state.currentTotalIdle += (assetsToWithdraw - loss);
                state.requestedAssets -= loss;
                state.currentTotalDebt -= assetsToWithdraw;

                // Vault will reduce debt because the unrealized loss has been taken by user
                uint256 newDebtAmount = currentDebt - (assetsToWithdraw + unrealisedLossesShare);

                // Update strategies storage
                _strategies[strategy].currentDebt = newDebtAmount;
                // Log the debt update
                emit DebtUpdated(strategy, currentDebt, newDebtAmount);

                // Break if we have enough total idle to serve initial request
                if (state.requestedAssets <= state.currentTotalIdle) {
                    break;
                }

                // Update previous balance for next iteration
                state.previousBalance = postBalance;

                // Reduce what we still need
                state.assetsNeeded -= assetsToWithdraw;
            }

            // If we exhaust the queue and still have insufficient total idle, revert
            require(state.currentTotalIdle >= state.requestedAssets, InsufficientAssetsInVault());
        }

        // Check if there is a loss and a non-default value was set
        if (assets_ > state.requestedAssets && maxLoss_ < MAX_BPS) {
            // Assure the loss is within the allowed range
            require(assets_ - state.requestedAssets <= (assets_ * maxLoss_) / MAX_BPS, TooMuchLoss());
        }

        // First burn the corresponding shares from the redeemer
        _burnShares(shares_, owner_);

        // Commit memory to storage
        _totalIdle = state.currentTotalIdle - state.requestedAssets;
        _totalDebt = state.currentTotalDebt;

        // Transfer the requested amount to the receiver
        _safeTransfer(state.asset, receiver_, state.requestedAssets);

        emit Withdraw(sender_, receiver_, owner_, state.requestedAssets, shares_);
        return state.requestedAssets;
    }

    /**
     * @dev Revokes a strategy
     */
    function _revokeStrategy(address strategy, bool force) internal {
        require(_strategies[strategy].activation != 0, StrategyNotActive());

        uint256 currentDebt = _strategies[strategy].currentDebt;
        uint256 lossAmount = 0;

        if (currentDebt != 0) {
            require(force, StrategyHasDebt());
            // If force is true, we realize the full loss of outstanding debt
            lossAmount = currentDebt;
        }

        // Set strategy params all back to 0 (WARNING: it can be re-added)
        _strategies[strategy] = StrategyParams({ activation: 0, lastReport: 0, currentDebt: 0, maxDebt: 0 });

        // Remove strategy from the default queue if it exists
        // Create a new dynamic array and add all strategies except the one being revoked
        address[] memory newQueue = new address[](_defaultQueue.length);
        uint256 newQueueLength = 0;
        uint256 defaultQueueLength = _defaultQueue.length;

        for (uint256 i = 0; i < defaultQueueLength; i++) {
            // Add all strategies to the new queue besides the one revoked
            if (_defaultQueue[i] != strategy) {
                newQueue[newQueueLength] = _defaultQueue[i];
                newQueueLength++;
            }
        }

        // Replace the default queue with our updated queue
        // First clear the existing queue
        while (_defaultQueue.length > 0) {
            _defaultQueue.pop();
        }

        // Then add all items from the new queue
        for (uint256 i = 0; i < newQueueLength; i++) {
            _defaultQueue.push(newQueue[i]);
        }

        // If there was a loss (force revoke with debt), update total vault debt
        if (lossAmount > 0) {
            _totalDebt -= lossAmount;
            emit StrategyReported(strategy, 0, lossAmount, 0, 0, 0, 0);
        }

        emit StrategyChanged(strategy, StrategyChangeType.REVOKED);
    }

    /// ERC20 SAFE OPERATIONS ///

    /**
     * @dev Safely transfer ERC20 tokens from one address to another, handling non-standard implementations
     * @param token The token to transfer
     * @param sender The address to transfer from
     * @param receiver The address to transfer to
     * @param amount The amount to transfer
     */
    function _safeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, sender, receiver, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), TransferFailed());
    }

    /**
     * @dev Safely transfer ERC20 tokens, handling non-standard implementations
     * @param token The token to transfer
     * @param receiver The address to transfer to
     * @param amount The amount to transfer
     */
    function _safeTransfer(address token, address receiver, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, receiver, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), TransferFailed());
    }
}
