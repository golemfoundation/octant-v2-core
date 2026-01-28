// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.18;

/**
 * @title IModuleProxyFactory
 * @author Gnosis Guild; modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for deploying zodiac module proxies with CREATE2
 * @dev Defines deterministic deployment for dragon router and generic modules
 * @custom:origin https://github.com/gnosisguild/zodiac/blob/master/contracts/factory/ModuleProxyFactory.sol
 */
interface IModuleProxyFactory {
    /// @notice Emitted when an arbitrary proxy is created
    /// @param deployer Address that deployed the proxy
    /// @param proxy Deployed proxy address
    /// @param masterCopy Master copy (implementation) address
    event ModuleProxyCreation(address indexed deployer, address indexed proxy, address indexed masterCopy);

    /// @notice Emitted when a dragon router is created
    /// @param owner Owner of the dragon router
    /// @param proxy Deployed dragon router proxy address
    /// @param masterCopy Master copy (implementation) address
    event DragonRouterCreation(address indexed owner, address indexed proxy, address indexed masterCopy);

    error ZeroAddress();
    error TakenAddress(address address_);
    error FailedInitialization();

    /**
     * @notice Deploy a module proxy using CREATE2
     * @param masterCopy Master copy (implementation) address
     * @param initializer Initialization calldata
     * @param saltNonce Salt nonce for deterministic address
     * @return proxy Deployed proxy address
     */
    function deployModule(
        address masterCopy,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);

    /**
     * @notice Deploy a module proxy from a Safe and enable it
     * @param masterCopy Master copy (implementation) address
     * @param data Initialization calldata
     * @param saltNonce Salt nonce for deterministic address
     * @return proxy Deployed proxy address
     */
    function deployAndEnableModuleFromSafe(
        address masterCopy,
        bytes memory data,
        uint256 saltNonce
    ) external returns (address proxy);

    /**
     * @notice Deploy a dragon router using CREATE2
     * @param owner Owner of the dragon router
     * @param strategies Initial strategy addresses
     * @param opexVault Opex vault address
     * @param saltNonce Salt nonce for deterministic address
     * @return router Deployed dragon router address
     */
    function deployDragonRouter(
        address owner,
        address[] memory strategies,
        address opexVault,
        uint256 saltNonce
    ) external returns (address payable router);

    /**
     * @notice Calculate deterministic proxy address from target and salt
     * @param target Target (master copy) address
     * @param salt CREATE2 salt
     * @return proxy Predicted proxy address
     */
    function calculateProxyAddress(address target, bytes32 salt) external view returns (address proxy);

    /**
     * @notice Calculate deterministic proxy address from masterCopy, initializer, and saltNonce
     * @param masterCopy Master copy (implementation) address
     * @param initializer Initialization calldata
     * @param saltNonce Salt nonce for deterministic address
     * @return proxy Predicted proxy address
     */
    function getModuleAddress(
        address masterCopy,
        bytes memory initializer,
        uint256 saltNonce
    ) external view returns (address proxy);
}
