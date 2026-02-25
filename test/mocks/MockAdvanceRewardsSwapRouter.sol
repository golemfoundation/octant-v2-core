// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Minimal Uniswap V3 router mock for advance rewards tests
contract MockAdvanceRewardsSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    error MockInsufficientOutput(uint256 actualOut, uint256 minOut);

    uint256 public outputBps = 10_000;

    function setOutputBps(uint256 _outputBps) external {
        outputBps = _outputBps;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * outputBps) / 10_000;
        if (amountOut < params.amountOutMinimum) {
            revert MockInsufficientOutput(amountOut, params.amountOutMinimum);
        }
        IMintableToken(params.tokenOut).mint(params.recipient, amountOut);
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {
        revert("unsupported");
    }
}
