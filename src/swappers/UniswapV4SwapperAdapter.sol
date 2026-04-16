// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "../core/interfaces/ISwapper.sol";

/// @notice Minimal Uniswap V4 PoolManager interface for executing swaps
/// @dev Only the functions needed by UniswapV4SwapperAdapter are included.
///      Currency in V4 is a user-defined type wrapping address; the ABI encoding is identical.
interface IV4PoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    /// @dev Returns BalanceDelta (a packed int256: upper 128 bits = amount0, lower 128 bits = amount1).
    ///      Negative = caller must settle (pay), Positive = caller may take (receive).
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (int256 swapDelta);

    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/**
 * @title UniswapV4SwapperAdapter
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice ISwapper adapter for Uniswap V4 exact-input swaps via the singleton PoolManager
 * @dev Supports both single-hop and multi-hop (via intermediate base token) swaps,
 *      mirroring the routing logic of UniswapV3SwapperAdapter.
 *
 *      Single-hop: tokenIn --(fee/tickSpacing/hooks)--> tokenOut
 *      Multi-hop:  tokenIn --(fee/tickSpacing/hooks)--> base --(feeOut/tickSpacingOut/hooksOut)--> tokenOut
 *
 *      The routing mode is determined by the `base` constructor parameter:
 *      - base == address(0): always single-hop
 *      - base != address(0): multi-hop unless tokenIn or tokenOut IS the base token,
 *        in which case it falls back to single-hop with the appropriate pool config
 *
 *      Settlement uses V4's sync/transfer/settle pattern for input tokens
 *      and take() for output tokens. No ERC20 approvals are needed.
 *
 *      Uniswap V4 PoolManager on Ethereum mainnet: 0x000000000004444c5dc75cB358380D2e3dE08A90
 *
 *      This contract is fully immutable and holds no tokens between calls.
 */
contract UniswapV4SwapperAdapter is ISwapper {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the PoolManager address is zero
    error InvalidPoolManager();

    /// @notice Thrown when a token address is zero
    error InvalidToken();

    /// @notice Thrown when tickSpacing is zero (invalid V4 pool configuration)
    error InvalidTickSpacing();

    /// @notice Thrown when the callback caller is not the PoolManager
    error UnauthorizedCallback();

    /// @notice Thrown when the swap output is less than the minimum required
    /// @param expected Minimum amount expected
    /// @param actual Amount actually received
    error InsufficientOutput(uint256 expected, uint256 actual);

    // ============================================
    // CONSTANTS
    // ============================================

    /// @dev Minimum sqrt price limit for V4 swaps (TickMath.MIN_SQRT_PRICE + 1)
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

    /// @dev Maximum sqrt price limit for V4 swaps (TickMath.MAX_SQRT_PRICE - 1)
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    // ============================================
    // STATE
    // ============================================

    /// @notice The Uniswap V4 PoolManager singleton address
    address public immutable poolManager;

    /// @notice Fee tier for direct swaps or the first hop (tokenIn -> base)
    uint24 public immutable fee;

    /// @notice Tick spacing for direct swaps or the first hop
    int24 public immutable tickSpacing;

    /// @notice Hooks address for direct swaps or the first hop (address(0) = no hooks)
    address public immutable hooks;

    /// @notice Optional intermediate token for multi-hop routing (address(0) = direct swap)
    address public immutable base;

    /// @notice Fee tier for the second hop (base -> tokenOut), only used when base != address(0)
    uint24 public immutable feeOut;

    /// @notice Tick spacing for the second hop, only used when base != address(0)
    int24 public immutable tickSpacingOut;

    /// @notice Hooks address for the second hop (address(0) = no hooks)
    address public immutable hooksOut;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a UniswapV4SwapperAdapter with fixed routing configuration
    /// @param _poolManager Address of the Uniswap V4 PoolManager singleton
    /// @param _fee Fee tier for direct swaps or first hop
    /// @param _tickSpacing Tick spacing for direct swaps or first hop
    /// @param _hooks Hooks address for direct swaps or first hop (address(0) = no hooks)
    /// @param _base Optional base token for multi-hop routing (address(0) for direct swaps)
    /// @param _feeOut Fee tier for second hop when using multi-hop (ignored if _base is address(0))
    /// @param _tickSpacingOut Tick spacing for second hop (ignored if _base is address(0))
    /// @param _hooksOut Hooks address for second hop (ignored if _base is address(0))
    constructor(
        address _poolManager,
        uint24 _fee,
        int24 _tickSpacing,
        address _hooks,
        address _base,
        uint24 _feeOut,
        int24 _tickSpacingOut,
        address _hooksOut
    ) {
        if (_poolManager == address(0)) revert InvalidPoolManager();
        if (_tickSpacing == 0) revert InvalidTickSpacing();
        if (_base != address(0) && _tickSpacingOut == 0) revert InvalidTickSpacing();

        poolManager = _poolManager;
        fee = _fee;
        tickSpacing = _tickSpacing;
        hooks = _hooks;
        base = _base;
        feeOut = _feeOut;
        tickSpacingOut = _tickSpacingOut;
        hooksOut = _hooksOut;
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

        bytes memory result = IV4PoolManager(poolManager).unlock(
            abi.encode(tokenIn, tokenOut, amountIn, minAmountOut, receiver)
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @notice Callback invoked by PoolManager during unlock(); executes swaps and settles
    /// @dev Only callable by the PoolManager. Reverts with UnauthorizedCallback otherwise.
    /// @param data ABI-encoded (tokenIn, tokenOut, amountIn, minAmountOut, receiver)
    /// @return ABI-encoded amountOut
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert UnauthorizedCallback();

        (address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address receiver) = abi.decode(
            data,
            (address, address, uint256, uint256, address)
        );

        uint256 amountOut;

        if (base == address(0) || tokenIn == base || tokenOut == base) {
            amountOut = _singleHop(tokenIn, tokenOut, amountIn);
        } else {
            amountOut = _multiHop(tokenIn, tokenOut, amountIn);
        }

        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);

        // Settle input: sync balance snapshot → transfer tokens → settle delta
        IV4PoolManager(poolManager).sync(tokenIn);
        IERC20(tokenIn).safeTransfer(poolManager, amountIn);
        IV4PoolManager(poolManager).settle();

        // Take output directly to receiver
        IV4PoolManager(poolManager).take(tokenOut, receiver, amountOut);

        return abi.encode(amountOut);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /// @dev Execute a single-hop exact-input swap and return the output amount
    function _singleHop(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        // Select pool config: if tokenIn IS the base, use second-hop config
        uint24 poolFee = (base != address(0) && tokenIn == base) ? feeOut : fee;
        int24 poolTickSpacing = (base != address(0) && tokenIn == base) ? tickSpacingOut : tickSpacing;
        address poolHooks = (base != address(0) && tokenIn == base) ? hooksOut : hooks;

        // V4 requires currency0 < currency1 in the PoolKey
        bool zeroForOne = tokenIn < tokenOut;
        (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);

        int256 delta = IV4PoolManager(poolManager).swap(
            IV4PoolManager.PoolKey(c0, c1, poolFee, poolTickSpacing, poolHooks),
            IV4PoolManager.SwapParams(
                zeroForOne,
                -int256(amountIn), // negative = exact input in V4
                zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            ),
            ""
        );

        // Extract output from packed BalanceDelta (upper 128 = amount0, lower 128 = amount1)
        // Output is the positive delta: amount1 for zeroForOne, amount0 for !zeroForOne
        amountOut = uint256(int256(zeroForOne ? int128(delta) : int128(delta >> 128)));
    }

    /// @dev Execute a two-hop exact-input swap: tokenIn → base → tokenOut
    ///      Base token deltas net to zero within the PoolManager's accounting.
    function _multiHop(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        // ── Hop 1: tokenIn → base ──
        bool zfo1 = tokenIn < base;
        (address c0_1, address c1_1) = zfo1 ? (tokenIn, base) : (base, tokenIn);

        int256 delta1 = IV4PoolManager(poolManager).swap(
            IV4PoolManager.PoolKey(c0_1, c1_1, fee, tickSpacing, hooks),
            IV4PoolManager.SwapParams(zfo1, -int256(amountIn), zfo1 ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT),
            ""
        );

        // Extract base amount received (positive delta)
        uint256 baseAmount = uint256(int256(zfo1 ? int128(delta1) : int128(delta1 >> 128)));

        // ── Hop 2: base → tokenOut ──
        bool zfo2 = base < tokenOut;
        (address c0_2, address c1_2) = zfo2 ? (base, tokenOut) : (tokenOut, base);

        int256 delta2 = IV4PoolManager(poolManager).swap(
            IV4PoolManager.PoolKey(c0_2, c1_2, feeOut, tickSpacingOut, hooksOut),
            IV4PoolManager.SwapParams(zfo2, -int256(baseAmount), zfo2 ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT),
            ""
        );

        // Extract final output amount (positive delta)
        amountOut = uint256(int256(zfo2 ? int128(delta2) : int128(delta2 >> 128)));
    }
}
