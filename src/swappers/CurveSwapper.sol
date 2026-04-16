// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "../core/interfaces/ISwapper.sol";

/// @notice Minimal interface for Curve StableSwap pool exchange
/// @dev Covers Curve V1 (StableSwap) pools that use int128 indices.
///      Uses non-returning variant for compatibility with legacy pools (e.g., 3Pool)
///      that do not return the output amount. Balance measurement is used instead.
interface ICurvePool {
    /// @notice Returns the token address at the given index in the pool
    /// @param index Index of the token in the pool's coins array
    function coins(uint256 index) external view returns (address);

    /// @notice Exchange tokens within the pool
    /// @param i Index of the input token in the pool
    /// @param j Index of the output token in the pool
    /// @param dx Amount of input token to swap
    /// @param min_dy Minimum amount of output token to receive
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

/**
 * @title CurveSwapper
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice ISwapper adapter for direct Curve StableSwap pool exchanges
 * @dev Performs single-pool swaps between correlated/pegged ERC20 assets via Curve's
 *      StableSwap invariant, which provides near-zero slippage for pegged pairs.
 *
 *      Each deployment is configured for a specific pool and token pair via immutables.
 *      Uses direct pool calls (not the Curve Router) for gas efficiency since the
 *      exact pool is known at deploy time.
 *
 *      Key Curve pools on Ethereum mainnet:
 *      - stETH/ETH:     0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 (indices: 0=ETH, 1=stETH)
 *      - rETH/wstETH:   0x447ddd4960d9fdbf6af9a790560d0af76795cb08 (indices: 0=rETH, 1=wstETH)
 *      - 3Pool:         0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1c7 (indices: 0=DAI, 1=USDC, 2=USDT)
 *
 *      LIMITATIONS:
 *      - ERC20-to-ERC20 only. Does not handle native ETH output (pools that return ETH
 *        require wrapping to WETH which is not supported). For ETH-involving swaps,
 *        use UniswapV3SwapperAdapter with WETH instead.
 *      - Only supports Curve V1 (StableSwap) pools with int128 indices.
 *
 *      This contract is fully immutable and holds no tokens between calls.
 */
contract CurveSwapper is ISwapper {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the pool address is zero
    error InvalidPool();

    /// @notice Thrown when a token address is zero or does not match the configured pair
    error InvalidToken();

    /// @notice Thrown when pool indices are identical
    error InvalidIndices();

    /// @notice Thrown when a token address does not match the pool's coins at the given index
    error TokenIndexMismatch();

    // ============================================
    // STATE
    // ============================================

    /// @notice The Curve pool to swap through
    address public immutable pool;

    /// @notice Index of the input token in the Curve pool
    int128 public immutable indexIn;

    /// @notice Index of the output token in the Curve pool
    int128 public immutable indexOut;

    /// @notice The expected input token for this swapper instance
    address public immutable tokenIn;

    /// @notice The expected output token for this swapper instance
    address public immutable tokenOut;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a CurveSwapper configured for a specific pool and token pair
    /// @param _pool Address of the Curve StableSwap pool
    /// @param _indexIn Index of tokenIn in the pool's coins array
    /// @param _indexOut Index of tokenOut in the pool's coins array
    /// @param _tokenIn Address of the input token (must match pool.coins[_indexIn])
    /// @param _tokenOut Address of the output token (must match pool.coins[_indexOut])
    constructor(address _pool, int128 _indexIn, int128 _indexOut, address _tokenIn, address _tokenOut) {
        if (_pool == address(0)) revert InvalidPool();
        if (_tokenIn == address(0) || _tokenOut == address(0)) revert InvalidToken();
        if (_indexIn == _indexOut) revert InvalidIndices();
        if (ICurvePool(_pool).coins(uint256(int256(_indexIn))) != _tokenIn) revert TokenIndexMismatch();
        if (ICurvePool(_pool).coins(uint256(int256(_indexOut))) != _tokenOut) revert TokenIndexMismatch();
        pool = _pool;
        indexIn = _indexIn;
        indexOut = _indexOut;
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /// @inheritdoc ISwapper
    /// @dev Uses balance measurement for compatibility with legacy Curve pools (e.g., 3Pool)
    ///      whose exchange() does not return the output amount.
    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external override returns (uint256 amountOut) {
        if (_tokenIn != tokenIn || _tokenOut != tokenOut) revert InvalidToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(pool, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        ICurvePool(pool).exchange(indexIn, indexOut, amountIn, minAmountOut);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        IERC20(tokenIn).forceApprove(pool, 0);

        IERC20(tokenOut).safeTransfer(receiver, amountOut);

        // Zero-residue invariant (cantina #1): Curve pools normally pull
        // the full `amountIn`, but any tokenIn that ended up here — whether
        // from an unusual pool implementation or a donation — is returned
        // to the caller so the adapter upholds its stateless-between-calls
        // contract on every path.
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
        if (leftover != 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, leftover);
        }
    }
}
