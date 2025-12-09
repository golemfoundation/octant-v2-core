/* solhint-disable gas-custom-errors*/
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title PaymentSplitter
 * @author OpenZeppelin; adapted by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Splits ETH and ERC20 token payments proportionally among payees based on shares
 * @dev Modified from OpenZeppelin to use initializable pattern instead of constructor.
 *      Payments split in proportion to number of shares held by each account. Pull payment
 *      model where payees call release() to claim their share. Not compatible with rebasing
 *      or fee-on-transfer tokens.
 * @custom:origin https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.6/contracts/finance/PaymentSplitter.sol
 */
contract PaymentSplitter is Initializable, Context {
    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new payee is added during initialization
    /// @param account Address of the payee added
    /// @param shares Number of proportional allocation shares assigned to the payee (unitless)
    event PayeeAdded(address account, uint256 shares);

    /// @notice Emitted when ETH is released to a payee
    /// @param to Address receiving the payment
    /// @param amount Amount of ETH released in wei
    event PaymentReleased(address to, uint256 amount);

    /// @notice Emitted when ERC20 tokens are released to a payee
    /// @param token ERC20 token being released
    /// @param to Address receiving the payment
    /// @param amount Amount of tokens released
    event ERC20PaymentReleased(IERC20 indexed token, address to, uint256 amount);

    /// @notice Emitted when ETH is received by the contract
    /// @param from Address sending the ETH
    /// @param amount Amount of ETH received in wei
    event PaymentReceived(address from, uint256 amount);

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Total shares across all payees
    /// @dev Sum of all individual payee shares. Used as denominator in distribution calculations
    uint256 private _totalShares;

    /// @notice Total ETH released to all payees
    /// @dev Cumulative amount of ETH paid out. Used to calculate pending payments
    uint256 private _totalReleased;

    /// @notice Mapping of payee addresses to their share allocation
    /// @dev Set once during initialize(). Immutable after initialization
    mapping(address => uint256) private _shares;

    /// @notice Mapping of payee addresses to ETH already released to them
    /// @dev Tracks cumulative ETH paid to each payee
    mapping(address => uint256) private _released;

    /// @notice Array of all payee addresses
    /// @dev Used for enumeration. Set during initialize(). Immutable
    address[] private _payees;

    /// @notice Mapping of ERC20 tokens to total amount released
    /// @dev Tracks cumulative amount of each token paid out
    mapping(IERC20 => uint256) private _erc20TotalReleased;

    /// @notice Nested mapping of tokens to payees to amounts released
    /// @dev Tracks cumulative amount of each token paid to each payee
    mapping(IERC20 => mapping(address => uint256)) private _erc20Released;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Constructor disables direct initialization
     * @dev Prevents using this contract directly - must be used via proxy pattern
     *      Disables initializers so only proxy instances can be initialized
     */
    constructor() payable {
        _disableInitializers();
    }

    // ============================================
    // RECEIVE FUNCTION
    // ============================================

    /**
     * @notice Receives ETH payments and emits event
     * @dev WARNING: Events are not fully reliable - ETH can be received without triggering this
     *      (e.g., via selfdestruct). Event reliability doesn't affect actual payment splitting
     *
     *      See Solidity docs on fallback functions for details
     */
    receive() external payable virtual {
        emit PaymentReceived(_msgSender(), msg.value);
    }

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initializes the payment splitter with payees and their shares
     * @dev CRITICAL: Can only be called ONCE (enforced by initializer modifier)
     *      Sets immutable payee list and share allocations
     *
     *      VALIDATION:
     *      - Arrays must have same length
     *      - Arrays must be non-empty
     *      - All payee addresses must be non-zero
     *      - All shares must be > 0
     *      - No duplicate payees allowed
     *
     *      EXAMPLE:
     *      payees = [alice, bob, charlie]
     *      shares = [50, 30, 20]
     *      Result: Alice gets 50%, Bob gets 30%, Charlie gets 20%
     *
     * @param payees Array of payee addresses (cannot be zero addresses)
     * @param shares_ Array of proportional allocation shares for each payee (unitless, must all be > 0)
     * @custom:security Can only be called once via initializer
     * @custom:security Payee list is immutable after initialization
     */
    function initialize(address[] memory payees, uint256[] memory shares_) public payable initializer {
        require(payees.length == shares_.length, "PaymentSplitter: payees and shares length mismatch");
        require(payees.length > 0, "PaymentSplitter: no payees");

        for (uint256 i = 0; i < payees.length; i++) {
            _addPayee(payees[i], shares_[i]);
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the total shares across all payees
     * @dev Used as denominator in payment calculations
     * @return total Sum of all payee proportional allocation shares (unitless)
     */
    function totalShares() public view returns (uint256) {
        return _totalShares;
    }

    /**
     * @notice Returns total ETH released to all payees
     * @dev Cumulative amount paid out since deployment
     * @return total Total ETH released in wei
     */
    function totalReleased() public view returns (uint256) {
        return _totalReleased;
    }

    /**
     * @notice Returns total amount of an ERC20 token released to all payees
     * @dev Cumulative amount of specific token paid out
     * @param token Address of the ERC20 token contract
     * @return total Total tokens released
     */
    function totalReleased(IERC20 token) public view returns (uint256) {
        return _erc20TotalReleased[token];
    }

    /**
     * @notice Returns the share allocation for a payee
     * @dev Share count, not percentage. Percentage = shares / totalShares
     * @param account Address of the payee
     * @return shares Number of proportional allocation shares assigned to payee (unitless)
     */
    function shares(address account) public view returns (uint256) {
        return _shares[account];
    }

    /**
     * @notice Returns ETH already released to a payee
     * @dev Cumulative amount paid to this payee
     * @param account Address of the payee
     * @return amount ETH released in wei
     */
    function released(address account) public view returns (uint256) {
        return _released[account];
    }

    /**
     * @notice Returns amount of an ERC20 token already released to a payee
     * @dev Cumulative amount of specific token paid to this payee
     * @param token Address of the ERC20 token contract
     * @param account Address of the payee
     * @return amount Tokens released
     */
    function released(IERC20 token, address account) public view returns (uint256) {
        return _erc20Released[token][account];
    }

    /**
     * @notice Returns the payee address at a specific index
     * @dev Used for enumerating all payees
     * @param index Index in the payees array (0 to payees.length - 1)
     * @return payee Payee address at the index
     */
    function payee(uint256 index) public view returns (address) {
        return _payees[index];
    }

    /**
     * @notice Returns amount of ETH claimable by a payee
     * @dev Formula: (totalReceived * payeeShares / totalShares) - alreadyReleased
     *      totalReceived = current balance + total released
     * @param account Address of the payee
     * @return amount Claimable ETH in wei
     */
    function releasable(address account) public view returns (uint256) {
        uint256 totalReceived = address(this).balance + totalReleased();
        return _pendingPayment(account, totalReceived, released(account));
    }

    /**
     * @notice Returns amount of ERC20 tokens claimable by a payee
     * @dev Formula: (totalReceived * payeeShares / totalShares) - alreadyReleased
     *      totalReceived = current balance + total released
     * @param token Address of the ERC20 token contract
     * @param account Address of the payee
     * @return amount Claimable tokens
     */
    function releasable(IERC20 token, address account) public view returns (uint256) {
        uint256 totalReceived = token.balanceOf(address(this)) + totalReleased(token);
        return _pendingPayment(account, totalReceived, released(token, account));
    }

    // ============================================
    // RELEASE FUNCTIONS
    // ============================================

    /**
     * @notice Releases owed ETH to a payee
     * @dev Pull payment: payee calls this to claim their share of accumulated ETH
     *
     *      CALCULATION:
     *      payment = (totalReceived * payeeShares / totalShares) - alreadyReleased
     *
     *      REQUIREMENTS:
     *      - Account must have shares > 0
     *      - Payment must be > 0
     *
     *      EFFECTS:
     *      - Updates _totalReleased and _released[account]
     *      - Transfers ETH to account
     *      - Emits PaymentReleased event
     *
     * @param account Address of the payee to release payment to
     * @custom:security Uses OpenZeppelin's Address.sendValue for safe ETH transfer
     */
    function release(address payable account) public virtual {
        require(_shares[account] > 0, "PaymentSplitter: account has no shares");

        uint256 payment = releasable(account);

        require(payment != 0, "PaymentSplitter: account is not due payment");

        // _totalReleased is the sum of all values in _released.
        // If "_totalReleased += payment" does not overflow, then "_released[account] += payment" cannot overflow.
        _totalReleased += payment;
        unchecked {
            _released[account] += payment;
        }

        Address.sendValue(account, payment);
        emit PaymentReleased(account, payment);
    }

    /**
     * @notice Releases owed ERC20 tokens to a payee
     * @dev Pull payment: payee calls this to claim their share of accumulated tokens
     *
     *      CALCULATION:
     *      payment = (totalReceived * payeeShares / totalShares) - alreadyReleased
     *
     *      REQUIREMENTS:
     *      - Account must have shares > 0
     *      - Payment must be > 0
     *
     *      COMPATIBILITY WARNING:
     *      - Not compatible with rebasing tokens
     *      - Not compatible with fee-on-transfer tokens
     *      - Test with specific token before production use
     *
     * @param token Address of the ERC20 token contract
     * @param account Address of the payee to release payment to
     * @custom:security Uses SafeERC20 for safe token transfers
     */
    function release(IERC20 token, address account) public virtual {
        require(_shares[account] > 0, "PaymentSplitter: account has no shares");

        uint256 payment = releasable(token, account);

        require(payment != 0, "PaymentSplitter: account is not due payment");

        // _erc20TotalReleased[token] is the sum of all values in _erc20Released[token].
        // If "_erc20TotalReleased[token] += payment" does not overflow, then "_erc20Released[token][account] += payment"
        // cannot overflow.
        _erc20TotalReleased[token] += payment;
        unchecked {
            _erc20Released[token][account] += payment;
        }

        SafeERC20.safeTransfer(token, account, payment);
        emit ERC20PaymentReleased(token, account, payment);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @dev Calculates pending payment for a payee
     * @param account Payee address
     * @param totalReceived Total received (balance + released)
     * @param alreadyReleased Amount already paid to this payee
     * @return payment Amount currently owed to payee
     */
    function _pendingPayment(
        address account,
        uint256 totalReceived,
        uint256 alreadyReleased
    ) private view returns (uint256) {
        return (totalReceived * _shares[account]) / _totalShares - alreadyReleased;
    }

    /**
     * @param account Payee address (cannot be zero)
     * @param shares_ Number of shares to assign (must be > 0)
     */
    function _addPayee(address account, uint256 shares_) private {
        require(account != address(0), "PaymentSplitter: account is the zero address");
        require(shares_ > 0, "PaymentSplitter: shares are 0");
        require(_shares[account] == 0, "PaymentSplitter: account already has shares");

        // Add to payees array for enumeration
        _payees.push(account);
        // Record share allocation
        _shares[account] = shares_;
        // Update total shares
        _totalShares = _totalShares + shares_;

        emit PayeeAdded(account, shares_);
    }
}
