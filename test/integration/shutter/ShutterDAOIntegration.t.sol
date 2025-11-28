// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";

/**
 * @title ShutterDAOIntegrationTest
 * @notice Integration test simulating the Shutter DAO 0x36 Octant v2 deployment scenario.
 * @dev Tests the full lifecycle:
 *      1. Deploy MultistrategyVault (no lockup) for USDC capital
 *      2. Deploy RegenStaker for SHU token governance staking
 *      3. Treasury deposits USDC into the vault
 *      4. SHU holders stake tokens for public goods funding
 *      5. AutoAllocate vs Keeper-triggered allocation
 *      6. Instant withdrawal flows
 *
 * Reference: https://blog.shutter.network/a-proposed-blueprint-for-launching-a-shutter-dao/
 */
contract ShutterDAOIntegrationTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyVault dragonVault;
    MockYieldStrategy strategy;

    RegenStaker regenStaker;
    RegenEarningPowerCalculator calculator;
    AddressSet allocationMechanismAllowset;
    AddressSet earningPowerAllowset;

    MockERC20 usdc;
    MockERC20Staking shuToken;
    MockERC20 rewardToken;

    address shutterDAOTreasury;
    address shutterDAOMultisig;
    address octantGovernance;
    address keeper;

    address shuHolder1;
    address shuHolder2;
    address shuHolder3;

    uint256 constant TREASURY_USDC_BALANCE = 1_500_000e6;
    uint256 constant SHU_HOLDER_BALANCE = 100_000e18;
    uint256 constant REWARD_DURATION = 90 days;
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;

    function setUp() public {
        shutterDAOTreasury = makeAddr("ShutterDAOTreasury");
        shutterDAOMultisig = makeAddr("ShutterDAOMultisig");
        octantGovernance = makeAddr("OctantGovernance");
        keeper = makeAddr("Keeper");

        shuHolder1 = makeAddr("SHUHolder1");
        shuHolder2 = makeAddr("SHUHolder2");
        shuHolder3 = makeAddr("SHUHolder3");

        usdc = new MockERC20(6);
        shuToken = new MockERC20Staking(18);
        rewardToken = new MockERC20(18);

        usdc.mint(shutterDAOTreasury, TREASURY_USDC_BALANCE);
        shuToken.mint(shuHolder1, SHU_HOLDER_BALANCE);
        shuToken.mint(shuHolder2, SHU_HOLDER_BALANCE);
        shuToken.mint(shuHolder3, SHU_HOLDER_BALANCE);

        _deployDragonVault();
        _deployStrategy();
        _deployRegenStaker();
    }

    function _deployDragonVault() internal {
        vaultImplementation = new MultistrategyVault();

        vm.prank(octantGovernance);
        vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );

        vm.startPrank(shutterDAOTreasury);
        dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(
                address(usdc),
                "Shutter Dragon Vault",
                "sdUSDC",
                shutterDAOTreasury,
                PROFIT_MAX_UNLOCK_TIME
            )
        );

        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        dragonVault.setDepositLimit(type(uint256).max, true);
        vm.stopPrank();
    }

    function _deployStrategy() internal {
        strategy = new MockYieldStrategy(address(usdc), address(dragonVault));

        vm.startPrank(shutterDAOTreasury);
        dragonVault.addStrategy(address(strategy), true);
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    function _deployRegenStaker() internal {
        vm.startPrank(shutterDAOMultisig);

        allocationMechanismAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();

        calculator = new RegenEarningPowerCalculator(
            shutterDAOMultisig,
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        regenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(shuToken)),
            calculator,
            1e18,
            shutterDAOMultisig,
            uint128(REWARD_DURATION),
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );

        regenStaker.setRewardNotifier(shutterDAOMultisig, true);
        vm.stopPrank();
    }

    function test_TreasuryDepositsUSDCIntoDragonVault() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.balanceOf(shutterDAOTreasury), depositAmount);
        assertEq(dragonVault.totalAssets(), depositAmount);
        assertEq(usdc.balanceOf(shutterDAOTreasury), 0);
    }

    function test_AutoAllocateDeploysToStrategy() public {
        vm.prank(shutterDAOTreasury);
        dragonVault.setAutoAllocate(true);

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.balanceOf(shutterDAOTreasury), depositAmount);
        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
        assertEq(strategy.totalAssets(), depositAmount);
    }

    function test_KeeperTriggeredAllocation() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.totalIdle(), depositAmount);
        assertEq(dragonVault.totalDebt(), 0);

        vm.prank(keeper);
        dragonVault.updateDebt(address(strategy), type(uint256).max, 0);

        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
        assertEq(strategy.totalAssets(), depositAmount);
    }

    function test_TreasuryCanWithdrawInstantly() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(depositAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), depositAmount);
        assertEq(dragonVault.balanceOf(shutterDAOTreasury), 0);
    }

    function test_TreasuryCanWithdrawFromStrategy() public {
        vm.prank(shutterDAOTreasury);
        dragonVault.setAutoAllocate(true);

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.totalDebt(), depositAmount);

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(depositAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), depositAmount);
        assertEq(dragonVault.balanceOf(shutterDAOTreasury), 0);
        assertEq(dragonVault.totalDebt(), 0);
    }

    function test_PartialWithdraw() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;
        uint256 halfAmount = depositAmount / 2;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(halfAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), halfAmount);
        assertEq(dragonVault.balanceOf(shutterDAOTreasury), halfAmount);
    }

    function test_SHUHoldersStakeForPublicGoodsFunding() public {
        uint256 stakeAmount = SHU_HOLDER_BALANCE;

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder1);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), stakeAmount);
    }

    function test_SHUHoldersCanDelegateVotingPower() public {
        uint256 stakeAmount = SHU_HOLDER_BALANCE;
        address delegatee = makeAddr("Delegatee");

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, delegatee);
        vm.stopPrank();

        assertEq(shuToken.delegates(regenStaker.predictSurrogateAddress(delegatee)), delegatee);
    }

    function test_MultipleSHUHoldersCanStake() public {
        uint256 stakeAmount = SHU_HOLDER_BALANCE;

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder1);
        vm.stopPrank();

        vm.startPrank(shuHolder2);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder2);
        vm.stopPrank();

        vm.startPrank(shuHolder3);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder3);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), stakeAmount * 3);
    }

    function test_EndToEndScenario() public {
        vm.prank(shutterDAOTreasury);
        dragonVault.setAutoAllocate(true);

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), TREASURY_USDC_BALANCE);
        dragonVault.deposit(TREASURY_USDC_BALANCE, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.totalAssets(), TREASURY_USDC_BALANCE);
        assertEq(dragonVault.totalDebt(), TREASURY_USDC_BALANCE);

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), SHU_HOLDER_BALANCE);
        regenStaker.stake(SHU_HOLDER_BALANCE, shuHolder1);
        vm.stopPrank();

        vm.startPrank(shuHolder2);
        shuToken.approve(address(regenStaker), SHU_HOLDER_BALANCE);
        regenStaker.stake(SHU_HOLDER_BALANCE, shuHolder2);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), SHU_HOLDER_BALANCE * 2);

        vm.warp(block.timestamp + 30 days);

        uint256 withdrawAmount = TREASURY_USDC_BALANCE / 4;

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(withdrawAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), withdrawAmount);
        assertGt(dragonVault.balanceOf(shutterDAOTreasury), 0);
    }

    function test_SharesAreTransferable() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        uint256 shares = dragonVault.balanceOf(shutterDAOTreasury);
        uint256 halfShares = shares / 2;

        vm.prank(shutterDAOTreasury);
        dragonVault.transfer(shuHolder1, halfShares);

        assertEq(dragonVault.balanceOf(shutterDAOTreasury), halfShares);
        assertEq(dragonVault.balanceOf(shuHolder1), halfShares);
    }
}

/**
 * @title ShutterDAOGasProfilingTest
 * @notice Gas profiling test to verify batched DAO proposal fits within 16M gas (EIP-7825).
 * @dev Simulates the exact transaction sequence that would be executed via Fractal/Decent.
 *      This test does NOT use setUp() to accurately measure deployment costs.
 */
contract ShutterDAOGasProfilingTest is Test {
    uint256 constant TREASURY_USDC_BALANCE = 1_500_000e6;
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;
    uint256 constant EIP_7825_BLOCK_GAS_LIMIT = 16_000_000;

    /**
     * @notice Measures gas for the complete batched DAO proposal.
     * @dev Simulates all 8 transactions from the playbook executed atomically.
     *      Expected to fit well under 16M gas.
     */
    function test_BatchedProposalGasProfile() public {
        address shutterDAOTreasury = makeAddr("ShutterDAOTreasury");
        address octantGovernance = makeAddr("OctantGovernance");
        address keeper = makeAddr("Keeper");

        MockERC20 usdc = new MockERC20(6);
        usdc.mint(shutterDAOTreasury, TREASURY_USDC_BALANCE);

        uint256 gasStart = gasleft();

        // === BATCHED PROPOSAL STARTS HERE ===
        // All operations below would be in a single DAO proposal

        // Pre-deployed by Octant (not part of DAO proposal gas)
        MultistrategyVault vaultImplementation = new MultistrategyVault();
        MultistrategyVaultFactory vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );

        uint256 gasAfterFactoryDeploy = gasleft();

        // TX 1: Deploy Strategy (simulated - in reality uses MorphoCompounderStrategy)
        vm.prank(shutterDAOTreasury);
        MockYieldStrategy strategy = new MockYieldStrategy(address(usdc), address(0));

        uint256 gasAfterStrategyDeploy = gasleft();

        // TX 2: Deploy Dragon Vault via Factory
        vm.prank(shutterDAOTreasury);
        MultistrategyVault dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(
                address(usdc),
                "Shutter Dragon Vault",
                "sdUSDC",
                shutterDAOTreasury,
                PROFIT_MAX_UNLOCK_TIME
            )
        );

        uint256 gasAfterVaultDeploy = gasleft();

        // Update strategy's vault reference
        strategy = new MockYieldStrategy(address(usdc), address(dragonVault));

        // TX 3-6: Configure vault roles and settings
        vm.startPrank(shutterDAOTreasury);

        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        // TX 3: Add Strategy
        dragonVault.addStrategy(address(strategy), true);

        // TX 4: Set Max Debt
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);

        // TX 5: Set Deposit Limit
        dragonVault.setDepositLimit(type(uint256).max, true);

        // TX 6: Enable AutoAllocate (optional)
        dragonVault.setAutoAllocate(true);

        uint256 gasAfterConfig = gasleft();

        // TX 7: Approve USDC
        usdc.approve(address(dragonVault), TREASURY_USDC_BALANCE);

        // TX 8: Deposit USDC
        dragonVault.deposit(TREASURY_USDC_BALANCE, shutterDAOTreasury);

        vm.stopPrank();

        // === BATCHED PROPOSAL ENDS HERE ===

        uint256 gasEnd = gasleft();
        uint256 totalGasUsed = gasStart - gasEnd;

        // Calculate individual phase costs
        uint256 factoryDeployGas = gasStart - gasAfterFactoryDeploy;
        uint256 strategyDeployGas = gasAfterFactoryDeploy - gasAfterStrategyDeploy;
        uint256 vaultDeployGas = gasAfterStrategyDeploy - gasAfterVaultDeploy;
        uint256 configGas = gasAfterVaultDeploy - gasAfterConfig;
        uint256 depositGas = gasAfterConfig - gasEnd;

        // Log gas breakdown
        emit log_named_uint("Factory + Impl Deploy (pre-deployed)", factoryDeployGas);
        emit log_named_uint("Strategy Deploy", strategyDeployGas);
        emit log_named_uint("Vault Deploy (via factory)", vaultDeployGas);
        emit log_named_uint("Vault Configuration", configGas);
        emit log_named_uint("Approve + Deposit", depositGas);
        emit log_named_uint("=== TOTAL GAS USED ===", totalGasUsed);
        emit log_named_uint("EIP-7825 Block Gas Limit", EIP_7825_BLOCK_GAS_LIMIT);
        emit log_named_uint("Remaining Headroom", EIP_7825_BLOCK_GAS_LIMIT - totalGasUsed);

        // The DAO proposal only includes TX 1-8, not factory deployment
        // Factory is pre-deployed by Octant
        uint256 daoProposalGas = totalGasUsed - factoryDeployGas;
        emit log_named_uint("=== DAO PROPOSAL GAS (excl factory) ===", daoProposalGas);

        // Assert fits within block gas limit with margin
        assertLt(daoProposalGas, EIP_7825_BLOCK_GAS_LIMIT, "DAO proposal exceeds 16M gas limit");

        // Verify deployment succeeded
        assertEq(dragonVault.totalAssets(), TREASURY_USDC_BALANCE);
        assertEq(dragonVault.totalDebt(), TREASURY_USDC_BALANCE);
        assertEq(strategy.totalAssets(), TREASURY_USDC_BALANCE);
    }

    /**
     * @notice Measures gas for deposit-only scenario (vault already deployed).
     * @dev This is the simpler case where Octant pre-deploys everything.
     */
    function test_DepositOnlyGasProfile() public {
        address shutterDAOTreasury = makeAddr("ShutterDAOTreasury");
        address octantGovernance = makeAddr("OctantGovernance");

        MockERC20 usdc = new MockERC20(6);
        usdc.mint(shutterDAOTreasury, TREASURY_USDC_BALANCE);

        // Pre-deploy everything (done by Octant before DAO proposal)
        MultistrategyVault vaultImplementation = new MultistrategyVault();
        MultistrategyVaultFactory vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );

        vm.prank(octantGovernance);
        MultistrategyVault dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(
                address(usdc),
                "Shutter Dragon Vault",
                "sdUSDC",
                octantGovernance,
                PROFIT_MAX_UNLOCK_TIME
            )
        );

        MockYieldStrategy strategy = new MockYieldStrategy(address(usdc), address(dragonVault));

        vm.startPrank(octantGovernance);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addStrategy(address(strategy), true);
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        dragonVault.setDepositLimit(type(uint256).max, true);
        dragonVault.setAutoAllocate(true);
        vm.stopPrank();

        // === DAO PROPOSAL: Just approve + deposit ===
        uint256 gasStart = gasleft();

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), TREASURY_USDC_BALANCE);
        dragonVault.deposit(TREASURY_USDC_BALANCE, shutterDAOTreasury);
        vm.stopPrank();

        uint256 gasEnd = gasleft();
        uint256 depositOnlyGas = gasStart - gasEnd;

        emit log_named_uint("=== DEPOSIT-ONLY GAS ===", depositOnlyGas);

        assertLt(depositOnlyGas, EIP_7825_BLOCK_GAS_LIMIT);
        assertEq(dragonVault.totalAssets(), TREASURY_USDC_BALANCE);
    }
}
