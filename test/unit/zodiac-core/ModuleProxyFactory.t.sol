// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { BaseTest } from "./Base.t.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { IModuleProxyFactory } from "src/zodiac-core/interfaces/IModuleProxyFactory.sol";
import { ISplitChecker } from "src/zodiac-core/interfaces/ISplitChecker.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import { MockModule } from "test/mocks/zodiac-core/MockModule.sol";
import { MockSafe } from "test/mocks/zodiac-core/MockSafe.sol";
import { MockLinearAllowance } from "test/mocks/zodiac-core/MockLinearAllowance.sol";
import { MockSafeDragonRouter } from "test/mocks/zodiac-core/MockSafeDragonRouter.sol";
import { MockDragonRouterSetup } from "test/mocks/zodiac-core/MockDragonRouterSetup.sol";
import { MultiSendCallOnly } from "src/utils/libs/Safe/MultiSendCallOnly.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";

contract ModuleProxyFactoryTest is BaseTest {
    ModuleProxyFactory public factory;
    address public owner = makeAddr("owner");
    address public splitChecker = address(new SplitChecker());
    address public dragonRouter = makeAddr("dragonRouter");
    address public governance = makeAddr("governance");
    address public regenGovernance = makeAddr("regenGovernance");
    address public metapool = makeAddr("metapool");
    address public opexVault = makeAddr("opexVault");
    address[] public strategies;
    address public mockModuleMaster;
    address public splitCheckerImpl;
    address public dragonRouterImpl;
    address public linearAllowanceImpl;
    uint256 public blockTimestampAtSetup;
    MultiSendCallOnly public multiSendCallOnly;
    MockSafe public safe;

    function setUp() public {
        factory = new ModuleProxyFactory(governance, regenGovernance, metapool, splitChecker, dragonRouter);
        blockTimestampAtSetup = block.timestamp;
        mockModuleMaster = address(new MockModule());
        multiSendCallOnly = new MultiSendCallOnly();
        safe = new MockSafe();
        splitCheckerImpl = address(new SplitChecker());
        dragonRouterImpl = address(new MockSafeDragonRouter(address(0)));
        linearAllowanceImpl = address(new MockLinearAllowance());
    }

    function setupFailsWithZeroGovernance() public {
        vm.expectRevert("ZeroAddress");
        new ModuleProxyFactory(address(0), regenGovernance, metapool, splitChecker, dragonRouter);
    }

    function setupFailsWithZeroRegenGovernance() public {
        vm.expectRevert("ZeroAddress");
        new ModuleProxyFactory(governance, address(0), metapool, splitChecker, dragonRouter);
    }

    function setupFailsWithZeroMetapool() public {
        vm.expectRevert("ZeroAddress");
        new ModuleProxyFactory(governance, regenGovernance, address(0), splitChecker, dragonRouter);
    }

    function setupFailsWithZeroSplitChecker() public {
        vm.expectRevert("ZeroAddress");
        new ModuleProxyFactory(governance, regenGovernance, metapool, address(0), dragonRouter);
    }

    function setupFailsWithZeroDragonRouter() public {
        vm.expectRevert("ZeroAddress");
        new ModuleProxyFactory(governance, regenGovernance, metapool, splitChecker, address(0));
    }

    function testDeployDragonRouterInitializesProxy() public {
        MockDragonRouterSetup mockImplementation = new MockDragonRouterSetup();
        ModuleProxyFactory localFactory = new ModuleProxyFactory(
            governance,
            regenGovernance,
            metapool,
            splitCheckerImpl,
            address(mockImplementation)
        );

        address[] memory localStrategies = new address[](2);
        localStrategies[0] = makeAddr("strategy1");
        localStrategies[1] = makeAddr("strategy2");

        address payable proxy = localFactory.deployDragonRouter(owner, localStrategies, opexVault, 1234);

        MockDragonRouterSetup deployed = MockDragonRouterSetup(proxy);

        assertEq(deployed.owner(), owner, "Owner not set");
        assertEq(deployed.governance(), governance, "Governance not set");
        assertEq(deployed.regenGovernance(), regenGovernance, "Regen governance not set");
        assertEq(deployed.splitChecker(), localFactory.SPLIT_CHECKER(), "SplitChecker not set");
        assertEq(deployed.opexVault(), opexVault, "Opex vault not set");
        assertEq(deployed.metapool(), metapool, "Metapool not set");
        assertEq(deployed.strategiesLength(), localStrategies.length, "Strategies length not set");
        assertEq(deployed.strategiesHash(), keccak256(abi.encode(localStrategies)), "Strategies hash mismatch");
    }

    function testSplitCheckerDeployedAtExpectedAddress() public view {
        // Define the constants used in the contract
        uint256 DEFAULT_MAX_OPEX_SPLIT = 0.5e18;
        uint256 DEFAULT_MIN_METAPOOL_SPLIT = 0.05e18;

        // Recreate initializer data used during factory construction
        bytes memory initializer = abi.encodeWithSignature(
            "initialize(address,uint256,uint256)",
            governance,
            DEFAULT_MAX_OPEX_SPLIT,
            DEFAULT_MIN_METAPOOL_SPLIT
        );

        // calculate the expected address
        address expectedSplitChecker = factory.getModuleAddress(splitChecker, initializer, blockTimestampAtSetup);

        // Get the actual SPLIT_CHECKER address from the factory
        address actualSplitChecker = factory.SPLIT_CHECKER();

        // Verify the SPLIT_CHECKER code is deployed
        assertTrue(actualSplitChecker.code.length > 0, "SPLIT_CHECKER has no code");

        // Verify SPLIT_CHECKER is properly initialized
        assertEq(actualSplitChecker, expectedSplitChecker, "SplitChecker address does not match expected address");
    }

    function testCalculateProxyAddress() public {
        bytes memory initializer = abi.encodeWithSignature("setUp(address)", address(this));
        uint256 saltNonce = 12345;

        address calculatedAddress = factory.getModuleAddress(mockModuleMaster, initializer, saltNonce);

        address deployedAddress = factory.deployModule(mockModuleMaster, initializer, saltNonce);

        assertEq(calculatedAddress, deployedAddress, "Calculated address should match deployed address");
    }

    function testGetModuleAddress() public {
        bytes memory initializer = abi.encodeWithSignature("setUp(address)", address(this));
        uint256 saltNonce = 12345;

        address addressViaGetModule = factory.getModuleAddress(mockModuleMaster, initializer, saltNonce);

        address deployedAddress = factory.deployModule(mockModuleMaster, initializer, saltNonce);

        assertEq(addressViaGetModule, deployedAddress, "Calculated address should match deployed address");
    }

    function testFuzz_DeterministicAddresses(uint256 saltNonce) public {
        vm.assume(saltNonce > 0);

        bytes memory initializer = abi.encodeWithSignature("setUp(address)", address(this));

        address expectedAddress = factory.getModuleAddress(mockModuleMaster, initializer, saltNonce);

        address deployedAddress = factory.deployModule(mockModuleMaster, initializer, saltNonce);

        assertEq(expectedAddress, deployedAddress, "Address calculation should be deterministic");
    }

    function testMultiSendBatchDeployment() public {
        bytes memory splitCheckerInit = abi.encodeWithSignature(
            "initialize(address,uint256,uint256)",
            governance,
            0.5e18,
            0.05e18
        );
        uint256 splitCheckerSalt = 100;

        address predictedSplitChecker = factory.getModuleAddress(splitCheckerImpl, splitCheckerInit, splitCheckerSalt);

        bytes memory dragonRouterInit = abi.encodeWithSignature("setUp(address)", predictedSplitChecker);
        uint256 dragonRouterSalt = 200;
        address predictedDragonRouter = factory.getModuleAddress(dragonRouterImpl, dragonRouterInit, dragonRouterSalt);

        bytes memory tx1 = _buildDeployModuleTx(factory, splitCheckerImpl, splitCheckerInit, splitCheckerSalt);

        bytes memory tx2 = _buildDeployModuleTx(factory, dragonRouterImpl, dragonRouterInit, dragonRouterSalt);

        bytes memory tx3 = _buildEnableModuleTx(linearAllowanceImpl);

        bytes memory batchData = bytes.concat(tx1, tx2, tx3);

        bool success = safe.execTransactionViaDelegateCall(
            address(multiSendCallOnly),
            abi.encodeWithSelector(multiSendCallOnly.multiSend.selector, batchData)
        );

        assertTrue(success, "MultiSend transaction failed");
        assertTrue(predictedSplitChecker.code.length > 0, "SplitChecker not deployed");
        assertTrue(predictedDragonRouter.code.length > 0, "DragonRouter not deployed");
        assertTrue(safe.modules(linearAllowanceImpl), "LinearAllowance module not enabled");

        assertEq(
            SplitChecker(predictedSplitChecker).governance(),
            governance,
            "SplitChecker governance not set correctly"
        );

        assertEq(
            MockSafeDragonRouter(predictedDragonRouter).splitChecker(),
            predictedSplitChecker,
            "DragonRouter not initialized with SplitChecker"
        );
    }

    function _buildDeployModuleTx(
        ModuleProxyFactory factoryInstance,
        address implementation,
        bytes memory initializer,
        uint256 salt
    ) internal pure returns (bytes memory) {
        bytes memory callData = abi.encodeWithSelector(
            factoryInstance.deployModule.selector,
            implementation,
            initializer,
            salt
        );

        return abi.encodePacked(uint8(0), address(factoryInstance), uint256(0), uint256(callData.length), callData);
    }

    function _buildEnableModuleTx(address moduleAddress) internal view returns (bytes memory) {
        bytes memory callData = abi.encodeWithSelector(MockSafe.enableModule.selector, moduleAddress);

        return abi.encodePacked(uint8(0), address(safe), uint256(0), uint256(callData.length), callData);
    }
}
