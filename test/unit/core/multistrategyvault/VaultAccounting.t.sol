// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { console } from "forge-std/console.sol";

contract VaultAccountingTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MultistrategyVaultFactory vaultFactory;
    MockERC20 asset;
    address gov;
    address depositLimitManager;
    uint256 constant DEPOSIT_AMOUNT = 1e18;

    function setUp() public {
        gov = address(this);
        depositLimitManager = makeAddr("depositLimitManager");
        asset = new MockERC20(18);

        // Create and initialize the vault
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        vm.startPrank(gov);
        // Set up roles for governance using direct values matching the Vyper implementation
        // Vyper Roles is a bit flag enum where each role is a power of 2
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        // set deposit limit manager
        vault.add_role(depositLimitManager, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vm.stopPrank();
        // set deposit limit
        vm.prank(depositLimitManager);
        vault.set_deposit_limit(100 ether, true);
    }

    function mintAndDepositIntoVault() internal returns (uint256) {
        asset.mint(gov, DEPOSIT_AMOUNT);
        asset.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, gov);
        return DEPOSIT_AMOUNT;
    }

    function airdropAsset(uint256 amount) internal {
        asset.mint(address(vault), amount);
    }

    function testVaultAirdropDoNotIncrease() public {
        uint256 vaultBalance = mintAndDepositIntoVault();
        assertGt(vaultBalance, 0, "Vault balance should be non-zero");

        // Get price per share before airdrop
        uint256 pricePerShare = vault.pricePerShare();

        // Airdrop to vault (10% of vault balance)
        uint256 airdropAmount = vaultBalance / 10;
        airdropAsset(airdropAmount);

        // Verify price per share hasn't changed
        assertEq(vault.pricePerShare(), pricePerShare, "Price per share should not change after airdrop");
    }

    function testVaultAirdropDoNotIncreaseReportRecordsIt() public {
        uint256 vaultBalance = mintAndDepositIntoVault();
        assertGt(vaultBalance, 0, "Vault balance should be non-zero");

        // Get price per share before airdrop
        uint256 pricePerShare = vault.pricePerShare();

        // Airdrop to vault (10% of vault balance)
        uint256 airdropAmount = vaultBalance / 10;
        airdropAsset(airdropAmount);

        // Verify price per share hasn't changed
        assertEq(vault.pricePerShare(), pricePerShare, "Price per share should not change after airdrop");
        assertEq(vault.totalIdle(), vaultBalance, "Total idle should equal vault balance");
        assertEq(
            asset.balanceOf(address(vault)),
            vaultBalance + airdropAmount,
            "Vault asset balance should include airdrop"
        );

        (uint256 gain, uint256 loss) = vault.process_report(address(vault));

        // Verify event data through return values
        assertEq(gain, airdropAmount, "Gain should equal airdrop amount");
        assertEq(loss, 0, "Loss should be zero");

        // Verify accounting after report
        assertEq(
            vault.pricePerShare(),
            pricePerShare,
            "Price per share should not change after report (profit locked)"
        );
        assertEq(vault.totalIdle(), vaultBalance + airdropAmount, "Total idle should include airdrop");
        assertEq(
            asset.balanceOf(address(vault)),
            vaultBalance + airdropAmount,
            "Vault asset balance should include airdrop"
        );

        // // Skip forward to almost unlock all profits
        // skip(vault.profitMaxUnlockTime() - 1);

        // // Could check profit unlocking state here if needed
    }
}
