// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

/**
 * @title ISwapper
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Minimal interface for pluggable token swap adapters
 * @dev Implementations are expected to be stateless and hold no tokens between calls.
 *      The caller MUST approve this contract for at least `amountIn` of `tokenIn`
 *      before calling swap(); the implementation pulls tokens via transferFrom.
 *      Any unused `tokenIn` (e.g. from a partial fill) MUST be returned to
 *      msg.sender before swap() returns.
 */
interface ISwapper {
    /// @notice Execute a token swap and send output to receiver
    /// @dev The caller MUST have approved this contract for at least `amountIn`
    ///      of `tokenIn` before calling. The implementation pulls via
    ///      transferFrom(msg.sender, this, amountIn) and returns any unused
    ///      `tokenIn` to msg.sender before returning.
    ///      Reverts if output is less than `minAmountOut`.
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Maximum amount of tokenIn to pull from msg.sender
    /// @param minAmountOut Minimum acceptable output amount (reverts if not met)
    /// @param receiver Address to receive the output tokens
    /// @return amountOut Actual amount of tokenOut sent to receiver
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256 amountOut);
}
