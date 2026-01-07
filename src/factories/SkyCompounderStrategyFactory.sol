// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { BaseStrategyFactory } from "./BaseStrategyFactory.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";

/**
 * @title SkyCompounderStrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying Sky Compounder yield donating strategies
 * @dev Inherits deterministic deployment from BaseStrategyFactory
 */
contract SkyCompounderStrategyFactory is BaseStrategyFactory {
    /// @notice USDS reward address on mainnet
    address constant USDS_REWARD_ADDRESS = 0x0650CAF159C5A49f711e8169D4336ECB9b950275;

    /// @notice Emitted when a new SkyCompounderStrategy is deployed
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
     * @notice Deploys a new SkyCompounder strategy for the Yield Donating Vault
     * @dev Uses deterministic deployment based on strategy parameters to prevent duplicates
     * @param _name Strategy share token name
     * @param _symbol Strategy share token symbol
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed SkyCompounderStrategy address
     */
    function createStrategy(
        string memory _name,
        string memory _symbol,
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
                USDS_REWARD_ADDRESS,
                _name,
                _symbol,
                _management,
                _keeper,
                _emergencyAdmin,
                _donationAddress,
                _enableBurning,
                _tokenizedStrategyAddress
            )
        );

        bytes memory bytecode = abi.encodePacked(
            type(SkyCompounderStrategy).creationCode,
            abi.encode(
                USDS_REWARD_ADDRESS,
                _name,
                _symbol,
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
