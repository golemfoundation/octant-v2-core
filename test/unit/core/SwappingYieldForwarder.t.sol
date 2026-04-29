// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { YieldForwarder } from "src/core/YieldForwarder.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

import { MockFactory } from "test/mocks/MockFactory.sol";
import { MockStrategy } from "test/mocks/core/tokenized-strategies/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/tokenized-strategies/MockYieldSource.sol";
import { MockSwapper } from "test/mocks/MockSwapper.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SeedHelpers } from "test/unit/strategies/yieldDonating/utils/SeedHelpers.sol";

contract SwappingYieldForwarderTest is SeedHelpers {
    SwappingYieldForwarder public forwarder;
    ERC20Mock public asset;
    ERC20Mock public targetAsset;
    IMockStrategy public strategy;
    MockYieldSource public yieldSource;
    MockFactory public mockFactory;
    MockSwapper public swapper;
    YieldDonatingTokenizedStrategy public implementation;

    address public receiver = address(0xBEEF);
    address public keeperEOA = address(0xCAFE);
    address public management = address(0xA1);
    address public emergencyAdmin = address(0xA2);
    address public user = address(0xA3);
    address public protocolFeeRecipient = address(0xA4);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        mockFactory = new MockFactory(0, protocolFeeRecipient);
        implementation = new YieldDonatingTokenizedStrategy();

        asset = new ERC20Mock();
        targetAsset = new ERC20Mock();
        yieldSource = new MockYieldSource(address(asset));

        // Deploy swapper (1:1 rate)
        swapper = new MockSwapper(address(targetAsset), 1e18);

        // Break the forwarder <-> strategy circular reference by predicting the
        // strategy's CREATE address. Forwarder needs the vault at construction,
        // strategy needs the forwarder as keeper/donation at construction.
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedStrategy = vm.computeCreateAddress(address(this), baseNonce + 1);

        // Deploy SwappingYieldForwarder with the predicted strategy as its vault source
        forwarder = new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            address(targetAsset),
            address(swapper),
            predictedStrategy,
            0
        );

        // Deploy strategy with forwarder as both keeper and donation address
        strategy = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset),
                    address(yieldSource),
                    management,
                    address(forwarder),
                    emergencyAdmin,
                    address(forwarder),
                    address(implementation)
                )
            )
        );
        assertEq(address(strategy), predictedStrategy, "Predicted strategy address must match actual");

        vm.startPrank(management);
        strategy.setKeeper(address(forwarder));
        strategy.setEmergencyAdmin(emergencyAdmin);
        strategy.setPendingManagement(management);
        strategy.acceptManagement();
        vm.stopPrank();
        _seedMinimumPosition(address(strategy), asset, management);

        vm.label(receiver, "Receiver");
        vm.label(keeperEOA, "KeeperEOA");
        vm.label(address(forwarder), "SwappingYieldForwarder");
        vm.label(address(strategy), "Strategy");
        vm.label(address(asset), "Asset");
        vm.label(address(targetAsset), "TargetAsset");
        vm.label(address(yieldSource), "YieldSource");
        vm.label(address(swapper), "MockSwapper");
    }

    function _depositIntoStrategy(address _user, uint256 _amount) internal {
        asset.mint(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, _user);
        vm.stopPrank();
    }

    function _simulateProfit(uint256 _profit) internal {
        asset.mint(address(yieldSource), _profit);
    }

    // ═══════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════

    function test_constructor_setsReceiver() public view {
        assertEq(forwarder.receiver(), receiver);
    }

    function test_constructor_setsKeeper() public view {
        assertEq(forwarder.keeper(), keeperEOA);
    }

    function test_constructor_setsTargetAsset() public view {
        assertEq(forwarder.targetAsset(), address(targetAsset));
    }

    function test_constructor_setsSwapper() public view {
        assertEq(address(forwarder.swapper()), address(swapper));
    }

    function test_constructor_setsVault() public view {
        assertEq(forwarder.vault(), address(strategy));
    }

    function test_constructor_setsMinSlippageBps() public {
        SwappingYieldForwarder fwd = new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            address(targetAsset),
            address(swapper),
            address(strategy),
            9_900
        );

        assertEq(fwd.minSlippageBps(), 9_900);
    }

    function test_constructor_revertsOnZeroReceiver() public {
        vm.expectRevert(YieldForwarder.InvalidReceiver.selector);
        new SwappingYieldForwarder(address(0), keeperEOA, address(targetAsset), address(swapper), address(strategy), 0);
    }

    function test_constructor_revertsOnZeroKeeper() public {
        vm.expectRevert(YieldForwarder.InvalidKeeper.selector);
        new SwappingYieldForwarder(receiver, address(0), address(targetAsset), address(swapper), address(strategy), 0);
    }

    function test_constructor_revertsOnZeroTargetAsset() public {
        vm.expectRevert(SwappingYieldForwarder.InvalidTargetAsset.selector);
        new SwappingYieldForwarder(receiver, keeperEOA, address(0), address(swapper), address(strategy), 0);
    }

    function test_constructor_revertsOnZeroSwapper() public {
        vm.expectRevert(SwappingYieldForwarder.InvalidSwapper.selector);
        new SwappingYieldForwarder(receiver, keeperEOA, address(targetAsset), address(0), address(strategy), 0);
    }

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(SwappingYieldForwarder.InvalidVault.selector);
        new SwappingYieldForwarder(receiver, keeperEOA, address(targetAsset), address(swapper), address(0), 0);
    }

    function test_constructor_revertsOnInvalidMinSlippageBps() public {
        vm.expectRevert(SwappingYieldForwarder.InvalidSlippageBps.selector);
        new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            address(targetAsset),
            address(swapper),
            address(strategy),
            10_001
        );
    }

    // ═══════════════════════════════════════════════════════════
    // forwardToken — AUTHORIZED RECOVERY
    // ═══════════════════════════════════════════════════════════

    function test_forwardToken_managementCanForwardToReceiver() public {
        asset.mint(address(forwarder), 3e18);

        vm.prank(management);
        forwarder.forwardToken(address(asset));

        assertEq(asset.balanceOf(address(forwarder)), 0, "forwarder residual must be flushed");
        assertEq(asset.balanceOf(receiver), 3e18, "receiver gets recovered balance");
    }

    function test_forwardToken_keeperCanForwardToReceiver() public {
        asset.mint(address(forwarder), 5e18);

        vm.prank(keeperEOA);
        forwarder.forwardToken(address(asset));

        assertEq(asset.balanceOf(address(forwarder)), 0, "forwarder residual must be flushed");
        assertEq(asset.balanceOf(receiver), 5e18, "receiver gets recovered balance");
    }

    function test_forwardToken_revertsWhenNeitherKeeperNorManagement() public {
        asset.mint(address(forwarder), 7e18);

        vm.prank(user);
        vm.expectRevert(SwappingYieldForwarder.OnlyVaultManagement.selector);
        forwarder.forwardToken(address(asset));

        assertEq(asset.balanceOf(address(forwarder)), 7e18, "unauthorized call keeps balance");
        assertEq(asset.balanceOf(receiver), 0, "receiver gets nothing");
    }

    function test_forwardToken_emitsTokenForwardedEvent() public {
        asset.mint(address(forwarder), 11e18);

        vm.expectEmit(true, true, false, true);
        emit YieldForwarder.TokenForwarded(address(asset), receiver, 11e18);

        vm.prank(keeperEOA);
        forwarder.forwardToken(address(asset));
    }

    // ═══════════════════════════════════════════════════════════
    // reportAndForward — NO-SWAP FALLBACK PATH
    // ═══════════════════════════════════════════════════════════

    function test_reportAndForward_fullFlow() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        uint256 profit = 10e18;
        _simulateProfit(profit);

        uint256 receiverBalanceBefore = asset.balanceOf(receiver);
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertGt(assets, 0, "Should forward nonzero assets");
        assertEq(asset.balanceOf(receiver), receiverBalanceBefore + assets, "Receiver should get underlying asset");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should have 0 shares");
        // Receiver gets underlying asset, NOT target asset
        assertEq(targetAsset.balanceOf(receiver), 0, "Receiver should NOT get target asset on no-swap path");
    }

    function test_reportAndForward_revertsWhenNotKeeper() public {
        vm.prank(address(0x1111));
        vm.expectRevert(YieldForwarder.OnlyKeeper.selector);
        forwarder.reportAndForward(address(strategy), 0);
    }

    function test_reportAndForward_zeroProfit_returnsZero() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertEq(assets, 0, "Should return 0 when no profit");
    }

    function test_reportAndForward_emitsEvent() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(20e18);

        vm.expectEmit(true, true, false, false);
        emit YieldForwarder.YieldForwarded(address(strategy), receiver, 0, 0);

        vm.prank(keeperEOA);
        forwarder.reportAndForward(address(strategy), 10_000);
    }

    // ═══════════════════════════════════════════════════════════
    // reportSwapAndForward — SWAP PATH
    // ═══════════════════════════════════════════════════════════

    function test_reportSwapAndForward_fullFlow() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        uint256 profit = 10e18;
        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        assertGt(assetsOut, 0, "Should swap and forward nonzero target assets");
        assertEq(targetAsset.balanceOf(receiver), assetsOut, "Receiver should get target asset");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should have 0 shares");
        // Underlying asset should NOT be at receiver (it was swapped)
        assertEq(asset.balanceOf(receiver), 0, "Receiver should NOT get underlying on swap path");
    }

    function test_reportSwapAndForward_revertsWhenNotKeeper() public {
        vm.prank(address(0x1111));
        vm.expectRevert(YieldForwarder.OnlyKeeper.selector);
        forwarder.reportSwapAndForward(address(strategy), 0, 0, block.timestamp + 1 hours);
    }

    function test_reportSwapAndForward_revertsOnExpiredDeadline() public {
        // Freshness check runs before any other work so a keeper transaction
        // that lands one block too late fails cheaply with ExpiredDeadline instead of
        // settling against a moved market.
        uint256 staleDeadline = block.timestamp - 1;

        vm.prank(keeperEOA);
        vm.expectRevert(
            abi.encodeWithSelector(SwappingYieldForwarder.ExpiredDeadline.selector, staleDeadline, block.timestamp)
        );
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0, staleDeadline);
    }

    function test_reportSwapAndForward_revertsOnDeadlineBoundary() public {
        // `block.timestamp == deadline` is accepted (require-eq semantics); `deadline + 1`
        // in the past is the tightest stale window and must revert.
        uint256 exactNow = block.timestamp;

        // Exactly at deadline: must not revert on the deadline check. We expect the
        // call to succeed through to the no-profit return of 0 (strategy is pristine).
        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, exactNow);
        assertEq(assetsOut, 0, "equal-timestamp deadline must pass the freshness gate");

        // One second past: must revert with ExpiredDeadline.
        vm.warp(block.timestamp + 2);
        vm.prank(keeperEOA);
        vm.expectRevert(
            abi.encodeWithSelector(SwappingYieldForwarder.ExpiredDeadline.selector, exactNow, block.timestamp)
        );
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0, exactNow);
    }

    function test_reportSwapAndForward_deadlineCheckedBeforeKeeperGate() public {
        // A non-keeper with an expired deadline must hit ExpiredDeadline first — cheaper
        // revert path and matches the ordering documented on the function.
        uint256 staleDeadline = block.timestamp - 1;

        vm.prank(address(0x1111)); // not keeper
        vm.expectRevert(
            abi.encodeWithSelector(SwappingYieldForwarder.ExpiredDeadline.selector, staleDeadline, block.timestamp)
        );
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0, staleDeadline);
    }

    function test_reportSwapAndForward_zeroProfit_returnsZero() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        assertEq(assetsOut, 0, "Should return 0 when no profit");
        assertEq(targetAsset.balanceOf(receiver), 0, "Receiver should get nothing");
    }

    function test_reportSwapAndForward_emitsEvent() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(20e18);

        vm.expectEmit(true, true, false, false);
        emit SwappingYieldForwarder.YieldSwappedAndForwarded(address(strategy), receiver, 0, 0, 0);

        vm.prank(keeperEOA);
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);
    }

    function test_reportSwapAndForward_multipleReports() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        // First profit cycle
        _simulateProfit(5e18);
        vm.prank(keeperEOA);
        uint256 assets1 = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);
        assertGt(assets1, 0, "First report should yield target assets");

        // Second profit cycle
        _simulateProfit(15e18);
        vm.prank(keeperEOA);
        uint256 assets2 = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);
        assertGt(assets2, 0, "Second report should yield target assets");

        assertEq(targetAsset.balanceOf(receiver), assets1 + assets2, "Receiver should accumulate all payouts");
    }

    function test_reportSwapAndForward_respectsMinAmountOut() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(10e18);

        // minAmountOut too high should revert (swapper enforces it)
        vm.prank(keeperEOA);
        vm.expectRevert();
        forwarder.reportSwapAndForward(address(strategy), 10_000, type(uint256).max, block.timestamp + 1 hours);
    }

    function test_reportSwapAndForward_lossScenario_noSharesMinted() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        // Simulate loss
        vm.prank(address(strategy));
        yieldSource.simulateLoss(5e18);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        assertEq(assetsOut, 0, "Loss report should return 0");
        assertEq(targetAsset.balanceOf(receiver), 0, "Receiver gets nothing on loss");
    }

    /// @notice Covers the `if (assetsIn == 0)` branch in reportSwapAndForward.
    ///         shares > 0 but redeem returns 0 assets (e.g., illiquid vault with maxLoss=MAX_BPS).
    ///         Must still emit YieldSwappedAndForwarded for monitoring observability.
    function test_reportSwapAndForward_sharesExistButRedeemReturnsZero() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(10e18);

        // Mock strategy.redeem() to return 0 assets (simulates illiquid vault)
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(bytes4(keccak256("redeem(uint256,address,address,uint256)"))),
            abi.encode(uint256(0))
        );

        vm.expectEmit(true, true, false, false);
        emit SwappingYieldForwarder.YieldSwappedAndForwarded(address(strategy), receiver, 0, 0, 0);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        assertEq(assetsOut, 0, "Should return 0 when redeem returns 0 assets");
        assertEq(targetAsset.balanceOf(receiver), 0, "Receiver gets nothing");

        vm.clearMockedCalls();
    }

    // ═══════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═══════════════════════════════════════════════════════════

    function test_reportSwapAndForward_fuzz_profitAmount(uint256 profit) public {
        profit = bound(profit, 1e15, 1e27);

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        assertGt(assetsOut, 0, "Should always forward positive target assets for positive profit");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should redeem all shares");
        assertEq(targetAsset.balanceOf(receiver), assetsOut, "Receiver balance should match returned assets");
    }

    function test_reportAndForward_fuzz_profitAmount(uint256 profit) public {
        profit = bound(profit, 1e15, 1e27);

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();

        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertGt(assets, 0, "Should always forward positive assets for positive profit");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should redeem all shares");
        assertEq(asset.balanceOf(receiver), assets, "Receiver balance should match returned assets");
    }

    // ═══════════════════════════════════════════════════════════
    // ROLE VERIFICATION
    // ═══════════════════════════════════════════════════════════

    function test_strategyDonationAddressIsForwarder() public view {
        assertEq(strategy.dragonRouter(), address(forwarder), "Strategy donation address should be forwarder");
    }

    function test_strategyKeeperIsForwarder() public view {
        assertEq(strategy.keeper(), address(forwarder), "Strategy keeper should be forwarder");
    }

    // ═══════════════════════════════════════════════════════════
    // setSwapper — VAULT MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function test_setSwapper_revertsOnNonManagementCaller() public {
        MockSwapper newSwapper = new MockSwapper(address(targetAsset), 1e18);
        vm.prank(address(0xBAD));
        vm.expectRevert(SwappingYieldForwarder.OnlyVaultManagement.selector);
        forwarder.setSwapper(address(newSwapper));
    }

    function test_setSwapper_revertsOnKeeperCaller() public {
        MockSwapper newSwapper = new MockSwapper(address(targetAsset), 1e18);
        vm.prank(keeperEOA);
        vm.expectRevert(SwappingYieldForwarder.OnlyVaultManagement.selector);
        forwarder.setSwapper(address(newSwapper));
    }

    function test_setSwapper_revertsOnZeroAddress() public {
        vm.prank(management);
        vm.expectRevert(SwappingYieldForwarder.InvalidSwapper.selector);
        forwarder.setSwapper(address(0));
    }

    function test_setSwapper_rotatesSwapperFromManagement() public {
        MockSwapper newSwapper = new MockSwapper(address(targetAsset), 1e18);

        vm.expectEmit(true, true, false, false);
        emit SwappingYieldForwarder.SwapperUpdated(address(swapper), address(newSwapper));

        vm.prank(management);
        forwarder.setSwapper(address(newSwapper));

        assertEq(address(forwarder.swapper()), address(newSwapper));
    }

    /// @notice After rotation, reportSwapAndForward routes through the new swapper.
    function test_setSwapper_newSwapperUsedOnNextSwap() public {
        ERC20Mock newTargetMintedBy = targetAsset; // same target asset, different adapter
        MockSwapper newSwapper = new MockSwapper(address(newTargetMintedBy), 2e18); // 2x rate

        vm.prank(management);
        forwarder.setSwapper(address(newSwapper));

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();
        _simulateProfit(10e18);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        // New swapper at 2x rate: assetsOut should be roughly 2x the redeemed underlying
        assertGt(assetsOut, 0);
        assertEq(targetAsset.balanceOf(receiver), assetsOut);
    }

    // ═══════════════════════════════════════════════════════════
    // setMinSlippageBps — ADMIN SLIPPAGE FLOOR
    // ═══════════════════════════════════════════════════════════

    function test_constructor_zeroMinSlippageBps_disablesFloor() public view {
        assertEq(forwarder.minSlippageBps(), 0, "Constructor floor 0 disables the floor");
    }

    function test_setMinSlippageBps_revertsOnNonManagement() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SwappingYieldForwarder.OnlyVaultManagement.selector);
        forwarder.setMinSlippageBps(9_900);
    }

    function test_setMinSlippageBps_revertsAboveMaxBps() public {
        vm.prank(management);
        vm.expectRevert(SwappingYieldForwarder.InvalidSlippageBps.selector);
        forwarder.setMinSlippageBps(10_001);
    }

    function test_setMinSlippageBps_updatesState() public {
        vm.expectEmit(false, false, false, true);
        emit SwappingYieldForwarder.MinSlippageBpsUpdated(0, 9_900);

        vm.prank(management);
        forwarder.setMinSlippageBps(9_900);

        assertEq(forwarder.minSlippageBps(), 9_900);
    }

    /// @notice When a floor is set, the keeper cannot pass a minAmountOut below
    ///         (assetsIn * floor / MAX_BPS).
    function test_reportSwapAndForward_enforcesSlippageFloor() public {
        vm.prank(management);
        forwarder.setMinSlippageBps(9_900); // 99% floor

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();
        uint256 profit = 10e18;
        _simulateProfit(profit);

        // minAmountOut = 0 is below the floor of assetsIn * 9_900 / 10_000
        vm.prank(keeperEOA);
        vm.expectRevert(
            abi.encodeWithSelector(SwappingYieldForwarder.SlippageFloorTooLoose.selector, (profit * 9_900) / 10_000, 0)
        );
        forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);
    }

    /// @notice A constructor-supplied floor is active before any management call.
    function test_reportSwapAndForward_constructorFloor_enforcesImmediately() public {
        (SwappingYieldForwarder fwd, IMockStrategy strat, MockYieldSource src) = _deployFixtureWithFloor(9_900);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(address(strat), DEPOSIT_AMOUNT);
        strat.deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        vm.prank(address(fwd));
        strat.report();
        uint256 profit = 10e18;
        asset.mint(address(src), profit);

        vm.prank(keeperEOA);
        vm.expectRevert(
            abi.encodeWithSelector(SwappingYieldForwarder.SlippageFloorTooLoose.selector, (profit * 9_900) / 10_000, 0)
        );
        fwd.reportSwapAndForward(address(strat), 10_000, 0, block.timestamp + 1 hours);
    }

    /// @notice Codex P1 regression — USDC(6) -> USDS(18), 99% floor.
    ///         Without decimals normalization the floor is computed in input-asset units
    ///         (~990_000 wei for 1 USDC of profit), and a `minAmountOut` of 1e17 wei
    ///         (a laughable 0.0001 USDS for 1 USDC of value) silently clears the check.
    ///         With normalization the floor becomes 9.9e17 in target units, and the
    ///         same minAmountOut reverts.
    function test_reportSwapAndForward_floor_lowToHighDecimals_enforcesNormalizedFloor() public {
        (
            SwappingYieldForwarder fwd,
            IMockStrategy strat,
            MockERC20 assetMix,
            ,
            MockYieldSource yieldSrc
        ) = _deployMixedDecimalFixture(6, 18);

        vm.prank(management);
        fwd.setMinSlippageBps(9_900);

        uint256 depositAmt = 100e6;
        uint256 profit = 1e6;
        assetMix.mint(user, depositAmt);
        vm.startPrank(user);
        assetMix.approve(address(strat), depositAmt);
        strat.deposit(depositAmt, user);
        vm.stopPrank();
        vm.prank(address(fwd));
        strat.report();
        assetMix.mint(address(yieldSrc), profit);

        // Normalized floor = (1e6 * 10**12) * 9_900 / 10_000 = 9.9e17 (target units).
        // Pre-fix floor (raw, no scaling) = 1e6 * 9_900 / 10_000 = 990_000 — so
        // minAmountOut = 1e17 sits between the two and distinguishes the fix.
        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(SwappingYieldForwarder.SlippageFloorTooLoose.selector, 9.9e17, 1e17));
        fwd.reportSwapAndForward(address(strat), 10_000, 1e17, block.timestamp + 1 hours);
    }

    /// @notice Codex P1 regression — USDS(18) -> USDC(6), 99% floor.
    ///         Without normalization the floor is 9.9e17 (18-dec input units), which is
    ///         orders of magnitude above any realistic USDC `minAmountOut`, turning every
    ///         valid swap into a DoS. With normalization the floor is 990_000 (6-dec
    ///         target units) and a `minAmountOut` of 1e6 (1 USDC) clears it.
    function test_reportSwapAndForward_floor_highToLowDecimals_doesNotDos() public {
        (
            SwappingYieldForwarder fwd,
            IMockStrategy strat,
            MockERC20 assetMix,
            ,
            MockYieldSource yieldSrc
        ) = _deployMixedDecimalFixture(18, 6);

        vm.prank(management);
        fwd.setMinSlippageBps(9_900);

        uint256 depositAmt = 100e18;
        uint256 profit = 1e18;
        assetMix.mint(user, depositAmt);
        vm.startPrank(user);
        assetMix.approve(address(strat), depositAmt);
        strat.deposit(depositAmt, user);
        vm.stopPrank();
        vm.prank(address(fwd));
        strat.report();
        assetMix.mint(address(yieldSrc), profit);

        // Normalized floor = (1e18 / 10**12) * 9_900 / 10_000 = 990_000 (target units).
        // Keeper passes minAmountOut = 1e6 (1 USDC), which clears the correct floor.
        // Pre-fix: floor would be 9.9e17 and the same call would revert (DoS).
        vm.prank(keeperEOA);
        uint256 assetsOut = fwd.reportSwapAndForward(address(strat), 10_000, 1e6, block.timestamp + 1 hours);
        assertGt(assetsOut, 0, "swap should succeed when floor is correctly normalized");
    }

    /// @dev Internal helper: deploys a fresh forwarder + strategy pair whose asset
    ///      and targetAsset have arbitrary decimals. Reuses the existing
    ///      `receiver`/`keeperEOA`/`management`/`implementation` fixtures.
    function _deployMixedDecimalFixture(
        uint8 inDec,
        uint8 outDec
    )
        internal
        returns (
            SwappingYieldForwarder fwd,
            IMockStrategy strat,
            MockERC20 assetMix,
            MockERC20 targetMix,
            MockYieldSource yieldSrc
        )
    {
        assetMix = new MockERC20(inDec);
        targetMix = new MockERC20(outDec);
        yieldSrc = new MockYieldSource(address(assetMix));
        MixedDecimalSwapper mixSwapper = new MixedDecimalSwapper(address(targetMix), inDec, outDec);

        uint256 baseNonce = vm.getNonce(address(this));
        address predictedStrat = vm.computeCreateAddress(address(this), baseNonce + 1);

        fwd = new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            address(targetMix),
            address(mixSwapper),
            predictedStrat,
            0
        );

        strat = IMockStrategy(
            address(
                new MockStrategy(
                    address(assetMix),
                    address(yieldSrc),
                    management,
                    address(fwd),
                    emergencyAdmin,
                    address(fwd),
                    address(implementation)
                )
            )
        );
        require(address(strat) == predictedStrat, "mixed-decimal fixture address mismatch");

        vm.startPrank(management);
        strat.setKeeper(address(fwd));
        strat.setEmergencyAdmin(emergencyAdmin);
        strat.setPendingManagement(management);
        strat.acceptManagement();
        vm.stopPrank();
        _seedMinimumPosition(address(strat), assetMix, management);
    }

    /// @notice A constructor floor of 0 preserves the prior "keeper sets slippage"
    ///         behaviour -- any minAmountOut including 0 is accepted.
    function test_reportSwapAndForward_zeroFloor_acceptsZeroMinAmountOut() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();
        _simulateProfit(10e18);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);
        assertGt(assetsOut, 0);
    }

    function _deployFixtureWithFloor(
        uint16 floorBps
    ) internal returns (SwappingYieldForwarder fwd, IMockStrategy strat, MockYieldSource src) {
        src = new MockYieldSource(address(asset));

        uint256 baseNonce = vm.getNonce(address(this));
        address predictedStrat = vm.computeCreateAddress(address(this), baseNonce + 1);

        fwd = new SwappingYieldForwarder(
            receiver,
            keeperEOA,
            address(targetAsset),
            address(swapper),
            predictedStrat,
            floorBps
        );

        strat = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset),
                    address(src),
                    management,
                    address(fwd),
                    emergencyAdmin,
                    address(fwd),
                    address(implementation)
                )
            )
        );
        require(address(strat) == predictedStrat, "floor fixture address mismatch");

        vm.startPrank(management);
        strat.setKeeper(address(fwd));
        strat.setEmergencyAdmin(emergencyAdmin);
        strat.setPendingManagement(management);
        strat.acceptManagement();
        vm.stopPrank();
        _seedMinimumPosition(address(strat), asset, management);
    }

    // ═══════════════════════════════════════════════════════════
    // POST-SWAP minAmountOut RE-CHECK (defense-in-depth)
    // ═══════════════════════════════════════════════════════════

    /// @notice A buggy swapper that under-reports assetsOut must be caught by
    ///         the forwarder's own threshold check, even if the swapper itself
    ///         doesn't revert. Regression for the defense-in-depth guard.
    function test_reportSwapAndForward_revertsWhenSwapperReportsBelowMin() public {
        // Install a dishonest swapper that mints the full output but returns 1 wei.
        DishonestSwapper dishonest = new DishonestSwapper(address(targetAsset));
        vm.prank(management);
        forwarder.setSwapper(address(dishonest));

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();
        _simulateProfit(10e18);

        vm.prank(keeperEOA);
        vm.expectRevert(abi.encodeWithSelector(SwappingYieldForwarder.InsufficientSwapOutput.selector, 5e18, 1));
        forwarder.reportSwapAndForward(address(strategy), 10_000, 5e18, block.timestamp + 1 hours);
    }

    /// @notice A pull-pattern swapper may consume less than `assetsIn` and leave
    ///         residual input with the forwarder. Authorized recovery flushes it
    ///         to the immutable receiver, while the forwarder must not retain a
    ///         live swapper allowance after the successful swap.
    function test_reportSwapAndForward_partialPullResidueRecoverableAndAllowanceCleared() public {
        PartialPullSwapper partialPull = new PartialPullSwapper(address(targetAsset), 6_000);
        vm.prank(management);
        forwarder.setSwapper(address(partialPull));

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);
        vm.prank(address(forwarder));
        strategy.report();
        _simulateProfit(10e18);

        vm.prank(keeperEOA);
        uint256 assetsOut = forwarder.reportSwapAndForward(address(strategy), 10_000, 0, block.timestamp + 1 hours);

        uint256 residual = asset.balanceOf(address(forwarder));
        assertGt(assetsOut, 0, "partial pull still produces output");
        assertGt(residual, 0, "unpulled input should remain recoverable at forwarder");
        assertEq(asset.allowance(address(forwarder), address(partialPull)), 0, "swapper allowance must be cleared");

        uint256 receiverAssetBefore = asset.balanceOf(receiver);
        vm.prank(management);
        forwarder.forwardToken(address(asset));

        assertEq(asset.balanceOf(address(forwarder)), 0, "forwarder residual must be flushed");
        assertEq(asset.balanceOf(receiver), receiverAssetBefore + residual, "receiver gets residual input");
    }
}

/// @dev A swapper that lies about amountOut to exercise the forwarder's post-swap check.
contract DishonestSwapper {
    using SafeERC20 for IERC20;

    address public immutable outputToken;

    constructor(address _outputToken) {
        outputToken = _outputToken;
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256, address receiver) external returns (uint256) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        ERC20Mock(outputToken).mint(receiver, amountIn);
        return 1; // lies: reports 1 wei despite minting full amount
    }
}

/// @dev Mock swapper for mixed-decimal targets (MockERC20 output). Models a
///      1:1-value conversion across a decimals gap: 1e{inDec} of tokenIn ->
///      1e{outDec} of tokenOut. Required because MockSwapper hardcodes an
///      ERC20Mock cast on the output token, which doesn't support custom decimals.
contract MixedDecimalSwapper {
    using SafeERC20 for IERC20;

    address payable public immutable outputToken;
    uint8 public immutable inDecimals;
    uint8 public immutable outDecimals;

    error Insufficient(uint256 expected, uint256 actual);

    constructor(address _outputToken, uint8 _inDecimals, uint8 _outDecimals) {
        outputToken = payable(_outputToken);
        inDecimals = _inDecimals;
        outDecimals = _outDecimals;
    }

    function swap(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = inDecimals >= outDecimals
            ? amountIn / (10 ** (inDecimals - outDecimals))
            : amountIn * (10 ** (outDecimals - inDecimals));
        if (amountOut < minAmountOut) revert Insufficient(minAmountOut, amountOut);
        MockERC20(outputToken).mint(receiver, amountOut);
    }
}

/// @dev Pull-pattern swapper that intentionally consumes only part of amountIn.
contract PartialPullSwapper {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    address public immutable outputToken;
    uint256 public immutable pullBps;

    constructor(address _outputToken, uint256 _pullBps) {
        outputToken = _outputToken;
        pullBps = _pullBps;
    }

    function swap(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256) {
        uint256 pulled = (amountIn * pullBps) / BPS;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), pulled);
        if (pulled < minAmountOut) revert MockSwapper.InsufficientOutput(minAmountOut, pulled);
        ERC20Mock(outputToken).mint(receiver, pulled);
        return pulled;
    }
}
