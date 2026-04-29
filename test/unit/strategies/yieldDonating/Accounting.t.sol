// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { console } from "forge-std/console.sol";
import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { IBaseStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract AccountingTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_airdropDoesNotIncreasePPS(address _address, uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, _address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);

        // PPS shouldn't change but the balance does.
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount - toAirdrop, toAirdrop, _amount);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out just the deposited amount leaving the rest deployed.
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_airdropDoesNotIncreasePPS_reportRecordsIt(
        address _address,
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != donationAddress
        );

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, _address, _amount);

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

        // PPS should not increase price per share after report - different behavior from original strategy
        assertEq(strategy.pricePerShare(), pricePerShare);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(strategy), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare, "!pps");

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // Total is the same but balance has adjusted again
        checkStrategyTotals(strategy, _amount + toAirdrop, _amount, toAirdrop);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares
        assertGt(donationShares, 0, "!donationShares is zero");
        vm.startPrank(address(donationAddress));
        strategy.redeem(donationShares, donationAddress, donationAddress);
        vm.stopPrank();

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        // assert donation address has the airdrop
        assertEq(asset.balanceOf(donationAddress), toAirdrop, "!donationAddress");
        assertEq(asset.balanceOf(address(strategy)), 0, "!strategy");

        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_earningYieldDoesNotIncreasePPS(address _address, uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the strategy
        mintAndDepositIntoStrategy(strategy, _address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        checkStrategyTotals(strategy, _amount, _amount, 0, _amount);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out just the deposit amount
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_earningYieldDoesNotIncreasePPS_reportRecordsIt(
        address _address,
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        vm.assume(
            _address != address(0) &&
                _address != address(strategy) &&
                _address != address(yieldSource) &&
                _address != donationAddress
        );

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, _address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // airdrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(asset.balanceOf(address(yieldSource)), _amount + toAirdrop, "!yieldSource");

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

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        // PPS should not increase price per share after report - different behavior from original strategy
        assertEq(strategy.pricePerShare(), pricePerShare);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare);

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // Total is the same.
        checkStrategyTotals(strategy, _amount + toAirdrop, _amount + toAirdrop, 0);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.startPrank(_address);
        uint256 _addressShares = strategy.balanceOf(_address);
        strategy.redeem(_addressShares, _address, _address);
        vm.stopPrank();

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares
        assertGt(donationShares, 0, "!donationShares is zero");
        vm.startPrank(address(donationAddress));
        strategy.redeem(donationShares, donationAddress, donationAddress);
        vm.stopPrank();

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        // assert donation address has the airdrop
        assertEq(asset.balanceOf(donationAddress), toAirdrop, "!donationAddress");
        assertEq(asset.balanceOf(address(strategy)), 0, "!strategy");

        checkStrategyTotals(strategy, 0, 0, 0, 0);
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

        // price per share should be the same
        assertEq(strategy.pricePerShare(), pricePerShare);

        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares
        assertGt(donationShares, 0, "!donationShares is zero");
        vm.startPrank(address(donationAddress));
        strategy.redeem(donationShares, donationAddress, donationAddress);
        vm.stopPrank();

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(asset.balanceOf(user), beforeBalance + _amount);
        // assert donation address has the airdrop
        assertEq(asset.balanceOf(donationAddress), toAirdrop, "!donationAddress");
        assertEq(asset.balanceOf(address(strategy)), 0, "!strategy");
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_tend_idleFunds_harvestProfit(uint256 _amount, uint16 _profitFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 1, MAX_BPS));

        // Use the illiquid mock strategy so it doesn't deposit all funds
        strategy = IMockStrategy(setUpIlliquidStrategy());

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 expectedDeposit = _amount / 2;
        checkStrategyTotals(strategy, _amount, expectedDeposit, _amount - expectedDeposit, _amount);

        assertEq(asset.balanceOf(address(yieldSource)), expectedDeposit, "!yieldSource");
        // should still be 1
        assertEq(strategy.pricePerShare(), wad);

        // airdrop to strategy to simulate a harvesting of rewards
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);
        assertEq(asset.balanceOf(address(strategy)), _amount - expectedDeposit + toAirdrop);

        vm.prank(keeper);
        strategy.tend();

        // Should have withdrawn all the funds from the yield source
        checkStrategyTotals(strategy, _amount, 0, _amount, _amount);
        assertEq(asset.balanceOf(address(yieldSource)), 0, "!yieldSource");
        assertEq(asset.balanceOf(address(strategy)), _amount + toAirdrop);
        assertEq(strategy.pricePerShare(), wad, "!pps");

        // Make sure we now report the profit correctly
        vm.prank(keeper);
        strategy.report();

        checkStrategyTotals(
            strategy,
            _amount + toAirdrop,
            (_amount + toAirdrop) / 2,
            (_amount + toAirdrop) - ((_amount + toAirdrop) / 2)
        );
        assertEq(asset.balanceOf(address(yieldSource)), (_amount + toAirdrop) / 2);

        skip(profitMaxUnlockTime);

        // price per share should be the same
        assertEq(strategy.pricePerShare(), pricePerShare);

        // withdaw donation address shares
        uint256 donationShares = strategy.balanceOf(donationAddress);
        // check donation address has shares
        assertGt(donationShares, 0, "!donationShares is zero");
    }

    function test_withdrawWithUnrealizedLoss_reverts(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.withdraw(_amount, _address, _address);
    }

    function test_withdrawWithUnrealizedLoss_withMaxLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(_address);
        strategy.withdraw(_amount, _address, _address, _lossFactor);

        uint256 afterBalance = asset.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        uint256 afterBalance = asset.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_redeemWithUnrealizedLoss_allowNoLoss_reverts(
        address _address,
        uint256 _amount,
        uint16 _lossFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, 0);
    }

    function test_redeemWithUnrealizedLoss_customMaxLoss(address _address, uint256 _amount, uint16 _lossFactor) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = uint16(bound(uint256(_lossFactor), 10, MAX_BPS));
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        mintAndDepositIntoStrategy(strategy, _address, _amount);

        uint256 toLose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLose);

        uint256 beforeBalance = asset.balanceOf(_address);
        uint256 expectedOut = _amount - toLose;

        // First set it to just under the expected loss.
        vm.expectRevert("too much loss");
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, _lossFactor - 1);

        // Now redeem with the correct loss.
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address, _lossFactor);

        uint256 afterBalance = asset.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.pricePerShare(), wad);
        checkStrategyTotals(strategy, 0, 0, 0, 0);
    }

    function test_maxUintDeposit_depositsBalance(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(0) && _address != address(strategy) && _address != address(yieldSource));

        asset.mint(_address, _amount);

        vm.prank(_address);
        asset.approve(address(strategy), _amount);

        assertEq(asset.balanceOf(_address), _amount);

        vm.prank(_address);
        strategy.deposit(type(uint256).max, _address);

        // Should just deposit the available amount.
        checkStrategyTotals(strategy, _amount, _amount, 0, _amount);

        assertEq(asset.balanceOf(_address), 0);
        assertEq(strategy.balanceOf(_address), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);

        assertEq(asset.balanceOf(address(yieldSource)), _amount);
    }

    // ===== BURN CONVERSION TESTS =====

    /**
     * @notice Test burn conversion accounting fix for dragon loss protection
     * @dev Verifies that asset value is calculated before burning shares to prevent inflated loss coverage
     */
    function test_burnConversion_correctAccounting() public {
        // Enable burning for this test
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        // Setup: totalShares == totalAssets == 100, dragon has 20 shares, loss = 25
        mintAndDepositIntoStrategy(strategy, user, 100e18);
        vm.prank(keeper);
        strategy.report();

        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Simulate 25 token loss
        yieldSource.simulateLoss(25e18);

        // Calculate what 20 shares are worth BEFORE burning (this is what the fix does)
        uint256 shareValueBeforeBurn = strategy.convertToAssets(20e18);
        assertEq(shareValueBeforeBurn, 20e18, "20 shares should be worth 20 assets before burn");

        // Report the loss (triggers the fixed _handleDragonLossProtection)
        vm.prank(keeper);
        (, uint256 reportedLoss) = strategy.report();

        assertEq(reportedLoss, 25e18, "Should report full 25 token loss");

        // VERIFICATION: Fix ensures correct accounting
        // 1. All dragon shares burned
        assertEq(strategy.balanceOf(donationAddress), 0, "All dragon shares should be burned");

        // 2. Shares reduced by burned amount only
        assertEq(strategy.totalSupply(), 80e18, "Should have 80 shares (100 - 20 burned)");

        // 3. Assets reduced by full loss amount
        assertEq(strategy.totalAssets(), 75e18, "Should have 75 assets (100 - 25 loss)");

        // 4. User gets fair share of remaining assets
        uint256 userShares = strategy.balanceOf(user);
        uint256 userAssetValue = strategy.convertToAssets(userShares);
        assertEq(userAssetValue, 75e18, "User should get fair share of 75 remaining assets");
    }

    /**
     * @notice Test burn conversion across different scenarios
     */
    function test_burnConversion_variousScenarios() public {
        // Enable burning
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        // Scenario 1: Loss fully covered by dragon shares
        mintAndDepositIntoStrategy(strategy, user, 100e18);
        vm.prank(keeper);
        strategy.report();

        vm.prank(user);
        strategy.transfer(donationAddress, 30e18);

        yieldSource.simulateLoss(20e18);
        vm.prank(keeper);
        strategy.report();

        // Should only burn 20 shares to cover 20 token loss
        assertEq(strategy.balanceOf(donationAddress), 10e18, "10 dragon shares should remain");
        assertEq(strategy.totalSupply(), 80e18, "Should have 80 total shares (100 - 20 burned)");
        assertEq(strategy.totalAssets(), 80e18, "Should have 80 total assets (100 - 20 loss)");

        // Scenario 2: Minimal dragon shares, large loss
        vm.startPrank(user);
        strategy.transfer(donationAddress, 9e18); // Dragon router now has 19 total shares
        vm.stopPrank();

        yieldSource.simulateLoss(50e18);
        vm.prank(keeper);
        strategy.report();

        // Should burn all 19 dragon shares, covering 19 tokens
        assertEq(strategy.balanceOf(donationAddress), 0, "All dragon shares should be burned");
        assertEq(strategy.totalSupply(), 61e18, "Should have 61 total shares (80 - 19)");
        assertEq(strategy.totalAssets(), 30e18, "Should have 30 total assets (80 - 50)");
    }

    /**
     * @notice Test burn conversion with burning disabled
     */
    function test_burnConversion_burningDisabled() public {
        // Disable burning
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);

        mintAndDepositIntoStrategy(strategy, user, 100e18);
        vm.prank(keeper);
        strategy.report();

        // Transfer shares to dragon
        vm.prank(user);
        strategy.transfer(donationAddress, 30e18);

        // Simulate loss
        yieldSource.simulateLoss(25e18);

        uint256 dragonBalanceBefore = strategy.balanceOf(donationAddress);

        // Report the loss
        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertEq(loss, 25e18, "Should report 25 token loss");

        // Verify no shares were burned
        assertEq(
            strategy.balanceOf(donationAddress),
            dragonBalanceBefore,
            "Dragon balance should remain unchanged when burning disabled"
        );

        // Verify assets reduced but shares unchanged
        assertEq(strategy.totalAssets(), 75e18, "Total assets should be 75 after loss");
        assertEq(strategy.totalSupply(), 100e18, "Total shares should remain 100");
    }

    /**
     * @notice Regression: Floor rounding must be used when PPS != 1
     * @dev At PPS=1, Ceil and Floor produce the same result, masking the bug.
     *      This test creates PPS < 1 via an unbacked loss with burning disabled,
     *      then verifies a subsequent loss with burning enabled uses Floor rounding.
     */
    function test_burnConversion_floorRoundingAtNonUnityPPS() public {
        // Step 1: Deposit and create profit so dragon gets shares via report
        mintAndDepositIntoStrategy(strategy, user, 100e18);
        asset.mint(address(yieldSource), 50e18); // 50 profit in yield source
        vm.prank(keeper);
        strategy.report(); // dragon gets ~50 shares from profit donation

        // totalAssets = 150, totalSupply = 150 (100 user + 50 dragon), PPS = 1
        uint256 dragonShares = strategy.balanceOf(donationAddress);
        assertGt(dragonShares, 0, "Dragon should have shares from profit donation");

        // Step 2: Create unbacked loss with burning DISABLED to push PPS < 1
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(false);

        yieldSource.simulateLoss(30e18); // lose 30 assets
        vm.prank(keeper);
        strategy.report(); // PPS drops, no shares burned

        // totalAssets = 120, totalSupply = 150, PPS = 120/150 = 0.8
        uint256 totalAssets = strategy.totalAssets();
        uint256 totalSupply = strategy.totalSupply();
        assertEq(totalAssets, 120e18, "Should have 120 assets after 30 loss");
        assertEq(totalSupply, 150e18, "Supply unchanged when burning disabled");

        // Step 3: Enable burning and trigger a small loss with non-zero remainder
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        // With totalSupply = 150e18 and totalAssets = 120e18, a loss of 7e18 gives:
        //   loss * totalSupply / totalAssets = 7 * 150 / 120 = 1050 / 120 = 8.75
        // At 1e18 precision this is exactly 8.75e18, so (7e18 * 150e18) % 120e18 == 0 (no remainder).
        // For this test we specifically need a non-zero remainder:
        //   (loss * totalSupply) % totalAssets != 0
        // to exercise the floor-vs-ceil behavior when converting loss to shares.
        //
        // Taking loss = 7e18 + 1 breaks exact divisibility:
        //   (7e18 + 1) * 150e18 % 120e18 != 0
        // so the integer division loss * totalSupply / totalAssets has a truncated fractional part.
        uint256 loss = 7e18 + 1;
        yieldSource.simulateLoss(loss);

        uint256 dragonSharesBefore = strategy.balanceOf(donationAddress);

        // Compute expected floor shares: loss * totalSupply / totalAssets (integer division = floor)
        uint256 floorShares = (loss * totalSupply) / totalAssets;
        uint256 ceilShares = floorShares + 1; // ceil adds 1 when remainder != 0

        // Verify our test parameters actually produce a remainder
        assertGt((loss * totalSupply) % totalAssets, 0, "Test setup: must have non-zero remainder");
        assertGt(ceilShares, floorShares, "Test setup: ceil must differ from floor");

        vm.prank(keeper);
        strategy.report();

        uint256 dragonSharesAfter = strategy.balanceOf(donationAddress);
        uint256 actualBurned = dragonSharesBefore - dragonSharesAfter;

        // The fix: Floor rounding means we burn floorShares, not ceilShares
        assertEq(actualBurned, floorShares, "Should burn floor(shares), not ceil");
        assertTrue(actualBurned < ceilShares, "Must not over-burn by rounding up");
    }

    /**
     * @notice Test conversion rate consistency during burn operations
     */
    function test_burnConversion_rateConsistency() public {
        // Enable burning
        vm.prank(management);
        YieldDonatingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        mintAndDepositIntoStrategy(strategy, user, 100e18);
        vm.prank(keeper);
        strategy.report();

        // Transfer 20 shares to dragon
        vm.prank(user);
        strategy.transfer(donationAddress, 20e18);

        // Calculate value of 20 shares BEFORE any loss/burn
        uint256 shareValue = strategy.convertToAssets(20e18);
        assertEq(shareValue, 20e18, "20 shares should be worth 20 assets at 1:1");

        // Simulate loss and report
        yieldSource.simulateLoss(25e18);
        vm.prank(keeper);
        strategy.report();

        // After the fix, the 20 burned shares should have covered exactly 20 assets of loss
        assertEq(strategy.totalAssets(), 75e18, "Should have 75 assets (100 - 25 loss)");
        assertEq(strategy.totalSupply(), 80e18, "Should have 80 shares (100 - 20 burned)");
    }
}
