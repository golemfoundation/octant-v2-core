// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { BaseStrategy, ERC20 } from "src/core/BaseStrategy.sol";
import { MockYieldSource } from "test/mocks/core/tokenized-strategies/MockYieldSource.sol";
import { MockStrategy } from "test/mocks/core/tokenized-strategies/MockStrategy.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeployYieldDonatingStrategy } from "script/deploy/DeployYieldDonatingStrategy.s.sol";

/**
 * @title YieldDonatingTokenizedStrategyTest
 * @author octant.finance
 * @notice Unit tests for YieldDonatingTokenizedStrategy, including deterministic deployment tests
 * @dev Tests both the contract functionality and deployment characteristics
 */
contract YieldDonatingTokenizedStrategyTest is Test {
    // Contracts
    YieldDonatingTokenizedStrategy public strategy;

    // Deployment variables
    DeployYieldDonatingStrategy public deployer;
    bytes32 public deploymentSalt;
    address public deployerAddress;

    /**
     * @notice Set up the test environment
     */
    function setUp() public {
        // Deploy the strategy implementation
        strategy = new YieldDonatingTokenizedStrategy();

        // Setup for deterministic deployment tests
        deployer = new DeployYieldDonatingStrategy();
        deploymentSalt = deployer.DEPLOYMENT_SALT();

        // Create test address for deployment
        deployerAddress = makeAddr("deployer");

        // Fund the deployer with some ETH for gas
        vm.deal(deployerAddress, 10 ether);
    }

    /**
     * @notice Test the constructor behavior
     * @dev Verifies the asset is set to address(1) to prevent re-initialization
     */
    function testConstructorBehavior() public view {
        // Verify asset is set to address(1)
        assertEq(strategy.asset(), address(1), "Asset should be set to address(1) in constructor");
    }

    /**
     * @notice Test that the contract cannot be initialized after deployment
     * @dev Constructor sets asset to address(1), which prevents initialization
     */
    function testCannotInitialize() public {
        // Create fake addresses for the test
        address mockAsset = makeAddr("mockAsset");
        address mockManagement = makeAddr("mockManagement");
        address mockKeeper = makeAddr("mockKeeper");
        address mockEmergencyAdmin = makeAddr("mockEmergencyAdmin");
        address mockDragonRouter = makeAddr("mockDragonRouter");

        // Attempt to initialize should revert
        vm.expectRevert("initialized");
        strategy.initialize(
            mockAsset,
            "Test Strategy",
            "tsTEST",
            mockManagement,
            mockKeeper,
            mockEmergencyAdmin,
            mockDragonRouter,
            true // enableBurning
        );
    }

    /**
     * @notice Test that we can access functions from the parent contract
     * @dev The strategy inherits functionality from DragonTokenizedStrategy
     */
    function testInheritedFunctions() public view {
        // Test accessing the API version
        string memory apiVersion = strategy.apiVersion();
        assertEq(apiVersion, "1.0.0", "API version should match parent contract");
    }

    /**
     * @notice Test that the strategy is deployed to the expected address
     * @dev Verifies deterministic deployment using CREATE2
     */
    function testDeterministicDeployment() public {
        // Pre-compute the expected address
        address expectedAddress = _computeCreate2Address(
            deployerAddress,
            deploymentSalt,
            type(YieldDonatingTokenizedStrategy).creationCode
        );

        console.log("Expected address:", expectedAddress);

        // First deployment
        vm.startPrank(deployerAddress);
        YieldDonatingTokenizedStrategy deterministicStrategy = new YieldDonatingTokenizedStrategy{
            salt: deploymentSalt
        }();
        address actualAddress = address(deterministicStrategy);
        vm.stopPrank();

        console.log("Actual deployed address:", actualAddress);

        // Verify addresses match
        assertEq(actualAddress, expectedAddress, "First deployment address doesn't match expected");

        // Verify asset is set to address(1)
        assertEq(deterministicStrategy.asset(), address(1), "Asset not correctly set to address(1)");

        // Try to deploy again with the same salt (should revert)
        vm.startPrank(deployerAddress);
        try new YieldDonatingTokenizedStrategy{ salt: deploymentSalt }() returns (YieldDonatingTokenizedStrategy) {
            fail();
        } catch {
            console.log("Create Collision: Cannot deploy with the same salt");
        }
        vm.stopPrank();

        // Check what happens with a different salt

        // Pre-compute the new expected address
        address newExpectedAddress = _computeCreate2Address(
            deployerAddress,
            keccak256("DIFFERENT_SALT"),
            type(YieldDonatingTokenizedStrategy).creationCode
        );

        console.log("New expected address (different salt):", newExpectedAddress);

        // Deploy with different salt
        vm.startPrank(deployerAddress);
        YieldDonatingTokenizedStrategy newStrategy = new YieldDonatingTokenizedStrategy{
            salt: keccak256("DIFFERENT_SALT")
        }();
        address newActualAddress = address(newStrategy);
        vm.stopPrank();

        console.log("New actual deployed address:", newActualAddress);

        // Verify addresses match the new expected address
        assertEq(newActualAddress, newExpectedAddress, "Second deployment address doesn't match expected");

        // Verify addresses are different from first deployment
        assertTrue(newActualAddress != actualAddress, "Addresses should be different with different salts");
    }

    /**
     * @notice Test deploying from different addresses produces different addresses
     * @dev Verifies that the deployer address affects the resulting contract address
     */
    function testDifferentDeployers() public {
        // Deploy from first address
        vm.startPrank(deployerAddress);
        YieldDonatingTokenizedStrategy strategy1 = new YieldDonatingTokenizedStrategy{ salt: deploymentSalt }();
        address address1 = address(strategy1);
        vm.stopPrank();

        // Create a second deployer address
        address deployer2 = makeAddr("deployer2");
        vm.deal(deployer2, 10 ether);

        // Deploy from second address with same salt
        vm.startPrank(deployer2);
        YieldDonatingTokenizedStrategy strategy2 = new YieldDonatingTokenizedStrategy{ salt: deploymentSalt }();
        address address2 = address(strategy2);
        vm.stopPrank();

        // Addresses should be different due to different deployers
        assertTrue(address1 != address2, "Addresses should be different with different deployers");

        // Verify both addresses have asset set to address(1)
        assertEq(strategy1.asset(), address(1), "Asset not correctly set to address(1) in first deployment");
        assertEq(strategy2.asset(), address(1), "Asset not correctly set to address(1) in second deployment");
    }

    /**
     * @notice Helper function to compute the expected address from create2 deployment
     * @param _deployer Address of the deployer
     * @param _salt Salt used for deployment
     * @param _creationCode Contract creation bytecode
     * @return Computed address where the contract should be deployed
     */
    function _computeCreate2Address(
        address _deployer,
        bytes32 _salt,
        bytes memory _creationCode
    ) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), _deployer, _salt, keccak256(_creationCode)))))
            );
    }
}
