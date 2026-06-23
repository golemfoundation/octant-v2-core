// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

/**
 * @title RegenEarningPowerCalculatorFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deterministic RegenEarningPowerCalculator deployment via CREATE2
 * @dev Final salt = keccak256(salt, owner). Ownership is set in the calculator's constructor.
 */
contract RegenEarningPowerCalculatorFactory {
    /// @notice Information about a deployed RegenEarningPowerCalculator
    struct CalculatorInfo {
        address deployerAddress;
        uint256 timestamp;
        address owner;
        address calculatorAddress;
        bytes32 salt;
    }

    /// @dev Tracks deployed calculators per deployer
    mapping(address => CalculatorInfo[]) public calculators;

    /// @notice Emitted when a new RegenEarningPowerCalculator is deployed
    /// @param deployer Address that called deploy
    /// @param calculator Deployed calculator address
    /// @param owner Address that owns the calculator
    /// @param salt Salt used for CREATE2 derivation
    event CalculatorDeployed(address indexed deployer, address indexed calculator, address indexed owner, bytes32 salt);

    /// @notice Deploy a new RegenEarningPowerCalculator with deterministic address
    /// @param salt Salt for CREATE2 address derivation
    /// @param owner Address that will own the calculator (Ownable admin)
    /// @param allowset Allowset contract address (active in ALLOWSET mode)
    /// @param blockset Blockset contract address (active in BLOCKSET mode)
    /// @param accessMode Initial access mode (NONE, ALLOWSET, or BLOCKSET)
    /// @return calculator Deployed calculator address
    function deploy(
        bytes32 salt,
        address owner,
        IAddressSet allowset,
        IAddressSet blockset,
        AccessMode accessMode
    ) external returns (address calculator) {
        bytes32 finalSalt = keccak256(abi.encode(salt, owner));
        RegenEarningPowerCalculator calc = new RegenEarningPowerCalculator{ salt: finalSalt }(
            owner,
            allowset,
            blockset,
            accessMode
        );
        calculator = address(calc);
        _recordCalculator(owner, calculator, salt);
        emit CalculatorDeployed(msg.sender, calculator, owner, salt);
    }

    /// @notice Predict deployment address before calling deploy
    /// @param salt Salt for CREATE2 address derivation
    /// @param owner Address that will own the calculator
    /// @param allowset Allowset contract address
    /// @param blockset Blockset contract address
    /// @param accessMode Access mode
    /// @return predicted Predicted deployment address
    function predictAddress(
        bytes32 salt,
        address owner,
        IAddressSet allowset,
        IAddressSet blockset,
        AccessMode accessMode
    ) external view returns (address predicted) {
        bytes32 finalSalt = keccak256(abi.encode(salt, owner));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                finalSalt,
                keccak256(
                    abi.encodePacked(
                        type(RegenEarningPowerCalculator).creationCode,
                        abi.encode(owner, allowset, blockset, accessMode)
                    )
                )
            )
        );
        predicted = address(uint160(uint256(hash)));
    }

    /// @notice Returns all calculators deployed by a specific address
    /// @param deployer Deployer address
    /// @return Array of CalculatorInfo entries for every calculator deployed by the given deployer
    function getCalculatorsByDeployer(address deployer) external view returns (CalculatorInfo[] memory) {
        return calculators[deployer];
    }

    function _recordCalculator(address owner, address deployedCalculator, bytes32 salt) internal {
        calculators[msg.sender].push(
            CalculatorInfo({
                deployerAddress: msg.sender,
                timestamp: block.timestamp,
                owner: owner,
                calculatorAddress: deployedCalculator,
                salt: salt
            })
        );
    }
}
