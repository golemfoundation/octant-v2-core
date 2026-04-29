// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract ShutdownTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    // ==================== Deposits Blocked After Shutdown ====================

    function test_depositBlockedAfterShutdown(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        vm.prank(management);
        strategy.shutdownStrategy();
        assertTrue(strategy.isShutdown(), "should be shutdown");

        asset.mint(user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert("ERC4626: deposit more than max");
        vm.prank(user);
        strategy.deposit(_amount, user);
    }

    function test_mintBlockedAfterShutdown(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        vm.prank(management);
        strategy.shutdownStrategy();

        asset.mint(user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert("ERC4626: mint more than max");
        vm.prank(user);
        strategy.mint(_amount, user);
    }

    // ==================== Withdrawals Still Work After Shutdown ====================

    function test_withdrawWorksAfterShutdown(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(management);
        strategy.shutdownStrategy();
        assertTrue(strategy.isShutdown(), "should be shutdown");

        uint256 balBefore = asset.balanceOf(user);
        uint256 userShares = strategy.balanceOf(user);

        vm.prank(user);
        strategy.redeem(userShares, user, user);

        assertEq(asset.balanceOf(user) - balBefore, _amount, "user should get full deposit back");
        assertEq(strategy.balanceOf(user), 0, "user should have 0 shares");
    }

    // ==================== Report Still Works After Shutdown ====================

    function test_reportWorksAfterShutdown_profit(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(management);
        strategy.shutdownStrategy();

        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, profit, "profit should be reported after shutdown");
        assertEq(reportedLoss, 0, "should be zero loss");
    }

    function test_reportWorksAfterShutdown_loss() public {
        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon some shares
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        vm.prank(management);
        strategy.shutdownStrategy();

        uint256 loss = 10e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = strategy.report();

        assertEq(reportedProfit, 0, "should be zero profit");
        assertEq(reportedLoss, loss, "loss should be reported after shutdown");
    }

    // ==================== Emergency Withdraw ====================

    function test_emergencyWithdraw_byManagement(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(management);
        strategy.shutdownStrategy();

        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Funds should be pulled from yield source to strategy
        assertEq(asset.balanceOf(address(strategy)), _amount, "funds should be in strategy");
        assertEq(asset.balanceOf(address(yieldSource)), 0, "yield source should be empty");
    }

    function test_emergencyWithdraw_byEmergencyAdmin(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount);

        assertEq(asset.balanceOf(address(strategy)), _amount, "funds should be in strategy");
    }

    function test_emergencyWithdraw_revertsForUnauthorized(address _caller) public {
        vm.assume(_caller != management && _caller != emergencyAdmin);

        mintAndDepositIntoStrategy(strategy, user, 1e18);

        vm.prank(management);
        strategy.shutdownStrategy();

        vm.prank(_caller);
        vm.expectRevert("!emergency authorized");
        strategy.emergencyWithdraw(1e18);
    }

    function test_emergencyWithdraw_revertsIfNotShutdown() public {
        mintAndDepositIntoStrategy(strategy, user, 1e18);

        assertFalse(strategy.isShutdown(), "should not be shutdown");

        vm.prank(management);
        vm.expectRevert("not shutdown");
        strategy.emergencyWithdraw(1e18);
    }

    // ==================== Shutdown + Report with Loss ====================

    function test_shutdown_reportLoss_burningEnabled_accountingCorrect() public {
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon some shares
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Shutdown then simulate loss
        vm.prank(management);
        strategy.shutdownStrategy();

        uint256 loss = 15e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, loss, "loss mismatch");
        assertEq(strategy.totalAssets(), amount - loss, "total assets should reflect loss");
        // Burning should still work after shutdown
        assertLt(strategy.balanceOf(donationAddress), 20e18, "dragon shares should be partially burned");
    }

    // ==================== Shutdown + Full Withdrawal Flow ====================

    function test_shutdown_emergencyWithdraw_thenUserWithdraws(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Shutdown and emergency withdraw
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // Funds are now idle in the strategy contract
        assertEq(asset.balanceOf(address(strategy)), _amount, "funds should be idle in strategy");

        // User can still withdraw
        uint256 userShares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(userShares, user, user);

        assertEq(asset.balanceOf(user), _amount, "user should get full deposit back");
        assertEq(strategy.balanceOf(user), 0, "user should have 0 shares");
    }

    // ==================== Multiple Users Withdraw After Shutdown ====================

    function test_shutdown_multipleUsersWithdraw() public {
        address user2 = address(10);
        uint256 amount1 = 50e18;
        uint256 amount2 = 100e18;

        mintAndDepositIntoStrategy(strategy, user, amount1);
        mintAndDepositIntoStrategy(strategy, user2, amount2);

        vm.prank(management);
        strategy.shutdownStrategy();

        // Both users can withdraw
        uint256 user1Shares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(user1Shares, user, user);
        assertEq(asset.balanceOf(user), amount1, "user1 should get deposit back");

        uint256 user2Shares = strategy.balanceOf(user2);
        vm.prank(user2);
        strategy.redeem(user2Shares, user2, user2);
        assertEq(asset.balanceOf(user2), amount2, "user2 should get deposit back");
    }
}
