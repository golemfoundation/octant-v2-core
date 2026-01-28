// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { BaseTest } from "../Base.t.sol";
import { MethYieldStrategy } from "src/zodiac-core/modules/MethYieldStrategy.sol";
import { YieldBearingDragonTokenizedStrategy } from "src/zodiac-core/vaults/YieldBearingDragonTokenizedStrategy.sol";
import { TokenizedStrategy__DepositMoreThanMax } from "src/errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { IDragonTokenizedStrategy } from "src/zodiac-core/interfaces/IDragonTokenizedStrategy.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MockMETH } from "test/mocks/MockMETH.sol";
import { MockMantleStaking } from "test/mocks/MockMantleStaking.sol";
import { MockMethYieldStrategy } from "test/mocks/zodiac-core/MockMethYieldStrategy.sol";
import { console } from "forge-std/console.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { DragonTokenizedStrategy__WithdrawMoreThanMax } from "src/errors.sol";
import { IMethYieldStrategy } from "src/zodiac-core/interfaces/IMethYieldStrategy.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

/**
 * @title MethYieldStrategyTest
 * @notice Unit tests for the MethYieldStrategy
 * @dev Uses mock contracts to simulate Mantle's staking and mETH behavior
 */
contract MethYieldStrategyTest is BaseTest {
    // Strategy parameters
    address management = makeAddr("management");
    address keeper = makeAddr("keeper");
    address dragonRouter = makeAddr("dragonRouter");
    address regenGovernance = makeAddr("regenGovernance");

    // Test wallets
    address internal deployer;
    address internal depositor;
    address internal depositor2;
    // Mock contracts
    MockMETH mockMeth;
    MockMantleStaking mockMantleStaking;

    // Test environment
    testTemps temps;
    address tokenizedStrategyImplementation;
    address moduleImplementation;
    MethYieldStrategy strategy;

    // The actual constant addresses for reference
    address constant REAL_MANTLE_STAKING = 0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f;

    // Test parameters
    uint256 internal constant ZERO_BPS = 0;
    // Fixed parameters for yield test
    uint256 internal constant EXCHANGE_RATE_INCREASE_PCT = 20;
    uint256 internal constant BASE_RATE = 1e18; // 1:1 ratio initially

    // State tracking for multi-cycle tests
    uint256 internal currentCycleRate;
    uint256 internal currentTotalAssets;

    function setUp() public {
        _configure(false, "eth");

        // Set up users
        deployer = makeAddr("deployer");
        depositor = makeAddr("depositor");
        depositor2 = makeAddr("depositor2");
        vm.deal(deployer, 10 ether);

        // Deploy mock contracts
        mockMeth = new MockMETH();
        mockMantleStaking = new MockMantleStaking(address(mockMeth));

        // Configure mock relationships
        mockMeth.setMantleStaking(address(mockMantleStaking));
        mockMantleStaking.setExchangeRate(1e18); // 1:1 for simplicity
        mockMantleStaking.setMETHToken(address(mockMeth));

        // Fund mock staking contract with ETH
        vm.deal(address(mockMantleStaking), 100 ether);

        // Setup mocks at the real address with etch
        vm.etch(REAL_MANTLE_STAKING, address(mockMantleStaking).code);
        vm.startPrank(address(this));
        // Initialize exchange rate at the real address
        MockMantleStaking(payable(REAL_MANTLE_STAKING)).setExchangeRate(1e18);
        // Set the mETH token reference in the staking contract
        MockMantleStaking(payable(REAL_MANTLE_STAKING)).setMETHToken(address(mockMeth));
        vm.stopPrank();

        // Fund the real address with ETH
        vm.deal(REAL_MANTLE_STAKING, 100 ether);

        // Create implementations
        moduleImplementation = address(new MockMethYieldStrategy());
        tokenizedStrategyImplementation = address(new YieldBearingDragonTokenizedStrategy());

        uint256 maxReportDelay = 7 days;

        // Use _testTemps to set up the test environment
        temps = _testTemps(
            moduleImplementation,
            abi.encode(
                tokenizedStrategyImplementation,
                management,
                keeper,
                dragonRouter,
                maxReportDelay,
                regenGovernance,
                address(mockMeth)
            )
        );

        // Cast the module to our strategy type
        strategy = MethYieldStrategy(payable(temps.module));

        // Set mock addresses in the strategy implementation
        MockMethYieldStrategy(payable(temps.module)).setMockAddresses(address(mockMantleStaking), address(mockMeth));

        // Mint tokens to the temps.safe address instead of directly to the strategy
        mockMeth.mint(temps.safe, 10 ether);
    }

    /**
     * @notice Test basic initialization and constants
     */
    function testInitialization() public view {
        assertEq(address(strategy.MANTLE_STAKING()), REAL_MANTLE_STAKING, "Incorrect Mantle staking address");
        assertEq(ITokenizedStrategy(address(strategy)).management(), management, "Incorrect management address");
        assertEq(ITokenizedStrategy(address(strategy)).keeper(), keeper, "Incorrect keeper address");
        assertEq(ITokenizedStrategy(address(strategy)).dragonRouter(), dragonRouter, "Incorrect dragon router address");
    }

    /**
     * @notice Helper function to process a harvest cycle and return key values
     * @return profit The profit generated in this cycle
     * @return routerBalance The router balance after harvest
     */
    function _processHarvestCycle()
        internal
        returns (uint256 profit, uint256 routerBalance, uint256 newRate, uint256 profitInShares)
    {
        // Calculate new exchange rate with increase
        // Calculate new exchange rate with increase
        newRate = currentCycleRate == 0
            ? BASE_RATE + ((BASE_RATE * EXCHANGE_RATE_INCREASE_PCT) / 100)
            : currentCycleRate + ((currentCycleRate * EXCHANGE_RATE_INCREASE_PCT) / 100);

        // Set the new rate in the mock
        mockMantleStaking.setExchangeRate(newRate);

        // Get the actual mETH balance
        uint256 actualMethBalance = mockMeth.balanceOf(address(strategy));

        uint256 expectedBalanceInEth = (actualMethBalance * currentCycleRate) / 1e18;

        // Calculate ETH value before and after rate change - replicate the exact calculation in the strategy
        uint256 previousEthValue = currentCycleRate == 0
            ? actualMethBalance // 1:1 initially
            : expectedBalanceInEth;
        uint256 newEthValue = (actualMethBalance * newRate) / 1e18;

        // Profit in ETH terms
        uint256 expectedProfitInEth = newEthValue - previousEthValue;

        // Trigger harvest/report
        vm.prank(keeper);
        (profit, ) = ITokenizedStrategy(address(strategy)).report();

        // assert expected profit in eth
        assertApproxEqRel(
            expectedProfitInEth,
            (profit * IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate()) / 1e18,
            0.0000000001 ether,
            "Profit should be close to expected profit in eth"
        );

        // Update current rate for next cycle
        currentCycleRate = newRate;

        // convert profit to shares
        profitInShares = YieldBearingDragonTokenizedStrategy(address(strategy)).convertToShares(profit);

        // Return the router's new balance
        routerBalance = ITokenizedStrategy(address(strategy)).balanceOf(dragonRouter);
    }

    /**
     * @notice Test the complete flow: deposit -> harvest -> redeemYield -> redeem
     * Verifies that after all operations, the original depositor gets back their
     * initial ETH value when redeeming their shares
     */
    function testDepositHarvestRedeemFlow() public {
        // Reset state tracking variables
        currentCycleRate = 0;

        // First make sure dragon-only mode is disabled
        bool isDragonOnly = IDragonTokenizedStrategy(address(strategy)).isDragonOnly();
        if (isDragonOnly) {
            vm.prank(temps.safe);
            IDragonTokenizedStrategy(address(strategy)).toggleDragonMode(false);
        }

        // Create a separate depositor
        uint256 depositAmountDepositor = 10 ether;
        uint256 depositAmountDepositor2 = 5 ether;

        // STEP 1: DEPOSIT

        mockMeth.mint(depositor, depositAmountDepositor);
        vm.startPrank(depositor);
        mockMeth.approve(address(strategy), depositAmountDepositor);
        uint256 initialSharesDepositor = IDragonTokenizedStrategy(address(strategy)).deposit(
            depositAmountDepositor,
            depositor
        );
        vm.stopPrank();

        // first harvest pre-second deposit
        _processHarvestCycle();

        // second harvest pre-second deposit
        _processHarvestCycle();

        // STEP 2: DEPOSIT FOR DEPOSITOR2
        mockMeth.mint(depositor2, depositAmountDepositor2);
        vm.startPrank(depositor2);
        uint256 initialMethBalanceDepositor2InEth = (mockMeth.balanceOf(depositor2) *
            IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate()) / 1e18;
        mockMeth.approve(address(strategy), depositAmountDepositor2);
        uint256 initialSharesDepositor2 = IDragonTokenizedStrategy(address(strategy)).deposit(
            depositAmountDepositor2,
            depositor2
        );
        vm.stopPrank();

        // Verify depositor received shares
        assertEq(
            ITokenizedStrategy(address(strategy)).balanceOf(depositor),
            initialSharesDepositor,
            "Depositor should have received shares"
        );

        // Verify depositor2 received shares
        assertEq(
            ITokenizedStrategy(address(strategy)).balanceOf(depositor2),
            initialSharesDepositor2,
            "Depositor2 should have received shares"
        );

        // 3rd harvest post-second deposit
        _processHarvestCycle();

        // redeem dragon router shares
        vm.startPrank(dragonRouter);
        uint256 dragonRouterShares = IDragonTokenizedStrategy(address(strategy)).balanceOf(dragonRouter);
        ITokenizedStrategy(address(strategy)).redeem(dragonRouterShares, dragonRouter, dragonRouter, ZERO_BPS);
        vm.stopPrank();

        // REDEEM: despositor shares
        vm.startPrank(depositor);
        uint256 depositorShares = IDragonTokenizedStrategy(address(strategy)).balanceOf(depositor);
        uint256 depositorAssetsReceived = ITokenizedStrategy(address(strategy)).redeem(
            depositorShares,
            depositor,
            depositor,
            ZERO_BPS
        );
        vm.stopPrank();

        // redeem depositor2 shares
        vm.startPrank(depositor2);
        uint256 depositor2Shares = IDragonTokenizedStrategy(address(strategy)).balanceOf(depositor2);
        uint256 depositor2AssetsReceived = ITokenizedStrategy(address(strategy)).redeem(
            depositor2Shares,
            depositor2,
            depositor2,
            ZERO_BPS
        );
        vm.stopPrank();

        // Convert assets to ETH value using current exchange rate
        uint256 currentExchangeRate = IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate();

        uint256 depositorEthValueReceived = (depositorAssetsReceived * currentExchangeRate) / 1e18;
        uint256 depositor2EthValueReceived = (depositor2AssetsReceived * currentExchangeRate) / 1e18;

        // Verify ETH values are approximately correct (within 1% to account for rounding)
        assertApproxEqRel(
            depositorEthValueReceived,
            depositAmountDepositor,
            0.0000000001 ether, // precision of more than 10^-10
            "Depositor should receive original deposit adjusted for exchange rate"
        );
        assertApproxEqRel(
            depositor2EthValueReceived,
            initialMethBalanceDepositor2InEth,
            0.0000000001 ether, // precision of more than 10^-10
            "Depositor2 should receive original deposit adjusted for exchange rate"
        );
    }

    /**
     * @notice Test multiple harvest cycles with exchange rate changes
     */
    function testMultipleHarvestCycles() public {
        // Reset state tracking variables
        currentCycleRate = 0;

        // disable dragon-only mode
        bool isDragonOnly = IDragonTokenizedStrategy(address(strategy)).isDragonOnly();
        if (isDragonOnly) {
            vm.prank(temps.safe);
            IDragonTokenizedStrategy(address(strategy)).toggleDragonMode(false);
        }

        // STEP 1: DEPOSIT
        mockMeth.mint(depositor, 10 ether);
        vm.startPrank(depositor);
        mockMeth.approve(address(strategy), 10 ether);
        IDragonTokenizedStrategy(address(strategy)).deposit(10 ether, depositor);
        vm.stopPrank();

        // Verify initial balance
        assertEq(mockMeth.balanceOf(address(strategy)), 10 ether, "Initial balance should be 10 mETH");
        // verify initial balance in eth is 10 ether
        assertEq((10 ether * IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate()) / 1e18, 10 ether);

        // dragon router balance before should be 0
        assertEq(ITokenizedStrategy(address(strategy)).balanceOf(dragonRouter), 0, "Dragon router balance should be 0");

        // ----- CYCLE 1 -----
        _processHarvestCycle();

        // ----- CYCLE 2 -----
        _processHarvestCycle();

        // ----- CYCLE 3 -----
        (, , uint newRate, ) = _processHarvestCycle();

        // ok to calculate this way because there are no withdrawals before
        uint256 expectedProfitInEth = ((10 ether *
            IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate()) / 1e18) - 10 ether;

        // withdraw all profit
        vm.startPrank(dragonRouter);
        uint256 dragonRouterSharesAfter = IDragonTokenizedStrategy(address(strategy)).balanceOf(dragonRouter);

        uint256 methProfit = YieldBearingDragonTokenizedStrategy(address(strategy)).redeem(
            dragonRouterSharesAfter,
            dragonRouter,
            dragonRouter,
            ZERO_BPS
        );

        vm.stopPrank();

        assertApproxEqRel(
            expectedProfitInEth,
            (methProfit * newRate) / 1e18,
            0.0000000001 ether,
            "Total Profit should be close to expected profit in eth"
        );

        // should revert if he tries to withdraw initial deposit (because mETH accrued in ETH value)
        vm.startPrank(depositor);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__WithdrawMoreThanMax.selector));
        IDragonTokenizedStrategy(address(strategy)).withdraw(10 ether, depositor, depositor, ZERO_BPS);
        vm.stopPrank();

        // STEP 7: depositor withdraws 10ETH worth of mETH
        vm.startPrank(depositor);
        uint256 depositorSharesAfter = IDragonTokenizedStrategy(address(strategy)).balanceOf(depositor);
        uint256 depositorAssetsReceived = IDragonTokenizedStrategy(address(strategy)).redeem(
            depositorSharesAfter,
            depositor,
            depositor,
            ZERO_BPS
        );
        vm.stopPrank();

        // verify depositor received 10ETH worth of mETH
        uint256 currentExchangeRate = IMethYieldStrategy(address(strategy)).getLastReportedExchangeRate();
        uint256 depositorEthValueReceived = (depositorAssetsReceived * currentExchangeRate) / 1e18;

        assertApproxEqRel(
            depositorEthValueReceived,
            10 ether,
            0.0000000001 ether,
            "Depositor should have received 10 ETH"
        );
    }

    /**
     * @notice Test emergency withdrawal functionality
     */
    function testEmergencyWithdraw() public {
        // Reset state tracking variables
        currentCycleRate = 0;

        // First make sure dragon-only mode is disabled
        bool isDragonOnly = IDragonTokenizedStrategy(address(strategy)).isDragonOnly();
        if (isDragonOnly) {
            vm.prank(temps.safe);
            IDragonTokenizedStrategy(address(strategy)).toggleDragonMode(false);
        }

        // STEP 1: DEPOSIT
        mockMeth.mint(depositor, 10 ether);
        vm.startPrank(depositor);
        mockMeth.approve(address(strategy), 10 ether);
        IDragonTokenizedStrategy(address(strategy)).deposit(10 ether, depositor);
        vm.stopPrank();

        // Verify initial balance
        assertEq(mockMeth.balanceOf(address(strategy)), 10 ether, "Initial balance should be 10 mETH");

        // STEP 2: Set emergency admin
        address emergencyAdmin = makeAddr("emergencyAdmin");
        vm.prank(management);
        ITokenizedStrategy(address(strategy)).setEmergencyAdmin(emergencyAdmin);

        // Verify emergency admin was set
        assertEq(
            ITokenizedStrategy(address(strategy)).emergencyAdmin(),
            emergencyAdmin,
            "Emergency admin should be set correctly"
        );

        // STEP 3: Trigger emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(strategy)).shutdownStrategy();

        // Verify strategy is shut down
        assertTrue(ITokenizedStrategy(address(strategy)).isShutdown(), "Strategy should be shut down");

        // STEP 4: Emergency withdraw
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(strategy)).emergencyWithdraw(10 ether);

        // Verify funds were transferred to emergency admin
        assertEq(mockMeth.balanceOf(emergencyAdmin), 10 ether, "Emergency admin should have received all mETH");
        assertEq(mockMeth.balanceOf(address(strategy)), 0, "Strategy should have 0 mETH");
    }
}
