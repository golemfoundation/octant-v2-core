// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.18;

import { IDragonTokenizedStrategy } from "src/zodiac-core/interfaces/IDragonTokenizedStrategy.sol";
import { IBaseStrategy } from "src/zodiac-core/interfaces/IBaseStrategy.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
// Interface to use during testing that implements the 4626 standard
// the implementation functions, the Strategies immutable functions
// as well as the added functions for the Mock Strategy.
interface IMockStrategy is IDragonTokenizedStrategy, IBaseStrategy {
    function setTrigger(bool _trigger) external;

    function onlyLetManagers() external;

    function onlyLetKeepersIn() external;

    function onlyLetEmergencyAdminsIn() external;

    function safeDeposit(uint256 assets, address receiver, uint256 minSharesOut) external;

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
