// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import "forge-std/console.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { ExtendedTest } from "./ExtendedTest.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy2.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { MockDragonRouter } from "test/mocks/zodiac-core/MockDragonRouter.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

import { IEvents } from "src/interfaces/IEvents.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";

contract Setup is ExtendedTest, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20Mock public asset;
    IMockStrategy public strategy;
    MockStrategy public mockStrategyImplementation;
    MockYieldSource public yieldSource;
    DragonTokenizedStrategy public tokenizedStrategy;
    MockDragonRouter public mockDragonRouter;

    string public name = "Test Mock Strategy";
    uint256 public maxReportDelay = 9;

    // Addresses for different roles we will use repeatedly.
    address public user;
    address public alice = address(1);
    address public ben = address(2);
    address public keeper = address(2);
    address public management = address(3);
    address public emergencyAdmin = address(4);
    address public metaPool = address(7);
    address public regenGovernance = address(15);

    // Integer variables that will be used repeatedly.
    uint256 public decimals = 18;
    uint256 public MAX_BPS = 10_000;
    uint256 public wad = 10 ** decimals;
    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _configure(false, "");
        // Deploy the implementation for deterministic location
        tokenizedStrategy = new DragonTokenizedStrategy();

        mockStrategyImplementation = new MockStrategy();

        // create asset we will be using as the underlying asset
        asset = new ERC20Mock();

        // create a mock yield source to deposit into
        yieldSource = new MockYieldSource(address(asset));

        // create a mock dragon module and router
        mockDragonRouter = new MockDragonRouter(address(asset), metaPool, management);

        // Deploy strategy and set variables
        strategy = IMockStrategy(setUpStrategy());

        vm.prank(management);
        strategy.setEmergencyAdmin(emergencyAdmin);

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(emergencyAdmin, "emergency admin");
        vm.label(address(yieldSource), "Mock Yield Source");
        vm.label(address(tokenizedStrategy), "tokenized Logic");
        vm.label(regenGovernance, "regen governance");
    }

    function setUpStrategy() public returns (address) {
        testTemps memory temps = _testTemps(
            address(mockStrategyImplementation),
            abi.encode(
                address(tokenizedStrategy),
                address(asset),
                address(yieldSource),
                management,
                keeper,
                address(mockDragonRouter),
                maxReportDelay,
                name,
                regenGovernance
            )
        );
        user = temps.safe;
        return address(temps.module);
    }

    function mintAndDepositIntoStrategy(IMockStrategy _strategy, address _user, uint256 _amount) public {
        asset.mint(_user, _amount);
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function checkStrategyTotals(
        IMockStrategy _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle,
        uint256 _totalSupply
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20Mock(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
        // We give supply a buffer or 1 wei for rounding
        assertApproxEq(_strategy.totalSupply(), _totalSupply, 1, "!supply");
    }

    // For checks without totalSupply while profit is unlocking
    function checkStrategyTotals(
        IMockStrategy _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public view {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20Mock(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function createAndCheckProfit(IMockStrategy _strategy, uint256 profit, uint256 _protocolFees) public {
        uint256 startingAssets = _strategy.totalAssets();
        asset.mint(address(_strategy), profit);

        // Check the event matches the expected values
        vm.expectEmit(true, true, true, true, address(_strategy));
        emit Reported(profit, 0, _protocolFees, 0);

        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = _strategy.report();

        assertEq(profit, _profit, "profit reported wrong");
        assertEq(_loss, 0, "Reported loss");
        assertEq(_strategy.totalAssets(), startingAssets + profit, "total assets wrong");
        assertEq(_strategy.lastReport(), block.timestamp, "last report");
        assertEq(_strategy.unlockedShares(), 0, "unlocked Shares");
    }

    function createAndCheckLoss(IMockStrategy _strategy, uint256 loss, uint256 _protocolFees, bool _checkFees) public {
        uint256 startingAssets = _strategy.totalAssets();

        yieldSource.simulateLoss(loss);
        // Check the event matches the expected values
        vm.expectEmit(true, true, true, _checkFees, address(_strategy));
        emit Reported(0, loss, _protocolFees, 0);

        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = _strategy.report();

        assertEq(0, _profit, "profit reported wrong");
        assertEq(_loss, loss, "Reported loss");
        assertEq(_strategy.totalAssets(), startingAssets - loss, "total assets wrong");
        assertEq(_strategy.lastReport(), block.timestamp, "last report");
    }

    function increaseTimeAndCheckBuffer(IMockStrategy _strategy, uint256 _time, uint256 _buffer) public {
        skip(_time);
        // We give a buffer or 1 wei for rounding
        assertApproxEq(_strategy.balanceOf(address(_strategy)), _buffer, 1, "!Buffer");
    }
}
