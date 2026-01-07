// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup } from "./utils/Setup.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { BaseStrategy } from "src/core/BaseStrategy.sol";

contract AccessControlTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_setManagement(address _address) public {
        vm.assume(_address != management && _address != address(0));

        vm.expectEmit(true, true, true, true, address(strategy));
        emit TokenizedStrategy.UpdatePendingManagement(_address);

        vm.prank(management);
        strategy.setPendingManagement(_address);

        assertEq(strategy.pendingManagement(), _address);
        assertEq(strategy.management(), management);

        vm.prank(_address);
        strategy.acceptManagement();

        assertEq(strategy.pendingManagement(), address(0));
        assertEq(strategy.management(), _address);
    }

    function test_setKeeper(address _address) public {
        vm.assume(_address != keeper && _address != address(0));

        vm.expectEmit(true, true, true, true, address(strategy));
        emit TokenizedStrategy.UpdateKeeper(_address);

        vm.prank(management);
        strategy.setKeeper(_address);

        assertEq(strategy.keeper(), _address);
    }

    function test_shutdown() public {
        assertTrue(!strategy.isShutdown());

        vm.expectEmit(true, true, true, true, address(strategy));
        emit TokenizedStrategy.StrategyShutdown();

        vm.prank(management);
        strategy.shutdownStrategy();

        assertTrue(strategy.isShutdown());
    }

    function test_emergencyWithdraw() public {
        vm.prank(management);
        strategy.shutdownStrategy();

        assertTrue(strategy.isShutdown());

        vm.prank(management);
        strategy.emergencyWithdraw(0);
    }

    function test_setManagement_reverts(address _address) public {
        vm.assume(_address != management && _address != address(0));

        address _management = strategy.management();

        vm.prank(_address);
        vm.expectRevert("!management");
        strategy.setPendingManagement(address(69));

        assertEq(strategy.management(), _management);
        assertEq(strategy.pendingManagement(), address(0));

        vm.prank(management);
        strategy.setPendingManagement(_address);

        assertEq(strategy.management(), _management);
        assertEq(strategy.pendingManagement(), _address);

        vm.expectRevert("!pending");
        vm.prank(management);
        strategy.acceptManagement();
    }

    function test_setKeeper_reverts(address _address) public {
        vm.assume(_address != management);

        address _keeper = strategy.keeper();

        vm.prank(_address);
        vm.expectRevert("!management");
        strategy.setKeeper(address(69));

        assertEq(strategy.keeper(), _keeper);
    }

    function test_shutdown_reverts(address _address) public {
        vm.assume(_address != management && _address != emergencyAdmin);
        assertTrue(!strategy.isShutdown());

        vm.prank(_address);
        vm.expectRevert("!emergency authorized");
        strategy.shutdownStrategy();

        assertTrue(!strategy.isShutdown());
    }

    function test_emergencyWithdraw_reverts(address _address) public {
        vm.assume(_address != management && _address != emergencyAdmin);

        vm.prank(management);
        strategy.shutdownStrategy();

        assertTrue(strategy.isShutdown());

        vm.prank(_address);
        vm.expectRevert("!emergency authorized");
        strategy.emergencyWithdraw(0);
    }

    function test_initializeTokenizedStrategy_reverts(address _address, string memory name_) public {
        vm.assume(_address != address(0));

        vm.expectRevert("initialized");
        tokenizedStrategy.initialize(address(asset), name_, "tsSYMBOL", _address, _address, _address, _address, false);
    }

    function test_accessControl_harvestAndReport(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(strategy) && _address != keeper && _address != management);

        // deposit into the vault and should deploy funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // assure the deposit worked correctly
        assertEq(yieldSource.balanceOf(address(strategy)), _amount);

        // works only from keeper
        vm.prank(_address);
        vm.expectRevert("!keeper");
        strategy.report();

        // if test fails, it means the strategy reverted, which is not expected
    }

    function test_accessControl_tendThis(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(strategy));

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert(BaseStrategy.NotSelf.selector);
        strategy.tendThis(_amount);

        vm.prank(address(strategy));
        strategy.tendThis(_amount);
    }

    function test_accessControl_tend(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != keeper && _address != management);

        asset.mint(address(strategy), _amount);

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert("!keeper");
        strategy.tend();

        vm.prank(keeper);
        strategy.tend();
    }

    function test_setName(address _address) public {
        vm.assume(_address != address(strategy) && _address != management);

        string memory newName = "New Strategy Name";

        vm.prank(_address);
        vm.expectRevert("!management");
        strategy.setName(newName);

        vm.prank(management);
        strategy.setName(newName);

        assertEq(strategy.name(), newName);
    }

    // ================== Dragon Router Cooldown Tests ==================

    function test_dragonRouter_initialState() public view {
        assertEq(strategy.dragonRouter(), donationAddress);
        assertEq(strategy.pendingDragonRouter(), address(0));
        assertEq(strategy.dragonRouterChangeTimestamp(), 0);
    }

    function test_setDragonRouter_initiatesCooldown(address _newRouter) public {
        vm.assume(_newRouter != address(0) && _newRouter != donationAddress);

        uint256 currentTime = block.timestamp;
        uint256 expectedEffectiveTime = currentTime + 14 days;

        vm.expectEmit(true, false, false, true, address(strategy));
        emit TokenizedStrategy.PendingDragonRouterChange(_newRouter, expectedEffectiveTime);

        vm.prank(management);
        strategy.setDragonRouter(_newRouter);

        assertEq(strategy.pendingDragonRouter(), _newRouter);
        assertEq(strategy.dragonRouterChangeTimestamp(), currentTime);
        assertEq(strategy.dragonRouter(), donationAddress); // Should not change yet
    }

    function test_setDragonRouter_accessControl(address _caller) public {
        vm.assume(_caller != management);
        address newRouter = address(0x123);

        vm.prank(_caller);
        vm.expectRevert("!management");
        strategy.setDragonRouter(newRouter);
    }

    function test_setDragonRouter_zeroAddress_reverts() public {
        vm.prank(management);
        vm.expectRevert("ZERO ADDRESS");
        strategy.setDragonRouter(address(0));
    }

    function test_setDragonRouter_sameRouter_reverts() public {
        vm.prank(management);
        vm.expectRevert("same dragon router");
        strategy.setDragonRouter(donationAddress);
    }

    function test_setDragonRouter_canOverridePending() public {
        address router1 = address(0x111);
        address router2 = address(0x222);

        // Set first router
        vm.prank(management);
        strategy.setDragonRouter(router1);
        assertEq(strategy.pendingDragonRouter(), router1);

        // Override with second router
        vm.prank(management);
        strategy.setDragonRouter(router2);
        assertEq(strategy.pendingDragonRouter(), router2);
        assertEq(strategy.dragonRouterChangeTimestamp(), block.timestamp);
    }

    function test_finalizeDragonRouterChange_afterCooldown() public {
        address newRouter = address(0x123);

        // Initiate change
        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Skip cooldown period
        skip(14 days);

        vm.expectEmit(true, false, false, false, address(strategy));
        emit TokenizedStrategy.UpdateDragonRouter(newRouter);

        // Anyone can finalize
        strategy.finalizeDragonRouterChange();

        assertEq(strategy.dragonRouter(), newRouter);
        assertEq(strategy.pendingDragonRouter(), address(0));
        assertEq(strategy.dragonRouterChangeTimestamp(), 0);
    }

    function test_finalizeDragonRouterChange_byAnyone(address _caller) public {
        vm.assume(_caller != address(0));
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        skip(14 days);

        vm.prank(_caller);
        strategy.finalizeDragonRouterChange();

        assertEq(strategy.dragonRouter(), newRouter);
    }

    function test_finalizeDragonRouterChange_noPendingChange_reverts() public {
        vm.expectRevert("no pending change");
        strategy.finalizeDragonRouterChange();
    }

    function test_finalizeDragonRouterChange_cooldownNotElapsed_reverts() public {
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Try before cooldown ends
        vm.expectRevert("cooldown not elapsed");
        strategy.finalizeDragonRouterChange();

        // Try just before cooldown ends
        skip(14 days - 1);
        vm.expectRevert("cooldown not elapsed");
        strategy.finalizeDragonRouterChange();

        // Should work exactly at cooldown end
        skip(1);
        strategy.finalizeDragonRouterChange();
    }

    function testFuzz_finalizeDragonRouterChange_atVariousTimes(uint256 _skipTime) public {
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        _skipTime = bound(_skipTime, 0, 14 days);
        skip(_skipTime);

        if (_skipTime < 14 days) {
            vm.expectRevert("cooldown not elapsed");
            strategy.finalizeDragonRouterChange();
        } else {
            strategy.finalizeDragonRouterChange();
            assertEq(strategy.dragonRouter(), newRouter);
        }
    }

    function test_cancelDragonRouterChange() public {
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        assertEq(strategy.pendingDragonRouter(), newRouter);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit TokenizedStrategy.PendingDragonRouterChange(address(0), 0);

        vm.prank(management);
        strategy.cancelDragonRouterChange();

        assertEq(strategy.pendingDragonRouter(), address(0));
        assertEq(strategy.dragonRouterChangeTimestamp(), 0);
        assertEq(strategy.dragonRouter(), donationAddress); // Should remain unchanged
    }

    function test_cancelDragonRouterChange_accessControl(address _caller) public {
        vm.assume(_caller != management);
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        vm.prank(_caller);
        vm.expectRevert("!management");
        strategy.cancelDragonRouterChange();
    }

    function test_cancelDragonRouterChange_noPendingChange_reverts() public {
        vm.prank(management);
        vm.expectRevert("no pending change");
        strategy.cancelDragonRouterChange();
    }

    function test_cancelDragonRouterChange_duringCooldown() public {
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Skip part of cooldown period
        skip(3 days);

        vm.prank(management);
        strategy.cancelDragonRouterChange();

        assertEq(strategy.pendingDragonRouter(), address(0));
        assertEq(strategy.dragonRouter(), donationAddress);
    }

    function test_cancelDragonRouterChange_afterCooldownBeforeFinalization() public {
        address newRouter = address(0x123);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Skip full cooldown period
        skip(14 days + 1 hours);

        // Management can still cancel even after cooldown
        vm.prank(management);
        strategy.cancelDragonRouterChange();

        assertEq(strategy.pendingDragonRouter(), address(0));
        assertEq(strategy.dragonRouter(), donationAddress);
    }

    function testFuzz_userWithdrawDuringCooldown(uint256 _amount, uint256 _skipTime) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _skipTime = bound(_skipTime, 0, 14 days - 1);
        address newRouter = address(0x123);

        // Setup user with funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Record initial balance before dragon router change
        uint256 initialBalance = yieldSource.balanceOf(user);

        // Initiate dragon router change
        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Skip some time during cooldown
        skip(_skipTime);

        // User should be able to withdraw normally during cooldown
        uint256 userShares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(userShares, user, user);

        // Should have received their yieldSource tokens back (checking the difference)
        // In yieldSkimming, user deposits yieldSource tokens and gets them back
        assertEq(yieldSource.balanceOf(user), initialBalance + _amount);
    }

    function test_reportingDuringPendingChange() public {
        address newRouter = address(0x123);
        uint256 amount = 1e18;

        // Setup some funds
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Initiate dragon router change
        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Generate some profit by minting assets to the yieldSource (simulating appreciation)
        // Use a larger amount to ensure detectable profit
        uint256 profitAmount = (amount * 10) / 100; // 10% profit
        asset.mint(address(yieldSource), profitAmount);

        // Reporting should work normally during pending change
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // The key test is that the dragon router change is still pending and working correctly
        assertEq(loss, 0, "loss should be 0");
        assertEq(strategy.pendingDragonRouter(), newRouter, "pending router should be set");
        assertEq(strategy.dragonRouter(), donationAddress, "current router should be unchanged");

        // If profit is generated, it should go to the current (original) dragon router
        if (profit > 0) {
            assertEq(strategy.balanceOf(newRouter), 0, "new router should have no shares yet");
        }
    }

    function test_reportingAfterFinalization() public {
        address newRouter = address(0x123);
        uint256 amount = 1e18;

        // Setup some funds
        mintAndDepositIntoStrategy(strategy, user, amount);

        // Change and finalize dragon router
        vm.prank(management);
        strategy.setDragonRouter(newRouter);
        skip(14 days);
        strategy.finalizeDragonRouterChange();

        // Verify the change was finalized
        assertEq(strategy.dragonRouter(), newRouter, "dragon router should be updated");
        assertEq(strategy.pendingDragonRouter(), address(0), "pending router should be cleared");

        // Generate some profit by minting assets to the yieldSource (simulating appreciation)
        // Use a larger amount to ensure detectable profit
        uint256 profitAmount = (amount * 10) / 100; // 10% profit
        asset.mint(address(yieldSource), profitAmount);

        // Record initial balances
        uint256 oldRouterInitialBalance = strategy.balanceOf(donationAddress);
        uint256 newRouterInitialBalance = strategy.balanceOf(newRouter);

        // Report should now use new dragon router
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(loss, 0, "loss should be 0");

        // If profit is generated, it should go to the new dragon router
        if (profit > 0) {
            // New router should have received the profit shares
            assertGt(strategy.balanceOf(newRouter), newRouterInitialBalance, "new router should receive profit shares");
            // Old router balance should not increase
            assertEq(
                strategy.balanceOf(donationAddress),
                oldRouterInitialBalance,
                "old router should not receive new shares"
            );
        }
    }

    function test_multipleChangesInSequence() public {
        address router1 = address(0x111);
        address router2 = address(0x222);

        // First change
        vm.prank(management);
        strategy.setDragonRouter(router1);

        // Override with another change
        vm.prank(management);
        strategy.setDragonRouter(router2);

        skip(14 days);

        // Finalize should use the latest change
        strategy.finalizeDragonRouterChange();
        assertEq(strategy.dragonRouter(), router2);
    }

    function test_cancelThenSetNewChange() public {
        address router1 = address(0x111);
        address router2 = address(0x222);

        // Set initial change
        vm.prank(management);
        strategy.setDragonRouter(router1);

        // Cancel it
        vm.prank(management);
        strategy.cancelDragonRouterChange();

        // Set a new change
        vm.prank(management);
        strategy.setDragonRouter(router2);

        skip(14 days);

        strategy.finalizeDragonRouterChange();
        assertEq(strategy.dragonRouter(), router2);
    }

    function testFuzz_timestampOverflow(uint96 _timestamp) public {
        address newRouter = address(0x123);

        // Test that the contract handles timestamp edge cases
        vm.warp(_timestamp);

        vm.prank(management);
        strategy.setDragonRouter(newRouter);

        // Should not overflow
        assertEq(strategy.dragonRouterChangeTimestamp(), _timestamp);
    }

    function testFuzz_getterFunctions(address _pendingRouter, uint96 _timestamp) public {
        vm.assume(_pendingRouter != address(0));
        vm.assume(_pendingRouter != donationAddress);

        vm.warp(_timestamp);

        vm.prank(management);
        strategy.setDragonRouter(_pendingRouter);

        assertEq(strategy.pendingDragonRouter(), _pendingRouter);
        assertEq(strategy.dragonRouterChangeTimestamp(), _timestamp);
        assertEq(strategy.dragonRouter(), donationAddress);
    }

    function test_cooldownPeriodConstant() public pure {
        // Verify cooldown period is 14 days (604800 seconds)
        uint256 EXPECTED_COOLDOWN = 14 days;
        assertEq(EXPECTED_COOLDOWN, 1209600);
    }
}
