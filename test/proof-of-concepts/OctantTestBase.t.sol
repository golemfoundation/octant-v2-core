// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Core components
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

// Regen components
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";

// Allocation mechanisms
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";

// Utils
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

// Mocks
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";

// External dependencies
import { Staker } from "staker/Staker.sol";

contract OctantTestBase is Test {
    // Core contract instances
    MultistrategyVault public vaultImplementation;
    MultistrategyVaultFactory public vaultFactory;
    MultistrategyVault public vault;

    RegenStaker public regenStaker;
    RegenEarningPowerCalculator public earningPowerCalculator;

    AllocationMechanismFactory public allocationFactory;
    QuadraticVotingMechanism public allocationMechanism;

    MockYieldStrategy public strategy;

    // Tokens
    MockERC20 public asset;
    MockERC20Staking public stakeToken;
    MockERC20 public rewardToken;

    // Allowsets
    AddressSet public stakerAllowset;
    AddressSet public contributionAllowset;
    AddressSet public allocationMechanismAllowset;
    AddressSet public earningPowerAllowset;

    // Standard test addresses
    address public admin = makeAddr("admin");
    address public governance = makeAddr("governance");
    address public vaultManager = makeAddr("vaultManager");
    address public strategist = makeAddr("strategist");
    address public keeper = makeAddr("keeper");
    address public emergencyAdmin = makeAddr("emergencyAdmin");
    address public protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address public performanceFeeRecipient = makeAddr("performanceFeeRecipient");
    address public donationAddress = makeAddr("donationAddress");
    address public rewardNotifier = makeAddr("rewardNotifier");

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100 ether;
    uint256 public constant INITIAL_STAKE = 50 ether;
    uint256 public constant INITIAL_REWARDS = 10 ether;
    uint256 public constant REWARD_DURATION = 30 days;
    uint256 public constant PROFIT_MAX_UNLOCK_TIME = 10 days;

    function setUp() public virtual {
        vm.startPrank(admin);

        // Deploy tokens
        asset = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20(18);

        // Deploy allowsets
        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();

        // Deploy vault infrastructure
        _deployVaultInfrastructure();

        // Deploy regen infrastructure
        _deployRegenInfrastructure();

        // Deploy allocation mechanism infrastructure
        _deployAllocationInfrastructure();

        // Deploy strategy infrastructure
        _deployStrategyInfrastructure();

        // Configure system
        _configureSystem();

        vm.stopPrank();

        _addLabels();
    }

    function _deployVaultInfrastructure() internal {
        // Deploy vault implementation and factory
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Octant Vault Factory", address(vaultImplementation), governance);

        // Deploy vault instance
        vault = MultistrategyVault(
            vaultFactory.deployNewVault(
                address(asset),
                "Octant Test Vault",
                "OTV",
                vaultManager,
                PROFIT_MAX_UNLOCK_TIME
            )
        );
    }

    function _deployRegenInfrastructure() internal {
        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy regen staker factory (skip for POC - use direct deployment)
        // regenStakerFactory = new RegenStakerFactory(regenStakerBytecode, noDelegationBytecode);

        // Deploy regen staker
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            earningPowerCalculator,
            1000, // maxBumpTip
            admin,
            uint128(REWARD_DURATION),
            0, // minStakeAmount
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );

        // Set reward notifier
        regenStaker.setRewardNotifier(rewardNotifier, true);
    }

    function _deployAllocationInfrastructure() internal {
        // Deploy allocation mechanism factory
        allocationFactory = new AllocationMechanismFactory();

        // Configure allocation mechanism
        AllocationConfig memory config = AllocationConfig({
            asset: rewardToken,
            name: "Test Allocation Mechanism",
            symbol: "TAM",
            votingDelay: 1 hours,
            votingPeriod: 7 days,
            quorumShares: 1 ether,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: admin
        });

        // Deploy quadratic voting mechanism
        address mechanismAddress = allocationFactory.deployQuadraticVotingMechanism(
            config,
            1, // alphaNumerator
            1 // alphaDenominator
        );
        allocationMechanism = QuadraticVotingMechanism(payable(mechanismAddress));
    }

    function _deployStrategyInfrastructure() internal {
        // Deploy strategy with same asset as vault
        strategy = new MockYieldStrategy(address(asset), address(vault));
    }

    function _configureSystem() internal {
        // Configure vault roles and limits
        vm.startPrank(vaultManager);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.addRole(vaultManager, IMultistrategyVault.Roles.REPORTING_MANAGER);

        vault.setDepositLimit(type(uint256).max, true);

        // Add strategy to vault
        vault.addStrategy(address(strategy), true);

        // Set max debt for strategy
        vault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        vm.stopPrank();

        // Setup allowsets
        vm.startPrank(admin);
        stakerAllowset.add(alice);
        stakerAllowset.add(bob);
        contributionAllowset.add(alice);
        contributionAllowset.add(bob);
        earningPowerAllowset.add(alice);
        earningPowerAllowset.add(bob);
        allocationMechanismAllowset.add(address(allocationMechanism));

        // Mint tokens for testing
        asset.mint(alice, INITIAL_DEPOSIT * 10);
        asset.mint(bob, INITIAL_DEPOSIT * 10);
        stakeToken.mint(alice, INITIAL_STAKE * 2);
        stakeToken.mint(bob, INITIAL_STAKE * 2);
        rewardToken.mint(rewardNotifier, INITIAL_REWARDS * 10);

        // No initial strategy balance - it will receive assets from vault allocation
    }

    function _addLabels() internal {
        vm.label(address(vault), "MultistrategyVault");
        vm.label(address(vaultFactory), "VaultFactory");
        vm.label(address(regenStaker), "RegenStaker");
        vm.label(address(earningPowerCalculator), "EarningPowerCalculator");
        vm.label(address(allocationFactory), "AllocationFactory");
        vm.label(address(allocationMechanism), "AllocationMechanism");
        vm.label(address(strategy), "YieldStrategy");
        vm.label(address(asset), "Asset");
        vm.label(address(stakeToken), "StakeToken");
        vm.label(address(rewardToken), "RewardToken");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(admin, "Admin");
        vm.label(governance, "Governance");
        vm.label(vaultManager, "VaultManager");
        vm.label(strategist, "Strategist");
        vm.label(keeper, "Keeper");
    }

    // Helper functions for testing flows

    function depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function stakeTokens(address user, uint256 amount, address delegatee) internal returns (Staker.DepositIdentifier) {
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), amount);
        Staker.DepositIdentifier depositId = regenStaker.stake(amount, delegatee, user);
        vm.stopPrank();
        return depositId;
    }

    function startRewardPeriod(uint256 rewardAmount) internal {
        vm.startPrank(rewardNotifier);
        rewardToken.approve(address(regenStaker), rewardAmount);
        rewardToken.transfer(address(regenStaker), rewardAmount);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.stopPrank();
    }

    function allocateVaultToStrategy(uint256 amount) internal {
        vm.prank(vaultManager);
        vault.updateDebt(address(strategy), amount, 0);
    }

    function reportStrategyProfit(uint256 /* profit */) internal {
        // MockYieldStrategy handles reporting internally
        vm.prank(keeper);
        strategy.report();

        // Vault needs to process the report to update totalAssets
        vm.prank(vaultManager);
        vault.processReport(address(strategy));
    }

    function generateYieldSourceProfit(uint256 profit) internal {
        // Add profit directly to strategy for testing
        asset.mint(address(this), profit);
        asset.approve(address(strategy), profit);
        strategy.addYield(profit);
    }
}
