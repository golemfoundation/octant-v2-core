// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./Base.t.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";

import { Unauthorized, TokenizedStrategy__NotKeeperOrManagement, TokenizedStrategy__NotManagement, TokenizedStrategy__NotOperator } from "src/errors.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract BaseStrategyTest is BaseTest {
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address dragonRouter = makeAddr("dragonRouter");
    address management = makeAddr("management");
    address regenGovernance = makeAddr("regenGovernance");

    testTemps temps;
    MockStrategy moduleImplementation;
    MockStrategy module;
    MockYieldSource yieldSource;
    DragonTokenizedStrategy tokenizedStrategyImplementation;

    string public name = "Test Mock Strategy";
    uint256 public maxReportDelay = 9;

    function setUp() public {
        _configure(true, "eth");

        moduleImplementation = new MockStrategy();
        yieldSource = new MockYieldSource(NATIVE_TOKEN);
        tokenizedStrategyImplementation = new DragonTokenizedStrategy();
        temps = _testTemps(
            address(moduleImplementation),
            abi.encode(
                address(tokenizedStrategyImplementation),
                NATIVE_TOKEN,
                address(yieldSource),
                management,
                keeper,
                dragonRouter,
                maxReportDelay,
                name,
                regenGovernance
            )
        );
        module = MockStrategy(payable(temps.module));
    }

    /// @dev tests if initial params are set correctly.
    function testInitialize() public view {
        assertTrue(module.tokenizedStrategyImplementation() == address(tokenizedStrategyImplementation));
        assertTrue(module.maxReportDelay() == maxReportDelay);
        assertTrue(ITokenizedStrategy(address(module)).management() == management);
        assertTrue(ITokenizedStrategy(address(module)).keeper() == keeper);
        assertTrue(ITokenizedStrategy(address(module)).operator() == temps.safe);
        assertTrue(ITokenizedStrategy(address(module)).dragonRouter() == dragonRouter);
    }

    function testDeployFunds() public {
        // add some assets to the safe
        uint256 amount = 1 ether;
        vm.deal(temps.safe, amount);

        // only safe can call deposit function
        vm.expectRevert(TokenizedStrategy__NotOperator.selector);
        ITokenizedStrategy(address(module)).deposit(amount, temps.safe);

        vm.startPrank(temps.safe);

        assertTrue(module.availableDepositLimit(temps.safe) == type(uint256).max);

        assertTrue(ITokenizedStrategy(address(module)).balanceOf(temps.safe) == 0);
        assertTrue(address(yieldSource).balance == 0);
        ITokenizedStrategy(address(module)).deposit(amount, temps.safe);
        assertTrue(ITokenizedStrategy(address(module)).balanceOf(temps.safe) == amount);
        assertTrue(address(yieldSource).balance == amount);

        vm.stopPrank();
    }

    function testfreeFunds() public {
        /// Setup
        uint256 amount = 1 ether;
        _deposit(amount);

        uint256 withdrawAmount = 0.5 ether;

        vm.startPrank(temps.safe);

        assertTrue(module.availableWithdrawLimit(temps.safe) == type(uint256).max);
        assertTrue(ITokenizedStrategy(address(module)).balanceOf(temps.safe) == amount);
        assertTrue(address(yieldSource).balance == amount);
        ITokenizedStrategy(address(module)).withdraw(withdrawAmount, temps.safe, temps.safe, 10000);
        assertTrue(ITokenizedStrategy(address(module)).balanceOf(temps.safe) == amount - withdrawAmount);
        assertTrue(address(yieldSource).balance == amount - withdrawAmount);

        vm.stopPrank();
    }

    function testHarvestTrigger() public {
        // returns false if strategy has no assets.
        assertTrue(!module.harvestTrigger());

        // deposit funds in the strategy
        uint256 amount = 1 ether;
        _deposit(amount);
        // should return false if strategy has funds but report has been called recently
        assertTrue(!module.harvestTrigger());

        // should return true if assets in strategy > 0 and report hasn't been called for time > maxReportDelay.
        vm.warp(block.timestamp + 100);
        assertTrue(module.harvestTrigger());
    }

    function testHarvestAndReport() public {
        /// Setup
        uint256 amount = 1 ether;
        _deposit(amount);

        vm.startPrank(keeper);
        uint256 harvestedAmount = 0.1 ether;
        vm.deal(address(yieldSource), amount + harvestedAmount);
        ITokenizedStrategy(address(module)).report();
        vm.stopPrank();
    }

    function testTendThis() public {
        // tend works only through keepers
        vm.expectRevert(TokenizedStrategy__NotKeeperOrManagement.selector);
        ITokenizedStrategy(address(module)).tend();

        vm.startPrank(keeper);

        uint256 idleFunds = 1 ether;
        vm.deal(address(module), idleFunds);

        module.setTrigger(true);
        (bool tendTrigger, ) = module.tendTrigger();
        assertTrue(tendTrigger == true);

        assertTrue(address(module).balance == idleFunds);
        assertTrue(address(yieldSource).balance == 0);
        ITokenizedStrategy(address(module)).tend();
        assertTrue(address(module).balance == 0);
        assertTrue(address(yieldSource).balance == idleFunds);

        vm.stopPrank();
    }

    function testShutdownWithdraw() public {
        /// Setup
        uint256 amount = 1 ether;
        _deposit(amount);

        vm.startPrank(management);

        uint256 emergencyWithdrawAmount = 0.5 ether;
        assertTrue(address(yieldSource).balance == amount);
        ITokenizedStrategy(address(module)).shutdownStrategy();
        ITokenizedStrategy(address(module)).emergencyWithdraw(emergencyWithdrawAmount);
        assertTrue(address(yieldSource).balance == amount - emergencyWithdrawAmount);

        vm.stopPrank();
    }

    function testAdjustPosition() public {
        /// Setup
        uint256 amount = 1 ether;
        _deposit(amount);

        // reverts if not called by management.
        uint256 debtOutstanding = 0.5 ether;
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        module.adjustPosition(debtOutstanding);

        vm.startPrank(management);

        assertTrue(address(yieldSource).balance == amount);
        module.adjustPosition(debtOutstanding);
        assertTrue(address(yieldSource).balance == amount - debtOutstanding);

        vm.stopPrank();
    }

    function testLiquidatePosition() public {
        /// Setup
        uint256 amount = 1 ether;
        _deposit(amount);

        // reverts if not called by management.
        uint256 liquidationAmount = 0.5 ether;
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        module.liquidatePosition(liquidationAmount);

        vm.startPrank(management);

        assertTrue(address(yieldSource).balance == amount);
        module.liquidatePosition(liquidationAmount);
        assertTrue(address(yieldSource).balance == amount - liquidationAmount);

        vm.stopPrank();
    }

    function _deposit(uint256 _amount) internal {
        vm.deal(temps.safe, _amount);
        vm.prank(temps.safe);
        ITokenizedStrategy(address(module)).deposit(_amount, temps.safe);
    }
}
