// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract BurningToggleTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    // ==================== Access Control ====================

    function test_setEnableBurning_byManagement_true() public {
        // MockStrategy starts with enableBurning=false, verify then enable
        assertFalse(strategy.enableBurning(), "should be disabled");

        vm.expectEmit(true, false, false, true, address(strategy));
        emit TokenizedStrategy.UpdateBurningMechanism(true);

        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
        assertTrue(strategy.enableBurning(), "should be enabled");
    }

    function test_setEnableBurning_byManagement_false() public {
        // First enable burning so we can test disabling
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
        assertTrue(strategy.enableBurning(), "should be enabled");

        vm.expectEmit(true, false, false, true, address(strategy));
        emit TokenizedStrategy.UpdateBurningMechanism(false);

        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);
        assertFalse(strategy.enableBurning(), "should be disabled");
    }

    function test_setEnableBurning_byNonManagement_reverts(address _caller) public {
        vm.assume(_caller != management);

        vm.prank(_caller);
        vm.expectRevert("!management");
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
    }

    // ==================== Burning Enabled Mid-Lifecycle ====================

    function test_burningEnabledMidLifecycle_lossAfterToggleBurnsShares() public {
        // Start with burning disabled
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon some shares
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Enable burning mid-lifecycle
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        // Simulate a loss
        uint256 loss = 10e18;
        yieldSource.simulateLoss(loss);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        strategy.report();

        // Dragon shares should be burned since burning is now enabled
        assertLt(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should decrease");
    }

    // ==================== Burning Disabled Mid-Lifecycle ====================

    function test_burningDisabledMidLifecycle_lossAfterToggleDoesNotBurn() public {
        // First enable burning so we can test disabling it mid-lifecycle
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
        assertTrue(strategy.enableBurning(), "should be enabled");

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon some shares
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Disable burning mid-lifecycle
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);

        // Simulate a loss
        uint256 loss = 10e18;
        yieldSource.simulateLoss(loss);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);
        uint256 totalSupplyBefore = strategy.totalSupply();

        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, loss, "loss mismatch");
        assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should NOT change");
        assertEq(strategy.totalSupply(), totalSupplyBefore, "total supply should NOT change");
    }

    // ==================== Toggle Does Not Affect Profit Minting ====================

    function test_burningToggle_doesNotAffectProfitMinting_disabled() public {
        // Disable burning
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Generate profit
        uint256 profit = 10e18;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        (uint256 reportedProfit, ) = strategy.report();

        assertEq(reportedProfit, profit, "profit should still be reported");
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon should still get profit shares when burning disabled");
    }

    function test_burningToggle_doesNotAffectProfitMinting_enabled() public {
        // Enable burning
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
        assertTrue(strategy.enableBurning(), "should be enabled");

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Generate profit
        uint256 profit = 10e18;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        (uint256 reportedProfit, ) = strategy.report();

        assertEq(reportedProfit, profit, "profit should be reported");
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon should get profit shares when burning enabled");
    }

    // ==================== Rapid Toggle ====================

    function test_rapidToggle_correctBehavior() public {
        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Toggle burning off and on quickly
        vm.startPrank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);
        vm.stopPrank();

        // Simulate loss while burning is disabled (final state)
        yieldSource.simulateLoss(10e18);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        strategy.report();

        // Burning is disabled so dragon shares should not change
        assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should not change");

        // Now enable burning and report another loss
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        yieldSource.simulateLoss(5e18);

        vm.prank(keeper);
        strategy.report();

        // Now dragon shares should be burned
        assertLt(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should decrease");
    }

    // ==================== Fuzz: Toggle and Report ====================

    function testFuzz_toggleAndReport(uint256 _amount, uint256 _loss, bool _enableBurning) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.report();

        // Transfer half of user shares to dragon
        uint256 toTransfer = strategy.balanceOf(user) / 2;
        vm.prank(user);
        strategy.transfer(donationAddress, toTransfer);

        // Set burning state
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(_enableBurning);

        // Bound loss to yield source balance
        uint256 maxLoss = yieldSource.balance();
        _loss = bound(_loss, 1, maxLoss);

        yieldSource.simulateLoss(_loss);

        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.prank(keeper);
        strategy.report();

        if (_enableBurning) {
            // Dragon shares should be burned (or partially burned)
            assertLe(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon balance should not increase");
            if (dragonBalBefore > 0) {
                assertLt(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should decrease");
            }
        } else {
            // No burning: dragon shares unchanged
            assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon shares should not change");
        }
    }
}
