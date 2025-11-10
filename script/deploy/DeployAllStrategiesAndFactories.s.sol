// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

// Strategy implementations
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

// Factory contracts
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";

/**
 * @title DeployAllStrategiesAndFactories
 * @author Golem Foundation
 * @notice Deployment script that deploys all tokenized strategies and factory contracts via Safe multisig
 * @dev Safe calls MultiSendCallOnly which makes multiple calls to CREATE2 factory for deployment
 */
contract DeployAllStrategiesAndFactories is Script, BatchScript {
    // Deployment salts for deterministic addresses (date-based: DDMMYYYY format)
    bytes32 public constant YIELD_DONATING_SALT = keccak256("OCTANT_YIELD_DONATING_STRATEGY_05112025");

    // Factory deployment salts
    bytes32 public constant MORPHO_FACTORY_SALT = keccak256("MORPHO_COMPOUNDER_FACTORY_05112025");
    bytes32 public constant SKY_FACTORY_SALT = keccak256("SKY_COMPOUNDER_FACTORY_05112025");
    bytes32 public constant PAYMENT_SPLITTER_FACTORY_SALT = keccak256("PAYMENT_SPLITTER_FACTORY_05112025");
    bytes32 public constant YEARN_V3_FACTORY_SALT = keccak256("YEARN_V3_STRATEGY_FACTORY_05112025");

    // Deployed addresses (to be logged)
    address public yieldDonatingStrategy;
    address public morphoFactory;
    address public skyFactory;
    address public paymentSplitterFactory;
    address public yearnV3Factory;

    // Safe address
    address public safe;

    function setUp() public {
        // Get Safe address from environment or prompt
        safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe == address(0)) {
            try vm.prompt("Enter Safe Address") returns (string memory res) {
                safe = vm.parseAddress(res);
            } catch {
                revert("Invalid Safe Address");
            }
        }

        console.log("Using Safe:", safe);
    }

    function run() public isBatch(safe) {
        // Calculate expected addresses
        _calculateExpectedAddresses();

        // Add all deployment transactions to the batch
        _addStrategyDeployments();
        _addFactoryDeployments();

        // Execute the batch (sends to Safe backend)
        executeBatch(true);

        // Log deployment summary
        _logDeploymentSummary();
    }

    function _calculateExpectedAddresses() internal {
        // YieldDonatingTokenizedStrategy
        bytes memory ydCreationCode = type(YieldDonatingTokenizedStrategy).creationCode;
        yieldDonatingStrategy = _computeCreate2Address(CREATE2_FACTORY, YIELD_DONATING_SALT, keccak256(ydCreationCode));

        // MorphoCompounderStrategyFactory
        bytes memory morphoCreationCode = type(MorphoCompounderStrategyFactory).creationCode;
        morphoFactory = _computeCreate2Address(CREATE2_FACTORY, MORPHO_FACTORY_SALT, keccak256(morphoCreationCode));

        // SkyCompounderStrategyFactory
        bytes memory skyCreationCode = type(SkyCompounderStrategyFactory).creationCode;
        skyFactory = _computeCreate2Address(CREATE2_FACTORY, SKY_FACTORY_SALT, keccak256(skyCreationCode));

        // PaymentSplitterFactory
        bytes memory paymentSplitterCreationCode = type(PaymentSplitterFactory).creationCode;
        paymentSplitterFactory = _computeCreate2Address(
            CREATE2_FACTORY,
            PAYMENT_SPLITTER_FACTORY_SALT,
            keccak256(paymentSplitterCreationCode)
        );

        // YearnV3StrategyFactory
        bytes memory yearnV3CreationCode = type(YearnV3StrategyFactory).creationCode;
        yearnV3Factory = _computeCreate2Address(CREATE2_FACTORY, YEARN_V3_FACTORY_SALT, keccak256(yearnV3CreationCode));
    }

    function _addStrategyDeployments() internal {
        console.log("Adding strategy deployments to batch...");

        // Deploy YieldDonatingTokenizedStrategy
        bytes memory ydDeployData = abi.encodePacked(
            YIELD_DONATING_SALT,
            type(YieldDonatingTokenizedStrategy).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, ydDeployData);
        console.log("- YieldDonatingTokenizedStrategy at:", yieldDonatingStrategy);
    }

    function _addFactoryDeployments() internal {
        console.log("Adding factory deployments to batch...");

        // Deploy MorphoCompounderStrategyFactory
        // CREATE2 factory expects: salt (32 bytes) + bytecode
        bytes memory morphoDeployData = abi.encodePacked(
            MORPHO_FACTORY_SALT,
            type(MorphoCompounderStrategyFactory).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, morphoDeployData);
        console.log("- MorphoCompounderStrategyFactory at:", morphoFactory);

        // Deploy SkyCompounderStrategyFactory
        bytes memory skyDeployData = abi.encodePacked(
            SKY_FACTORY_SALT,
            type(SkyCompounderStrategyFactory).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, skyDeployData);
        console.log("- SkyCompounderStrategyFactory at:", skyFactory);

        // Deploy PaymentSplitterFactory
        bytes memory paymentSplitterDeployData = abi.encodePacked(
            PAYMENT_SPLITTER_FACTORY_SALT,
            type(PaymentSplitterFactory).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, paymentSplitterDeployData);
        console.log("- PaymentSplitterFactory at:", paymentSplitterFactory);

        // Deploy YearnV3StrategyFactory
        bytes memory yearnV3DeployData = abi.encodePacked(
            YEARN_V3_FACTORY_SALT,
            type(YearnV3StrategyFactory).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, yearnV3DeployData);
        console.log("- YearnV3StrategyFactory at:", yearnV3Factory);
    }

    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("\nTokenized Strategies:");
        console.log("- YieldDonatingTokenizedStrategy:", yieldDonatingStrategy);
        console.log("\nFactory Contracts:");
        console.log("- MorphoCompounderStrategyFactory:", morphoFactory);
        console.log("- SkyCompounderStrategyFactory:", skyFactory);
        console.log("- PaymentSplitterFactory:", paymentSplitterFactory);
        console.log("- YearnV3StrategyFactory:", yearnV3Factory);
        console.log("\nBatch transaction created:");
        console.log("- Safe will call execTransaction once");
        console.log("- execTransaction calls MultiSendCallOnly");
        console.log("- MultiSendCallOnly makes 5 calls to CREATE2 factory");
        console.log("- CREATE2 factory deploys each contract deterministically");
        console.log("\nTransaction sent to Safe for signing.");
        console.log("========================\n");
    }

    /**
     * @notice Helper function to compute CREATE2 address
     * @param _deployer Address that will deploy the contract
     * @param _salt Salt used for deployment
     * @param _initCodeHash Hash of the contract's creation code
     * @return Expected deployment address
     */
    function _computeCreate2Address(
        address _deployer,
        bytes32 _salt,
        bytes32 _initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", _deployer, _salt, _initCodeHash)))));
    }
}
