// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import "forge-std/console.sol";
import { Setup, IMockStrategy } from "./Setup.sol";
import { TokenizedStrategy__TooMuchLoss, ZeroShares, ZeroAssets } from "src/errors.sol";

contract AccountingTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_airdropDoesNotIncreasePPS(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // set fees to 0 for calculations simplicity

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);

        // PPS shouldn't change but the balance does.
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount - toAirdrop, toAirdrop, _amount);

        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out just the deposited amount leaving the rest deployed.
        assertEq(asset.balanceOf(user), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_airdropDoesNotIncreasePPS_reportRecordsIt(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // set fees to 0 for calculations simplicity

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);

        // PPS shouldn't change but the balance does.
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount - toAirdrop, toAirdrop, _amount);

        // process a report to realize the gain from the airdrop
        uint256 profit;
        vm.prank(keeper);
        (profit, ) = strategy.report();

        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(profit, toAirdrop);
        checkStrategyTotals(strategy, _amount + toAirdrop, _amount + toAirdrop, 0, _amount + toAirdrop);

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        assertEq(strategy.pricePerShare(), wad);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(strategy), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare);

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // we should not get a return at all since price per share should stay constant because we donate all the profits
        assertRelApproxEq(strategy.pricePerShare(), wad, MAX_BPS);

        // Total is the same but balance has adjusted again
        checkStrategyTotals(strategy, _amount + toAirdrop, _amount, toAirdrop);
        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out the deposit and have donated everything else
        assertEq(asset.balanceOf(user), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop * 2);
        // Everything left in the vault is owned by the dragon router
        // get dragon router shares
        uint256 dragonRouterShares = strategy.balanceOf(address(mockDragonRouter));
        assertEq(dragonRouterShares, strategy.convertToShares(toAirdrop));
        checkStrategyTotals(strategy, toAirdrop, toAirdrop, 0, dragonRouterShares);
    }

    function test_earningYieldDoesNotIncreasePPS(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // set fees to 0 for calculations simplicity

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount, 0, _amount);

        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out just the deposit amount
        assertEq(asset.balanceOf(user), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_earningYieldDoesNotIncreasePPS_reportRecordsIt(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // set fees to 0 for calculations simplicity

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = 0.1 ether;
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(asset.balanceOf(address(yieldSource)), _amount + toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount, 0, _amount);

        // process a report to realize the gain from the airdrop
        uint256 profit;
        vm.prank(keeper);
        (profit, ) = strategy.report();

        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(profit, toAirdrop);

        checkStrategyTotals(strategy, _amount + toAirdrop, _amount + toAirdrop, 0, _amount + toAirdrop);

        // it doesn't matter how long we wait since profit locking is turned off
        skip(profitMaxUnlockTime / 2);

        // even if profit locking was turned on we donate all of the profits so the price per share should stay the same
        assertEq(strategy.pricePerShare(), pricePerShare);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare);

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // we should not get a return at all since price per share should stay constant because we donate all the profits
        assertRelApproxEq(strategy.pricePerShare(), wad, MAX_BPS);

        // Total is the same.
        checkStrategyTotals(strategy, _amount + toAirdrop, _amount + toAirdrop, 0);

        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out the principal without touching the profit that was reported but not the either airdrop
        assertEq(asset.balanceOf(user), beforeBalance + _amount);

        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop * 2);
        uint256 dragonRouterShares = strategy.balanceOf(address(mockDragonRouter));
        assertEq(dragonRouterShares, strategy.convertToShares(toAirdrop));
        checkStrategyTotals(strategy, toAirdrop, toAirdrop, 0, dragonRouterShares);
        // calling report again should assign profit to the dragon router
        vm.prank(keeper);
        (profit, ) = strategy.report();
        dragonRouterShares = strategy.balanceOf(address(mockDragonRouter));
        assertEq(dragonRouterShares, strategy.convertToShares(toAirdrop * 2));

        checkStrategyTotals(strategy, toAirdrop * 2, toAirdrop * 2, 0, dragonRouterShares);
    }

    function test_tend_noIdle_harvestProfit(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 1, MAX_BPS));

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy to simulate a harvesting of rewards
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);
        assertEq(asset.balanceOf(address(strategy)), toAirdrop);
        checkStrategyTotals(strategy, _amount, _amount - toAirdrop, toAirdrop);

        vm.prank(keeper);
        strategy.tend();

        // Should have deposited the toAirdrop amount but no other changes
        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertEq(asset.balanceOf(address(yieldSource)), _amount + toAirdrop, "!yieldSource");
        assertEq(strategy.pricePerShare(), wad, "!pps");

        // Make sure we now report the profit correctly
        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        assertRelApproxEq(strategy.pricePerShare(), wad, MAX_BPS);
        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out the deposit principal but not any of the profit
        assertEq(asset.balanceOf(user), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
        uint256 dragonRouterShares = strategy.balanceOf(address(mockDragonRouter));
        assertEq(dragonRouterShares, strategy.convertToShares(toAirdrop));

        checkStrategyTotals(strategy, toAirdrop, toAirdrop, 0, dragonRouterShares);
    }

    function test_withdrawWithUnrealizedLoss_reverts(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.expectRevert(TokenizedStrategy__TooMuchLoss.selector);
        vm.prank(user);
        strategy.withdraw(_amount, user, user);
    }

    function test_withdrawWithUnrealizedLoss_withMaxLoss(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(user);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(user);
        strategy.withdraw(_amount, user, user, _lossFactor);

        uint256 afterBalance = asset.balanceOf(user);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(user);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        uint256 afterBalance = asset.balanceOf(user);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss_allowNoLoss_reverts(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.expectRevert(TokenizedStrategy__TooMuchLoss.selector);
        vm.prank(user);
        strategy.redeem(_amount, user, user, 0);
    }

    function test_redeemWithUnrealizedLoss_customMaxLoss(uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(user);
        uint256 expectedOut = _amount - toLose;

        // First set it to just under the expected loss.
        vm.expectRevert(TokenizedStrategy__TooMuchLoss.selector);
        vm.prank(user);
        strategy.redeem(_amount, user, user, _lossFactor - 1);

        // Now redeem with the correct loss.
        vm.prank(user);
        strategy.redeem(_amount, user, user, _lossFactor);

        uint256 afterBalance = asset.balanceOf(user);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_maxUintDeposit_depositsBalance(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        asset.mint(user, _amount);

        vm.prank(user);
        asset.approve(address(strategy), _amount);

        assertEq(asset.balanceOf(user), _amount);

        vm.prank(user);
        strategy.deposit(type(uint256).max, user);

        // Should just deposit the available amount.
        checkStrategyTotals(strategy, _amount, _amount, 0, _amount);

        assertEq(asset.balanceOf(user), 0);
        assertEq(strategy.balanceOf(user), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);

        assertEq(asset.balanceOf(address(yieldSource)), _amount);
    }

    function test_deposit_zeroAssetsPositiveSupply_reverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = _amount;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.prank(keeper);
        strategy.report();

        // Should still have shares but no assets
        checkStrategyTotals(strategy, 0, 0, 0, _amount);

        assertEq(strategy.balanceOf(user), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(yieldSource)), 0);

        asset.mint(user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert(ZeroShares.selector);
        vm.prank(user);
        strategy.deposit(_amount, user);

        assertEq(strategy.convertToAssets(_amount), 0);
        assertEq(strategy.convertToShares(_amount), 0);
        assertEq(strategy.pricePerShare(), 0);
    }

    function test_mint_zeroAssetsPositiveSupply_reverts(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 toLose = _amount;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.prank(keeper);
        strategy.report();

        // Should still have shares but no assets
        checkStrategyTotals(strategy, 0, 0, 0, _amount);

        assertEq(strategy.balanceOf(user), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(yieldSource)), 0);

        asset.mint(user, _amount);
        vm.prank(user);
        asset.approve(address(strategy), _amount);

        vm.expectRevert(ZeroAssets.selector);
        vm.prank(user);
        strategy.mint(_amount, user);

        assertEq(strategy.convertToAssets(_amount), 0);
        assertEq(strategy.convertToShares(_amount), 0);
        assertEq(strategy.pricePerShare(), 0);
    }
}
