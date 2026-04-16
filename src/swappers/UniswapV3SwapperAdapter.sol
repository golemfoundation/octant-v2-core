// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "@tokenized-strategy-periphery/interfaces/Uniswap/V3/ISwapRouter.sol";
import { ISwapper } from "../core/interfaces/ISwapper.sol";

/**
 * @title UniswapV3SwapperAdapter
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice ISwapper adapter for Uniswap V3 exact-input swaps
 * @dev Supports both single-hop and multi-hop (via intermediate base token) swaps.
 *
 *      Single-hop: tokenIn --(fee)--> tokenOut
 *      Multi-hop:  tokenIn --(fee)--> base --(feeOut)--> tokenOut
 *
 *      The routing mode is determined by the `base` constructor parameter:
 *      - base == address(0): always single-hop with `fee`
 *      - base != address(0): multi-hop unless tokenIn or tokenOut IS the base token,
 *        in which case it falls back to single-hop with the appropriate fee tier
 *
 *      Uniswap V3 Router on Ethereum mainnet: 0xE592427A0AEce92De3Edee1F18E0157C05861564
 *      Common base token (WETH):               0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
 *
 *      Common fee tiers: 100 (0.01%), 500 (0.05%), 3000 (0.3%), 10000 (1%)
 *
 *      This contract is fully immutable and holds no tokens between calls.
 */
contract UniswapV3SwapperAdapter is ISwapper {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the router address is zero
    error InvalidRouter();

    /// @notice Thrown when a token address is zero
    error InvalidToken();

    // ============================================
    // STATE
    // ============================================

    /// @notice The Uniswap V3 SwapRouter address
    address public immutable router;

    /// @notice Fee tier for direct swaps or the first hop (tokenIn -> base)
    uint24 public immutable fee;

    /// @notice Optional intermediate token for multi-hop routing (address(0) = direct swap)
    address public immutable base;

    /// @notice Fee tier for the second hop (base -> tokenOut), only used when base != address(0)
    uint24 public immutable feeOut;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a UniswapV3SwapperAdapter with fixed routing configuration
    /// @param _router Address of the Uniswap V3 SwapRouter
    /// @param _fee Fee tier for direct swaps or first hop (e.g., 3000 for 0.3%)
    /// @param _base Optional base token for multi-hop routing (address(0) for direct swaps)
    /// @param _feeOut Fee tier for second hop when using multi-hop (ignored if _base is address(0))
    constructor(address _router, uint24 _fee, address _base, uint24 _feeOut) {
        if (_router == address(0)) revert InvalidRouter();
        router = _router;
        fee = _fee;
        base = _base;
        feeOut = _feeOut;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /// @inheritdoc ISwapper
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external override returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(router, amountIn);

        if (base == address(0) || tokenIn == base || tokenOut == base) {
            // Single-hop swap
            // If tokenIn IS the base, use feeOut (base -> tokenOut pool)
            // Otherwise use fee (tokenIn -> base/tokenOut pool)
            uint24 poolFee = (base != address(0) && tokenIn == base) ? feeOut : fee;

            amountOut = ISwapRouter(router).exactInputSingle(
                ISwapRouter.ExactInputSingleParams(
                    tokenIn,
                    tokenOut,
                    poolFee,
                    receiver,
                    block.timestamp,
                    amountIn,
                    minAmountOut,
                    0
                )
            );
        } else {
            // Multi-hop: tokenIn --(fee)--> base --(feeOut)--> tokenOut
            bytes memory path = abi.encodePacked(tokenIn, fee, base, feeOut, tokenOut);

            amountOut = ISwapRouter(router).exactInput(
                ISwapRouter.ExactInputParams(path, receiver, block.timestamp, amountIn, minAmountOut)
            );
        }
    }
}
