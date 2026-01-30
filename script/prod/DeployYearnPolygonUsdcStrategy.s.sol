// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

import { YearnPolygonUsdcStrategy } from "src/zodiac-core/modules/YearnPolygonUsdcStrategy.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";

contract DeployYearnPolygonUsdcStrategy is Script {
    address[] public owners;
    uint256 public threshold;
    address public safeSingleton;
    address public proxyFactory;
    address public moduleFactory;
    address public module;

    address tokenizedStrategyImplementation;
    address management;
    address keeper;
    address dragonRouter;
    address splitCheckerImplementation;
    address metapool;
    address dragonRouterImplementation;
    SafeProxy proxy;
    bool isSafeDeployed;

    /// @notice change this according to the strategy
    uint256 maxReportDelay = 7 days;

    function run() public {
        vm.startBroadcast();

        try vm.prompt("Enter DragonRouter proxy address") returns (string memory res) {
            dragonRouter = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid DragonRouter proxy address");
        }

        try vm.prompt("Enter DragonRouter implementation address") returns (string memory res) {
            dragonRouterImplementation = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid DragonRouter implementation address");
        }

        try vm.prompt("Enter SplitChecker implementation address") returns (string memory res) {
            splitCheckerImplementation = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid SplitChecker implementation address");
        }

        try vm.prompt("Enter Metapool address") returns (string memory res) {
            metapool = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid Metapool address");
        }

        try
            vm.prompt("Is the module factory already deployed? (if yes, provide the address) / (if no, provide 'no')")
        returns (string memory res) {
            if (keccak256(abi.encode(res)) == keccak256(abi.encode("no"))) {
                moduleFactory = address(
                    new ModuleProxyFactory(
                        msg.sender,
                        msg.sender,
                        splitCheckerImplementation,
                        metapool,
                        dragonRouterImplementation
                    )
                );
                console.log("Module Factory deployed at:", moduleFactory);
            } else {
                moduleFactory = vm.parseAddress(res);
            }
        } catch (bytes memory) {
            revert("Invalid Module Factory Response");
        }

        try vm.prompt("Is Safe already deployed? (if yes, provide the address) / (if no, provide 'no')") returns (
            string memory res
        ) {
            if (keccak256(abi.encode(res)) != keccak256(abi.encode("no"))) {
                proxy = SafeProxy(payable(vm.parseAddress(res)));
                isSafeDeployed = true;
            }
        } catch (bytes memory) {
            revert("Invalid Safe Deployment Response");
        }

        try
            vm.prompt(
                "Is the dragon tokenized strategy implementation already deployed? (if yes, provide the address) / (if no, provide 'no')"
            )
        returns (string memory res) {
            if (keccak256(abi.encode(res)) == keccak256(abi.encode("no"))) {
                tokenizedStrategyImplementation = address(new DragonTokenizedStrategy());
                console.log("Tokenized Strategy Implementation deployed at:", address(tokenizedStrategyImplementation));
            } else {
                tokenizedStrategyImplementation = vm.parseAddress(res);
            }
        } catch (bytes memory) {
            revert("Invalid Tokenized Strategy Implementation Deployment Response");
        }

        try
            vm.prompt(
                "Is the strategy module implementation already deployed? (if yes, provide the address) / (if no, provide 'no')"
            )
        returns (string memory res) {
            if (keccak256(abi.encode(res)) == keccak256(abi.encode("no"))) {
                module = address(new YearnPolygonUsdcStrategy());
                console.log("Strategy Module Implementation deployed at:", address(module));
            } else {
                module = vm.parseAddress(res);
            }
        } catch (bytes memory) {
            revert("Invalid Module Deployment Response");
        }

        if (!isSafeDeployed) {
            _deploySafe();
        }

        vm.stopBroadcast();

        if (isSafeDeployed) {
            _deployModuleForSafe();
        }
    }

    function _deployModuleForSafe() internal {
        address dragonVaultModule = ModuleProxyFactory(moduleFactory).deployModule(
            module,
            abi.encodeWithSignature(
                "setUp(bytes)",
                abi.encode(
                    address(proxy),
                    abi.encode(tokenizedStrategyImplementation, management, keeper, dragonRouter, maxReportDelay)
                )
            ),
            block.timestamp
        );

        console.log(
            "Yearn Polygon USDC Strategy Module: (NOTE: module not linked to safe yet - to link run script ./AttachModule.s.sol) ",
            dragonVaultModule
        );
    }

    function _deploySafe() internal {
        // Initialize owners and threshold
        owners = [vm.envAddress("OWNER")];
        threshold = vm.envUint("SAFE_THRESHOLD");

        // Set the addresses for the Safe singleton and Proxy Factory
        safeSingleton = vm.envAddress("SAFE_SINGLETON");
        proxyFactory = vm.envAddress("SAFE_PROXY_FACTORY");

        try vm.prompt("Enter keeper address") returns (string memory res) {
            keeper = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid keeper address");
        }

        try vm.prompt("Enter management address") returns (string memory res) {
            management = vm.parseAddress(res);
        } catch (bytes memory) {
            revert("Invalid management address");
        }

        /// @notice default max report delay
        maxReportDelay = 7 days;

        // Deploy a new Safe Multisig using the Proxy Factory
        bytes memory data = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            moduleFactory,
            abi.encodeWithSignature(
                "deployAndEnableModuleFromSafe(address,bytes,uint256)",
                module,
                abi.encode(tokenizedStrategyImplementation, management, keeper, dragonRouter, maxReportDelay),
                block.timestamp
            ),
            address(0),
            address(0),
            0,
            address(0)
        );

        // Deploy a new Safe Multisig using the Proxy Factory
        SafeProxyFactory factory = SafeProxyFactory(proxyFactory);
        proxy = factory.createProxyWithNonce(safeSingleton, data, block.timestamp);
        console.log("Safe deployed at:", address(proxy), "with strategy module added");
    }
}
