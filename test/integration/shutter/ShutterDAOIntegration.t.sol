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

        vm.startPrank(octantGovernance);
        dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(address(usdc), "Shutter Dragon Vault", "sdUSDC", octantGovernance, PROFIT_MAX_UNLOCK_TIME)
        );

        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        dragonVault.setDepositLimit(type(uint256).max, true);
        vm.stopPrank();
    }

    function _deployStrategy() internal {
        strategy = new MockYieldStrategy(address(usdc), address(dragonVault));

        vm.startPrank(octantGovernance);
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
        vm.prank(octantGovernance);
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
        vm.prank(octantGovernance);
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

        assertEq(
            shuToken.delegates(regenStaker.predictSurrogateAddress(delegatee)),
            delegatee
        );
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
        vm.prank(octantGovernance);
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
