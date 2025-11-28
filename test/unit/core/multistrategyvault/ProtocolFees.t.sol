// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";

contract ProtocolFeesTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockFlexibleAccountant public accountant;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public fish = address(0x2);
    address public feeRecipient = address(0x3);
    address constant ZERO_ADDRESS = address(0);

    uint256 public fishAmount = 10_000e18;
    uint256 public MAX_BPS = 10_000;
    uint256 public MAX_BPS_ACCOUNTANT = 10_000;
    uint256 constant YEAR = 365 days;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        vaultImplementation = new MultistrategyVault();

        // Deploy factory
        vm.prank(gov);
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        // Deploy accountant
        accountant = new MockFlexibleAccountant(address(asset));
    }

    function createVault() internal returns (MultistrategyVault) {
        vm.startPrank(address(vaultFactory));
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);
        vm.stopPrank();

        return vault;
    }

    function createStrategy(MultistrategyVault _vault) internal returns (MockYieldStrategy) {
        return new MockYieldStrategy(address(asset), address(_vault));
    }

    function userDeposit(address user, MultistrategyVault _vault, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(_vault), amount);
        _vault.deposit(amount, user);
        vm.stopPrank();
    }

    function addStrategyToVault(MultistrategyVault _vault, address strategyAddress) internal {
        vm.prank(gov);
        _vault.add_strategy(strategyAddress, true);
        vm.prank(gov);
        _vault.update_max_debt_for_strategy(strategyAddress, type(uint256).max);
    }

    function addDebtToStrategy(MultistrategyVault _vault, address strategyAddress, uint256 amount) internal {
        vm.prank(gov);
        _vault.update_debt(strategyAddress, amount, 0);
    }

    function setFactoryFeeConfig(uint256 protocolFee, address recipient) internal {
        vm.startPrank(gov);
        vaultFactory.setProtocolFeeRecipient(recipient);
        vaultFactory.setProtocolFeeBps(uint16(protocolFee));
        vm.stopPrank();
    }

    function setupWithAccountant(
        uint256 amount,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 refundRatio
    ) internal returns (MultistrategyVault, MockYieldStrategy, MockFlexibleAccountant) {
        MultistrategyVault _vault = createVault();
        MockYieldStrategy _strategy = createStrategy(_vault);
        MockFlexibleAccountant _accountant = new MockFlexibleAccountant(address(asset));

        // Setup accountant
        vm.prank(gov);
        _accountant.setFees(address(_strategy), managementFee, performanceFee, refundRatio);

        // Set accountant for vault
        vm.prank(gov);
        _vault.set_accountant(address(_accountant));

        // Deposit assets
        userDeposit(fish, _vault, amount);

        // Add and fund strategy
        addStrategyToVault(_vault, address(_strategy));
        addDebtToStrategy(_vault, address(_strategy), amount);

        return (_vault, _strategy, _accountant);
    }

    function testReportWithNoProtocolFeesNoAccountantFees() public {
        uint256 amount = fishAmount / 10;

        // Verify factory has no protocol fee config
        (uint256 fee, ) = vaultFactory.protocolFeeConfig(address(0));
        assertEq(fee, 0, "Protocol fee should be 0");

        // Create vault and strategy
        vault = createVault();
        strategy = createStrategy(vault);

        // Deposit assets to vault and get strategy ready
        userDeposit(fish, vault, amount);
        addStrategyToVault(vault, address(strategy));
        addDebtToStrategy(vault, address(strategy), amount);

        // Check initial price per share
        assertEq(vault.pricePerShare(), 10 ** vault.decimals(), "Initial price per share should be 1");

        // Process report
        vm.prank(gov);

        vault.process_report(address(strategy));

        // Check protocol shares
        uint256 sharesProtocol = vault.balanceOf(gov);
        assertEq(vault.convertToAssets(sharesProtocol), 0, "No protocol fees should be collected");

        // Check price per share hasn't changed
        assertEq(vault.pricePerShare(), 10 ** vault.decimals(), "Price per share should remain 1");
    }

    function testReportGainWithProtocolFeesAccountantFees() public {
        uint256 amount = fishAmount / 10;
        uint256 profit = amount / 10; // 10% profit

        // Set protocol to 10% for easy calculations
        uint256 protocolFee = 1000;
        uint256 managementFee = 0;
        uint256 performanceFee = 1000;
        uint256 refundRatio = 0;

        // Set protocol fees
        setFactoryFeeConfig(protocolFee, gov);

        // Set up vault, strategy and accountant
        (vault, strategy, accountant) = setupWithAccountant(amount, managementFee, performanceFee, refundRatio);

        // Create a profit by airdropping to strategy
        asset.mint(address(strategy), profit);

        // Report from strategy
        vm.prank(gov);
        strategy.report();

        // Calculate expected fees
        uint256 expectedAccountantFee = (profit * performanceFee) / MAX_BPS_ACCOUNTANT;
        uint256 expectedProtocolFee = (expectedAccountantFee * protocolFee) / MAX_BPS_ACCOUNTANT;

        // Check initial price per share
        uint256 pricePerSharePre = vault.pricePerShare();
        assertEq(pricePerSharePre, 10 ** vault.decimals(), "Initial price per share should be 1");

        // Process report
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Check protocol shares
        uint256 sharesProtocol = vault.balanceOf(gov);
        uint256 protocolAssets = (pricePerSharePre * sharesProtocol) / (10 ** vault.decimals());
        assertEq(protocolAssets, expectedProtocolFee, "Protocol should receive correct fee amount");

        // Check price per share hasn't changed (unlocking mechanism not tested here)
        assertEq(vault.pricePerShare(), 10 ** vault.decimals(), "Price per share should remain 1");
    }

    function testReportNoGainWithProtocolFeesAccountantFees() public {
        uint256 amount = fishAmount / 10;
        uint256 profit = 0; // No profit

        // Set protocol to 10% for easy calculations
        uint256 protocolFee = 1000;
        uint256 managementFee = 0;
        uint256 performanceFee = 1000;
        uint256 refundRatio = 0;

        // Set protocol fees
        setFactoryFeeConfig(protocolFee, gov);

        // Set up vault, strategy and accountant
        (vault, strategy, accountant) = setupWithAccountant(amount, managementFee, performanceFee, refundRatio);

        // No profit created

        // Calculate expected fees (should be 0 since no profit)
        uint256 expectedAccountantFee = (profit * performanceFee) / MAX_BPS_ACCOUNTANT;
        uint256 expectedProtocolFee = (expectedAccountantFee * protocolFee) / MAX_BPS_ACCOUNTANT;

        // Check initial price per share
        uint256 pricePerSharePre = vault.pricePerShare();
        assertEq(pricePerSharePre, 10 ** vault.decimals(), "Initial price per share should be 1");

        // Process report
        vm.prank(gov);

        vault.process_report(address(strategy));

        // Check protocol shares (should be 0)
        uint256 sharesProtocol = vault.balanceOf(gov);
        uint256 protocolAssets = (pricePerSharePre * sharesProtocol) / (10 ** vault.decimals());
        assertEq(protocolAssets, expectedProtocolFee, "Protocol should receive correct fee amount (0)");

        // Check price per share hasn't changed
        assertEq(vault.pricePerShare(), 10 ** vault.decimals(), "Price per share should remain 1");
    }

    function testReportGainWithProtocolFeesNoAccountantFees() public {
        uint256 amount = fishAmount / 10;
        uint256 profit = amount / 10; // 10% profit

        // Set protocol to 10% for easy calculations
        uint256 protocolFee = 1000;
        uint256 managementFee = 0;
        uint256 performanceFee = 0; // No performance fee
        uint256 refundRatio = 0;

        // Set protocol fees
        setFactoryFeeConfig(protocolFee, gov);

        // Set up vault, strategy and accountant
        (vault, strategy, accountant) = setupWithAccountant(amount, managementFee, performanceFee, refundRatio);

        // Create a profit by airdropping to strategy
        asset.mint(address(strategy), profit);

        // Calculate expected fees (should be 0 since no performance fee)
        uint256 expectedAccountantFee = (profit * performanceFee) / MAX_BPS_ACCOUNTANT;
        uint256 expectedProtocolFee = (expectedAccountantFee * protocolFee) / MAX_BPS_ACCOUNTANT;

        // Check initial price per share
        uint256 pricePerSharePre = vault.pricePerShare();
        assertEq(pricePerSharePre, 10 ** vault.decimals(), "Initial price per share should be 1");

        // Process report
        vm.prank(gov);

        vault.process_report(address(strategy));

        // Check protocol shares (should be 0)
        uint256 sharesProtocol = vault.balanceOf(gov);
        uint256 protocolAssets = (pricePerSharePre * sharesProtocol) / (10 ** vault.decimals());
        assertEq(protocolAssets, expectedProtocolFee, "Protocol should receive correct fee amount (0)");

        // Check price per share hasn't changed
        assertEq(vault.pricePerShare(), 10 ** vault.decimals(), "Price per share should remain 1");
    }
}
