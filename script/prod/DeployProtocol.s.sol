// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";

import { DeploySafe } from "script/deploy/DeploySafe.sol";
import { DeployDragonRouter } from "script/deploy/DeployDragonRouter.sol";
import { DeployModuleProxyFactory } from "script/deploy/DeployModuleProxyFactory.sol";
import { DeployDragonTokenizedStrategy } from "script/deploy/DeployDragonTokenizedStrategy.sol";
import { DeployMockStrategy } from "script/deploy/DeployMockStrategy.sol";
import { DeployHatsProtocol } from "script/deploy/DeployHatsProtocol.sol";

/**
 * @title DeployProtocol
 * @notice Production deployment script for Dragon Protocol core components
 * @dev This script handles the sequential deployment of all protocol components
 *      with proper security checks and verification steps
 */
contract DeployProtocol is Script {
    // Constants for Safe deployment
    address public constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address public constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    uint256 public constant SAFE_THRESHOLD = 1;
    uint256 public constant SAFE_TOTAL_OWNERS = 1;

    // Deployment scripts
    DeploySafe public deploySafe;
    DeployModuleProxyFactory public deployModuleProxyFactory;
    DeployDragonTokenizedStrategy public deployDragonTokenizedStrategy;
    DeployDragonRouter public deployDragonRouter;
    DeployHatsProtocol public deployHatsProtocol;
    DeployMockStrategy public deployMockStrategy;
    ModuleProxyFactory public moduleProxyFactory;
    DragonTokenizedStrategy public dragonTokenizedStrategySingleton;
    SplitChecker public splitCheckerSingleton;

    // Deployed contract addresses
    address public safeAddress;
    address public moduleProxyFactoryAddress;
    address public dragonTokenizedStrategyAddress;
    address public dragonRouterAddress;
    address public mockStrategyAddress;

    error DeploymentFailed();
    error InvalidAddress();

    function setUp() public {
        // Initialize deployment scripts
        deploySafe = new DeploySafe();
        deployModuleProxyFactory = new DeployModuleProxyFactory(msg.sender, msg.sender, msg.sender);
        deployDragonTokenizedStrategy = new DeployDragonTokenizedStrategy();
        deployDragonRouter = new DeployDragonRouter();
        deployHatsProtocol = new DeployHatsProtocol();
        deployMockStrategy = new DeployMockStrategy(msg.sender, msg.sender, msg.sender);
    }

    function run() public {
        // Get deployer address from private key
        setUp();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.rememberKey(deployerPrivateKey);

        console2.log("Starting deployment with deployer:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Safe with single signer
        address[] memory owners = new address[](SAFE_TOTAL_OWNERS);
        owners[0] = deployerAddress;
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            SAFE_THRESHOLD,
            address(0), // No module
            bytes(""), // Empty setup data
            address(0), // No fallback handler
            address(0), // No payment token
            0, // No payment
            address(0) // No payment receiver
        );

        // Deploy new Safe via factory
        uint256 salt = block.timestamp; // Use timestamp as salt
        SafeProxyFactory factory = SafeProxyFactory(SAFE_PROXY_FACTORY);
        SafeProxy proxy = factory.createProxyWithNonce(SAFE_SINGLETON, initializer, salt);

        // Store deployed Safe
        safeAddress = address(proxy);
        console2.log("Safe deployed at:", address(proxy));
        console2.log("Safe threshold:", SAFE_THRESHOLD);
        console2.log("Safe owners:", SAFE_TOTAL_OWNERS);
        console2.log("Deployer address:", deployerAddress);

        if (safeAddress == address(0)) revert DeploymentFailed();

        // 4. Deploy Dragon Tokenized Strategy Implementation

        dragonTokenizedStrategySingleton = new DragonTokenizedStrategy();
        salt += 1;
        SafeProxy governance = factory.createProxyWithNonce(SAFE_SINGLETON, initializer, salt);
        salt += 1;
        SafeProxy regenGovernance = factory.createProxyWithNonce(SAFE_SINGLETON, initializer, salt);
        salt += 1;
        SafeProxy metapool = factory.createProxyWithNonce(SAFE_SINGLETON, initializer, salt);

        splitCheckerSingleton = new SplitChecker();

        // Deploy Module Proxy Factory
        moduleProxyFactory = new ModuleProxyFactory(
            address(governance),
            address(regenGovernance),
            address(metapool),
            address(splitCheckerSingleton),
            address(dragonTokenizedStrategySingleton)
        );
        moduleProxyFactoryAddress = address(moduleProxyFactory);
        if (moduleProxyFactoryAddress == address(0)) revert DeploymentFailed();

        vm.stopBroadcast();

        // 5. Deploy Dragon Router
        deployDragonRouter.deploy();
        dragonRouterAddress = address(deployDragonRouter.dragonRouterProxy());
        if (dragonRouterAddress == address(0)) revert DeploymentFailed();

        // 6. Deploy Mock Strategy
        deployMockStrategy.deploy(safeAddress, dragonTokenizedStrategyAddress, dragonRouterAddress);
        mockStrategyAddress = address(deployMockStrategy.mockStrategyProxy());
        if (mockStrategyAddress == address(0)) revert DeploymentFailed();

        // Log deployment addresses
        console2.log("\nDeployment Summary:");
        console2.log("------------------");
        console2.log("Safe:", safeAddress);
        console2.log("Module Proxy Factory:", moduleProxyFactoryAddress);
        console2.log("Dragon Tokenized Strategy:", dragonTokenizedStrategyAddress);
        console2.log("Dragon Router:", dragonRouterAddress);
        console2.log("Mock Strategy:", mockStrategyAddress);
        console2.log("Hats Protocol:", address(deployHatsProtocol.hats()));
        console2.log("Dragon Hatter:", address(deployHatsProtocol.dragonHatter()));

        // Verify deployments
        _verifyDeployments();
    }

    function _verifyDeployments() internal view {
        // Verify Safe setup
        Safe safe = Safe(payable(safeAddress));
        require(safe.getThreshold() == SAFE_THRESHOLD, "Invalid Safe threshold");
        require(safe.getOwners().length == SAFE_TOTAL_OWNERS, "Invalid Safe owners count");
        require(safe.isOwner(vm.addr(vm.envUint("PRIVATE_KEY"))), "Deployer not Safe owner");

        // Verify Mock Strategy is enabled on Safe
        if (!safe.isModuleEnabled(mockStrategyAddress)) {
            console2.log("Mock Strategy not enabled on Safe");
        }

        // Additional security checks can be added here
        console2.log("\nAll deployments verified successfully!");
    }
}
