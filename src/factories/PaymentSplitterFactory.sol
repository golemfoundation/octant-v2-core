/* solhint-disable gas-custom-errors*/
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { PaymentSplitter } from "src/core/PaymentSplitter.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title PaymentSplitter Factory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deploying PaymentSplitter instances as minimal proxies
 * @dev Uses OpenZeppelin Clones (ERC-1167) for gas-efficient deployments
 *
 *      DEPLOYMENT PATTERN:
 *      - Minimal proxy (EIP-1167): ~50k gas vs ~300k for full deployment
 *      - All splitters delegate to single implementation
 *      - Each deployment tracked for deployer
 *
 *      FEATURES:
 *      - Deterministic addresses via CREATE2
 *      - Deployment tracking per deployer
 *      - Payee name labels for identification
 *      - Sweep function for rescue operations
 */
contract PaymentSplitterFactory {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Information about a deployed payment splitter
     * @dev Stored for each deployer to track their splitters
     */
    struct SplitterInfo {
        /// @notice Address of the deployed splitter contract
        address splitterAddress;
        /// @notice Array of payee addresses
        address[] payees;
        /// @notice Human-readable names for each payee
        /// @dev e.g., "GrantRoundOperator", "ESF", "OpEx"
        string[] payeeNames;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Address of the PaymentSplitter implementation
    /// @dev All deployed proxies delegate to this implementation
    address public immutable implementation;

    /// @notice Factory owner authorized to sweep accidentally sent funds
    /// @dev Set to deployer in constructor
    address public immutable owner;

    /// @notice Mapping of deployers to their deployed splitters
    /// @dev Allows tracking and enumeration of splitters per deployer
    mapping(address => SplitterInfo[]) public deployerToSplitters;

    /// @notice Emitted when a new PaymentSplitter is created
    event PaymentSplitterCreated(
        address indexed deployer,
        address indexed paymentSplitter,
        address[] payees,
        string[] payeeNames,
        uint256[] shares
    );

    /**
     * @notice Deploys the factory and PaymentSplitter implementation
     * @dev Deploys implementation contract used as base for all minimal proxies
     */
    constructor() {
        // Deploy the implementation contract
        implementation = address(new PaymentSplitter());
        owner = msg.sender;
    }

    /// @notice Restricts function access to factory owner
    modifier onlyOwner() {
        require(msg.sender == owner, "PaymentSplitterFactory: not owner");
        _;
    }

    /**
     * @notice Creates a new PaymentSplitter instance with specified payees and shares
     * @dev Uses CREATE2 for deterministic deployment
     *      Deploys as minimal proxy to save gas (~50k vs ~300k)
     * @param payees Addresses of payees to receive payments
     * @param payeeNames Names for each payee (e.g., "GrantRoundOperator", "ESF", "OpEx")
     * @param shares Number of shares assigned to each payee
     * @return paymentSplitter Address of newly created PaymentSplitter
     */
    function createPaymentSplitter(
        address[] memory payees,
        string[] memory payeeNames,
        uint256[] memory shares
    ) external returns (address) {
        require(
            payees.length == payeeNames.length && payees.length == shares.length,
            "PaymentSplitterFactory: length mismatch"
        );

        // Generate deterministic salt combining user input with sender and deployment count
        bytes32 finalSalt = keccak256(abi.encode(msg.sender, deployerToSplitters[msg.sender].length));

        // Create a deterministic minimal proxy
        address paymentSplitter = Clones.cloneDeterministic(implementation, finalSalt);

        // Initialize the proxy; revert with a factory-specific error if initialization fails
        bytes memory initData = abi.encodeWithSelector(PaymentSplitter.initialize.selector, payees, shares);
        (bool success, ) = paymentSplitter.call(initData);
        require(success, "PaymentSplitterFactory: initialization failed");

        // Store the deployed splitter info
        deployerToSplitters[msg.sender].push(SplitterInfo(paymentSplitter, payees, payeeNames));

        // Emit event for tracking
        emit PaymentSplitterCreated(msg.sender, paymentSplitter, payees, payeeNames, shares);

        return paymentSplitter;
    }

    /**
     * @notice Creates a new PaymentSplitter and funds it with ETH
     * @dev Uses CREATE2 for deterministic deployment with value
     *      Deploys as minimal proxy to save gas (~50k vs ~300k)
     *      Forwards msg.value to the new splitter contract
     * @param payees Addresses of payees to receive payments
     * @param payeeNames Names for each payee (e.g., "GrantRoundOperator", "ESF", "OpEx")
     * @param shares Number of shares assigned to each payee
     * @return paymentSplitter Address of newly created PaymentSplitter
     */
    function createPaymentSplitterWithETH(
        address[] memory payees,
        string[] memory payeeNames,
        uint256[] memory shares
    ) external payable returns (address) {
        require(
            payees.length == payeeNames.length && payees.length == shares.length,
            "PaymentSplitterFactory: length mismatch"
        );

        // Generate deterministic salt combining user input with sender and deployment count
        bytes32 finalSalt = keccak256(abi.encode(msg.sender, deployerToSplitters[msg.sender].length));

        // Create a deterministic minimal proxy with value
        address paymentSplitter = Clones.cloneDeterministic(implementation, finalSalt, msg.value);

        // Initialize the proxy; revert with a factory-specific error if initialization fails
        bytes memory initData = abi.encodeWithSelector(PaymentSplitter.initialize.selector, payees, shares);
        (bool success, ) = paymentSplitter.call(initData);
        require(success, "PaymentSplitterFactory: initialization failed");

        // Store the deployed splitter info
        deployerToSplitters[msg.sender].push(SplitterInfo(paymentSplitter, payees, payeeNames));

        // Emit event for tracking
        emit PaymentSplitterCreated(msg.sender, paymentSplitter, payees, payeeNames, shares);

        return paymentSplitter;
    }

    /**
     * @notice Sweep any ETH accidentally sent to this factory
     * @dev Should normally be zero since ETH forwards to clones at creation
     * @param recipient Address to receive swept ETH
     * @custom:security Only owner can sweep
     */
    function sweep(address payable recipient) external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "PaymentSplitterFactory: no ETH to sweep");
        (bool success, ) = recipient.call{ value: balance }("");
        require(success, "PaymentSplitterFactory: sweep failed");
    }

    /**
     * @notice Returns all payment splitters created by a specific deployer
     * @dev May be expensive for deployers with many splitters
     * @return splitters Array of deployed splitters with payee info
     */
    function getSplittersByDeployer(address deployer) external view returns (SplitterInfo[] memory) {
        return deployerToSplitters[deployer];
    }

    /**
     * @notice Predicts the address of a deterministic clone for a deployer
     * @dev Uses CREATE2 based on deployer address and deployment count
     * @return predicted Predicted address of next deployment
     */
    function predictDeterministicAddress(address deployer) external view returns (address) {
        bytes32 finalSalt = keccak256(abi.encode(deployer, deployerToSplitters[deployer].length));
        return Clones.predictDeterministicAddress(implementation, finalSalt);
    }
}
