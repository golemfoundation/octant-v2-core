// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { console2 } from "forge-std/Test.sol";
import { Script } from "forge-std/Script.sol";
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";

contract DeployPaymentSplitterFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_PAYMENT_SPLITTER_FACTORY_V2");

    PaymentSplitterFactory public paymentSplitterFactory;

    function deploy() public virtual {
        run();
    }

    function run() public returns (PaymentSplitterFactory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console2.log("Deploying PaymentSplitterFactory with CREATE2...");
        console2.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy the factory using CREATE2 with salt
        paymentSplitterFactory = new PaymentSplitterFactory{ salt: DEPLOYMENT_SALT }();

        console2.log("PaymentSplitterFactory deployed at:", address(paymentSplitterFactory));

        vm.stopBroadcast();

        return paymentSplitterFactory;
    }
}
