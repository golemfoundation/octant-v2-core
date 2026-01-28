// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Module } from "zodiac/core/Module.sol";

import { BaseStrategy } from "src/zodiac-core/BaseStrategy.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

/**
 * @title Dragon Base Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract base for strategies integrated with the Dragon Router and TokenizedStrategy.
 * @dev This contract follows a Yearn V3-style pattern where the proxy strategy delegates
 *      calls to a shared `TokenizedStrategy` implementation via a fallback `delegatecall`.
 *      It wires up core lifecycle hooks (harvest, adjust, liquidate) and provides
 *      initialization that sets the implementation address and strategy metadata.
 */
abstract contract DragonBaseStrategy is BaseStrategy, Module {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Address of the shared TokenizedStrategy implementation used via delegatecall
     * @dev All strategy logic and storage live in the implementation contract; this
     *      contract acts as a thin proxy router for strategy-specific overrides.
     *      The address should be identical across all strategies using this base.
     */
    address public tokenizedStrategyImplementation;

    /// @notice Maximum allowed time between harvest reports (seconds)
    uint256 public maxReportDelay;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Receive native ETH (used by strategies dealing with NATIVE_TOKEN)
    receive() external payable {}

    /**
     * @notice Delegates unknown calls to the TokenizedStrategy implementation
     * @dev Copies calldata, performs `delegatecall` to `tokenizedStrategyImplementation`, and
     *      returns or bubbles up errors. Includes a small guard to reject plain ETH sends.
     *      Uses memory-safe inline assembly; review carefully when changing.
     */
    fallback() external payable {
        assembly ("memory-safe") {
            if and(iszero(calldatasize()), not(iszero(callvalue()))) {
                return(0, 0)
            }
        }
        address _tokenizedStrategyAddress = tokenizedStrategyImplementation;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), _tokenizedStrategyAddress, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /// @notice Liquidate strategy assets to fulfill `_amountNeeded`
    /// @dev To be implemented by concrete strategies. Called by management
    /// @param _amountNeeded Amount to liquidate in asset base units
    /// @return _liquidatedAmount Actual liquidated amount in asset base units
    /// @return _loss Realized loss if any in asset base units
    function liquidatePosition(
        uint256 _amountNeeded
    ) external virtual onlyManagement returns (uint256 _liquidatedAmount, uint256 _loss) {}

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Adjust core position based on outstanding debt target
    /// @param _debtOutstanding Amount to adjust towards (asset base units)
    function adjustPosition(uint256 _debtOutstanding) external virtual onlyManagement {}

    /*//////////////////////////////////////////////////////////////
                        TokenizedStrategy HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Signal to keeper whether `report()` should be called
     * @return timeToReport True if time since last report >= `maxReportDelay` and assets > 0
     */
    function harvestTrigger() external view virtual returns (bool timeToReport) {
        // Should not trigger if strategy is not active (no assets) or harvest has been recently called.
        if (
            TokenizedStrategy.totalAssets() != 0 && (block.timestamp - TokenizedStrategy.lastReport()) >= maxReportDelay
        ) return true;
    }

    /**
     * @notice Initialize the strategy and bind to the TokenizedStrategy implementation
     * @dev Sets implementation address, strategy metadata, and delegates TokenizedStrategy.initialize.
     * @param _tokenizedStrategyImplementation Address of the TokenizedStrategy implementation
     * @param _asset Address of the underlying ERC20 asset
     * @param _owner Address that will own the strategy (admin)
     * @param _management Address with management privileges
     * @param _keeper Address of keeper authorized to perform upkeep
     * @param _dragonRouter Address of the Dragon Router (loss protection integration)
     * @param _maxReportDelay Maximum time between reports (seconds)
     * @param _name ERC20 name for the strategy
     * @param _regenGovernance Address of Regen governance (if applicable)
     */
    function __BaseStrategy_init(
        address _tokenizedStrategyImplementation,
        address _asset,
        address _owner,
        address _management,
        address _keeper,
        address _dragonRouter,
        uint256 _maxReportDelay,
        string memory _name,
        address _regenGovernance
    ) internal onlyInitializing {
        tokenizedStrategyImplementation = _tokenizedStrategyImplementation;
        asset = ERC20(_asset);
        maxReportDelay = _maxReportDelay;

        TokenizedStrategy = ITokenizedStrategy(address(this));

        _delegateCall(
            abi.encodeCall(
                ITokenizedStrategy.initialize,
                (_asset, _name, _owner, _management, _keeper, _dragonRouter, _regenGovernance)
            )
        );

        // Store at EIP-1967 implementation slot for Etherscan interface detection
        // (stored on initialization and never updated)
        assembly ("memory-safe") {
            sstore(
                // keccak256('eip1967.proxy.implementation' - 1)
                0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc,
                _tokenizedStrategyImplementation
            )
        }
    }

    /**
     * @notice Internal helper to delegatecall into the TokenizedStrategy
     * @dev Reverts bubbling up the exact reason on failure.
     * @param _calldata ABI-encoded call data for the implementation
     * @return result Raw return data from the delegated call
     */
    function _delegateCall(bytes memory _calldata) internal returns (bytes memory) {
        //slither-disable-next-line controlled-delegatecall
        (bool success, bytes memory result) = tokenizedStrategyImplementation.delegatecall(_calldata);

        if (!success) {
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }

        return result;
    }

    /**
     * @notice Optional tend trigger for strategies that implement periodic tending
     * @dev Returns true if there are idle assets (native or ERC20) to tend with.
     */
    function _tendTrigger() internal view virtual override returns (bool) {
        return (address(asset) == NATIVE_TOKEN ? address(this).balance : asset.balanceOf(address(this))) > 0;
    }
}
