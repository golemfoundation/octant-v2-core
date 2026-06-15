// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ─── Forge ──────────────────────────────────────────────────────────────────
import { Script, console } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";

// ─── Safe batching ──────────────────────────────────────────────────────────
import { BatchScript } from "../helpers/BatchScript.sol";

// ─── Phase A: Strategy implementations ──────────────────────────────────────
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

// ─── Phase A: Factory contracts ─────────────────────────────────────────────
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { AddressSetFactory } from "src/factories/AddressSetFactory.sol";
import { RegenEarningPowerCalculatorFactory } from "src/factories/RegenEarningPowerCalculatorFactory.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";

// ─── Phase B: Instance contracts ────────────────────────────────────────────
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { AccessMode } from "src/constants.sol";

// ─── OZ imports (verification test) ─────────────────────────────────────────
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// ─── Type imports (staker-compatible for CreateStakerParams) ────────────────
import { Staker, IERC20 } from "staker/Staker.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";

// ─── Pinned bytecodes (reproducible deployment) ─────────────────────────────
import { REGEN_STAKER_V1_CREATION_CODE, REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE } from "./RegenStakerBytecodes.sol";

// ═════════════════════════════════════════════════════════════════════════════
//
//  FILE-LEVEL CONSTANTS -- protocol parameters (not deployment targets)
//
// ═════════════════════════════════════════════════════════════════════════════

// --- Tokens ---
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant GLM = 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429;

// --- Staker Configuration ---
uint256 constant MAX_BUMP_TIP = 0.002 ether;
uint256 constant MINIMUM_STAKE = 0;
uint256 constant REWARD_DURATION = 30 days;

// ═════════════════════════════════════════════════════════════════════════════
//
//  DEPLOYMENT SCRIPT
//
// ═════════════════════════════════════════════════════════════════════════════

/// @title DeployProtocol
/// @notice Reproducible Foundry script encoding the complete Octant v2 protocol
///         deployment to Ethereum mainnet. Protocol parameters (tokens, staker
///         config) are file-level constants. Deployment-target parameters are
///         resolved at runtime:
///           - SAFE_ADDRESS (env var, required) -- target Gnosis Safe
///           - SALT_TIMESTAMP (env var, optional) -- suffix for CREATE2 salts
///             Auto-generated via `date -u +%H%d%m%Y` if not set.
///           - Expected addresses computed from salts + safe at runtime.
///
///         The deployment is structured as 7 Gnosis Safe transactions:
///           Phase A (Tx 1-3): 10 factory/implementation contracts via Nick's CREATE2
///           Phase B (Tx 4-7): 3 address sets + calculator + staker + staker access set assignment
///                             Staker is constructed with address(0) for allowset/blockset,
///                             then assigned post-construction via admin setters in Tx 7
///                             (accessMode=NONE, so they are initially inactive).
///
///         Replay on a fork (simulation only, default):
///           CHAIN=mainnet WALLET_TYPE=local PRIVATE_KEY=0x... \
///           SAFE_ADDRESS=0x... \
///           forge script script/prod/DeployProtocol.s.sol:DeployProtocol \
///             --sig "phaseA_batch1()" --rpc-url $FORK_RPC --ffi
///
///         Set SEND=true to submit Safe transactions to the API (production).
contract DeployProtocol is Script, BatchScript {
    // ═════════════════════════════════════════════════════════════════════════
    //  STATE -- resolved once via _initialize()
    // ═════════════════════════════════════════════════════════════════════════

    bool internal _initialized;
    address internal _safe;
    string internal _saltTimestamp;

    // Phase A salts
    bytes32 internal _yieldSkimmingSalt;
    bytes32 internal _yieldDonatingSalt;
    bytes32 internal _paymentSplitterFactorySalt;
    bytes32 internal _lidoFactorySalt;
    bytes32 internal _morphoFactorySalt;
    bytes32 internal _skyFactorySalt;
    bytes32 internal _yearnV3FactorySalt;
    bytes32 internal _aaveV3FactorySalt;
    bytes32 internal _addressSetFactorySalt;
    bytes32 internal _calcFactorySalt;
    bytes32 internal _stakerFactorySalt;

    // Phase B salts
    bytes32 internal _allocationMechanismAllowsetSalt;
    bytes32 internal _calculatorSalt;
    bytes32 internal _stakerSalt;
    bytes32 internal _stakerAllowsetSalt;
    bytes32 internal _stakerBlocksetSalt;

    // ═════════════════════════════════════════════════════════════════════════
    //  INITIALIZATION
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Resolves SAFE_ADDRESS and SALT_TIMESTAMP from env, computes all 16
    ///      salts, and logs the full deployment configuration. Guarded by
    ///      _initialized to run exactly once.
    function _initialize() internal {
        if (_initialized) return;
        _initialized = true;

        _safe = vm.envAddress("SAFE_ADDRESS");

        string memory defaultTs = "";
        _saltTimestamp = vm.envOr("SALT_TIMESTAMP", defaultTs);
        if (bytes(_saltTimestamp).length == 0) {
            _saltTimestamp = _generateTimestamp();
        }

        // Phase A salts (date-based prefix)
        _yieldSkimmingSalt = keccak256(abi.encodePacked("OCTANT_YIELD_SKIMMING_STRATEGY_", _saltTimestamp));
        _yieldDonatingSalt = keccak256(abi.encodePacked("OCTANT_YIELD_DONATING_STRATEGY_", _saltTimestamp));
        _paymentSplitterFactorySalt = keccak256(abi.encodePacked("PAYMENT_SPLITTER_FACTORY_", _saltTimestamp));
        _lidoFactorySalt = keccak256(abi.encodePacked("LIDO_STRATEGY_FACTORY_", _saltTimestamp));
        _morphoFactorySalt = keccak256(abi.encodePacked("MORPHO_COMPOUNDER_FACTORY_", _saltTimestamp));
        _skyFactorySalt = keccak256(abi.encodePacked("SKY_COMPOUNDER_FACTORY_", _saltTimestamp));
        _yearnV3FactorySalt = keccak256(abi.encodePacked("YEARN_V3_STRATEGY_FACTORY_", _saltTimestamp));
        _aaveV3FactorySalt = keccak256(abi.encodePacked("AAVE_V3_STRATEGY_FACTORY_", _saltTimestamp));
        _addressSetFactorySalt = keccak256(abi.encodePacked("ADDRESS_SET_FACTORY_", _saltTimestamp));
        _calcFactorySalt = keccak256(abi.encodePacked("REGEN_EARNING_POWER_CALCULATOR_FACTORY_", _saltTimestamp));
        _stakerFactorySalt = keccak256(abi.encodePacked("REGEN_STAKER_FACTORY_", _saltTimestamp));

        // Phase B salts (instance prefix)
        _allocationMechanismAllowsetSalt = keccak256(
            abi.encodePacked("OCTANT_ALLOCATION_MECHANISM_ALLOWSET_", _saltTimestamp)
        );
        _calculatorSalt = keccak256(abi.encodePacked("OCTANT_REGEN_EARNING_POWER_CALCULATOR_", _saltTimestamp));
        _stakerSalt = keccak256(abi.encodePacked("OCTANT_REGEN_STAKER_WITHOUT_DELEGATION_", _saltTimestamp));
        _stakerAllowsetSalt = keccak256(abi.encodePacked("OCTANT_STAKER_ALLOWSET_", _saltTimestamp));
        _stakerBlocksetSalt = keccak256(abi.encodePacked("OCTANT_STAKER_BLOCKSET_", _saltTimestamp));

        // Log full configuration for operator review
        console.log("=== DEPLOYMENT CONFIGURATION ===");
        console.log("Safe:", _safe);
        console.log("Salt timestamp:", _saltTimestamp);
        console.log("");
        _logPhaseAAddresses();
        _logPhaseBAddresses();
        console.log("================================");
    }

    /// @dev Calls _initialize() and returns _safe. Used as an argument to the
    ///      isBatch(address) modifier so initialization happens before the
    ///      modifier body runs.
    function _initAndGetSafe() internal returns (address) {
        _initialize();
        return _safe;
    }

    /// @dev Generates a timestamp string in HH_DDMMYYYY format via FFI.
    ///      The underscore prevents Foundry's vm.ffi from hex-decoding
    ///      all-numeric output. Unique per hour, reproducible within the
    ///      same hour.
    function _generateTimestamp() internal returns (string memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = "printf '%s' $(date -u +'%H_%d%m%Y')";
        return string(vm.ffi(inputs));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Returns true when SEND=true env var is set. Defaults to false
    ///      (simulation only). Set SEND=true for production Safe API submission.
    function _shouldSend() internal view returns (bool) {
        return vm.envOr("SEND", false);
    }

    /// @dev Computes the deterministic AddressSetFactory address from Phase A.
    function _addressSetFactoryAddress() internal view returns (address) {
        return _computeCreate2AddressViaFactory(_addressSetFactorySalt, type(AddressSetFactory).creationCode);
    }

    /// @dev Computes the deterministic RegenStakerFactory address from Phase A.
    function _stakerFactoryAddress() internal view returns (address) {
        return
            _computeCreate2AddressViaFactory(
                _stakerFactorySalt,
                abi.encodePacked(
                    type(RegenStakerFactory).creationCode,
                    abi.encode(
                        keccak256(REGEN_STAKER_V1_CREATION_CODE),
                        keccak256(REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE)
                    )
                )
            );
    }

    /// @dev Computes the deterministic RegenEarningPowerCalculator address from Phase B.
    function _calculatorAddress() internal view returns (address) {
        return
            _computeCreate2AddressViaFactory(
                _calculatorSalt,
                abi.encodePacked(
                    type(RegenEarningPowerCalculator).creationCode,
                    abi.encode(_safe, IAddressSet(address(0)), IAddressSet(address(0)), AccessMode.NONE)
                )
            );
    }

    /// @dev Predicts an AddressSet address as deployed by AddressSetFactory.
    ///      Replicates AddressSetFactory.predictAddress logic using a pre-computed factory address.
    function _predictAddressSet(address asFactory, bytes32 salt, address owner) internal pure returns (address) {
        bytes32 finalSalt = keccak256(abi.encode(salt, owner));
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), asFactory, finalSalt, keccak256(type(AddressSet).creationCode))
        );
        return address(uint160(uint256(hash)));
    }

    /// @dev Computes the deterministic RegenStaker (WITHOUT delegation) address from Phase B.
    ///      Replicates RegenStakerFactory._deployStaker CREATE2 logic using a pre-computed factory address.
    function _stakerAddress() internal view returns (address) {
        address asFactory = _addressSetFactoryAddress();
        address sfactory = _stakerFactoryAddress();

        // Replicate _encodeConstructorParams ordering from RegenStakerFactory
        bytes memory constructorParams = abi.encode(
            IERC20(WETH), // rewardsToken
            IERC20(GLM), // stakeToken
            IEarningPowerCalculator(_calculatorAddress()), // earningPowerCalculator
            MAX_BUMP_TIP, // maxBumpTip
            _safe, // admin
            REWARD_DURATION, // rewardDuration
            MINIMUM_STAKE, // minimumStakeAmount
            IAddressSet(address(0)), // stakerAllowset (assigned post-construction via Tx 7)
            IAddressSet(address(0)), // stakerBlockset (assigned post-construction via Tx 7)
            AccessMode.NONE, // stakerAccessMode
            IAddressSet(_predictAddressSet(asFactory, _allocationMechanismAllowsetSalt, _safe)) // allocationMechanismAllowset
        );

        bytes memory fullBytecode = bytes.concat(REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE, constructorParams);
        // finalSalt = keccak256(abi.encode(salt, msg.sender)) where msg.sender is the Safe
        bytes32 finalSalt = keccak256(abi.encode(_stakerSalt, _safe));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), sfactory, finalSalt, keccak256(fullBytecode)));
        return address(uint160(uint256(hash)));
    }

    /// @notice Compute and log all 16 deterministic addresses from CREATE2 math.
    ///         Requires SAFE_ADDRESS env var. Uses SALT_TIMESTAMP if set,
    ///         otherwise auto-generates via FFI.
    ///
    ///         Usage: SAFE_ADDRESS=0x... forge script script/prod/DeployProtocol.s.sol:DeployProtocol \
    ///                  --sig "computeAllAddresses()" --ffi
    function computeAllAddresses() external {
        _initialize();
        // Addresses already logged by _initialize() via _logPhaseAAddresses/_logPhaseBAddresses
    }

    function _logPhaseAAddresses() internal view {
        console.log(
            "EXPECTED_YIELD_SKIMMING:",
            _computeCreate2AddressViaFactory(_yieldSkimmingSalt, type(YieldSkimmingTokenizedStrategy).creationCode)
        );
        console.log(
            "EXPECTED_YIELD_DONATING:",
            _computeCreate2AddressViaFactory(_yieldDonatingSalt, type(YieldDonatingTokenizedStrategy).creationCode)
        );
        console.log(
            "EXPECTED_PAYMENT_SPLITTER_FACTORY:",
            _computeCreate2AddressViaFactory(_paymentSplitterFactorySalt, type(PaymentSplitterFactory).creationCode)
        );
        console.log(
            "EXPECTED_LIDO_FACTORY:",
            _computeCreate2AddressViaFactory(_lidoFactorySalt, type(LidoStrategyFactory).creationCode)
        );
        console.log(
            "EXPECTED_MORPHO_FACTORY:",
            _computeCreate2AddressViaFactory(_morphoFactorySalt, type(MorphoCompounderStrategyFactory).creationCode)
        );
        console.log(
            "EXPECTED_SKY_FACTORY:",
            _computeCreate2AddressViaFactory(_skyFactorySalt, type(SkyCompounderStrategyFactory).creationCode)
        );
        console.log(
            "EXPECTED_YEARN_FACTORY:",
            _computeCreate2AddressViaFactory(_yearnV3FactorySalt, type(YearnV3StrategyFactory).creationCode)
        );
        console.log(
            "EXPECTED_AAVE_FACTORY:",
            _computeCreate2AddressViaFactory(_aaveV3FactorySalt, type(AaveV3StrategyFactory).creationCode)
        );
        console.log("EXPECTED_ADDRESS_SET_FACTORY:", _addressSetFactoryAddress());
        console.log(
            "EXPECTED_CALC_FACTORY:",
            _computeCreate2AddressViaFactory(_calcFactorySalt, type(RegenEarningPowerCalculatorFactory).creationCode)
        );
        console.log("EXPECTED_STAKER_FACTORY:", _stakerFactoryAddress());
    }

    function _logPhaseBAddresses() internal view {
        address asFactory = _addressSetFactoryAddress();
        console.log("EXPECTED_ALLOWSET:", _predictAddressSet(asFactory, _allocationMechanismAllowsetSalt, _safe));
        console.log("EXPECTED_STAKER_ALLOWSET:", _predictAddressSet(asFactory, _stakerAllowsetSalt, _safe));
        console.log("EXPECTED_STAKER_BLOCKSET:", _predictAddressSet(asFactory, _stakerBlocksetSalt, _safe));
        console.log("EXPECTED_CALCULATOR:", _calculatorAddress());
        console.log("EXPECTED_STAKER:", _stakerAddress());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PHASE A: Factory Deployment (3 Safe Transactions)
    //
    //  All 11 contracts deployed via Nick's CREATE2 factory (0x4e59b44...56C).
    //  Split into 3 batches due to the EIP-7825 per-tx gas limit of ~16.78M.
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Tx 1 (~12.4M gas): 5 contracts
    ///         - YieldSkimmingTokenizedStrategy
    ///         - YieldDonatingTokenizedStrategy
    ///         - PaymentSplitterFactory
    ///         - LidoStrategyFactory
    ///         - MorphoCompounderStrategyFactory
    function phaseA_batch1() external isBatch(_initAndGetSafe()) {
        address deployed;
        address expected;

        deployed = _addCreate2Deployment(_yieldSkimmingSalt, type(YieldSkimmingTokenizedStrategy).creationCode);
        expected = _computeCreate2AddressViaFactory(
            _yieldSkimmingSalt,
            type(YieldSkimmingTokenizedStrategy).creationCode
        );
        require(deployed == expected, "YieldSkimming address mismatch");
        console.log("YieldSkimmingTokenizedStrategy:", deployed);

        deployed = _addCreate2Deployment(_yieldDonatingSalt, type(YieldDonatingTokenizedStrategy).creationCode);
        expected = _computeCreate2AddressViaFactory(
            _yieldDonatingSalt,
            type(YieldDonatingTokenizedStrategy).creationCode
        );
        require(deployed == expected, "YieldDonating address mismatch");
        console.log("YieldDonatingTokenizedStrategy:", deployed);

        deployed = _addCreate2Deployment(_paymentSplitterFactorySalt, type(PaymentSplitterFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(
            _paymentSplitterFactorySalt,
            type(PaymentSplitterFactory).creationCode
        );
        require(deployed == expected, "PaymentSplitterFactory address mismatch");
        console.log("PaymentSplitterFactory:", deployed);

        deployed = _addCreate2Deployment(_lidoFactorySalt, type(LidoStrategyFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(_lidoFactorySalt, type(LidoStrategyFactory).creationCode);
        require(deployed == expected, "LidoStrategyFactory address mismatch");
        console.log("LidoStrategyFactory:", deployed);

        deployed = _addCreate2Deployment(_morphoFactorySalt, type(MorphoCompounderStrategyFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(
            _morphoFactorySalt,
            type(MorphoCompounderStrategyFactory).creationCode
        );
        require(deployed == expected, "MorphoCompounderStrategyFactory address mismatch");
        console.log("MorphoCompounderStrategyFactory:", deployed);

        executeBatch(_shouldSend());
    }

    /// @notice Tx 2: 3 contracts
    ///         - SkyCompounderStrategyFactory
    ///         - YearnV3StrategyFactory
    ///         - AaveV3StrategyFactory
    function phaseA_batch2() external isBatch(_initAndGetSafe()) {
        address deployed;
        address expected;

        deployed = _addCreate2Deployment(_skyFactorySalt, type(SkyCompounderStrategyFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(_skyFactorySalt, type(SkyCompounderStrategyFactory).creationCode);
        require(deployed == expected, "SkyFactory address mismatch");
        console.log("SkyCompounderStrategyFactory:", deployed);

        deployed = _addCreate2Deployment(_yearnV3FactorySalt, type(YearnV3StrategyFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(_yearnV3FactorySalt, type(YearnV3StrategyFactory).creationCode);
        require(deployed == expected, "YearnFactory address mismatch");
        console.log("YearnV3StrategyFactory:", deployed);

        deployed = _addCreate2Deployment(_aaveV3FactorySalt, type(AaveV3StrategyFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(_aaveV3FactorySalt, type(AaveV3StrategyFactory).creationCode);
        require(deployed == expected, "AaveV3Factory address mismatch");
        console.log("AaveV3StrategyFactory:", deployed);

        executeBatch(_shouldSend());
    }

    /// @notice Tx 3 (~3M gas): 3 contracts
    ///         - AddressSetFactory
    ///         - RegenEarningPowerCalculatorFactory
    ///         - RegenStakerFactory (constructor: canonical bytecode hashes)
    function phaseA_batch3() external isBatch(_initAndGetSafe()) {
        address deployed;
        address expected;

        deployed = _addCreate2Deployment(_addressSetFactorySalt, type(AddressSetFactory).creationCode);
        expected = _addressSetFactoryAddress();
        require(deployed == expected, "AddressSetFactory address mismatch");
        console.log("AddressSetFactory:", deployed);

        deployed = _addCreate2Deployment(_calcFactorySalt, type(RegenEarningPowerCalculatorFactory).creationCode);
        expected = _computeCreate2AddressViaFactory(
            _calcFactorySalt,
            type(RegenEarningPowerCalculatorFactory).creationCode
        );
        require(deployed == expected, "CalcFactory address mismatch");
        console.log("RegenEarningPowerCalculatorFactory:", deployed);

        deployed = _addCreate2Deployment(
            _stakerFactorySalt,
            abi.encodePacked(
                type(RegenStakerFactory).creationCode,
                abi.encode(
                    keccak256(REGEN_STAKER_V1_CREATION_CODE),
                    keccak256(REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE)
                )
            )
        );
        expected = _stakerFactoryAddress();
        require(deployed == expected, "StakerFactory address mismatch");
        console.log("RegenStakerFactory:", deployed);

        executeBatch(_shouldSend());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  PHASE B: Instance Deployment (4 Safe Transactions)
    //
    //  Requires Phase A factories to be deployed and executed on-chain first.
    //  Deploys 3 address sets, the earning power calculator, and the staker.
    //  The staker is constructed with address(0) for allowset/blockset, then
    //  assigned post-construction via admin setters in Tx 7.
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Tx 4: Deploy all 3 address sets via AddressSetFactory
    ///         - allocationMechanismAllowset
    ///         - stakerAllowset
    ///         - stakerBlockset
    ///         Batched into a single Safe MultiSend transaction.
    function phaseB_addressSets() external isBatch(_initAndGetSafe()) {
        address asFactory = _addressSetFactoryAddress();
        address deployed;
        address expected;

        // 1. Deploy allocation mechanism allowset
        bytes memory result = addToBatch(
            asFactory,
            0,
            abi.encodeWithSignature("deploy(bytes32,address)", _allocationMechanismAllowsetSalt, _safe)
        );
        deployed = abi.decode(result, (address));
        expected = _predictAddressSet(asFactory, _allocationMechanismAllowsetSalt, _safe);
        require(deployed == expected, "AllowSet address mismatch");
        console.log("AllocationMechanismAllowset:", deployed);

        // 2. Deploy staker allowset
        result = addToBatch(
            asFactory,
            0,
            abi.encodeWithSignature("deploy(bytes32,address)", _stakerAllowsetSalt, _safe)
        );
        deployed = abi.decode(result, (address));
        expected = _predictAddressSet(asFactory, _stakerAllowsetSalt, _safe);
        require(deployed == expected, "StakerAllowset address mismatch");
        console.log("StakerAllowset:", deployed);

        // 3. Deploy staker blockset
        result = addToBatch(
            asFactory,
            0,
            abi.encodeWithSignature("deploy(bytes32,address)", _stakerBlocksetSalt, _safe)
        );
        deployed = abi.decode(result, (address));
        expected = _predictAddressSet(asFactory, _stakerBlocksetSalt, _safe);
        require(deployed == expected, "StakerBlockset address mismatch");
        console.log("StakerBlockset:", deployed);

        executeBatch(_shouldSend());
    }

    /// @notice Tx 5: Deploy RegenEarningPowerCalculator via Nick's CREATE2 factory
    ///         Constructor args: owner=Safe, allowset=0, blockset=0, accessMode=NONE
    ///         Batched as a single Safe transaction. Address assertion runs before
    ///         the batch is submitted.
    function phaseB_calculator() external isBatch(_initAndGetSafe()) {
        bytes memory creationCode = abi.encodePacked(
            type(RegenEarningPowerCalculator).creationCode,
            abi.encode(_safe, IAddressSet(address(0)), IAddressSet(address(0)), AccessMode.NONE)
        );

        address deployed = _addCreate2Deployment(_calculatorSalt, creationCode);
        address expected = _calculatorAddress();
        require(deployed == expected, "Calculator address mismatch");
        console.log("RegenEarningPowerCalculator:", deployed);

        executeBatch(_shouldSend());
    }

    /// @notice Tx 6: Deploy RegenStaker (WITHOUT delegation) via RegenStakerFactory
    ///         Staker is constructed with address(0) for stakerAllowset and
    ///         stakerBlockset. These are assigned post-construction in Tx 7.
    ///         accessMode is set to NONE so the sets are initially inactive.
    ///         Batched as a single Safe transaction. Address assertion runs
    ///         before the batch is submitted.
    function phaseB_staker() external isBatch(_initAndGetSafe()) {
        AddressSetFactory asFactory = AddressSetFactory(_addressSetFactoryAddress());

        RegenStakerFactory.CreateStakerParams memory params = RegenStakerFactory.CreateStakerParams({
            rewardsToken: IERC20(WETH),
            stakeToken: IERC20(GLM),
            admin: _safe,
            stakerAllowset: IAddressSet(address(0)),
            stakerBlockset: IAddressSet(address(0)),
            stakerAccessMode: AccessMode.NONE,
            allocationMechanismAllowset: IAddressSet(asFactory.predictAddress(_allocationMechanismAllowsetSalt, _safe)),
            earningPowerCalculator: IEarningPowerCalculator(_calculatorAddress()),
            maxBumpTip: MAX_BUMP_TIP,
            minimumStakeAmount: MINIMUM_STAKE,
            rewardDuration: REWARD_DURATION
        });

        bytes memory data = abi.encodeWithSignature(
            "createStakerWithoutDelegation((address,address,address,address,address,uint8,address,address,uint256,uint256,uint256),bytes32,bytes)",
            params,
            _stakerSalt,
            REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE
        );

        bytes memory result = addToBatch(_stakerFactoryAddress(), 0, data);
        address deployed = abi.decode(result, (address));
        address expected = _stakerAddress();
        require(deployed == expected, "Staker address mismatch");
        console.log("RegenStaker:", deployed);

        executeBatch(_shouldSend());
    }

    /// @notice Tx 7: Assign staker allowset and blockset via admin setters.
    ///         Batched into a single Safe MultiSend transaction.
    ///         Requires Tx 6 (staker deployment) to have been executed on-chain.
    function phaseB_stakerAccessSets() external isBatch(_initAndGetSafe()) {
        address stakerAddr = _stakerAddress();
        require(stakerAddr.code.length > 0, "Staker not deployed -- run phaseB_staker first");

        address asFactory = _addressSetFactoryAddress();
        address expectedAllowset = _predictAddressSet(asFactory, _stakerAllowsetSalt, _safe);
        address expectedBlockset = _predictAddressSet(asFactory, _stakerBlocksetSalt, _safe);

        addToBatch(stakerAddr, 0, abi.encodeWithSignature("setStakerAllowset(address)", expectedAllowset));

        addToBatch(stakerAddr, 0, abi.encodeWithSignature("setStakerBlockset(address)", expectedBlockset));

        // Verify state was set correctly in simulation before submitting
        RegenStakerWithoutDelegateSurrogateVotes staker = RegenStakerWithoutDelegateSurrogateVotes(stakerAddr);
        require(
            address(staker.stakerAllowset()) == expectedAllowset,
            "stakerAllowset not set correctly after simulation"
        );
        require(
            address(staker.stakerBlockset()) == expectedBlockset,
            "stakerBlockset not set correctly after simulation"
        );

        executeBatch(_shouldSend());
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//
//  SOURCE CODE VERIFICATION (Etherscan & Sourcify)
//
// ═════════════════════════════════════════════════════════════════════════════

/// @title VerifyProtocolSourceCode
/// @notice Verifies all 16 Octant v2 protocol contracts on Etherscan and Sourcify.
///         Uses deterministic addresses computed at runtime from SAFE_ADDRESS and
///         SALT_TIMESTAMP env vars, reusing DeployProtocol address-computation helpers.
///
///         Etherscan (requires API key):
///           SAFE_ADDRESS=0x... SALT_TIMESTAMP=... ETHERSCAN_API_KEY=... \
///           forge script script/prod/DeployProtocol.s.sol:VerifyProtocolSourceCode \
///             --sig "verifyEtherscan()" --ffi
///
///         Sourcify (no API key needed):
///           SAFE_ADDRESS=0x... SALT_TIMESTAMP=... \
///           forge script script/prod/DeployProtocol.s.sol:VerifyProtocolSourceCode \
///             --sig "verifySourcify()" --ffi
contract VerifyProtocolSourceCode is DeployProtocol {
    // ═════════════════════════════════════════════════════════════════════════
    //  CONTRACT SOURCE PATHS
    // ═════════════════════════════════════════════════════════════════════════

    string constant YIELD_SKIMMING_PATH =
        "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol:YieldSkimmingTokenizedStrategy";
    string constant YIELD_DONATING_PATH =
        "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol:YieldDonatingTokenizedStrategy";
    string constant PAYMENT_SPLITTER_FACTORY_PATH = "src/factories/PaymentSplitterFactory.sol:PaymentSplitterFactory";
    string constant LIDO_FACTORY_PATH = "src/factories/LidoStrategyFactory.sol:LidoStrategyFactory";
    string constant MORPHO_FACTORY_PATH =
        "src/factories/MorphoCompounderStrategyFactory.sol:MorphoCompounderStrategyFactory";
    string constant SKY_FACTORY_PATH = "src/factories/SkyCompounderStrategyFactory.sol:SkyCompounderStrategyFactory";
    string constant YEARN_FACTORY_PATH =
        "src/factories/yieldDonating/YearnV3StrategyFactory.sol:YearnV3StrategyFactory";
    string constant AAVE_FACTORY_PATH = "src/factories/AaveV3StrategyFactory.sol:AaveV3StrategyFactory";
    string constant ADDRESS_SET_FACTORY_PATH = "src/factories/AddressSetFactory.sol:AddressSetFactory";
    string constant CALC_FACTORY_PATH =
        "src/factories/RegenEarningPowerCalculatorFactory.sol:RegenEarningPowerCalculatorFactory";
    string constant STAKER_FACTORY_PATH = "src/factories/RegenStakerFactory.sol:RegenStakerFactory";
    string constant ADDRESS_SET_PATH = "src/utils/AddressSet.sol:AddressSet";
    string constant CALCULATOR_PATH = "src/regen/RegenEarningPowerCalculator.sol:RegenEarningPowerCalculator";
    string constant STAKER_PATH =
        "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol:RegenStakerWithoutDelegateSurrogateVotes";

    // ═════════════════════════════════════════════════════════════════════════
    //  ENTRY POINTS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Verify all 16 contracts on Etherscan. Requires ETHERSCAN_API_KEY env var.
    function verifyEtherscan() external {
        _initialize();
        _verifyAll("etherscan");
    }

    /// @notice Verify all 16 contracts on Sourcify. No API key needed.
    function verifySourcify() external {
        _initialize();
        _verifyAll("sourcify");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL: ORCHESTRATION
    // ═════════════════════════════════════════════════════════════════════════

    function _verifyAll(string memory verifier) internal {
        console.log("=== VERIFYING ALL 16 PROTOCOL CONTRACTS ===");
        console.log("Verifier:", verifier);
        console.log("");

        _verifyPhaseANoArgs(verifier);
        _verifyPhaseAWithArgs(verifier);
        _verifyPhaseBNoArgs(verifier);
        _verifyPhaseBWithArgs(verifier);

        console.log("=== VERIFICATION COMPLETE ===");
    }

    function _verifyPhaseANoArgs(string memory verifier) internal {
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_yieldSkimmingSalt, type(YieldSkimmingTokenizedStrategy).creationCode),
            YIELD_SKIMMING_PATH,
            "YieldSkimmingTokenizedStrategy",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_yieldDonatingSalt, type(YieldDonatingTokenizedStrategy).creationCode),
            YIELD_DONATING_PATH,
            "YieldDonatingTokenizedStrategy",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_paymentSplitterFactorySalt, type(PaymentSplitterFactory).creationCode),
            PAYMENT_SPLITTER_FACTORY_PATH,
            "PaymentSplitterFactory",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_lidoFactorySalt, type(LidoStrategyFactory).creationCode),
            LIDO_FACTORY_PATH,
            "LidoStrategyFactory",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_morphoFactorySalt, type(MorphoCompounderStrategyFactory).creationCode),
            MORPHO_FACTORY_PATH,
            "MorphoCompounderStrategyFactory",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_skyFactorySalt, type(SkyCompounderStrategyFactory).creationCode),
            SKY_FACTORY_PATH,
            "SkyCompounderStrategyFactory",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_yearnV3FactorySalt, type(YearnV3StrategyFactory).creationCode),
            YEARN_FACTORY_PATH,
            "YearnV3StrategyFactory",
            verifier
        );
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_aaveV3FactorySalt, type(AaveV3StrategyFactory).creationCode),
            AAVE_FACTORY_PATH,
            "AaveV3StrategyFactory",
            verifier
        );
        _verifyNoArgs(_addressSetFactoryAddress(), ADDRESS_SET_FACTORY_PATH, "AddressSetFactory", verifier);
        _verifyNoArgs(
            _computeCreate2AddressViaFactory(_calcFactorySalt, type(RegenEarningPowerCalculatorFactory).creationCode),
            CALC_FACTORY_PATH,
            "RegenEarningPowerCalculatorFactory",
            verifier
        );
    }

    function _verifyPhaseAWithArgs(string memory verifier) internal {
        bytes memory stakerFactoryArgs = abi.encode(
            keccak256(REGEN_STAKER_V1_CREATION_CODE),
            keccak256(REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE)
        );
        _verifyWithArgs(
            _stakerFactoryAddress(),
            STAKER_FACTORY_PATH,
            "RegenStakerFactory",
            stakerFactoryArgs,
            verifier
        );
    }

    function _verifyPhaseBNoArgs(string memory verifier) internal {
        address asFactory = _addressSetFactoryAddress();
        _verifyNoArgs(
            _predictAddressSet(asFactory, _allocationMechanismAllowsetSalt, _safe),
            ADDRESS_SET_PATH,
            "AddressSet (allocationMechanism)",
            verifier
        );
        _verifyNoArgs(
            _predictAddressSet(asFactory, _stakerAllowsetSalt, _safe),
            ADDRESS_SET_PATH,
            "AddressSet (stakerAllowset)",
            verifier
        );
        _verifyNoArgs(
            _predictAddressSet(asFactory, _stakerBlocksetSalt, _safe),
            ADDRESS_SET_PATH,
            "AddressSet (stakerBlockset)",
            verifier
        );
    }

    function _verifyPhaseBWithArgs(string memory verifier) internal {
        bytes memory calculatorArgs = abi.encode(
            _safe,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );
        _verifyWithArgs(_calculatorAddress(), CALCULATOR_PATH, "RegenEarningPowerCalculator", calculatorArgs, verifier);

        address asFactory = _addressSetFactoryAddress();
        bytes memory stakerArgs = abi.encode(
            IERC20(WETH),
            IERC20(GLM),
            IEarningPowerCalculator(_calculatorAddress()),
            MAX_BUMP_TIP,
            _safe,
            REWARD_DURATION,
            MINIMUM_STAKE,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(_predictAddressSet(asFactory, _allocationMechanismAllowsetSalt, _safe))
        );
        _verifyWithArgs(
            _stakerAddress(),
            STAKER_PATH,
            "RegenStakerWithoutDelegateSurrogateVotes",
            stakerArgs,
            verifier
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL: FFI VERIFICATION
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Verify a contract with no constructor args via forge verify-contract.
    function _verifyNoArgs(
        address contractAddress,
        string memory contractPath,
        string memory displayName,
        string memory verifier
    ) internal {
        console.log("Verifying", displayName, "at", contractAddress);

        string[] memory inputs = new string[](9);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(contractAddress);
        inputs[3] = contractPath;
        inputs[4] = "--verifier";
        inputs[5] = verifier;
        inputs[6] = "--chain";
        inputs[7] = "1";
        inputs[8] = "--watch";

        try vm.ffi(inputs) returns (bytes memory result) {
            console.log("  [SUCCESS]", displayName);
            console.log("   ", string(result));
        } catch (bytes memory error) {
            console.log("  [FAILED]", displayName);
            console.log("   ", string(error));
        }

        console.log("");
    }

    /// @dev Verify a contract with constructor args via forge verify-contract.
    ///      For Sourcify, constructor args are extracted from the creation tx automatically,
    ///      so we skip the --constructor-args flag.
    function _verifyWithArgs(
        address contractAddress,
        string memory contractPath,
        string memory displayName,
        bytes memory constructorArgs,
        string memory verifier
    ) internal {
        console.log("Verifying", displayName, "at", contractAddress);

        bool isEtherscan = keccak256(bytes(verifier)) == keccak256(bytes("etherscan"));

        uint256 inputCount = isEtherscan ? 11 : 9;
        string[] memory inputs = new string[](inputCount);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(contractAddress);
        inputs[3] = contractPath;
        inputs[4] = "--verifier";
        inputs[5] = verifier;
        inputs[6] = "--chain";
        inputs[7] = "1";
        inputs[8] = "--watch";

        if (isEtherscan) {
            inputs[9] = "--constructor-args";
            inputs[10] = vm.toString(constructorArgs);
        }

        try vm.ffi(inputs) returns (bytes memory result) {
            console.log("  [SUCCESS]", displayName);
            console.log("   ", string(result));
        } catch (bytes memory error) {
            console.log("  [FAILED]", displayName);
            console.log("   ", string(error));
        }

        console.log("");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
//
//  DEPLOYMENT VERIFICATION TEST
//
// ═════════════════════════════════════════════════════════════════════════════

/// @title VerifyProtocolDeployment
/// @notice Fork test that validates all deployed mainnet contracts are correctly
///         deployed and functionally operational. Covers all Phase A
///         factory/implementation contracts available via env/defaults and all
///         5 Phase B instance contracts.
///
///         All addresses are read from env vars with production defaults, so the
///         test works both for production verification (run with no env vars) and
///         testbed verification (override via env).
///
///         Run against Ethereum mainnet fork:
///           forge test --match-contract VerifyProtocolDeployment --fork-url <mainnet-rpc>
///
///         Run against testbed deployment:
///           SAFE_ADDRESS=0x... SALT_TIMESTAMP=... \
///           EXPECTED_YIELD_SKIMMING=0x... EXPECTED_YIELD_DONATING=0x... ... \
///           forge test --match-contract VerifyProtocolDeployment --fork-url <mainnet-rpc>
contract VerifyProtocolDeployment is Test {
    // --- State (set in setUp from env vars with production defaults) ---

    address internal _safe;

    // Phase A
    address internal _yieldSkimming;
    address internal _yieldDonating;
    PaymentSplitterFactory internal paymentSplitterFactory;
    LidoStrategyFactory internal lidoStrategyFactory;
    MorphoCompounderStrategyFactory internal morphoFactory;
    SkyCompounderStrategyFactory internal skyFactory;
    YearnV3StrategyFactory internal yearnFactory;
    AaveV3StrategyFactory internal aaveFactory;
    AddressSetFactory internal addressSetFactory;
    RegenEarningPowerCalculatorFactory internal calculatorFactory;
    RegenStakerFactory internal regenStakerFactory;

    // Phase B
    AddressSet internal allowSet;
    RegenEarningPowerCalculator internal calculator;
    RegenStakerWithoutDelegateSurrogateVotes internal staker;

    // Phase C
    AddressSet internal stakerAllowset;
    AddressSet internal stakerBlockset;

    // Salts (for determinism checks)
    bytes32 internal _allocationMechanismAllowsetSalt;
    bytes32 internal _stakerAllowsetSalt;
    bytes32 internal _stakerBlocksetSalt;

    // --- All deployed addresses for code-existence check ---
    address[] internal allContracts;

    address internal testUser = makeAddr("testUser");

    function setUp() public {
        // Deployment target
        _safe = vm.envOr("SAFE_ADDRESS", address(0x4B55fA101Dfa399af2FCDa83bB9e77bCa0009418));

        // Compute salts from timestamp (default "V1" matches production Phase B salts)
        string memory saltTimestamp = vm.envOr("SALT_TIMESTAMP", string("V1"));
        _allocationMechanismAllowsetSalt = keccak256(
            abi.encodePacked("OCTANT_ALLOCATION_MECHANISM_ALLOWSET_", saltTimestamp)
        );
        _stakerAllowsetSalt = keccak256(abi.encodePacked("OCTANT_STAKER_ALLOWSET_", saltTimestamp));
        _stakerBlocksetSalt = keccak256(abi.encodePacked("OCTANT_STAKER_BLOCKSET_", saltTimestamp));

        // Phase A addresses
        _yieldSkimming = vm.envOr("EXPECTED_YIELD_SKIMMING", address(0x573A99d6717273fcC48072F1A9761b337b4877fF));
        _yieldDonating = vm.envOr("EXPECTED_YIELD_DONATING", address(0xb7Ac4a08b9e0FAD5DC154e4F4b35b4365B2Fb3cA));
        paymentSplitterFactory = PaymentSplitterFactory(
            vm.envOr("EXPECTED_PAYMENT_SPLITTER_FACTORY", address(0x11551f2b877055b2731E5A25B1C01966C0D5aaA1))
        );
        lidoStrategyFactory = LidoStrategyFactory(
            vm.envOr("EXPECTED_LIDO_FACTORY", address(0x4732CF067dEcB38B84F64f4Ae61FD83a6D2eBb03))
        );
        morphoFactory = MorphoCompounderStrategyFactory(
            vm.envOr("EXPECTED_MORPHO_FACTORY", address(0xeC9710B9e3404C788AddD567dF52D669942fA5d2))
        );
        skyFactory = SkyCompounderStrategyFactory(
            vm.envOr("EXPECTED_SKY_FACTORY", address(0x67E5dc580c5c8702B7E46BA1812C56d304B136D3))
        );
        yearnFactory = YearnV3StrategyFactory(
            vm.envOr("EXPECTED_YEARN_FACTORY", address(0xd5338eb7DFFE2e16cd217e8b0FA3d762024f614C))
        );
        aaveFactory = AaveV3StrategyFactory(vm.envOr("EXPECTED_AAVE_FACTORY", address(0)));
        addressSetFactory = AddressSetFactory(
            vm.envOr("EXPECTED_ADDRESS_SET_FACTORY", address(0x94e05a2bEd3a6bD2809cF8Dcb7dc85b57019F714))
        );
        calculatorFactory = RegenEarningPowerCalculatorFactory(
            vm.envOr("EXPECTED_CALC_FACTORY", address(0x5Afd92333b6e5AF40A55455abD435cb2EE876Dba))
        );
        regenStakerFactory = RegenStakerFactory(
            vm.envOr("EXPECTED_STAKER_FACTORY", address(0x8f15465724bF7a7fF4171257E4f03Df1A586201D))
        );

        // Phase B addresses
        allowSet = AddressSet(vm.envOr("EXPECTED_ALLOWSET", address(0x19cD4e88f7F76948e54285b4E47B7d202225ee50)));
        calculator = RegenEarningPowerCalculator(
            vm.envOr("EXPECTED_CALCULATOR", address(0x66F7b714360866725EF9d5C13EB4761113F3580c))
        );
        staker = RegenStakerWithoutDelegateSurrogateVotes(
            vm.envOr("EXPECTED_STAKER", address(0xD883B716F03EDcC3a007b6B1e5131eE81f04490a))
        );
        stakerAllowset = AddressSet(
            vm.envOr("EXPECTED_STAKER_ALLOWSET", address(0xb0661B32f9B5D0eBAde3fec11DF21FBd12a1e941))
        );
        stakerBlockset = AddressSet(
            vm.envOr("EXPECTED_STAKER_BLOCKSET", address(0xa64E2d8dd4C283F89dCF1Db5414A0c78ae4e85b5))
        );

        allContracts.push(_yieldSkimming);
        allContracts.push(_yieldDonating);
        allContracts.push(address(paymentSplitterFactory));
        allContracts.push(address(lidoStrategyFactory));
        allContracts.push(address(morphoFactory));
        allContracts.push(address(skyFactory));
        allContracts.push(address(yearnFactory));
        if (address(aaveFactory) != address(0)) {
            allContracts.push(address(aaveFactory));
        }
        allContracts.push(address(addressSetFactory));
        allContracts.push(address(calculatorFactory));
        allContracts.push(address(regenStakerFactory));
        allContracts.push(address(allowSet));
        allContracts.push(address(calculator));
        allContracts.push(address(staker));
        allContracts.push(address(stakerAllowset));
        allContracts.push(address(stakerBlockset));
    }

    // -----------------------------------------------------------------------
    // Test 1: All configured contracts have code on-chain
    // -----------------------------------------------------------------------

    function test_allContractsHaveCode() public view {
        for (uint256 i = 0; i < allContracts.length; i++) {
            assertTrue(
                allContracts[i].code.length > 0,
                string.concat("No code at address: ", vm.toString(allContracts[i]))
            );
        }
    }

    // -----------------------------------------------------------------------
    // Test 2: Factory interface smoke tests
    // -----------------------------------------------------------------------

    function test_factoryInterfaces() public view {
        // PaymentSplitterFactory
        assertTrue(paymentSplitterFactory.implementation() != address(0), "PSF: zero implementation");
        assertTrue(paymentSplitterFactory.owner() != address(0), "PSF: zero owner");

        // LidoStrategyFactory
        assertEq(lidoStrategyFactory.WSTETH(), 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "LidoFactory: wrong WSTETH");

        // MorphoCompounderStrategyFactory
        assertEq(morphoFactory.USDC(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "MorphoFactory: wrong USDC");
        assertEq(morphoFactory.YS_USDC(), 0x074134A2784F4F66b6ceD6f68849382990Ff3215, "MorphoFactory: wrong YS_USDC");

        // SkyCompounderStrategyFactory
        assertEq(skyFactory.USDS(), 0xdC035D45d973E3EC169d2276DDab16f1e407384F, "SkyFactory: wrong USDS");
        assertEq(
            skyFactory.USDS_REWARD_ADDRESS(),
            0x0650CAF159C5A49f711e8169D4336ECB9b950275,
            "SkyFactory: wrong USDS_REWARD_ADDRESS"
        );

        // YearnV3StrategyFactory: computeStrategyAddress doesn't revert
        yearnFactory.computeStrategyAddress(
            address(1),
            address(2),
            "test",
            "TST",
            address(3),
            address(4),
            address(5),
            address(6),
            false,
            _yieldDonating,
            address(7)
        );

        if (address(aaveFactory) != address(0)) {
            assertEq(
                aaveFactory.AAVE_ADDRESSES_PROVIDER(),
                0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e,
                "AaveFactory: wrong AAVE_ADDRESSES_PROVIDER"
            );
            assertEq(aaveFactory.USDC(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "AaveFactory: wrong USDC");
        }

        // AddressSetFactory: predictAddress returns non-zero
        address predicted = addressSetFactory.predictAddress(bytes32(uint256(1)), address(this));
        assertTrue(predicted != address(0), "AddressSetFactory: zero predicted address");

        // RegenEarningPowerCalculatorFactory: predictAddress returns non-zero
        address calcPredicted = calculatorFactory.predictAddress(
            bytes32(uint256(1)),
            address(this),
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );
        assertTrue(calcPredicted != address(0), "CalcFactory: zero predicted address");

        // RegenStakerFactory: canonical bytecode hashes match pinned bytecodes
        assertEq(
            regenStakerFactory.canonicalBytecodeHash(RegenStakerFactory.RegenStakerVariant.WITH_DELEGATION),
            keccak256(REGEN_STAKER_V1_CREATION_CODE),
            "StakerFactory: WITH_DELEGATION hash does not match pinned bytecode"
        );
        assertEq(
            regenStakerFactory.canonicalBytecodeHash(RegenStakerFactory.RegenStakerVariant.WITHOUT_DELEGATION),
            keccak256(REGEN_STAKER_WITHOUT_DELEGATION_V1_CREATION_CODE),
            "StakerFactory: WITHOUT_DELEGATION hash does not match pinned bytecode"
        );
    }

    // -----------------------------------------------------------------------
    // Test 3: AllowSet ownership and initial state
    // -----------------------------------------------------------------------

    function test_allowSetOwnership() public view {
        assertEq(allowSet.owner(), _safe, "AllowSet: owner is not Safe");
        assertEq(allowSet.length(), 0, "AllowSet: should be empty on fresh deploy");
    }

    // -----------------------------------------------------------------------
    // Test 4: AllowSet add/remove functionality
    // -----------------------------------------------------------------------

    function test_allowSetFunctionality() public {
        address testAddr = makeAddr("allowSetTest");

        vm.prank(_safe);
        allowSet.add(testAddr);
        assertTrue(allowSet.contains(testAddr), "AllowSet: address not found after add");
        assertEq(allowSet.length(), 1, "AllowSet: length should be 1 after add");

        vm.prank(_safe);
        allowSet.remove(testAddr);
        assertFalse(allowSet.contains(testAddr), "AllowSet: address found after remove");
        assertEq(allowSet.length(), 0, "AllowSet: length should be 0 after remove");

        vm.prank(testUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, testUser));
        allowSet.add(testAddr);
    }

    // -----------------------------------------------------------------------
    // Test 5: AddressSetFactory determinism (all 3 AddressSets match predictions)
    // -----------------------------------------------------------------------

    function test_addressSetFactoryDeterminism() public view {
        assertEq(
            addressSetFactory.predictAddress(_allocationMechanismAllowsetSalt, _safe),
            address(allowSet),
            "AddressSetFactory: prediction mismatch for allocationMechanismAllowset"
        );

        assertEq(
            addressSetFactory.predictAddress(_stakerAllowsetSalt, _safe),
            address(stakerAllowset),
            "AddressSetFactory: prediction mismatch for stakerAllowset"
        );

        assertEq(
            addressSetFactory.predictAddress(_stakerBlocksetSalt, _safe),
            address(stakerBlockset),
            "AddressSetFactory: prediction mismatch for stakerBlockset"
        );

        assertTrue(address(allowSet) != address(stakerAllowset), "allowSet == stakerAllowset");
        assertTrue(address(allowSet) != address(stakerBlockset), "allowSet == stakerBlockset");
        assertTrue(address(stakerAllowset) != address(stakerBlockset), "stakerAllowset == stakerBlockset");
    }

    // -----------------------------------------------------------------------
    // Test 6: Staker AddressSet ownership and initial state
    // -----------------------------------------------------------------------

    function test_stakerAddressSetsOwnership() public view {
        assertEq(stakerAllowset.owner(), _safe, "stakerAllowset: owner is not Safe");
        assertEq(stakerAllowset.length(), 0, "stakerAllowset: should be empty on fresh deploy");
        assertEq(stakerBlockset.owner(), _safe, "stakerBlockset: owner is not Safe");
        assertEq(stakerBlockset.length(), 0, "stakerBlockset: should be empty on fresh deploy");
    }

    // -----------------------------------------------------------------------
    // Test 7: Calculator parameters
    // -----------------------------------------------------------------------

    function test_calculatorParameters() public view {
        assertEq(calculator.owner(), _safe, "Calculator: owner is not Safe");
        assertTrue(calculator.accessMode() == AccessMode.NONE, "Calculator: accessMode should be NONE");
        assertEq(address(calculator.allowset()), address(0), "Calculator: allowset should be zero");
        assertEq(address(calculator.blockset()), address(0), "Calculator: blockset should be zero");
    }

    // -----------------------------------------------------------------------
    // Test 8: Calculator earning power computation
    // -----------------------------------------------------------------------

    function test_calculatorEarningPower() public view {
        address user = address(0xBEEF);
        uint256 stakeAmount = 1000e18;

        uint256 ep = calculator.getEarningPower(stakeAmount, user, user);
        assertEq(ep, stakeAmount, "Calculator: earning power should equal staked amount in NONE mode");

        (uint256 newEP, bool qualifies) = calculator.getNewEarningPower(stakeAmount, user, user, 500e18);
        assertEq(newEP, stakeAmount, "Calculator: newEarningPower mismatch");
        assertTrue(qualifies, "Calculator: should qualify for bump when EP changed");

        (uint256 sameEP, bool noBump) = calculator.getNewEarningPower(stakeAmount, user, user, stakeAmount);
        assertEq(sameEP, stakeAmount, "Calculator: sameEarningPower mismatch");
        assertFalse(noBump, "Calculator: should not qualify for bump when EP unchanged");
    }

    // -----------------------------------------------------------------------
    // Test 9: Staker parameters
    // -----------------------------------------------------------------------

    function test_stakerParameters() public view {
        assertEq(address(staker.REWARD_TOKEN()), WETH, "Staker: wrong REWARD_TOKEN");
        assertEq(address(staker.STAKE_TOKEN()), GLM, "Staker: wrong STAKE_TOKEN");
        assertEq(staker.admin(), _safe, "Staker: admin is not Safe");
        assertEq(staker.maxBumpTip(), MAX_BUMP_TIP, "Staker: wrong maxBumpTip");
        assertEq(staker.rewardDuration(), REWARD_DURATION, "Staker: wrong rewardDuration");
        assertEq(staker.minimumStakeAmount(), MINIMUM_STAKE, "Staker: minimumStakeAmount should be 0");
        assertEq(address(staker.earningPowerCalculator()), address(calculator), "Staker: wrong earningPowerCalculator");
        assertEq(
            address(staker.allocationMechanismAllowset()),
            address(allowSet),
            "Staker: wrong allocationMechanismAllowset"
        );
        assertEq(
            address(staker.stakerAllowset()),
            address(stakerAllowset),
            "Staker: stakerAllowset not wired correctly"
        );
        assertEq(
            address(staker.stakerBlockset()),
            address(stakerBlockset),
            "Staker: stakerBlockset not wired correctly"
        );
        assertTrue(staker.stakerAccessMode() == AccessMode.NONE, "Staker: stakerAccessMode should be NONE");
        assertEq(staker.totalStaked(), 0, "Staker: totalStaked should be 0");
        assertEq(staker.totalEarningPower(), 0, "Staker: totalEarningPower should be 0");
    }

    // -----------------------------------------------------------------------
    // Test 10: Staker stake and withdraw cycle
    // -----------------------------------------------------------------------

    function test_stakerStakeAndWithdraw() public {
        uint256 amount = 100e18;

        deal(GLM, testUser, amount);

        vm.startPrank(testUser);
        IERC20(GLM).approve(address(staker), amount);
        Staker.DepositIdentifier depositId = staker.stake(amount, address(staker));
        vm.stopPrank();

        assertEq(staker.totalStaked(), amount, "Staker: totalStaked mismatch after stake");
        assertEq(staker.depositorTotalStaked(testUser), amount, "Staker: depositorTotalStaked mismatch");

        vm.prank(testUser);
        staker.withdraw(depositId, amount);

        assertEq(staker.totalStaked(), 0, "Staker: totalStaked should be 0 after withdraw");
        assertEq(IERC20(GLM).balanceOf(testUser), amount, "Staker: GLM not returned to user");
    }

    // -----------------------------------------------------------------------
    // Test 11: Cross-contract integration (stake -> earning power via calculator)
    // -----------------------------------------------------------------------

    function test_crossContractIntegration() public {
        uint256 amount = 500e18;

        deal(GLM, testUser, amount);
        vm.startPrank(testUser);
        IERC20(GLM).approve(address(staker), amount);
        Staker.DepositIdentifier depositId = staker.stake(amount, address(staker));
        vm.stopPrank();

        (uint96 balance, , uint96 earningPower, , , , ) = staker.deposits(depositId);

        assertEq(uint256(balance), amount, "Deposit: balance mismatch");
        assertEq(uint256(earningPower), amount, "Deposit: earningPower should equal staked amount in NONE mode");
        assertEq(staker.totalEarningPower(), amount, "Staker: totalEarningPower should equal staked amount");

        vm.prank(testUser);
        staker.withdraw(depositId, amount);
    }
}
