// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

// Custom errors for Hats Protocol integration.
// Used by AbstractHatsManager and DragonHatter for role-based access control.

error Hats__InvalidAddressFor(string message, address a);

error Hats__InvalidHat(uint256 hatId);

error Hats__DoesNotHaveThisHat(address sender, uint256 hatId);

error Hats__HatAlreadyExists(bytes32 roleId);

error Hats__HatDoesNotExist(bytes32 roleId);

error Hats__NotAdminOfHat(address sender, uint256 hatId);

error Hats__TooManyInitialHolders(uint256 initialHolders, uint256 maxSupply);
