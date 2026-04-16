// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockForwarderSwapper
 * @notice Minimal ISwapper mock for Kontrol formal verification of SwappingYieldForwarder
 * @dev Pull-pattern compatible: pulls tokenIn from msg.sender via transferFrom,
 *      captures arguments, and returns a controllable swap output value.
 *
 *      Storage layout (all plain slots, no ERC-7201):
 *        slot 0: mockSwapReturn    -- returned by swap()
 *        slot 1: lastSwapReceiver  -- captures receiver arg
 *        slot 2: lastTokenIn       -- captures tokenIn arg
 *        slot 3: lastTokenOut      -- captures tokenOut arg
 *        slot 4: lastAmountIn      -- captures amountIn arg
 *        slot 5: lastMinAmountOut  -- captures minAmountOut arg
 */
contract MockForwarderSwapper {
    using SafeERC20 for IERC20;

    uint256 public mockSwapReturn;
    address public lastSwapReceiver;
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastMinAmountOut;

    /// @notice Mock swap that pulls tokenIn, captures arguments, and returns a controllable output
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        lastTokenIn = tokenIn;
        lastTokenOut = tokenOut;
        lastAmountIn = amountIn;
        lastMinAmountOut = minAmountOut;
        lastSwapReceiver = receiver;
        return mockSwapReturn;
    }
}
