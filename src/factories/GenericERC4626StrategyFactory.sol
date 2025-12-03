// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { GenericERC4626Strategy } from "src/strategies/yieldDonating/GenericERC4626Strategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

/**
 * @title GenericERC4626StrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying Generic ERC4626 yield donating strategies
 * @dev Uses CREATE2 for deterministic deployments; records deployments via BaseStrategyFactory
 *
 *      GENERIC ERC4626 INTEGRATION:
 *      This factory deploys strategies that can deposit into any ERC4626-compliant vault,
 *      including SparkDAO vaults, Yearn v3 vaults, or any other standard ERC4626 implementation.
 *      The underlying vault must have manipulation-resistant accounting.
 */
contract GenericERC4626StrategyFactory is BaseStrategyFactory {
    /// @notice Emitted on successful strategy deployment
    /// @param deployer Transaction sender performing deployment
    /// @param targetVault ERC4626 vault address the strategy will deposit into
    /// @param donationAddress Donation destination address for strategy
    /// @param strategyAddress Deployed strategy address
    /// @param vaultTokenName Vault token name associated with strategy
    event StrategyDeploy(
        address indexed deployer,
        address indexed targetVault,
        address indexed donationAddress,
        address strategyAddress,
        string vaultTokenName
    );

    /**
     * @notice Deploy a new GenericERC4626 strategy
     * @dev Deterministic salt derived from all parameters to avoid duplicates
     * @param _targetVault ERC4626 vault address to deposit into
     * @param _asset Underlying asset address (must match vault's asset)
     * @param _name Strategy share token name
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed GenericERC4626Strategy address
     */
    function createStrategy(
        address _targetVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    ) external returns (address) {
        bytes32 parameterHash = keccak256(
            abi.encode(
                _targetVault,
                _asset,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                _tokenizedStrategyAddress
            )
        );

        bytes memory bytecode = abi.encodePacked(
            type(GenericERC4626Strategy).creationCode,
            abi.encode(
                _targetVault,
                _asset,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                _tokenizedStrategyAddress
            )
        );

        address strategyAddress = _deployStrategy(bytecode, parameterHash);
        _recordStrategy(_name, _donationAddress, strategyAddress);

        emit StrategyDeploy(msg.sender, _targetVault, _donationAddress, strategyAddress, _name);
        return strategyAddress;
    }
}