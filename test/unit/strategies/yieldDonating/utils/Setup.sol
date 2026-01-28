// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { MockFaultyStrategy } from "test/mocks/core/tokenized-strategies/MockFaultyStrategy.sol";
import { MockIlliquidStrategy } from "test/mocks/core/tokenized-strategies/MockIlliquidStrategy.sol";
import { MockYieldSource } from "test/mocks/core/tokenized-strategies/MockYieldSource.sol";
import { MockStrategy } from "test/mocks/core/tokenized-strategies/MockStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

contract Setup is Test {
    // Contract instances that we will use repeatedly.
    ERC20Mock public asset;
    IMockStrategy public strategy;
    MockFactory public mockFactory;
    MockYieldSource public yieldSource;
    YieldDonatingTokenizedStrategy public tokenizedStrategy;
    YieldDonatingTokenizedStrategy public implementation;

    // Addresses for different roles we will use repeatedly.
    address public user = address(1);
    address public keeper = address(2);
    address public management = address(3);
    address public emergencyAdmin = address(4);
    address public protocolFeeRecipient = address(5);
    address public performanceFeeRecipient = address(6);
    address public donationAddress = address(7);

    // Integer variables that will be used repeatedly.
    uint256 public decimals = 18;
    uint256 public MAX_BPS = 10_000;
    uint256 public wad = 10 ** decimals;
    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e30;
    uint256 public minFuzzAmount = 10_000;
    uint256 public profitMaxUnlockTime = 10 days;

    bytes32 public constant BASE_STRATEGY_STORAGE = bytes32(uint256(keccak256("yearn.base.strategy.storage")) - 1);

    function setUp() public virtual {
        // Deploy the mock factory first for deterministic location
        mockFactory = new MockFactory(0, protocolFeeRecipient);

        // Deploy the implementation for deterministic location
        implementation = new YieldDonatingTokenizedStrategy();

        // Deploy the proxy for deterministic location
        tokenizedStrategy = YieldDonatingTokenizedStrategy(address(new ERC1967Proxy(address(implementation), "")));
        // initialize the tokenized strategy

        // create asset we will be using as the underlying asset
        asset = new ERC20Mock();

        tokenizedStrategy.initialize(
            address(asset),
            "Test Strategy",
            "tsSYMBOL",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true // enableBurning
        );

        // create a mock yield source to deposit into
        yieldSource = new MockYieldSource(address(asset));

        // Deploy strategy and set variables
        strategy = IMockStrategy(setUpStrategy());

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(emergencyAdmin, "emergency admin");
        vm.label(address(mockFactory), "mock Factory");
        vm.label(address(yieldSource), "Mock Yield Source");
        vm.label(address(tokenizedStrategy), "tokenized Logic");
        vm.label(protocolFeeRecipient, "Protocol Fee Recipient");
        vm.label(performanceFeeRecipient, "Performance Fee Recipient");
    }

    function setUpStrategy() public returns (address) {
        // we save the mock base strategy as a IMockStrategy to give it the needed interface
        IMockStrategy _strategy = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset),
                    address(yieldSource),
                    management,
                    keeper,
                    emergencyAdmin,
                    donationAddress,
                    address(implementation)
                )
            )
        );

        vm.startPrank(management);
        // set keeper
        _strategy.setKeeper(keeper);

        // set the emergency admin
        _strategy.setEmergencyAdmin(emergencyAdmin);
        // set management of the strategy
        _strategy.setPendingManagement(management);

        _strategy.acceptManagement();
        vm.stopPrank();

        return address(_strategy);
    }

    function setUpIlliquidStrategy() public returns (address) {
        IMockStrategy _strategy = IMockStrategy(
            address(
                new MockIlliquidStrategy(
                    address(asset),
                    address(yieldSource),
                    management,
                    keeper,
                    emergencyAdmin,
                    donationAddress,
                    address(implementation)
                )
            )
        );

        vm.startPrank(management);

        // set keeper
        _strategy.setKeeper(keeper);
        // set the emergency admin
        _strategy.setEmergencyAdmin(emergencyAdmin);

        // set management of the strategy
        _strategy.setPendingManagement(management);

        _strategy.acceptManagement();
        vm.stopPrank();

        return address(_strategy);
    }

    function setUpFaultyStrategy() public returns (address) {
        IMockStrategy _strategy = IMockStrategy(
            address(
                new MockFaultyStrategy(
                    address(asset),
                    address(yieldSource),
                    management,
                    keeper,
                    emergencyAdmin,
                    donationAddress,
                    address(implementation)
                )
            )
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set the emergency admin
        _strategy.setEmergencyAdmin(emergencyAdmin);
        // set management of the strategy
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
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
    ) public view {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20Mock(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
        // We give supply a buffer or 1 wei for rounding
        assertApproxEqRel(_strategy.totalSupply(), _totalSupply, 1e13, "!supply");
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

    function createAndCheckProfit(IMockStrategy _strategy, uint256 profit) public {
        uint256 startingAssets = _strategy.totalAssets();
        asset.mint(address(_strategy), profit);

        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = _strategy.report();

        assertEq(profit, _profit, "profit reported wrong");
        assertEq(_loss, 0, "Reported loss");
        assertEq(_strategy.totalAssets(), startingAssets + profit, "total assets wrong");
        assertEq(_strategy.lastReport(), block.timestamp, "last report");
        assertEq(_strategy.unlockedShares(), 0, "unlocked Shares");
    }

    function createAndCheckLoss(IMockStrategy _strategy, uint256 loss) public {
        uint256 startingAssets = _strategy.totalAssets();

        yieldSource.simulateLoss(loss);

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
        assertApproxEqAbs(_strategy.balanceOf(address(_strategy)), _buffer, 1, "!Buffer");
    }

    function setupAllowset(address _address) public {
        MockIlliquidStrategy _strategy = MockIlliquidStrategy(payable(address(strategy)));

        _strategy.setAllowset(true);

        _strategy.allow(_address);
    }

    function configureFaultyStrategy(uint256 _fault, bool _callBack) public {
        MockFaultyStrategy _strategy = MockFaultyStrategy(payable(address(strategy)));

        _strategy.setFaultAmount(_fault);
        _strategy.setCallBack(_callBack);
    }

    function _strategyStorage() internal pure returns (YieldDonatingTokenizedStrategy.StrategyData storage S) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = BASE_STRATEGY_STORAGE;
        assembly {
            S.slot := slot
        }
    }
}
