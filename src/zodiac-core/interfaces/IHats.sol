// SPDX-License-Identifier: AGPL-3.0
// Copyright (C) 2023 Haberdasher Labs
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.8.20;

/**
 * @title IHats
 * @author Haberdasher Labs
 * @custom:security-contact security@golem.foundation
 * @custom:vendor Hats Protocol
 * @custom:license AGPL-3.0
 * @custom:ported-from https://github.com/Hats-Protocol/hats-protocol/blob/main/src/Interfaces/IHats.sol
 * @notice Interface for Hats Protocol role management system
 * @dev Minimal interface for hat creation and verification
 */
interface IHats {
    /**
     * @notice Creates a new hat (role) in the Hats Protocol tree
     * @param _admin Hat ID of the admin hat (parent in tree hierarchy)
     * @param _details IPFS hash or URI containing hat metadata
     * @param _maxSupply Maximum number of addresses that can wear this hat (0 = unlimited)
     * @param _eligibility Address of eligibility module (determines who can wear hat, 0x0 = anyone)
     * @param _toggle Address of toggle module (can deactivate hat, 0x0 = always active)
     * @param _mutable Whether hat properties can be changed after creation
     * @param _imageURI IPFS hash or URI for hat image/icon
     * @return newHatId Unique identifier for the newly created hat
     */
    function createHat(
        uint256 _admin,
        string calldata _details,
        uint32 _maxSupply,
        address _eligibility,
        address _toggle,
        bool _mutable,
        string calldata _imageURI
    ) external returns (uint256 newHatId);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieves complete hat configuration and state
     * @param _hatId Hat ID to query
     * @return details IPFS hash or URI containing hat metadata
     * @return maxSupply Maximum number of wearers allowed (0 = unlimited)
     * @return supply Current number of addresses wearing this hat
     * @return eligibility Address of eligibility module contract
     * @return toggle Address of toggle module contract
     * @return imageURI IPFS hash or URI for hat image/icon
     * @return lastHatId ID of last child hat created under this hat
     * @return mutable_ Whether hat properties can be changed
     * @return active Whether hat is currently active
     */
    function viewHat(
        uint256 _hatId
    )
        external
        view
        returns (
            string memory details,
            uint32 maxSupply,
            uint32 supply,
            address eligibility,
            address toggle,
            string memory imageURI,
            uint16 lastHatId,
            bool mutable_,
            bool active
        );

    /**
     * @notice Checks if an address is currently wearing a specific hat
     * @param _user Address to check
     * @param _hatId Hat ID to check for
     * @return isWearer True if user is wearing the hat and it's active
     */
    function isWearerOfHat(address _user, uint256 _hatId) external view returns (bool isWearer);

    /**
     * @notice Checks if an address is an admin of a specific hat
     * @dev Admin means the address wears the parent (admin) hat in the tree hierarchy
     * @param _user Address to check
     * @param _hatId Hat ID to check admin status for
     * @return isAdmin True if user is an admin of the specified hat
     */
    function isAdminOfHat(address _user, uint256 _hatId) external view returns (bool isAdmin);

    /**
     * @notice Checks if a hat wearer is in good standing
     * @dev Good standing is determined by the hat's eligibility module
     * @param _wearer Address of the hat wearer
     * @param _hatId Hat ID to check standing for
     * @return standing True if wearer is in good standing (eligible)
     */
    function isInGoodStanding(address _wearer, uint256 _hatId) external view returns (bool standing);
}
