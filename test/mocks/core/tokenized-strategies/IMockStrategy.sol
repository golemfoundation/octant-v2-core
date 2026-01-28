// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.18;

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";

/**
 * @title IMockStrategy
 * @notice Interface for mock strategies used in testing
 * @dev Extends ITokenizedStrategy with mock-specific test methods
 */
interface IMockStrategy is ITokenizedStrategy, IBaseStrategy {
    function setTrigger(bool _trigger) external;

    function onlyLetManagers() external;

    function onlyLetKeepersIn() external;

    function onlyLetEmergencyAdminsIn() external;

    function yieldSource() external view returns (address);

    function managed() external view returns (bool);

    function kept() external view returns (bool);

    function emergentizated() external view returns (bool);

    function dontTend() external view returns (bool);

    function setDontTend(bool _dontTend) external;

    function unlockedShares() external view returns (uint256);

    function setDragonRouter(address _dragonRouter) external;

    function finalizeDragonRouterChange() external;

    function pendingDragonRouter() external view returns (address);

    function dragonRouter() external view returns (address);

    function dragonRouterChangeTimestamp() external view returns (uint256);

    function cancelDragonRouterChange() external;

    function lossAmount() external view returns (uint256);

    function enableBurning() external view returns (bool);

    function setEnableBurning(bool _enableBurning) external;
}
