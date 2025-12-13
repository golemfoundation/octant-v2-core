// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SparkStrategy } from "src/strategies/yieldDonating/SparkStrategy.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title SparkStrategy Test
/// @author Octant
/// @notice Integration tests for the SparkStrategy using a mainnet fork with Spark vaults
contract SparkStrategyTest is Test {
    using SafeERC20 for ERC20;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy public tokenizedStrategy;
    SparkStrategyFactory public factory;
    SparkStrategy public strategy;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;

    // Mock airdrop token
    MockERC20 public airdropToken;
    MockERC20 public anotherToken;

    // Mainnet addresses - Spark vaults
    address public constant USDC_SPARK_VAULT = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days
    YieldDonatingTokenizedStrategy public implementation;

    // Test users
    address public user1 = address(0x1234);
    address public unauthorizedUser = address(0x5678);

    function setUp() public {
        // Create a mainnet fork
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldDonatingTokenizedStrategy
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldDonatingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1001);
        keeper = address(0x1002);
        emergencyAdmin = address(0x1003);
        donationAddress = address(0x1004);

        // Deploy mock airdrop tokens
        airdropToken = new MockERC20(18);
        anotherToken = new MockERC20(6);

        // Deploy factory
        factory = new SparkStrategyFactory();

        // Deploy strategy through factory
        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            "Spark USDC Strategy",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        strategy = SparkStrategy(strategyAddress);

        // Label addresses for better trace outputs
        vm.label(address(factory), "SparkStrategyFactory");
        vm.label(address(strategy), "SparkStrategy");
        vm.label(USDC_SPARK_VAULT, "USDC Spark Vault");
        vm.label(USDC, "USDC");
        vm.label(address(airdropToken), "AirdropToken");
        vm.label(address(anotherToken), "AnotherToken");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(unauthorizedUser, "Unauthorized User");
    }

    /// @notice Test that strategy inherits all basic ERC4626Strategy functionality
    function testBasicInheritance() public view {
        // Verify strategy was initialized correctly
        assertEq(IERC4626(address(strategy)).asset(), USDC, "Asset should be USDC");
        assertEq(strategy.targetVault(), USDC_SPARK_VAULT, "Target vault should be USDC Spark vault");
        // Note: management() and keeper() are not directly accessible in this version
        // We verify through successful operations that require these roles
    }

    /// @notice Test successful airdrop sweep by keeper
    function testSuccessfulAirdropSweepByKeeper() public {
        uint256 airdropAmount = 1000e18;

        // Mint airdrop tokens to strategy
        airdropToken.mint(address(strategy), airdropAmount);

        // Verify initial balances
        assertEq(airdropToken.balanceOf(address(strategy)), airdropAmount, "Strategy should have airdrop tokens");
        assertEq(airdropToken.balanceOf(donationAddress), 0, "Donation address should start with 0");

        // Sweep as keeper
        vm.startPrank(keeper);
        vm.expectEmit(true, false, true, true);
        emit SparkStrategy.TokenSwept(address(airdropToken), airdropAmount, donationAddress);
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        // Verify balances after sweep
        assertEq(airdropToken.balanceOf(address(strategy)), 0, "Strategy should have no airdrop tokens");
        assertEq(airdropToken.balanceOf(donationAddress), airdropAmount, "Donation address should receive tokens");
    }

    /// @notice Test successful airdrop sweep by management
    function testSuccessfulAirdropSweepByManagement() public {
        uint256 airdropAmount = 500e6; // 6 decimals for anotherToken

        // Mint airdrop tokens to strategy
        anotherToken.mint(address(strategy), airdropAmount);

        // Sweep as management
        vm.startPrank(management);
        vm.expectEmit(true, false, true, true);
        emit SparkStrategy.TokenSwept(address(anotherToken), airdropAmount, donationAddress);
        strategy.sweepAirdrop(address(anotherToken));
        vm.stopPrank();

        // Verify balances after sweep
        assertEq(anotherToken.balanceOf(address(strategy)), 0, "Strategy should have no airdrop tokens");
        assertEq(anotherToken.balanceOf(donationAddress), airdropAmount, "Donation address should receive tokens");
    }

    /// @notice Test that unauthorized users cannot sweep airdrops
    function testUnauthorizedSweepReverts() public {
        uint256 airdropAmount = 100e18;

        // Mint airdrop tokens to strategy
        airdropToken.mint(address(strategy), airdropAmount);

        // Try to sweep as unauthorized user
        vm.startPrank(unauthorizedUser);
        vm.expectRevert("!keeper");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        // Verify tokens are still in strategy
        assertEq(airdropToken.balanceOf(address(strategy)), airdropAmount, "Tokens should remain in strategy");
    }

    /// @notice Test that main asset cannot be swept
    function testCannotSweepMainAsset() public {
        // Try to sweep USDC (main asset) as keeper
        vm.startPrank(keeper);
        vm.expectRevert("SparkStrategy: Cannot sweep main asset");
        strategy.sweepAirdrop(USDC);
        vm.stopPrank();
    }

    /// @notice Test that vault shares cannot be swept
    function testCannotSweepVaultShares() public {
        // Try to sweep vault shares as management
        vm.startPrank(management);
        vm.expectRevert("SparkStrategy: Cannot sweep vault shares");
        strategy.sweepAirdrop(USDC_SPARK_VAULT);
        vm.stopPrank();
    }

    /// @notice Test that sweeping with zero balance reverts
    function testSweepZeroBalanceReverts() public {
        // Try to sweep token with no balance
        vm.startPrank(keeper);
        vm.expectRevert("SparkStrategy: No balance to sweep");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();
    }

    /// @notice Test multiple token sweeps
    function testMultipleTokenSweeps() public {
        uint256 airdropAmount1 = 1000e18;
        uint256 airdropAmount2 = 500e6;

        // Mint different airdrop tokens to strategy
        airdropToken.mint(address(strategy), airdropAmount1);
        anotherToken.mint(address(strategy), airdropAmount2);

        // Sweep first token as keeper
        vm.startPrank(keeper);
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        // Sweep second token as management
        vm.startPrank(management);
        strategy.sweepAirdrop(address(anotherToken));
        vm.stopPrank();

        // Verify all tokens were swept
        assertEq(airdropToken.balanceOf(address(strategy)), 0, "First token should be swept");
        assertEq(anotherToken.balanceOf(address(strategy)), 0, "Second token should be swept");
        assertEq(airdropToken.balanceOf(donationAddress), airdropAmount1, "Donation address should have first token");
        assertEq(anotherToken.balanceOf(donationAddress), airdropAmount2, "Donation address should have second token");
    }

    /// @notice Test that emergency admin cannot sweep (only keeper and management)
    function testEmergencyAdminCannotSweep() public {
        uint256 airdropAmount = 100e18;

        // Mint airdrop tokens to strategy
        airdropToken.mint(address(strategy), airdropAmount);

        // Try to sweep as emergency admin
        vm.startPrank(emergencyAdmin);
        vm.expectRevert("!keeper");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();
    }

    /// @notice Test factory deployment and tracking
    function testFactoryDeployment() public {
        // First, verify the original strategy from setUp is tracked
        // Get all strategies for management to check if any are recorded
        SparkStrategyFactory.StrategyInfo[] memory allStrategies = factory.getStrategiesByDeployer(management);

        assertEq(allStrategies.length, 1, "Should have exactly 1 strategy from setUp");

        (address deployerAddress, , string memory name, address stratDonationAddress) = factory.strategies(
            management,
            0
        );

        assertEq(deployerAddress, management, "Original deployer address should be management");
        assertEq(name, "Spark USDC Strategy", "Original strategy name should be correct");
        assertEq(stratDonationAddress, donationAddress, "Original donation address should be correct");

        // Create another strategy through factory
        string memory strategyName = "Another Spark Strategy";
        vm.startPrank(management);
        address newStrategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify new strategy is tracked in factory
        (deployerAddress, , name, stratDonationAddress) = factory.strategies(management, 1);
        assertEq(deployerAddress, management, "New strategy deployer address should be management");
        assertEq(name, strategyName, "New strategy name should be correct");
        assertEq(stratDonationAddress, donationAddress, "New strategy donation address should be correct");

        // Verify new strategy
        SparkStrategy newStrategy = SparkStrategy(newStrategyAddress);
        assertEq(newStrategy.targetVault(), USDC_SPARK_VAULT, "New strategy should target correct vault");
        assertEq(IERC4626(address(newStrategy)).asset(), USDC, "New strategy should have correct asset");
    }

    /// @notice Test asset validation during strategy creation
    function testAssetValidationInFactory() public {
        string memory strategyName = "Invalid Asset Strategy";

        // Try to create strategy with wrong asset for USDC vault
        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            USDC_SPARK_VAULT,
            address(airdropToken), // Wrong asset - should be USDC
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();
    }
}
