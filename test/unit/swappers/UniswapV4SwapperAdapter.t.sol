// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { UniswapV4SwapperAdapter, IV4PoolManager } from "src/swappers/UniswapV4SwapperAdapter.sol";

contract UniswapV4SwapperAdapterTest is Test {
    ERC20Mock public tokenA;
    ERC20Mock public tokenB;
    ERC20Mock public baseToken;
    MockV4PoolManager public pm;

    address public receiver = address(0xBEEF);

    uint24 internal constant FEE = 3000;
    uint24 internal constant FEE_OUT = 500;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_SPACING_OUT = 10;

    function setUp() public {
        tokenA = new ERC20Mock();
        tokenB = new ERC20Mock();
        baseToken = new ERC20Mock();
        pm = new MockV4PoolManager();

        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(baseToken), "BaseToken");
        vm.label(address(pm), "PoolManager");
        vm.label(receiver, "Receiver");
    }

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(baseToken),
            FEE_OUT,
            TICK_SPACING_OUT,
            address(0)
        );
        assertEq(s.poolManager(), address(pm));
        assertEq(s.fee(), FEE);
        assertEq(s.tickSpacing(), TICK_SPACING);
        assertEq(s.hooks(), address(0));
        assertEq(s.base(), address(baseToken));
        assertEq(s.feeOut(), FEE_OUT);
        assertEq(s.tickSpacingOut(), TICK_SPACING_OUT);
        assertEq(s.hooksOut(), address(0));
    }

    function test_constructor_revertsOnZeroPoolManager() public {
        vm.expectRevert(UniswapV4SwapperAdapter.InvalidPoolManager.selector);
        new UniswapV4SwapperAdapter(address(0), FEE, TICK_SPACING, address(0), address(0), 0, 0, address(0));
    }

    function test_constructor_revertsOnZeroTickSpacing() public {
        vm.expectRevert(UniswapV4SwapperAdapter.InvalidTickSpacing.selector);
        new UniswapV4SwapperAdapter(address(pm), FEE, 0, address(0), address(0), 0, 0, address(0));
    }

    function test_constructor_revertsOnZeroTickSpacingOutWithBase() public {
        vm.expectRevert(UniswapV4SwapperAdapter.InvalidTickSpacing.selector);
        new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(baseToken),
            FEE_OUT,
            0,
            address(0)
        );
    }

    function test_constructor_allowsZeroBase() public {
        // base == address(0) is valid — means direct swap
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );
        assertEq(s.base(), address(0));
    }

    function test_constructor_allowsZeroTickSpacingOutWhenNoBase() public {
        // tickSpacingOut == 0 is fine when base == address(0) (second hop not used)
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );
        assertEq(s.tickSpacingOut(), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — TOKEN VALIDATION
    // ═══════════════════════════════════════════════════════════

    function test_swap_revertsOnZeroTokenIn() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );
        vm.expectRevert(UniswapV4SwapperAdapter.InvalidToken.selector);
        s.swap(address(0), address(tokenB), 100, 0, receiver);
    }

    function test_swap_revertsOnZeroTokenOut() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );
        vm.expectRevert(UniswapV4SwapperAdapter.InvalidToken.selector);
        s.swap(address(tokenA), address(0), 100, 0, receiver);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — UNAUTHORIZED CALLBACK
    // ═══════════════════════════════════════════════════════════

    function test_unlockCallback_revertsUnauthorized() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        // Call unlockCallback directly (not from poolManager)
        vm.expectRevert(UniswapV4SwapperAdapter.UnauthorizedCallback.selector);
        s.unlockCallback(abi.encode(address(tokenA), address(tokenB), uint256(100), uint256(0), receiver));
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (no base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_noBase() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);

        pm.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Single-hop should return 1:1 from mock");
        assertEq(tokenB.balanceOf(receiver), amountOut, "Receiver should have output");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (tokenOut == base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_tokenOutIsBase() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(baseToken),
            FEE_OUT,
            TICK_SPACING_OUT,
            address(0)
        );

        uint256 amountIn = 500e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);
        pm.setOutputToken(address(baseToken));

        uint256 amountOut = s.swap(address(tokenA), address(baseToken), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "tokenOut==base: single-hop 1:1");
        assertEq(baseToken.balanceOf(receiver), amountOut);
        // Verify pool config used is first-hop (fee, tickSpacing, hooks)
        assertEq(pm.lastPoolFee(), FEE, "Should use fee when tokenOut==base");
        assertEq(pm.lastPoolTickSpacing(), TICK_SPACING, "Should use tickSpacing when tokenOut==base");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — SINGLE-HOP (tokenIn == base)
    // ═══════════════════════════════════════════════════════════

    function test_swap_singleHop_tokenInIsBase() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(baseToken),
            FEE_OUT,
            TICK_SPACING_OUT,
            address(0)
        );

        uint256 amountIn = 500e18;
        baseToken.mint(address(this), amountIn);
        baseToken.approve(address(s), amountIn);
        pm.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(baseToken), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "tokenIn==base: single-hop 1:1");
        assertEq(tokenB.balanceOf(receiver), amountOut);
        // Verify pool config used is second-hop (feeOut, tickSpacingOut, hooksOut)
        assertEq(pm.lastPoolFee(), FEE_OUT, "Should use feeOut when tokenIn==base");
        assertEq(pm.lastPoolTickSpacing(), TICK_SPACING_OUT, "Should use tickSpacingOut when tokenIn==base");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — MULTI-HOP
    // ═══════════════════════════════════════════════════════════

    function test_swap_multiHop() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(baseToken),
            FEE_OUT,
            TICK_SPACING_OUT,
            address(0)
        );

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);
        pm.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        assertEq(amountOut, amountIn, "Multi-hop should return 1:1 from mock");
        assertEq(tokenB.balanceOf(receiver), amountOut);
        assertEq(pm.swapCallCount(), 2, "Should have called swap twice for multi-hop");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — INSUFFICIENT OUTPUT
    // ═══════════════════════════════════════════════════════════

    function test_swap_revertsOnInsufficientOutput() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);
        pm.setOutputToken(address(tokenB));
        pm.setOutputRate(5e17); // 50% output rate

        vm.expectRevert(abi.encodeWithSelector(UniswapV4SwapperAdapter.InsufficientOutput.selector, amountIn, 500e18));
        s.swap(address(tokenA), address(tokenB), amountIn, amountIn, receiver);
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — DIRECTION CORRECTNESS (zeroForOne)
    // ═══════════════════════════════════════════════════════════

    function test_swap_correctZeroForOne() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        uint256 amountIn = 100e18;

        // Ensure tokenA < tokenB for deterministic zeroForOne
        address low = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address high = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        ERC20Mock(low).mint(address(this), amountIn);
        ERC20Mock(low).approve(address(s), amountIn);
        pm.setOutputToken(high);

        s.swap(low, high, amountIn, 0, receiver);

        assertTrue(pm.lastZeroForOne(), "tokenIn < tokenOut should be zeroForOne=true");
    }

    function test_swap_correctNotZeroForOne() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        uint256 amountIn = 100e18;

        address low = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address high = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        ERC20Mock(high).mint(address(this), amountIn);
        ERC20Mock(high).approve(address(s), amountIn);
        pm.setOutputToken(low);

        s.swap(high, low, amountIn, 0, receiver);

        assertFalse(pm.lastZeroForOne(), "tokenIn > tokenOut should be zeroForOne=false");
    }

    // ═══════════════════════════════════════════════════════════
    // SWAP — PARTIAL FILL RESIDUE (bailsec #76)
    // ═══════════════════════════════════════════════════════════

    /// @notice When the pool consumes less than amountIn (liquidity exhausted
    ///         at the tick limit), the adapter must take the surplus tokenIn
    ///         delta back to the original caller. Without the fix,
    ///         unlock reverts with CurrencyNotSettled and the surplus is
    ///         stranded in the PoolManager singleton. Regression for bailsec #76.
    function test_swap_partialFill_takesUnusedTokenInBack() public {
        UniswapV4SwapperAdapter s = new UniswapV4SwapperAdapter(
            address(pm),
            FEE,
            TICK_SPACING,
            address(0),
            address(0),
            0,
            0,
            address(0)
        );

        uint256 amountIn = 1000e18;
        tokenA.mint(address(this), amountIn);
        tokenA.approve(address(s), amountIn);

        // Simulate partial fill at 70% and 1:1 rate
        pm.setConsumedBps(7000);
        pm.setOutputToken(address(tokenB));

        uint256 amountOut = s.swap(address(tokenA), address(tokenB), amountIn, 0, receiver);

        uint256 consumed = (amountIn * 7000) / 10_000;
        uint256 unused = amountIn - consumed;

        assertEq(amountOut, consumed, "amountOut should equal consumed at 1:1 rate");
        assertEq(tokenB.balanceOf(receiver), amountOut, "Receiver should get output");
        assertEq(tokenA.balanceOf(address(s)), 0, "Adapter must hold zero tokenIn after swap");
        assertEq(tokenA.balanceOf(address(this)), unused, "Caller must receive unused tokenIn");
        // PoolManager ends up with exactly `consumed` (its share of the swap settlement)
        assertEq(tokenA.balanceOf(address(pm)), consumed, "PoolManager keeps only the consumed amount");
    }
}

// ═══════════════════════════════════════════════════════════
// MOCK UNISWAP V4 POOL MANAGER
// ═══════════════════════════════════════════════════════════

/// @dev Mock PoolManager that simulates the V4 unlock/callback/swap/settle/take flow.
///      Uses a configurable output rate (default 1:1) and mints output tokens via take().
contract MockV4PoolManager {
    address public outputToken;
    uint256 public outputRate = 1e18; // 1:1 by default (1e18 = 100%)
    uint256 public consumedBps = 10_000; // default: full fill (100% of amountIn consumed)

    uint256 internal constant BPS = 10_000;

    // Tracked for assertions
    uint24 public lastPoolFee;
    int24 public lastPoolTickSpacing;
    bool public lastZeroForOne;
    uint256 public swapCallCount;

    function setOutputToken(address _token) external {
        outputToken = _token;
    }

    function setOutputRate(uint256 _rate) external {
        outputRate = _rate;
    }

    /// @notice Control how much of amountSpecified the mock swap consumes.
    ///         10_000 = full fill; below that simulates a shallow pool that
    ///         reaches MIN/MAX tick with unconsumed input remaining.
    function setConsumedBps(uint256 _bps) external {
        consumedBps = _bps;
    }

    function resetSwapCallCount() external {
        swapCallCount = 0;
    }

    /// @dev Calls back the sender's unlockCallback, simulating the PM unlock pattern
    function unlock(bytes calldata data) external returns (bytes memory) {
        swapCallCount = 0; // reset per unlock
        return IUnlockCallbackMock(msg.sender).unlockCallback(data);
    }

    /// @dev Returns a packed BalanceDelta simulating an exact-input swap.
    ///      For zeroForOne=true:  amount0 (negative, input) | amount1 (positive, output)
    ///      For zeroForOne=false: amount0 (positive, output) | amount1 (negative, input)
    function swap(
        IV4PoolManager.PoolKey memory key,
        IV4PoolManager.SwapParams memory params,
        bytes calldata /* hookData */
    ) external returns (int256) {
        lastPoolFee = key.fee;
        lastPoolTickSpacing = key.tickSpacing;
        lastZeroForOne = params.zeroForOne;
        swapCallCount++;

        uint256 absAmountIn = uint256(-params.amountSpecified); // amountSpecified is negative for exactInput
        uint256 consumed = (absAmountIn * consumedBps) / BPS;
        uint256 amountOut = (consumed * outputRate) / 1e18;

        int128 inputDelta = -int128(int256(consumed)); // negative: caller pays consumed
        int128 outputDelta = int128(int256(amountOut)); // positive: caller receives

        int128 d0;
        int128 d1;
        if (params.zeroForOne) {
            d0 = inputDelta; // currency0 = input (negative)
            d1 = outputDelta; // currency1 = output (positive)
        } else {
            d0 = outputDelta; // currency0 = output (positive)
            d1 = inputDelta; // currency1 = input (negative)
        }

        // Pack as BalanceDelta: upper 128 bits = amount0, lower 128 bits = amount1
        return (int256(d0) << 128) | int256(uint256(uint128(d1)));
    }

    /// @dev No-op for mock — balance snapshot
    function sync(address /* currency */) external {}

    /// @dev No-op for mock — settlement accounting
    function settle() external payable returns (uint256) {
        return 0;
    }

    /// @dev Pays `amount` of `currency` to `to`. For the configured outputToken
    ///      we mint (simulating release from the pool's reserves); for any
    ///      other currency (e.g. tokenIn surplus on a partial fill) we
    ///      transfer from this contract's balance, modelling the real PM
    ///      releasing a positive delta from its reserves.
    function take(address currency, address to, uint256 amount) external {
        if (currency == outputToken) {
            ERC20Mock(outputToken).mint(to, amount);
        } else {
            ERC20Mock(currency).transfer(to, amount);
        }
    }
}

interface IUnlockCallbackMock {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
