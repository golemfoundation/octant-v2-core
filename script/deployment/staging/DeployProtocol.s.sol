// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DeployLinearAllowanceSingletonForGnosisSafe } from "script/deploy/DeployLinearAllowanceSingletonForGnosisSafe.sol";
import { DeployPaymentSplitterFactory } from "script/deploy/DeployPaymentSplitterFactory.sol";
import { DeploySkyCompounderStrategyFactory } from "script/deploy/DeploySkyCompounderStrategyFactory.sol";
import { DeployMorphoCompounderStrategyFactory } from "script/deploy/DeployMorphoCompounderStrategyFactory.sol";
import { DeployAaveV3StrategyFactory } from "script/deploy/DeployAaveV3StrategyFactory.sol";
import { DeployAllocationMechanismFactory } from "script/deploy/DeployAllocationMechanismFactory.sol";
import { DeployYearnV3StrategyFactory } from "script/deploy/DeployYearnV3StrategyFactory.s.sol";
import { DeployLidoStrategyFactory } from "script/deploy/DeployLidoStrategyFactory.sol";
import { DeployedAddresses } from "script/helpers/DeployedAddresses.sol";

/**
 * @title DeployProtocol
 * @notice Production deployment script for Octant Protocol core components
 * @dev This script handles the sequential deployment of all protocol components
 */
contract DeployProtocol is Script {
    // Deployers
    DeployLinearAllowanceSingletonForGnosisSafe public deployLinearAllowanceSingletonForGnosisSafe;
    DeployPaymentSplitterFactory public deployPaymentSplitterFactory;
    DeploySkyCompounderStrategyFactory public deploySkyCompounderStrategyFactory;
    DeployMorphoCompounderStrategyFactory public deployMorphoCompounderStrategyFactory;
    DeployAaveV3StrategyFactory public deployAaveV3StrategyFactory;
    DeployAllocationMechanismFactory public deployAllocationMechanismFactory;
    DeployYearnV3StrategyFactory public deployYearnV3StrategyFactory;
    DeployLidoStrategyFactory public deployLidoStrategyFactory;

    // Address registry for network-specific deployments
    DeployedAddresses public immutable deployedAddresses;

    // Deployed contract addresses
    address public linearAllowanceSingletonForGnosisSafeAddress;
    address public paymentSplitterFactoryAddress;
    address public skyCompounderStrategyFactoryAddress;
    address public morphoCompounderStrategyFactoryAddress;
    address public aaveV3StrategyFactoryAddress;
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
        deployLinearAllowanceSingletonForGnosisSafe = new DeployLinearAllowanceSingletonForGnosisSafe();
        deployPaymentSplitterFactory = new DeployPaymentSplitterFactory();
        deploySkyCompounderStrategyFactory = new DeploySkyCompounderStrategyFactory();
        deployMorphoCompounderStrategyFactory = new DeployMorphoCompounderStrategyFactory();
        deployAaveV3StrategyFactory = new DeployAaveV3StrategyFactory();
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

        linearAllowanceSingletonForGnosisSafeAddress = addresses.linearAllowanceSingleton;
        paymentSplitterFactoryAddress = addresses.paymentSplitterFactory;
        skyCompounderStrategyFactoryAddress = addresses.skyCompounderStrategyFactory;
        morphoCompounderStrategyFactoryAddress = addresses.morphoCompounderStrategyFactory;
        aaveV3StrategyFactoryAddress = addresses.aaveV3StrategyFactory;
        regenStakerFactoryAddress = addresses.regenStakerFactory;
        allocationMechanismFactoryAddress = addresses.allocationMechanismFactory;
        yieldDonatingTokenizedStrategyAddress = addresses.yieldDonatingTokenizedStrategy;
        yearnV3StrategyFactoryAddress = addresses.yearnV3StrategyFactory;
        lidoStrategyFactoryAddress = addresses.lidoStrategyFactory;
    }

    // This entrypoint intentionally coordinates multiple conditional deployments.
    // solhint-disable-next-line code-complexity
    function run() public {
        string memory startingBlock = vm.toString(block.number);

        setUp();
        setUpDeployedContracts();

        // Deploy LinearAllowanceSingletonForGnosisSafe
        if (linearAllowanceSingletonForGnosisSafeAddress == address(0)) {
            deployLinearAllowanceSingletonForGnosisSafe.deploy();
            linearAllowanceSingletonForGnosisSafeAddress = address(
                deployLinearAllowanceSingletonForGnosisSafe.linearAllowanceSingletonForGnosisSafe()
            );
            if (linearAllowanceSingletonForGnosisSafeAddress == address(0)) revert DeploymentFailed();
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

        // Deploy Aave V3 Strategy Factory
        if (aaveV3StrategyFactoryAddress == address(0)) {
            deployAaveV3StrategyFactory.deploy();
            aaveV3StrategyFactoryAddress = address(deployAaveV3StrategyFactory.aaveV3StrategyFactory());
            if (aaveV3StrategyFactoryAddress == address(0)) revert DeploymentFailed();
        }

        // Regen Staker Factory must be pre-deployed via Safe multisig
        // Use script/deploy/DeployRegenStakerFactory.s.sol with SAFE_ADDRESS env var
        if (regenStakerFactoryAddress == address(0)) {
            revert("RegenStakerFactory must be deployed via Safe multisig first");
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
        console2.log("Linear Allowance Singleton:               ", linearAllowanceSingletonForGnosisSafeAddress);
        console2.log("Payment Splitter Factory:                 ", paymentSplitterFactoryAddress);
        console2.log("Sky Compounder Strategy Factory:          ", skyCompounderStrategyFactoryAddress);
        console2.log("Morpho Compounder Strategy Vault Factory: ", morphoCompounderStrategyFactoryAddress);
        console2.log("Aave V3 Strategy Factory:                 ", aaveV3StrategyFactoryAddress);
        console2.log("Regen Staker Factory:                     ", regenStakerFactoryAddress);
        console2.log("Allocation Mechanism Factory:             ", allocationMechanismFactoryAddress);
        console2.log("Yearn V3 Strategy Factory:                ", yearnV3StrategyFactoryAddress);
        console2.log("Lido Strategy Factory:                    ", lidoStrategyFactoryAddress);
        console2.log("------------------");

        string memory contractAddressFilename = "./contract_addresses.txt";
        if (vm.exists(contractAddressFilename)) {
            vm.removeFile(contractAddressFilename);
        }
        vm.writeLine(contractAddressFilename, string.concat("BLOCK_NUMBER=", startingBlock));
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
            string.concat("AAVE_V3_STRATEGY_FACTORY_ADDRESS=", vm.toString(aaveV3StrategyFactoryAddress))
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
    }
}
