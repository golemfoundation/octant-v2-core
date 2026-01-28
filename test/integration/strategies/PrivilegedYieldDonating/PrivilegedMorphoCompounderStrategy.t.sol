// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { PrivilegedYieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/PrivilegedYieldDonatingTokenizedStrategy.sol";
import { BasePrivilegedYieldDonatingIntegrationTest } from "./base/BasePrivilegedYieldDonatingIntegrationTest.sol";
import { IPrivilegedStrategy } from "../base/BasePrivilegedIntegrationTest.sol";
import { MorphoTestConfig } from "../config/MorphoTestConfig.sol";

/// @title Privileged MorphoCompounder Strategy Integration Tests
/// @author Octant
/// @notice Integration tests for the privileged yield donating MorphoCompounder strategy
contract PrivilegedMorphoCompounderStrategyTest is BasePrivilegedYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    MorphoCompounderStrategy public strategy;
    MorphoCompounderStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return MorphoTestConfig.USDC;
    }

    function _strategyName() internal pure override returns (string memory) {
        return MorphoTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return MorphoTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure override returns (address) {
        return MorphoTestConfig.MORPHO_VAULT;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return MorphoTestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        // Use PrivilegedYieldDonatingTokenizedStrategy instead of regular YieldDonatingTokenizedStrategy
        implementation = new PrivilegedYieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_PRIVILEGED_YIELD_DONATING_STRATEGY_V1")
        }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(MorphoTestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        strategy = MorphoCompounderStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "PrivilegedMorphoCompounderDonating");
        vm.label(address(factory), "MorphoCompounderStrategyFactory");
        vm.label(MorphoTestConfig.MORPHO_VAULT, "Morpho Vault");
        vm.label(MorphoTestConfig.USDC, "USDC");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
        vm.label(privilegedUser, "Privileged User");
        vm.label(nonPrivilegedUser, "Non-Privileged User");
    }

    function setUp() public {
        _privilegedBaseSetUp();
    }

    // ========== PRIVILEGED ACCESS CONTROL TESTS ==========

    function testSetPrivilegedOnlyManagement() public {
        _testSetPrivilegedOnlyManagement();
    }

    function testSetPrivilegedByManagement() public {
        _testSetPrivilegedByManagement();
    }

    function testSetPrivilegedBatchOnlyManagement() public {
        _testSetPrivilegedBatchOnlyManagement();
    }

    function testSetPrivilegedBatchByManagement() public {
        _testSetPrivilegedBatchByManagement();
    }

    function testDepositRevertsWhenSenderNotPrivileged() public {
        _testDepositRevertsWhenSenderNotPrivileged();
    }

    function testDepositRevertsWhenReceiverNotPrivileged() public {
        _testDepositRevertsWhenReceiverNotPrivileged();
    }

    function testDepositSucceedsWhenBothPrivileged() public {
        _testDepositSucceedsWhenBothPrivileged();
    }

    function testMintRevertsWhenSenderNotPrivileged() public {
        _testMintRevertsWhenSenderNotPrivileged();
    }

    function testMintRevertsWhenReceiverNotPrivileged() public {
        _testMintRevertsWhenReceiverNotPrivileged();
    }

    function testMintSucceedsWhenBothPrivileged() public {
        _testMintSucceedsWhenBothPrivileged();
    }

    function testMaxDepositReturnsZeroForNonPrivileged() public view {
        _testMaxDepositReturnsZeroForNonPrivileged();
    }

    function testMaxDepositReturnsNonZeroForPrivileged() public view {
        _testMaxDepositReturnsNonZeroForPrivileged();
    }

    function testMaxMintReturnsZeroForNonPrivileged() public view {
        _testMaxMintReturnsZeroForNonPrivileged();
    }

    function testMaxMintReturnsNonZeroForPrivileged() public view {
        _testMaxMintReturnsNonZeroForPrivileged();
    }

    function testWithdrawWorksForNonPrivileged() public {
        _testWithdrawWorksForNonPrivileged();
    }

    function testRedeemWorksForNonPrivileged() public {
        _testRedeemWorksForNonPrivileged();
    }

    function testTransferWorksForNonPrivileged() public {
        _testTransferWorksForNonPrivileged();
    }

    function testFuzzPrivilegedDeposit(uint256 depositAmount) public {
        _testFuzzPrivilegedDeposit(depositAmount);
    }

    function testPrivilegedCanDepositToAnotherPrivileged() public {
        _testPrivilegedCanDepositToAnotherPrivileged();
    }

    function testIsPrivilegedViewFunction() public view {
        _testIsPrivilegedViewFunction();
    }

    // ========== BASE YIELD DONATING TESTS (with privileged user) ==========

    function testInitializationPrivilegedMorpho() public view {
        _testInitialization();
    }

    function testFuzzDepositPrivilegedMorpho(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawPrivilegedMorpho(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    function testHarvestWithProfitPrivilegedMorpho() public {
        uint256 depositAmount = _minDeposit() * 10;
        uint256 profitAmount = _minDeposit();

        // Morpho has slight rounding differences, so we don't use the base test
        // which has strict event emission checks
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 userSharesBefore = vault.balanceOf(user);

        airdrop(ERC20(_asset()), address(vault), profitAmount);

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Allow 1 wei tolerance for Morpho rounding
        assertApproxEqAbs(profit, profitAmount, 1, "Should have captured profit");
        assertEq(loss, 0, "Should have no loss");
        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not change");
        assertGt(vault.totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    function testMultipleUserProfitDistributionPrivilegedMorpho() public {
        // Make user2 privileged for this test
        address user2 = address(0x5678);
        vm.prank(management);
        IPrivilegedStrategy(address(vault)).setPrivileged(user2, true);

        _testMultipleUserProfitDistribution();
    }

    function testEmergencyExitPrivilegedMorpho() public {
        uint256 depositAmount = _initialDeposit() / 10;

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Get the available withdraw limit from the strategy to avoid Morpho constraints
        uint256 availableWithdraw = strategy.availableWithdrawLimit(address(this));

        // Emergency shutdown and withdraw
        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();
        // Use availableWithdrawLimit to avoid "withdraw more than max" errors from Morpho
        vault.emergencyWithdraw(availableWithdraw);
        vm.stopPrank();

        // User should be able to withdraw their funds
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        // Use maxRedeem to avoid "redeem more than max" errors
        uint256 maxRedeemable = IERC4626(address(vault)).maxRedeem(user);
        uint256 sharesToRedeem = userShares > maxRedeemable ? maxRedeemable : userShares;
        uint256 assetsReceived = vault.redeem(sharesToRedeem, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.01e18, "User should receive approximately original deposit");
    }
}
