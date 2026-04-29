// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { MockStrategy as MockBaseStrategy } from "test/mocks/core/MockBaseStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

contract TokenizedStrategyPermitTest is Test {
    MockBaseStrategy tokenizedStrategy;
    MockERC20 asset;
    MockYieldSource yieldSource;
    YieldDonatingTokenizedStrategy implementation;

    uint256 ownerPk;
    address owner;
    address spender;

    bytes32 constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 constant VERSION_HASH = keccak256(bytes("1.1.0"));

    function setUp() public {
        ownerPk = uint256(keccak256(abi.encodePacked("TokenizedStrategyPermitTest owner")));
        owner = vm.addr(ownerPk);
        spender = address(0xBEEF);

        asset = new MockERC20(18);
        yieldSource = new MockYieldSource(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();
        tokenizedStrategy = new MockBaseStrategy(address(asset), address(yieldSource), address(implementation));
    }

    function _signWithDomain(
        bytes32 domainSeparator,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8, bytes32, bytes32) {
        uint256 nonce = ITokenizedStrategy(address(tokenizedStrategy)).nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(ownerPk, digest);
    }

    function test_permit_AllowsSignatureUsingTokenNameDomain() external {
        uint256 value = 1e18;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 nameHash = keccak256(bytes(ITokenizedStrategy(address(tokenizedStrategy)).name()));
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712DOMAIN_TYPEHASH, nameHash, VERSION_HASH, block.chainid, address(tokenizedStrategy))
        );

        assertEq(ITokenizedStrategy(address(tokenizedStrategy)).DOMAIN_SEPARATOR(), domainSeparator);

        (uint8 v, bytes32 r, bytes32 s) = _signWithDomain(domainSeparator, value, deadline);
        ITokenizedStrategy(address(tokenizedStrategy)).permit(owner, spender, value, deadline, v, r, s);

        assertEq(ITokenizedStrategy(address(tokenizedStrategy)).allowance(owner, spender), value);
    }
}
