// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import "forge-std/console.sol";
import { Setup } from "./Setup.sol";
import { DragonTokenizedStrategy__PerformanceFeeDisabled, DragonTokenizedStrategy__MaxUnlockIsAlwaysZero, Unauthorized, DragonTokenizedStrategy__InvalidLockupDuration, DragonTokenizedStrategy__InvalidRageQuitCooldownPeriod, TokenizedStrategy__NotKeeperOrManagement, TokenizedStrategy__NotManagement, TokenizedStrategy__NotPendingManagement, TokenizedStrategy__NotEmergencyAuthorized, TokenizedStrategy__NotRegenGovernance, TokenizedStrategy__AlreadyInitialized, BaseStrategy__NotSelf } from "src/errors.sol";

contract AccessControlTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_setManagement(address _address) public {
        vm.assume(_address != management && _address != address(0));

        vm.expectEmit(true, true, true, true, address(strategy));
        emit UpdatePendingManagement(_address);

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
        emit UpdateKeeper(_address);

        vm.prank(management);
        strategy.setKeeper(_address);

        assertEq(strategy.keeper(), _address);
    }

    function test_shutdown() public {
        assertTrue(!strategy.isShutdown());

        vm.expectEmit(true, true, true, true, address(strategy));
        emit StrategyShutdown();

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
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        strategy.setPendingManagement(address(69));

        assertEq(strategy.management(), _management);
        assertEq(strategy.pendingManagement(), address(0));

        vm.prank(management);
        strategy.setPendingManagement(_address);

        assertEq(strategy.management(), _management);
        assertEq(strategy.pendingManagement(), _address);

        vm.expectRevert(TokenizedStrategy__NotPendingManagement.selector);
        vm.prank(management);
        strategy.acceptManagement();
    }

    function test_setKeeper_reverts(address _address) public {
        vm.assume(_address != management);

        address _keeper = strategy.keeper();

        vm.prank(_address);
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        strategy.setKeeper(address(69));

        assertEq(strategy.keeper(), _keeper);
    }

    function test_shutdown_reverts(address _address) public {
        vm.assume(_address != management && _address != emergencyAdmin);
        assertTrue(!strategy.isShutdown());

        vm.prank(_address);
        vm.expectRevert(TokenizedStrategy__NotEmergencyAuthorized.selector);
        strategy.shutdownStrategy();

        assertTrue(!strategy.isShutdown());
    }

    function test_emergencyWithdraw_reverts(address _address) public {
        vm.assume(_address != management && _address != emergencyAdmin);

        vm.prank(management);
        strategy.shutdownStrategy();

        assertTrue(strategy.isShutdown());

        vm.prank(_address);
        vm.expectRevert(TokenizedStrategy__NotEmergencyAuthorized.selector);
        strategy.emergencyWithdraw(0);
    }

    function test_initializeTokenizedStrategy_reverts(address _address, string memory name_) public {
        vm.assume(_address != address(0));

        assertEq(tokenizedStrategy.management(), address(1));
        assertEq(tokenizedStrategy.keeper(), address(0));

        vm.expectRevert(TokenizedStrategy__AlreadyInitialized.selector);
        tokenizedStrategy.initialize(
            address(asset),
            name_,
            _address,
            _address,
            _address,
            address(mockDragonRouter),
            regenGovernance
        );

        assertEq(tokenizedStrategy.management(), address(1));
        assertEq(tokenizedStrategy.keeper(), address(0));
    }

    function test_accessControl_deployFunds(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(strategy));

        asset.mint(address(strategy), _amount);

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.deployFunds(_amount);

        vm.prank(management);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.deployFunds(_amount);

        assertEq(asset.balanceOf(address(yieldSource)), 0);

        vm.prank(address(strategy));
        strategy.deployFunds(_amount);

        // make sure we deposited into the funds
        assertEq(asset.balanceOf(address(yieldSource)), _amount, "!out");
    }

    function test_accessControl_freeFunds(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(strategy));

        // deposit into the vault and should deploy funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // assure the deposit worked correctly
        assertEq(asset.balanceOf(address(yieldSource)), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.freeFunds(_amount);
        (_amount);

        // doesn't work from management either
        vm.prank(management);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.freeFunds(_amount);

        assertEq(asset.balanceOf(address(strategy)), 0);

        vm.prank(address(strategy));
        strategy.freeFunds(_amount);

        assertEq(asset.balanceOf(address(yieldSource)), 0);
        assertEq(asset.balanceOf(address(strategy)), _amount, "!out");
    }

    function test_accessControl_harvestAndReport(address _address, uint256 _amount) public {
        _amount = bound(_amount, 0.1 ether, maxFuzzAmount);
        vm.assume(_address != address(strategy));

        // deposit into the vault and should deploy funds
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // assure the deposit worked correctly
        assertEq(asset.balanceOf(address(yieldSource)), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.harvestAndReport();

        // doesn't work from management either
        vm.prank(management);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
        strategy.harvestAndReport();

        vm.prank(address(strategy));
        uint256 amountOut = strategy.harvestAndReport();

        assertEq(amountOut, _amount, "!out");
    }

    function test_accessControl_tendThis(address _address, uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(strategy));

        // doesn't work from random address
        vm.prank(_address);
        vm.expectRevert(BaseStrategy__NotSelf.selector);
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
        vm.expectRevert(TokenizedStrategy__NotKeeperOrManagement.selector);
        strategy.tend();

        vm.prank(keeper);
        strategy.tend();
    }

    function test_setName(address _address) public {
        vm.assume(_address != address(strategy) && _address != management);

        string memory newName = "New Strategy Name";

        vm.prank(_address);
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        strategy.setName(newName);

        vm.prank(management);
        strategy.setName(newName);

        assertEq(strategy.name(), newName);
    }

    function test_setLockupDuration() public {
        uint256 newDuration = 180 days;

        vm.prank(regenGovernance);
        strategy.setLockupDuration(newDuration);

        // Test successful change
        assertEq(strategy.minimumLockupDuration(), newDuration);
    }

    function test_setLockupDuration_reverts(address _address) public {
        vm.assume(_address != regenGovernance);
        uint256 newDuration = 180 days;

        // Test unauthorized access
        vm.startPrank(_address);
        vm.expectRevert(TokenizedStrategy__NotRegenGovernance.selector);
        strategy.setLockupDuration(newDuration);
        vm.stopPrank();

        // Test invalid duration below minimum
        vm.startPrank(regenGovernance);
        vm.expectRevert(DragonTokenizedStrategy__InvalidLockupDuration.selector);
        strategy.setLockupDuration(29 days);
        vm.stopPrank();
        // Test invalid duration above maximum
        vm.startPrank(regenGovernance);
        vm.expectRevert(DragonTokenizedStrategy__InvalidLockupDuration.selector);
        strategy.setLockupDuration(3651 days);
        vm.stopPrank();
    }

    function test_setRageQuitCooldownPeriod() public {
        uint256 newPeriod = 180 days;

        vm.prank(regenGovernance);
        strategy.setRageQuitCooldownPeriod(newPeriod);

        // Test successful change
        assertEq(strategy.rageQuitCooldownPeriod(), newPeriod);
    }

    function test_setRageQuitCooldownPeriod_reverts(address _address) public {
        vm.assume(_address != regenGovernance);
        uint256 newPeriod = 180 days;

        // Test unauthorized access
        vm.startPrank(_address);
        vm.expectRevert(TokenizedStrategy__NotRegenGovernance.selector);
        strategy.setRageQuitCooldownPeriod(newPeriod);
        vm.stopPrank();

        // Test invalid period below minimum
        vm.startPrank(regenGovernance);
        vm.expectRevert(DragonTokenizedStrategy__InvalidRageQuitCooldownPeriod.selector);
        strategy.setRageQuitCooldownPeriod(29 days);
        vm.stopPrank();

        // Test invalid period above maximum
        vm.startPrank(regenGovernance);
        vm.expectRevert(DragonTokenizedStrategy__InvalidRageQuitCooldownPeriod.selector);
        strategy.setRageQuitCooldownPeriod(3651 days);
        vm.stopPrank();
    }
}
