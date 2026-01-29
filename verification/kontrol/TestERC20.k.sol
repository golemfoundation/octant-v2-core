// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { KontrolTest } from "./KontrolTest.k.sol";

/**
 * @title DummyERCWithMetadata Contract
 * @author Cork Team
 * @notice Dummy contract which provides ERC20 with Metadata for RA & PA
 */
contract TestERC20 is ERC20, KontrolTest {
    uint256 private constant _balancesSlot = 0;
    uint256 private constant _allowancesSlot = 1;
    uint256 private constant _totalSupplySlot = 2;

    constructor() ERC20("Dragon Test Token", "DTT") {}

    function symbolicSetUp() public {
        kevm.symbolicStorage(address(this));
        uint256 totalSupply = freshUInt256Bounded("assetTotalSupply");
        vm.store(address(this), bytes32(_totalSupplySlot), bytes32(totalSupply));
    }

    function setSymbolicBalanceOf(address account, string memory /* name */) external {
        uint256 balance = freshUInt256();
        vm.assume(balance <= totalSupply());
        bytes32 balanceAccountSlot = keccak256(abi.encode(account, _balancesSlot));
        vm.store(address(this), balanceAccountSlot, bytes32(balance));
    }

    function setSymbolicAllowance(address owner, address spender, string memory name) external {
        uint256 allowance = freshUInt256Bounded(name);
        bytes32 allowanceAccountSlot = keccak256(abi.encode(spender, keccak256(abi.encode(owner, _allowancesSlot))));
        vm.store(address(this), allowanceAccountSlot, bytes32(allowance));
    }

    /**
     * @notice mints `amount` number of tokens to `to` address
     * @param to address of receiver
     * @param amount number of tokens to be minted
     */
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
