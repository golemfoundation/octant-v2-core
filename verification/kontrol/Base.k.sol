// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { TestPlus } from "solady-test/utils/TestPlus.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";

contract BaseTest is Test, TestPlus {
    struct testTemps {
        address owner;
        uint256 ownerPrivateKey;
        address safe;
        address module;
    }

    Safe safe;

    address[] public owners;

    function _configure() internal {
        safe = new Safe();
        // So we don't need to setup a proxy for Safe
        vm.store(address(safe), bytes32(uint256(4)), bytes32(0));
        //proxyFactory = address(new SafeProxyFactory());
    }

    /// @notice Helper function to setup test environment with a Safe and Module
    /// @dev Creates a new Safe with a single owner and deploys a module through the factory
    /// @param moduleImplementation The implementation address of the module to deploy
    function _testTemps(address moduleImplementation) internal {
        address owner = makeAddr("OWNER");
        owners = [owner];
        // Deploy a new Safe Multisig using the Proxy Factory
        //SafeProxyFactory factory = SafeProxyFactory(proxyFactory);
        safe.setup(owners, 1, address(0), "0x00", address(0), address(0), 0, payable(address(0)));

        vm.prank(address(safe));
        safe.enableModule(moduleImplementation);

        ISafe(address(safe)).getModulesPaginated(address(0x1), 1);
    }
}
