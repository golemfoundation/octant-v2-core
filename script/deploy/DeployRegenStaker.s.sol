// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { IERC20, IAddressSet, IEarningPowerCalculator } from "src/regen/RegenStakerBase.sol";
import { AccessMode } from "src/constants.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

/**
 * @title DeployRegenStaker
 * @author [Golem Foundation](https://golem.foundation)
 * @notice Deploy RegenStaker variants via RegenStakerFactory using Safe multisig
 */
contract DeployRegenStaker is Script, BatchScript {
    error InvalidAccessMode(uint256 mode);
    error InvalidRewardDuration(uint256 duration);

    string public constant DEFAULT_SALT_WITH_DELEGATION = "OCTANT_REGEN_STAKER_WITH_DELEGATION_V1";
    string public constant DEFAULT_SALT_WITHOUT_DELEGATION = "OCTANT_REGEN_STAKER_WITHOUT_DELEGATION_V1";

    address public safe;
    RegenStakerFactory public factory;

    function setUp() public {
        safe = _loadSafeAddress();
        factory = RegenStakerFactory(vm.envAddress("REGEN_STAKER_FACTORY"));
        console.log("Using Safe:", safe);
        console.log("RegenStakerFactory:", address(factory));
    }

    function deployWithDelegation() external isBatch(safe) returns (address) {
        return _deploy(true);
    }

    function deployWithoutDelegation() external isBatch(safe) returns (address) {
        return _deploy(false);
    }

    function _deploy(bool withDelegation) internal returns (address) {
        RegenStakerFactory.CreateStakerParams memory params = _loadParams();

        string memory saltLabel = vm.envOr(
            withDelegation ? "REGEN_STAKER_WITH_DELEGATION_SALT" : "REGEN_STAKER_WITHOUT_DELEGATION_SALT",
            withDelegation ? DEFAULT_SALT_WITH_DELEGATION : DEFAULT_SALT_WITHOUT_DELEGATION
        );
        if (bytes(saltLabel).length == 0) {
            saltLabel = withDelegation ? DEFAULT_SALT_WITH_DELEGATION : DEFAULT_SALT_WITHOUT_DELEGATION;
        }
        bytes32 salt = keccak256(bytes(saltLabel));

        bytes memory code = withDelegation
            ? type(RegenStaker).creationCode
            : type(RegenStakerWithoutDelegateSurrogateVotes).creationCode;

        bytes memory data = withDelegation
            ? abi.encodeWithSignature(
                "createStakerWithDelegation((address,address,address,address,address,uint8,address,address,uint256,uint256,uint256),bytes32,bytes)",
                params,
                salt,
                code
            )
            : abi.encodeWithSignature(
                "createStakerWithoutDelegation((address,address,address,address,address,uint8,address,address,uint256,uint256,uint256),bytes32,bytes)",
                params,
                salt,
                code
            );

        console.log("=== REGEN STAKER DEPLOYMENT ===");
        console.log("Variant:", withDelegation ? "WITH_DELEGATION" : "WITHOUT_DELEGATION");
        console.log("Salt string:", saltLabel);
        console.logBytes32(salt);

        bytes memory result = executeTransaction(address(factory), 0, data, Operation.CALL, true);
        address deployedAddress = abi.decode(result, (address));
        console.log("RegenStaker deployed at:", deployedAddress);
        return deployedAddress;
    }

    function _loadParams() internal view returns (RegenStakerFactory.CreateStakerParams memory params) {
        uint256 accessModeRaw = vm.envOr("ACCESS_MODE", uint256(0));
        if (accessModeRaw > 2) revert InvalidAccessMode(accessModeRaw);

        uint256 rewardDuration = vm.envOr("REWARD_DURATION", uint256(30 days));
        if (rewardDuration < 7 days || rewardDuration > 3000 days) {
            revert InvalidRewardDuration(rewardDuration);
        }

        params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(vm.envAddress("REWARDS_TOKEN")),
            stakeToken: IERC20(vm.envAddress("STAKE_TOKEN")),
            admin: vm.envOr("ADMIN", safe),
            stakerAllowset: IAddressSet(vm.envOr("STAKER_ALLOWSET", address(0))),
            stakerBlockset: IAddressSet(vm.envOr("STAKER_BLOCKSET", address(0))),
            stakerAccessMode: AccessMode(accessModeRaw),
            allocationMechanismAllowset: IAddressSet(vm.envAddress("ALLOCATION_ALLOWSET")),
            earningPowerCalculator: IEarningPowerCalculator(vm.envAddress("EARNING_POWER_CALCULATOR")),
            maxBumpTip: vm.envOr("MAX_BUMP_TIP", uint256(0)),
            minimumStakeAmount: vm.envOr("MIN_STAKE", uint256(0)),
            rewardDuration: rewardDuration
        });
    }
}
