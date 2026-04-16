// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ISwapRouter } from "@tokenized-strategy-periphery/interfaces/Uniswap/V3/ISwapRouter.sol";

import { UniswapV3SwapperAdapter } from "src/swappers/UniswapV3SwapperAdapter.sol";

contract UniswapV3SwapperAdapterTest is Test {
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    ERC20Mock public baseToken;
    MockUniRouter public router;

    address public receiver = address(0xBEEF);

    uint24 internal constant FEE = 3000;
    uint24 internal constant FEE_OUT = 500;

    function setUp() public {
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        baseToken = new ERC20Mock();
        router = new MockUniRouter();

        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(baseToken), "BaseToken");
        vm.label(address(router), "Router");
        vm.label(receiver, "Receiver");
    }

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(baseToken), FEE_OUT);
        assertEq(s.router(), address(router));
        assertEq(s.fee(), FEE);
        assertEq(s.base(), address(baseToken));
        assertEq(s.feeOut(), FEE_OUT);
    }

    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(UniswapV3SwapperAdapter.InvalidRouter.selector);
        new UniswapV3SwapperAdapter(address(0), FEE, address(baseToken), FEE_OUT);
    }

    function test_constructor_allowsZeroBase() public {
        // base == address(0) is valid — means direct swap
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(0), 0);
        assertEq(s.base(), address(0));
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — TOKEN VALIDATION
    // ═══════════════════════════════════════════════════════════

    function test_swap_revertsOnZeroTokenIn() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(0), 0);
        vm.expectRevert(UniswapV3SwapperAdapter.InvalidToken.selector);
        s.swap(address(0), address(tokenB), 100, 0, receiver);
    }

    function test_swap_revertsOnZeroTokenOut() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(0), 0);
        vm.expectRevert(UniswapV3SwapperAdapter.InvalidToken.selector);
        s.swap(address(tokenA), address(0), 100, 0, receiver);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (no base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_noBase() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(0), 0);

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);

        router.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Single-hop should return 1:1 from mock");
        assertEq(tokenB.balanceOf(receiver), amountOut, "Receiver should have output");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (tokenOut == base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_tokenOutIsBase() public {
        // base != 0, tokenOut == base => single-hop with fee
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(baseToken), FEE_OUT);

        uint256 amountIn = 500e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);
        router.setOutputToken(address(baseToken));

        uint256 amountOut = s.swap(address(tokenA), address(baseToken), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "tokenOut==base: single-hop 1:1");
        assertEq(baseToken.balanceOf(receiver), amountOut);
        // Verify fee used is `fee` (not feeOut) — captured in mock
        assertEq(router.lastFee(), FEE, "Should use fee when tokenOut==base");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (tokenIn == base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_tokenInIsBase() public {
        // base != 0, tokenIn == base => single-hop with feeOut
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(baseToken), FEE_OUT);

        uint256 amountIn = 500e18;
        baseToken.mint(address(this), amountIn);
        baseToken.approve(address(s), amountIn);
        router.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(baseToken), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "tokenIn==base: single-hop 1:1");
        assertEq(tokenB.balanceOf(receiver), amountOut);
        // Verify fee used is `feeOut` (not fee) — captured in mock
        assertEq(router.lastFee(), FEE_OUT, "Should use feeOut when tokenIn==base");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — MULTI-HOP
    // ═══════════════════════════════════════════════════════════

    function test_swap_multiHop() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(baseToken), FEE_OUT);

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);
        router.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Multi-hop should return 1:1 from mock");
        assertEq(tokenB.balanceOf(receiver), amountOut);
        assertTrue(router.lastWasMultiHop(), "Should have used multi-hop path");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — PARTIAL FILL RESIDUE (bailsec #73, #74)
    // ═══════════════════════════════════════════════════════════

    /// @notice A partial fill (router pulls less than amountIn) must leave the
    ///         adapter with zero balance, zero router allowance, and the unused
    ///         tokenIn returned to the caller. Regression test for bailsec
    ///         #73 (sweepable residue) and #74 (hanging approval).
    function test_swap_partialFill_returnsLeftoverAndZerosApproval() public {
        UniswapV3SwapperAdapter s = new UniswapV3SwapperAdapter(address(router), FEE, address(0), 0);

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);

        // Simulate shallow pool: router consumes 70% of amountIn and leaves
        // the rest approved-but-not-pulled (equivalent to hitting MIN/MAX tick).
        router.setConsumedBps(7000);
        router.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        uint256 consumed = (amountIn * 7000) / 10_000;
        uint256 leftover = amountIn - consumed;

        assertEq(amountOut, consumed, "amountOut should reflect consumed input");
        assertEq(tokenB.balanceOf(receiver), amountOut, "Receiver should get output");
        assertEq(tokenA.balanceOf(address(s)), 0, "Adapter must hold zero tokenIn after swap");
        assertEq(
            IERC20(address(tokenA)).allowance(address(s), address(router)),
            0,
            "Adapter must have zero router allowance after swap"
        );
        assertEq(tokenA.balanceOf(address(this)), leftover, "Caller must receive unused tokenIn");
    }
}

// ═══════════════════════════════════════════════════════════
// MOCK UNISWAP V3 ROUTER
// ═══════════════════════════════════════════════════════════

contract MockUniRouter {
    address public outputToken;
    uint24 public lastFee;
    bool public lastWasMultiHop;
    uint256 public consumedBps = 10_000; // default: 100% consumption (full fill)

    uint256 internal constant BPS = 10_000;

    function setOutputToken(address _token) external {
        outputToken = _token;
    }

    /// @notice Control how much of amountIn the mock "consumes" from the caller.
    ///         10_000 = full fill (default). Values below simulate a shallow
    ///         pool reaching MIN/MAX tick where the real router pulls only
    ///         the consumed amount via its pay callback.
    function setConsumedBps(uint256 _bps) external {
        consumedBps = _bps;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        lastFee = params.fee;
        lastWasMultiHop = false;
        uint256 consumed = (params.amountIn * consumedBps) / BPS;
        // Simulate real router pulling only the consumed input from the caller.
        ERC20Mock(params.tokenIn).transferFrom(msg.sender, address(this), consumed);
        amountOut = consumed;
        ERC20Mock(outputToken).mint(params.recipient, amountOut);
    }

    function exactInput(ISwapRouter.ExactInputParams calldata params) external returns (uint256 amountOut) {
        lastWasMultiHop = true;
        // First token in the path is tokenIn
        address tokenIn;
        bytes calldata path = params.path;
        assembly {
            tokenIn := shr(96, calldataload(path.offset))
        }
        uint256 consumed = (params.amountIn * consumedBps) / BPS;
        ERC20Mock(tokenIn).transferFrom(msg.sender, address(this), consumed);
        amountOut = consumed;
        ERC20Mock(outputToken).mint(params.recipient, amountOut);
    }
}
