// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0;

import { ISafe } from "./interfaces/Safe.sol";
import { IModuleProxyFactory } from "./interfaces/IModuleProxyFactory.sol";

/**
 * @title ModuleProxyFactory
 * @author Gnosis Guild; modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @custom:origin https://github.com/gnosisguild/zodiac-core/blob/master/contracts/factory/ModuleProxyFactory.sol
 * @notice Factory for deploying Zodiac modules as minimal proxies with CREATE2
 * @dev EIP-1167 minimal proxy pattern for gas-efficient module deployments
 *
 *      CORE FUNCTIONALITY:
 *      - Deploys DragonRouter, SplitChecker, and generic modules as proxies
 *      - CREATE2 for deterministic addresses based on init params + salt
 *      - Single implementation serves all proxies (gas savings)
 *
 *      DEPLOYED COMPONENTS:
 *      - DragonRouter: Yield distribution router (multiple per factory)
 *      - SplitChecker: Revenue split validator (one shared instance)
 *      - Generic modules: Via deployModule() for Safe extensions
 *
 *      DETERMINISTIC ADDRESSES:
 *      - Salt = keccak256(keccak256(initializer), saltNonce)
 *      - Predictable via calculateProxyAddress()
 *      - Same params + salt = same address (prevents duplicates)
 *
 *      INITIALIZATION FLOW:
 *      1. Create proxy via CREATE2
 *      2. Call setUp() on proxy with init params
 *      3. Proxy delegates to implementation for all logic
 *
 *      IMMUTABLE REFERENCES:
 *      - GOVERNANCE: Main protocol governance
 *      - REGEN_GOVERNANCE: Regenerative finance governance
 *      - SPLIT_CHECKER: Shared split validator
 *      - METAPOOL: Meta-pool for yield aggregation
 *      - DRAGON_ROUTER_IMPLEMENTATION: DragonRouter logic contract
 *
 * @custom:security Proxy pattern requires careful initialization
 * @custom:security SplitChecker deployed in constructor (one per factory)
 */
contract ModuleProxyFactory is IModuleProxyFactory {
    /// @notice Main protocol governance address
    address public immutable GOVERNANCE;

    /// @notice Regenerative finance governance address
    address public immutable REGEN_GOVERNANCE;

    /// @notice Deployed SplitChecker proxy instance
    address public immutable SPLIT_CHECKER;

    /// @notice Meta-pool address for yield aggregation
    address public immutable METAPOOL;

    /// @notice DragonRouter implementation contract address
    address public immutable DRAGON_ROUTER_IMPLEMENTATION;

    /**
     * @notice Initializes factory with core protocol addresses
     * @dev Deploys shared SplitChecker in constructor with default limits:
     *      - maxOpexSplit: 0.5e18 (50% max to operational expenses)
     *      - minMetapoolSplit: 0.05e18 (5% min to metapool)
     * @param _governance Main governance address (cannot be zero)
     * @param _regenGovernance Regen governance address (cannot be zero)
     * @param _metapool Meta-pool address (cannot be zero)
     * @param _splitCheckerImplementation SplitChecker implementation (cannot be zero)
     * @param _dragonRouterImplementation DragonRouter implementation (cannot be zero)
     */
    constructor(
        address _governance,
        address _regenGovernance,
        address _metapool,
        address _splitCheckerImplementation,
        address _dragonRouterImplementation
    ) {
        _ensureNonzeroAddress(_governance);
        _ensureNonzeroAddress(_regenGovernance);
        _ensureNonzeroAddress(_splitCheckerImplementation);
        _ensureNonzeroAddress(_metapool);
        _ensureNonzeroAddress(_dragonRouterImplementation);
        GOVERNANCE = _governance;
        REGEN_GOVERNANCE = _regenGovernance;
        uint256 DEFAULT_MAX_OPEX_SPLIT = 0.5e18;
        uint256 DEFAULT_MIN_METAPOOL_SPLIT = 0.05e18;
        SPLIT_CHECKER = deployModule(
            _splitCheckerImplementation,
            abi.encodeWithSignature(
                "initialize(address,uint256,uint256)",
                GOVERNANCE,
                DEFAULT_MAX_OPEX_SPLIT,
                DEFAULT_MIN_METAPOOL_SPLIT
            ),
            block.timestamp
        );
        METAPOOL = _metapool;
        DRAGON_ROUTER_IMPLEMENTATION = _dragonRouterImplementation;
    }

    /// @notice Deploys a minimal proxy for the given implementation with deterministic address
    function deployModule(
        address masterCopy,
        bytes memory initializer,
        uint256 saltNonce
    ) public returns (address proxy) {
        proxy = createProxy(masterCopy, keccak256(abi.encodePacked(keccak256(initializer), saltNonce)));
        (bool success, ) = proxy.call(initializer);
        if (!success) revert FailedInitialization();

        emit ModuleProxyCreation(msg.sender, proxy, masterCopy);
    }

    /// @notice Deploys a new DragonRouter proxy with configured strategies and governance
    function deployDragonRouter(
        address owner,
        address[] memory strategies,
        address opexVault,
        uint256 saltNonce
    ) public returns (address payable) {
        _ensureNonzeroAddress(owner);
        _ensureNonzeroAddress(opexVault);
        bytes memory data = abi.encode(strategies, GOVERNANCE, REGEN_GOVERNANCE, SPLIT_CHECKER, opexVault, METAPOOL);
        bytes memory initializer = abi.encode(owner, data);

        address payable proxy = payable(
            deployModule(DRAGON_ROUTER_IMPLEMENTATION, abi.encodeWithSignature("setUp(bytes)", initializer), saltNonce)
        );

        emit DragonRouterCreation(owner, proxy, DRAGON_ROUTER_IMPLEMENTATION);
        return proxy;
    }

    /// @notice Deploys module and immediately enables it on the calling Safe
    function deployAndEnableModuleFromSafe(
        address masterCopy,
        bytes memory data,
        uint256 saltNonce
    ) public returns (address proxy) {
        proxy = deployModule(
            masterCopy,
            abi.encodeWithSignature("setUp(bytes)", abi.encode(address(this), data)),
            saltNonce
        );

        ISafe(address(this)).enableModule(proxy);
    }

    /// @notice Calculates the deterministic address of a proxy for given implementation and salt
    function calculateProxyAddress(address target, bytes32 salt) public view returns (address) {
        bytes memory deployment = abi.encodePacked(
            hex"602d8060093d393df3363d3d373d3d3d363d73",
            target,
            hex"5af43d82803e903d91602b57fd5bf3"
        );

        bytes32 deploymentHash = keccak256(deployment);
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, deploymentHash));

        return address(uint160(uint256(data)));
    }

    /// @notice Computes the deterministic address for a module given its implementation, initializer, and salt nonce
    function getModuleAddress(
        address masterCopy,
        bytes memory initializer,
        uint256 saltNonce
    ) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        return calculateProxyAddress(masterCopy, salt);
    }

    /**
     * @dev Creates minimal proxy via CREATE2
     * @param target Implementation contract address
     * @param salt CREATE2 salt for deterministic address
     * @return result Deployed proxy address
     * @custom:security Reverts if address already taken
     */
    function createProxy(address target, bytes32 salt) internal returns (address payable result) {
        _ensureNonzeroAddress(target);
        // EIP-1167 minimal proxy bytecode
        bytes memory deployment = abi.encodePacked(
            hex"602d8060093d393df3363d3d373d3d3d363d73",
            target,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := create2(0, add(deployment, 0x20), mload(deployment), salt)
        }
        if (result == address(0)) revert TakenAddress(result);
    }

    /**
     * @dev Validates address is not zero
     * @param address_ Address to validate
     * @custom:error ZeroAddress thrown if address is zero
     */
    function _ensureNonzeroAddress(address address_) internal pure {
        if (address_ == address(0)) {
            revert ZeroAddress();
        }
    }
}
