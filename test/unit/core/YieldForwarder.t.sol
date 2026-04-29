// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { YieldForwarder } from "src/core/YieldForwarder.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

import { MockFactory } from "test/mocks/MockFactory.sol";
import { MockStrategy } from "test/mocks/core/tokenized-strategies/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/tokenized-strategies/MockYieldSource.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { SeedHelpers } from "test/unit/strategies/yieldDonating/utils/SeedHelpers.sol";

contract YieldForwarderTest is SeedHelpers {
    YieldForwarder public forwarder;
    ERC20Mock public asset;
    IMockStrategy public strategy;
    MockYieldSource public yieldSource;
    MockFactory public mockFactory;
    YieldDonatingTokenizedStrategy public implementation;

    address public receiver = address(0xBEEF);
    address public keeperEOA = address(0xCAFE);
    address public management = address(0xA1);
    address public emergencyAdmin = address(0xA2);
    address public user = address(0xA3);
    address public protocolFeeRecipient = address(0xA4);

    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        // Deploy factory (0 fees for clean test math)
        mockFactory = new MockFactory(0, protocolFeeRecipient);

        // Deploy YieldDonatingTokenizedStrategy implementation
        implementation = new YieldDonatingTokenizedStrategy();

        // Deploy asset and yield source
        asset = new ERC20Mock();
        yieldSource = new MockYieldSource(address(asset));

        // Deploy YieldForwarder first (address needed for strategy config)
        forwarder = new YieldForwarder(receiver, keeperEOA);

        // Deploy strategy with the forwarder as both keeper and donation address
        strategy = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset),
                    address(yieldSource),
                    management,
                    address(forwarder), // keeper = forwarder (so forwarder can call report())
                    emergencyAdmin,
                    address(forwarder), // donationAddress = forwarder (profit shares go here)
                    address(implementation)
                )
            )
        );

        // Configure strategy roles
        vm.startPrank(management);
        strategy.setKeeper(address(forwarder));
        strategy.setEmergencyAdmin(emergencyAdmin);
        strategy.setPendingManagement(management);
        strategy.acceptManagement();
        vm.stopPrank();
        _seedMinimumPosition(address(strategy), asset, management);

        // Labels
        vm.label(receiver, "Receiver");
        vm.label(keeperEOA, "KeeperEOA");
        vm.label(address(forwarder), "YieldForwarder");
        vm.label(address(strategy), "Strategy");
        vm.label(address(asset), "Asset");
        vm.label(address(yieldSource), "YieldSource");
        vm.label(management, "Management");
        vm.label(user, "User");
    }

    /// @dev Mints assets to a user, approves, and deposits into the strategy
    function _depositIntoStrategy(address _user, uint256 _amount) internal {
        asset.mint(_user, _amount);
        vm.startPrank(_user);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, _user);
        vm.stopPrank();
    }

    /// @dev Simulates yield by minting extra assets directly to the yield source
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

    function test_constructor_revertsOnZeroReceiver() public {
        vm.expectRevert(YieldForwarder.InvalidReceiver.selector);
        new YieldForwarder(address(0), keeperEOA);
    }

    function test_constructor_revertsOnZeroKeeper() public {
        vm.expectRevert(YieldForwarder.InvalidKeeper.selector);
        new YieldForwarder(receiver, address(0));
    }

    // ═══════════════════════════════════════════════════════════
    // reportAndForward — FULL VAULT INTEGRATION TESTS
    // ═══════════════════════════════════════════════════════════

    function test_reportAndForward_fullFlow() public {
        // 1. User deposits into strategy
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // 2. Strategy deploys funds to yield source on report
        //    (initial report to move idle → deployed)
        vm.prank(address(forwarder));
        strategy.report();

        // 3. Simulate profit in yield source
        uint256 profit = 10e18;
        _simulateProfit(profit);

        // 4. Keeper triggers reportAndForward
        uint256 receiverBalanceBefore = asset.balanceOf(receiver);
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        // 5. Verify: assets forwarded to receiver
        assertGt(assets, 0, "Should forward nonzero assets");
        assertEq(asset.balanceOf(receiver), receiverBalanceBefore + assets, "Receiver should get forwarded assets");
        // 6. Forwarder should hold no shares
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should have 0 shares");
    }

    function test_reportAndForward_revertsWhenNotKeeper() public {
        address nonKeeper = address(0x1111);
        vm.prank(nonKeeper);
        vm.expectRevert(YieldForwarder.OnlyKeeper.selector);
        forwarder.reportAndForward(address(strategy), 0);
    }

    function test_reportAndForward_zeroProfit_returnsZero() public {
        // Deposit but no yield → report produces no profit
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Initial report to deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // No profit simulated; second report has nothing new
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertEq(assets, 0, "Should return 0 when no profit");
        assertEq(asset.balanceOf(receiver), 0, "Receiver should get nothing");
    }

    function test_reportAndForward_emitsEvent() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // Simulate profit
        uint256 profit = 20e18;
        _simulateProfit(profit);

        // We expect a YieldForwarded event with the strategy and receiver addresses
        // The exact shares/assets depend on vault math, so check indexed params only
        vm.expectEmit(true, true, false, false);
        emit YieldForwarder.YieldForwarded(address(strategy), receiver, 0, 0);

        vm.prank(keeperEOA);
        forwarder.reportAndForward(address(strategy), 10_000);
    }

    function test_reportAndForward_noEventOnZeroProfit() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // No profit — check no YieldForwarded event
        vm.recordLogs();
        vm.prank(keeperEOA);
        forwarder.reportAndForward(address(strategy), 10_000);

        bytes32 yieldForwardedSelector = keccak256("YieldForwarded(address,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != yieldForwardedSelector,
                "YieldForwarded should not be emitted on zero profit"
            );
        }
    }

    function test_reportAndForward_multipleReports() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // First profit cycle
        uint256 profit1 = 5e18;
        _simulateProfit(profit1);

        vm.prank(keeperEOA);
        uint256 assets1 = forwarder.reportAndForward(address(strategy), 10_000);
        assertGt(assets1, 0, "First report should yield assets");

        // Second profit cycle
        uint256 profit2 = 15e18;
        _simulateProfit(profit2);

        vm.prank(keeperEOA);
        uint256 assets2 = forwarder.reportAndForward(address(strategy), 10_000);
        assertGt(assets2, 0, "Second report should yield assets");

        // Receiver accumulated both payouts
        assertEq(asset.balanceOf(receiver), assets1 + assets2, "Receiver should accumulate all payouts");
    }

    function test_reportAndForward_multipleStrategies() public {
        // Create a second independent vault + yield source
        ERC20Mock asset2 = new ERC20Mock();
        MockYieldSource yieldSource2 = new MockYieldSource(address(asset2));

        IMockStrategy strategy2 = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset2),
                    address(yieldSource2),
                    management,
                    address(forwarder),
                    emergencyAdmin,
                    address(forwarder),
                    address(implementation)
                )
            )
        );

        vm.startPrank(management);
        strategy2.setKeeper(address(forwarder));
        strategy2.setEmergencyAdmin(emergencyAdmin);
        strategy2.setPendingManagement(management);
        strategy2.acceptManagement();
        vm.stopPrank();
        _seedMinimumPosition(address(strategy2), asset2, management);

        // Deposit into both strategies
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        asset2.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset2.approve(address(strategy2), DEPOSIT_AMOUNT);
        strategy2.deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        // Deploy funds for both
        vm.prank(address(forwarder));
        strategy.report();
        vm.prank(address(forwarder));
        strategy2.report();

        // Simulate profit in both
        uint256 profit1 = 8e18;
        uint256 profit2 = 12e18;
        asset.mint(address(yieldSource), profit1);
        asset2.mint(address(yieldSource2), profit2);

        // Forward from strategy 1
        vm.prank(keeperEOA);
        uint256 assets1 = forwarder.reportAndForward(address(strategy), 10_000);
        assertGt(assets1, 0, "Strategy 1 should produce assets");
        assertEq(asset.balanceOf(receiver), assets1);

        // Forward from strategy 2
        vm.prank(keeperEOA);
        uint256 assets2 = forwarder.reportAndForward(address(strategy2), 10_000);
        assertGt(assets2, 0, "Strategy 2 should produce assets");
        assertEq(asset2.balanceOf(receiver), assets2);
    }

    function test_reportAndForward_passesMaxLoss() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // Simulate profit
        _simulateProfit(10e18);

        // Use specific maxLoss (100 bps = 1%)
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 100);
        assertGt(assets, 0, "Should succeed with maxLoss=100bps");
    }

    function test_reportAndForward_lossScenario_noSharesMinted() public {
        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // Simulate a loss in yield source (assets disappear)
        uint256 loss = 5e18;
        vm.prank(address(strategy));
        yieldSource.simulateLoss(loss);

        // Report should register loss; no profit shares minted to forwarder
        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertEq(assets, 0, "Loss report should return 0 assets");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "No shares should remain");
        assertEq(asset.balanceOf(receiver), 0, "Receiver gets nothing on loss");
    }

    function test_reportAndForward_fuzz_profitAmount(uint256 profit) public {
        profit = bound(profit, 1e15, 1e27);

        _depositIntoStrategy(user, DEPOSIT_AMOUNT);

        // Deploy funds
        vm.prank(address(forwarder));
        strategy.report();

        // Simulate fuzzed profit
        _simulateProfit(profit);

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(strategy), 10_000);

        assertGt(assets, 0, "Should always forward positive assets for positive profit");
        assertEq(strategy.balanceOf(address(forwarder)), 0, "Forwarder should redeem all shares");
        assertEq(asset.balanceOf(receiver), assets, "Receiver balance should match returned assets");
    }

    function test_reportAndForward_donationAddressIsForwarder() public view {
        // Verify the strategy's dragonRouter (donation address) is the forwarder
        assertEq(strategy.dragonRouter(), address(forwarder), "Strategy donation address should be forwarder");
    }

    function test_reportAndForward_keeperIsForwarder() public view {
        // Verify the strategy's keeper is the forwarder
        assertEq(strategy.keeper(), address(forwarder), "Strategy keeper should be forwarder");
    }
}
