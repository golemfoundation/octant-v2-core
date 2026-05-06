// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DirectTransfer } from "src/core/DirectTransfer.sol";

/**
 * @title DeployDirectTransfer
 * @notice Staging deployment script for the DirectTransfer logging contract.
 * @dev DirectTransfer is stateless and has no constructor arguments — one deployment
 *      per chain serves every supported ERC20. The script always deploys a fresh
 *      instance; the printed BLOCK_NUMBER is therefore the contract's actual
 *      deployment block, safe to use as the subgraph startBlock.
 *
 *      Required env: PRIVATE_KEY
 */
contract DeployDirectTransfer is Script {
    /// @notice The deployed DirectTransfer instance
    DirectTransfer public directTransfer;

    error DeploymentFailed();

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        directTransfer = new DirectTransfer();
        vm.stopBroadcast();

        address directTransferAddress = address(directTransfer);
        if (directTransferAddress == address(0)) revert DeploymentFailed();

        console2.log("\nDirectTransfer Deployment");
        console2.log("------------------");
        console2.log("BLOCK_NUMBER=", vm.toString(block.number));
        console2.log("DIRECT_TRANSFER_ADDRESS=", vm.toString(directTransferAddress));
        console2.log("------------------");
        console2.log("Copy the two values above into octant-v2-subgraph/subgraphs/regen/networks.json");
        console2.log("under the DirectTransfer entry (address + startBlock).");
    }
}
