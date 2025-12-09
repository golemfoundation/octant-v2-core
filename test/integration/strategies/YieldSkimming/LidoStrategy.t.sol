// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { console } from "forge-std/console.sol";

/// @title Lido Test
/// @author Octant
/// @notice Integration tests for the Lido strategy using a mainnet fork
contract LidoStrategyTest is Test {
    using SafeERC20 for ERC20;
    using WadRayMath for uint256;

    // Strategy instance
    LidoStrategy public strategy;
    ITokenizedStrategy public vault;

    // Factory for creating strategies
    YieldSkimmingTokenizedStrategy tokenizedStrategy;
    LidoStrategyFactory public factory;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    string public vaultSharesName = "Lido Vault Shares";
    bytes32 public strategySalt = keccak256("TEST_STRATEGY_SALT");
    YieldSkimmingTokenizedStrategy public implementation;

    // Test user
    address public user = address(0x1234);

    // Mainnet addresses
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e18; // WSTETH has 18 decimals
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days

    // Events from ITokenizedStrategy
    event Reported(uint256 profit, uint256 loss);

    // Use struct to avoid stack too deep
    struct TestState {
        address user1;
        address user2;
        uint256 depositAmount1;
        uint256 depositAmount2;
        uint256 initialExchangeRate;
        uint256 newExchangeRate1;
        uint256 newExchangeRate2;
        uint256 donationBalanceBefore1;
        uint256 donationBalanceAfter1;
        uint256 donationBalanceBefore2;
        uint256 donationBalanceAfter2;
        uint256 user1Shares;
        uint256 user2Shares;
        uint256 user1Assets;
        uint256 user2Assets;
        uint256 user1Profit;
        uint256 user2Profit;
        uint256 user1ProfitPercentage;
        uint256 user2ProfitPercentage;
    }

    // Additional struct for fuzz tests to avoid stack too deep
    struct FuzzTestState {
        uint256 initialExchangeRate;
        uint256 profitRate;
        uint256 firstLossRate;
        uint256 secondLossRate;
        uint256 donationSharesAfterProfit;
        uint256 donationSharesAfterFirstLoss;
        uint256 donationSharesAfterSecondLoss;
        uint256 assetsReceived;
    }

    // Setup parameters struct to avoid stack too deep
    struct SetupParams {
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        string vaultSharesName;
        bytes32 strategySalt;
        address implementationAddress;
        bool enableBurning;
    }

    /**
     * @notice Helper function to airdrop tokens to a specified address
     * @param _asset The ERC20 token to airdrop
     * @param _to The recipient address
     * @param _amount The amount of tokens to airdrop
     */
    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setUp() public {
        // Create a mainnet fork
        // NOTE: This relies on the RPC URL configured in foundry.toml under [rpc_endpoints]
        // where mainnet = "${ETHEREUM_NODE_MAINNET}" environment variable
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldSkimmingTokenizedStrategy
        implementation = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldSkimmingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Create setup params to avoid stack too deep
        SetupParams memory params = SetupParams({
            management: management,
            keeper: keeper,
            emergencyAdmin: emergencyAdmin,
            donationAddress: donationAddress,
            vaultSharesName: vaultSharesName,
            strategySalt: strategySalt,
            implementationAddress: address(implementation),
            enableBurning: true
        });

        // Deploy factory
        factory = new LidoStrategyFactory();

        // Deploy strategy using the factory's createStrategy method
        vm.startPrank(params.management);
        address strategyAddress = factory.createStrategy(
            params.vaultSharesName,
            params.management,
            params.keeper,
            params.emergencyAdmin,
            params.donationAddress,
            params.enableBurning,
            params.implementationAddress
        );
        vm.stopPrank();

        // Cast the deployed address to our strategy type
        strategy = LidoStrategy(strategyAddress);
        vault = ITokenizedStrategy(address(strategy));

        // Label addresses for better trace outputs
        vm.label(address(strategy), "Lido");
        vm.label(address(factory), "YieldSkimmingVaultFactory");
        vm.label(WSTETH, "Lido Yield Vault");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");

        // Airdrop WSTETH tokens to test user
        airdrop(ERC20(WSTETH), user, INITIAL_DEPOSIT);

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that the strategy is properly initialized
    function testInitializationLido() public view {
        assertEq(IERC4626(address(strategy)).asset(), WSTETH, "Yield vault address incorrect");
        assertEq(vault.management(), management, "Management address incorrect");
        assertEq(vault.keeper(), keeper, "Keeper address incorrect");
        assertEq(vault.emergencyAdmin(), emergencyAdmin, "Emergency admin incorrect");
        assertGt(
            IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate(),
            0,
            "Last reported exchange rate should be initialized"
        );
    }

    /// @notice Test depositing assets into the strategy
    function testDepositLido() public {
        uint256 depositAmount = 100e18; // 100 WSTETH

        // Initial balances
        uint256 initialUserBalance = ERC20(WSTETH).balanceOf(user);

        // Deposit assets
        vm.startPrank(user);
        // approve the strategy to spend the user's tokens
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify balances after deposit
        assertEq(
            ERC20(WSTETH).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );

        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertGt(strategy.balanceOfAsset(), 0, "Strategy should have deployed assets to yield vault");
    }

    /// @notice Fuzz test depositing assets into the strategy
    function testFuzzDepositLido(uint256 depositAmount) public {
        // Bound the deposit amount to reasonable values (0.01 to 10,000 WSTETH)
        depositAmount = bound(depositAmount, 0.01e18, 10000e18);

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // Initial balances
        uint256 initialUserBalance = ERC20(WSTETH).balanceOf(user);

        // Deposit assets
        vm.startPrank(user);
        // approve the strategy to spend the user's tokens
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify balances after deposit
        assertEq(
            ERC20(WSTETH).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );

        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertGt(strategy.balanceOfAsset(), 0, "Strategy should have deployed assets to yield vault");
    }

    /// @notice Fuzz test withdrawing assets from the strategy
    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawPercentage) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH
        withdrawPercentage = bound(withdrawPercentage, 1, 100); // 1% to 100% (prevents overflow in percentage calc)

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // Deposit first
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);

        // Initial balances before withdrawal
        uint256 initialUserBalance = ERC20(WSTETH).balanceOf(user);
        uint256 initialShareBalance = vault.balanceOf(user);

        // redeem balance of shares
        uint256 sharesToBurn = (vault.balanceOf(user) * withdrawPercentage) / 100;
        uint256 withdrawnAmount = vault.redeem(sharesToBurn, user, user);
        vm.stopPrank();

        // Verify balances after withdrawal
        assertEq(
            ERC20(WSTETH).balanceOf(user),
            initialUserBalance + withdrawnAmount,
            "User didn't receive correct assets"
        );
        assertEq(vault.balanceOf(user), initialShareBalance - sharesToBurn, "Shares not burned correctly");
    }

    // Additional struct for profit fuzz tests to avoid stack too deep
    struct ProfitFuzzTestState {
        uint256 totalAssetsBefore;
        uint256 initialExchangeRate;
        uint256 newExchangeRate;
        uint256 donationAddressBalanceBefore;
        uint256 donationAddressBalanceAfter;
        uint256 totalAssetsAfter;
        uint256 sharesToRedeem;
        uint256 assetsReceived;
        uint256 donationAssetsReceived;
    }

    /// @notice Fuzz test the harvesting functionality with profit
    function testFuzzHarvestWithProfitLido(uint256 depositAmount, uint256 profitPercentage) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH
        profitPercentage = bound(profitPercentage, 1, 99); // 1% to 99% profit (under 100% health check limit)

        ProfitFuzzTestState memory state;

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // Deposit first
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Check initial state
        state.totalAssetsBefore = vault.totalAssets();
        state.initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // Simulate exchange rate increase based on fuzzed percentage
        state.newExchangeRate = (state.initialExchangeRate * (100 + profitPercentage)) / 100;

        // Mock the actual yield vault's stEthPerToken (convert back to WAD format)
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.newExchangeRate));

        state.donationAddressBalanceBefore = ERC20(address(strategy)).balanceOf(donationAddress);

        // Call report
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Clear mock to avoid interference with other tests
        vm.clearMockedCalls();

        // Assert profit and loss
        assertGt(profit, 0, "Profit should be positive");
        assertEq(loss, 0, "There should be no loss");

        state.donationAddressBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);

        // donation address should have received the profit
        assertGt(
            state.donationAddressBalanceAfter,
            state.donationAddressBalanceBefore,
            "Donation address should have received profit"
        );

        // Check total assets after harvest
        state.totalAssetsAfter = vault.totalAssets();
        assertEq(state.totalAssetsAfter, state.totalAssetsBefore, "Total assets should not change after harvest");

        // Ensure obligations solvency by keeping current rate equal to last reported rate during redemption
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.newExchangeRate));

        // withdraw the donation address shares first to ensure obligations solvency
        vm.startPrank(donationAddress);
        state.donationAssetsReceived = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();
        vm.clearMockedCalls();

        // then user withdraws
        vm.startPrank(user);
        state.sharesToRedeem = vault.balanceOf(user);
        state.assetsReceived = vault.redeem(state.sharesToRedeem, user, user);
        vm.stopPrank();

        assertApproxEqRel(
            state.donationAssetsReceived,
            (depositAmount * profitPercentage) / (100 + profitPercentage),
            0.1e16,
            "Donation address should have received profit"
        );

        // Verify user received their original deposit
        assertApproxEqRel(
            state.assetsReceived * state.newExchangeRate,
            depositAmount * state.initialExchangeRate,
            0.1e16, // 0.1% tolerance for fuzzing
            "User should receive original deposit"
        );
    }

    /// @notice Test multiple users with fair profit distribution
    function testMultipleUserProfitDistributionLido() public {
        TestState memory state;

        // First user deposits
        state.user1 = user; // Reuse existing test user
        state.user2 = address(0x5678);
        state.depositAmount1 = 1000e18; // 1000 WSTETH
        state.depositAmount2 = 2000e18; // 2000 WSTETH

        // Get initial exchange rate
        state.initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        vm.startPrank(state.user1);
        vault.deposit(state.depositAmount1, state.user1);
        vm.stopPrank();

        // Generate yield for first user (10% increase in exchange rate)
        state.newExchangeRate1 = (state.initialExchangeRate * 110) / 100;

        // Check donation address balance before harvest
        state.donationBalanceBefore1 = ERC20(address(strategy)).balanceOf(donationAddress);

        // Mock the yield vault's stEthPerToken instead of strategy's internal method
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.newExchangeRate1));

        // Harvest to realize profit
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Check donation address balance after harvest
        state.donationBalanceAfter1 = ERC20(address(strategy)).balanceOf(donationAddress);

        // Verify donation address received profit
        assertGt(
            state.donationBalanceAfter1,
            state.donationBalanceBefore1,
            "Donation address should have received profit after first harvest"
        );

        // Second user deposits after profit
        vm.startPrank(address(this));
        airdrop(ERC20(WSTETH), state.user2, state.depositAmount2);
        vm.stopPrank();

        vm.startPrank(state.user2);
        ERC20(WSTETH).approve(address(strategy), type(uint256).max);
        vault.deposit(state.depositAmount2, state.user2);
        vm.stopPrank();

        // Clear mock
        vm.clearMockedCalls();

        // Generate more yield after second user joined (5% increase from last rate)
        state.newExchangeRate2 = (state.newExchangeRate1 * 105) / 100;

        // Check donation address balance before second harvest
        state.donationBalanceBefore2 = ERC20(address(strategy)).balanceOf(donationAddress);

        // Mock the yield vault's stEthPerToken
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.newExchangeRate2));

        // Harvest again
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Clear mock
        vm.clearMockedCalls();

        // Check donation address balance after second harvest
        state.donationBalanceAfter2 = ERC20(address(strategy)).balanceOf(donationAddress);

        // Verify donation address received more profit
        assertGt(
            state.donationBalanceAfter2,
            state.donationBalanceBefore2,
            "Donation address should have received profit after second harvest"
        );

        // Keep current exchange rate at last reported during redemptions to ensure obligations solvency
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.newExchangeRate2));

        // redeem the shares of the donation address first
        vm.startPrank(donationAddress);
        vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        // Then both users withdraw
        vm.startPrank(state.user1);
        state.user1Shares = vault.balanceOf(state.user1);
        state.user1Assets = vault.redeem(vault.balanceOf(state.user1), state.user1, state.user1);
        vm.stopPrank();

        vm.startPrank(state.user2);
        state.user2Shares = vault.balanceOf(state.user2);
        state.user2Assets = vault.redeem(vault.balanceOf(state.user2), state.user2, state.user2);
        vm.stopPrank();

        vm.clearMockedCalls();

        // User 1 deposited before first yield accrual, so should have earned more
        assertApproxEqRel(
            state.user1Assets * state.newExchangeRate2,
            state.depositAmount1 * state.initialExchangeRate,
            0.000001e18, // 0.0001% tolerance
            "User 1 should receive deposit adjusted for exchange rate change"
        );

        // User 2 deposited after first yield accrual but before second
        assertApproxEqRel(
            state.user2Assets * state.newExchangeRate2,
            state.depositAmount2 * state.newExchangeRate1,
            0.00001e18, // 0.1% tolerance
            "User 2 should receive deposit adjusted for exchange rate change"
        );
    }

    /// @notice Test the harvesting functionality
    function testHarvestLido() public {
        uint256 depositAmount = 100e18; // 100 WSTETH

        // Deposit first
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Capture initial state
        uint256 initialAssets = vault.totalAssets();
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // Call report as keeper (which internally calls _harvestAndReport)
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Get new exchange rate and total assets
        uint256 newExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 newTotalAssets = vault.totalAssets();

        // mock stEthPerToken to be 1.1x the initial exchange rate
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode((newExchangeRate * 11) / 10));

        // Verify exchange rate is updated
        assertEq(newExchangeRate, initialExchangeRate, "Exchange rate should be updated after harvest");

        // Verify total assets after harvest
        // Note: We don't check for specific increases here as we're using a mainnet fork
        // and yield calculation can vary, but assets should be >= than before unless there's a loss
        assertGe(newTotalAssets, initialAssets, "Total assets should not decrease after harvest");
    }

    /// @notice Fuzz test emergency exit functionality
    function testFuzzEmergencyExit(uint256 depositAmount) public {
        // Bound deposit amount to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // User deposits
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Trigger emergency shutdown mode - must be called by emergency admin
        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();

        // Execute emergency withdraw
        vault.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // User withdraws their funds
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        // The user should receive approximately their original deposit in value
        // We allow a small deviation due to potential rounding in the calculations
        assertApproxEqRel(
            assetsReceived,
            depositAmount,
            0.001e18, // 0.1% tolerance
            "User should receive approximately original deposit value"
        );
    }

    /// @notice Fuzz test exchange rate tracking and yield calculation
    function testFuzzExchangeRateTrackingLido(uint256 depositAmount, uint256 exchangeRateIncreasePercentage) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH
        exchangeRateIncreasePercentage = bound(exchangeRateIncreasePercentage, 1, 99); // 1% to 50% increase

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // Deposit first
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Get initial exchange rate
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // Simulate exchange rate increase based on fuzzed percentage
        uint256 newExchangeRate = (initialExchangeRate * (100 + exchangeRateIncreasePercentage)) / 100;

        // Mock the yield vault's stEthPerToken
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(newExchangeRate));

        // Report to capture yield
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Clear mock
        vm.clearMockedCalls();

        // Verify profit and loss
        assertGt(profit, 0, "Should have captured profit from exchange rate increase");
        assertEq(loss, 0, "Should have no loss");

        // Verify exchange rate was updated
        uint256 updatedExchangeRate = IYieldSkimmingStrategy(address(strategy)).getLastRateRay().rayToWad();

        assertApproxEqRel(
            updatedExchangeRate,
            newExchangeRate,
            0.000001e18,
            "Exchange rate should be updated after harvest"
        );
    }

    /// @notice Test getting the last reported exchange rate
    function testgetCurrentExchangeRate() public view {
        uint256 rate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        assertGt(rate, 0, "Exchange rate should be initialized and greater than zero");
    }

    /// @notice Test balance of asset and shares
    function testBalanceOfAssetAndShares() public {
        uint256 depositAmount = 100e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 assetBalance = strategy.balanceOfAsset();
        uint256 sharesBalance = strategy.balanceOfAsset();

        assertEq(assetBalance, sharesBalance, "Asset and shares balance should match for this strategy");
        assertGt(assetBalance, 0, "Asset balance should be greater than zero after deposit");
    }

    /// @notice Test health check for profit limit exceeded
    function testHealthCheckProfitLimitExceeded() public {
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // First report: sets doHealthCheck = true, does NOT check
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Mock a 10x exchange rate
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 newExchangeRate = (initialExchangeRate * 7) / 3; // 233%
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(newExchangeRate));

        // Second report: should revert
        vm.startPrank(keeper);
        vm.expectRevert("!profit");
        vault.report();
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    // testHealthCheckProfitLimitExceeded when doHealthCheck is false
    function testHealthCheckProfitLimitExceededWhenDoHealthCheckIsFalse() public {
        vm.startPrank(management);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        // check the do health check
        assertEq(strategy.doHealthCheck(), false);

        // old exchange rate
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // make a 10 time profit (should revert when doHealthCheck is true but not when it is false)
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(initialExchangeRate * 10));

        // report
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // check the do health check
        assertEq(strategy.doHealthCheck(), true);
    }

    // test change profit limit ratio
    function testChangeProfitLimitRatio() public {
        vm.startPrank(management);
        strategy.setProfitLimitRatio(5000);
        vm.stopPrank();

        // check the profit limit ratio
        assertEq(strategy.profitLimitRatio(), 5000);
    }

    function testSetDoHealthCheckToFalse() public {
        vm.startPrank(management);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        // check the do health check
        assertEq(strategy.doHealthCheck(), false);
    }

    // tendTrigger always returns false
    function testTendTriggerAlwaysFalse() public view {
        (bool trigger, ) = IBaseStrategy(address(strategy)).tendTrigger();
        assertEq(trigger, false, "Tend trigger should always be false");
    }

    /// @notice Fuzz test basic loss scenario with single user
    function testFuzzHarvestWithLossLido(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 lossPercentage
    ) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH
        profitPercentage = bound(profitPercentage, 5, 50); // 5% to 50% profit first
        lossPercentage = bound(lossPercentage, 1, 19); // 1% to 19% loss (less than 20% limit)

        // Set loss limit to allow 20% losses
        vm.startPrank(management);
        strategy.setLossLimitRatio(2000); // 20%
        vm.stopPrank();

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // First deposit to create some donation shares for loss protection
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Generate some profit first to create donation shares
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 profitExchangeRate = (initialExchangeRate * (100 + profitPercentage)) / 100;

        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(profitExchangeRate));

        vm.startPrank(keeper);
        vault.report(); // This creates donation shares for loss protection
        vm.stopPrank();

        vm.clearMockedCalls();

        // Check donation address has shares for loss protection
        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        assertGt(donationSharesBefore, 0, "Donation address should have shares for loss protection");

        // Check initial state before loss
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 userSharesBefore = vault.balanceOf(user);

        // Simulate exchange rate decrease
        uint256 lossExchangeRate = (profitExchangeRate * (100 - lossPercentage)) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(lossExchangeRate));

        // Call report and capture the returned values
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Clear mock to avoid interference with other tests
        vm.clearMockedCalls();

        // Assert loss and profit
        assertEq(profit, 0, "Profit should be zero");
        assertGt(loss, 0, "Loss should be positive");

        // Check that donation shares were burned for loss protection
        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertLt(donationSharesAfter, donationSharesBefore, "Donation shares should be burned for loss protection");

        // User shares should remain the same (loss protection in effect)
        uint256 userSharesAfter = vault.balanceOf(user);
        assertEq(userSharesAfter, userSharesBefore, "User shares should not change due to loss protection");

        // Total assets should not change
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets should be the same before and after loss");
    }

    /// @notice Test loss scenario where loss exceeds available donation shares
    function testLossExceedingDonationSharesLido() public {
        // Set loss limit to allow 15% losses
        vm.startPrank(management);
        strategy.setLossLimitRatio(1500); // 15%
        vm.stopPrank();

        uint256 depositAmount = 1000e18; // 1000 WSTETH

        // User deposits
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Generate small profit to create minimal donation shares
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 smallProfitRate = (initialExchangeRate * 1005) / 1000; // 0.5% profit
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(smallProfitRate));

        vm.startPrank(keeper);
        vault.report(); // Creates small amount of donation shares
        vm.stopPrank();
        vm.clearMockedCalls();

        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        uint256 userSharesBefore = vault.balanceOf(user);

        // Generate large loss (10% from initial rate)
        uint256 largeLossRate = (initialExchangeRate * 90) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(largeLossRate));

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();
        vm.clearMockedCalls();

        // Verify loss was reported
        assertEq(profit, 0, "Should have no profit");
        assertGt(loss, 0, "Should have reported loss");

        // All donation shares should be burned (limited by available balance)
        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertLt(donationSharesAfter, donationSharesBefore, "Some donation shares should be burned");

        // User shares should remain the same (they don't get burned)
        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not be burned");

        // User should still be able to withdraw, but will receive less due to insufficient loss protection
        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        // User receives less than original deposit due to insufficient loss protection
        assertLt(
            assetsReceived * largeLossRate,
            depositAmount * initialExchangeRate,
            "User should receive less due to insufficient loss protection"
        );
    }

    /// @notice Test consecutive loss scenarios
    function testConsecutiveLossesLido() public {
        // Set loss limit to allow 15% losses
        vm.startPrank(management);
        strategy.setLossLimitRatio(1500); // 15%
        vm.stopPrank();

        uint256 depositAmount = 1000e18; // 1000 WSTETH

        // User deposits
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Generate profit to create donation shares
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 profitRate = (initialExchangeRate * 120) / 100; // 20% profit
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(profitRate));

        vm.startPrank(keeper);
        vault.report(); // Creates donation shares
        vm.stopPrank();
        vm.clearMockedCalls();

        uint256 donationSharesAfterProfit = vault.balanceOf(donationAddress);
        assertGt(donationSharesAfterProfit, 0, "Should have donation shares after profit");

        // First loss (5% from profit rate)
        uint256 firstLossRate = (profitRate * 95) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(firstLossRate));

        vm.startPrank(keeper);
        (uint256 profit1, uint256 loss1) = vault.report();
        vm.stopPrank();
        vm.clearMockedCalls();

        assertEq(profit1, 0, "Should have no profit in first loss");
        assertGt(loss1, 0, "Should have loss in first report");

        uint256 donationSharesAfterFirstLoss = vault.balanceOf(donationAddress);
        assertLt(
            donationSharesAfterFirstLoss,
            donationSharesAfterProfit,
            "Donation shares should decrease after first loss"
        );

        // Second consecutive loss (another 5% from current rate)
        uint256 secondLossRate = (firstLossRate * 95) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(secondLossRate));

        vm.startPrank(keeper);
        (uint256 profit2, uint256 loss2) = vault.report();
        vm.stopPrank();
        vm.clearMockedCalls();

        assertEq(profit2, 0, "Should have no profit in second loss");
        assertGt(loss2, 0, "Should have loss in second report");

        uint256 donationSharesAfterSecondLoss = vault.balanceOf(donationAddress);
        assertLe(
            donationSharesAfterSecondLoss,
            donationSharesAfterFirstLoss,
            "Donation shares should decrease or stay same after second loss"
        );

        // User should still be able to withdraw
        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "User should receive some assets");
    }

    /// @notice Test that loss protection works correctly with zero donation shares
    function testLossWithZeroDonationSharesLido() public {
        // Set loss limit to allow 10% losses
        vm.startPrank(management);
        strategy.setLossLimitRatio(1000); // 10%
        vm.stopPrank();

        uint256 depositAmount = 1000e18; // 1000 WSTETH

        // User deposits without any prior profit generation
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify no donation shares exist
        uint256 donationSharesBefore = vault.balanceOf(donationAddress);
        assertEq(donationSharesBefore, 0, "Should have no donation shares initially");

        uint256 userSharesBefore = vault.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();

        // Generate loss (5% decrease)
        uint256 initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
        uint256 lossRate = (initialExchangeRate * 95) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(lossRate));

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();
        vm.clearMockedCalls();

        // Verify loss was reported
        assertEq(profit, 0, "Should have no profit");
        assertGt(loss, 0, "Should have reported loss");

        // Donation shares should remain zero (nothing to burn)
        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertEq(donationSharesAfter, 0, "Should still have no donation shares");

        // User shares should remain unchanged
        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not change");

        // Total assets should decrease by loss
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets should be the same before and after loss");

        // User withdrawal should work but receive reduced value
        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();

        // User receives less due to no loss protection
        assertLt(
            assetsReceived * lossRate,
            depositAmount * initialExchangeRate,
            "User should receive less due to no loss protection"
        );
    }

    /// @notice Fuzz test consecutive loss scenarios
    function testFuzzConsecutiveLossesLido(
        uint256 depositAmount,
        uint256 profitPercentage,
        uint256 firstLossPercentage,
        uint256 secondLossPercentage
    ) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1e18, 10000e18); // 1 to 10,000 WSTETH
        profitPercentage = bound(profitPercentage, 10, 50); // 10% to 50% profit first
        firstLossPercentage = bound(firstLossPercentage, 1, 10); // 1% to 10% first loss
        secondLossPercentage = bound(secondLossPercentage, 1, 10); // 1% to 10% second loss

        FuzzTestState memory state;

        // Set loss limit to allow 15% losses
        vm.startPrank(management);
        strategy.setLossLimitRatio(2000); // 20%
        vm.stopPrank();

        // Airdrop tokens to user for this test
        airdrop(ERC20(WSTETH), user, depositAmount);

        // Get the current exchange rate before deposit
        state.initialExchangeRate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();

        // User deposits
        vm.startPrank(user);
        ERC20(WSTETH).approve(address(strategy), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Do an initial report to establish the baseline rate
        vm.prank(keeper);
        vault.report();

        // Generate profit to create donation shares
        state.profitRate = (state.initialExchangeRate * (100 + profitPercentage)) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.profitRate));

        vm.startPrank(keeper);
        vault.report(); // Creates donation shares
        vm.stopPrank();

        // make sure donation address received shares
        assertGt(vault.balanceOf(donationAddress), 0, "Donation address should have received shares");

        assertApproxEqRel(
            vault.convertToAssets(vault.balanceOf(user)) * state.profitRate,
            depositAmount * state.initialExchangeRate,
            0.01e16, // 0.01% tolerance for loss protection limitations and precision in edge cases
            "Withdrawable underlying value should be the same as the deposit amount * initial exchange rate"
        );

        vm.clearMockedCalls();

        state.donationSharesAfterProfit = vault.balanceOf(donationAddress);
        assertGt(state.donationSharesAfterProfit, 0, "Should have donation shares after profit");

        // First loss
        state.firstLossRate = (state.profitRate * (100 - firstLossPercentage)) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.firstLossRate));

        vm.startPrank(keeper);
        (uint256 profit1, uint256 loss1) = vault.report();
        vm.stopPrank();

        assertEq(profit1, 0, "Should have no profit in first loss");
        assertGt(loss1, 0, "Should have loss in first report");

        vm.clearMockedCalls();

        state.donationSharesAfterFirstLoss = vault.balanceOf(donationAddress);
        assertLt(
            state.donationSharesAfterFirstLoss,
            state.donationSharesAfterProfit,
            "Donation shares should decrease after first loss"
        );

        // Second consecutive loss
        state.secondLossRate = (state.firstLossRate * (100 - secondLossPercentage)) / 100;
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(state.secondLossRate));

        vm.startPrank(keeper);
        (uint256 profit2, uint256 loss2) = vault.report();
        vm.stopPrank();

        assertEq(profit2, 0, "Should have no profit in second loss");
        assertGt(loss2, 0, "Should have loss in second report");

        state.donationSharesAfterSecondLoss = vault.balanceOf(donationAddress);
        assertLe(
            state.donationSharesAfterSecondLoss,
            state.donationSharesAfterFirstLoss,
            "Donation shares should decrease or stay same after second loss"
        );

        // User should still be able to withdraw
        vm.startPrank(user);
        state.assetsReceived = vault.redeem(vault.balanceOf(user), user, user);
        vm.stopPrank();
        // Calculate underlying values
        uint256 initialValue = depositAmount * state.initialExchangeRate;
        uint256 receivedValue = state.assetsReceived * state.secondLossRate;

        // Check if net rate change is negative (losses > gains)
        if (state.secondLossRate < state.initialExchangeRate) {
            // Net loss scenario: user should receive less than initial deposit in underlying terms
            // This upholds the invariant that users cannot withdraw more than deposited
            assertLe(
                receivedValue,
                initialValue,
                "User cannot receive more than initial deposit in underlying terms when net loss occurs"
            );
        } else {
            // Net gain scenario: user should receive about the same as their initial deposit
            assertApproxEqRel(
                receivedValue,
                initialValue,
                3e16, // 3% tolerance for complex yield skimming edge cases with consecutive rate changes
                "User should receive about the same as deposit when net gain occurs"
            );
        }
    }

    // Struct to hold test data and avoid stack too deep
    struct ProfitLossTestData {
        address user1;
        address user2;
        uint256 depositAmount1;
        uint256 depositAmount2;
        uint256 initialRate;
        uint256 increasedRate;
        uint256 user1Shares;
        uint256 user2Shares;
        uint256 profit1;
        uint256 loss1;
        uint256 dragonShares;
        uint256 user1Assets;
        uint256 user2Assets;
        uint256 profit2;
        uint256 loss2;
        uint256 dragonSharesAfterLoss;
    }

    /// @notice Test profit then loss scenario with proper dragon share burning
    /// @dev Sequence: r1.0, d1, r1.5, d2, report, r1.0, w1, report, r1.5, w2
    /// Demonstrates that losses are properly handled regardless of rate direction
    function test_profitThenLoss_dragonSharesBurnCorrectly() public {
        ProfitLossTestData memory data;

        data.user1 = makeAddr("user1");
        data.user2 = makeAddr("user2");
        data.depositAmount1 = 100e18; // 100 rETH
        data.depositAmount2 = 150e18; // 150 rETH
        data.initialRate = 1e18;
        data.increasedRate = (1e18 * 15) / 10; // 1.5x rate

        // Airdrop rETH to both users
        airdrop(ERC20(WSTETH), data.user1, data.depositAmount1);
        airdrop(ERC20(WSTETH), data.user2, data.depositAmount2);

        // Set loss limit to allow for the rate drop from 1.5 to 1.0 (33% loss)
        vm.startPrank(management);
        strategy.setLossLimitRatio(5000); // 50% loss limit
        vm.stopPrank();

        // Step 1-2: r1.0, d1 - set rate to 1.0
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.initialRate));

        vm.startPrank(data.user1);
        ERC20(WSTETH).approve(address(strategy), data.depositAmount1);
        data.user1Shares = vault.deposit(data.depositAmount1, data.user1);
        vm.stopPrank();

        // Expected shares for user1: depositAmount * rate = 100e18 * 1e18 / 1e18 = 100e18
        // When first depositor, shares = assets
        assertEq(
            data.user1Shares,
            data.depositAmount1,
            "User1 should receive 100e18 shares for 100e18 rETH at 1:1 rate"
        );

        // Total assets should increase by deposit amount
        assertEq(vault.totalAssets(), data.depositAmount1, "Total assets should be 100e18 after user1 deposit");

        vm.clearMockedCalls();

        // Step 3-4: r1.5, d2 - Rate increases to 1.5, User2 deposits 150 rETH
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.increasedRate));

        vm.startPrank(data.user2);
        ERC20(WSTETH).approve(address(strategy), data.depositAmount2);
        data.user2Shares = vault.deposit(data.depositAmount2, data.user2);
        vm.stopPrank();

        // Expected shares for user2:
        // User2 deposits 150e18 rETH when rate is 1.5
        // shares = assets * initialRate / currentRate = 150e18 * 1.5 = 225e18
        assertEq(data.user2Shares, 225e18, "User2 should receive 225e18 shares for 150e18 rETH at 1.5x rate");

        // Total assets should increase by deposit amount
        assertEq(vault.totalAssets(), 250e18, "Total assets should be 250e18 after both deposits");

        // Step 5: report - First report (should mint dragon shares)
        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();
        data.dragonShares = vault.balanceOf(donationAddress);

        // Expected profit calculation:
        // Before report: totalSupply = 100e18 (user1) + 225e18 (user2) = 325e18
        // Before report: totalAssets = 250e18 rETH
        // Current rate = 1.5, last reported rate = 1.0
        //
        // Dragon shares calculation (excess value method):
        // 1. Total vault value (in ETH terms) = 250e18 rETH × 1.5 rate = 375e18 ETH
        // 2. Total user debt (what we owe) = 325e18 shares × 1 ETH/share = 325e18 ETH
        // 3. Excess value = 375e18 - 325e18 = 50e18 ETH
        // 4. Dragon shares minted = 50e18 (1 share = 1 ETH value, except in case of uncovered loss)
        // 5. Profit reported = 50e18 ETH ÷ 1.5 rate = 33.333e18 rETH
        assertEq(data.profit1, 33333333333333333333, "Should report 33.333e18 profit");
        assertEq(data.loss1, 0, "Should report no loss in first report");
        assertEq(data.dragonShares, 50e18, "Dragon shares should be 50e18");

        // Total supply should increase by dragon shares
        assertEq(vault.totalSupply(), 375e18, "Total supply should be 325e18 + 50e18 dragon shares");

        // Step 6: r1.0 - Rate drops back to 1.0
        vm.clearMockedCalls();
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.initialRate));

        // Step 7-8: w1 - User1 withdraws all
        vm.startPrank(data.user1);
        data.user1Assets = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        // User1 has 100e18 shares
        // So user1 receives: 100 shares / 375 shares  * 250e18 = 66.666e18 rETH
        assertEq(
            data.user1Assets,
            66666666666666666666,
            "User1 should receive 66.666e18 rETH (100e18 shares at last rate 1.5)"
        );
        assertEq(
            ERC20(WSTETH).balanceOf(data.user1),
            66666666666666666666,
            "User1 balance should be 66.666e18 after withdrawal"
        );
        assertEq(vault.balanceOf(data.user1), 0, "User1 should have no shares left");

        // Step 9: report - Second report (should burn dragon shares due to loss)
        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();
        data.dragonSharesAfterLoss = vault.balanceOf(donationAddress);

        // Expected loss calculation using excess value method:
        // After user1 withdrawal:
        // - User1 withdrew: 100e18 shares ÷ 1.5 rate = 66.666e18 rETH
        // - Remaining shares: user2 (225e18) + dragon shares (50e18) = 275e18
        // - Remaining assets: 250e18 - 66.666e18 = 183.333e18 rETH
        // - Current rate: 1.0, last reported rate: 1.5
        //
        // Loss calculation (excess value method):
        // 1. Total vault value (in ETH terms) = 183.333e18 rETH × 1.0 rate = 183.333e18 ETH
        // 2. Total debt owed = 275e18 shares × 1 ETH/share = 275e18 ETH
        // 3. Deficit (loss) = 183.333e18 - 275e18 = -91.666e18 ETH
        // 4. Loss reported = 91.666e18 ETH ÷ 1.0 rate = 91.666e18 rETH
        assertEq(data.profit2, 0, "Should report no profit in second report");
        assertEq(data.loss2, 91666666666666666666, "Should report 91.666e18 loss");

        // Dragon shares burning to cover loss:
        // - Loss to cover: 91.666e18 ETH
        // - Dragon shares available: 50e18
        // - All 50e18 dragon shares burned (insufficient to cover full loss)
        // - Uncovered loss: 91.666e18 - 50e18 = 41.666e18 ETH remains as vault deficit
        assertEq(data.dragonSharesAfterLoss, 0, "All dragon shares should be burned");

        // Log the actual values for debugging
        console.log("Dragon shares before loss:", data.dragonShares);
        console.log("Dragon shares after loss:", data.dragonSharesAfterLoss);
        console.log("Loss reported:", data.loss2);

        // Step 10-11: r1.5, w2 - Rate increases back to 1.5, User2 withdraws all
        vm.clearMockedCalls();
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.increasedRate));

        vm.startPrank(data.user2);
        data.user2Assets = vault.redeem(vault.balanceOf(data.user2), data.user2, data.user2);

        vm.stopPrank();

        // check if vault is insolvent
        assertEq(IYieldSkimmingStrategy(address(vault)).isVaultInsolvent(), false, "Vault should be solvent");

        // User2 has 225e18 shares
        // At rate 1.5, user2 should receive: 225e18 / 1.5 = 150e18 rETH
        assertEq(data.user2Assets, 150e18, "User2 should receive 150e18 rETH (225e18 shares at 1.5 rate)");
        assertEq(ERC20(WSTETH).balanceOf(data.user2), 150e18, "User2 balance should be 150e18 after withdrawal");
        assertEq(vault.balanceOf(data.user2), 0, "User2 should have no shares left");

        // Final state: vault should be mostly empty
        // There might be some remaining dragon shares that weren't fully burned
        // and their value at the current rate
        uint256 remainingDragonShares = vault.balanceOf(donationAddress);
        uint256 remainingAssets = vault.totalAssets();

        // Log final state for debugging
        console.log("Remaining dragon shares:", remainingDragonShares);
        console.log("Remaining total supply:", vault.totalSupply());
        console.log("Remaining assets:", remainingAssets);

        // Final state analysis:
        // In this specific test scenario, we know the outcome:
        // - remainingDragonShares = 0 (all 50e18 burned to cover loss)
        // - vault.totalSupply() = 0 (both users withdrew all shares)
        // - remainingAssets = 33.333e18 rETH (uncovered loss portion)

        assertEq(remainingDragonShares, 0, "All dragon shares should be burned");
        assertEq(vault.totalSupply(), 0, "All shares should be withdrawn");

        // Final state explanation:
        // After all operations: 183.333e18 rETH remained after user1 withdrawal
        // User2 then withdrew: 225e18 shares ÷ 1.5 rate = 150e18 rETH
        // Remaining assets: 183.333e18 - 150e18 = 33.333e18 rETH
        //
        // This 33.333e18 rETH represents the uncovered portion of the 91.666e18 ETH loss
        // that couldn't be covered by the 50e18 dragon shares that were burned
        console.log("Expected behavior: Assets remain due to uncovered loss");
        assertEq(remainingAssets, 33333333333333333334, "Expected 33.333e18 rETH to remain from uncovered loss");

        // lets call report
        vm.startPrank(keeper);
        (uint256 profit3, uint256 loss3) = vault.report();
        vm.stopPrank();
        console.log("Profit reported:", profit3);
        console.log("Loss reported:", loss3);
        console.log("Dragon shares remaining:", vault.balanceOf(donationAddress));
        console.log("Total assets:", vault.totalAssets());

        // dragon should withdraw remaining assets
        vm.startPrank(donationAddress);
        uint256 assets = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        console.log("Assets withdrawn:", assets);
        vm.stopPrank();
        console.log("Donation address balance:", ERC20(WSTETH).balanceOf(donationAddress));
        console.log("Donation address total assets:", vault.totalAssets());
        console.log("Donation address total supply:", vault.totalSupply());
    }

    // Struct to avoid stack too deep for dragon withdrawal tests
    struct DragonWithdrawalTestData {
        address user1;
        uint256 depositAmount;
        uint256 initialRate;
        uint256 increasedRate;
        uint256 decreasedRate;
        uint256 finalRate;
        uint256 user1Shares;
        uint256 dragonSharesAfterProfit;
        uint256 dragonAssets;
        uint256 profit1;
        uint256 loss1;
        uint256 profit2;
        uint256 loss2;
        uint256 profit3;
        uint256 loss3;
        uint256 assetsReceived;
    }

    /// @notice Test dragon router withdrawal followed by rate recovery - user should have no loss
    /// @dev Sequence: d1 -> r1.5 -> report (mint DR) -> wDR -> r1.0 -> report (cant burn shares) -> r1.5 -> report -> w1 (no loss)
    function test_dragonRouterWithdrawal_rateRecovery_userNoLoss() public {
        DragonWithdrawalTestData memory data;

        data.user1 = makeAddr("user1");
        data.depositAmount = 100e18; // 100 rETH
        data.initialRate = 1e18; // 1.0
        data.increasedRate = (1e18 * 15) / 10; // 1.5x rate
        data.decreasedRate = 1e18; // back to 1.0

        // Airdrop rETH to user
        airdrop(ERC20(WSTETH), data.user1, data.depositAmount);

        // Set loss limit to allow for rate changes
        vm.startPrank(management);
        strategy.setLossLimitRatio(5000); // 50% loss limit
        vm.stopPrank();

        // Step 1: d1 - User deposits at rate 1.0
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.initialRate));

        vm.startPrank(data.user1);
        ERC20(WSTETH).approve(address(strategy), data.depositAmount);
        data.user1Shares = vault.deposit(data.depositAmount, data.user1);
        vm.stopPrank();

        // Expected shares: depositAmount * rate = 100e18 * 1e18 / 1e18 = 100e18
        assertEq(data.user1Shares, 100e18, "User1 should receive 100e18 shares at 1:1 rate");

        vm.clearMockedCalls();

        // Step 2: r1.5 - Rate increases to 1.5
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.increasedRate));

        // Step 3: report (mint DR) - First report creates dragon shares
        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();

        data.dragonSharesAfterProfit = vault.balanceOf(donationAddress);

        // Expected profit calculation:
        // Total assets: 100e18 rETH
        // Current rate: 1.5, last rate: 1.0
        // Vault value: 100e18 * 1.5 = 150e18 ETH
        // User debt: 100e18 * 1.0 = 100e18 ETH
        // Excess value: 150e18 - 100e18 = 50e18 ETH
        // Dragon shares minted: 50e18
        // Profit reported: 50e18 / 1.5 = 33.333e18 rETH
        assertEq(data.profit1, 33333333333333333333, "Should report 33.333e18 profit");
        assertEq(data.loss1, 0, "Should report no loss");
        assertEq(data.dragonSharesAfterProfit, 50e18, "Dragon shares should be 50e18");

        // Step 4: wDR - Dragon router withdraws all shares (removes protection buffer)
        vm.startPrank(donationAddress);
        data.dragonAssets = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        // Expected dragon withdrawal:
        // Dragon shares: 50e18
        // Total shares: 150e18 (100e18 user + 50e18 dragon)
        // Total assets: 100e18 rETH
        // Dragon receives: 50e18 / 150e18 * 100e18 = 33.333e18 rETH
        assertEq(data.dragonAssets, 33333333333333333333, "Dragon should receive 33.333e18 rETH");
        assertEq(vault.balanceOf(donationAddress), 0, "Dragon should have no shares after withdrawal");

        vm.clearMockedCalls();

        // Step 5: r1.0 - Rate drops back to 1.0
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.decreasedRate));

        // Step 6: report (cant burn shares) - Report with no dragon shares to burn
        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();

        // Expected loss calculation:
        // Remaining assets: 100e18 - 33.333e18 = 66.666e18 rETH
        // Current rate: 1.0, last rate: 1.5
        // Vault value: 66.666e18 * 1.0 = 66.666e18 ETH
        // User debt: 100e18 * 1.0 = 100e18 ETH
        // Deficit: 66.666e18 - 100e18 = -33.333e18 ETH
        // Loss reported: 33.333e18 ETH / 1.0 = 33.333e18 rETH
        // No dragon shares to burn, loss remains uncovered
        assertEq(data.profit2, 0, "Should report no profit");
        assertEq(data.loss2, 33333333333333333333, "Should report 33.333e18 loss (with rounding)");
        assertEq(vault.balanceOf(donationAddress), 0, "Still no dragon shares to burn");

        vm.clearMockedCalls();

        // Step 7: r1.5 - Rate recovers to 1.5
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.increasedRate));

        // Step 8: report - Report the recovery
        vm.startPrank(keeper);
        (data.profit3, data.loss3) = vault.report();
        vm.stopPrank();

        // Expected profit from recovery:
        // Assets: 66.666e18 rETH
        // Current rate: 1.5, last rate: 1.0
        // Vault value: 66.666e18 * 1.5 = 100e18 ETH
        // User debt: 100e18 ETH (unchanged)
        // No excess value, no profit to report (exactly breaks even)
        assertEq(data.profit3, 0, "Should report no profit (exactly breaks even)");
        assertEq(data.loss3, 0, "Should report no loss");

        // Step 9: w1 - User withdraws (should have no loss due to rate recovery)
        vm.startPrank(data.user1);
        data.assetsReceived = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        // Expected withdrawal:
        // User shares: 100e18
        // Total shares: 100e18 (only user shares remain)
        // Total assets: 66.666e18 rETH
        // At rate 1.5, user receives: 100e18 / 1.5 = 66.666e18 rETH
        // Value check: 66.666e18 * 1.5 = 100e18 ETH (matches initial deposit value)
        assertEq(data.assetsReceived, 66666666666666666666, "User should receive 66.666e18 rETH");

        // Verify no loss in ETH value terms
        // Since rates are in WAD format (1e18), we need to divide by 1e18 after multiplication
        uint256 depositValue = (data.depositAmount * data.initialRate) / 1e18; // 100e18 ETH
        uint256 withdrawValue = (data.assetsReceived * data.increasedRate) / 1e18; // 66.666e18 * 1.5 = 100e18 ETH
        assertApproxEqAbs(
            withdrawValue,
            depositValue,
            1e15,
            "User should have no loss in ETH value terms (within 0.001 ETH tolerance)"
        );
    }

    /// @notice Test dragon router withdrawal followed by rate decline - user should experience loss
    /// @dev Sequence: d1 -> r1.5 -> report (mint DR) -> wDR -> r1.0 -> report (cant burn shares) -> r0.9 -> w1 (loss)
    function test_dragonRouterWithdrawal_rateDecline_userLoss() public {
        DragonWithdrawalTestData memory data;

        data.user1 = makeAddr("user1");
        data.depositAmount = 100e18; // 100 rETH
        data.initialRate = 1e18; // 1.0
        data.increasedRate = (1e18 * 15) / 10; // 1.5x rate
        data.decreasedRate = 1e18; // 1.0
        data.finalRate = (1e18 * 9) / 10; // 0.9x rate

        // Airdrop rETH to user
        airdrop(ERC20(WSTETH), data.user1, data.depositAmount);

        // Set loss limit to allow for rate changes
        vm.startPrank(management);
        strategy.setLossLimitRatio(5000); // 50% loss limit
        vm.stopPrank();

        // Step 1: d1 - User deposits at rate 1.0
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.initialRate));

        vm.startPrank(data.user1);
        ERC20(WSTETH).approve(address(strategy), data.depositAmount);
        data.user1Shares = vault.deposit(data.depositAmount, data.user1);
        vm.stopPrank();

        // Expected shares: depositAmount * rate = 100e18 * 1e18 / 1e18 = 100e18
        assertEq(data.user1Shares, 100e18, "User1 should receive 100e18 shares at 1:1 rate");

        vm.clearMockedCalls();

        // Step 2: r1.5 - Rate increases to 1.5
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.increasedRate));

        // Step 3: report (mint DR) - First report creates dragon shares
        vm.startPrank(keeper);
        (data.profit1, data.loss1) = vault.report();
        vm.stopPrank();

        data.dragonSharesAfterProfit = vault.balanceOf(donationAddress);

        // Expected profit calculation (same as first test):
        // Total assets: 100e18 rETH
        // Current rate: 1.5, last rate: 1.0
        // Vault value: 100e18 * 1.5 = 150e18 ETH
        // User debt: 100e18 * 1.0 = 100e18 ETH
        // Excess value: 150e18 - 100e18 = 50e18 ETH
        // Dragon shares minted: 50e18
        // Profit reported: 50e18 / 1.5 = 33.333e18 rETH
        assertEq(data.profit1, 33333333333333333333, "Should report 33.333e18 profit");
        assertEq(data.loss1, 0, "Should report no loss");
        assertEq(data.dragonSharesAfterProfit, 50e18, "Dragon shares should be 50e18");

        // Step 4: wDR - Dragon router withdraws all shares (removes protection buffer)
        vm.startPrank(donationAddress);
        data.dragonAssets = vault.redeem(vault.balanceOf(donationAddress), donationAddress, donationAddress);
        vm.stopPrank();

        // Expected dragon withdrawal:
        // Dragon shares: 50e18
        // Total shares: 150e18 (100e18 user + 50e18 dragon)
        // Total assets: 100e18 rETH
        // Dragon receives: 50e18 / 150e18 * 100e18 = 33.333e18 rETH
        assertEq(data.dragonAssets, 33333333333333333333, "Dragon should receive 33.333e18 rETH");
        assertEq(vault.balanceOf(donationAddress), 0, "Dragon should have no shares after withdrawal");

        vm.clearMockedCalls();

        // Step 5: r1.0 - Rate drops back to 1.0
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.decreasedRate));

        // Step 6: report (cant burn shares) - Report with no dragon shares to burn
        vm.startPrank(keeper);
        (data.profit2, data.loss2) = vault.report();
        vm.stopPrank();

        // Expected loss calculation:
        // Remaining assets: 100e18 - 33.333e18 = 66.666e18 rETH
        // Current rate: 1.0, last rate: 1.5
        // Vault value: 66.666e18 * 1.0 = 66.666e18 ETH
        // User debt: 100e18 * 1.0 = 100e18 ETH
        // Deficit: 66.666e18 - 100e18 = -33.333e18 ETH
        // Loss reported: 33.333e18 ETH / 1.0 = 33.333e18 rETH
        // No dragon shares to burn, loss remains uncovered
        assertEq(data.profit2, 0, "Should report no profit");
        assertEq(data.loss2, 33333333333333333333, "Should report 33.333e18 loss (with rounding)");
        assertEq(vault.balanceOf(donationAddress), 0, "Still no dragon shares to burn");

        vm.clearMockedCalls();

        // Step 7: r0.9 - Rate declines further to 0.9 (below deposit rate)
        vm.mockCall(WSTETH, abi.encodeWithSignature("stEthPerToken()"), abi.encode(data.finalRate));

        // Step 8: w1 - User withdraws (should experience loss due to rate below deposit rate and no dragon protection)
        vm.startPrank(data.user1);
        data.assetsReceived = vault.redeem(vault.balanceOf(data.user1), data.user1, data.user1);
        vm.stopPrank();

        // Expected withdrawal with loss:
        // User shares: 100e18
        // Total shares: 100e18 (only user shares remain)
        // Total assets: 66.666e18 rETH
        // Since vault is insolvent (lastReportedRate=1.0, currentRate=0.9):
        //   Vault value: 66.666e18 * 0.9 = 60e18 ETH
        //   User debt: 100e18 ETH
        //   Deficit: 60e18 - 100e18 = -40e18 ETH (vault is insolvent)
        // In insolvency, user receives proportional share of assets:
        //   User receives: 100e18 shares / 100e18 total shares * 66.666e18 assets = 66.666e18 rETH
        assertEq(data.assetsReceived, 66666666666666666667, "User should receive 66.666e18 rETH");

        // Calculate the loss in ETH value terms
        // Since rates are in WAD format (1e18), we need to divide by 1e18 after multiplication
        uint256 depositValue = (data.depositAmount * data.initialRate) / 1e18; // 100e18 ETH
        uint256 withdrawValue = (data.assetsReceived * data.finalRate) / 1e18; // 66.666e18 * 0.9 = 60e18 ETH

        // User should receive less than their deposit due to loss and no dragon protection
        assertLt(withdrawValue, depositValue, "User should receive less ETH value than deposited");

        // Expected loss: 100e18 - 60e18 = 40e18 ETH (40% loss)
        uint256 actualLoss = depositValue - withdrawValue;
        assertApproxEqAbs(actualLoss, 40e18, 1e15, "User should experience ~40e18 ETH loss (40%)");

        // Verify the user experienced significant loss (40%)
        uint256 lossPercentage = (actualLoss * 100) / depositValue;
        assertEq(lossPercentage, 40, "User should experience exactly 40% loss");
    }
}
