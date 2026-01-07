// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { ERC4626StrategyFactory } from "src/factories/ERC4626StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title Base SparkVault Yield Donating Test
/// @author Octant
/// @notice Base contract for integration tests of ERC4626 strategy with SparkDAO vaults
abstract contract BaseSparkVaultStrategyTest is Test {
    using SafeERC20 for ERC20;

    // Setup parameters struct to avoid stack too deep
    struct SetupParams {
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        string strategyName;
        bytes32 salt;
        address implementationAddress;
    }

    // Strategy instance
    ERC4626Strategy public strategy;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    ERC4626StrategyFactory public factory;
    string public strategyName;

    // Test user
    address public user = address(0x1234);

    // Abstract parameters - to be defined by concrete implementations
    function getSparkVault() internal pure virtual returns (address);
    function getAsset() internal pure virtual returns (address);
    function getAssetName() internal pure virtual returns (string memory);
    function getInitialDeposit() internal pure virtual returns (uint256);
    function getWrongAsset() internal pure virtual returns (address);

    // Common addresses
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;
    YieldDonatingTokenizedStrategy public implementation;
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days

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
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldDonatingTokenizedStrategy
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

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
            strategyName: strategyName,
            salt: keccak256("OCT_SPARK_STRATEGY_V1"),
            implementationAddress: address(implementation)
        });

        // ERC4626StrategyFactory
        factory = new ERC4626StrategyFactory{ salt: keccak256("OCT_GENERIC_ERC4626_STRATEGY_FACTORY_V1") }();

        // Deploy strategy using virtual functions
        strategy = ERC4626Strategy(
            factory.createStrategy(
                getSparkVault(),
                getAsset(),
                params.strategyName,
                params.management,
                params.keeper,
                params.emergencyAdmin,
                params.donationAddress,
                false, // enableBurning
                params.implementationAddress
            )
        );

        // Set strategy name based on asset
        strategyName = string(abi.encodePacked("Spark ", getAssetName(), " Donating Strategy"));

        // Label addresses for better trace outputs
        vm.label(address(strategy), "SparkStrategy");
        vm.label(getSparkVault(), "Spark Vault");
        vm.label(getAsset(), getAssetName());
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");

        // Airdrop asset tokens to test user
        airdrop(ERC20(getAsset()), user, getInitialDeposit());

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(getAsset()).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that the strategy is properly initialized
    function testInitialization() public view {
        assertEq(
            IERC4626(address(strategy)).asset(),
            getAsset(),
            string(abi.encodePacked("Asset should be ", getAssetName()))
        );
        assertEq(strategy.targetVault(), getSparkVault(), "Target vault incorrect");
    }

    /// @notice Fuzz test depositing assets into the strategy
    function testFuzzDeposit(uint256 depositAmount) public {
        // Bound the deposit amount to reasonable values (handle different decimals)
        uint256 minDeposit = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1e6 : 1e18; // 1 unit
        depositAmount = bound(depositAmount, minDeposit, getInitialDeposit());

        // Ensure user has enough balance
        if (ERC20(getAsset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(getAsset()), user, depositAmount);
        }

        // Initial balances
        uint256 initialUserBalance = ERC20(getAsset()).balanceOf(user);
        uint256 initialStrategyAssets = IERC4626(address(strategy)).totalAssets();

        // Deposit assets
        vm.startPrank(user);
        uint256 sharesReceived = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Verify balances after deposit
        assertEq(
            ERC20(getAsset()).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );

        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertEq(
            IERC4626(address(strategy)).totalAssets(),
            initialStrategyAssets + depositAmount,
            "Strategy total assets should increase"
        );
    }

    /// @notice Fuzz test withdrawing assets from the strategy
    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawFraction) public {
        // Bound the deposit amount to reasonable values (handle different decimals)
        uint256 minDeposit = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1e6 : 1e18; // 1 unit
        depositAmount = bound(depositAmount, minDeposit, getInitialDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100); // 1% to 100%

        // Ensure user has enough balance
        if (ERC20(getAsset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(getAsset()), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);

        // Calculate withdrawal amount as a fraction of deposit
        uint256 withdrawAmount = (depositAmount * withdrawFraction) / 100;

        // Skip if withdraw amount is 0
        vm.assume(withdrawAmount > 0);

        // Initial balances before withdrawal
        uint256 initialUserBalance = ERC20(getAsset()).balanceOf(user);
        uint256 initialShareBalance = IERC4626(address(strategy)).balanceOf(user);

        // Withdraw portion of the deposit
        uint256 previewMaxWithdraw = IERC4626(address(strategy)).maxWithdraw(user);
        vm.assume(previewMaxWithdraw >= withdrawAmount);
        uint256 sharesToBurn = IERC4626(address(strategy)).previewWithdraw(withdrawAmount);
        uint256 assetsReceived = IERC4626(address(strategy)).withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Verify balances after withdrawal
        assertEq(
            ERC20(getAsset()).balanceOf(user),
            initialUserBalance + withdrawAmount,
            "User didn't receive correct assets"
        );
        assertEq(
            IERC4626(address(strategy)).balanceOf(user),
            initialShareBalance - sharesToBurn,
            "Shares not burned correctly"
        );
        assertEq(assetsReceived, withdrawAmount, "Incorrect amount of assets received");
    }

    /// @notice Fuzz test the harvesting functionality with profit donation
    function testFuzzHarvestWithProfitDonation(uint256 depositAmount, uint256 profitAmount) public {
        // Bound amounts to reasonable values (handle different decimals)
        uint256 minDeposit = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1e6 : 1e18; // 1 unit
        uint256 minProfit = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1e5 : 1e17; // 0.1 unit
        depositAmount = bound(depositAmount, minDeposit, getInitialDeposit());
        profitAmount = bound(profitAmount, minProfit, depositAmount);

        // Ensure user has enough balance
        if (ERC20(getAsset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(getAsset()), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Check initial state
        uint256 totalAssetsBefore = IERC4626(address(strategy)).totalAssets();
        uint256 userSharesBefore = IERC4626(address(strategy)).balanceOf(user);
        uint256 donationBalanceBefore = ERC20(address(strategy)).balanceOf(donationAddress);

        // Call report to harvest and donate yield
        // mock IERC4626(targetVault).convertToAssets(shares) so that it returns profit
        uint256 balanceOfSparkVault = IERC4626(getSparkVault()).balanceOf(address(strategy));
        vm.mockCall(
            address(IERC4626(getSparkVault())),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfSparkVault),
            abi.encode(depositAmount + profitAmount)
        );
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        vm.clearMockedCalls();

        // airdrop profit to the strategy
        airdrop(ERC20(getAsset()), address(strategy), profitAmount);

        // Verify results
        assertGt(profit, 0, "Should have captured profit from yield");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (no dilution)
        assertEq(IERC4626(address(strategy)).balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit
        uint256 donationBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase by the profit amount
        assertGt(IERC4626(address(strategy)).totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    /// @notice Test available deposit limit without idle assets
    function testAvailableDepositLimitWithoutIdleAssets() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 sparkLimit = IERC4626(getSparkVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(getAsset()).balanceOf(address(strategy));

        // Since there are no idle assets initially, limit should equal spark limit
        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, sparkLimit, "Available deposit limit should match Spark vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets
    function testAvailableDepositLimitWithIdleAssets() public {
        // Use appropriate amount based on asset decimals
        uint256 idleAmount = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1000e6 : 1000e18; // 1,000 units idle assets

        // Airdrop idle assets to strategy to simulate undeployed funds
        airdrop(ERC20(getAsset()), address(strategy), idleAmount);

        // Get the limits
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 sparkLimit = IERC4626(getSparkVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(getAsset()).balanceOf(address(strategy));

        // Verify idle assets are present
        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        // The available deposit limit should be spark limit minus idle balance
        uint256 expectedLimit = sparkLimit > idleAmount ? sparkLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        assertLt(limit, sparkLimit, "Available deposit limit should be less than spark limit when idle assets exist");
    }

    /// @notice Test available deposit limit edge case where idle assets exceed spark limit
    function testAvailableDepositLimitIdleAssetsExceedSparkLimit() public {
        uint256 sparkLimit = IERC4626(getSparkVault()).maxDeposit(address(strategy));

        // Skip test if spark limit is too high for this test
        vm.assume(sparkLimit < type(uint256).max / 2);

        // Use appropriate amount based on asset decimals
        uint256 excessAmount = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1000e6 : 1000e18; // 1,000 units
        uint256 excessIdleAmount = sparkLimit + excessAmount; // Idle assets exceed spark limit

        // Airdrop excess idle assets to strategy
        airdrop(ERC20(getAsset()), address(strategy), excessIdleAmount);

        // Get the limit
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(getAsset()).balanceOf(address(strategy));

        // Verify idle assets are present and exceed spark limit
        assertEq(idleBalance, excessIdleAmount, "Strategy should have excess idle assets");
        assertGt(idleBalance, sparkLimit, "Idle assets should exceed spark limit");

        // The available deposit limit should be 0 since idle assets exceed spark capacity
        assertEq(limit, 0, "Available deposit limit should be 0 when idle assets exceed spark limit");
    }

    /// @notice Fuzz test emergency withdraw functionality
    function testFuzzEmergencyWithdraw(uint256 depositAmount, uint256 withdrawFraction) public {
        // Bound amounts to reasonable values (handle different decimals)
        uint256 minDeposit = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1e6 : 1e18; // 1 unit
        depositAmount = bound(depositAmount, minDeposit, getInitialDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100); // 1% to 100%

        // Ensure user has enough balance
        if (ERC20(getAsset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(getAsset()), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Calculate emergency withdraw amount as fraction of deposit
        uint256 emergencyWithdrawAmount = (depositAmount * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        // Get maximum withdrawable amount from strategy's perspective
        uint256 maxWithdrawable = strategy.availableWithdrawLimit(address(this));

        // Ensure emergency withdraw amount is within available limits
        vm.assume(emergencyWithdrawAmount <= maxWithdrawable);

        // Get initial state for precise assertions
        uint256 initialSparkShares = IERC4626(getSparkVault()).balanceOf(address(strategy));
        uint256 initialStrategyBalance = ERC20(getAsset()).balanceOf(address(strategy));
        uint256 expectedShares = IERC4626(getSparkVault()).previewWithdraw(emergencyWithdrawAmount);

        // Emergency withdraw
        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // Verify precise outcomes
        uint256 finalSparkShares = IERC4626(getSparkVault()).balanceOf(address(strategy));
        uint256 finalStrategyBalance = ERC20(getAsset()).balanceOf(address(strategy));

        // Strategy should have received exactly the requested amount
        assertEq(
            finalStrategyBalance,
            initialStrategyBalance + emergencyWithdrawAmount,
            "Strategy should receive exact emergency withdraw amount"
        );

        // Spark vault shares should decrease by expected amount (with small tolerance for rounding)
        assertApproxEqRel(
            initialSparkShares - finalSparkShares,
            expectedShares,
            1e14, // 0.01% tolerance
            "Spark shares should decrease by expected amount"
        );
    }

    /// @notice Test that constructor validates asset compatibility
    function testConstructorAssetValidation() public {
        // Try to deploy with wrong asset - should revert
        vm.expectRevert("Asset mismatch with target vault");
        new ERC4626Strategy(
            getSparkVault(),
            getWrongAsset(), // Wrong asset
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(implementation)
        );
    }

    /// @notice Test Spark-specific functionality: VSR (Variable Savings Rate)
    /// @dev This test verifies that the Spark vault accrues yield over time
    function testSparkVSRAccrual() public {
        // Use appropriate amount based on asset decimals
        uint256 depositAmount = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 10000e6 : 10e18; // 10,000 USDC or 10 WETH

        // Ensure user has enough balance
        if (ERC20(getAsset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(getAsset()), user, depositAmount);
        }

        // Deposit funds
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Get initial vault shares and assets
        uint256 initialShares = IERC4626(getSparkVault()).balanceOf(address(strategy));
        uint256 initialAssets = IERC4626(getSparkVault()).convertToAssets(initialShares);

        // Fast forward time to simulate yield accrual
        vm.warp(block.timestamp + 365 days);

        // Force Spark vault to drip (update chi accumulator)
        // This is specific to SparkVault's implementation
        (bool success, ) = getSparkVault().call(abi.encodeWithSignature("drip()"));
        if (success) {
            // Get assets after time passage
            uint256 finalAssets = IERC4626(getSparkVault()).convertToAssets(initialShares);

            // Assets should have increased due to VSR
            assertGe(finalAssets, initialAssets, "Spark vault should accrue yield over time");
        }
    }

    /// @notice Test deposit cap handling
    function testDepositCap() public {
        // Get the deposit cap from Spark vault
        uint256 depositCap = IERC4626(getSparkVault()).maxDeposit(address(strategy));

        // If deposit cap is effectively unlimited, skip this test
        uint256 maxCheckAmount = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1000000000e6 : 1000000e18;
        if (depositCap > maxCheckAmount) {
            return;
        }

        // Try to deposit more than the cap (if reasonable)
        uint256 excessBaseAmount = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 1000e6 : 1e18; // 1,000 USDC or 1 WETH
        uint256 excessAmount = depositCap + excessBaseAmount;

        // Ensure user has enough balance
        airdrop(ERC20(getAsset()), user, excessAmount);

        // Approve strategy
        vm.startPrank(user);
        ERC20(getAsset()).approve(address(strategy), excessAmount);

        // This should revert due to deposit cap
        vm.expectRevert();
        IERC4626(address(strategy)).deposit(excessAmount, user);
        vm.stopPrank();
    }

    /// @notice Test multiple users depositing and withdrawing
    function testMultiUserFlow() public {
        address user2 = address(0x5678);
        // Use appropriate amounts based on asset decimals
        uint256 deposit1 = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 5000e6 : 5e18; // 5,000 USDC or 5 WETH
        uint256 deposit2 = getAsset() == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 ? 3000e6 : 3e18; // 3,000 USDC or 3 WETH

        // Setup users
        airdrop(ERC20(getAsset()), user, deposit1);
        airdrop(ERC20(getAsset()), user2, deposit2);

        // Approve
        vm.prank(user);
        ERC20(getAsset()).approve(address(strategy), deposit1);
        vm.prank(user2);
        ERC20(getAsset()).approve(address(strategy), deposit2);

        // User 1 deposits
        vm.prank(user);
        uint256 shares1 = IERC4626(address(strategy)).deposit(deposit1, user);

        // User 2 deposits
        vm.prank(user2);
        uint256 shares2 = IERC4626(address(strategy)).deposit(deposit2, user2);

        // Verify shares
        assertEq(IERC4626(address(strategy)).balanceOf(user), shares1);
        assertEq(IERC4626(address(strategy)).balanceOf(user2), shares2);

        // User 1 withdraws half
        vm.prank(user);
        IERC4626(address(strategy)).redeem(shares1 / 2, user, user);

        // Verify balances
        assertEq(IERC4626(address(strategy)).balanceOf(user), shares1 / 2);
        assertGt(ERC20(getAsset()).balanceOf(user), 0);
    }
}
