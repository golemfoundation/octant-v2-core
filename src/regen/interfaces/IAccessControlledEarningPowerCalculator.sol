// SPDX-License-Identifier: AGPL-3.0-only
// This contract inherits from IEarningPowerCalculator by [ScopeLift](https://scopelift.co)
// IEarningPowerCalculator is licensed under AGPL-3.0-only.
// Users of this contract should ensure compliance with the AGPL-3.0-only license terms of the inherited IEarningPowerCalculator contract.

pragma solidity ^0.8.0;

import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IAccessControlledEarningPowerCalculator
/// @author [Golem Foundation](https://golem.foundation)
/// @notice This interface extends IEarningPowerCalculator with dual-mode address set access control
interface IAccessControlledEarningPowerCalculator is IEarningPowerCalculator, IERC165 {
    /// @notice Emitted when allowset is assigned
    /// @param allowset New allowset contract address
    event AllowsetAssigned(IAddressSet indexed allowset);

    /// @notice Sets the allowset controlling calculator access
    /// @param _allowset New allowset contract (restricts who can calculate earning power)
    function setAllowset(IAddressSet _allowset) external;

    /// @notice Returns the allowset for the earning power calculator
    /// @return Current allowset contract address
    function allowset() external view returns (IAddressSet);
}
