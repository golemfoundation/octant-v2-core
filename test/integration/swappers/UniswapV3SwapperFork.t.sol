// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniswapV3Swapper } from "src/strategies/periphery/UniswapV3Swapper.sol";
import { MorphoTestConfig } from "test/integration/strategies/config/MorphoTestConfig.sol";

contract UniswapV3SwapperHarness is UniswapV3Swapper {
    constructor(address _router, address _base, address _token0, address _token1, uint24 _fee) {
        router = _router;
        base = _base;
        minAmountToSell = 0;
        _setUniFees(_token0, _token1, _fee);
    }

    function exposedSwapFrom(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external returns (uint256) {
        return _swapFrom(_from, _to, _amountIn, _minAmountOut);
    }
}

/// @notice Mainnet-fork PoC coverage for the strategy periphery Uniswap V3 swapper.
contract UniswapV3SwapperForkTest is Test {
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint24 internal constant FEE_USDC_WETH = 500;
    uint256 internal constant SWAP_AMOUNT_USDC = 10_000e6;

    UniswapV3SwapperHarness internal swapper;

    function setUp() public {
        uint256 forkId = vm.createFork("mainnet", MorphoTestConfig.FORK_BLOCK);
        vm.selectFork(forkId);

        swapper = new UniswapV3SwapperHarness(UNISWAP_V3_ROUTER, WETH, USDC, WETH, FEE_USDC_WETH);

        vm.label(UNISWAP_V3_ROUTER, "UniswapV3Router");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(address(swapper), "UniswapV3SwapperHarness");
    }

    function testFork_swapFromWithZeroMinAmountOutExecutesAgainstMainnetPool() public {
        deal(USDC, address(swapper), SWAP_AMOUNT_USDC);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(swapper));
        uint256 delayedTimestamp = block.timestamp + 1 days;
        vm.warp(delayedTimestamp);

        uint256 amountOut = swapper.exposedSwapFrom(USDC, WETH, SWAP_AMOUNT_USDC, 0);

        uint256 wethReceived = IERC20(WETH).balanceOf(address(swapper)) - wethBefore;
        assertEq(block.timestamp, delayedTimestamp, "Swap should use the execution block timestamp");
        assertGt(amountOut, 0, "Mainnet USDC/WETH pool should return WETH");
        assertEq(wethReceived, amountOut, "Returned amount should match WETH balance delta");
        assertEq(IERC20(USDC).balanceOf(address(swapper)), 0, "Exact input swap should spend all USDC");
    }

    function testFork_swapFromRevertsWhenMinAmountOutExceedsMainnetPrice() public {
        deal(USDC, address(swapper), SWAP_AMOUNT_USDC);

        vm.expectRevert();
        swapper.exposedSwapFrom(USDC, WETH, SWAP_AMOUNT_USDC, type(uint256).max);

        assertEq(IERC20(WETH).balanceOf(address(swapper)), 0, "No WETH should be received after revert");
        assertEq(IERC20(USDC).balanceOf(address(swapper)), SWAP_AMOUNT_USDC, "USDC should remain after revert");
    }
}
