// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { BaseStrategyFactory } from "./BaseStrategyFactory.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";

/**
 * @title LidoStrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying LidoStrategy instances with deterministic addresses
 * @dev Uses CREATE2 for predictable deployment addresses based on parameters
 *      \n *      DEPLOYMENT:\n *      - Hardcoded to wstETH on Ethereum mainnet\n *      - Parameters hashed to prevent duplicate deployments\n *      - Each deployer can create multiple strategies with different params\n *      \n *      GAS COST:\n *      - Strategy deployment: ~3-4M gas\n *      - Includes full contract deployment (not a proxy)\n */
contract LidoStrategyFactory is BaseStrategyFactory {
    /// @notice wstETH token address on Ethereum mainnet
    /// @dev Lido's wrapped staked ETH (non-rebasing wrapper for stETH)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Emitted when a new LidoStrategy is deployed
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
     * @notice Deploys a new LidoStrategy instance
     * @dev Uses CREATE2 for deterministic deployment
     *
     *      PARAMETERS HASHED FOR SALT:
     *      All parameters combined determine unique address
     *      Same parameters = same address (prevents duplicates)
     *
     *      PROCESS:
     *      1. Hash all parameters for salt generation
     *      2. Encode bytecode with constructor args
     *      3. Deploy via CREATE2 (reverts if duplicate)
     *      4. Emit StrategyDeploy event
     *      5. Record deployment for tracking
     *
     * @param _name Strategy share token name
     * @param _symbol Strategy share token symbol
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable dragon loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed LidoStrategy address
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
                WSTETH,
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
            type(LidoStrategy).creationCode,
            abi.encode(
                WSTETH,
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
