// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract ERC20Test is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public fish = address(0x2);
    address public bunny = address(0x3);
    address public doggie = address(0x4);
    address public feeRecipient = address(0x5);

    uint256 public fishAmount = 10_000e18;
    uint256 constant MAX_INT = type(uint256).max;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        // Deploy factory
        vm.prank(gov);
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        // Deploy vault
        vm.startPrank(address(vaultFactory));
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set deposit limit to max
        vault.set_deposit_limit(MAX_INT, false);
        vm.stopPrank();
    }

    function userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function testTransferWithInsufficientFundsRevert() public {
        uint256 amount = 1;

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InsufficientFunds.selector);
        vault.transfer(bunny, amount);
    }

    function testTransferWithSufficientFundsTransfers() public {
        uint256 amount = fishAmount;

        userDeposit(fish, amount);

        vm.prank(fish);

        vault.transfer(bunny, amount);

        // Check balances
        assertEq(vault.balanceOf(fish), 0, "Fish should have 0 balance");
        assertEq(vault.balanceOf(bunny), amount, "Bunny should have the transferred amount");
    }

    function testApproveWithAmount() public {
        vm.prank(fish);

        vault.approve(bunny, MAX_INT);

        assertEq(vault.allowance(fish, bunny), MAX_INT, "Allowance should be MAX_INT");

        // Test overwrite approval
        vm.prank(fish);

        vault.approve(bunny, fishAmount);

        assertEq(vault.allowance(fish, bunny), fishAmount, "Allowance should be updated to fishAmount");
    }

    function testTransferFromWithApproval() public {
        uint256 amount = fishAmount;

        userDeposit(fish, amount);

        vm.prank(fish);
        vault.approve(bunny, amount);

        vm.prank(bunny);

        vault.transferFrom(fish, doggie, amount);

        // Check balances and allowance
        assertEq(vault.balanceOf(fish), 0, "Fish should have 0 balance");
        assertEq(vault.balanceOf(bunny), 0, "Bunny should have 0 balance");
        assertEq(vault.balanceOf(doggie), amount, "Doggie should have the transferred amount");
        assertEq(vault.allowance(fish, bunny), 0, "Allowance should be reduced to 0");
    }

    function testTransferFromWithInsufficientAllowanceReverts() public {
        uint256 amount = fishAmount;

        userDeposit(fish, amount);

        // No approval

        vm.prank(bunny);
        vm.expectRevert();
        vault.transferFrom(fish, doggie, amount);
    }

    function testTransferFromWithApprovalAndInsufficientFundsReverts() public {
        uint256 amount = fishAmount;

        // No deposit, just approval
        vm.prank(fish);
        vault.approve(bunny, amount);

        vm.prank(bunny);
        vm.expectRevert();
        vault.transferFrom(fish, doggie, amount);
    }
}
