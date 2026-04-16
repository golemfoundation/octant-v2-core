// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "../core/interfaces/ISwapper.sol";
import { IPSM, IExchange } from "../strategies/interfaces/IPSM.sol";

/**
 * @title PSMSwapper
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice ISwapper adapter for Sky Protocol Peg Stability Module (PSM) and DaiUsds converter
 * @dev Supports four swap routes for stablecoin conversions on Ethereum mainnet:
 *
 *      SELL_GEM:    gem (e.g., USDC) -> DAI/USDS via PSM (LitePSM or LitePSMWrapper)
 *      BUY_GEM:     DAI/USDS -> gem (e.g., USDC) via PSM (LitePSM or LitePSMWrapper)
 *      DAI_TO_USDS: DAI -> USDS via DaiUsds converter (always 1:1, permanently fee-free)
 *      USDS_TO_DAI: USDS -> DAI via DaiUsds converter (always 1:1, permanently fee-free)
 *
 *      Key addresses on Ethereum mainnet:
 *      - LitePSM (USDC/DAI):     0xf6e72Db5454dd049d0788e411b06CfAF16853042
 *      - LitePSMWrapper (USDC/USDS): 0xA188EEC8F81263234dA3622A406892F3d630f98c
 *      - DaiUsds converter:       0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A
 *
 *      PSM fees (tin/tout) are currently 0% but are governance-controlled and may change.
 *      The BUY_GEM route dynamically queries tout() to calculate the correct gem amount.
 *
 *      This contract is fully immutable and holds no tokens between calls.
 */
contract PSMSwapper is ISwapper {
    using SafeERC20 for IERC20;

    // ============================================
    // TYPES
    // ============================================

    enum Route {
        SELL_GEM, // gem (e.g., USDC) -> DAI/USDS via IPSM.sellGem()
        BUY_GEM, // DAI/USDS -> gem (e.g., USDC) via IPSM.buyGem()
        DAI_TO_USDS, // DAI -> USDS via IExchange.daiToUsds()
        USDS_TO_DAI // USDS -> DAI via IExchange.usdsToDai()
    }

    // ============================================
    // CONSTANTS
    // ============================================

    /// @dev 1e18, used for PSM fee calculations
    uint256 internal constant WAD = 1e18;

    // ============================================
    // STATE
    // ============================================

    /// @notice The PSM or DaiUsds converter contract address
    address public immutable protocol;

    /// @notice The configured swap direction
    Route public immutable route;

    /// @notice The expected input token for this swapper instance
    address public immutable tokenIn;

    /// @notice The expected output token for this swapper instance
    address public immutable tokenOut;

    /// @notice Decimal conversion factor between gem and DAI/USDS (e.g., 1e12 for USDC)
    /// @dev Only used for BUY_GEM route. Set to 0 for other routes.
    uint256 public immutable conversionFactor;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the protocol address is zero
    error InvalidProtocol();

    /// @notice Thrown when a token address is zero or does not match the configured route
    error InvalidToken();

    /// @notice Thrown when the swap output is less than the minimum required
    /// @param expected Minimum amount expected
    /// @param actual Amount actually received
    error InsufficientOutput(uint256 expected, uint256 actual);

    /// @notice Thrown when a 1:1 DaiUsds conversion does not produce exact output
    /// @param expected The input amount (expected output for 1:1)
    /// @param actual Amount actually received
    error NonOneToOneConversion(uint256 expected, uint256 actual);

    /// @notice Thrown when conversionFactor is zero for the BUY_GEM route
    error InvalidConversionFactor();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a PSMSwapper configured for a specific stablecoin swap route
    /// @param _protocol Address of the PSM or DaiUsds converter contract
    /// @param _route The swap direction this instance handles
    /// @param _tokenIn Address of the input token
    /// @param _tokenOut Address of the output token
    /// @param _conversionFactor Decimal scaling factor (e.g., 1e12 for 6->18 decimal conversion).
    ///        Required for BUY_GEM, ignored for other routes.
    constructor(address _protocol, Route _route, address _tokenIn, address _tokenOut, uint256 _conversionFactor) {
        if (_protocol == address(0)) revert InvalidProtocol();
        if (_tokenIn == address(0) || _tokenOut == address(0)) revert InvalidToken();
        if (_route == Route.BUY_GEM && _conversionFactor == 0) revert InvalidConversionFactor();
        protocol = _protocol;
        route = _route;
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        conversionFactor = _conversionFactor;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /// @inheritdoc ISwapper
    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external override returns (uint256 amountOut) {
        if (_tokenIn != tokenIn || _tokenOut != tokenOut) revert InvalidToken();

        // Per-route pull pattern. BUY_GEM computes the exact PSM charge
        // upfront and pulls only that (rounding remainder stays with caller);
        // the other routes consume the full amountIn so we pull it here.
        if (route == Route.SELL_GEM) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            amountOut = _sellGem(amountIn, receiver);
        } else if (route == Route.BUY_GEM) {
            amountOut = _buyGem(amountIn, receiver);
        } else if (route == Route.DAI_TO_USDS) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            amountOut = _daiToUsds(amountIn, receiver);
            minAmountOut = amountIn; // 1:1 converter, enforce exact output
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            amountOut = _usdsToDai(amountIn, receiver);
            minAmountOut = amountIn; // 1:1 converter, enforce exact output
        }

        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);

        // Defense-in-depth: flush any residual tokenIn back to the caller so
        // the adapter upholds the stateless invariant on every route.
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
        if (leftover != 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, leftover);
        }
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /// @dev Sell gem (e.g., USDC) for DAI/USDS via PSM.
    ///      PSM pulls gem from this contract and sends DAI/USDS to this contract,
    ///      which then forwards to receiver.
    function _sellGem(uint256 amountIn, address receiver) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(protocol, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IPSM(protocol).sellGem(address(this), amountIn);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        IERC20(tokenIn).forceApprove(protocol, 0);

        IERC20(tokenOut).safeTransfer(receiver, amountOut);
    }

    /// @dev Buy gem (e.g., USDC) with DAI/USDS via PSM.
    ///      Calculates max gem purchasable from amountIn accounting for PSM fees (tout),
    ///      then pulls ONLY the exact charge (gemAmt * conversionFactor * (WAD + tout) / WAD)
    ///      via transferFrom so the floor-division remainder stays with the caller
    ///      rather than being stranded in this adapter (bailsec #70).
    function _buyGem(uint256 amountIn, address receiver) internal returns (uint256 amountOut) {
        uint256 tout = IPSM(protocol).tout();
        uint256 gemAmt = (amountIn * WAD) / (conversionFactor * (WAD + tout));
        if (gemAmt == 0) revert InsufficientOutput(1, 0);

        uint256 actualPulled = (gemAmt * conversionFactor * (WAD + tout)) / WAD;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), actualPulled);
        IERC20(tokenIn).forceApprove(protocol, actualPulled);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IPSM(protocol).buyGem(address(this), gemAmt);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        IERC20(tokenIn).forceApprove(protocol, 0);

        IERC20(tokenOut).safeTransfer(receiver, amountOut);
    }

    /// @dev Convert DAI to USDS via DaiUsds converter (always 1:1, permanently fee-free).
    ///      Output is sent directly to receiver by the converter contract.
    ///      Reverts if the actual output does not match amountIn exactly.
    function _daiToUsds(uint256 amountIn, address receiver) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(protocol, amountIn);
        uint256 balBefore = IERC20(tokenOut).balanceOf(receiver);
        IExchange(protocol).daiToUsds(receiver, amountIn);
        amountOut = IERC20(tokenOut).balanceOf(receiver) - balBefore;
        if (amountOut != amountIn) revert NonOneToOneConversion(amountIn, amountOut);
    }

    /// @dev Convert USDS to DAI via DaiUsds converter (always 1:1, permanently fee-free).
    ///      Output is sent directly to receiver by the converter contract.
    ///      Reverts if the actual output does not match amountIn exactly.
    function _usdsToDai(uint256 amountIn, address receiver) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(protocol, amountIn);
        uint256 balBefore = IERC20(tokenOut).balanceOf(receiver);
        IExchange(protocol).usdsToDai(receiver, amountIn);
        amountOut = IERC20(tokenOut).balanceOf(receiver) - balBefore;
        if (amountOut != amountIn) revert NonOneToOneConversion(amountIn, amountOut);
    }
}
