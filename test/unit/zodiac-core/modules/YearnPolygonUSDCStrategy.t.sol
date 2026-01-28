// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../Base.t.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { YearnPolygonUsdcStrategy } from "src/zodiac-core/modules/YearnPolygonUsdcStrategy.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStrategy } from "src/zodiac-core/interfaces/IStrategy.sol";
import { TokenizedStrategy__NotOperator } from "src/errors.sol";

contract YearnPolygonUsdcStrategyTest is BaseTest {
    address management = makeAddr("management");
    address keeper = makeAddr("keeper");
    address dragonRouter = makeAddr("dragonRouter");
    uint256 maxReportDelay = 7 days;

    testTemps temps;
    address tokenizedStrategyImplementation;
    address moduleImplementation;
    IStrategy module;
    IStrategy yieldSource = IStrategy(0x52367C8E381EDFb068E9fBa1e7E9B2C847042897);
    IERC20 asset = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);
    /// @dev USDC Polygon

    function setUp() public {
        _configure(true, "polygon");
        moduleImplementation = address(new YearnPolygonUsdcStrategy());
        tokenizedStrategyImplementation = address(new DragonTokenizedStrategy());

        temps = _testTemps(
            moduleImplementation,
            abi.encode(tokenizedStrategyImplementation, management, keeper, dragonRouter, maxReportDelay, management)
        );
        module = IStrategy(payable(temps.module));
    }

    function testCheckModuleInitialization() public view {
        assertTrue(module.owner() == temps.safe);
        assertTrue(module.keeper() == keeper);
        assertTrue(module.management() == management);
        assertTrue(module.dragonRouter() == dragonRouter);
        assertTrue(module.tokenizedStrategyImplementation() == address(tokenizedStrategyImplementation));
        assertTrue(module.maxReportDelay() == maxReportDelay);
    }

    function testDeployFunds() public {
        // add some assets to the safe
        uint256 amount = 1e13;
        deal(address(asset), temps.safe, amount, true);

        // only safe can call deposit function
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotOperator.selector));
        module.deposit(amount, temps.safe);

        vm.startPrank(temps.safe);

        assertTrue(module.balanceOf(temps.safe) == 0);
        module.deposit(amount, temps.safe);
        assertTrue(module.balanceOf(temps.safe) > 0);

        vm.stopPrank();
    }

    function testfreeFunds() public {
        /// Setup
        uint256 amount = 1e13;
        _deposit(amount);

        uint256 withdrawAmount = 0.000001 ether;

        vm.startPrank(temps.safe);

        assertTrue(module.availableWithdrawLimit(temps.safe) == type(uint256).max);
        assertTrue(module.balanceOf(temps.safe) == amount);
        module.withdraw(withdrawAmount, temps.safe, temps.safe, 10_000);
        assertTrue(asset.balanceOf(temps.safe) == withdrawAmount);

        vm.stopPrank();
    }

    function testHarvestTrigger() public {
        // returns false if strategy has no assets.
        assertTrue(!module.harvestTrigger());

        // deposit funds in the strategy
        uint256 amount = 1e13;
        _deposit(amount);
        // should return false if strategy has funds but report has been called recently
        assertTrue(!module.harvestTrigger());

        // should return true if assets in strategy > 0 and report hasn't been called for time > maxReportDelay.
        vm.warp(block.timestamp + 7 days);
        assertTrue(module.harvestTrigger());
    }

    function testharvestAndReport() public {
        /// Setup
        uint256 amount = 1e13;
        _deposit(amount);

        vm.prank(keeper);
        module.report();
        assertTrue(asset.balanceOf(address(module)) > 0);

        // As report is called all the funds from the strategy are withdrawn
        // Therefore we need to deposit the idle funds in the strategy again.
        vm.prank(keeper);
        module.tend();
        assertTrue(asset.balanceOf(address(module)) == 0);
    }

    function testShutdownWithdraw() public {
        /// Setup
        uint256 amount = 1e13;
        _deposit(amount);

        vm.startPrank(management);

        uint256 emergencyWithdrawAmount = 0.000001 ether;
        module.shutdownStrategy();
        module.emergencyWithdraw(emergencyWithdrawAmount);
        assertTrue(asset.balanceOf(address(module)) == emergencyWithdrawAmount);

        vm.stopPrank();
    }

    function _deposit(uint256 _amount) internal {
        deal(address(asset), temps.safe, _amount, true);
        vm.prank(temps.safe);
        module.deposit(_amount, temps.safe);
    }
}
