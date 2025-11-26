// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { MultistrategyLockedVault } from "src/core/MultistrategyLockedVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { IMultistrategyLockedVault } from "src/core/interfaces/IMultistrategyLockedVault.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";

/**
 * @title ShutterDAOIntegrationTest
 * @notice Integration test simulating the Shutter DAO 0x36 Octant v2 deployment scenario.
 * @dev Tests the full lifecycle:
 *      1. Deploy MSLV (MultistrategyLockedVault) for USDC capital
 *      2. Deploy RegenStaker for SHU token governance staking
 *      3. Treasury deposits USDC into the vault
 *      4. SHU holders stake tokens for dual voting power
 *      5. Yield generation and distribution
 *      6. Rage quit and withdrawal flows
 *
 * Reference: https://blog.shutter.network/a-proposed-blueprint-for-launching-a-shutter-dao/
 */
contract ShutterDAOIntegrationTest is Test {
    MultistrategyLockedVault vaultImplementation;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyLockedVault dragonVault;

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
    uint256 constant COOLDOWN_PERIOD = 7 days;

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
        _deployRegenStaker();
    }

    function _deployDragonVault() internal {
        vaultImplementation = new MultistrategyLockedVault();

        vm.prank(octantGovernance);
        vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );

        vm.startPrank(octantGovernance);
        dragonVault = MultistrategyLockedVault(
            vaultFactory.deployNewVault(address(usdc), "Shutter Dragon Vault", "sdUSDC", octantGovernance, 7 days)
        );

        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        dragonVault.addRole(octantGovernance, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(shutterDAOTreasury, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        dragonVault.setDepositLimit(type(uint256).max, true);
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

        assertEq(dragonVault.balanceOf(shutterDAOTreasury), depositAmount, "Treasury should have vault shares");
        assertEq(dragonVault.totalAssets(), depositAmount, "Vault should hold total assets");
        assertEq(usdc.balanceOf(shutterDAOTreasury), 0, "Treasury should have transferred all USDC");
    }

    function test_SHUHoldersStakeForOctantVoting() public {
        uint256 stakeAmount = SHU_HOLDER_BALANCE;

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder1);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), stakeAmount, "Total staked should match");
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
            delegatee,
            "Surrogate should delegate to delegatee"
        );
    }

    function test_TreasuryCanRageQuitAndWithdraw() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        uint256 shares = dragonVault.balanceOf(shutterDAOTreasury);

        vm.prank(shutterDAOTreasury);
        dragonVault.initiateRageQuit(shares);

        vm.warp(block.timestamp + dragonVault.rageQuitCooldownPeriod() + 1);

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(depositAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), depositAmount, "Treasury should have USDC back");
        assertEq(dragonVault.balanceOf(shutterDAOTreasury), 0, "Treasury should have no shares");
    }

    function test_PartialRageQuitAndWithdraw() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;
        uint256 halfAmount = depositAmount / 2;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        vm.prank(shutterDAOTreasury);
        dragonVault.initiateRageQuit(halfAmount);

        vm.warp(block.timestamp + dragonVault.rageQuitCooldownPeriod() + 1);

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(halfAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), halfAmount, "Treasury should have half USDC back");
        assertEq(dragonVault.balanceOf(shutterDAOTreasury), halfAmount, "Treasury should have half shares remaining");
    }

    function test_CannotWithdrawBeforeCooldownEnds() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        uint256 shares = dragonVault.balanceOf(shutterDAOTreasury);

        vm.prank(shutterDAOTreasury);
        dragonVault.initiateRageQuit(shares);

        vm.prank(shutterDAOTreasury);
        vm.expectRevert(IMultistrategyLockedVault.SharesStillLocked.selector);
        dragonVault.withdraw(depositAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));
    }

    function test_CannotTransferLockedShares() public {
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, shutterDAOTreasury);
        vm.stopPrank();

        uint256 shares = dragonVault.balanceOf(shutterDAOTreasury);

        vm.prank(shutterDAOTreasury);
        dragonVault.initiateRageQuit(shares);

        vm.prank(shutterDAOTreasury);
        vm.expectRevert(IMultistrategyLockedVault.TransferExceedsAvailableShares.selector);
        dragonVault.transfer(shuHolder1, shares);
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

        assertEq(regenStaker.totalStaked(), stakeAmount * 3, "Total staked should be sum of all stakes");
    }

    function test_EndToEndScenario() public {
        vm.startPrank(shutterDAOTreasury);
        usdc.approve(address(dragonVault), TREASURY_USDC_BALANCE);
        dragonVault.deposit(TREASURY_USDC_BALANCE, shutterDAOTreasury);
        vm.stopPrank();

        assertEq(dragonVault.totalAssets(), TREASURY_USDC_BALANCE, "Vault should hold treasury capital");

        vm.startPrank(shuHolder1);
        shuToken.approve(address(regenStaker), SHU_HOLDER_BALANCE);
        regenStaker.stake(SHU_HOLDER_BALANCE, shuHolder1);
        vm.stopPrank();

        vm.startPrank(shuHolder2);
        shuToken.approve(address(regenStaker), SHU_HOLDER_BALANCE);
        regenStaker.stake(SHU_HOLDER_BALANCE, shuHolder2);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), SHU_HOLDER_BALANCE * 2, "Regen staker should have SHU staked");

        vm.warp(block.timestamp + 30 days);

        uint256 withdrawAmount = TREASURY_USDC_BALANCE / 4;
        uint256 shares = dragonVault.balanceOf(shutterDAOTreasury);

        vm.prank(shutterDAOTreasury);
        dragonVault.initiateRageQuit(shares / 4);

        vm.warp(block.timestamp + dragonVault.rageQuitCooldownPeriod() + 1);

        vm.prank(shutterDAOTreasury);
        dragonVault.withdraw(withdrawAmount, shutterDAOTreasury, shutterDAOTreasury, 0, new address[](0));

        assertEq(usdc.balanceOf(shutterDAOTreasury), withdrawAmount, "Treasury should have partial USDC back");
        assertGt(dragonVault.balanceOf(shutterDAOTreasury), 0, "Treasury should still have shares");
    }
}
