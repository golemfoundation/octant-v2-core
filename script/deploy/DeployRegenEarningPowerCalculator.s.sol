// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

/**
 * @title DeployRegenEarningPowerCalculator
 * @author [Golem Foundation](https://golem.foundation)
 * @notice Deployment script for RegenEarningPowerCalculator using Safe multisig
 * @dev Deploys deterministically via CREATE2 factory
 */
contract DeployRegenEarningPowerCalculator is Script, BatchScript {
    error AddressMismatch(address expected, address actual);
    error InvalidOwner();
    error InvalidAccessMode(uint256 mode);

    /// @notice Default salt label for deterministic deployment
    string public constant DEFAULT_SALT_LABEL = "OCTANT_REGEN_EARNING_POWER_CALCULATOR_V1";
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_REGEN_EARNING_POWER_CALCULATOR_V1");

    /// @notice Deployed calculator contract
    RegenEarningPowerCalculator public calculator;

    /// @notice Safe address used to submit the batch
    address public safe;

    function setUp() public {
        safe = _loadSafeAddress();
        console.log("Using Safe:", safe);
    }

    function run() external isBatch(safe) returns (address) {
        return _deploy();
    }

    function _deploy() internal returns (address) {
        console.log("=== REGEN EARNING POWER CALCULATOR DEPLOYMENT ===");

        string memory saltLabel = vm.envOr("REGEN_EARNING_POWER_CALCULATOR_SALT", DEFAULT_SALT_LABEL);
        if (bytes(saltLabel).length == 0) {
            saltLabel = DEFAULT_SALT_LABEL;
        }
        bytes32 salt = keccak256(bytes(saltLabel));

        address owner = vm.envOr("EARNING_POWER_CALCULATOR_OWNER", safe);
        if (owner == address(0)) revert InvalidOwner();

        IAddressSet allowset = IAddressSet(vm.envOr("EARNING_POWER_ALLOWSET", address(0)));
        IAddressSet blockset = IAddressSet(vm.envOr("EARNING_POWER_BLOCKSET", address(0)));
        uint256 accessModeRaw = vm.envOr("EARNING_POWER_ACCESS_MODE", uint256(0));
        if (accessModeRaw > 2) revert InvalidAccessMode(accessModeRaw);
        AccessMode accessMode = AccessMode(accessModeRaw);

        bytes memory creationCode = abi.encodePacked(
            type(RegenEarningPowerCalculator).creationCode,
            abi.encode(owner, allowset, blockset, accessMode)
        );
        address expectedAddress = _computeCreate2AddressViaFactory(salt, creationCode);

        console.log("Expected calculator address:", expectedAddress);
        console.log("Salt string:", saltLabel);
        console.logBytes32(salt);
        console.log("Owner:", owner);
        console.log("Allowset:", address(allowset));
        console.log("Blockset:", address(blockset));
        console.log("AccessMode:", accessModeRaw);

        bytes memory deployData = abi.encodePacked(salt, creationCode);
        bytes memory result = executeTransaction(CREATE2_FACTORY, 0, deployData, Operation.CALL, true);
        address deployedAddress = _decodeCreate2DeployerResult(result);
        if (deployedAddress != expectedAddress) {
            revert AddressMismatch(expectedAddress, deployedAddress);
        }

        calculator = RegenEarningPowerCalculator(deployedAddress);
        console.log("RegenEarningPowerCalculator deployed at:", deployedAddress);
        return deployedAddress;
    }
}
