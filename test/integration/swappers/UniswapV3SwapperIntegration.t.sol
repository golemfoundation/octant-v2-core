// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { UniswapV3SwapperAdapter } from "src/swappers/UniswapV3SwapperAdapter.sol";
import { ISwapper } from "src/core/interfaces/ISwapper.sol";
import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MorphoTestConfig } from "test/integration/strategies/config/MorphoTestConfig.sol";
import { BaseSwapperIntegrationTest } from "./base/BaseSwapperIntegrationTest.sol";

/// @title UniswapV3SwapperIntegration
/// @notice Integration test: MorphoCompounder USDC profit → Uniswap V3 → WETH → receiver
/// @dev Uses Uniswap V3 single-hop swap (USDC/WETH 0.05% pool) on mainnet fork
contract UniswapV3SwapperIntegrationTest is BaseSwapperIntegrationTest {
    // Uniswap V3 mainnet
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // 500 = 0.05% fee tier (USDC/WETH)
    uint24 internal constant FEE = 500;

    UniswapV3SwapperAdapter public uniswapSwapper;

    function _targetAsset() internal pure override returns (address) {
        return WETH;
    }

    function _deploySwapper() internal override returns (ISwapper) {
        uniswapSwapper = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE,
            address(0), // no base token (direct swap)
            0 // feeOut unused for direct swap
        );
        return ISwapper(address(uniswapSwapper));
    }

    function _labelSwapperAddresses() internal override {
        vm.label(UNISWAP_V3_ROUTER, "UniswapV3Router");
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

    // ========== SWAP PATH TESTS (single-hop, no base) ==========

    function test_reportSwapAndForward_fullFlow_UniswapV3() public {
        _test_reportSwapAndForward_fullFlow();
    }

    function test_reportSwapAndForward_zeroProfit_UniswapV3() public {
        _test_reportSwapAndForward_zeroProfit();
    }

    function test_reportSwapAndForward_multipleReports_UniswapV3() public {
        _test_reportSwapAndForward_multipleReports();
    }

    function test_reportSwapAndForward_emitsEvent_UniswapV3() public {
        _test_reportSwapAndForward_emitsEvent();
    }

    // ========== ACCESS CONTROL ==========

    function test_onlyKeeper_reportAndForward_UniswapV3() public {
        _test_onlyKeeper_reportAndForward();
    }

    function test_onlyKeeper_reportSwapAndForward_UniswapV3() public {
        _test_onlyKeeper_reportSwapAndForward();
    }

    // ========== UNISWAP-SPECIFIC TESTS ==========

    /// @notice Uniswap V3: USDC → WETH produces a market-rate WETH output
    function test_uniswapSwap_producesWETH() public {
        _depositAndReport(DEPOSIT_AMOUNT);

        uint256 profit = 1_000e6;
        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);

        _clearMocks();

        assertGt(assetsOut, 0, "Uniswap should produce nonzero WETH output");
        assertGt(ERC20(WETH).balanceOf(receiver), 0, "Receiver should have WETH");
    }

    /// @notice Verify swapper immutables are correctly set
    function test_uniswapSwapper_config() public view {
        assertEq(uniswapSwapper.router(), UNISWAP_V3_ROUTER);
        assertEq(uniswapSwapper.fee(), FEE);
        assertEq(uniswapSwapper.base(), address(0));
        assertEq(uniswapSwapper.feeOut(), 0);
    }
}

/// @title UniswapV3MultiHopTest
/// @notice Tests all three routing paths in UniswapV3SwapperAdapter on a mainnet fork
/// @dev Standalone adapter tests (no forwarder) to exercise:
///      1. Multi-hop:           USDC --(500)--> WETH --(3000)--> DAI
///      2. tokenOut == base:    USDC --(500)--> WETH  (single-hop, uses fee)
///      3. tokenIn == base:     WETH --(3000)--> DAI  (single-hop, uses feeOut)
contract UniswapV3MultiHopTest is Test {
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint24 internal constant FEE_USDC_WETH = 500; // 0.05%
    uint24 internal constant FEE_WETH_DAI = 3000; // 0.3%

    uint256 internal constant SWAP_AMOUNT_USDC = 10_000e6; // 10k USDC
    uint256 internal constant SWAP_AMOUNT_WETH = 1e18; // 1 WETH

    address internal swapReceiver = address(0xBEEF);
    uint256 internal mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork("mainnet", MorphoTestConfig.FORK_BLOCK);
        vm.selectFork(mainnetFork);

        vm.label(UNISWAP_V3_ROUTER, "UniswapV3Router");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(DAI, "DAI");
        vm.label(swapReceiver, "SwapReceiver");
    }

    // ═══════════════════════════════════════════════════════════
    // MULTI-HOP: USDC → WETH → DAI  (neither token is base)
    // ═══════════════════════════════════════════════════════════

    /// @notice Multi-hop swap: USDC → WETH → DAI via exactInput path encoding
    function test_multiHop_USDC_WETH_DAI() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH, // fee: USDC → WETH
            WETH, // base token
            FEE_WETH_DAI // feeOut: WETH → DAI
        );

        deal(USDC, address(this), SWAP_AMOUNT_USDC);
        IERC20(USDC).approve(address(adapter), SWAP_AMOUNT_USDC);

        uint256 amountOut = adapter.swap(USDC, DAI, SWAP_AMOUNT_USDC, 0, swapReceiver);

        assertGt(amountOut, 0, "Multi-hop should produce nonzero DAI");
        assertEq(ERC20(DAI).balanceOf(swapReceiver), amountOut, "Receiver should get exact DAI output");
        assertEq(ERC20(USDC).balanceOf(address(adapter)), 0, "Adapter should hold no USDC");
    }

    /// @notice Multi-hop with minAmountOut slippage protection
    function test_multiHop_respectsMinAmountOut() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH,
            WETH,
            FEE_WETH_DAI
        );

        deal(USDC, address(this), SWAP_AMOUNT_USDC);
        IERC20(USDC).approve(address(adapter), SWAP_AMOUNT_USDC);

        // Unreasonably high minAmountOut should revert
        vm.expectRevert();
        adapter.swap(USDC, DAI, SWAP_AMOUNT_USDC, type(uint256).max, swapReceiver);
    }

    /// @notice Multi-hop config is correctly set
    function test_multiHop_config() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH,
            WETH,
            FEE_WETH_DAI
        );

        assertEq(adapter.router(), UNISWAP_V3_ROUTER);
        assertEq(adapter.fee(), FEE_USDC_WETH);
        assertEq(adapter.base(), WETH);
        assertEq(adapter.feeOut(), FEE_WETH_DAI);
    }

    // ═══════════════════════════════════════════════════════════
    // SINGLE-HOP FALLBACK: tokenOut == base  (USDC → WETH)
    // Uses `fee` for the pool
    // ═══════════════════════════════════════════════════════════

    /// @notice When tokenOut == base, falls back to single-hop using `fee`
    function test_singleHop_tokenOutIsBase_USDC_WETH() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH, // fee: used for USDC → WETH
            WETH, // base
            FEE_WETH_DAI // feeOut: unused here
        );

        deal(USDC, address(this), SWAP_AMOUNT_USDC);
        IERC20(USDC).approve(address(adapter), SWAP_AMOUNT_USDC);

        uint256 amountOut = adapter.swap(USDC, WETH, SWAP_AMOUNT_USDC, 0, swapReceiver);

        assertGt(amountOut, 0, "Single-hop (tokenOut==base) should produce nonzero WETH");
        assertEq(ERC20(WETH).balanceOf(swapReceiver), amountOut, "Receiver should get exact WETH output");
    }

    // ═══════════════════════════════════════════════════════════
    // SINGLE-HOP FALLBACK: tokenIn == base  (WETH → DAI)
    // Uses `feeOut` for the pool
    // ═══════════════════════════════════════════════════════════

    /// @notice When tokenIn == base, falls back to single-hop using `feeOut`
    function test_singleHop_tokenInIsBase_WETH_DAI() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH, // fee: unused here
            WETH, // base
            FEE_WETH_DAI // feeOut: used for WETH → DAI
        );

        deal(WETH, address(this), SWAP_AMOUNT_WETH);
        IERC20(WETH).approve(address(adapter), SWAP_AMOUNT_WETH);

        uint256 amountOut = adapter.swap(WETH, DAI, SWAP_AMOUNT_WETH, 0, swapReceiver);

        assertGt(amountOut, 0, "Single-hop (tokenIn==base) should produce nonzero DAI");
        assertEq(ERC20(DAI).balanceOf(swapReceiver), amountOut, "Receiver should get exact DAI output");
    }

    /// @notice Verify fee selection: tokenIn==base uses feeOut, not fee
    /// @dev Deploy with an invalid fee for the first hop. If the adapter incorrectly
    ///      uses `fee` instead of `feeOut`, the swap will revert because no pool exists
    ///      at that fee tier.
    function test_singleHop_tokenInIsBase_usesFeeOut_notFee() public {
        UniswapV3SwapperAdapter adapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            10_000, // fee: intentionally wrong tier (1%) — should NOT be used
            WETH,
            FEE_WETH_DAI // feeOut: correct tier (0.3%) — should be used
        );

        deal(WETH, address(this), SWAP_AMOUNT_WETH);
        IERC20(WETH).approve(address(adapter), SWAP_AMOUNT_WETH);

        // Should succeed because it uses feeOut (3000), not fee (10000)
        uint256 amountOut = adapter.swap(WETH, DAI, SWAP_AMOUNT_WETH, 0, swapReceiver);
        assertGt(amountOut, 0, "Should use feeOut for tokenIn==base path");
    }

    // ═══════════════════════════════════════════════════════════
    // MULTI-HOP END-TO-END WITH FORWARDER
    // ═══════════════════════════════════════════════════════════

    /// @notice Full forwarder flow with multi-hop: strategy USDC profit → WETH → DAI → receiver
    function test_forwarder_multiHop_USDC_WETH_DAI() public {
        // Deploy full stack with multi-hop swapper
        UniswapV3SwapperAdapter multiHopAdapter = new UniswapV3SwapperAdapter(
            UNISWAP_V3_ROUTER,
            FEE_USDC_WETH,
            WETH,
            FEE_WETH_DAI
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

        // Predict addresses to resolve the forwarder <-> strategy cycle: forwarder needs
        // the strategy as its vault reference, strategy needs the forwarder as keeper/donation.
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

        SwappingYieldForwarder fwd = new SwappingYieldForwarder(recv, keeper, DAI, address(multiHopAdapter), predictedStrat);
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

        // Report, swap (multi-hop USDC→WETH→DAI), forward
        vm.prank(keeper);
        uint256 daiOut = fwd.reportSwapAndForward(stratAddr, 10_000, 0);
        vm.clearMockedCalls();

        assertGt(daiOut, 0, "Multi-hop through forwarder should produce DAI");
        assertEq(ERC20(DAI).balanceOf(recv), daiOut, "Receiver should get DAI via multi-hop");
    }
}
