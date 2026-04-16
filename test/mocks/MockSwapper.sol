// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "src/core/interfaces/ISwapper.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Mock swapper for unit testing SwappingYieldForwarder
/// @dev Pulls tokenIn via transferFrom (pull-pattern ISwapper semantic) and
///      mints output tokens at a configurable rate.
contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;

    address public immutable outputToken;
    uint256 public exchangeRate; // WAD (1e18 = 1:1)

    error InsufficientOutput(uint256 expected, uint256 actual);

    constructor(address _outputToken, uint256 _exchangeRate) {
        outputToken = _outputToken;
        exchangeRate = _exchangeRate;
    }

    function swap(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * exchangeRate) / 1e18;
        if (amountOut < minAmountOut) revert InsufficientOutput(minAmountOut, amountOut);
        ERC20Mock(outputToken).mint(receiver, amountOut);
        return amountOut;
    }
}
