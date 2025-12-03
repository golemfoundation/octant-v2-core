// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { GenericERC4626Strategy } from "src/strategies/yieldDonating/GenericERC4626Strategy.sol";
import { GenericERC4626StrategyFactory } from "src/factories/GenericERC4626StrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title GenericERC4626StrategyFactory Test
/// @author Octant
/// @notice Integration tests for the GenericERC4626StrategyFactory using a mainnet fork
contract GenericERC4626StrategyFactoryTest is Test {
    using SafeERC20 for ERC20;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy public tokenizedStrategy;
    GenericERC4626StrategyFactory public factory;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;

    // Mainnet addresses - Spark vaults
    address public constant USDC_SPARK_VAULT = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d;
    address public constant WETH_SPARK_VAULT = 0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days
    YieldDonatingTokenizedStrategy public implementation;

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
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Deploy factory
        factory = new GenericERC4626StrategyFactory();

        // Label addresses for better trace outputs
        vm.label(address(factory), "GenericERC4626StrategyFactory");
        vm.label(USDC_SPARK_VAULT, "USDC Spark Vault");
        vm.label(WETH_SPARK_VAULT, "WETH Spark Vault");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
    }

    /// @notice Test creating a strategy through the factory for USDC Spark vault
    function testCreateStrategyUSDC() public {
        string memory strategyName = "Spark USDC Donating Strategy";

        // Create a strategy and check events
        vm.startPrank(management);
        vm.expectEmit(true, true, true, false); // Check deployer, targetVault, and donationAddress; ignore strategy address
        emit GenericERC4626StrategyFactory.StrategyDeploy(
            management,
            USDC_SPARK_VAULT,
            donationAddress,
            address(0),
            strategyName
        );

        address strategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy is tracked in factory
        (address deployerAddress, uint256 timestamp, string memory name, address stratDonationAddress) = factory
            .strategies(management, 0);

        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, strategyName, "Strategy name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
        assertTrue(timestamp > 0, "Timestamp should be set");

        // Verify strategy was initialized correctly
        GenericERC4626Strategy strategy = GenericERC4626Strategy(strategyAddress);
        assertEq(IERC4626(address(strategy)).asset(), USDC, "Asset should be USDC");
        assertEq(strategy.targetVault(), USDC_SPARK_VAULT, "Target vault should be USDC Spark vault");
    }

    /// @notice Test creating a strategy through the factory for WETH Spark vault
    function testCreateStrategyWETH() public {
        string memory strategyName = "Spark WETH Donating Strategy";

        // Create a strategy and check events
        vm.startPrank(management);
        vm.expectEmit(true, true, true, false); // Check deployer, targetVault, and donationAddress; ignore strategy address
        emit GenericERC4626StrategyFactory.StrategyDeploy(
            management,
            WETH_SPARK_VAULT,
            donationAddress,
            address(0),
            strategyName
        );

        address strategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy is tracked in factory
        (address deployerAddress, uint256 timestamp, string memory name, address stratDonationAddress) = factory
            .strategies(management, 0);

        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, strategyName, "Strategy name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
        assertTrue(timestamp > 0, "Timestamp should be set");

        // Verify strategy was initialized correctly
        GenericERC4626Strategy strategy = GenericERC4626Strategy(strategyAddress);
        assertEq(IERC4626(address(strategy)).asset(), WETH, "Asset should be WETH");
        assertEq(strategy.targetVault(), WETH_SPARK_VAULT, "Target vault should be WETH Spark vault");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUser() public {
        // Create first strategy (USDC)
        string memory firstStrategyName = "First Spark USDC Strategy";

        vm.startPrank(management);
        address firstStrategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            firstStrategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );

        // Create second strategy (WETH) for same user
        string memory secondStrategyName = "First Spark WETH Strategy";

        address secondStrategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            secondStrategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify both strategies exist
        (address deployerAddress, , string memory name, ) = factory.strategies(management, 0);
        assertEq(deployerAddress, management, "First deployer address incorrect");
        assertEq(name, firstStrategyName, "First strategy name incorrect");

        (deployerAddress, , name, ) = factory.strategies(management, 1);
        assertEq(deployerAddress, management, "Second deployer address incorrect");
        assertEq(name, secondStrategyName, "Second strategy name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");

        // Verify they target different vaults
        GenericERC4626Strategy firstStrategy = GenericERC4626Strategy(firstStrategyAddress);
        GenericERC4626Strategy secondStrategy = GenericERC4626Strategy(secondStrategyAddress);
        assertEq(firstStrategy.targetVault(), USDC_SPARK_VAULT, "First strategy should target USDC vault");
        assertEq(secondStrategy.targetVault(), WETH_SPARK_VAULT, "Second strategy should target WETH vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsers() public {
        string memory firstStrategyName = "First User's USDC Strategy";
        string memory secondStrategyName = "Second User's WETH Strategy";

        address firstUser = address(0x5678);
        address secondUser = address(0x9876);

        // Create strategy for first user (USDC)
        vm.startPrank(firstUser);
        address firstStrategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            firstStrategyName,
            firstUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Create strategy for second user (WETH)
        vm.startPrank(secondUser);
        address secondStrategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            secondStrategyName,
            secondUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategies are properly tracked for each user
        (address deployerAddress, , string memory name, ) = factory.strategies(firstUser, 0);
        assertEq(deployerAddress, firstUser, "First user's deployer address incorrect");
        assertEq(name, firstStrategyName, "First user's strategy name incorrect");

        (deployerAddress, , name, ) = factory.strategies(secondUser, 0);
        assertEq(deployerAddress, secondUser, "Second user's deployer address incorrect");
        assertEq(name, secondStrategyName, "Second user's strategy name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressing() public {
        string memory strategyName = "Deterministic USDC Strategy";

        // Create a strategy
        vm.startPrank(management);
        address firstAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Try to deploy the exact same strategy again - should revert
        vm.startPrank(management);
        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.StrategyAlreadyExists.selector, firstAddress));
        factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Create a strategy with different parameters - should succeed
        string memory differentName = "Different USDC Strategy";
        vm.startPrank(management);
        address secondAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            differentName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Different parameters should result in different address
        assertTrue(firstAddress != secondAddress, "Different params should create different address");
    }

    /// @notice Test creating strategy with different vault (same user, different target vault)
    function testDifferentVaultSameParams() public {
        string memory strategyName = "Same Name Different Vault";

        vm.startPrank(management);
        // Create USDC strategy
        address usdcStrategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );

        // Create WETH strategy with same name and params but different vault
        address wethStrategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            strategyName, // Same name
            management, // Same management
            keeper, // Same keeper
            emergencyAdmin, // Same emergency admin
            donationAddress, // Same donation address
            false, // Same enableBurning
            address(implementation) // Same implementation
        );
        vm.stopPrank();

        // Should create different strategies since target vault is different
        assertTrue(
            usdcStrategyAddress != wethStrategyAddress,
            "Different target vaults should create different strategies"
        );

        // Verify both are tracked
        (address deployerAddress, , , ) = factory.strategies(management, 0);
        assertEq(deployerAddress, management, "First strategy should be tracked");
        (deployerAddress, , , ) = factory.strategies(management, 1);
        assertEq(deployerAddress, management, "Second strategy should be tracked");
    }

    /// @notice Test asset validation during strategy creation
    function testAssetValidation() public {
        string memory strategyName = "Invalid Asset Strategy";

        // Try to create strategy with wrong asset for USDC vault
        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            USDC_SPARK_VAULT,
            WETH, // Wrong asset - should be USDC
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Try to create strategy with wrong asset for WETH vault
        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            WETH_SPARK_VAULT,
            USDC, // Wrong asset - should be WETH
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();
    }

    /// @notice Test creating strategy with enableBurning = true
    function testEnableBurning() public {
        string memory strategyName = "Burning Enabled Strategy";

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning = true
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy was created successfully
        assertTrue(strategyAddress != address(0), "Strategy should be deployed");

        // Verify it's tracked in factory
        (address deployerAddress, , string memory name, ) = factory.strategies(management, 0);
        assertEq(deployerAddress, management, "Deployer should be tracked");
        assertEq(name, strategyName, "Name should match");
    }
}
