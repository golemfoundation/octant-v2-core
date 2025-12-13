// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { Constants } from "test/unit/utils/constants.sol";

contract VaultRolesTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MultistrategyVaultFactory vaultFactory;
    address public gov;
    address public fish;
    address public strategist;
    address public bunny;

    function setUp() public {
        gov = address(this);
        fish = makeAddr("fish");
        strategist = makeAddr("strategist");
        bunny = makeAddr("bunny");
        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));
    }

    function testSetRole() public {
        // Gov can set role
        vault.set_role(fish, uint256(IMultistrategyVault.Roles.DEBT_MANAGER));

        // Fish tries to set role (should fail)
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_role(fish, uint256(IMultistrategyVault.Roles.DEBT_MANAGER));
    }

    function testTransfersRoleManager() public {
        // Check initial state
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);

        // Gov transfers role to strategist
        vault.transfer_role_manager(strategist);
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), strategist);

        // Strategist accepts role
        vm.prank(strategist);
        vault.accept_role_manager();
        assertEq(vault.roleManager(), strategist);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);
    }

    function testGovTransfersRoleManager_GovCantAccept() public {
        // Check initial state
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);

        // Gov transfers role to strategist
        vault.transfer_role_manager(strategist);
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), strategist);

        // Gov tries to accept (should fail)
        vm.expectRevert(IMultistrategyVault.NotFutureRoleManager.selector);
        vault.accept_role_manager();

        // State should remain unchanged
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), strategist);
    }

    function testRandomTransfersRoleManager_Reverts() public {
        // Check initial state
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);

        // Strategist tries to transfer role (should fail)
        vm.prank(strategist);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.transfer_role_manager(strategist);

        // State should remain unchanged
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);
    }

    function testGovTransfersRoleManager_CanChangeFutureManager() public {
        // Check initial state
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);

        // Gov transfers role to strategist
        vault.transfer_role_manager(strategist);
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), strategist);

        // Gov changes future manager to bunny
        vault.transfer_role_manager(bunny);
        assertEq(vault.roleManager(), gov);
        assertEq(vault.futureRoleManager(), bunny);

        // Strategist tries to accept (should fail)
        vm.prank(strategist);
        vm.expectRevert(IMultistrategyVault.NotFutureRoleManager.selector);
        vault.accept_role_manager();

        // Bunny accepts the role
        vm.prank(bunny);
        vault.accept_role_manager();
        assertEq(vault.roleManager(), bunny);
        assertEq(vault.futureRoleManager(), Constants.ZERO_ADDRESS);
    }
}
