// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { TestPlus } from "solady-test/utils/TestPlus.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { Safe } from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import { SafeProxy } from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import { SafeProxyFactory } from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { Enum } from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { Hats } from "hats-protocol/Hats.sol";
import { DragonHatter } from "src/utils/hats/DragonHatter.sol";
import { SimpleEligibilityAndToggle } from "src/utils/hats/SimpleEligibilityAndToggle.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { LibString } from "solady/utils/LibString.sol";

import { TokenizedStrategy__StrategyNotInShutdown, TokenizedStrategy__NotEmergencyAuthorized, TokenizedStrategy__HatsAlreadyInitialized, TokenizedStrategy__NotKeeperOrManagement, TokenizedStrategy__NotManagement } from "src/errors.sol";

contract SetupIntegrationTest is Test, TestPlus {
    uint256 constant TEST_THRESHOLD = 3;
    uint256 constant TEST_TOTAL_OWNERS = 5;
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    mapping(uint256 => uint256) public testPrivateKeys;
    address public deployer;
    /// ============ DeploySafe ===========================
    uint256 public threshold;
    uint256 public totalOwners;
    address[] public owners;
    address public safeSingleton;
    address public safeProxyFactory;
    Safe public deployedSafe;
    /// ===================================================

    /// ========== DeployDragonTokenizedStrategy ==========
    DragonTokenizedStrategy public dragonTokenizedStrategySingleton;
    /// ===================================================

    /// ============ DeploySplitChecker ==================
    SplitChecker public splitCheckerSingleton;
    SplitChecker public splitCheckerProxy;
    /// ===================================================

    /// ============ DeployDragonRouter ==================
    address public dragonRouterSingleton;
    address public dragonRouterProxy;
    /// ===================================================

    /// ============ DeployModuleProxyFactory ============
    ModuleProxyFactory public moduleProxyFactory;
    /// ===================================================

    /// ============ DeployHatsProtocol ===================
    Hats public HATS;
    DragonHatter public dragonHatter;
    SimpleEligibilityAndToggle public simpleEligibilityAndToggle;
    uint256 public topHatId;
    uint256 public autonomousAdminHatId;
    uint256 public dragonAdminHatId;
    uint256 public branchHatId;
    /// ===================================================

    /// ============ DeployMockStrategy ===================
    MockStrategy public mockStrategySingleton;
    IMockStrategy public mockStrategyProxy;
    MockYieldSource public mockYieldSource;
    MockERC20 public token;
    address public safeAddress;
    address public dragonTokenizedStrategyAddress;
    address public dragonRouterProxyAddress;

    /// ===================================================

    function addLabels() internal {
        vm.label(SAFE_SINGLETON, "Safe Singleton");
        vm.label(SAFE_PROXY_FACTORY, "Safe Proxy Factory");
        vm.label(address(deployedSafe), "Safe Proxy");
        vm.label(address(dragonTokenizedStrategySingleton), "DragonTokenizedStrategy Implementation");
        vm.label(address(splitCheckerSingleton), "SplitChecker Implementation");
        vm.label(address(splitCheckerProxy), "SplitChecker Proxy");
        vm.label(address(dragonRouterSingleton), "DragonRouter Implementation");
        vm.label(address(dragonRouterProxy), "DragonRouter Proxy");
        vm.label(address(moduleProxyFactory), "ModuleProxyFactory");
        //loop over owners
        for (uint256 i = 0; i < TEST_TOTAL_OWNERS; i++) {
            vm.label(owners[i], string.concat("Owner ", vm.toString(i + 1)));
        }
        vm.label(address(token), "Test Token");

        // Add Hats Protocol labels
        vm.label(address(HATS), "Hats Protocol");
        vm.label(address(dragonHatter), "Dragon Hatter");
        vm.label(address(simpleEligibilityAndToggle), "SimpleEligibilityAndToggle");

        // Add Mock Strategy labels
        vm.label(address(mockStrategySingleton), "MockStrategy Implementation");
        vm.label(address(mockStrategyProxy), "MockStrategy Proxy");
        vm.label(address(mockYieldSource), "MockYieldSource");
    }

    // Add constants for Hats protocol setup
    string public constant BASE_IMAGE_URI = "https://www.images.hats.work/";
    string public constant PROTOCOL_NAME = "Dragon Protocol Hats";
    uint32 public constant DEFAULT_MAX_SUPPLY = 5;
    uint256 public constant DEFAULT_THRESHOLD = 5;
    uint256 public constant DEFAULT_TOTAL_OWNERS = 9;

    using LibString for uint256;
    using LibString for address;

    function deploy() public {
        // Deploy everything as the current msg.sender (should be the deployer from setUp)

        // Deploy Safe first as it will be the admin
        _deploySafe();

        // Deploy Hats Protocol and setup roles
        _deployHatsProtocol();

        // Deploy remaining components
        _deployDragonTokenizedStrategy();
        _deployDragonRouter();

        // Deploy mock strategy
        _deployMockStrategy(safeAddress, dragonTokenizedStrategyAddress, dragonRouterProxyAddress);
    }

    // Modified implementation that skips broadcasting
    function _deploySafe() internal {
        // The caller should have already started a prank as the deployer

        // Use setup from test parameters
        uint256 configuredThreshold = TEST_THRESHOLD;
        uint256 configuredTotalOwners = TEST_TOTAL_OWNERS;

        // Check if owners are already set up
        if (owners.length == 0) {
            // Generate owner addresses from environment or use test owners
            address[] memory _owners = new address[](configuredTotalOwners);
            _owners = _createTestOwners(configuredTotalOwners);
            // Set up parameters
            safeSingleton = SAFE_SINGLETON;
            safeProxyFactory = SAFE_PROXY_FACTORY;
            threshold = configuredThreshold;
            totalOwners = configuredTotalOwners;

            // Clear and set owners
            delete owners;
            for (uint256 i = 0; i < _owners.length; i++) {
                owners.push(_owners[i]);
            }
        }

        // Generate initialization data directly
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            address(0), // No module
            bytes(""), // Empty setup data
            address(0), // No fallback handler
            address(0), // No payment token
            0, // No payment
            address(0) // No payment receiver
        );

        // Deploy new Safe via factory
        SafeProxyFactory factory = SafeProxyFactory(safeProxyFactory);
        SafeProxy proxy = factory.createProxyWithNonce(
            safeSingleton,
            initializer,
            block.timestamp // Use timestamp as salt
        );

        // Store deployed Safe
        deployedSafe = Safe(payable(address(proxy)));

        // Make sure we save the address for the mock strategy deployment
        safeAddress = address(deployedSafe);
    }

    // Modified implementation that skips broadcasting
    function _deployHatsProtocol() internal {
        // 1. Deploy Hats protocol
        HATS = new Hats(PROTOCOL_NAME, BASE_IMAGE_URI);

        // 2. Create TopHat (1) and mint to deployer
        topHatId = HATS.mintTopHat(deployer, "Dragon Protocol Top Hat", string.concat(BASE_IMAGE_URI, "tophat"));

        // Deploy simple eligibility and toggle module
        simpleEligibilityAndToggle = new SimpleEligibilityAndToggle();

        // 3. Create Autonomous Admin Hat (1.1)
        autonomousAdminHatId = HATS.createHat(
            topHatId,
            "Dragon Protocol Autonomous Admin",
            DEFAULT_MAX_SUPPLY,
            address(simpleEligibilityAndToggle),
            address(simpleEligibilityAndToggle),
            true,
            string.concat(BASE_IMAGE_URI, "autonomous")
        );

        // 4. Create Dragon Admin Hat (1.1.1)
        dragonAdminHatId = HATS.createHat(
            autonomousAdminHatId,
            "Dragon Protocol Admin",
            DEFAULT_MAX_SUPPLY,
            address(simpleEligibilityAndToggle),
            address(simpleEligibilityAndToggle),
            true,
            string.concat(BASE_IMAGE_URI, "dragon-admin")
        );

        // Mint Dragon Admin hat to deployer
        HATS.mintHat(dragonAdminHatId, deployer);

        // Create branch hat with proper admin rights
        branchHatId = HATS.createHat(
            dragonAdminHatId,
            "Dragon Protocol Vault Management",
            DEFAULT_MAX_SUPPLY,
            address(simpleEligibilityAndToggle),
            address(simpleEligibilityAndToggle),
            true,
            ""
        );

        // Deploy DragonHatter with branch hat ID
        dragonHatter = new DragonHatter(address(HATS), dragonAdminHatId, branchHatId);

        // Mint branch hat to DragonHatter
        HATS.mintHat(branchHatId, address(dragonHatter));

        // Initialize roles
        dragonHatter.initialize();

        // Grant roles to deployer using DragonHatter's grantRole function
        dragonHatter.grantRole(dragonHatter.KEEPER_ROLE(), deployer);
        dragonHatter.grantRole(dragonHatter.MANAGEMENT_ROLE(), deployer);
        dragonHatter.grantRole(dragonHatter.EMERGENCY_ROLE(), deployer);
        dragonHatter.grantRole(dragonHatter.REGEN_GOVERNANCE_ROLE(), deployer);

        vm.label(address(dragonHatter), "DragonHatter");
        vm.label(address(simpleEligibilityAndToggle), "SimpleEligibilityAndToggle");
        vm.label(deployer, "Deployer");
    }

    // Modified implementation that skips broadcasting
    function _deployDragonTokenizedStrategy() internal {
        // The caller should start prank with the right deployer account

        // Deploy DragonTokenizedStrategy implementation
        dragonTokenizedStrategySingleton = new DragonTokenizedStrategy();

        // Make sure we save the address for the mock strategy deployment
        dragonTokenizedStrategyAddress = address(dragonTokenizedStrategySingleton);
    }

    // Modified implementation that skips broadcasting
    function _deployDragonRouter() internal {
        // Deploy module proxy factory if not already deployed
        if (address(moduleProxyFactory) == address(0)) {
            _deployModuleProxyFactory();
        }

        // DragonRouter contract removed; use placeholder addresses for tests
        dragonRouterSingleton = makeAddr("dragonRouterImplementation");
        dragonRouterProxy = makeAddr("dragonRouterProxy");
        dragonRouterProxyAddress = dragonRouterProxy;

        // Deploy SplitChecker implementation
        splitCheckerSingleton = new SplitChecker();

        // Initialize SplitChecker first
        bytes memory initSplitCheckerData = abi.encodeWithSignature(
            "initialize(address,uint256,uint256)",
            deployer, // governance
            0.2e18, // maxOpexSplit (20%)
            0.5e18 // minMetapoolSplit (50%)
        );

        address splitCheckerProxyAddr = moduleProxyFactory.deployModule(
            address(splitCheckerSingleton),
            initSplitCheckerData,
            block.timestamp
        );

        splitCheckerProxy = SplitChecker(payable(splitCheckerProxyAddr));
    }

    // Modified implementation that skips broadcasting
    function _deployModuleProxyFactory() internal {
        address governance = msg.sender;
        address regenGovernance = msg.sender;
        address splitCheckerImplementation = address(new SplitChecker());
        address metapool = msg.sender;
        address dragonRouterImplementation = makeAddr("dragonRouterImplementation");
        moduleProxyFactory = new ModuleProxyFactory(
            governance,
            regenGovernance,
            metapool,
            splitCheckerImplementation,
            dragonRouterImplementation
        );
    }

    // Modified implementation that skips broadcasting
    function _deployMockStrategy(
        address _safeAddress,
        address _dragonTokenizedStrategyAddress,
        address _dragonRouterProxyAddress
    ) internal {
        // Store addresses in storage
        safeAddress = _safeAddress;
        dragonTokenizedStrategyAddress = _dragonTokenizedStrategyAddress;
        dragonRouterProxyAddress = _dragonRouterProxyAddress;

        // Deploy test token
        token = new MockERC20(18);

        // Deploy implementation
        mockStrategySingleton = new MockStrategy();

        // Deploy mock yield source
        mockYieldSource = new MockYieldSource(address(token));

        uint256 _maxReportDelay = 1 days;
        string memory _name = "Mock Dragon Strategy";

        // Prepare initialization data
        bytes memory strategyParams = abi.encode(
            dragonTokenizedStrategyAddress,
            address(token),
            address(mockYieldSource),
            safeAddress, // management
            safeAddress, // keeper
            dragonRouterProxyAddress,
            _maxReportDelay, // maxReportDelay
            _name,
            safeAddress // regenGovernance
        );

        bytes memory initData = abi.encodeWithSignature("setUp(bytes)", abi.encode(safeAddress, strategyParams));

        // Deploy and enable module on safe
        address proxy = moduleProxyFactory.deployModule(address(mockStrategySingleton), initData, block.timestamp);

        console2.log("MockStrategy Proxy Address:", address(proxy));
        mockStrategyProxy = IMockStrategy(payable(address(proxy)));

        // Enable the module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(mockStrategyProxy));

        // Execute the enableModule transaction through the Safe
        // First sign with required number of owners
        owners = deployedSafe.getOwners();
        bytes32 txHash = deployedSafe.getTransactionHash(
            safeAddress, // to
            0, // value
            enableModuleData, // data
            Enum.Operation.Call, // operation
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            deployedSafe.nonce() // nonce
        );

        // Collect signatures from the first TEST_THRESHOLD owners
        bytes memory signatures;
        for (uint256 i = 0; i < TEST_THRESHOLD; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(testPrivateKeys[i], txHash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }

        // Execute transaction
        bool success = deployedSafe.execTransaction(
            safeAddress, // to
            0, // value
            enableModuleData, // data
            Enum.Operation.Call, // operation
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures // signatures
        );

        require(success, "Failed to enable module");

        // Verify the module was enabled
        require(deployedSafe.isModuleEnabled(address(mockStrategyProxy)), "Module not enabled");
    }

    function setUp() public virtual {
        // Fork mainnet
        vm.createSelectFork(vm.envString("TEST_RPC_URL"));

        // Generate a new private key using Anvil's createKey cheatcode
        (address _deployer, uint256 deployerPrivateKey) = makeAddrAndKey("deployer");
        deployer = _deployer;

        // Remember the key so we can use it in prank mode
        vm.rememberKey(deployerPrivateKey);

        // Set ourselves as the deployer and run deployment
        vm.startPrank(deployer);
        deploy();

        // Add labels
        addLabels();

        // Verify deployment
        require(address(deployedSafe) != address(0), "Safe not deployed");
        require(deployedSafe.getThreshold() == TEST_THRESHOLD, "Invalid threshold");
        require(deployedSafe.getOwners().length == TEST_TOTAL_OWNERS, "Invalid number of owners");
        require(address(dragonTokenizedStrategySingleton) != address(0), "Strategy not deployed");
        require(address(moduleProxyFactory) != address(0), "ModuleProxyFactory not deployed");
        require(address(dragonRouterSingleton) != address(0), "DragonRouter implementation not deployed");
        require(address(dragonRouterProxy) != address(0), "DragonRouter proxy not deployed");
        require(address(splitCheckerSingleton) != address(0), "SplitChecker not deployed");
        require(address(HATS) != address(0), "Hats Protocol not deployed");
        require(address(dragonHatter) != address(0), "DragonHatter not deployed");

        // End the prank
        vm.stopPrank();
    }

    /**
     * @notice Creates an array of test owner addresses and stores their private keys
     * @dev Creates deterministic addresses based on a fixed seed
     *      and sorts them in ascending order
     * @return _owners Array of owner addresses for Safe setup
     */
    function _createTestOwners(uint256 _totalOwners) internal returns (address[] memory _owners) {
        _owners = new address[](_totalOwners);
        uint256[] memory privateKeys = new uint256[](_totalOwners);

        // Generate all owners first
        for (uint256 i = 0; i < _totalOwners; i++) {
            // Create a deterministic signer with its private key
            // Use a different seed for each owner to ensure uniqueness
            bytes32 seed = keccak256(abi.encodePacked("owner", i, block.timestamp));
            uint256 privateKey = uint256(seed);

            // Make sure the private key is valid (less than curve order)
            privateKey = privateKey % 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
            if (privateKey == 0) privateKey = 1;

            address owner = vm.addr(privateKey);
            _owners[i] = owner;
            privateKeys[i] = privateKey;
        }

        // Sort owners and private keys together (bubble sort)
        for (uint256 i = 0; i < _totalOwners - 1; i++) {
            for (uint256 j = 0; j < _totalOwners - i - 1; j++) {
                if (uint160(_owners[j]) > uint160(_owners[j + 1])) {
                    // Swap owners
                    address tempAddr = _owners[j];
                    _owners[j] = _owners[j + 1];
                    _owners[j + 1] = tempAddr;

                    // Swap corresponding private keys
                    uint256 tempKey = privateKeys[j];
                    privateKeys[j] = privateKeys[j + 1];
                    privateKeys[j + 1] = tempKey;
                }
            }
        }

        // Store sorted private keys
        for (uint256 i = 0; i < _totalOwners; i++) {
            testPrivateKeys[i] = privateKeys[i];
            vm.rememberKey(privateKeys[i]);
        }
    }

    /**
     * @notice Execute a transaction through the Safe with direct signing
     * @dev Uses pre-sorted signer indices to generate signatures in ascending order
     */
    function execTransaction(address to, uint256 value, bytes memory data, uint256[] memory signerIndices) public {
        require(address(deployedSafe) != address(0), "Safe not deployed");
        require(signerIndices.length >= TEST_THRESHOLD, "Not enough signers");

        // Prepare transaction data
        bytes32 txHash = deployedSafe.getTransactionHash(
            to,
            value,
            data,
            Enum.Operation.Call,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            deployedSafe.nonce()
        );

        // Collect signatures using pre-sorted indices
        bytes memory signatures = new bytes(signerIndices.length * 65);
        uint256 pos = 0;
        // log all the owner public keys
        for (uint256 i = 0; i < TEST_TOTAL_OWNERS; i++) {
            // check they are all owners of the safe
            require(deployedSafe.isOwner(owners[i]), "Owner not owner of safe");
        }

        for (uint256 i = 0; i < signerIndices.length; i++) {
            uint256 ownerSk = testPrivateKeys[signerIndices[i]];
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerSk, txHash);

            assembly {
                mstore(add(signatures, add(pos, 32)), r)
                mstore(add(signatures, add(pos, 64)), s)
                mstore8(add(signatures, add(pos, 96)), v)
            }
            pos += 65;
        }
        vm.startBroadcast(testPrivateKeys[0]);
        // Execute transaction
        bool success = deployedSafe.execTransaction(
            to,
            value,
            data,
            Enum.Operation.Call,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );
        vm.stopBroadcast();
        require(success, "Transaction execution failed");
    }
}
