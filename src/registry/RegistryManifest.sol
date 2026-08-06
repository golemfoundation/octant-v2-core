// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IOctantRegistry } from "../interfaces/IOctantRegistry.sol";

/**
 * @title RegistryManifest
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Canonical digest scheme for OctantRegistry publication manifests
 */
library RegistryManifest {
    bytes32 internal constant PUBLICATION_DOMAIN = keccak256("OCTANT_REGISTRY_PUBLICATION_V1");

    /**
     * @notice Hashes a complete registry publication with chain and registry replay protection
     * @param chainId Chain on which the publication will execute
     * @param registry Registry receiving the publication
     * @param expectedEpoch Current epoch expected by the publication
     * @param updates Ordered entry changes
     * @param releaseLabel Human-readable software or deployment release label
     * @return Canonical publication manifest hash
     */
    function hash(
        uint256 chainId,
        address registry,
        uint64 expectedEpoch,
        IOctantRegistry.Update[] memory updates,
        string memory releaseLabel
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    PUBLICATION_DOMAIN,
                    chainId,
                    registry,
                    expectedEpoch,
                    keccak256(bytes(releaseLabel)),
                    updates
                )
            );
    }
}
