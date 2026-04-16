// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { YieldForwarder } from "src/core/YieldForwarder.sol";
import { ISwapper } from "src/core/interfaces/ISwapper.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";

import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MorphoTestConfig } from "test/integration/strategies/config/MorphoTestConfig.sol";

/// @title BaseSwapperIntegrationTest
/// @notice Abstract base for swapper integration tests using MorphoCompounder strategy on mainnet fork
/// @dev Concrete tests only need to implement _deploySwapper() and _targetAsset().
///      This base class handles: strategy deployment, forwarder wiring, deposit + profit simulation,
///      and shared test flows for both swap and no-swap paths.
abstract contract BaseSwapperIntegrationTest is Test {
    using SafeERC20 for ERC20;

    // ========== STATE ==========

    MorphoCompounderStrategy public strategy;
    MorphoCompounderStrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;
    SwappingYieldForwarder public forwarder;

    address public management = address(0xA1);
    address public keeperEOA = address(0xCAFE);
    address public emergencyAdmin = address(0xA3);
    address public receiver = address(0xBEEF);
    address public user = address(0x1234);

    uint256 public mainnetFork;
    uint256 public constant DEPOSIT_AMOUNT = 100_000e6; // 100k USDC

    // ========== ABSTRACT ==========

    /// @notice Deploy and return the concrete ISwapper implementation
    function _deploySwapper() internal virtual returns (ISwapper);

    /// @notice Return the address of the target asset after swap
    function _targetAsset() internal view virtual returns (address);

    /// @notice Label addresses specific to the concrete swapper
    function _labelSwapperAddresses() internal virtual;

    // ========== SETUP ==========

    function _baseSetUp() internal {
        mainnetFork = vm.createFork("mainnet", MorphoTestConfig.FORK_BLOCK);
        vm.selectFork(mainnetFork);

        // 1. Etch YieldDonatingTokenizedStrategy implementation
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        vm.etch(MorphoTestConfig.TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);

        // 2. Deploy swapper (concrete test provides this)
        ISwapper swapper = _deploySwapper();

        // 3. Deploy the factory
        factory = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

        // 4. Predict the forwarder's CREATE address (next contract deployed by this test),
        //    then predict the strategy's CREATE2 address using the predicted forwarder
        //    as keeper/donation (both feed into the factory's salt hash). This breaks the
        //    forwarder <-> strategy circular dependency.
        address predictedForwarder = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedStrategy = factory.computeStrategyAddress(
            factory.YS_USDC(),
            factory.USDC(),
            "MorphoCompounder Donating Strategy",
            "osMORPHO",
            management,
            predictedForwarder,
            emergencyAdmin,
            predictedForwarder,
            false,
            address(implementation),
            management
        );

        // 5. Deploy SwappingYieldForwarder with the predicted strategy as its vault
        forwarder = new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            _targetAsset(),
            address(swapper),
            predictedStrategy
        );
        require(address(forwarder) == predictedForwarder, "Forwarder address mismatch");

        // 6. Deploy the strategy with forwarder as keeper AND donation address
        vm.startPrank(management);
        address strategyAddr = factory.createStrategy(
            "MorphoCompounder Donating Strategy",
            "osMORPHO",
            management,
            address(forwarder), // keeper = forwarder (so forwarder can call report)
            emergencyAdmin,
            address(forwarder), // donationAddress = forwarder (profit shares minted here)
            false,
            address(implementation)
        );
        vm.stopPrank();
        require(strategyAddr == predictedStrategy, "Strategy address mismatch: vault wiring broken");

        strategy = MorphoCompounderStrategy(strategyAddr);

        // 5. Airdrop USDC to user and approve
        deal(MorphoTestConfig.USDC, user, DEPOSIT_AMOUNT);
        vm.prank(user);
        ERC20(MorphoTestConfig.USDC).approve(address(strategy), type(uint256).max);

        // 6. Labels
        vm.label(address(strategy), "MorphoCompounderStrategy");
        vm.label(address(forwarder), "SwappingYieldForwarder");
        vm.label(address(swapper), "Swapper");
        vm.label(receiver, "Receiver");
        vm.label(keeperEOA, "KeeperEOA");
        vm.label(management, "Management");
        vm.label(user, "User");
        vm.label(MorphoTestConfig.USDC, "USDC");
        _labelSwapperAddresses();
    }

    // ========== HELPERS ==========

    /// @notice Deposit into strategy, then run initial report so strategy deploys to Morpho
    /// @dev Disables health check for the initial report (Morpho rounding can cause 1 wei "loss")
    function _depositAndReport(uint256 amount) internal {
        vm.prank(user);
        IERC4626(address(strategy)).deposit(amount, user);

        // Disable health check for initial report (Morpho vault rounding)
        vm.prank(management);
        IBaseHealthCheck(address(strategy)).setDoHealthCheck(false);

        // Initial report deploys funds into Morpho and sets baseline
        vm.prank(address(forwarder));
        IMockStrategy(address(strategy)).report();
    }

    /// @notice Simulate profit by mocking Morpho vault convertToAssets to return inflated value
    /// @dev After calling report(), the strategy will see this as profit and mint shares to donationAddress
    function _simulateProfit(uint256 profitAmount) internal {
        uint256 morphoShares = IERC4626(MorphoTestConfig.MORPHO_VAULT).balanceOf(address(strategy));
        uint256 currentAssets = IERC4626(MorphoTestConfig.MORPHO_VAULT).convertToAssets(morphoShares);

        // Mock convertToAssets to return inflated value
        vm.mockCall(
            MorphoTestConfig.MORPHO_VAULT,
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, morphoShares),
            abi.encode(currentAssets + profitAmount)
        );

        // Airdrop actual USDC to strategy so redeem has real tokens
        deal(MorphoTestConfig.USDC, address(strategy), profitAmount);
    }

    function _clearMocks() internal {
        vm.clearMockedCalls();
    }

    // ========== SHARED TEST: NO-SWAP FALLBACK ==========

    function _test_reportAndForward_noSwap() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        uint256 profit = 1_000e6; // 1k USDC profit
        _simulateProfit(profit);

        uint256 receiverUsdcBefore = ERC20(MorphoTestConfig.USDC).balanceOf(receiver);

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        _clearMocks();

        assertGt(assets, 0, "Should forward nonzero underlying assets");
        assertEq(
            ERC20(MorphoTestConfig.USDC).balanceOf(receiver),
            receiverUsdcBefore + assets,
            "Receiver should get underlying USDC"
        );
        assertEq(IERC20(address(strategy)).balanceOf(address(forwarder)), 0, "Forwarder should have 0 shares");
    }

    function _test_reportAndForward_zeroProfit() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        // No profit simulation — just call again
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertEq(assets, 0, "Should return 0 when no profit");
    }

    // ========== SHARED TEST: SWAP PATH ==========

    function _test_reportSwapAndForward_fullFlow() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        uint256 profit = 1_000e6; // 1k USDC profit
        _simulateProfit(profit);

        uint256 receiverTargetBefore = ERC20(_targetAsset()).balanceOf(receiver);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);

        _clearMocks();

        assertGt(assetsOut, 0, "Should swap and forward nonzero target assets");
        assertEq(
            ERC20(_targetAsset()).balanceOf(receiver),
            receiverTargetBefore + assetsOut,
            "Receiver should get target asset"
        );
        assertEq(IERC20(address(strategy)).balanceOf(address(forwarder)), 0, "Forwarder should have 0 shares");
    }

    function _test_reportSwapAndForward_zeroProfit() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);

        assertEq(assetsOut, 0, "Should return 0 when no profit");
        assertEq(ERC20(_targetAsset()).balanceOf(receiver), 0, "Receiver gets nothing");
    }

    function _test_reportSwapAndForward_multipleReports() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        // First profit cycle
        _simulateProfit(500e6);
        vm.prank(keeperEOA);
        uint256 assets1 = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);
        _clearMocks();
        assertGt(assets1, 0, "First report should yield target assets");

        // Second profit cycle
        _simulateProfit(1_500e6);
        vm.prank(keeperEOA);
        uint256 assets2 = forwarder.reportSwapAndForward(address(strategy), 10_000, 0);
        _clearMocks();
        assertGt(assets2, 0, "Second report should yield target assets");

        assertEq(
            ERC20(_targetAsset()).balanceOf(receiver),
            assets1 + assets2,
            "Receiver should accumulate all payouts"
        );
    }

    function _test_reportSwapAndForward_emitsEvent() internal {
        _depositAndReport(DEPOSIT_AMOUNT);

        _simulateProfit(1_000e6);

        vm.expectEmit(true, true, false, false);
        emit SwappingYieldForwarder.YieldSwappedAndForwarded(address(strategy), receiver, 0, 0, 0);

        vm.prank(keeperEOA);
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0);

        _clearMocks();
    }

    // ========== SHARED TEST: ACCESS CONTROL ==========

    function _test_onlyKeeper_reportAndForward() internal {
        vm.prank(address(0x1111));
        vm.expectRevert(YieldForwarder.OnlyKeeper.selector);
        forwarder.reportAndForward(address(strategy), 0);
    }

    function _test_onlyKeeper_reportSwapAndForward() internal {
        vm.prank(address(0x1111));
        vm.expectRevert(YieldForwarder.OnlyKeeper.selector);
        forwarder.reportSwapAndForward(address(strategy), 0, 0);
    }
}
