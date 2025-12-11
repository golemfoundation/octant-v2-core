// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { YearnV3Strategy } from "./YearnV3Strategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

/**
 * @title CustomQueueYearnV3Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice YearnV3Strategy that fixes the MultistrategyVault queue issue via custom emergency withdraw
 * @dev Simple implementation that checks access control and shutdown status, then calls
 *      MultistrategyVault.withdraw with custom strategies array to bypass queue bugs.
 *
 *      FIXING THE QUEUE ISSUE:
 *      - MultistrategyVault._deposit() doesn't check useDefaultQueue before auto-allocation
 *      - MultistrategyVault._redeem() uses default queue even when useDefaultQueue=false
 *      - This strategy bypasses both issues by allowing direct custom queue specification
 *
 *      WORKFLOW:
 *      1. User calls emergencyWithdraw(amount, strategiesArray) on this strategy
 *      2. Function checks if caller is authorized (emergencyAdmin or management)
 *      3. Function checks if strategy is shutdown (required for emergency withdrawals)
 *      4. Directly calls MultistrategyVault.withdraw with custom strategies array
 *      5. Falls back to normal Yearn vault withdrawal if MultistrategyVault call fails
 */
contract CustomQueueYearnV3Strategy is YearnV3Strategy {
    /// @dev Event emitted when custom strategies queue is used for emergency withdrawal
    event CustomStrategiesUsed(address[] strategies, uint256 amount);
    constructor(
        address _yearnVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        YearnV3Strategy(
            _yearnVault,
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    /**
     * @notice Emergency withdraw with custom strategies array to bypass MultistrategyVault queue issues
     * @dev Checks access control and shutdown status, then calls MultistrategyVault with custom queue
     *
     * @param amount Amount to withdraw
     * @param strategiesArrayAddresses Array of strategy addresses for withdrawal queue order
     */
    function emergencyWithdraw(uint256 amount, address[] calldata strategiesArrayAddresses) external {
        // Access control: only emergency admin or management can call
        require(
            TokenizedStrategy.emergencyAdmin() == msg.sender || TokenizedStrategy.management() == msg.sender,
            "Not authorized"
        );

        // Strategy must be shutdown for emergency withdrawals
        require(TokenizedStrategy.isShutdown(), "Strategy not shutdown");

        // Try to withdraw using custom strategies from MultistrategyVault
        // The yearnVault parameter is actually the MultistrategyVault address in this use case
        try
            IMultistrategyVault(yearnVault).withdraw(
                amount,
                address(this), // receiver (this strategy)
                address(this), // owner (this strategy owns shares)
                10_000, // maxLoss (accept 100% to prevent reverts)
                strategiesArrayAddresses // custom withdrawal queue - THIS BYPASSES THE QUEUE ISSUE!
            )
        returns (uint256) {
            // Successfully withdrew using custom strategies, bypassing vault queue bugs
            emit CustomStrategiesUsed(strategiesArrayAddresses, amount);
            return;
        } catch {
            // If withdraw fails, fall back to normal Yearn vault withdrawal
            // This might happen if the yearnVault is not actually a MultistrategyVault
            _freeFunds(amount);
        }
    }
}
