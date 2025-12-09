// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { BaseStrategyFactory } from "../BaseStrategyFactory.sol";
import { RocketPoolStrategy } from "src/strategies/yieldSkimming/RocketPoolStrategy.sol";

/**
 * @title RocketPoolStrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying RocketPool yield skimming strategies
 * @dev Inherits deterministic deployment from BaseStrategyFactory
 */
contract RocketPoolStrategyFactory is BaseStrategyFactory {
    /// @notice rETH token address on mainnet
    address public constant R_ETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    /// @notice Emitted when a new RocketPoolStrategy is deployed
    /// @param deployer Address that deployed the strategy
    /// @param donationAddress Dragon router address that receives profit shares
    /// @param strategyAddress Deployed strategy address
    /// @param vaultTokenName Strategy share token name
    event StrategyDeploy(
        address indexed deployer,
        address indexed donationAddress,
        address indexed strategyAddress,
        string vaultTokenName
    );

    /**
     * @notice Deploys a new RocketPool strategy for the Yield Skimming Vault
     * @dev Uses deterministic deployment based on strategy parameters to prevent duplicates
     * @param _name Strategy share token name
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed RocketPoolStrategy address
     */
    function createStrategy(
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    ) external returns (address strategyAddress) {
        // Generate deterministic hash from all strategy parameters
        bytes32 parameterHash = keccak256(
            abi.encode(
                R_ETH,
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
            type(RocketPoolStrategy).creationCode,
            abi.encode(
                R_ETH,
                _name,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                _tokenizedStrategyAddress
            )
        );

        // Deploy using parameter hash to prevent duplicates
        strategyAddress = _deployStrategy(bytecode, parameterHash);

        emit StrategyDeploy(msg.sender, _donationAddress, strategyAddress, _name);

        // Record the deployment
        _recordStrategy(_name, _donationAddress, strategyAddress);
    }
}
