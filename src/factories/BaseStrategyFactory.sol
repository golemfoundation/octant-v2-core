// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title BaseStrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Base contract for strategy factories with deterministic deployment
 * @dev Uses CREATE2 with parameter-based hashing to prevent duplicate deployments
 *
 * Security Considerations:
 * - Strategy parameters are hashed to create a unique salt
 * - Same parameters always result in the same deployment address
 * - Duplicate strategy deployments are automatically prevented
 * - Addresses are deterministic and predictable based on parameters
 */
abstract contract BaseStrategyFactory {
    /**
     * @dev Struct to store information about a strategy
     * @param deployerAddress Deployer who created the strategy
     * @param timestamp Timestamp when the strategy was created (seconds)
     * @param vaultTokenName Name of the vault token associated with the strategy
     * @param donationAddress Address where donations from the strategy will be sent
     */
    struct StrategyInfo {
        address deployerAddress;
        uint256 timestamp;
        string vaultTokenName;
        address donationAddress;
    }

    /// @dev Mapping from deployer address to their deployed strategies
    /// Used for tracking deployed strategies
    mapping(address => StrategyInfo[]) public strategies;

    // Custom errors
    error StrategyAlreadyExists(address existingStrategy);
    error InvalidVault(address provided, address expected);
    error InvalidAsset(address provided, address expected);

    // Note: Child factories should declare and emit their own `StrategyDeploy` event for compatibility.

    /**
     * @notice Compute the deterministic address where a strategy will be deployed
     * @dev Must be implemented by child factories using their own bytecode
     * @param _vault Vault address (e.g., Yearn vault, or factory constant for hardcoded vaults)
     * @param _asset Underlying asset address (or factory constant for hardcoded assets)
     * @param _name Strategy share token name
     * @param _symbol Strategy share token symbol
     * @param _management Management address
     * @param _keeper Keeper address
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Donation address
     * @param _enableBurning Enable burning flag
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation
     * @param _deployer Address that will deploy the strategy
     * @return Predicted strategy address
     */
    function computeStrategyAddress(
        address _vault,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress,
        address _deployer
    ) public view virtual returns (address);

    /**
     * @dev Internal helper to predict deterministic deployment address
     * @dev Single source of truth for salt computation - used by child factories' computeStrategyAddress
     * @param _parameterHash Hash of all strategy parameters
     * @param _deployer Deployer address
     * @param _bytecode Deployment bytecode (including constructor args)
     * @return Predicted contract address
     */
    function _predictStrategyAddress(
        bytes32 _parameterHash,
        address _deployer,
        bytes memory _bytecode
    ) internal view returns (address) {
        bytes32 finalSalt = keccak256(abi.encodePacked(_parameterHash, _deployer));
        return Create2.computeAddress(finalSalt, keccak256(_bytecode));
    }

    /**
     * @dev Internal function to deploy strategy using CREATE2
     * @param _bytecode Deployment bytecode including constructor args
     * @param _parameterHash Hash of all strategy parameters for deterministic deployment
     * @return strategyAddress Deployed strategy address
     */
    function _deployStrategy(
        bytes memory _bytecode,
        bytes32 _parameterHash
    ) internal returns (address strategyAddress) {
        bytes32 finalSalt = keccak256(abi.encodePacked(_parameterHash, msg.sender));

        // Check if strategy would be deployed to an existing address
        address predictedAddress = _predictStrategyAddress(_parameterHash, msg.sender, _bytecode);

        if (predictedAddress.code.length > 0) {
            revert StrategyAlreadyExists(predictedAddress);
        }

        strategyAddress = Create2.deploy(0, finalSalt, _bytecode);
    }

    /**
     * @dev Internal function to record strategy deployment
     * @param _name Strategy name
     * @param _donationAddress Donation address
     * @param _strategyAddress Deployed strategy address
     */
    function _recordStrategy(string memory _name, address _donationAddress, address _strategyAddress) internal {
        // Silence unused parameter warning
        _strategyAddress;
        StrategyInfo memory strategyInfo = StrategyInfo({
            deployerAddress: msg.sender,
            timestamp: block.timestamp,
            vaultTokenName: _name,
            donationAddress: _donationAddress
        });

        strategies[msg.sender].push(strategyInfo);
    }

    /**
     * @notice Returns all strategies deployed by a specific address
     * @dev Get all strategies deployed by a specific address
     * @param deployer Deployer address
     * @return Array of StrategyInfo for all strategies deployed by the address
     */
    function getStrategiesByDeployer(address deployer) external view returns (StrategyInfo[] memory) {
        return strategies[deployer];
    }
}
