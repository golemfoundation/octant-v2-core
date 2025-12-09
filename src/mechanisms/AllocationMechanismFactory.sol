// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { TokenizedAllocationMechanism } from "./TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "./mechanism/QuadraticVotingMechanism.sol";
import { AllocationConfig } from "./BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title Allocation Mechanism Factory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying voting/allocation mechanisms with shared implementation
 * @dev Follows Yearn V3 proxy pattern: lightweight proxies + shared logic
 *
 *      ARCHITECTURE:
 *      - One TokenizedAllocationMechanism implementation (shared)
 *      - Multiple mechanism proxies (QuadraticVotingMechanism, etc.)
 *      - Each proxy delegates to shared implementation
 *      - Custom behavior via hooks in proxy contracts
 *
 *      DEPLOYMENT:
 *      - CREATE2 for deterministic addresses
 *      - Parameters hashed for uniqueness
 *      - Duplicate prevention via address check
 *      - Registry tracking of all deployments
 *
 * @custom:security CREATE2 salt includes all parameters to prevent collisions
 * @custom:security Duplicate deployments revert to prevent parameter confusion
 */
contract AllocationMechanismFactory {
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Shared TokenizedAllocationMechanism implementation address
    /// @dev All deployed mechanisms delegate to this for common logic
    address public immutable tokenizedAllocationImplementation;

    /// @notice Array of all deployed mechanism addresses
    /// @dev Used for enumeration and tracking
    address[] public deployedMechanisms;

    /// @notice Mapping to quickly check if address is a deployed mechanism
    /// @dev Set to true when mechanism is deployed
    mapping(address => bool) public isMechanism;

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a new allocation mechanism is deployed
     * @param mechanism Address of the deployed mechanism contract
     * @param asset Address of the ERC20 token used for voting
     * @param name Human-readable name of the mechanism
     * @param symbol Token symbol for the mechanism shares
     * @param deployer Address that deployed the mechanism (becomes owner)
     */
    event AllocationMechanismDeployed(
        address indexed mechanism,
        address indexed asset,
        string name,
        string symbol,
        address indexed deployer
    );

    // ============================================
    // ERRORS
    // ============================================

    error MechanismAlreadyExists(address existingMechanism);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploys the factory and shared TokenizedAllocationMechanism implementation
     * @dev Implementation is deployed once and shared by all proxy mechanisms
     *      This saves significant gas on subsequent deployments (~300k → ~50k gas)
     */
    constructor() {
        // Deploy the shared TokenizedAllocationMechanism implementation
        tokenizedAllocationImplementation = address(new TokenizedAllocationMechanism());
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Predict the deployment address of a QuadraticVotingMechanism
     * @dev Uses CREATE2 address computation with same salt generation as deployment
     *      Address prediction is deterministic and guaranteed to match deployment
     * @param _config Configuration struct containing all mechanism parameters
     * @param _alphaNumerator Alpha numerator for ProperQF weighting (dimensionless ratio, 0 to _alphaDenominator)
     * @param _alphaDenominator Alpha denominator for ProperQF weighting (dimensionless ratio)
     * @param deployer Address that will deploy the mechanism (used in salt)
     * @return predicted Deterministic CREATE2 address where mechanism will be deployed
     */
    function predictMechanismAddress(
        AllocationConfig memory _config,
        uint256 _alphaNumerator,
        uint256 _alphaDenominator,
        address deployer
    ) public view returns (address predicted) {
        // Set the deployer as the owner to match deployment logic
        _config.owner = deployer;

        // Generate deterministic salt from parameters
        bytes32 salt = keccak256(
            abi.encode(
                tokenizedAllocationImplementation,
                _config.asset,
                _config.name,
                _config.symbol,
                _config.votingDelay,
                _config.votingPeriod,
                _config.quorumShares,
                _config.timelockDelay,
                _config.gracePeriod,
                _alphaNumerator,
                _alphaDenominator,
                deployer
            )
        );

        // Need to build the same bytecode that will be used in deployment
        bytes memory bytecode = abi.encodePacked(
            type(QuadraticVotingMechanism).creationCode,
            abi.encode(tokenizedAllocationImplementation, _config, _alphaNumerator, _alphaDenominator)
        );

        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Deploy a new QuadraticVotingMechanism with deterministic address
     * @dev Uses CREATE2 for deterministic deployment address
     *      Reverts if mechanism with same parameters already exists
     *
     *      DEPLOYMENT STEPS:
     *      1. Set msg.sender as mechanism owner
     *      2. Generate deterministic salt from all parameters
     *      3. Compute expected address via CREATE2
     *      4. Check for existing deployment (revert if exists)
     *      5. Deploy via CREATE2
     *      6. Track in registry
     *      7. Emit deployment event
     * @param _config Configuration struct containing mechanism parameters
     * @param _alphaNumerator Alpha numerator for ProperQF weighting (dimensionless ratio, 0 to _alphaDenominator)
     * @param _alphaDenominator Alpha denominator for ProperQF weighting (dimensionless ratio)
     * @return mechanism Address of the deployed QuadraticVotingMechanism contract
     * @custom:security Caller becomes mechanism owner with admin privileges
     * @custom:security CREATE2 ensures same parameters always deploy to same address
     */
    function deployQuadraticVotingMechanism(
        AllocationConfig memory _config,
        uint256 _alphaNumerator,
        uint256 _alphaDenominator
    ) external returns (address mechanism) {
        // Set the deployer as the owner
        _config.owner = msg.sender;

        // Generate deterministic salt from parameters
        bytes32 salt = keccak256(
            abi.encode(
                tokenizedAllocationImplementation,
                _config.asset,
                _config.name,
                _config.symbol,
                _config.votingDelay,
                _config.votingPeriod,
                _config.quorumShares,
                _config.timelockDelay,
                _config.gracePeriod,
                _alphaNumerator,
                _alphaDenominator,
                msg.sender
            )
        );

        // Prepare creation bytecode
        bytes memory bytecode = abi.encodePacked(
            type(QuadraticVotingMechanism).creationCode,
            abi.encode(tokenizedAllocationImplementation, _config, _alphaNumerator, _alphaDenominator)
        );

        // Check if mechanism already exists
        address predictedAddress = Create2.computeAddress(salt, keccak256(bytecode));

        if (predictedAddress.code.length > 0) {
            revert MechanismAlreadyExists(predictedAddress);
        }

        // Deploy new QuadraticVotingMechanism using CREATE2
        mechanism = Create2.deploy(0, salt, bytecode);

        // Track deployment
        deployedMechanisms.push(mechanism);
        isMechanism[mechanism] = true;

        emit AllocationMechanismDeployed(mechanism, address(_config.asset), _config.name, _config.symbol, msg.sender);

        return mechanism;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the total number of deployed mechanisms
     * @return count Number of mechanisms deployed by this factory
     * @dev Used for enumeration and pagination
     */
    function getDeployedCount() external view returns (uint256 count) {
        return deployedMechanisms.length;
    }

    /**
     * @notice Get all deployed mechanism addresses
     * @return mechanisms Array of all deployed mechanism addresses
     * @dev May be expensive for large arrays; consider pagination via getDeployedMechanism()
     */
    function getAllDeployedMechanisms() external view returns (address[] memory mechanisms) {
        return deployedMechanisms;
    }

    /**
     * @notice Get a specific deployed mechanism by array index
     * @param index Zero-based index in the deployedMechanisms array
     * @return mechanism Address of the mechanism at given index
     * @dev Reverts if index out of bounds
     * @dev Use with getDeployedCount() for pagination
     */
    function getDeployedMechanism(uint256 index) external view returns (address mechanism) {
        require(index < deployedMechanisms.length, "Index out of bounds");
        return deployedMechanisms[index];
    }
}
