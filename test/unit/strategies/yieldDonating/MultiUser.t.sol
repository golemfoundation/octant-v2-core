// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract MultiUserTest is Setup {
    address public user2 = address(10);
    address public user3 = address(11);

    function setUp() public override {
        super.setUp();
        vm.label(user2, "user2");
        vm.label(user3, "user3");
    }

    // ==================== Multiple Depositors, One Report ====================

    function test_multipleDepositors_samePrice_dragonGetsProfit(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 2);

        // Two users deposit equal amounts
        mintAndDepositIntoStrategy(strategy, user, _amount);
        mintAndDepositIntoStrategy(strategy, user2, _amount);

        assertEq(strategy.balanceOf(user), _amount, "user1 shares");
        assertEq(strategy.balanceOf(user2), _amount, "user2 shares");
        assertEq(strategy.pricePerShare(), wad, "PPS should be 1:1");

        // Generate profit
        uint256 profit = _amount / 5;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        (uint256 reportedProfit, ) = strategy.report();

        assertEq(reportedProfit, profit, "profit mismatch");
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon should have shares");
        // PPS stays 1:1 since profit shares go to dragon
        assertEq(strategy.pricePerShare(), wad, "PPS should remain 1:1");
    }

    // ==================== Deposit Before and After Report ====================

    function test_depositBeforeAndAfterReport_correctSharePricing(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount / 3);

        // User1 deposits before report
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Generate profit and report
        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);
        vm.prank(keeper);
        strategy.report();

        // PPS should still be 1:1
        uint256 ppsAfterReport = strategy.pricePerShare();
        assertEq(ppsAfterReport, wad, "PPS should be 1:1 after report");

        // User2 deposits after report
        mintAndDepositIntoStrategy(strategy, user2, _amount);

        // User2 should get shares at the same 1:1 rate
        assertEq(strategy.balanceOf(user2), _amount, "user2 should get 1:1 shares");
        assertEq(strategy.pricePerShare(), wad, "PPS should still be 1:1");
    }

    // ==================== Withdraw After Dragon Shares Minted ====================

    function test_withdrawAfterDragonMinted_getsOriginalDeposit(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Generate profit
        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        // User redeems all shares
        uint256 userShares = strategy.balanceOf(user);
        uint256 balBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(userShares, user, user);

        // User gets back their original deposit (not the profit)
        assertEq(asset.balanceOf(user) - balBefore, _amount, "user should get original deposit back");
    }

    // ==================== Dragon Router Redeems Shares ====================

    function test_dragonRouterRedeems_receivesCorrectAssets(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Generate profit
        uint256 profit = _amount / 10;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        uint256 dragonShares = strategy.balanceOf(donationAddress);
        assertGt(dragonShares, 0, "dragon should have shares");

        uint256 expectedAssets = strategy.convertToAssets(dragonShares);

        vm.prank(donationAddress);
        strategy.redeem(dragonShares, donationAddress, donationAddress);

        assertEq(asset.balanceOf(donationAddress), expectedAssets, "dragon should receive correct assets");
        assertEq(strategy.balanceOf(donationAddress), 0, "dragon should have 0 shares after redeem");
    }

    // ==================== Loss With Burning: Both Users Affected Equally ====================

    function test_twoUsers_lossWithBurning_equallyAffected() public {
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        uint256 amount = 50e18;

        mintAndDepositIntoStrategy(strategy, user, amount);
        mintAndDepositIntoStrategy(strategy, user2, amount);

        vm.prank(keeper);
        strategy.report();

        // Give dragon some shares via transfer from user
        vm.prank(user);
        strategy.transfer(donationAddress, 10e18);

        // Loss of 20e18; dragon has 10 shares that get burned, leaving 10 residual loss
        uint256 loss = 20e18;
        yieldSource.simulateLoss(loss);

        vm.prank(keeper);
        strategy.report();

        // Both users' value should be reduced proportionally by the residual loss
        // After burning 10 dragon shares: totalAssets = 80, totalSupply = 90 (100 - 10 burned)
        // user has 40 shares, user2 has 50 shares
        uint256 user1Value = strategy.convertToAssets(strategy.balanceOf(user));
        uint256 user2Value = strategy.convertToAssets(strategy.balanceOf(user2));

        // user2 deposited more and didn't transfer any, so should have proportionally more value
        assertGt(user2Value, user1Value, "user2 should have more value (more shares)");

        // Both should be below their initial deposits
        assertLt(user1Value, amount, "user1 value should be below deposit");
        assertLt(user2Value, amount, "user2 value should be below deposit");
    }

    // ==================== Large Depositor + Small Depositor ====================

    function test_largeAndSmallDepositor_proportionalTreatment() public {
        uint256 smallAmount = 1e18;
        uint256 largeAmount = 1000e18;

        mintAndDepositIntoStrategy(strategy, user, smallAmount);
        mintAndDepositIntoStrategy(strategy, user2, largeAmount);

        // Generate profit
        uint256 profit = 100e18;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        // PPS is still 1:1 so both get back what they deposited
        uint256 user1Shares = strategy.balanceOf(user);
        uint256 user2Shares = strategy.balanceOf(user2);

        assertEq(user1Shares, smallAmount, "small depositor shares");
        assertEq(user2Shares, largeAmount, "large depositor shares");

        // Both can redeem for their original amount
        vm.prank(user);
        strategy.redeem(user1Shares, user, user);
        assertEq(asset.balanceOf(user), smallAmount, "small depositor gets deposit back");

        vm.prank(user2);
        strategy.redeem(user2Shares, user2, user2);
        assertEq(asset.balanceOf(user2), largeAmount, "large depositor gets deposit back");
    }

    // ==================== Multiple Users + Multiple Reports ====================

    function test_multipleUsers_multipleReports() public {
        uint256 amount = 100e18;

        // User1 deposits
        mintAndDepositIntoStrategy(strategy, user, amount);

        // First report with profit
        asset.mint(address(yieldSource), 10e18);
        vm.prank(keeper);
        strategy.report();

        // User2 deposits after first report
        mintAndDepositIntoStrategy(strategy, user2, amount);

        // Second report with profit
        asset.mint(address(yieldSource), 20e18);
        vm.prank(keeper);
        strategy.report();

        // User3 deposits after second report
        mintAndDepositIntoStrategy(strategy, user3, amount);

        // All users should have the same PPS since yield donating keeps PPS at 1:1
        assertEq(strategy.balanceOf(user), amount, "user1 shares");
        assertEq(strategy.balanceOf(user2), amount, "user2 shares");
        assertEq(strategy.balanceOf(user3), amount, "user3 shares");
        assertEq(strategy.pricePerShare(), wad, "PPS should be 1:1");

        // Dragon router should have accumulated profit shares from both reports
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon should have profit shares");
    }

    // ==================== Fuzz: Multi-User Deposit and Withdraw ====================

    function testFuzz_multiUser_depositAndWithdraw(uint256 _amount1, uint256 _amount2) public {
        _amount1 = bound(_amount1, minFuzzAmount, maxFuzzAmount / 2);
        _amount2 = bound(_amount2, minFuzzAmount, maxFuzzAmount / 2);

        mintAndDepositIntoStrategy(strategy, user, _amount1);
        mintAndDepositIntoStrategy(strategy, user2, _amount2);

        // Generate profit and report
        uint256 profit = (_amount1 + _amount2) / 10;
        asset.mint(address(yieldSource), profit);

        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        // Both users withdraw via withdraw() instead of redeem() to avoid large-share edge cases
        uint256 user1Shares = strategy.balanceOf(user);
        uint256 user1Assets = strategy.convertToAssets(user1Shares);

        vm.prank(user);
        strategy.withdraw(user1Assets, user, user);
        assertEq(asset.balanceOf(user), _amount1, "user1 should get back deposit");

        uint256 user2Shares = strategy.balanceOf(user2);
        uint256 user2Assets = strategy.convertToAssets(user2Shares);

        vm.prank(user2);
        strategy.withdraw(user2Assets, user2, user2);
        assertEq(asset.balanceOf(user2), _amount2, "user2 should get back deposit");

        // Dragon gets the profit
        uint256 dragonShares = strategy.balanceOf(donationAddress);
        if (dragonShares > 0) {
            uint256 dragonAssets = strategy.convertToAssets(dragonShares);
            vm.prank(donationAddress);
            strategy.withdraw(dragonAssets, donationAddress, donationAddress);
            assertGt(asset.balanceOf(donationAddress), 0, "dragon should receive assets");
        }
    }
}
