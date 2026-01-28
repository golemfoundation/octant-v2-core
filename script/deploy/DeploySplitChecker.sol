// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";

/**
 * @title DeploySplitChecker
 * @notice Script to deploy the base implementation of SplitChecker
 * @dev Uses OpenZeppelin Upgrades plugin for transparent proxy deployment
 */
contract DeploySplitChecker is Test {
    /// @notice The deployed SplitChecker implementation
    SplitChecker public splitCheckerSingleton;
    /// @notice The deployed SplitChecker proxy
    SplitChecker public splitCheckerProxy;

    /// @notice Default configuration values
    uint256 constant DEFAULT_MAX_OPEX_SPLIT = 0.5e18;
    uint256 constant DEFAULT_MIN_METAPOOL_SPLIT = 0.05e18;

    function deploy() public virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        splitCheckerSingleton = new SplitChecker();

        // Deploy ProxyAdmin for DragonRouter proxy
        ProxyAdmin proxyAdmin = new ProxyAdmin(msg.sender);

        // Deploy TransparentProxy for DragonRouter
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(splitCheckerSingleton),
            address(proxyAdmin),
            abi.encodeCall(
                SplitChecker.initialize,
                (
                    _getConfiguredAddress("GOVERNANCE"),
                    _getConfiguredUint("MAX_OPEX_SPLIT", DEFAULT_MAX_OPEX_SPLIT),
                    _getConfiguredUint("MIN_METAPOOL_SPLIT", DEFAULT_MIN_METAPOOL_SPLIT)
                )
            )
        );

        splitCheckerProxy = SplitChecker(payable(address(proxy)));

        vm.stopBroadcast();

        // Log deployment info
        // console2.log("SplitChecker Implementation deployed at:", address(splitCheckerSingleton));
        // console2.log("SplitChecker Proxy deployed at:", address(splitCheckerProxy));
        // console2.log("\nConfiguration:");
        // console2.log("- Governance:", _getConfiguredAddress("GOVERNANCE"));
        // console2.log("- Max Opex Split:", _getConfiguredUint("MAX_OPEX_SPLIT", DEFAULT_MAX_OPEX_SPLIT));
        // console2.log("- Min Metapool Split:", _getConfiguredUint("MIN_METAPOOL_SPLIT", DEFAULT_MIN_METAPOOL_SPLIT));
    }

    /**
     * @dev Helper to get address from environment with fallback to msg.sender
     */
    function _getConfiguredAddress(string memory key) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return msg.sender;
        }
    }

    /**
     * @dev Helper to get uint from environment with fallback to default value
     */
    function _getConfiguredUint(string memory key, uint256 defaultValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return defaultValue;
        }
    }
}
