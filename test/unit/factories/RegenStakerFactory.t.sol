// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";

contract RegenStakerFactoryTest is Test {
    RegenStakerFactory public factory;

    IERC20 public rewardsToken;
    IERC20Staking public stakeToken;
    IEarningPowerCalculator public earningPowerCalculator;

    address public admin;
    address public deployer1;
    address public deployer2;

    IAddressSet public stakerAllowset;
    IAddressSet public contributionAllowset;
    IAddressSet public allocationMechanismAllowset;

    uint256 public constant MAX_BUMP_TIP = 1000e18;
    uint256 public constant MAX_CLAIM_FEE = 500;
    uint256 public constant MINIMUM_STAKE_AMOUNT = 100e18;
    uint256 public constant REWARD_DURATION = 30 days;

    event StakerDeploy(
        address indexed deployer,
        address indexed admin,
        address indexed stakerAddress,
        bytes32 salt,
        RegenStakerFactory.RegenStakerVariant variant,
        address calculatorAddress
    );

    function setUp() public {
        admin = address(0x1);
        deployer1 = address(0x2);
        deployer2 = address(0x3);

        rewardsToken = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();

        // Deploy the factory with both variants' bytecode hashes (this test contract is the deployer)
        bytes32 regenStakerBytecodeHash = keccak256(type(RegenStaker).creationCode);
        bytes32 noDelegationBytecodeHash = keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode);
        factory = new RegenStakerFactory(regenStakerBytecodeHash, noDelegationBytecodeHash);

        vm.label(address(factory), "RegenStakerFactory");
        vm.label(address(rewardsToken), "RewardsToken");
        vm.label(address(stakeToken), "StakeToken");
        vm.label(admin, "Admin");
        vm.label(deployer1, "Deployer1");
        vm.label(deployer2, "Deployer2");
    }

    function getRegenStakerBytecode() internal pure returns (bytes memory) {
        return type(RegenStaker).creationCode;
    }

    function testCreateStaker() public {
        bytes32 salt = keccak256("TEST_STAKER_SALT");

        // Build constructor params and bytecode for prediction
        bytes memory constructorParams = abi.encode(
            rewardsToken,
            stakeToken,
            earningPowerCalculator,
            MAX_BUMP_TIP,
            admin,
            REWARD_DURATION,
            MINIMUM_STAKE_AMOUNT,
            stakerAllowset,
            IAddressSet(address(0)), // stakerBlockset
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        bytes memory bytecode = bytes.concat(getRegenStakerBytecode(), constructorParams);

        vm.startPrank(deployer1);
        address predictedAddress = factory.predictStakerAddress(salt, deployer1, bytecode);

        vm.expectEmit(true, true, true, true);
        emit StakerDeploy(
            deployer1,
            admin,
            predictedAddress,
            salt,
            RegenStakerFactory.RegenStakerVariant.WITH_DELEGATION,
            address(earningPowerCalculator)
        );

        address stakerAddress = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt,
            getRegenStakerBytecode()
        );
        vm.stopPrank();

        assertTrue(stakerAddress != address(0), "Staker address should not be zero");

        RegenStaker staker = RegenStaker(stakerAddress);
        assertEq(address(staker.REWARD_TOKEN()), address(rewardsToken), "Rewards token should be set correctly");
        assertEq(address(staker.STAKE_TOKEN()), address(stakeToken), "Stake token should be set correctly");
        assertEq(staker.minimumStakeAmount(), MINIMUM_STAKE_AMOUNT, "Minimum stake amount should be set correctly");
    }

    function testCreateMultipleStakers() public {
        bytes32 salt1 = keccak256("FIRST_STAKER_SALT");
        bytes32 salt2 = keccak256("SECOND_STAKER_SALT");

        vm.startPrank(deployer1);
        address firstStaker = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt1,
            getRegenStakerBytecode()
        );

        address secondStaker = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP + 100,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT + 50e18,
                rewardDuration: REWARD_DURATION
            }),
            salt2,
            getRegenStakerBytecode()
        );
        vm.stopPrank();

        assertTrue(firstStaker != secondStaker, "Stakers should have different addresses");
    }

    function testCreateStakersForDifferentDeployers() public {
        bytes32 salt1 = keccak256("DEPLOYER1_SALT");
        bytes32 salt2 = keccak256("DEPLOYER2_SALT");

        vm.prank(deployer1);
        address staker1 = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt1,
            getRegenStakerBytecode()
        );

        vm.prank(deployer2);
        address staker2 = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt2,
            getRegenStakerBytecode()
        );

        assertTrue(staker1 != staker2, "Stakers should have different addresses");
    }

    function testDeterministicAddressing() public {
        bytes32 salt = keccak256("DETERMINISTIC_SALT");

        // Build constructor params and bytecode for prediction
        bytes memory constructorParams = abi.encode(
            rewardsToken,
            stakeToken,
            earningPowerCalculator,
            MAX_BUMP_TIP,
            admin,
            REWARD_DURATION,
            MINIMUM_STAKE_AMOUNT,
            stakerAllowset,
            IAddressSet(address(0)), // stakerBlockset
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        bytes memory bytecode = bytes.concat(getRegenStakerBytecode(), constructorParams);

        vm.prank(deployer1);
        address predictedAddress = factory.predictStakerAddress(salt, deployer1, bytecode);

        vm.prank(deployer1);
        address actualAddress = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: stakerAllowset,
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt,
            getRegenStakerBytecode()
        );

        assertEq(predictedAddress, actualAddress, "Predicted address should match actual address");
    }

    function testCreateStakerWithNullAllowsets() public {
        bytes32 salt = keccak256("NULL_ALLOWSET_SALT");

        vm.prank(deployer1);
        address stakerAddress = factory.createStakerWithDelegation(
            RegenStakerFactory.CreateStakerParams({
                rewardsToken: rewardsToken,
                stakeToken: stakeToken,
                admin: admin,
                stakerAllowset: IAddressSet(address(0)),
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allocationMechanismAllowset,
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: MAX_BUMP_TIP,
                minimumStakeAmount: MINIMUM_STAKE_AMOUNT,
                rewardDuration: REWARD_DURATION
            }),
            salt,
            getRegenStakerBytecode()
        );

        assertTrue(stakerAddress != address(0), "Staker should be created with null allowsets");

        RegenStaker staker = RegenStaker(stakerAddress);
        assertEq(
            address(staker.stakerAllowset()),
            address(0),
            "Staker allowset should be null when address(0) is passed"
        );
    }
}
