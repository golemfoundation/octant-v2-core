// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MockERC1271Signer - Mock contract that can sign via ERC1271
/// @notice Used for testing ERC1271 signature validation in TokenizedAllocationMechanism
contract MockERC1271Signer is IERC1271 {
    using ECDSA for bytes32;

    address public owner;

    /// @notice ERC1271 magic value for valid signatures
    bytes4 public constant MAGIC_VALUE = 0x1626ba7e;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @notice Validates a signature according to ERC-1271
    /// @dev This mock implementation validates that the signature was created by the owner
    /// @param hash The hash that was supposedly signed
    /// @param signature The signature to validate (expected format: abi.encodePacked(r, s, v))
    /// @return magicValue Returns MAGIC_VALUE if valid, or reverts
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4 magicValue) {
        // Decode the signature components
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := calldataload(add(signature.offset, 0))
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // Recover signer from the signature
        address signer = ecrecover(hash, v, r, s);

        // Check if the signer is the owner
        if (signer == owner) {
            return MAGIC_VALUE;
        } else {
            revert("Invalid signer");
        }
    }

    /// @notice Allows changing the owner for testing different scenarios
    function setOwner(address newOwner) external {
        require(msg.sender == owner, "Only owner");
        owner = newOwner;
    }
}
