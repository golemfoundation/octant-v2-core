// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title ILinearAllowanceSingleton
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
/// @notice Interface for a module that allows to delegate spending allowances with linear accrual
interface ILinearAllowanceSingleton {
    /// @notice Structure defining an allowance with linear accrual
    struct LinearAllowance {
        uint192 dripRatePerDay;
        uint64 lastBookedAtInSeconds;
        uint256 totalUnspent;
        uint256 totalSpent;
    }

    /// @notice Emitted when an allowance is set for a delegate
    /// @param source Safe that owns the allowance
    /// @param delegate Authorized spender
    /// @param token Token being allowed
    /// @param dripRatePerDay Drip rate in token base units per day
    event AllowanceSet(address indexed source, address indexed delegate, address indexed token, uint192 dripRatePerDay);

    /// @notice Emitted when an allowance transfer is executed
    /// @param source Safe that owns the allowance
    /// @param delegate Authorized spender executing the transfer
    /// @param token Token being transferred
    /// @param to Recipient address
    /// @param amount Amount transferred in token base units
    event AllowanceTransferred(
        address indexed source,
        address indexed delegate,
        address indexed token,
        address to,
        uint256 amount
    );

    /// @notice Emitted when an allowance is revoked, clearing all accrued unspent amounts
    /// @param source Safe that owns the allowance
    /// @param delegate Spender whose allowance is revoked
    /// @param token Token for which allowance is revoked
    /// @param clearedAmount Amount of unspent allowance cleared in token base units
    event AllowanceRevoked(
        address indexed source,
        address indexed delegate,
        address indexed token,
        uint256 clearedAmount
    );

    error NoAllowanceToTransfer(address source, address delegate, address token);
    error TransferFailed(address source, address delegate, address token);
    error ZeroTransfer(address source, address delegate, address token);
    error AddressZeroForArgument(string argumentName);
    error ArrayLengthsMismatch(uint256 lengthOne, uint256 lengthTwo, uint256 lengthThree);
    error SafeTransactionFailed();

    /// @notice Set the allowance for a delegate. To revoke, set dripRatePerDay to 0. Revoking will not cancel any unspent allowance.
    /// @param delegate Authorized spender address
    /// @param token Use NATIVE_TOKEN for ETH, otherwise ERC20 address
    /// @param dripRatePerDay Drip rate in token base units per day
    function setAllowance(address delegate, address token, uint192 dripRatePerDay) external;

    /// @notice Set multiple allowances in a single transaction
    /// @param delegates Authorized spender addresses
    /// @param tokens Token addresses (use NATIVE_TOKEN for ETH)
    /// @param dripRatesPerDay Drip rates in token base units per day
    function setAllowances(
        address[] calldata delegates,
        address[] calldata tokens,
        uint192[] calldata dripRatesPerDay
    ) external;

    /// @notice Revocation that immediately zeros drip rate AND clears all accrued unspent allowance
    /// @dev This function provides immediate incident response capability for compromised delegates.
    /// Unlike setAllowance(delegate, token, 0) which preserves accrued amounts, this function
    /// completely revokes access by clearing both future accrual and existing unspent balances.
    /// @param delegate Spender whose allowance to revoke
    /// @param token Use NATIVE_TOKEN for ETH, otherwise ERC20 address
    function revokeAllowance(address delegate, address token) external;

    /// @notice Revoke multiple allowances in a single transaction
    /// @param delegates Spender addresses to revoke
    /// @param tokens Token addresses (use NATIVE_TOKEN for ETH)
    function revokeAllowances(address[] calldata delegates, address[] calldata tokens) external;

    /// @notice Execute a transfer of the allowance
    /// @dev msg.sender is the delegate
    /// @param source Safe address that owns the allowance
    /// @param token Use NATIVE_TOKEN for ETH, otherwise ERC20 address
    /// @param to Recipient address
    /// @return Amount actually transferred in token base units
    function executeAllowanceTransfer(address source, address token, address payable to) external returns (uint256);

    /// @notice Execute a batch of transfers of the allowance
    /// @dev msg.sender is the delegate
    /// @param safes Safe addresses that own the allowances
    /// @param tokens Token addresses to transfer (use NATIVE_TOKEN for ETH)
    /// @param tos Recipient addresses
    /// @return transferAmounts Amounts transferred for each operation in token base units
    function executeAllowanceTransfers(
        address[] calldata safes,
        address[] calldata tokens,
        address[] calldata tos
    ) external returns (uint256[] memory transferAmounts);

    /// @notice Get the total unspent allowance for a token as of now
    /// @param source Safe address owning the allowance
    /// @param delegate Authorized spender address
    /// @param token Use NATIVE_TOKEN for ETH, otherwise ERC20 address
    /// @return Total unspent allowance in token base units
    function getTotalUnspent(address source, address delegate, address token) external view returns (uint256);

    /// @notice Get the maximum withdrawable amount for a token, considering both allowance and Safe balance
    /// @param source Safe address owning the allowance
    /// @param delegate Authorized spender address
    /// @param token Use NATIVE_TOKEN for ETH, otherwise ERC20 address
    /// @return Maximum withdrawable amount in token base units (min of allowance and Safe balance)
    function getMaxWithdrawableAmount(address source, address delegate, address token) external view returns (uint256);
}
