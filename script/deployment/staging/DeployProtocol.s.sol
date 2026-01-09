// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DeployDragonRouter } from "script/deploy/DeployDragonRouter.sol";
import { DeployDragonTokenizedStrategy } from "script/deploy/DeployDragonTokenizedStrategy.sol";
import { DeployHatsProtocol } from "script/deploy/DeployHatsProtocol.sol";
import { DeployLinearAllowanceSingletonForGnosisSafe } from "script/deploy/DeployLinearAllowanceSingletonForGnosisSafe.sol";
import { DeployMockStrategy } from "script/deploy/DeployMockStrategy.sol";
import { DeployModuleProxyFactory } from "script/deploy/DeployModuleProxyFactory.sol";
import { DeployPaymentSplitterFactory } from "script/deploy/DeployPaymentSplitterFactory.sol";
import { DeploySkyCompounderStrategyFactory } from "script/deploy/DeploySkyCompounderStrategyFactory.sol";
import { DeployMorphoCompounderStrategyFactory } from "script/deploy/DeployMorphoCompounderStrategyFactory.sol";
import { DeployRegenStakerFactory } from "script/deploy/DeployRegenStakerFactory.sol";
import { DeployAllocationMechanismFactory } from "script/deploy/DeployAllocationMechanismFactory.sol";
import { DeployYearnV3StrategyFactory } from "script/deploy/DeployYearnV3StrategyFactory.s.sol";
import { DeployLidoStrategyFactory } from "script/deploy/DeployLidoStrategyFactory.sol";
import { DeployedAddresses } from "script/helpers/DeployedAddresses.sol";

/**
 * @title DeployProtocol
 * @notice Production deployment script for Dragon Protocol core components
 * @dev This script handles the sequential deployment of all protocol components
 */
contract DeployProtocol is Script {
    // Deployers
    DeployModuleProxyFactory public deployModuleProxyFactory;
    DeployLinearAllowanceSingletonForGnosisSafe public deployLinearAllowanceSingletonForGnosisSafe;
    DeployDragonTokenizedStrategy public deployDragonTokenizedStrategy;
    DeployDragonRouter public deployDragonRouter;
    DeployMockStrategy public deployMockStrategy;
    DeployHatsProtocol public deployHatsProtocol;
    DeployPaymentSplitterFactory public deployPaymentSplitterFactory;
    DeploySkyCompounderStrategyFactory public deploySkyCompounderStrategyFactory;
    DeployMorphoCompounderStrategyFactory public deployMorphoCompounderStrategyFactory;
    DeployRegenStakerFactory public deployRegenStakerFactory;
    DeployAllocationMechanismFactory public deployAllocationMechanismFactory;
    DeployYearnV3StrategyFactory public deployYearnV3StrategyFactory;
    DeployLidoStrategyFactory public deployLidoStrategyFactory;

    // Address registry for network-specific deployments
    DeployedAddresses public immutable deployedAddresses;

    // Deployed contract addresses
    address public moduleProxyFactoryAddress;
    address public linearAllowanceSingletonForGnosisSafeAddress;
    address public dragonTokenizedStrategyAddress;
    address public dragonRouterAddress;
    address public splitCheckerAddress;
    address public mockStrategySingletonAddress;
    address public mockTokenAddress;
    address public mockYieldSourceAddress;
    address public hatsAddress;
    address public paymentSplitterFactoryAddress;
    address public skyCompounderStrategyFactoryAddress;
    address public morphoCompounderStrategyFactoryAddress;
    address public regenStakerFactoryAddress;
    address public allocationMechanismFactoryAddress;
    // External strategy contracts (tracked for reference, not deployed by this script)
    address public yieldDonatingTokenizedStrategyAddress;
    address public yearnV3StrategyFactoryAddress;
    address public lidoStrategyFactoryAddress;

    error DeploymentFailed();

    /**
     * @notice Constructor to initialize the deployed addresses registry
     * @dev Initializes the immutable deployedAddresses variable once
     */
    constructor() {
        deployedAddresses = new DeployedAddresses();
    }

    function setUp() public {
        // Initialize deployment scripts
        deployModuleProxyFactory = new DeployModuleProxyFactory(msg.sender, msg.sender, msg.sender);
        deployLinearAllowanceSingletonForGnosisSafe = new DeployLinearAllowanceSingletonForGnosisSafe();
        deployDragonTokenizedStrategy = new DeployDragonTokenizedStrategy();
        deployDragonRouter = new DeployDragonRouter();
        deployMockStrategy = new DeployMockStrategy(msg.sender, msg.sender, msg.sender);
        deployHatsProtocol = new DeployHatsProtocol();
        deployPaymentSplitterFactory = new DeployPaymentSplitterFactory();
        deploySkyCompounderStrategyFactory = new DeploySkyCompounderStrategyFactory();
        deployMorphoCompounderStrategyFactory = new DeployMorphoCompounderStrategyFactory();
        deployRegenStakerFactory = new DeployRegenStakerFactory();
        deployAllocationMechanismFactory = new DeployAllocationMechanismFactory();
        deployYearnV3StrategyFactory = new DeployYearnV3StrategyFactory();
        deployLidoStrategyFactory = new DeployLidoStrategyFactory();
    }

    /**
     * @notice Load previously deployed contract addresses for the current network
     * @dev Uses DeployedAddresses helper to get network-specific addresses via DEPLOYMENT_NETWORK env var
     *      Any address set to address(0) will trigger fresh deployment in the run() function
     *      Set DEPLOYMENT_NETWORK to: "mainnet", "sepolia", "staging", or "anvil"
     */
    function setUpDeployedContracts() public {
        DeployedAddresses.ContractAddresses memory addresses = deployedAddresses.getAddressesByEnv();

        // Load all addresses from the centralized registry
        // Note: yieldDonatingTokenizedStrategy and yearnV3StrategyFactory are EXTERNAL dependencies,
        // not deployed by this script. They are pre-existing contracts we reference.
        moduleProxyFactoryAddress = addresses.moduleProxyFactory;
        linearAllowanceSingletonForGnosisSafeAddress = addresses.linearAllowanceSingleton;
        dragonTokenizedStrategyAddress = addresses.dragonTokenizedStrategy;
        dragonRouterAddress = addresses.dragonRouter;
        splitCheckerAddress = addresses.splitChecker;
        mockStrategySingletonAddress = addresses.mockStrategySingleton;
        mockTokenAddress = addresses.mockToken;
        mockYieldSourceAddress = addresses.mockYieldSource;
        hatsAddress = addresses.hats;
        paymentSplitterFactoryAddress = addresses.paymentSplitterFactory;
        skyCompounderStrategyFactoryAddress = addresses.skyCompounderStrategyFactory;
        morphoCompounderStrategyFactoryAddress = addresses.morphoCompounderStrategyFactory;
        regenStakerFactoryAddress = addresses.regenStakerFactory;
        allocationMechanismFactoryAddress = addresses.allocationMechanismFactory;
        yieldDonatingTokenizedStrategyAddress = addresses.yieldDonatingTokenizedStrategy;
        yearnV3StrategyFactoryAddress = addresses.yearnV3StrategyFactory;
        lidoStrategyFactoryAddress = addresses.lidoStrategyFactory;
    }

    function run() public {
        string memory startingBlock = vm.toString(block.number);

        setUp();
        setUpDeployedContracts();

        // Deploy Module Proxy Factory
        if (moduleProxyFactoryAddress == address(0)) {
            deployModuleProxyFactory.deploy();
            moduleProxyFactoryAddress = address(deployModuleProxyFactory.moduleProxyFactory());
            if (moduleProxyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy LinearAllowanceSingletonForGnosisSafe
        if (linearAllowanceSingletonForGnosisSafeAddress == address(0)) {
            deployLinearAllowanceSingletonForGnosisSafe.deploy();
            linearAllowanceSingletonForGnosisSafeAddress = address(
                deployLinearAllowanceSingletonForGnosisSafe.linearAllowanceSingletonForGnosisSafe()
            );
            if (linearAllowanceSingletonForGnosisSafeAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Dragon Tokenized Strategy Implementation
        if (dragonTokenizedStrategyAddress == address(0)) {
            deployDragonTokenizedStrategy.deploy();
            dragonTokenizedStrategyAddress = address(deployDragonTokenizedStrategy.dragonTokenizedStrategySingleton());
            if (dragonTokenizedStrategyAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Dragon Router
        if (dragonRouterAddress == address(0) || splitCheckerAddress == address(0)) {
            if (dragonRouterAddress != address(0) || splitCheckerAddress != address(0)) {
                revert DeploymentFailed();
            }
            deployDragonRouter.deploy();
            dragonRouterAddress = address(deployDragonRouter.dragonRouterProxy());
            if (dragonRouterAddress == address(0)) revert DeploymentFailed();
            splitCheckerAddress = address(deployDragonRouter.splitCheckerProxy());
        }

        // Deploy Mock Strategy
        if (
            mockStrategySingletonAddress == address(0) ||
            mockTokenAddress == address(0) ||
            mockYieldSourceAddress == address(0)
        ) {
            if (
                mockStrategySingletonAddress != address(0) ||
                mockTokenAddress != address(0) ||
                mockYieldSourceAddress != address(0)
            ) {
                revert DeploymentFailed();
            }
            deployMockStrategy.deploy();
            mockStrategySingletonAddress = address(deployMockStrategy.mockStrategySingleton());
            if (mockStrategySingletonAddress == address(0)) revert DeploymentFailed();
            mockTokenAddress = address(deployMockStrategy.token());
            mockYieldSourceAddress = address(deployMockStrategy.mockYieldSource());
        }

        // Deploy HATS
        if (hatsAddress == address(0)) {
            deployHatsProtocol.deploy();
            hatsAddress = address(deployHatsProtocol.hats());
        }

        // Deploy Payment Splitter Factory
        if (paymentSplitterFactoryAddress == address(0)) {
            deployPaymentSplitterFactory.deploy();
            paymentSplitterFactoryAddress = address(deployPaymentSplitterFactory.paymentSplitterFactory());
            if (paymentSplitterFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Compounder Strategy Factories
        if (skyCompounderStrategyFactoryAddress == address(0)) {
            deploySkyCompounderStrategyFactory.deploy();
            skyCompounderStrategyFactoryAddress = address(
                deploySkyCompounderStrategyFactory.skyCompounderStrategyFactory()
            );
            if (skyCompounderStrategyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Morpho Compounder Strategy Factory
        if (morphoCompounderStrategyFactoryAddress == address(0)) {
            deployMorphoCompounderStrategyFactory.deploy();
            morphoCompounderStrategyFactoryAddress = address(
                deployMorphoCompounderStrategyFactory.morphoCompounderStrategyFactory()
            );
            if (morphoCompounderStrategyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Regen Staker Factory
        if (regenStakerFactoryAddress == address(0)) {
            deployRegenStakerFactory.deploy();
            regenStakerFactoryAddress = address(deployRegenStakerFactory.regenStakerFactory());
            if (regenStakerFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Allocation Mechanism Factory
        if (allocationMechanismFactoryAddress == address(0)) {
            deployAllocationMechanismFactory.deploy();
            allocationMechanismFactoryAddress = address(deployAllocationMechanismFactory.allocationMechanismFactory());
            if (allocationMechanismFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Yearn V3 Strategy Factory
        if (yearnV3StrategyFactoryAddress == address(0)) {
            yearnV3StrategyFactoryAddress = deployYearnV3StrategyFactory.run();
            if (yearnV3StrategyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Deploy Lido Strategy Factory
        if (lidoStrategyFactoryAddress == address(0)) {
            lidoStrategyFactoryAddress = deployLidoStrategyFactory.deploy();
            if (lidoStrategyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Log deployment addresses
        console2.log("\nDeployment Summary:");
        console2.log("------------------");
        console2.log("Starting block:                           ", startingBlock);
        console2.log("Module Proxy Factory:                     ", moduleProxyFactoryAddress);
        console2.log("Dragon Tokenized Strategy:                ", dragonTokenizedStrategyAddress);
        console2.log("Dragon Router:                            ", dragonRouterAddress);
        console2.log("Split Checker:                            ", splitCheckerAddress);
        console2.log("Mock Strategy Singleton:                  ", mockStrategySingletonAddress);
        console2.log("Mock token:                               ", mockTokenAddress);
        console2.log("Mock yield source:                        ", mockYieldSourceAddress);
        console2.log("Linear Allowance Singleton:               ", linearAllowanceSingletonForGnosisSafeAddress);
        console2.log("Hats contract:                            ", hatsAddress);
        console2.log("DragonHatter:                             ", address(deployHatsProtocol.dragonHatter()));
        console2.log("Payment Splitter Factory:                 ", paymentSplitterFactoryAddress);
        console2.log("Sky Compounder Strategy Factory:          ", skyCompounderStrategyFactoryAddress);
        console2.log("Morpho Compounder Strategy Vault Factory: ", morphoCompounderStrategyFactoryAddress);
        console2.log("Regen Staker Factory:                     ", regenStakerFactoryAddress);
        console2.log("Allocation Mechanism Factory:             ", allocationMechanismFactoryAddress);
        console2.log("Yearn V3 Strategy Factory:                ", yearnV3StrategyFactoryAddress);
        console2.log("Lido Strategy Factory:                    ", lidoStrategyFactoryAddress);
        console2.log("------------------");
        console2.log("Top Hat ID:                ", vm.toString(deployHatsProtocol.topHatId()));
        console2.log("Autonomous Admin Hat ID:   ", vm.toString(deployHatsProtocol.autonomousAdminHatId()));
        console2.log("Dragon Admin Hat ID:       ", vm.toString(deployHatsProtocol.dragonAdminHatId()));
        console2.log("Branch Hat ID:             ", vm.toString(deployHatsProtocol.branchHatId()));
        console2.log("------------------");

        string memory contractAddressFilename = "./contract_addresses.txt";
        if (vm.exists(contractAddressFilename)) {
            vm.removeFile(contractAddressFilename);
        }
        vm.writeLine(contractAddressFilename, string.concat("BLOCK_NUMBER=", startingBlock));
        vm.writeLine(
            contractAddressFilename,
            string.concat("MODULE_PROXY_FACTORY_ADDRESS=", vm.toString(moduleProxyFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("DRAGON_TOKENIZED_STRATEGY_ADDRESS=", vm.toString(dragonTokenizedStrategyAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("DRAGON_ROUTER_ADDRESS=", vm.toString(dragonRouterAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("SPLIT_CHECKER_ADDRESS=", vm.toString(splitCheckerAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("MOCK_STRATEGY_SINGLETON_ADDRESS=", vm.toString(mockStrategySingletonAddress))
        );
        vm.writeLine(contractAddressFilename, string.concat("MOCK_TOKEN_ADDRESS=", vm.toString(mockTokenAddress)));
        vm.writeLine(
            contractAddressFilename,
            string.concat("MOCK_YIELD_SOURCE_ADDRESS=", vm.toString(mockYieldSourceAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat(
                "LINEAR_ALLOWANCE_SINGLETON_FOR_GNOSIS_SAFE_ADDRESS=",
                vm.toString(linearAllowanceSingletonForGnosisSafeAddress)
            )
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("PAYMENT_SPLITTER_FACTORY_ADDRESS=", vm.toString(paymentSplitterFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("SKY_COMPOUNDER_STRATEGY_FACTORY_ADDRESS=", vm.toString(skyCompounderStrategyFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat(
                "MORPHO_COMPOUNDER_STRATEGY_FACTORY_ADDRESS=",
                vm.toString(morphoCompounderStrategyFactoryAddress)
            )
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("REGEN_STAKER_FACTORY_ADDRESS=", vm.toString(regenStakerFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("ALLOCATION_MECHANISM_FACTORY_ADDRESS=", vm.toString(allocationMechanismFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("YEARN_V3_STRATEGY_FACTORY_ADDRESS=", vm.toString(yearnV3StrategyFactoryAddress))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("LIDO_STRATEGY_FACTORY_ADDRESS=", vm.toString(lidoStrategyFactoryAddress))
        );
        vm.writeLine(contractAddressFilename, string.concat("HATS_ADDRESS=", vm.toString(hatsAddress)));
        vm.writeLine(
            contractAddressFilename,
            string.concat("DRAGON_HATTER_ADDRESS=", vm.toString(address(deployHatsProtocol.dragonHatter())))
        );
        vm.writeLine(contractAddressFilename, string.concat("TOP_HAT_ID=", vm.toString(deployHatsProtocol.topHatId())));
        vm.writeLine(
            contractAddressFilename,
            string.concat("AUTONOMOUS_ADMIN_HAT_ID=", vm.toString(deployHatsProtocol.autonomousAdminHatId()))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("DRAGON_ADMIN_HAT_ID=", vm.toString(deployHatsProtocol.dragonAdminHatId()))
        );
        vm.writeLine(
            contractAddressFilename,
            string.concat("BRANCH_HAT_ID=", vm.toString(deployHatsProtocol.branchHatId()))
        );
    }
}
