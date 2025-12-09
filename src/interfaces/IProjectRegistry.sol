// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.25;

/**
 * @title IProjectRegistry
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for project registration and tracking
 * @dev Used by allocation mechanisms to validate eligible projects
 */
interface IProjectRegistry {
    /**
     * @notice Checks if a project is registered
     * @param _project Address of the project to check
     * @return bool True if project is registered, false otherwise
     * @dev Returns false for address(0)
     */
    function isRegistered(address _project) external view returns (bool);

    /**
     * @notice Adds a new project to the registry
     * @param _project Address of the project to add
     * @dev Access restricted to authorized roles
     * @dev Reverts if project already registered or address is zero
     */
    function addProject(address _project) external;

    /**
     * @notice Removes a project from the registry
     * @param _project Address of the project to remove
     * @dev Access restricted to authorized roles
     * @dev Reverts if project not registered
     */
    function removeProject(address _project) external;

    /**
     * @notice Gets the project ID for a given project
     * @param _project Address of the project to get ID for
     * @return uint256 Project ID (0 if project not registered)
     * @dev Returns 0 for unregistered projects or address(0)
     */
    function getProjectId(address _project) external view returns (uint256);

    /**
     * @notice Emitted when a project is added
     * @param project Address of the added project
     */
    event ProjectAdded(address indexed project);

    /**
     * @notice Emitted when a project is removed
     * @param project Address of the removed project
     */
    event ProjectRemoved(address indexed project);
}
