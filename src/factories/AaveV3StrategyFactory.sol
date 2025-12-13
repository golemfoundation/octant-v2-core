// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

/**
 * @title AaveV3StrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying Aave V3 yield donating strategies
 * @dev Uses CREATE2 for deterministic deployments; records deployments via BaseStrategyFactory
 *
 *      AAVE V3 INTEGRATION:
 *      This factory deploys strategies that deposit into Aave V3 lending pools
 *      to earn yield through interest accrual on supplied assets.
 */
contract AaveV3StrategyFactory is BaseStrategyFactory {
    /// @notice Aave V3 AddressesProvider on Ethereum mainnet
    address public constant AAVE_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    /// @notice aUSDC V3 token address on Ethereum mainnet
    address public constant AUSDC_V3 = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    /// @notice USDC token address (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 on Ethereum mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Emitted on successful strategy deployment
    /// @param deployer Transaction sender performing deployment
    /// @param donationAddress Donation destination address for strategy
    /// @param strategyAddress Deployed strategy address
    /// @param vaultTokenName Vault token name associated with strategy
    event StrategyDeploy(
        address indexed deployer,
        address indexed donationAddress,
        address indexed strategyAddress,
        string vaultTokenName
    );

    /**
     * @notice Deploy a new AaveV3 strategy
     * @dev Deterministic salt derived from all parameters to avoid duplicates
     * @param _name Strategy share token name
     * @param _management Management address (can update params)
     * @param _keeper Keeper address (calls report)
     * @param _emergencyAdmin Emergency admin address
     * @param _donationAddress Dragon router address (receives profit shares)
     * @param _enableBurning True to enable burning shares during loss protection
     * @param _tokenizedStrategyAddress TokenizedStrategy implementation address
     * @return strategyAddress Deployed AaveV3Strategy address
     */
    function createStrategy(
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
                AAVE_ADDRESSES_PROVIDER,
                AUSDC_V3,
                USDC,
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
            type(AaveV3Strategy).creationCode,
            abi.encode(
                AAVE_ADDRESSES_PROVIDER,
                AUSDC_V3,
                USDC,
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

        emit StrategyDeploy(msg.sender, _donationAddress, strategyAddress, _name);
        return strategyAddress;
    }
}
