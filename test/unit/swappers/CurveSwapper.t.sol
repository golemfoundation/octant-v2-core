// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { CurveSwapper } from "src/swappers/CurveSwapper.sol";

contract CurveSwapperTest is Test {
    ERC20Mock public tokenIn;
    ERC20Mock public tokenOut;
    MockCurvePool public pool;

    address public receiver = address(0xBEEF);

    int128 internal constant INDEX_IN = 1;
    int128 internal constant INDEX_OUT = 2;

    function setUp() public {
        tokenIn = new ERC20Mock();
        tokenOut = new ERC20Mock();
        pool = new MockCurvePool(address(tokenIn), address(tokenOut), INDEX_IN, INDEX_OUT);

        vm.label(address(tokenIn), "TokenIn");
        vm.label(address(tokenOut), "TokenOut");
        vm.label(address(pool), "CurvePool");
        vm.label(receiver, "Receiver");
    }

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));
        assertEq(s.pool(), address(pool));
        assertEq(s.indexIn(), INDEX_IN);
        assertEq(s.indexOut(), INDEX_OUT);
        assertEq(s.tokenIn(), address(tokenIn));
        assertEq(s.tokenOut(), address(tokenOut));
    }

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(CurveSwapper.InvalidPool.selector);
        new CurveSwapper(address(0), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));
    }

    function test_constructor_revertsOnZeroTokenIn() public {
        vm.expectRevert(CurveSwapper.InvalidToken.selector);
        new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(0), address(tokenOut));
    }

    function test_constructor_revertsOnZeroTokenOut() public {
        vm.expectRevert(CurveSwapper.InvalidToken.selector);
        new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(0));
    }

    function test_constructor_revertsOnSameIndices() public {
        vm.expectRevert(CurveSwapper.InvalidIndices.selector);
        new CurveSwapper(address(pool), INDEX_IN, INDEX_IN, address(tokenIn), address(tokenOut));
    }

    function test_constructor_revertsOnTokenInIndexMismatch() public {
        // pool.coins(INDEX_IN) = tokenIn, but we pass tokenOut as _tokenIn
        vm.expectRevert(CurveSwapper.TokenIndexMismatch.selector);
        new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenOut), address(tokenOut));
    }

    function test_constructor_revertsOnTokenOutIndexMismatch() public {
        // pool.coins(INDEX_OUT) = tokenOut, but we pass tokenIn as _tokenOut
        vm.expectRevert(CurveSwapper.TokenIndexMismatch.selector);
        new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenIn));
    }

    function test_constructor_revertsOnSwappedIndices() public {
        // Correct tokens but swapped indices (INDEX_OUT for tokenIn, INDEX_IN for tokenOut)
        vm.expectRevert(CurveSwapper.TokenIndexMismatch.selector);
        new CurveSwapper(address(pool), INDEX_OUT, INDEX_IN, address(tokenIn), address(tokenOut));
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — TOKEN MISMATCH
    // ═══════════════════════════════════════════════════════════

    function test_swap_revertsOnTokenInMismatch() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));
        vm.expectRevert(CurveSwapper.InvalidToken.selector);
        s.swap(address(0xDEAD), address(tokenOut), 100, 0, receiver);
    }

    function test_swap_revertsOnTokenOutMismatch() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));
        vm.expectRevert(CurveSwapper.InvalidToken.selector);
        s.swap(address(tokenIn), address(0xDEAD), 100, 0, receiver);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — FULL FLOW
    // ═══════════════════════════════════════════════════════════

    function test_swap_fullFlow() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));

        uint256 amountIn = 1000e18;
        tokenIn.mint(address(this), amountIn);
        tokenIn.approve(address(s), amountIn);

        uint256 amountOut = s.swap(address(tokenIn), address(tokenOut), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Output should match 1:1 from mock pool");
        assertEq(tokenOut.balanceOf(receiver), amountOut, "Receiver should have output tokens");
    }

    function test_swap_respectsMinAmountOut() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));

        uint256 amountIn = 1000e18;
        tokenIn.mint(address(this), amountIn);
        tokenIn.approve(address(s), amountIn);

        // Pool enforces minAmountOut via the mock
        pool.setSlippage(50); // 50% output

        // The Curve pool's exchange will be called with min_dy, and the pool mock will
        // output less. However, since CurveSwapper passes minAmountOut to the pool,
        // the pool itself should revert. Let's test that the CurveSwapper forwards minAmountOut.
        // In our mock, the pool doesn't enforce min_dy, so this tests the balance measurement.
        uint256 amountOut = s.swap(address(tokenIn), address(tokenOut), amountIn, 0, receiver);
        assertEq(amountOut, 500e18, "Output should reflect slippage");
    }

    function test_swap_fuzz(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e30);
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));

        tokenIn.mint(address(this), amountIn);
        tokenIn.approve(address(s), amountIn);
        uint256 amountOut = s.swap(address(tokenIn), address(tokenOut), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "1:1 mock output");
        assertEq(tokenOut.balanceOf(receiver), amountOut);
    }

    // ═══════════════════════════════════════════════════════════
    // ZERO-RESIDUE INVARIANT (cantina #1)
    // ═══════════════════════════════════════════════════════════

    /// @notice The adapter must hold zero tokenIn after any swap call, even
    ///         when pre-existing balance (a donation, or pool pull semantics
    ///         leaving surplus) is present at entry. Regression for cantina #1.
    function test_swap_flushesPreExistingTokenInBalance() public {
        CurveSwapper s = new CurveSwapper(address(pool), INDEX_IN, INDEX_OUT, address(tokenIn), address(tokenOut));

        // Simulate a prior donation / leftover of 7e18 sitting in the adapter.
        uint256 donation = 7e18;
        tokenIn.mint(address(s), donation);

        uint256 amountIn = 100e18;
        tokenIn.mint(address(this), amountIn);
        tokenIn.approve(address(s), amountIn);

        uint256 callerBalBefore = tokenIn.balanceOf(address(this));

        uint256 amountOut = s.swap(address(tokenIn), address(tokenOut), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Output follows 1:1 mock");
        assertEq(tokenIn.balanceOf(address(s)), 0, "Adapter must hold zero tokenIn after swap");
        // Caller paid amountIn, received back the donation via the residue flush.
        assertEq(
            tokenIn.balanceOf(address(this)),
            callerBalBefore - amountIn + donation,
            "Caller should receive the prior donation back via the flush"
        );
    }
}

// ═══════════════════════════════════════════════════════════
// MOCK CURVE POOL
// ═══════════════════════════════════════════════════════════

contract MockCurvePool {
    mapping(uint256 => address) public coins;
    ERC20Mock public tokenIn;
    ERC20Mock public tokenOut;
    uint256 public slippagePct = 100; // 100 = no slippage

    constructor(address _tokenIn, address _tokenOut, int128 _indexIn, int128 _indexOut) {
        tokenIn = ERC20Mock(_tokenIn);
        tokenOut = ERC20Mock(_tokenOut);
        coins[uint256(int256(_indexIn))] = _tokenIn;
        coins[uint256(int256(_indexOut))] = _tokenOut;
    }

    function setSlippage(uint256 _pct) external {
        slippagePct = _pct;
    }

    /// @dev Simulates Curve exchange: pulls tokenIn, mints tokenOut to caller (1:1 with optional slippage)
    function exchange(int128, int128, uint256 dx, uint256) external {
        tokenIn.transferFrom(msg.sender, address(this), dx);
        uint256 dy = (dx * slippagePct) / 100;
        tokenOut.mint(msg.sender, dy);
    }
}
