// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

/**
 * @title BaseERC4626StrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract base factory for ERC4626-based yield donating strategies
 * @dev Uses CREATE2 for deterministic deployments; records deployments via BaseStrategyFactory
 *
 *      This factory provides shared logic for deploying strategies that deposit into ERC4626 vaults.
 *      Child factories must implement _getCreationCode() to provide the specific strategy bytecode.
 */
abstract contract BaseERC4626StrategyFactory is BaseStrategyFactory {
    /// @notice Parameters for strategy creation
    struct CreateStrategyParams {
        address targetVault;
        address asset;
        string name;
        string symbol;
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        bool enableBurning;
        address tokenizedStrategyAddress;
    }

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
     * @notice Deploy a new ERC4626-based strategy
     * @dev Deterministic salt derived from all parameters to avoid duplicates
     * @param _targetVault ERC4626 vault address to deposit into
     * @param _asset Underlying asset address (must match vault's asset)
     * @param _name Strategy share token name
     * @param _symbol Strategy share token symbol
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed strategy address
     */
    function createStrategy(
        address _targetVault,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    ) external returns (address strategyAddress) {
        CreateStrategyParams memory params = CreateStrategyParams({
            targetVault: _targetVault,
            asset: _asset,
            name: _name,
            symbol: _symbol,
            management: _management,
            keeper: _keeper,
            emergencyAdmin: _emergencyAdmin,
            donationAddress: _donationAddress,
            enableBurning: _enableBurning,
            tokenizedStrategyAddress: _tokenizedStrategyAddress
        });

        strategyAddress = _createStrategyInternal(params);
    }

    /**
     * @dev Returns the creation code for the strategy contract
     * @return The bytecode of the strategy contract (without constructor args)
     */
    function _getCreationCode() internal pure virtual returns (bytes memory);

    /// @inheritdoc BaseStrategyFactory
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
    ) public view override returns (address) {
        bytes memory constructorArgs = abi.encode(
            _vault,
            _asset,
            _name,
            _symbol,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        );

        bytes32 parameterHash = keccak256(constructorArgs);
        bytes memory bytecode = abi.encodePacked(_getCreationCode(), constructorArgs);

        return _predictStrategyAddress(parameterHash, _deployer, bytecode);
    }

    /**
     * @dev Internal function to deploy strategy with given parameters
     * @param params Strategy creation parameters
     * @return strategyAddress Deployed strategy address
     */
    function _createStrategyInternal(CreateStrategyParams memory params) internal returns (address strategyAddress) {
        bytes memory constructorArgs = abi.encode(
            params.targetVault,
            params.asset,
            params.name,
            params.symbol,
            params.management,
            params.keeper,
            params.emergencyAdmin,
            params.donationAddress,
            params.enableBurning,
            params.tokenizedStrategyAddress
        );

        bytes32 parameterHash = keccak256(constructorArgs);
        bytes memory bytecode = abi.encodePacked(_getCreationCode(), constructorArgs);

        strategyAddress = _deployStrategy(bytecode, parameterHash);
        _recordStrategy(params.name, params.donationAddress, strategyAddress);

        emit StrategyDeploy(msg.sender, params.targetVault, params.donationAddress, strategyAddress, params.name);
    }
}
