// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { console2 } from "forge-std/Test.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { DeployModuleProxyFactory } from "./DeployModuleProxyFactory.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";

contract DeployMockStrategy is DeployModuleProxyFactory {
    MockStrategy public mockStrategySingleton;
    IMockStrategy public mockStrategyProxy;
    MockYieldSource public mockYieldSource;
    MockERC20 public token;

    address public safeAddress;
    address public dragonTokenizedStrategyAddress;
    address public dragonRouterProxyAddress;

    constructor(
        address _governance,
        address _regenGovernance,
        address _metapool
    ) DeployModuleProxyFactory(_governance, _regenGovernance, _metapool) {}

    function deploy() public override {
        // Store addresses in storage
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy test token
        token = new MockERC20(18);

        // Deploy implementation
        mockStrategySingleton = new MockStrategy();

        // Deploy mock yield source
        mockYieldSource = new MockYieldSource(address(token));

        vm.stopBroadcast();
    }

    function deploy(
        address _safeAddress,
        address _dragonTokenizedStrategyAddress,
        address _dragonRouterProxyAddress
    ) public virtual {
        deploy(_safeAddress, _dragonTokenizedStrategyAddress, _dragonRouterProxyAddress, address(0));
    }

    function deploy(
        address _safeAddress,
        address _dragonTokenizedStrategyAddress,
        address _dragonRouterProxyAddress,
        address _moduleProxyFactoryAddress
    ) public virtual {
        // Store addresses in storage
        safeAddress = _safeAddress;
        dragonTokenizedStrategyAddress = _dragonTokenizedStrategyAddress;
        dragonRouterProxyAddress = _dragonRouterProxyAddress;

        deploy();

        // Deploy module proxy factory first
        if (_moduleProxyFactoryAddress == address(0)) {
            DeployModuleProxyFactory.deploy();
        } else {
            moduleProxyFactory = ModuleProxyFactory(_moduleProxyFactoryAddress);
        }

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        uint256 _maxReportDelay = 1 days;
        string memory _name = "Mock Dragon Strategy";

        // Prepare initialization data
        // First encode the strategy initialization parameters
        bytes memory strategyParams = abi.encode(
            dragonTokenizedStrategyAddress,
            address(token),
            address(mockYieldSource),
            safeAddress, // management
            safeAddress, // keeper
            dragonRouterProxyAddress,
            _maxReportDelay, // maxReportDelay
            _name,
            safeAddress // regenGovernance
        );

        // Then encode the full initialization call with owner and params
        bytes memory initData = abi.encodeWithSignature("setUp(bytes)", abi.encode(safeAddress, strategyParams));

        // Deploy and enable module on safe
        address proxy = moduleProxyFactory.deployModule(address(mockStrategySingleton), initData, block.timestamp);
        mockStrategyProxy = IMockStrategy(payable(address(proxy)));

        // ISafe(safeAddress).enableModule(address(mockStrategyProxy));

        vm.stopBroadcast();
    }
}
