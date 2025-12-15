// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Enum } from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";

interface IGnosisSafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);
}

/**
 * @title Keeper Bot Guard
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Guard that allows authorized keeper bots to trigger strategy report() calls through a Safe
 * @dev This contract should be enabled as a module on a Safe. It uses execTransactionFromModule
 *      to make the Safe itself call strategy.report().
 */
contract KeeperBotGuard is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error KeeperBotGuard__NotAuthorizedBot();
    error KeeperBotGuard__InvalidStrategy();
    error KeeperBotGuard__InvalidSafe();
    error KeeperBotGuard__ModuleTransactionFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BotAuthorized(address indexed bot, bool authorized);
    event StrategyReportCalled(address indexed strategy, address indexed bot);
    event SafeSet(address indexed safe);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Safe that this module will use for execution
    IGnosisSafe public immutable safe;

    /// @notice Mapping of authorized keeper bot addresses
    mapping(address => bool) public authorizedBots;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function calls to authorized keeper bots only
    modifier onlyAuthorizedBot() {
        if (!authorizedBots[msg.sender]) {
            revert KeeperBotGuard__NotAuthorizedBot();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _safe) Ownable(_owner) {
        if (_safe == address(0)) {
            revert KeeperBotGuard__InvalidSafe();
        }
        safe = IGnosisSafe(_safe);
        emit SafeSet(_safe);
    }

    /*//////////////////////////////////////////////////////////////
                           BOT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Triggers the Safe to call report() on the specified strategy
     * @dev Can only be called by authorized keeper bots. Uses Safe's execTransactionFromModule
     *      to make the Safe itself call strategy.report(). The Safe must be set as a keeper on the strategy.
     *      If health check is enabled, it will first disable it before calling report.
     * @param strategy Address of the strategy to call report() on
     */
    function callStrategyReport(address strategy) external onlyAuthorizedBot {
        if (strategy == address(0)) {
            revert KeeperBotGuard__InvalidStrategy();
        }

        // First, try to check and disable health check if it's active
        // Use try/catch as doHealthCheck and setDoHealthCheck may not be implemented
        bool healthCheckActive = false;

        // Try to read the health check status
        try IBaseHealthCheck(strategy).doHealthCheck() returns (bool isActive) {
            healthCheckActive = isActive;
        } catch {
            // If doHealthCheck doesn't exist, continue without disabling
        }

        // If health check is active, disable it
        if (healthCheckActive) {
            // Try to disable health check
            bytes memory disableHealthCheckData = abi.encodeWithSelector(
                IBaseHealthCheck.setDoHealthCheck.selector,
                false
            );

            safe.execTransactionFromModule(
                strategy,
                0, // value
                disableHealthCheckData,
                Enum.Operation.Call
            );
        }

        // Prepare the call data for strategy.report()
        bytes memory data = abi.encodeWithSignature("report()");

        // Use the Safe's execTransactionFromModule to execute the call
        bool success = safe.execTransactionFromModule(
            strategy,
            0, // value
            data,
            Enum.Operation.Call
        );

        if (!success) {
            revert KeeperBotGuard__ModuleTransactionFailed();
        }

        emit StrategyReportCalled(strategy, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes or deauthorizes a keeper bot
     * @dev Can only be called by contract owner
     * @param bot Address of the bot to authorize/deauthorize
     * @param authorized Whether the bot should be authorized
     */
    function setBotAuthorization(address bot, bool authorized) external onlyOwner {
        authorizedBots[bot] = authorized;
        emit BotAuthorized(bot, authorized);
    }

    /**
     * @notice Batch authorize/deauthorize multiple bots
     * @dev Can only be called by contract owner
     * @param bots Array of bot addresses
     * @param authorized Array of authorization statuses (must match bots array length)
     */
    function setBotAuthorizationBatch(address[] calldata bots, bool[] calldata authorized) external onlyOwner {
        require(bots.length == authorized.length, "Array length mismatch");

        for (uint256 i = 0; i < bots.length; i++) {
            authorizedBots[bots[i]] = authorized[i];
            emit BotAuthorized(bots[i], authorized[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if an address is an authorized bot
     * @param bot Address to check
     * @return Whether the address is authorized
     */
    function isBotAuthorized(address bot) external view returns (bool) {
        return authorizedBots[bot];
    }
}
