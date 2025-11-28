// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyLockedVault } from "src/core/MultistrategyLockedVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract DepositAndWithdrawLockedTest is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyLockedVault vault;
    MockERC20 asset;
    address gov;
    address fish;
    address bunny;
    address doggie;
    address panda;
    address woofy;

    uint256 fishAmount = 10_000e18;
    uint256 constant MAX_INT = type(uint256).max;
    uint256 constant COOLDOWN_PERIOD = 7 days;

    function setUp() public {
        gov = address(0x1);
        fish = address(0x2);
        bunny = address(0x3);
        doggie = address(0x4);
        panda = address(0x5);
        woofy = address(0x6);

        // Setup asset
        asset = new MockERC20(18);
        asset.mint(fish, fishAmount);

        vaultImplementation = new MultistrategyLockedVault();

        // prank as gov
        vm.prank(gov);
        vaultFactory = new MultistrategyVaultFactory("Locked Test Factory", address(vaultImplementation), gov);

        // Create vault
        _createVault();
    }

    function _createVault() internal {
        vm.startPrank(gov);

        vault = MultistrategyLockedVault(
            vaultFactory.deployNewVault(address(asset), "Locked Test Vault", "vLTST", gov, 7 days)
        );

        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);

        vault.set_deposit_limit(type(uint256).max, true);
        vm.stopPrank();
    }

    function checkVaultEmpty(MultistrategyLockedVault _vault) internal view {
        assertEq(_vault.totalSupply(), 0, "Total supply should be 0");
        assertEq(_vault.totalAssets(), 0, "Total assets should be 0");
        assertEq(_vault.totalIdle(), 0, "Total idle should be 0");
        assertEq(_vault.totalDebt(), 0, "Total debt should be 0");
    }

    function initiateAndCompleteRageQuit(address user) internal {
        // Only initiate rage quit if user has balance
        uint256 userBalance = vault.balanceOf(user);
        if (userBalance > 0) {
            // Initiate rage quit for user
            vm.startPrank(user);
            vault.initiateRageQuit(userBalance);
            vm.stopPrank();

            // Fast forward past cooldown period
            vm.warp(block.timestamp + vault.rageQuitCooldownPeriod() + 1);
        }
    }

    function testDepositAndWithdraws() public {
        uint256 amount = fishAmount;
        uint256 halfAmount = fishAmount / 2;
        uint256 quarterAmount = halfAmount / 2;

        // Deposit quarter
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(quarterAmount, fish);
        vm.stopPrank();

        assertEq(vault.totalSupply(), quarterAmount, "Total supply should match deposit");
        assertEq(asset.balanceOf(address(vault)), quarterAmount, "Vault asset balance should match deposit");
        assertEq(vault.totalIdle(), quarterAmount, "Total idle should match deposit");
        assertEq(vault.totalDebt(), 0, "Total debt should be 0");
        assertEq(vault.pricePerShare(), 10 ** asset.decimals(), "Price per share should be 1:1");

        // Set deposit limit to half_amount
        vm.prank(gov);
        vault.set_deposit_limit(halfAmount, true);

        // Try to deposit more than limit
        vm.startPrank(fish);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(amount, fish);

        // Deposit another quarter
        vault.deposit(quarterAmount, fish);
        vm.stopPrank();

        assertEq(vault.totalSupply(), halfAmount, "Total supply should match deposits");
        assertEq(asset.balanceOf(address(vault)), halfAmount, "Vault asset balance should match deposits");
        assertEq(vault.totalIdle(), halfAmount, "Total idle should match deposits");
        assertEq(vault.totalDebt(), 0, "Total debt should be 0");
        assertEq(vault.pricePerShare(), 10 ** asset.decimals(), "Price per share should be 1:1");

        // Raise deposit limit
        vm.prank(gov);
        vault.set_deposit_limit(fishAmount, true);

        // Deposit another half
        vm.prank(fish);
        vault.deposit(halfAmount, fish);

        assertEq(vault.totalSupply(), amount, "Total supply should match total deposit");
        assertEq(asset.balanceOf(address(vault)), amount, "Vault asset balance should match total deposit");
        assertEq(vault.totalIdle(), amount, "Total idle should match total deposit");
        assertEq(vault.totalDebt(), 0, "Total debt should be 0");
        assertEq(vault.pricePerShare(), 10 ** asset.decimals(), "Price per share should be 1:1");

        // Initiate rage quit and wait for cooldown period
        initiateAndCompleteRageQuit(fish);

        // Withdraw half
        vm.prank(fish);
        vault.withdraw(halfAmount, fish, fish, 0, new address[](0));

        assertEq(vault.totalSupply(), halfAmount, "Total supply should match remaining deposit");
        assertEq(asset.balanceOf(address(vault)), halfAmount, "Vault asset balance should match remaining deposit");
        assertEq(vault.totalIdle(), halfAmount, "Total idle should match remaining deposit");
        assertEq(vault.totalDebt(), 0, "Total debt should be 0");
        assertEq(vault.pricePerShare(), 10 ** asset.decimals(), "Price per share should be 1:1");

        // Withdraw remaining half (can withdraw remaining custodied shares from same rage quit)
        vm.startPrank(fish);
        vault.withdraw(halfAmount, fish, fish, 0, new address[](0));
        vm.stopPrank();

        checkVaultEmpty(vault);
        assertEq(asset.balanceOf(address(vault)), 0, "Vault should have no assets");
        assertEq(vault.pricePerShare(), 10 ** asset.decimals(), "Price per share should still be 1:1");
    }

    function testDelegatedDepositAndWithdraw() public {
        uint256 balance = asset.balanceOf(fish);

        // Ensure we have assets to test with
        assertTrue(balance > 0, "Fish should have assets");

        // 1. Deposit from fish and send shares to bunny
        vm.startPrank(fish);
        asset.approve(address(vault), asset.balanceOf(fish));
        vault.deposit(asset.balanceOf(fish), bunny);
        vm.stopPrank();

        // Verify fish no longer has assets and bunny has shares
        assertEq(asset.balanceOf(fish), 0, "Fish should have no assets");
        assertEq(vault.balanceOf(fish), 0, "Fish should have no shares");
        assertEq(vault.balanceOf(bunny), balance, "Bunny should have shares");

        // Initiate rage quit for bunny and wait for cooldown to complete
        initiateAndCompleteRageQuit(bunny);

        // 2. Withdraw from bunny to doggie
        vm.startPrank(bunny);
        vault.withdraw(vault.balanceOf(bunny), doggie, bunny, 0, new address[](0));
        vm.stopPrank();

        // Verify bunny no longer has shares and doggie has assets
        assertEq(vault.balanceOf(bunny), 0, "Bunny should have no shares");
        assertEq(asset.balanceOf(bunny), 0, "Bunny should have no assets");
        assertEq(asset.balanceOf(doggie), balance, "Doggie should have assets");

        // 3. Deposit from doggie and send shares to panda
        vm.startPrank(doggie);
        asset.approve(address(vault), asset.balanceOf(doggie));
        vault.deposit(asset.balanceOf(doggie), panda);
        vm.stopPrank();

        // Verify doggie no longer has assets and panda has shares
        assertEq(asset.balanceOf(doggie), 0, "Doggie should have no assets");
        assertEq(vault.balanceOf(doggie), 0, "Doggie should have no shares");
        assertEq(vault.balanceOf(panda), balance, "Panda should have shares");

        // Initiate rage quit for panda and wait for cooldown to complete
        initiateAndCompleteRageQuit(panda);

        // 4. Withdraw from panda to woofy
        vm.startPrank(panda);
        vault.withdraw(vault.balanceOf(panda), woofy, panda, 0, new address[](0));
        vm.stopPrank();

        // Verify panda no longer has shares and woofy has assets
        assertEq(vault.balanceOf(panda), 0, "Panda should have no shares");
        assertEq(asset.balanceOf(panda), 0, "Panda should have no assets");
        assertEq(asset.balanceOf(woofy), balance, "Woofy should have assets");
    }
}
