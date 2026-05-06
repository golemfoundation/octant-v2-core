// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DirectTransfer
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Dedicated passthrough contract for logged ERC20 transfers between two addresses
 * @dev Caller must first approve this contract to spend the relevant token. The contract
 *      pulls the token from the caller via `safeTransferFrom` and pushes it to the
 *      recipient in the same call, emitting a single event per transfer. Stateless and
 *      token-agnostic — one deployment per chain serves every supported ERC20.
 *
 *      Block number, timestamp, and transaction hash are intentionally omitted from the
 *      event payload. Every indexer attaches them to each log automatically, so emitting
 *      them on-chain would only duplicate data and waste gas.
 *
 *      Intended for standard ERC20s only (e.g. WETH). Fee-on-transfer, deflationary, and
 *      rebasing tokens are out of scope: the emitted `amount` equals the requested amount,
 *      not the recipient's balance delta, so events would not reflect the value actually
 *      received by `to` for such tokens.
 */
contract DirectTransfer {
    using SafeERC20 for IERC20;

    /// @notice Emitted on every successful transfer routed through this contract
    /// @param token ERC20 token transferred
    /// @param from Address sending the token (token spender, equal to msg.sender)
    /// @param to Address receiving the token
    /// @param amount Amount of the token transferred, in the token's smallest unit
    event Transferred(address indexed token, address indexed from, address indexed to, uint256 amount);

    /// @notice Thrown when the token address is the zero address
    error ZeroToken();

    /// @notice Thrown when the recipient address is the zero address
    error ZeroRecipient();

    /// @notice Thrown when the transfer amount is zero
    error ZeroAmount();

    /// @notice Transfer ERC20 tokens from the caller to `to` and emit a `Transferred` event
    /// @dev Caller must have approved at least `amount` of `token` to this contract.
    ///      Reverts if the token or recipient is the zero address or the amount is zero.
    /// @param token ERC20 token to transfer
    /// @param to Address receiving the token
    /// @param amount Amount of the token to transfer, in the token's smallest unit
    function transfer(IERC20 token, address to, uint256 amount) external {
        if (address(token) == address(0)) revert ZeroToken();
        if (to == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, to, amount);

        emit Transferred(address(token), msg.sender, to, amount);
    }
}
