// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { TestPlus } from "solady-test/utils/TestPlus.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import "@gnosis.pm/safe-contracts/contracts/Safe.sol";

import { SetupIntegrationTest } from "../../Setup.t.sol";
import { TokenizedStrategy__StrategyNotInShutdown, TokenizedStrategy__NotEmergencyAuthorized, TokenizedStrategy__HatsAlreadyInitialized, TokenizedStrategy__NotKeeperOrManagement, TokenizedStrategy__NotManagement } from "src/errors.sol";

contract HatsIntegrationTest is SetupIntegrationTest {
    // Setup test addresses
    address public keeper = address(0x123);
    address public manager = address(0x456);
    address public emergency = address(0x789);
    address public regenGov = address(0xabc);
    address public unauthorized = address(0xdef);
    function setUp() public override {
        super.setUp();

        // Create signature array for safe transaction
        uint256[] memory signerIndices = new uint256[](TEST_THRESHOLD);
        for (uint256 i = 0; i < TEST_THRESHOLD; i++) {
            signerIndices[i] = i;
        }

        // // Get role hat IDs from existing deployment
        uint256 keeperHatId = dragonHatter.getRoleHat(dragonHatter.KEEPER_ROLE());
        uint256 managementHatId = dragonHatter.getRoleHat(dragonHatter.MANAGEMENT_ROLE());
        uint256 emergencyHatId = dragonHatter.getRoleHat(dragonHatter.EMERGENCY_ROLE());
        uint256 regenGovernanceHatId = dragonHatter.getRoleHat(dragonHatter.REGEN_GOVERNANCE_ROLE());

        // // Setup MockStrategy with Hats Protocol through safe
        bytes memory setupHatsData = abi.encodeWithSignature(
            "setupHatsProtocol(address,uint256,uint256,uint256,uint256)",
            address(HATS),
            keeperHatId,
            managementHatId,
            emergencyHatId,
            regenGovernanceHatId
        );

        execTransaction(address(mockStrategyProxy), 0, setupHatsData, signerIndices);

        // Grant roles using DragonHatter
        vm.startPrank(deployer);
        dragonHatter.grantRole(dragonHatter.KEEPER_ROLE(), keeper);
        dragonHatter.grantRole(dragonHatter.MANAGEMENT_ROLE(), manager);
        dragonHatter.grantRole(dragonHatter.EMERGENCY_ROLE(), emergency);
        dragonHatter.grantRole(dragonHatter.REGEN_GOVERNANCE_ROLE(), regenGov);
        vm.stopPrank();

        // Deposit some tokens into the strategy first
        vm.startPrank(address(deployedSafe));
        token.mint(address(deployedSafe), 1 ether);
        token.approve(address(mockStrategyProxy), 1 ether);
        mockStrategyProxy.deposit(1 ether, address(deployedSafe));
        token.mint(address(mockStrategyProxy), 1 ether);
        vm.stopPrank();
    }
    function testCannotSetupHatsProtocolTwice() public {
        // Get role hat IDs from existing deployment
        uint256 keeperHatId = 1;
        uint256 managementHatId = 2;
        uint256 emergencyHatId = 3;
        uint256 regenGovernanceHatId = 4;

        vm.startPrank(address(deployedSafe));
        vm.expectRevert(TokenizedStrategy__HatsAlreadyInitialized.selector);
        mockStrategyProxy.setupHatsProtocol(
            address(HATS),
            keeperHatId,
            managementHatId,
            emergencyHatId,
            regenGovernanceHatId
        );
        vm.stopPrank();
    }
    function testKeeperFunctions() public {
        // Test unauthorized access
        vm.startPrank(unauthorized);
        vm.expectRevert(TokenizedStrategy__NotKeeperOrManagement.selector);
        mockStrategyProxy.tend();
        vm.stopPrank();

        // Test authorized keeper access
        vm.prank(keeper);
        mockStrategyProxy.tend(); // Should succeed
    }

    function testManagementFunctions() public {
        // Test unauthorized access
        vm.startPrank(unauthorized);
        vm.expectRevert(TokenizedStrategy__NotManagement.selector);
        mockStrategyProxy.adjustPosition(100);
        vm.stopPrank();

        // Test authorized management access
        vm.prank(manager);
        mockStrategyProxy.adjustPosition(100); // Should succeed
    }

    function testEmergencyFunctions() public {
        // Test unauthorized access
        vm.startPrank(unauthorized);
        vm.expectRevert(TokenizedStrategy__NotEmergencyAuthorized.selector);
        mockStrategyProxy.emergencyWithdraw(100);
        vm.stopPrank();

        // Test emergency withdraw fails when not shut down
        vm.prank(emergency);
        vm.expectRevert(TokenizedStrategy__StrategyNotInShutdown.selector);
        mockStrategyProxy.emergencyWithdraw(100);

        // Test emergency withdraw succeeds after shutdown
        vm.startPrank(emergency);
        mockStrategyProxy.shutdownStrategy();
        mockStrategyProxy.emergencyWithdraw(100);
        vm.stopPrank();
    }
    function testRoleRevocation() public {
        // Test role revocation
        vm.startPrank(address(deployer));
        dragonHatter.revokeRole(dragonHatter.KEEPER_ROLE(), keeper);
        vm.stopPrank();

        // Verify revoked access
        vm.startPrank(keeper);
        vm.expectRevert(TokenizedStrategy__NotKeeperOrManagement.selector);
        mockStrategyProxy.tend();
        vm.stopPrank();

        //revoke emergency role
        vm.startPrank(address(deployer));
        dragonHatter.revokeRole(dragonHatter.EMERGENCY_ROLE(), emergency);
        vm.stopPrank();

        //make sure reverts
        vm.startPrank(emergency);
        vm.expectRevert(TokenizedStrategy__NotEmergencyAuthorized.selector);
        mockStrategyProxy.emergencyWithdraw(100);
        vm.stopPrank();
    }
}
