// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract ReportLifecycleTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    // ==================== Report with Profit ====================

    function test_reportProfit_mintsSharesToDragonRouter(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 profit = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), profit);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, profit, "profit mismatch");
        assertEq(reportedLoss, 0, "should report zero loss");
        assertGt(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon should receive shares");
    }

    function test_reportProfit_ppsUnchanged(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 ppsBefore = strategy.pricePerShare();

        uint256 profit = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.pricePerShare(), ppsBefore, "PPS should remain unchanged after profit report");

        // PPS should stay unchanged even after unlock period
        skip(profitMaxUnlockTime);
        assertEq(strategy.pricePerShare(), ppsBefore, "PPS should remain unchanged after full unlock");
    }

    function test_reportProfit_emitsDonationMinted(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        // Expect DonationMinted event
        vm.expectEmit(true, false, false, false, address(strategy));
        emit YieldDonatingTokenizedStrategy.DonationMinted(donationAddress, 0); // amount not checked with false

        vm.prank(keeper);
        strategy.report();
    }

    function test_reportProfit_emitsReported(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit TokenizedStrategy.Reported(profit, 0);

        vm.prank(keeper);
        strategy.report();
    }

    // ==================== Report with Loss + Burning Enabled ====================

    function test_reportLoss_burningEnabled_burnsDragonShares() public {
        // Enable burning on the strategy (MockStrategy defaults to false)
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Report once to establish accounting
        vm.prank(keeper);
        strategy.report();

        // Transfer shares to dragon router to simulate accumulated profit shares
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);
        assertEq(dragonBalBefore, 20e18, "dragon should have 20 shares");

        // Simulate a loss smaller than dragon balance
        uint256 loss = 15e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, 0, "should report zero profit");
        assertEq(reportedLoss, loss, "loss mismatch");

        // Dragon shares should have been burned to cover the loss
        assertLt(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should decrease");
    }

    function test_reportLoss_burningEnabled_lossExceedsDragonShares() public {
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon only 10 shares
        vm.prank(user);
        strategy.transfer(donationAddress, 10e18);

        // Simulate a loss larger than dragon holdings
        uint256 loss = 25e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, loss, "loss mismatch");
        assertEq(strategy.balanceOf(donationAddress), 0, "all dragon shares should be burned");
        // Remaining loss affects all holders via PPS reduction
        assertEq(strategy.totalAssets(), amount - loss, "total assets should reflect full loss");
    }

    function test_reportLoss_burningEnabled_emitsDonationBurned() public {
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        uint256 loss = 15e18;
        yieldSource.simulateLoss(loss);

        vm.expectEmit(true, false, false, false, address(strategy));
        emit YieldDonatingTokenizedStrategy.DonationBurned(donationAddress, 0);

        vm.prank(keeper);
        strategy.report();
    }

    // ==================== Report with Loss + Burning Disabled ====================

    function test_reportLoss_burningDisabled_noSharesBurned() public {
        // Burning is disabled by default on MockStrategy (enableBurning=false)

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);
        uint256 totalSupplyBefore = strategy.totalSupply();

        uint256 loss = 15e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, loss, "loss mismatch");
        assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should not change");
        assertEq(strategy.totalSupply(), totalSupplyBefore, "total supply should not change");
        // PPS drops for all holders
        assertEq(strategy.totalAssets(), amount - loss, "total assets should reflect loss");
    }

    // ==================== Report with Zero Change ====================

    function test_reportZeroChange_noMintNoBurn(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 supplyBefore = strategy.totalSupply();
        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "should report zero profit");
        assertEq(loss, 0, "should report zero loss");
        assertEq(strategy.totalSupply(), supplyBefore, "supply should not change");
        assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon balance should not change");
    }

    // ==================== Consecutive Reports ====================

    function test_consecutiveReports_alternatingProfitLoss() public {
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Report 1: profit
        asset.mint(address(yieldSource), 10e18);
        vm.prank(keeper);
        (uint256 profit1, uint256 loss1) = strategy.report();
        assertEq(profit1, 10e18, "report1 profit");
        assertEq(loss1, 0, "report1 loss");
        uint256 dragonAfterProfit = strategy.balanceOf(donationAddress);
        assertGt(dragonAfterProfit, 0, "dragon should have shares after profit");

        // Report 2: loss (smaller than dragon holdings)
        uint256 lossAmount = 5e18;
        yieldSource.simulateLoss(lossAmount);
        vm.prank(keeper);
        (uint256 profit2, uint256 loss2) = strategy.report();
        assertEq(profit2, 0, "report2 profit");
        assertEq(loss2, lossAmount, "report2 loss");
        assertLt(strategy.balanceOf(donationAddress), dragonAfterProfit, "dragon shares should decrease after loss");

        // Report 3: profit again
        asset.mint(address(yieldSource), 8e18);
        vm.prank(keeper);
        (uint256 profit3, uint256 loss3) = strategy.report();
        assertEq(profit3, 8e18, "report3 profit");
        assertEq(loss3, 0, "report3 loss");
    }

    // ==================== Report After Shutdown ====================

    function test_reportAfterShutdown_stillWorks(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(management);
        strategy.shutdownStrategy();

        assertTrue(strategy.isShutdown(), "should be shutdown");

        // Simulate profit
        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        // Report should still work after shutdown
        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, profit, "profit mismatch");
        assertEq(reportedLoss, 0, "should report zero loss");
    }

    // ==================== lastReport Timestamp ====================

    function test_lastReportTimestamp_updatesOnEachReport() public {
        uint256 amount = 1e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // First report
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.lastReport(), block.timestamp, "lastReport should match after first report");

        uint256 firstReportTime = block.timestamp;

        // Skip time and do second report
        skip(1 days);
        asset.mint(address(yieldSource), 0.1e18);

        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.lastReport(), block.timestamp, "lastReport should match after second report");
        assertGt(strategy.lastReport(), firstReportTime, "lastReport should increase");
    }

    // ==================== Fuzz: Varying Profit Sizes ====================

    function testFuzz_reportProfit_varyingSizes(uint256 _amount, uint256 _profit) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profit = bound(_profit, 1, _amount); // profit up to 100% of deposited amount

        mintAndDepositIntoStrategy(strategy, user, _amount);

        asset.mint(address(yieldSource), _profit);

        uint256 ppsBefore = strategy.pricePerShare();

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, _profit, "profit mismatch");
        assertEq(reportedLoss, 0, "should be zero loss");
        assertEq(strategy.pricePerShare(), ppsBefore, "PPS should not change");
        assertEq(strategy.totalAssets(), _amount + _profit, "totalAssets should include profit");
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon should get shares");
    }

    // ==================== Fuzz: Varying Loss Sizes vs Dragon Balance ====================

    function testFuzz_reportLoss_vsDragonBalance(uint256 _amount, uint256 _dragonShares, uint256 _loss) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.report();

        // Bound dragon shares to user's balance
        uint256 userBal = strategy.balanceOf(user);
        _dragonShares = bound(_dragonShares, 1, userBal);

        vm.prank(user);
        strategy.transfer(donationAddress, _dragonShares);

        // Bound loss to total assets so yield source doesn't underflow
        uint256 maxLoss = yieldSource.balance();
        _loss = bound(_loss, 1, maxLoss);

        yieldSource.simulateLoss(_loss);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, _loss, "loss mismatch");

        // Dragon balance should decrease (or be fully burned)
        assertLe(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon balance should not increase");
        if (dragonBalBefore > 0) {
            assertLt(
                strategy.balanceOf(donationAddress),
                dragonBalBefore,
                "dragon shares should decrease when burning enabled"
            );
        }
    }
}
