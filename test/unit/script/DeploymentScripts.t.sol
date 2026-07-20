// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { DeployNewStrategiesAndFactories } from "script/deploy/DeployNewStrategiesAndFactories.s.sol";
import { DeployLidoStrategyFactory } from "script/deploy/DeployLidoStrategyFactory.sol";
import { DeployRocketPoolStrategyFactory } from "script/deploy/DeployRocketPoolStrategyFactory.sol";
import { DeploySparkStrategyFactory } from "script/deploy/DeploySparkStrategyFactory.sol";
import { DeployAaveV3StrategyFactory } from "script/deploy/DeployAaveV3StrategyFactory.sol";
import { DeployProtocol } from "script/deployment/staging/DeployProtocol.s.sol";
import { DeployedAddresses } from "script/helpers/DeployedAddresses.sol";

import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { AddressSetFactory } from "src/factories/AddressSetFactory.sol";
import { RegenEarningPowerCalculatorFactory } from "src/factories/RegenEarningPowerCalculatorFactory.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";

/// @notice Exposes the script's internal address precomputation so tests assert against the
///         values the script itself logs, not against a re-derivation that could drift.
contract BatchScriptHarness is DeployNewStrategiesAndFactories {
    function calculateAllAddresses() external {
        _calculateBatch1Addresses();
        _calculateBatch2Addresses();
        _calculateBatch3Addresses();
        _calculateBatch4Addresses();
    }

    /// @dev Deploys against a deliberately wrong expected address to exercise the guard.
    function queueWithWrongExpectedAddress() external {
        _addAndAssert(
            SPARK_FACTORY_SALT,
            type(SparkStrategyFactory).creationCode,
            address(0xdead),
            "SparkStrategyFactory"
        );
    }
}

/**
 * @title DeploymentScriptsTest
 * @author Golem Foundation
 * @notice Guards the deployment scripts themselves: CREATE2 salt hygiene, address
 *         predictability, and the wiring of the standalone factory scripts.
 * @dev Deployments go through Nick's CREATE2 factory exactly as the Safe batches do, so a bad
 *      salt or a reverting constructor fails here instead of in front of a Safe signer.
 *
 *      LIMIT: runs on a fresh EVM and cannot see whether a target is already occupied on the
 *      target chain. Green here does not mean a batch is proposable -- batch 1's
 *      YieldSkimmingTokenizedStrategy already exists on mainnet, so runBatch1() reverts there
 *      while these still pass. Check occupancy with `cast code` or a fork simulation.
 */
contract DeploymentScriptsTest is Test {
    /// @dev One entry per contract queued by DeployNewStrategiesAndFactories.
    struct Deployment {
        string label;
        bytes32 salt;
        bytes creationCode;
    }

    DeployNewStrategiesAndFactories internal batchScript;
    Deployment[] internal deployments;

    function setUp() public {
        batchScript = new DeployNewStrategiesAndFactories();

        // Batch 1
        _register(
            "YieldSkimmingTokenizedStrategy",
            batchScript.YIELD_SKIMMING_SALT(),
            type(YieldSkimmingTokenizedStrategy).creationCode
        );
        _register(
            "YieldDonatingTokenizedStrategy",
            batchScript.YIELD_DONATING_SALT(),
            type(YieldDonatingTokenizedStrategy).creationCode
        );
        _register(
            "PaymentSplitterFactory",
            batchScript.PAYMENT_SPLITTER_FACTORY_SALT(),
            type(PaymentSplitterFactory).creationCode
        );
        _register("LidoStrategyFactory", batchScript.LIDO_FACTORY_SALT(), type(LidoStrategyFactory).creationCode);
        _register(
            "MorphoCompounderStrategyFactory",
            batchScript.MORPHO_FACTORY_SALT(),
            type(MorphoCompounderStrategyFactory).creationCode
        );

        // Batch 2
        _register(
            "SkyCompounderStrategyFactory",
            batchScript.SKY_FACTORY_SALT(),
            type(SkyCompounderStrategyFactory).creationCode
        );
        _register(
            "YearnV3StrategyFactory",
            batchScript.YEARN_V3_FACTORY_SALT(),
            type(YearnV3StrategyFactory).creationCode
        );

        // Batch 3
        _register("AddressSetFactory", batchScript.ADDRESS_SET_FACTORY_SALT(), type(AddressSetFactory).creationCode);
        _register(
            "RegenEarningPowerCalculatorFactory",
            batchScript.EARNING_POWER_CALCULATOR_FACTORY_SALT(),
            type(RegenEarningPowerCalculatorFactory).creationCode
        );
        _register(
            "RegenStakerFactory",
            batchScript.REGEN_STAKER_FACTORY_SALT(),
            abi.encodePacked(
                type(RegenStakerFactory).creationCode,
                abi.encode(
                    keccak256(type(RegenStaker).creationCode),
                    keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode)
                )
            )
        );

        // Batch 4
        _register("SparkStrategyFactory", batchScript.SPARK_FACTORY_SALT(), type(SparkStrategyFactory).creationCode);
        _register(
            "AaveV3StrategyFactory",
            batchScript.AAVE_V3_FACTORY_SALT(),
            type(AaveV3StrategyFactory).creationCode
        );
        _register(
            "RocketPoolStrategyFactory",
            batchScript.ROCKET_POOL_FACTORY_SALT(),
            type(RocketPoolStrategyFactory).creationCode
        );
    }

    function _register(string memory label, bytes32 salt, bytes memory creationCode) internal {
        deployments.push(Deployment({ label: label, salt: salt, creationCode: creationCode }));
    }

    /// @dev Mirrors BatchScript._computeCreate2AddressViaFactory.
    function _predict(bytes32 salt, bytes memory creationCode) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", CREATE2_FACTORY, salt, keccak256(creationCode)))))
            );
    }

    /// @dev Deploys through Nick's CREATE2 factory the same way a Safe batch does.
    function _deployViaCreate2Factory(bytes32 salt, bytes memory creationCode) internal returns (address deployed) {
        (bool success, bytes memory result) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
        require(success, "CREATE2 deployment reverted");
        deployed = address(uint160(bytes20(result)));
    }

    // -----------------------------------------------------------------------
    // Salt hygiene
    // -----------------------------------------------------------------------

    /// @notice Every salt must be distinct -- a duplicate is always a copy-paste bug.
    function test_saltsAreUnique() public view {
        for (uint256 i = 0; i < deployments.length; i++) {
            for (uint256 j = i + 1; j < deployments.length; j++) {
                assertTrue(
                    deployments[i].salt != deployments[j].salt,
                    string.concat("Duplicate salt: ", deployments[i].label, " / ", deployments[j].label)
                );
            }
        }
    }

    /// @notice An address collision would make the second deployment a silent no-op.
    function test_predictedAddressesAreUnique() public view {
        address[] memory predicted = new address[](deployments.length);
        for (uint256 i = 0; i < deployments.length; i++) {
            predicted[i] = _predict(deployments[i].salt, deployments[i].creationCode);
        }

        for (uint256 i = 0; i < predicted.length; i++) {
            for (uint256 j = i + 1; j < predicted.length; j++) {
                assertTrue(
                    predicted[i] != predicted[j],
                    string.concat("Address collision: ", deployments[i].label, " / ", deployments[j].label)
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    // CREATE2 predictability -- the addresses logged for Safe signers are real
    // -----------------------------------------------------------------------

    /// @notice Catches a constructor that reverts or bytecode over the EIP-170 24KB limit.
    function test_everyBatchContractDeploysAtPredictedAddress() public {
        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];

            address predicted = _predict(d.salt, d.creationCode);
            address deployed = _deployViaCreate2Factory(d.salt, d.creationCode);

            assertEq(deployed, predicted, string.concat(d.label, ": deployed address != predicted address"));
            assertTrue(deployed.code.length > 0, string.concat(d.label, ": no code after deployment"));
        }
    }

    /// @notice Fails if a _calculateBatchNAddresses() entry uses the wrong salt or contract --
    ///         the case where signers approve a payload while reading a bogus address.
    function test_scriptPrecomputedAddressesMatchRealDeployments() public {
        BatchScriptHarness harness = new BatchScriptHarness();
        harness.calculateAllAddresses();

        address[13] memory precomputed = [
            harness.yieldSkimmingStrategy(),
            harness.yieldDonatingStrategy(),
            harness.paymentSplitterFactory(),
            harness.lidoFactory(),
            harness.morphoFactory(),
            harness.skyFactory(),
            harness.yearnV3Factory(),
            harness.addressSetFactory(),
            harness.earningPowerCalculatorFactory(),
            harness.regenStakerFactory(),
            harness.sparkFactory(),
            harness.aaveV3Factory(),
            harness.rocketPoolFactory()
        ];

        assertEq(precomputed.length, deployments.length, "Harness and test registry disagree on contract count");

        for (uint256 i = 0; i < deployments.length; i++) {
            Deployment memory d = deployments[i];
            address deployed = _deployViaCreate2Factory(d.salt, d.creationCode);

            assertEq(deployed, precomputed[i], string.concat(d.label, ": script precomputed the wrong address"));
        }
    }

    // -----------------------------------------------------------------------
    // Standalone factory scripts (the path used by staging DeployProtocol)
    // -----------------------------------------------------------------------

    function test_standaloneSparkScriptDeploysWorkingFactory() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(keccak256("deployer"))));

        DeploySparkStrategyFactory script = new DeploySparkStrategyFactory();
        address factory = script.deploy();

        // No protocol constants to check, so assert identity via runtime bytecode.
        assertEq(
            keccak256(factory.code),
            keccak256(type(SparkStrategyFactory).runtimeCode),
            "SparkStrategyFactory: runtime bytecode mismatch"
        );
        // A salted CREATE2 collides with itself; dropping the salt would silently fall back to
        // nonce-based CREATE and deploy twice. Asserting the exact address is not sound here --
        // vm.startBroadcast attributes the creation differently in a test than in a real run.
        vm.expectRevert();
        script.deploy();
    }

    function test_standaloneAaveV3ScriptDeploysWorkingFactory() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(keccak256("deployer"))));

        DeployAaveV3StrategyFactory script = new DeployAaveV3StrategyFactory();
        address factory = script.deploy();

        assertTrue(factory.code.length > 0, "AaveV3StrategyFactory: no code");
        assertEq(
            AaveV3StrategyFactory(factory).AAVE_ADDRESSES_PROVIDER(),
            0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e,
            "AaveV3StrategyFactory: wrong AAVE_ADDRESSES_PROVIDER"
        );
        // A salted CREATE2 collides with itself; dropping the salt would silently fall back to
        // nonce-based CREATE and deploy twice. Asserting the exact address is not sound here --
        // vm.startBroadcast attributes the creation differently in a test than in a real run.
        vm.expectRevert();
        script.deploy();
    }

    function test_standaloneRocketPoolScriptDeploysWorkingFactory() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(keccak256("deployer"))));

        DeployRocketPoolStrategyFactory script = new DeployRocketPoolStrategyFactory();
        address factory = script.deploy();

        assertTrue(factory.code.length > 0, "RocketPoolStrategyFactory: no code");
        assertEq(
            RocketPoolStrategyFactory(factory).R_ETH(),
            0xae78736Cd615f374D3085123A210448E74Fc6393,
            "RocketPoolStrategyFactory: wrong R_ETH"
        );
        // A salted CREATE2 collides with itself; dropping the salt would silently fall back to
        // nonce-based CREATE and deploy twice. Asserting the exact address is not sound here --
        // vm.startBroadcast attributes the creation differently in a test than in a real run.
        vm.expectRevert();
        script.deploy();
    }

    function test_standaloneLidoScriptDeploysWorkingFactory() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(keccak256("deployer"))));

        DeployLidoStrategyFactory script = new DeployLidoStrategyFactory();
        address factory = script.deploy();

        assertTrue(factory.code.length > 0, "LidoStrategyFactory: no code");
        assertEq(
            LidoStrategyFactory(factory).WSTETH(),
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            "LidoStrategyFactory: wrong WSTETH"
        );
        // A salted CREATE2 collides with itself; dropping the salt would silently fall back to
        // nonce-based CREATE and deploy twice. Asserting the exact address is not sound here --
        // vm.startBroadcast attributes the creation differently in a test than in a real run.
        vm.expectRevert();
        script.deploy();
    }

    /// @notice The four standalone scripts must declare distinct salts.
    function test_standaloneScriptSaltsAreDistinct() public {
        bytes32[4] memory salts = [
            new DeployLidoStrategyFactory().DEPLOYMENT_SALT(),
            new DeployRocketPoolStrategyFactory().DEPLOYMENT_SALT(),
            new DeploySparkStrategyFactory().DEPLOYMENT_SALT(),
            new DeployAaveV3StrategyFactory().DEPLOYMENT_SALT()
        ];

        for (uint256 i = 0; i < salts.length; i++) {
            for (uint256 j = i + 1; j < salts.length; j++) {
                assertTrue(salts[i] != salts[j], "Standalone deploy scripts share a salt");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Staging orchestrator wiring
    // -----------------------------------------------------------------------

    /// @notice DeployProtocol.setUp() must instantiate a deployer for every factory it
    ///         claims to deploy. A missing `new Deploy...()` would otherwise surface as a
    ///         call to address(0) halfway through a staging deployment.
    function test_stagingDeployProtocolWiresEveryFactoryDeployer() public {
        DeployProtocol protocol = new DeployProtocol();
        protocol.setUp();

        assertTrue(address(protocol.deploySparkStrategyFactory()) != address(0), "Spark deployer not wired");
        assertTrue(address(protocol.deployAaveV3StrategyFactory()) != address(0), "Aave V3 deployer not wired");
        assertTrue(address(protocol.deployRocketPoolStrategyFactory()) != address(0), "Rocket Pool deployer not wired");
        assertTrue(address(protocol.deployLidoStrategyFactory()) != address(0), "Lido deployer not wired");
    }

    /// @notice Anvil deploys fresh; staging, a mainnet fork, must reuse mainnet's addresses.
    ///         Catches a factory redeployed in the mainnet profile but forgotten in staging.
    /// @dev One test on purpose: vm.setEnv mutates shared process state, so two tests both
    ///      setting DEPLOYMENT_NETWORK would race and read each other's value.
    function test_deployedAddressesNetworkProfiles() public {
        DeployedAddresses registry = new DeployedAddresses();

        vm.setEnv("DEPLOYMENT_NETWORK", "anvil");
        DeployedAddresses.ContractAddresses memory anvil = registry.getAddressesByEnv();
        assertEq(anvil.sparkStrategyFactory, address(0), "anvil: spark should deploy fresh");
        assertEq(anvil.aaveV3StrategyFactory, address(0), "anvil: aave should deploy fresh");
        assertEq(anvil.rocketPoolStrategyFactory, address(0), "anvil: rocket pool should deploy fresh");
        assertEq(anvil.lidoStrategyFactory, address(0), "anvil: lido should deploy fresh");

        vm.setEnv("DEPLOYMENT_NETWORK", "mainnet");
        DeployedAddresses.ContractAddresses memory mainnet = registry.getAddressesByEnv();

        vm.setEnv("DEPLOYMENT_NETWORK", "staging");
        DeployedAddresses.ContractAddresses memory staging = registry.getAddressesByEnv();

        assertEq(staging.paymentSplitterFactory, mainnet.paymentSplitterFactory, "paymentSplitterFactory drifted");
        assertEq(
            staging.skyCompounderStrategyFactory,
            mainnet.skyCompounderStrategyFactory,
            "skyCompounderStrategyFactory drifted"
        );
        assertEq(
            staging.morphoCompounderStrategyFactory,
            mainnet.morphoCompounderStrategyFactory,
            "morphoCompounderStrategyFactory drifted"
        );
        assertEq(
            staging.yieldDonatingTokenizedStrategy,
            mainnet.yieldDonatingTokenizedStrategy,
            "yieldDonatingTokenizedStrategy drifted"
        );
        assertEq(staging.yearnV3StrategyFactory, mainnet.yearnV3StrategyFactory, "yearnV3StrategyFactory drifted");
        assertEq(staging.lidoStrategyFactory, mainnet.lidoStrategyFactory, "lidoStrategyFactory drifted");
        assertEq(staging.sparkStrategyFactory, mainnet.sparkStrategyFactory, "sparkStrategyFactory drifted");
        assertEq(staging.aaveV3StrategyFactory, mainnet.aaveV3StrategyFactory, "aaveV3StrategyFactory drifted");
        assertEq(
            staging.rocketPoolStrategyFactory,
            mainnet.rocketPoolStrategyFactory,
            "rocketPoolStrategyFactory drifted"
        );
        assertEq(staging.addressSetFactory, mainnet.addressSetFactory, "addressSetFactory drifted");
        assertEq(
            staging.regenEarningPowerCalculatorFactory,
            mainnet.regenEarningPowerCalculatorFactory,
            "regenEarningPowerCalculatorFactory drifted"
        );
        assertEq(staging.regenStakerFactory, mainnet.regenStakerFactory, "regenStakerFactory drifted");
    }

    // -----------------------------------------------------------------------
    // Negative case: the address assertion must actually reject a mismatch
    // -----------------------------------------------------------------------

    /// @notice Without this, the tests above would all still pass if the require were deleted.
    function test_addAndAssertRevertsOnAddressMismatch() public {
        BatchScriptHarness harness = new BatchScriptHarness();

        vm.expectRevert(bytes("SparkStrategyFactory: address mismatch"));
        harness.queueWithWrongExpectedAddress();
    }
}
