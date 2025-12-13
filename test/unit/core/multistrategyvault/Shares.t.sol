// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { Constants } from "test/unit/utils/constants.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { Checks } from "test/unit/utils/checks.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract VaultSharesTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;

    address gov;
    address fish;
    address bunny;
    address reportingManager;
    address debtPurchaser;
    uint256 fishAmount;
    uint256 constant WEEK = 7 * 24 * 60 * 60;

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    function setUp() public {
        gov = address(this);
        fish = makeAddr("fish");
        bunny = makeAddr("bunny");
        reportingManager = makeAddr("reportingManager");
        debtPurchaser = makeAddr("debtPurchaser");
        fishAmount = 1e18;
        asset = new MockERC20(18);

        // Give fish some tokens
        asset.mint(fish, fishAmount);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
    }

    function createVault(uint256 depositLimit) internal returns (MultistrategyVault) {
        MultistrategyVault newVault = MultistrategyVault(
            vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, WEEK)
        );

        // Set up roles for governance
        newVault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        // report manager
        newVault.add_role(reportingManager, IMultistrategyVault.Roles.REPORTING_MANAGER);
        // strategy manager
        newVault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        // MAX_DEBT_MANAGER
        newVault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        // DEBT_MANAGER
        newVault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        // DEBT_PURCHASER
        newVault.add_role(debtPurchaser, IMultistrategyVault.Roles.DEBT_PURCHASER);

        if (depositLimit > 0) {
            newVault.set_deposit_limit(depositLimit, true);
        }

        return newVault;
    }

    function initialSetUp(uint256 amount) internal returns (MultistrategyVault, MockYieldStrategy) {
        MultistrategyVault newVault = createVault(amount);

        // Create and initialize the strategy
        MockYieldStrategy newStrategy = new MockYieldStrategy(address(asset), address(newVault));

        // Add strategy to vault
        vm.startPrank(gov);
        newVault.add_strategy(address(newStrategy), true);
        newVault.update_max_debt_for_strategy(address(newStrategy), type(uint256).max);
        vm.stopPrank();

        // User deposit
        vm.startPrank(fish);
        asset.approve(address(newVault), amount);
        newVault.deposit(amount, fish);
        vm.stopPrank();

        // Allocate to strategy
        newVault.update_debt(address(newStrategy), amount, 0);

        return (newVault, newStrategy);
    }

    function createProfit(
        MockYieldStrategy strat,
        MultistrategyVault v,
        uint256 profitAmount
    ) internal returns (uint256) {
        // We create a virtual profit
        uint256 initialDebt = v.strategies(address(strat)).currentDebt;

        // Transfer profit to strategy
        asset.mint(address(strat), profitAmount);

        // Report profit
        strat.report();

        // Process report
        vm.startPrank(reportingManager);
        v.process_report(address(strat));
        vm.stopPrank();

        // Return the reported fees
        return v.strategies(address(strat)).currentDebt - initialDebt;
    }

    // Deposit Tests

    function testDepositWithInvalidRecipientReverts() public {
        vault = createVault(0);
        uint256 amount = 1000;

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(amount, address(vault));

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(amount, Constants.ZERO_ADDRESS);

        vm.stopPrank();
    }

    function testDepositWithZeroFundsReverts() public {
        vault = createVault(0);
        uint256 amount = 0;

        vm.startPrank(fish);
        vm.expectRevert(IMultistrategyVault.CannotDepositZero.selector);
        vault.deposit(amount, fish);
        vm.stopPrank();
    }

    function testDepositWithinDepositLimit() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vm.expectEmit(true, true, true, true);
        emit IERC4626Payable.Deposit(fish, fish, amount, shares);
        vault.deposit(amount, fish);

        vm.stopPrank();

        assertEq(vault.totalIdle(), amount);
        assertEq(vault.balanceOf(fish), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(asset.balanceOf(fish), 0);
    }

    function testDepositExceedDepositLimitReverts() public {
        uint256 amount = fishAmount;
        uint256 depositLimit = amount - 1;
        vault = createVault(depositLimit);

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(amount, fish);

        vm.stopPrank();
    }

    function testDepositAllExceedDepositLimitReverts() public {
        uint256 amount = fishAmount;
        uint256 depositLimit = amount / 2;
        vault = createVault(depositLimit);

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(Constants.MAX_INT, fish);

        vm.stopPrank();
    }

    function testDepositWithDelegation() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        vault = createVault(amount);

        // Check amount is non-zero
        assertGt(amount, 0);

        // Delegate deposit to bunny
        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vault.deposit(amount, bunny);

        vm.stopPrank();

        // Fish has no more assets
        assertEq(asset.balanceOf(fish), 0);
        // Fish has no shares
        assertEq(vault.balanceOf(fish), 0);
        // Bunny has been issued vault shares
        assertEq(vault.balanceOf(bunny), shares);
    }

    // Mint Tests

    function testMintWithInvalidRecipientReverts() public {
        // convert
        vault = createVault(0);
        uint256 shares = 100;

        vm.startPrank(fish);
        asset.approve(address(vault), shares);

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.mint(shares, address(vault));

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.mint(shares, Constants.ZERO_ADDRESS);

        vm.stopPrank();
    }

    function testMintWithZeroFundsReverts() public {
        vault = createVault(fishAmount);
        uint256 shares = 0;

        vm.startPrank(fish);
        vm.expectRevert(IMultistrategyVault.CannotDepositZero.selector);
        vault.mint(shares, fish);
        vm.stopPrank();
    }

    function testMintWithinDepositLimit() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vault.mint(shares, fish);

        vm.stopPrank();

        assertEq(vault.totalIdle(), amount);
        assertEq(vault.balanceOf(fish), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(asset.balanceOf(fish), 0);
    }

    function testMintExceedDepositLimitReverts() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        uint256 depositLimit = amount - 1;
        vault = createVault(depositLimit);

        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.mint(shares, fish);

        vm.stopPrank();
    }

    function testMintWithDelegation() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        vault = createVault(fishAmount);

        // Check amount is non-zero
        assertGt(amount, 0);

        // Delegate mint to bunny
        vm.startPrank(fish);
        asset.approve(address(vault), amount);

        vault.mint(shares, bunny);

        vm.stopPrank();

        // Fish has no more assets
        assertEq(asset.balanceOf(fish), 0);
        // Fish has no shares
        assertEq(vault.balanceOf(fish), 0);
        // Bunny has been issued vault shares
        assertEq(vault.balanceOf(bunny), shares);
    }

    // Withdraw Tests
    function testWithdraw() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(fish, fish, fish, amount, shares);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
        vm.stopPrank();

        Checks.checkVaultEmpty(vault);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(fish), amount);
    }

    function testWithdrawWithInsufficientSharesReverts() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount + 1;

        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);

        vm.expectRevert(IMultistrategyVault.InsufficientSharesToRedeem.selector);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testWithdrawWithNoSharesReverts() public {
        vault = createVault(fishAmount);
        uint256 shares = 0;

        vm.startPrank(fish);
        vm.expectRevert(IMultistrategyVault.NoSharesToRedeem.selector);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    function testWithdrawWithDelegation() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        // Check balance is non-zero
        assertGt(amount, 0);

        // Deposit balance
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);

        // Withdraw to bunny
        vm.expectEmit(true, true, true, true);
        emit Withdraw(fish, bunny, fish, amount, shares);
        vault.withdraw(shares, bunny, fish, 0, new address[](0));
        vm.stopPrank();

        // Fish no longer has shares
        assertEq(vault.balanceOf(fish), 0);
        // Fish did not receive tokens
        assertEq(asset.balanceOf(fish), 0);
        // Bunny has tokens
        assertEq(asset.balanceOf(bunny), amount);
    }

    function testWithdrawWithDelegationAndSufficientAllowance() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        // Check balance is non-zero
        assertGt(amount, 0);

        // Deposit balance
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Check initial allowance is zero
        assertEq(vault.allowance(fish, bunny), 0);

        // Approve bunny
        vm.startPrank(fish);
        vault.approve(bunny, amount);
        vm.stopPrank(); // Stop fish's prank

        // Withdraw as bunny to fish
        vm.startPrank(bunny);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
        vm.stopPrank();

        Checks.checkVaultEmpty(vault);
        assertEq(vault.allowance(fish, bunny), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(fish), amount);
    }

    function testWithdrawWithDelegationAndInsufficientAllowanceReverts() public {
        vault = createVault(fishAmount);
        uint256 amount = fishAmount;
        uint256 shares = amount;

        // Check balance is non-zero
        assertGt(amount, 0);

        // Deposit balance
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);

        // Withdraw as bunny to fish
        vm.startPrank(bunny);
        vm.expectRevert(IMultistrategyVault.InsufficientAllowance.selector);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
        vm.stopPrank();
    }

    // Test setting deposit limit with different values
    function testSetDepositLimitWithZero() public {
        vault = createVault(0);
        uint256 depositLimit = 0;

        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.UpdateDepositLimit(depositLimit);
        vault.set_deposit_limit(depositLimit, true);

        assertEq(vault.depositLimit(), depositLimit);
    }

    function testSetDepositLimitWithValue() public {
        vault = createVault(0);
        uint256 depositLimit = 1e18;

        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.UpdateDepositLimit(depositLimit);
        vault.set_deposit_limit(depositLimit, true);

        assertEq(vault.depositLimit(), depositLimit);
    }

    function testSetDepositLimitWithMaxInt() public {
        vault = createVault(0);
        uint256 depositLimit = type(uint256).max;

        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.UpdateDepositLimit(depositLimit);
        vault.set_deposit_limit(depositLimit, true);

        assertEq(vault.depositLimit(), depositLimit);
    }

    // Test deposit/mint with zero totalSupply but positive assets
    function testDepositSharesWithZeroTotalSupplyPositiveAssets() public {
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        (vault, strategy) = initialSetUp(amount);

        // Create profit
        createProfit(strategy, vault, firstProfit);

        // Withdraw funds from strategy
        vault.update_debt(address(strategy), 0, 0);

        // Verify more shares than deposits due to profit unlock
        assertGt(vault.totalSupply(), amount);

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);

        // User redeems shares
        vm.startPrank(fish);
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Verify non-zero total supply
        assertGt(vault.totalSupply(), 0);

        // Skip time to fully unlock profits
        skip(14 * 24 * 3600);

        // Verify zero total supply
        assertEq(vault.totalSupply(), 0);

        // Before the second deposit attempt, add:
        vault.set_deposit_limit(type(uint256).max, true);

        // Deposit again
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Verify shares minted at 1:1
        assertEq(vault.balanceOf(fish), amount);
        assertGt(vault.pricePerShare(), 10 ** vault.decimals());
    }

    function testMintSharesWithZeroTotalSupplyPositiveAssets() public {
        uint256 amount = fishAmount / 10;
        uint256 firstProfit = fishAmount / 10;

        (vault, strategy) = initialSetUp(amount);

        // Create profit
        createProfit(strategy, vault, firstProfit);

        // Withdraw funds from strategy
        vault.update_debt(address(strategy), 0, 0);

        // Verify more shares than deposits due to profit unlock
        assertGt(vault.totalSupply(), amount);

        // User redeems shares
        vm.startPrank(fish);
        vault.redeem(vault.balanceOf(fish), fish, fish, 0, new address[](0));
        vm.stopPrank();

        // Verify non-zero total supply
        assertGt(vault.totalSupply(), 0);

        // Skip time to fully unlock profits
        skip(14 * 24 * 3600);

        // Verify zero total supply
        assertEq(vault.totalSupply(), 0);

        // Before the second deposit attempt, add:
        vault.set_deposit_limit(type(uint256).max, true);

        // Mint again
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vault.mint(amount, fish);
        vm.stopPrank();

        // Verify shares minted at 1:1
        assertEq(vault.balanceOf(fish), amount);
        assertGt(vault.pricePerShare(), 10 ** vault.decimals());
    }

    // Test deposit/mint with zero totalAssets but positive supply
    function testDepositWithZeroTotalAssetsPositiveSupply() public {
        uint256 amount = fishAmount / 10;

        (vault, strategy) = initialSetUp(amount);

        // Create a loss (transfer assets out of the strategy)
        vm.prank(address(strategy));
        asset.transfer(gov, amount);
        strategy.report();

        // Verify strategy assets are zero
        assertEq(strategy.convertToAssets(amount), 0);

        // Process report
        vm.startPrank(reportingManager);
        vault.process_report(address(strategy));
        vm.stopPrank();

        // Verify zero total assets but non-zero supply
        assertEq(vault.totalAssets(), 0);
        assertNotEq(vault.totalSupply(), 0);

        // Try to deposit (should revert)
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vm.expectRevert(IMultistrategyVault.CannotMintZero.selector);
        vault.deposit(amount, fish);
        vm.stopPrank();

        // Verify state
        assertEq(vault.balanceOf(fish), amount);
        assertEq(vault.pricePerShare(), 0);
        assertEq(vault.convertToShares(amount), 0);
        assertEq(vault.convertToAssets(amount), 0);
    }

    function testMintWithZeroTotalAssetsPositiveSupply() public {
        uint256 amount = fishAmount / 10;

        (vault, strategy) = initialSetUp(amount);

        // Create a loss (transfer assets out of the strategy)
        vm.prank(address(strategy));
        asset.transfer(gov, amount);
        strategy.report();

        // Verify strategy assets are zero
        assertEq(strategy.convertToAssets(amount), 0);

        // Process report
        vm.startPrank(reportingManager);
        vault.process_report(address(strategy));
        vm.stopPrank();

        // Verify zero total assets but non-zero supply
        assertEq(vault.totalAssets(), 0);
        assertNotEq(vault.totalSupply(), 0);

        // Try to mint (should revert)
        vm.startPrank(fish);
        asset.approve(address(vault), amount);
        vm.expectRevert(IMultistrategyVault.CannotDepositZero.selector);
        vault.mint(amount, fish);
        vm.stopPrank();

        // Verify state
        assertEq(vault.balanceOf(fish), amount);
        assertEq(vault.pricePerShare(), 0);
        assertEq(vault.convertToShares(amount), 0);
        assertEq(vault.convertToAssets(amount), 0);
    }
}
