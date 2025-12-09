// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockERC20Permit } from "test/mocks/MockERC20Permit.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RegenStakerFactoryVariantsTest
 * @notice Tests for the RegenStakerFactory contract explicit variant deployment
 */
contract RegenStakerFactoryVariantsTest is Test {
    RegenStakerFactory factory;
    RegenEarningPowerCalculator calculator;
    AddressSet stakerAllowset;
    AddressSet contributionAllowset;
    AddressSet allocationMechanismAllowset;

    MockERC20 basicToken;
    MockERC20Permit permitToken;
    MockERC20Staking stakingToken;

    address public constant ADMIN = address(0x1);
    uint256 public constant MAX_BUMP_TIP = 1e18;
    uint256 public constant MAX_CLAIM_FEE = 1e18;
    uint256 public constant MIN_REWARD_DURATION = 7 days;

    function setUp() public {
        vm.startPrank(ADMIN);

        bytes32 permitCodeHash = keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode);
        bytes32 stakingCodeHash = keccak256(type(RegenStaker).creationCode);
        factory = new RegenStakerFactory(stakingCodeHash, permitCodeHash);

        basicToken = new MockERC20(18);
        permitToken = new MockERC20Permit(18);
        stakingToken = new MockERC20Staking(18);

        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();

        calculator = new RegenEarningPowerCalculator(
            ADMIN,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        vm.stopPrank();
    }

    function test_CreateStakerWithoutDelegation_WithBasicERC20_Success() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(basicToken)),
            stakeToken: IERC20(address(basicToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory permitCode = type(RegenStakerWithoutDelegateSurrogateVotes).creationCode;

        address stakerAddress = factory.createStakerWithoutDelegation(params, bytes32(uint256(1)), permitCode);

        assertTrue(stakerAddress != address(0));
        assertTrue(stakerAddress.code.length > 0);
    }

    function test_CreateStakerWithoutDelegation_WithPermitToken_Success() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(permitToken)),
            stakeToken: IERC20(address(permitToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory permitCode = type(RegenStakerWithoutDelegateSurrogateVotes).creationCode;

        address stakerAddress = factory.createStakerWithoutDelegation(params, bytes32(uint256(2)), permitCode);

        assertTrue(stakerAddress != address(0));
        assertTrue(stakerAddress.code.length > 0);
    }

    function test_CreateStakerWithDelegation_WithStakingToken_Success() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(stakingToken)),
            stakeToken: IERC20(address(stakingToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory stakingCode = type(RegenStaker).creationCode;

        address stakerAddress = factory.createStakerWithDelegation(params, bytes32(uint256(3)), stakingCode);

        assertTrue(stakerAddress != address(0));
        assertTrue(stakerAddress.code.length > 0);
    }

    function test_CreateStakerWithDelegation_WithBasicToken_Success() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(basicToken)),
            stakeToken: IERC20(address(basicToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory stakingCode = type(RegenStaker).creationCode;

        address stakerAddress = factory.createStakerWithDelegation(params, bytes32(uint256(4)), stakingCode);

        assertTrue(stakerAddress != address(0));
        assertTrue(stakerAddress.code.length > 0);
    }

    function test_RevertIf_CreateStakerNoDelegation_WithInvalidBytecode() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(basicToken)),
            stakeToken: IERC20(address(basicToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory wrongCode = type(RegenStaker).creationCode; // Using with-delegation code for without-delegation variant

        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerFactory.UnauthorizedBytecode.selector,
                RegenStakerFactory.RegenStakerVariant.WITHOUT_DELEGATION,
                keccak256(wrongCode),
                factory.canonicalBytecodeHash(RegenStakerFactory.RegenStakerVariant.WITHOUT_DELEGATION)
            )
        );

        factory.createStakerWithoutDelegation(params, bytes32(uint256(5)), wrongCode);
    }

    function test_RevertIf_CreateStakerERC20Staking_WithInvalidBytecode() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(stakingToken)),
            stakeToken: IERC20(address(stakingToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        bytes memory wrongCode = type(RegenStakerWithoutDelegateSurrogateVotes).creationCode; // Using without-delegation code for with-delegation variant

        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerFactory.UnauthorizedBytecode.selector,
                RegenStakerFactory.RegenStakerVariant.WITH_DELEGATION,
                keccak256(wrongCode),
                factory.canonicalBytecodeHash(RegenStakerFactory.RegenStakerVariant.WITH_DELEGATION)
            )
        );

        factory.createStakerWithDelegation(params, bytes32(uint256(6)), wrongCode);
    }

    function test_RevertIf_CreateStaker_WithEmptyBytecode() public {
        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(address(basicToken)),
            stakeToken: IERC20(address(basicToken)),
            admin: ADMIN,
            stakerAllowset: stakerAllowset,
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: allocationMechanismAllowset,
            earningPowerCalculator: calculator,
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: 0,
            rewardDuration: MIN_REWARD_DURATION
        });

        vm.expectRevert(RegenStakerFactory.InvalidBytecode.selector);
        factory.createStakerWithoutDelegation(params, bytes32(uint256(7)), "");

        vm.expectRevert(RegenStakerFactory.InvalidBytecode.selector);
        factory.createStakerWithDelegation(params, bytes32(uint256(8)), "");
    }

    function test_CanonicalBytecodeHashes_SetCorrectly() public view {
        bytes32 noDelegationHash = factory.canonicalBytecodeHash(
            RegenStakerFactory.RegenStakerVariant.WITHOUT_DELEGATION
        );
        bytes32 erc20StakingHash = factory.canonicalBytecodeHash(RegenStakerFactory.RegenStakerVariant.WITH_DELEGATION);

        assertTrue(noDelegationHash != bytes32(0));
        assertTrue(erc20StakingHash != bytes32(0));
        assertTrue(noDelegationHash != erc20StakingHash);
    }

    function test_PredictStakerAddress_WorksCorrectly() public view {
        bytes32 salt = bytes32(uint256(100));
        address deployer = address(0x123);

        // Create constructor params to build bytecode
        bytes memory constructorParams = abi.encode(
            basicToken,
            basicToken,
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            MIN_REWARD_DURATION,
            0, // minimumStakeAmount
            stakerAllowset,
            contributionAllowset,
            allocationMechanismAllowset
        );

        // Build bytecode with constructor params (using WITH_DELEGATION variant)
        bytes memory bytecode = bytes.concat(type(RegenStaker).creationCode, constructorParams);

        address predicted = factory.predictStakerAddress(salt, deployer, bytecode);
        assertTrue(predicted != address(0));
    }
}
