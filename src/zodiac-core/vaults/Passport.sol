// SPDX-License-Identifier: AGPL-3.0-or-later
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Octant Passport
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice NFT-based access pass for Octant ecosystem features
 * @dev Simple ERC721 with owner-controlled minting
 */
contract OctantPassport is ERC721, Ownable {
    /// @dev Owner set to Octant governance multisig
    constructor() ERC721("Octant Passport", "OP") Ownable(0xfF2e547240946f08600BB93A496b9a377b44E5D0) {}

    /// @notice Mint a new passport NFT
    /// @param to Recipient address
    /// @param tokenId Token ID to mint
    /// @dev Reverts if tokenId already exists (ERC721 standard behavior)
    /// @custom:security Only owner can mint
    function safeMint(address to, uint256 tokenId) public onlyOwner {
        _safeMint(to, tokenId);
    }
}
