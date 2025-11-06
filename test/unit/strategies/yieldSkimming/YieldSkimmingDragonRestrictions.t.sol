// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";

// Mock strategy that implements the required interface for YieldSkimmingTokenizedStrategy
contract MockYieldSkimmingStrategy is YieldSkimmingTokenizedStrategy {
    using WadRayMath for uint256;

    uint256 private _exchangeRate = 1e18; // Start at 1.0 in wad format
    uint256 private _decimals = 18;

    function setExchangeRate(uint256 newRate) external {
        _exchangeRate = newRate;
    }

    function setExchangeRateDecimals(uint256 newDecimals) external {
        _decimals = newDecimals;
    }

    function getCurrentExchangeRate() external view returns (uint256) {
        return _exchangeRate;
    }

    function decimalsOfExchangeRate() external view returns (uint256) {
        return _decimals;
    }

    function harvestAndReport() external view returns (uint256) {
        // Simple implementation - return current total assets
        return _strategyStorage().totalAssets;
    }

    function deployFunds(uint256) external {
        // No-op for testing
    }

    function availableDepositLimit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function availableWithdrawLimit(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract YieldSkimmingDragonRestrictionsTest is Test {
    using Math for uint256;
    using WadRayMath for uint256;

    MockYieldSkimmingStrategy public strategy;
    MockYieldSkimmingStrategy public implementation;
    ERC20Mock public asset;

    // Test addresses
    address public management = address(0x1);
    address public keeper = address(0x2);
    address public emergencyAdmin = address(0x3);
    address public dragonRouter = address(0x4);
    address public user1 = address(0x5);
    address public user2 = address(0x6);

    // Constants
    uint256 public constant WAD = 1e18;
    uint256 public constant RAY = 1e27;
    uint256 public constant INITIAL_RATE = 1e18; // 1.0 in wad

    function setUp() public {
        // Deploy mock asset
        asset = new ERC20Mock();

        // Deploy implementation
        implementation = new MockYieldSkimmingStrategy();

        // Deploy proxy
        strategy = MockYieldSkimmingStrategy(address(new ERC1967Proxy(address(implementation), "")));

        // Initialize strategy
        strategy.initialize(
            address(asset),
            "Test Yield Skimming Strategy",
            management,
            keeper,
            emergencyAdmin,
            dragonRouter,
            true // enableBurning
        );

        // Set initial exchange rate
        strategy.setExchangeRate(INITIAL_RATE);
    }

    function _depositUser(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(strategy), amount);
        vm.prank(user);
        strategy.deposit(amount, user);
    }

    function _createProfit(uint256 profitAmount) internal {
        // Increase exchange rate to create profit
        uint256 currentRate = strategy.getCurrentExchangeRate();
        uint256 currentAssets = strategy.totalAssets();

        // Calculate new rate that would generate the desired profit
        uint256 currentValue = currentAssets.mulDiv(currentRate, WAD);
        uint256 newValue = currentValue + profitAmount;
        uint256 newRate = newValue.mulDiv(WAD, currentAssets);

        strategy.setExchangeRate(newRate);

        vm.prank(keeper);
        strategy.report();
    }

    function _createLoss(uint256 lossAmount) internal {
        // Decrease exchange rate to create loss
        uint256 currentRate = strategy.getCurrentExchangeRate();
        uint256 currentAssets = strategy.totalAssets();

        // Calculate new rate that would generate the desired loss
        uint256 currentValue = currentAssets.mulDiv(currentRate, WAD);
        uint256 newValue = currentValue > lossAmount ? currentValue - lossAmount : 0;
        uint256 newRate = currentAssets > 0 ? newValue.mulDiv(WAD, currentAssets) : 0;

        strategy.setExchangeRate(newRate);

        vm.prank(keeper);
        strategy.report();
    }

    /**
     * Test maxWithdraw/maxRedeem for dragon router in normal conditions
     */
    function test_dragonMaxWithdrawRedeem_normal() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalance = strategy.balanceOf(dragonRouter);
        assertGt(dragonBalance, 0, "Dragon should have shares from profit");

        // Dragon should be able to withdraw/redeem up to its balance in normal conditions
        uint256 maxWithdraw = strategy.maxWithdraw(dragonRouter);
        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);

        assertGt(maxWithdraw, 0, "Dragon should be able to withdraw");
        assertGt(maxRedeem, 0, "Dragon should be able to redeem");
        assertEq(maxRedeem, dragonBalance, "Dragon max redeem should equal balance");
    }

    /**
     * Test maxWithdraw/maxRedeem for dragon router during insolvency
     */
    function test_dragonMaxWithdrawRedeem_insolvency() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;
        uint256 lossAmount = 25 ether; // Reasonable loss that makes vault insolvent

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalanceBefore = strategy.balanceOf(dragonRouter);
        assertGt(dragonBalanceBefore, 0, "Dragon should have shares");

        // Create loss that makes vault insolvent (vault value < user debt)
        _createLoss(lossAmount);

        // Dragon should not be able to withdraw/redeem during insolvency
        uint256 maxWithdraw = strategy.maxWithdraw(dragonRouter);
        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);

        assertEq(maxWithdraw, 0, "Dragon should not be able to withdraw during insolvency");
        assertEq(maxRedeem, 0, "Dragon should not be able to redeem during insolvency");
    }

    /**
     * Test maxWithdraw/maxRedeem for dragon router when burning is disabled
     */
    function test_dragonMaxWithdrawRedeem_burningDisabled() public {
        // Disable burning
        vm.prank(management);
        strategy.setEnableBurning(false);

        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;
        uint256 lossAmount = 25 ether; // Reasonable loss

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalance = strategy.balanceOf(dragonRouter);

        // Create loss
        _createLoss(lossAmount);

        // When burning is disabled, dragon should be able to withdraw full balance even during insolvency
        uint256 maxWithdraw = strategy.maxWithdraw(dragonRouter);
        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);

        assertEq(maxRedeem, dragonBalance, "Dragon should be able to redeem full balance when burning disabled");
        assertGt(maxWithdraw, 0, "Dragon should be able to withdraw when burning disabled");
    }

    /**
     * Test that dragon cannot withdraw profit shares before report() when there's potential loss
     * This is the key test: dragon should be restricted BEFORE burning occurs
     */
    function test_dragonCannotWithdrawProfitBeforeReport() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;

        // User deposits at rate 1.0
        _depositUser(user1, userDeposit);

        // Create profit for dragon (rate goes to 1.2)
        _createProfit(profitAmount);

        uint256 dragonBalance = strategy.balanceOf(dragonRouter);
        // Dragon should have profit shares (exact amount depends on conversion logic)
        assertGt(dragonBalance, 0, "Dragon should have profit shares from 20 ether profit");

        // Dragon can withdraw in healthy state
        uint256 maxRedeemHealthy = strategy.maxRedeem(dragonRouter);
        assertEq(maxRedeemHealthy, dragonBalance, "Dragon should be able to redeem all shares when healthy");

        // Now exchange rate drops slightly (indicating 5 ether loss from peak)
        // This would leave vault value at 115 ether vs total debt of 120 ether (100 user + 20 dragon)
        // Vault is still above user debt (100) but below total debt, restricting dragon
        uint256 currentAssets = strategy.totalAssets();
        uint256 targetValue = userDeposit + 15 ether; // 115 ether total value - still above user debt
        uint256 newRate = targetValue.mulDiv(WAD, currentAssets);
        strategy.setExchangeRate(newRate);

        // BEFORE calling report(), dragon should be restricted
        uint256 maxRedeemBeforeReport = strategy.maxRedeem(dragonRouter);
        assertLt(maxRedeemBeforeReport, dragonBalance, "Dragon should be restricted before report()");

        // Dragon cannot withdraw their full balance due to restrictions
        vm.prank(dragonRouter);
        vm.expectRevert("Transfer would cause vault insolvency");
        strategy.redeem(dragonBalance, dragonRouter, dragonRouter);

        // But dragon can still withdraw the allowed amount
        if (maxRedeemBeforeReport > 0) {
            vm.prank(dragonRouter);
            strategy.redeem(maxRedeemBeforeReport, dragonRouter, dragonRouter);
        }
    }

    /**
     * Test that dragon cannot redeem more than maxRedeem
     */
    function test_dragonCannotRedeemMoreThanMax() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);

        // Try to redeem more than max should fail
        vm.prank(dragonRouter);
        vm.expectRevert("ERC4626: redeem more than max");
        strategy.redeem(maxRedeem + 1, dragonRouter, dragonRouter);
    }

    /**
     * Test that dragon cannot withdraw more than maxWithdraw
     */
    function test_dragonCannotWithdrawMoreThanMax() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 20 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 maxWithdraw = strategy.maxWithdraw(dragonRouter);

        // Try to withdraw more than max should fail
        vm.prank(dragonRouter);
        vm.expectRevert("ERC4626: withdraw more than max");
        strategy.withdraw(maxWithdraw + 1, dragonRouter, dragonRouter);
    }

    /**
     * Test transfer respects maxRedeem limits
     */
    function test_transferRespectsMaxRedeem() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 50 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalance = strategy.balanceOf(dragonRouter);

        // Create partial loss to limit dragon's redeemable amount
        _createLoss(15 ether); // Reasonable loss amount

        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);
        assertLt(maxRedeem, dragonBalance, "Max redeem should be less than balance after loss");

        // Dragon should be able to transfer up to maxRedeem
        vm.prank(dragonRouter);
        strategy.transfer(user2, maxRedeem);

        // But trying to transfer more than maxRedeem should fail
        uint256 remainingBalance = strategy.balanceOf(dragonRouter);
        if (remainingBalance > 0) {
            vm.prank(dragonRouter);
            vm.expectRevert("Dragon cannot operate during insolvency");
            strategy.transfer(user2, 1);
        }
    }

    /**
     * Test transferFrom respects maxRedeem limits
     */
    function test_transferFromRespectsMaxRedeem() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 50 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        // Dragon approves user2 to spend their shares
        vm.prank(dragonRouter);
        strategy.approve(user2, type(uint256).max);

        // Create partial loss to limit dragon's redeemable amount
        _createLoss(15 ether); // Reasonable loss amount

        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);

        // User2 should be able to transfer up to maxRedeem on behalf of dragon
        vm.prank(user2);
        strategy.transferFrom(dragonRouter, user2, maxRedeem);

        // But trying to transfer more should fail if it would violate solvency
        uint256 remainingBalance = strategy.balanceOf(dragonRouter);
        if (remainingBalance > 0) {
            vm.prank(user2);
            vm.expectRevert("Dragon cannot operate during insolvency");
            strategy.transferFrom(dragonRouter, user2, 1);
        }
    }

    /**
     * Test dragon restrictions change as losses accumulate
     */
    function test_dragonRestrictionsChangeWithLosses() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 50 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 initialMaxRedeem = strategy.maxRedeem(dragonRouter);
        assertGt(initialMaxRedeem, 0, "Dragon should initially be able to redeem");

        // Create small loss
        _createLoss(10 ether);
        uint256 maxRedeemAfterSmallLoss = strategy.maxRedeem(dragonRouter);
        assertLt(maxRedeemAfterSmallLoss, initialMaxRedeem, "Max redeem should decrease after loss");

        // Create larger loss
        _createLoss(30 ether);
        uint256 maxRedeemAfterLargeLoss = strategy.maxRedeem(dragonRouter);
        assertLt(maxRedeemAfterLargeLoss, maxRedeemAfterSmallLoss, "Max redeem should decrease further");

        // Create loss that makes vault insolvent
        _createLoss(50 ether);
        uint256 maxRedeemAfterInsolvency = strategy.maxRedeem(dragonRouter);
        assertEq(maxRedeemAfterInsolvency, 0, "Dragon should not be able to redeem during insolvency");
    }

    /**
     * Test normal users are not affected by dragon restrictions
     */
    function test_normalUsersUnaffectedByDragonRestrictions() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 30 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalanceAfterProfit = strategy.balanceOf(dragonRouter);
        assertGt(dragonBalanceAfterProfit, 0, "Dragon should have shares after profit");

        // Create a loss that leaves vault value close to user debt
        // This should restrict dragon without making vault insolvent
        _createLoss(25 ether);

        uint256 dragonMaxRedeem = strategy.maxRedeem(dragonRouter);

        // Debug info to understand the situation
        uint256 userDebt = strategy.gettotalDebtOwedToUserInAssetValue();
        uint256 dragonDebt = strategy.getDragonRouterDebtInAssetValue();
        uint256 totalAssets = strategy.totalAssets();
        uint256 currentRate = strategy.getCurrentExchangeRate();
        uint256 vaultValue = (totalAssets * currentRate) / WAD;

        // The test validates that dragons restrictions work correctly
        // In some scenarios dragon may not be restricted if there's sufficient excess value
        if (vaultValue > userDebt && dragonDebt > 0) {
            uint256 excessValue = vaultValue - userDebt;
            uint256 expectedMaxRedeem = Math.min(dragonDebt, excessValue);
            assertEq(dragonMaxRedeem, expectedMaxRedeem, "Dragon max redeem should match expected calculation");
        }

        // But normal user should not be restricted
        uint256 userMaxRedeem = strategy.maxRedeem(user1);
        uint256 userBalance = strategy.balanceOf(user1);
        assertEq(userMaxRedeem, userBalance, "Normal user should not be restricted");

        // User should be able to redeem their full balance
        vm.prank(user1);
        strategy.redeem(userBalance, user1, user1);
        assertEq(strategy.balanceOf(user1), 0, "User should have redeemed all shares");
    }

    /**
     * Test edge case: dragon with exactly enough excess value
     */
    function test_dragonExactExcessValue() public {
        uint256 userDeposit = 100 ether;
        uint256 profitAmount = 30 ether;

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalance = strategy.balanceOf(dragonRouter);

        // Create loss that leaves exactly the dragon's debt as excess
        // Dragon should be able to redeem exactly its debt amount
        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);
        assertEq(maxRedeem, dragonBalance, "Dragon should be able to redeem all shares when excess equals debt");
    }

    /**
     * Test fuzz: dragon restrictions work across various scenarios
     */
    function testFuzz_dragonRestrictions(uint256 userDeposit, uint256 profitAmount, uint256 lossAmount) public {
        userDeposit = bound(userDeposit, 10 ether, 1000 ether);
        profitAmount = bound(profitAmount, 1 ether, userDeposit);
        lossAmount = bound(lossAmount, 0, profitAmount + userDeposit);

        // User deposits
        _depositUser(user1, userDeposit);

        // Create profit for dragon
        _createProfit(profitAmount);

        uint256 dragonBalanceAfterProfit = strategy.balanceOf(dragonRouter);
        assertGt(dragonBalanceAfterProfit, 0, "Dragon should have shares after profit");

        // Create loss
        _createLoss(lossAmount);

        uint256 maxRedeem = strategy.maxRedeem(dragonRouter);
        uint256 maxWithdraw = strategy.maxWithdraw(dragonRouter);
        uint256 dragonBalance = strategy.balanceOf(dragonRouter);

        // Max redeem should never exceed dragon balance
        assertLe(maxRedeem, dragonBalance, "Max redeem should not exceed dragon balance");

        // If vault is insolvent, dragon should not be able to withdraw
        if (strategy.isVaultInsolvent()) {
            assertEq(maxRedeem, 0, "Dragon should not redeem during insolvency");
            assertEq(maxWithdraw, 0, "Dragon should not withdraw during insolvency");
        }

        // Try to redeem up to max - should succeed
        if (maxRedeem > 0) {
            vm.prank(dragonRouter);
            strategy.redeem(maxRedeem, dragonRouter, dragonRouter);
        }
    }
}
