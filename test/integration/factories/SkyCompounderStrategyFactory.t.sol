// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { IStaking } from "src/strategies/interfaces/ISky.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title SkyCompounderStrategyFactory Test
/// @author mil0x
/// @notice Unit tests for the SkyCompounderStrategyFactory using a mainnet fork
contract SkyCompounderStrategyFactoryTest is Test {
    using SafeERC20 for ERC20;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy tokenizedStrategy;
    SkyCompounderStrategyFactory public factory;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;

    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant STAKING = 0x0650CAF159C5A49f711e8169D4336ECB9b950275; // Sky Protocol Staking Contract
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 19230000; // A recent Ethereum mainnet block

    function setUp() public {
        // Create a mainnet fork
        // NOTE: This relies on the RPC URL configured in foundry.toml under [rpc_endpoints]
        // where mainnet = "${ETHEREUM_NODE_MAINNET}" environment variable
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldDonatingTokenizedStrategy
        YieldDonatingTokenizedStrategy tempStrategy = new YieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1")
        }();
        bytes memory tokenizedStrategyBytecode = address(tempStrategy).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldDonatingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Deploy factory
        factory = new SkyCompounderStrategyFactory();

        // Label addresses for better trace outputs
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(USDS, "USDS Token");
        vm.label(STAKING, "Sky Staking");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
    }

    /// @notice Test creating a strategy through the factory
    function testCreateStrategy() public {
        string memory vaultSharesName = "SkyCompounder Vault Shares";

        string memory vaultSymbol = "osSKY";

        // Calculate expected address based on parameters
        bytes32 parameterHash = keccak256(
            abi.encode(
                0x0650CAF159C5A49f711e8169D4336ECB9b950275, // USDS_REWARD_ADDRESS
                vaultSharesName,
                vaultSymbol,
                management,
                keeper,
                emergencyAdmin,
                donationAddress,
                true, // enableBurning
                address(tokenizedStrategy)
            )
        );

        // Build the bytecode for address prediction
        bytes memory bytecode = abi.encodePacked(
            type(SkyCompounderStrategy).creationCode,
            abi.encode(
                0x0650CAF159C5A49f711e8169D4336ECB9b950275, // USDS_REWARD_ADDRESS
                vaultSharesName,
                vaultSymbol,
                management,
                keeper,
                emergencyAdmin,
                donationAddress,
                true, // enableBurning
                address(tokenizedStrategy)
            )
        );

        // Create a strategy and check events
        vm.startPrank(management);
        vm.expectEmit(true, true, true, true); // Check all parameters including predicted address
        emit SkyCompounderStrategyFactory.StrategyDeploy(
            management,
            donationAddress,
            factory.predictStrategyAddress(parameterHash, management, bytecode),
            vaultSharesName
        );

        address strategyAddress = factory.createStrategy(
            vaultSharesName,
            vaultSymbol,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );
        vm.stopPrank();

        // Verify strategy is tracked in factory
        (address deployerAddress, uint256 timestamp, string memory name, address stratDonationAddress) = factory
            .strategies(management, 0);

        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, vaultSharesName, "Vault shares name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
        assertTrue(timestamp > 0, "Timestamp should be set");

        // Verify strategy was initialized correctly
        SkyCompounderStrategy strategy = SkyCompounderStrategy(strategyAddress);
        assertEq(strategy.staking(), STAKING, "Staking address incorrect");
        // assertEq(strategy.donationAddress(), donationAddress, "Donation address incorrect");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUser() public {
        // Create first strategy
        string memory firstVaultName = "First SkyCompounder Vault";

        vm.startPrank(management);
        address firstStrategyAddress = factory.createStrategy(
            firstVaultName,
            "osSKY1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );

        // Create second strategy for same user with different parameters
        string memory secondVaultName = "Second SkyCompounder Vault";

        address secondStrategyAddress = factory.createStrategy(
            secondVaultName,
            "osSKY2",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );
        vm.stopPrank();

        // Verify both strategies exist
        (address deployerAddress, , string memory name, ) = factory.strategies(management, 0);
        assertEq(deployerAddress, management, "First deployer address incorrect");
        assertEq(name, firstVaultName, "First vault name incorrect");

        (deployerAddress, , name, ) = factory.strategies(management, 1);
        assertEq(deployerAddress, management, "Second deployer address incorrect");
        assertEq(name, secondVaultName, "Second vault name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsers() public {
        string memory firstVaultName = "First User's Vault";

        address firstUser = address(0x5678);
        address secondUser = address(0x9876);

        // Create strategy for first user
        vm.startPrank(firstUser);
        address firstStrategyAddress = factory.createStrategy(
            firstVaultName,
            "osSKY1",
            firstUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );
        vm.stopPrank();

        // Create strategy for second user
        string memory secondVaultName = "Second User's Vault";

        vm.startPrank(secondUser);
        address secondStrategyAddress = factory.createStrategy(
            secondVaultName,
            "osSKY2",
            secondUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );
        vm.stopPrank();

        // Verify strategies are properly tracked for each user
        (address deployerAddress, , string memory name, ) = factory.strategies(firstUser, 0);
        assertEq(deployerAddress, firstUser, "First user's deployer address incorrect");
        assertEq(name, firstVaultName, "First user's vault name incorrect");

        (deployerAddress, , name, ) = factory.strategies(secondUser, 0);
        assertEq(deployerAddress, secondUser, "Second user's deployer address incorrect");
        assertEq(name, secondVaultName, "Second user's vault name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");
    }

    /// @notice Test deterministic addressing and duplicate prevention
    function testDeterministicAddressing() public {
        string memory vaultSharesName = "Deterministic Vault";

        // Create a strategy
        vm.startPrank(management);
        address firstAddress = factory.createStrategy(
            vaultSharesName,
            "osDET",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );

        // Try to create the exact same strategy again - should revert
        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.StrategyAlreadyExists.selector, firstAddress));
        factory.createStrategy(
            vaultSharesName,
            "osDET",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );

        // Create strategy with different name - should succeed
        string memory differentName = "Different Vault";
        address secondAddress = factory.createStrategy(
            differentName,
            "osDIF",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(tokenizedStrategy)
        );
        vm.stopPrank();

        // Different parameters should result in different address
        assertTrue(firstAddress != secondAddress, "Different params should create different address");
    }
}

// Event to match the factory's event signature
event StrategyDeploy(address deployer, address donationAddress, address strategyAddress);
