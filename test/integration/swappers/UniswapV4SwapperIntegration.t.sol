// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { UniswapV4SwapperAdapter, IV4PoolManager } from "src/swappers/UniswapV4SwapperAdapter.sol";
import { ISwapper } from "src/core/interfaces/ISwapper.sol";
import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MorphoTestConfig } from "test/integration/strategies/config/MorphoTestConfig.sol";
import { BaseSwapperIntegrationTest } from "./base/BaseSwapperIntegrationTest.sol";

/// @title UniswapV4SwapperIntegrationTest
/// @notice Integration test: MorphoCompounder USDC profit → Uniswap V4 → WETH → receiver
/// @dev Uses Uniswap V4 single-hop swap (USDC/WETH pool) on mainnet fork.
///      Pool parameters (fee/tickSpacing) must match an existing V4 pool at the fork block.
contract UniswapV4SwapperIntegrationTest is BaseSwapperIntegrationTest {
    // Uniswap V4 mainnet
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Pool parameters for USDC/WETH on V4
    // These must match an initialized pool on mainnet at the fork block
    uint24 internal constant FEE = 3000; // 0.3%
    int24 internal constant TICK_SPACING = 60;
    address internal constant HOOKS = address(0); // no hooks

    UniswapV4SwapperAdapter public uniswapV4Swapper;

    function _targetAsset() internal pure override returns (address) {
        return WETH;
    }

    function _deploySwapper() internal override returns (ISwapper) {
        uniswapV4Swapper = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE,
            TICK_SPACING,
            HOOKS,
            address(0), // no base token (direct swap)
            0, // feeOut unused
            0, // tickSpacingOut unused
            address(0) // hooksOut unused
        );
        return ISwapper(address(uniswapV4Swapper));
    }

    function _labelSwapperAddresses() internal override {
        vm.label(V4_POOL_MANAGER, "V4PoolManager");
        vm.label(WETH, "WETH");
    }

    function setUp() public {
        _baseSetUp();
    }

    // ========== NO-SWAP FALLBACK TESTS ==========

    function test_reportAndForward_noSwap() public {
        _test_reportAndForward_noSwap();
    }

    function test_reportAndForward_zeroProfit() public {
        _test_reportAndForward_zeroProfit();
    }

    // ========== SWAP PATH TESTS (single-hop via V4) ==========

    function test_reportSwapAndForward_fullFlow_UniswapV4() public {
        _test_reportSwapAndForward_fullFlow();
    }

    function test_reportSwapAndForward_zeroProfit_UniswapV4() public {
        _test_reportSwapAndForward_zeroProfit();
    }

    function test_reportSwapAndForward_multipleReports_UniswapV4() public {
        _test_reportSwapAndForward_multipleReports();
    }

    function test_reportSwapAndForward_emitsEvent_UniswapV4() public {
        _test_reportSwapAndForward_emitsEvent();
    }

    // ========== ACCESS CONTROL ==========

    function test_onlyKeeper_reportAndForward_UniswapV4() public {
        _test_onlyKeeper_reportAndForward();
    }

    function test_onlyKeeper_reportSwapAndForward_UniswapV4() public {
        _test_onlyKeeper_reportSwapAndForward();
    }

    // ========== V4-SPECIFIC TESTS ==========

    /// @notice V4: USDC → WETH produces a market-rate WETH output
    function test_v4Swap_producesWETH() public {
        _depositAndReport(DEPOSIT_AMOUNT);

        uint256 profit = 1_000e6;
        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);

        _clearMocks();

        assertGt(assetsOut, 0, "V4 should produce nonzero WETH output");
        assertGt(ERC20(WETH).balanceOf(receiver), 0, "Receiver should have WETH");
    }

    /// @notice Verify swapper immutables are correctly set
    function test_v4Swapper_config() public view {
        assertEq(uniswapV4Swapper.poolManager(), V4_POOL_MANAGER);
        assertEq(uniswapV4Swapper.fee(), FEE);
        assertEq(uniswapV4Swapper.tickSpacing(), TICK_SPACING);
        assertEq(uniswapV4Swapper.hooks(), HOOKS);
        assertEq(uniswapV4Swapper.base(), address(0));
    }
}

/// @title UniswapV4MultiHopTest
/// @notice Tests all three routing paths in UniswapV4SwapperAdapter on a mainnet fork
/// @dev Standalone adapter tests (no forwarder) to exercise:
///      1. Multi-hop:           WETH --(3000/60)--> USDC --(100/1)--> DAI
///      2. tokenOut == base:    WETH --(3000/60)--> USDC  (single-hop, uses fee/tickSpacing)
///      3. tokenIn == base:     USDC --(100/1)---> DAI   (single-hop, uses feeOut/tickSpacingOut)
contract UniswapV4MultiHopTest is Test {
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Pool params: WETH/USDC (first hop) and USDC/DAI (second hop)
    uint24 internal constant FEE_WETH_USDC = 3000; // 0.3%
    int24 internal constant TS_WETH_USDC = 60;
    uint24 internal constant FEE_USDC_DAI = 100; // 0.01%
    int24 internal constant TS_USDC_DAI = 1;

    uint256 internal constant SWAP_AMOUNT_USDC = 10_000e6; // 10k USDC
    uint256 internal constant SWAP_AMOUNT_WETH = 1e18; // 1 WETH

    address internal swapReceiver = address(0xBEEF);
    uint256 internal mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork("mainnet", MorphoTestConfig.FORK_BLOCK);
        vm.selectFork(mainnetFork);

        vm.label(V4_POOL_MANAGER, "V4PoolManager");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(DAI, "DAI");
        vm.label(swapReceiver, "SwapReceiver");
    }

    // ═══════════════════════════════════════════════════════════
    // MULTI-HOP: WETH → USDC → DAI (neither token is base)
    // ═══════════════════════════════════════════════════════════

    /// @notice Multi-hop swap: WETH → USDC → DAI via two V4 pools
    function test_multiHop_WETH_USDC_DAI() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0), // hooks
            USDC, // base
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0) // hooksOut
        );

        deal(WETH, address(this), SWAP_AMOUNT_WETH);
        IERC20(WETH).approve(address(adapter), SWAP_AMOUNT_WETH);

        uint256 amountOut = adapter.swap(WETH, DAI, SWAP_AMOUNT_WETH, 0, swapReceiver);

        assertGt(amountOut, 0, "Multi-hop should produce nonzero DAI");
        assertEq(ERC20(DAI).balanceOf(swapReceiver), amountOut, "Receiver should get exact DAI output");
        assertEq(ERC20(WETH).balanceOf(address(adapter)), 0, "Adapter should hold no WETH");
    }

    /// @notice Multi-hop with minAmountOut slippage protection
    function test_multiHop_respectsMinAmountOut() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0),
            USDC,
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0)
        );

        deal(WETH, address(this), SWAP_AMOUNT_WETH);
        IERC20(WETH).approve(address(adapter), SWAP_AMOUNT_WETH);

        // Unreasonably high minAmountOut should revert
        vm.expectRevert();
        adapter.swap(WETH, DAI, SWAP_AMOUNT_WETH, type(uint256).max, swapReceiver);
    }

    /// @notice Multi-hop config is correctly set
    function test_multiHop_config() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0),
            USDC,
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0)
        );

        assertEq(adapter.poolManager(), V4_POOL_MANAGER);
        assertEq(adapter.fee(), FEE_WETH_USDC);
        assertEq(adapter.tickSpacing(), TS_WETH_USDC);
        assertEq(adapter.base(), USDC);
        assertEq(adapter.feeOut(), FEE_USDC_DAI);
        assertEq(adapter.tickSpacingOut(), TS_USDC_DAI);
    }

    // ═══════════════════════════════════════════════════════════
    // SINGLE-HOP FALLBACK: tokenOut == base (WETH → USDC)
    // Uses `fee`/`tickSpacing` for the pool
    // ═══════════════════════════════════════════════════════════

    /// @notice When tokenOut == base, falls back to single-hop using fee/tickSpacing
    function test_singleHop_tokenOutIsBase_WETH_USDC() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0), // hooks
            USDC, // base
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0) // hooksOut
        );

        deal(WETH, address(this), SWAP_AMOUNT_WETH);
        IERC20(WETH).approve(address(adapter), SWAP_AMOUNT_WETH);

        uint256 amountOut = adapter.swap(WETH, USDC, SWAP_AMOUNT_WETH, 0, swapReceiver);

        assertGt(amountOut, 0, "Single-hop (tokenOut==base) should produce nonzero USDC");
        assertEq(ERC20(USDC).balanceOf(swapReceiver), amountOut, "Receiver should get exact USDC output");
    }

    // ═══════════════════════════════════════════════════════════
    // SINGLE-HOP FALLBACK: tokenIn == base (USDC → DAI)
    // Uses `feeOut`/`tickSpacingOut` for the pool
    // ═══════════════════════════════════════════════════════════

    /// @notice When tokenIn == base, falls back to single-hop using feeOut/tickSpacingOut
    function test_singleHop_tokenInIsBase_USDC_DAI() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0),
            USDC,
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0)
        );

        deal(USDC, address(this), SWAP_AMOUNT_USDC);
        IERC20(USDC).approve(address(adapter), SWAP_AMOUNT_USDC);

        uint256 amountOut = adapter.swap(USDC, DAI, SWAP_AMOUNT_USDC, 0, swapReceiver);

        assertGt(amountOut, 0, "Single-hop (tokenIn==base) should produce nonzero DAI");
        assertEq(ERC20(DAI).balanceOf(swapReceiver), amountOut, "Receiver should get exact DAI output");
    }

    /// @notice Verify fee selection: tokenIn==base uses feeOut/tickSpacingOut, not fee/tickSpacing
    /// @dev Deploy with invalid first-hop params. If the adapter incorrectly uses fee/tickSpacing
    ///      instead of feeOut/tickSpacingOut, the swap will revert because no pool exists.
    function test_singleHop_tokenInIsBase_usesFeeOut_notFee() public {
        UniswapV4SwapperAdapter adapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            10_000, // fee: intentionally wrong — should NOT be used
            200, // tickSpacing: intentionally wrong — should NOT be used
            address(0),
            USDC,
            FEE_USDC_DAI, // feeOut: correct — should be used
            TS_USDC_DAI, // tickSpacingOut: correct — should be used
            address(0)
        );

        deal(USDC, address(this), SWAP_AMOUNT_USDC);
        IERC20(USDC).approve(address(adapter), SWAP_AMOUNT_USDC);

        // Should succeed because it uses feeOut/tickSpacingOut, not fee/tickSpacing
        uint256 amountOut = adapter.swap(USDC, DAI, SWAP_AMOUNT_USDC, 0, swapReceiver);
        assertGt(amountOut, 0, "Should use feeOut for tokenIn==base path");
    }

    // ═══════════════════════════════════════════════════════════
    // FORWARDER END-TO-END WITH SWAP
    // ═══════════════════════════════════════════════════════════

    /// @notice Full forwarder flow: strategy USDC profit → swap to DAI → receiver
    function test_forwarder_swapAndForward_USDC_DAI() public {
        // Deploy swapper with base=USDC (strategy profit is USDC, so tokenIn==base → single-hop to DAI)
        UniswapV4SwapperAdapter swapAdapter = new UniswapV4SwapperAdapter(
            V4_POOL_MANAGER,
            FEE_WETH_USDC,
            TS_WETH_USDC,
            address(0),
            USDC,
            FEE_USDC_DAI,
            TS_USDC_DAI,
            address(0)
        );

        // Deploy implementation + factory + strategy + forwarder
        YieldDonatingTokenizedStrategy impl = new YieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1")
        }();
        vm.etch(MorphoTestConfig.TOKENIZED_STRATEGY_ADDRESS, address(impl).code);

        address mgmt = address(0xA1);
        address keeper = address(0xCAFE);
        address recv = address(0xBEEF);

        MorphoCompounderStrategyFactory fac = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

        // Predict addresses to resolve the forwarder <-> strategy cycle.
        address predictedFwd = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedStrat = fac.computeStrategyAddress(
            fac.YS_USDC(),
            fac.USDC(),
            "MorphoCompounder Donating Strategy",
            "osMORPHO",
            mgmt,
            predictedFwd,
            address(0xA3),
            predictedFwd,
            false,
            address(impl),
            mgmt
        );

        SwappingYieldForwarder fwd = new SwappingYieldForwarder(recv, keeper, DAI, address(swapAdapter), predictedStrat);
        require(address(fwd) == predictedFwd, "Forwarder address mismatch");

        vm.startPrank(mgmt);
        address stratAddr = fac.createStrategy(
            "MorphoCompounder Donating Strategy",
            "osMORPHO",
            mgmt,
            address(fwd),
            address(0xA3),
            address(fwd),
            false,
            address(impl)
        );
        vm.stopPrank();
        require(stratAddr == predictedStrat, "Strategy address mismatch");

        // Deposit
        address usr = address(0x1234);
        deal(USDC, usr, 100_000e6);
        vm.startPrank(usr);
        ERC20(USDC).approve(stratAddr, type(uint256).max);
        IERC4626(stratAddr).deposit(100_000e6, usr);
        vm.stopPrank();

        // Initial report
        vm.prank(mgmt);
        IBaseHealthCheck(stratAddr).setDoHealthCheck(false);
        vm.prank(address(fwd));
        IMockStrategy(stratAddr).report();

        // Simulate profit
        uint256 morphoShares = IERC4626(MorphoTestConfig.MORPHO_VAULT).balanceOf(stratAddr);
        uint256 currentAssets = IERC4626(MorphoTestConfig.MORPHO_VAULT).convertToAssets(morphoShares);
        vm.mockCall(
            MorphoTestConfig.MORPHO_VAULT,
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, morphoShares),
            abi.encode(currentAssets + 1_000e6)
        );
        deal(USDC, stratAddr, 1_000e6);

        // Report, swap (USDC→DAI via V4), forward
        vm.prank(keeper);
        uint256 daiOut = fwd.reportSwapAndForward(stratAddr, 10_000, 0);
        vm.clearMockedCalls();

        assertGt(daiOut, 0, "Forwarder should produce DAI via swap");
        assertEq(ERC20(DAI).balanceOf(recv), daiOut, "Receiver should get DAI");
    }
}
