// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";

contract ShareTransferTest is Setup {
    address public user2 = address(10);

    function setUp() public override {
        super.setUp();
        vm.label(user2, "user2");
    }

    // ==================== Basic Transfer ====================

    function test_transfer_balancesUpdate(uint256 _amount, uint256 _transferAmount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _transferAmount = bound(_transferAmount, 1, _amount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user);
        bool success = strategy.transfer(user2, _transferAmount);

        assertTrue(success, "transfer should return true");
        assertEq(strategy.balanceOf(user), _amount - _transferAmount, "sender balance");
        assertEq(strategy.balanceOf(user2), _transferAmount, "receiver balance");
    }

    function test_transfer_fullBalance(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user);
        strategy.transfer(user2, _amount);

        assertEq(strategy.balanceOf(user), 0, "sender should have 0");
        assertEq(strategy.balanceOf(user2), _amount, "receiver should have full amount");
    }

    function test_transfer_moreThanBalance_reverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user);
        vm.expectRevert();
        strategy.transfer(user2, _amount + 1);
    }

    // ==================== Transfer to Dragon Router ====================

    function test_transfer_toDragonRouter_allowed(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user);
        strategy.transfer(donationAddress, _amount / 2);

        assertEq(strategy.balanceOf(donationAddress), _amount / 2, "dragon should receive shares");
    }

    function test_dragonRouter_transfersSharesOut(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Generate profit so dragon gets shares
        asset.mint(address(yieldSource), _amount / 10);
        vm.prank(keeper);
        strategy.report();

        uint256 dragonShares = strategy.balanceOf(donationAddress);
        assertGt(dragonShares, 0, "dragon should have shares");

        // Dragon transfers shares to user2
        vm.prank(donationAddress);
        strategy.transfer(user2, dragonShares);

        assertEq(strategy.balanceOf(donationAddress), 0, "dragon should have 0 after transfer");
        assertEq(strategy.balanceOf(user2), dragonShares, "user2 should receive dragon shares");
    }

    // ==================== TransferFrom with Approval ====================

    function test_transferFrom_withApproval(uint256 _amount, uint256 _transferAmount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _transferAmount = bound(_transferAmount, 1, _amount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // User approves user2
        vm.prank(user);
        strategy.approve(user2, _transferAmount);

        assertEq(strategy.allowance(user, user2), _transferAmount, "allowance should be set");

        // User2 transfers from user
        vm.prank(user2);
        bool success = strategy.transferFrom(user, user2, _transferAmount);

        assertTrue(success, "transferFrom should return true");
        assertEq(strategy.balanceOf(user), _amount - _transferAmount, "sender balance");
        assertEq(strategy.balanceOf(user2), _transferAmount, "receiver balance");
        assertEq(strategy.allowance(user, user2), 0, "allowance should be consumed");
    }

    function test_transferFrom_withoutApproval_reverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        strategy.transferFrom(user, user2, _amount);
    }

    function test_transferFrom_insufficientAllowance_reverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Approve less than transfer amount
        vm.prank(user);
        strategy.approve(user2, _amount / 2);

        vm.prank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        strategy.transferFrom(user, user2, _amount);
    }

    // ==================== Approve ====================

    function test_approve_setsAllowance(uint256 _amount) public {
        _amount = bound(_amount, 1, type(uint256).max);

        vm.prank(user);
        bool success = strategy.approve(user2, _amount);

        assertTrue(success, "approve should return true");
        assertEq(strategy.allowance(user, user2), _amount, "allowance should match");
    }

    function test_approve_infiniteAllowance_notConsumed(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Set infinite approval
        vm.prank(user);
        strategy.approve(user2, type(uint256).max);

        // Transfer some
        vm.prank(user2);
        strategy.transferFrom(user, user2, _amount / 2);

        // Allowance should still be max
        assertEq(strategy.allowance(user, user2), type(uint256).max, "infinite allowance should not decrease");
    }

    function test_approve_overwrite(uint256 _first, uint256 _second) public {
        _first = bound(_first, 1, type(uint256).max);
        _second = bound(_second, 0, type(uint256).max);
        vm.assume(_first != _second);

        vm.prank(user);
        strategy.approve(user2, _first);
        assertEq(strategy.allowance(user, user2), _first, "first allowance");

        vm.prank(user);
        strategy.approve(user2, _second);
        assertEq(strategy.allowance(user, user2), _second, "second allowance should overwrite");
    }

    // ==================== Transfer Edge Cases ====================

    function test_transfer_toZeroAddress_reverts() public {
        mintAndDepositIntoStrategy(strategy, user, 1e18);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer to the zero address");
        strategy.transfer(address(0), 1e18);
    }

    function test_transfer_toStrategyAddress_reverts() public {
        mintAndDepositIntoStrategy(strategy, user, 1e18);

        vm.prank(user);
        vm.expectRevert("ERC20 transfer to strategy");
        strategy.transfer(address(strategy), 1e18);
    }

    function test_transfer_zeroAmount(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(user);
        strategy.transfer(user2, 0);

        assertEq(strategy.balanceOf(user), _amount, "sender balance unchanged");
        assertEq(strategy.balanceOf(user2), 0, "receiver balance still 0");
    }

    // ==================== Allowance Consumed Correctly ====================

    function test_allowance_consumedCorrectly_multipleTransfers() public {
        uint256 amount = 100e18;
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Approve 60 tokens
        vm.prank(user);
        strategy.approve(user2, 60e18);

        // First transfer: 30
        vm.prank(user2);
        strategy.transferFrom(user, user2, 30e18);
        assertEq(strategy.allowance(user, user2), 30e18, "remaining allowance");

        // Second transfer: 30
        vm.prank(user2);
        strategy.transferFrom(user, user2, 30e18);
        assertEq(strategy.allowance(user, user2), 0, "allowance should be 0");

        // Third transfer should revert: no remaining allowance
        vm.prank(user2);
        vm.expectRevert("ERC20: insufficient allowance");
        strategy.transferFrom(user, user2, 1);
    }

    // ==================== Transfer After Report ====================

    function test_transfer_afterReport_sharesStillWorkCorrectly(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Report profit
        asset.mint(address(yieldSource), _amount / 10);
        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        // Transfer shares to user2
        uint256 transferAmount = strategy.balanceOf(user) / 2;
        vm.prank(user);
        strategy.transfer(user2, transferAmount);

        // Both should be able to redeem
        uint256 user1Shares = strategy.balanceOf(user);
        uint256 user2Shares = strategy.balanceOf(user2);
        uint256 user1Assets = strategy.convertToAssets(user1Shares);
        uint256 user2Assets = strategy.convertToAssets(user2Shares);

        vm.prank(user);
        strategy.redeem(user1Shares, user, user);
        assertEq(asset.balanceOf(user), user1Assets, "user1 redemption");

        vm.prank(user2);
        strategy.redeem(user2Shares, user2, user2);
        assertEq(asset.balanceOf(user2), user2Assets, "user2 redemption");
    }
}
