// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.13;

contract MockDragonRouterSetup {
    address public owner;
    address public governance;
    address public regenGovernance;
    address public splitChecker;
    address public opexVault;
    address public metapool;
    bytes32 public strategiesHash;
    uint256 public strategiesLength;

    function setUp(bytes memory initializer) external {
        (address _owner, bytes memory data) = abi.decode(initializer, (address, bytes));
        (
            address[] memory _strategies,
            address _governance,
            address _regenGovernance,
            address _splitChecker,
            address _opexVault,
            address _metapool
        ) = abi.decode(data, (address[], address, address, address, address, address));

        owner = _owner;
        governance = _governance;
        regenGovernance = _regenGovernance;
        splitChecker = _splitChecker;
        opexVault = _opexVault;
        metapool = _metapool;
        strategiesHash = keccak256(abi.encode(_strategies));
        strategiesLength = _strategies.length;
    }
}
