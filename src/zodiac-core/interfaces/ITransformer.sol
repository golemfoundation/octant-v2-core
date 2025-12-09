// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title Transformer Interface (Routing/Swaps)
 * @author Golem Foundation
 * @notice Minimal interface for modules that transform one token into another (e.g., swap/bridge).
 *         Implementations may pull funds and must return the amount of output tokens delivered.
 */
interface ITransformer {
    function transform(address fromToken, address toToken, uint256 amount) external payable returns (uint256);
}
