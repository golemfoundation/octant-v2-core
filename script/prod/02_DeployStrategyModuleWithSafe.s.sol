// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import "forge-std/Script.sol";

import { MockStrategy } from "../../test/mocks/zodiac-core/MockStrategy2.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldSource } from "../../test/mocks/core/MockYieldSource.sol";

contract DeployStrategyModuleWithSafe is Script {
    address[] public owners;
    uint256 public threshold;
    address public safeSingleton;
    address public proxyFactory;
    address public moduleFactory;
    address public module;

    address keeper;
    address management;
    address treasury;
    address dragonRouter;
    address tokenizedStrategyImplementation;
    MockERC20 token;
    MockYieldSource yieldSource;

    /// @notice change this according to the strategy
    uint256 maxReportDelay = 30 days;
    string name = "Test Mock Strategy";

    function setUp() public {
        // Initialize owners and threshold
        owners = [vm.envAddress("OWNER")];
        threshold = vm.envUint("SAFE_THRESHOLD");

        // Set the addresses for the Safe singleton and Proxy Factory
        safeSingleton = vm.envAddress("SAFE_SINGLETON");
        proxyFactory = vm.envAddress("SAFE_PROXY_FACTORY");

        moduleFactory = vm.envAddress("MODULE_FACTORY");
        keeper = vm.envAddress("KEEPER");
        management = vm.envAddress("MANAGEMENT");
        treasury = vm.envAddress("TREASURY");
        dragonRouter = vm.envAddress("DRAGON_ROUTER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy Dragon Tokenized Strategy Implementation
        tokenizedStrategyImplementation = address(new DragonTokenizedStrategy());

        // Deploy the mock strategy module
        MockStrategy mockStrategy = new MockStrategy();
        module = address(mockStrategy);

        // Deploy the token
        token = new MockERC20(18);

        // Deploy Mock Yield Source
        yieldSource = new MockYieldSource(address(token));

        // Deploy a new Safe Multisig using the Proxy Factory
        SafeProxyFactory factory = SafeProxyFactory(proxyFactory);
        bytes memory data = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            moduleFactory,
            abi.encodeWithSignature(
                "deployAndEnableModuleFromSafe(address,bytes,uint256)",
                module,
                abi.encode(
                    tokenizedStrategyImplementation,
                    address(token),
                    address(yieldSource),
                    management,
                    keeper,
                    dragonRouter,
                    maxReportDelay,
                    name
                ),
                block.timestamp
            ),
            address(0),
            address(0),
            0,
            address(0)
        );

        SafeProxy proxy = factory.createProxyWithNonce(safeSingleton, data, block.timestamp);

        vm.stopBroadcast();

        // Log the addresses of the newly deployed contracts
        console.log("Safe deployed at:", address(proxy));
        console.log("Token deployed at:", address(token));
        console.log("Yield Source deployed at:", address(yieldSource));
        console.log("Tokenized Strategy Implementation deployed at:", address(tokenizedStrategyImplementation));
        console.log("Module deployed at:", address(module));
    }
}
