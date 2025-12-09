// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IERC20, IAddressSet, IEarningPowerCalculator } from "src/regen/RegenStaker.sol";
import { AccessMode } from "src/constants.sol";

/// @title RegenStaker Factory
/// @notice Deploys RegenStaker contracts with explicit variant selection
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
///
/// @dev SECURITY: Validates deployment bytecode against pre-configured canonical hashes
///
/// @dev SECURITY ASSUMPTION: Factory deployer is trusted to provide correct canonical bytecode hashes.
///      If deployer is compromised, all future deployments could use unauthorized code.
///      This is an acceptable risk given the controlled deployment environment.
///
/// @dev TRUST BOUNDARY WARNING:
///      This factory guarantees CODE IDENTITY only, NOT parameter safety.
///
///      The factory validates that deployed bytecode matches canonical, audited code.
///      However, it does NOT validate constructor parameters, including:
///      - earningPowerCalculator: Controls reward distribution logic
///      - admin: Has full control over staker configuration
///      - Access Control: Allowsets and blocksets control access to various operations
///
///      A malicious actor can deploy a staker with canonical bytecode but inject:
///      - A malicious earning power calculator (to manipulate rewards)
///      - Themselves as admin (to change calculator post-deployment)
///      - Malicious address sets
///
/// @dev OPERATIONAL SECURITY:
///      Before funding or integrating with ANY RegenStaker instance:
///      1. Verify the earningPowerCalculator address and its code
///      2. Verify the admin is a trusted party/governance contract
///      3. Verify all address sets are legitimate
///      4. For official deployments, use published addresses from governance
///
///      The StakerDeploy event includes calculator address and codehash
///      to facilitate verification. For production use, consider requiring
///      deployments from a governance-approved strict factory that maintains an allowset of
///      acceptable calculators.
contract RegenStakerFactory {
    mapping(RegenStakerVariant => bytes32) public canonicalBytecodeHash;

    struct CreateStakerParams {
        IERC20 rewardsToken;
        IERC20 stakeToken;
        address admin;
        IAddressSet stakerAllowset;
        IAddressSet stakerBlockset;
        AccessMode stakerAccessMode;
        IAddressSet allocationMechanismAllowset;
        IEarningPowerCalculator earningPowerCalculator;
        uint256 maxBumpTip;
        uint256 minimumStakeAmount;
        uint256 rewardDuration;
    }

    enum RegenStakerVariant {
        WITHOUT_DELEGATION,
        WITH_DELEGATION
    }

    // Events
    /// @notice Emitted when a new RegenStaker is deployed
    /// @param deployer Address that called the factory
    /// @param admin Admin of the newly deployed staker
    /// @param stakerAddress Address of the deployed staker
    /// @param salt Deployment salt used
    /// @param variant Variant of staker deployed
    /// @param calculatorAddress Earning power calculator address (CRITICAL FOR VERIFICATION)
    /// @dev calculatorAddress is sufficient for verification; off-chain tools can query code directly
    event StakerDeploy(
        address indexed deployer,
        address indexed admin,
        address indexed stakerAddress,
        bytes32 salt,
        RegenStakerVariant variant,
        address calculatorAddress
    );

    // Errors
    error InvalidBytecode();
    error UnauthorizedBytecode(RegenStakerVariant variant, bytes32 providedHash, bytes32 expectedHash);

    /// @notice Initializes the factory with canonical bytecode hashes for both variants
    /// @param regenStakerBytecodeHash Canonical hash for WITH_DELEGATION variant
    /// @param noDelegationBytecodeHash Canonical hash for WITHOUT_DELEGATION variant
    constructor(bytes32 regenStakerBytecodeHash, bytes32 noDelegationBytecodeHash) {
        canonicalBytecodeHash[RegenStakerVariant.WITH_DELEGATION] = regenStakerBytecodeHash;
        canonicalBytecodeHash[RegenStakerVariant.WITHOUT_DELEGATION] = noDelegationBytecodeHash;
    }

    /// @notice Modifier to validate bytecode against canonical hash
    modifier validatedBytecode(bytes calldata code, RegenStakerVariant variant) {
        _validateBytecode(code, variant);
        _;
    }

    /// @notice Deploy RegenStaker without delegation support
    /// @param params Staker configuration parameters
    /// @param salt Deployment salt for deterministic addressing
    /// @param code Bytecode for WITHOUT_DELEGATION variant
    /// @return stakerAddress Address of deployed contract
    /// @dev WARNING: This factory validates bytecode but NOT constructor parameters.
    ///      Verify params.earningPowerCalculator, params.admin, and address sets before funding!
    function createStakerWithoutDelegation(
        CreateStakerParams calldata params,
        bytes32 salt,
        bytes calldata code
    ) external validatedBytecode(code, RegenStakerVariant.WITHOUT_DELEGATION) returns (address stakerAddress) {
        if (code.length == 0) revert InvalidBytecode();
        stakerAddress = _deployStaker(params, salt, code, RegenStakerVariant.WITHOUT_DELEGATION);
    }

    /// @notice Deploy RegenStaker with delegation support
    /// @param params Staker configuration parameters
    /// @param salt Deployment salt for deterministic addressing
    /// @param code Bytecode for WITH_DELEGATION variant
    /// @return stakerAddress Address of deployed contract
    /// @dev WARNING: This factory validates bytecode but NOT constructor parameters.
    ///      Verify params.earningPowerCalculator, params.admin, and address sets before funding!
    function createStakerWithDelegation(
        CreateStakerParams calldata params,
        bytes32 salt,
        bytes calldata code
    ) external validatedBytecode(code, RegenStakerVariant.WITH_DELEGATION) returns (address stakerAddress) {
        if (code.length == 0) revert InvalidBytecode();
        stakerAddress = _deployStaker(params, salt, code, RegenStakerVariant.WITH_DELEGATION);
    }

    /// @notice Predict deterministic deployment address
    /// @param salt Deployment salt
    /// @param deployer Address that will deploy
    /// @param bytecode Deployment bytecode (including constructor args)
    /// @return Predicted contract address
    function predictStakerAddress(
        bytes32 salt,
        address deployer,
        bytes memory bytecode
    ) external view returns (address) {
        bytes32 finalSalt = keccak256(abi.encode(salt, deployer));
        return Create2.computeAddress(finalSalt, keccak256(bytecode));
    }

    /// @notice Validate bytecode against canonical hash
    /// @param code Bytecode to validate
    /// @param variant RegenStaker variant this bytecode represents
    function _validateBytecode(bytes calldata code, RegenStakerVariant variant) internal view {
        if (code.length == 0) revert InvalidBytecode();

        bytes32 providedHash = keccak256(code);
        bytes32 expectedHash = canonicalBytecodeHash[variant];

        if (providedHash != expectedHash) {
            revert UnauthorizedBytecode(variant, providedHash, expectedHash);
        }
    }

    function _deployStaker(
        CreateStakerParams calldata params,
        bytes32 salt,
        bytes memory code,
        RegenStakerVariant variant
    ) internal returns (address stakerAddress) {
        bytes memory constructorParams = _encodeConstructorParams(params);

        bytes memory fullBytecode = bytes.concat(code, constructorParams);
        bytes32 finalSalt = keccak256(abi.encode(salt, msg.sender));

        stakerAddress = Create2.deploy(0, finalSalt, fullBytecode);

        // Emit deployment metadata to facilitate off-chain verification

        emit StakerDeploy(
            msg.sender,
            params.admin,
            stakerAddress,
            salt,
            variant,
            address(params.earningPowerCalculator)
        );
    }

    function _encodeConstructorParams(CreateStakerParams calldata params) internal pure returns (bytes memory) {
        return
            abi.encode(
                params.rewardsToken,
                params.stakeToken,
                params.earningPowerCalculator,
                params.maxBumpTip,
                params.admin,
                params.rewardDuration,
                params.minimumStakeAmount,
                params.stakerAllowset,
                params.stakerBlockset,
                params.stakerAccessMode,
                params.allocationMechanismAllowset
            );
    }
}
