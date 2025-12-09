// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { YearnV3Strategy } from "src/strategies/yieldDonating/YearnV3Strategy.sol";

/**
 * @title YearnV3StrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying Yearn v3 yield donating strategies
 * @dev Deterministic deployment and per-strategy metadata storage
 */
contract YearnV3StrategyFactory is BaseStrategyFactory {
    /**
     * @dev Extended struct to store YearnV3Strategy-specific information
     * @param management Management address responsible for the strategy
     */
    struct YearnV3StrategyInfo {
        address management;
    }

    /// @dev Mapping to store YearnV3Strategy-specific information
    /// Maps strategy address to YearnV3StrategyInfo
    mapping(address => YearnV3StrategyInfo) public yearnV3StrategyInfo;

    /// @notice Emitted on successful strategy deployment
    /// @param management Management address for the deployed strategy
    /// @param donationAddress Donation destination address for strategy
    /// @param strategyAddress Deployed strategy address
    /// @param vaultTokenName Vault token name associated with strategy
    event StrategyDeploy(
        address indexed management,
        address indexed donationAddress,
        address indexed strategyAddress,
        string vaultTokenName
    );

    /**
     * @notice Deploy a new YearnV3 strategy
     * @dev Deterministic salt derived from all parameters to avoid duplicates
     * @param _yearnVault Yearn v3 vault address to compound into
     * @param _asset Underlying asset address
     * @param _name Strategy share token name
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed YearnV3Strategy address
     */
    function createStrategy(
        address _yearnVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    ) external returns (address) {
        // Generate parameter hash from all inputs
        bytes32 parameterHash = keccak256(
            abi.encode(
                _yearnVault,
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

        // Prepare bytecode for deployment
        bytes memory bytecode = abi.encodePacked(
            type(YearnV3Strategy).creationCode,
            abi.encode(
                _yearnVault,
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

        // Deploy strategy using base factory method
        address strategyAddress = _deployStrategy(bytecode, parameterHash);

        // Record strategy in base factory
        _recordStrategy(_name, _donationAddress, strategyAddress);

        // Store YearnV3-specific information
        yearnV3StrategyInfo[strategyAddress] = YearnV3StrategyInfo({ management: _management });

        emit StrategyDeploy(_management, _donationAddress, strategyAddress, _name);
        return strategyAddress;
    }
}
