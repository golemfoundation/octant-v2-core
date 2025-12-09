// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TokenizedStrategy__InvalidSigner } from "src/errors.sol";

contract Finding658Fix is Test {
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 private ownerKey;
    address private owner;
    address private spender;

    function setUp() public {
        ownerKey = 0xBEEF;
        owner = vm.addr(ownerKey);
        spender = address(0xBEEF02);
    }

    function testMultistrategyPermitRejectsHighS() public {
        MultistrategyVault vault = _deployVault();

        uint256 amount = 123;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = vault.nonces(owner);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            vault.DOMAIN_SEPARATOR(),
            owner,
            spender,
            amount,
            nonce,
            deadline
        );

        (uint8 vHigh, bytes32 sHigh) = _toHighS(v, s);

        vm.expectRevert(IMultistrategyVault.InvalidSignature.selector);
        vault.permit(owner, spender, amount, deadline, vHigh, r, sHigh);
    }

    function testMultistrategyPermitAcceptsCanonicalSignature() public {
        MultistrategyVault vault = _deployVault();

        uint256 amount = 456;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = vault.nonces(owner);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            vault.DOMAIN_SEPARATOR(),
            owner,
            spender,
            amount,
            nonce,
            deadline
        );

        vault.permit(owner, spender, amount, deadline, v, r, s);

        assertEq(vault.allowance(owner, spender), amount, "allowance not set");
        assertEq(vault.nonces(owner), nonce + 1, "nonce not incremented");
    }

    function testTokenizedStrategyPermitRejectsHighS() public {
        YieldDonatingTokenizedStrategy strategy = _deployStrategy();

        uint256 amount = 789;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = strategy.nonces(owner);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            strategy.DOMAIN_SEPARATOR(),
            owner,
            spender,
            amount,
            nonce,
            deadline
        );

        (uint8 vHigh, bytes32 sHigh) = _toHighS(v, s);

        vm.expectRevert(TokenizedStrategy__InvalidSigner.selector);
        strategy.permit(owner, spender, amount, deadline, vHigh, r, sHigh);
    }

    function testTokenizedStrategyPermitAcceptsCanonicalSignature() public {
        YieldDonatingTokenizedStrategy strategy = _deployStrategy();

        uint256 amount = 321;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = strategy.nonces(owner);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            strategy.DOMAIN_SEPARATOR(),
            owner,
            spender,
            amount,
            nonce,
            deadline
        );

        strategy.permit(owner, spender, amount, deadline, v, r, s);

        assertEq(strategy.allowance(owner, spender), amount, "strategy allowance not set");
        assertEq(strategy.nonces(owner), nonce + 1, "strategy nonce not incremented");
    }

    function _deployVault() private returns (MultistrategyVault vault) {
        address governance = address(0xA11CE);
        address feeRecipient = address(0xFEE);

        MockERC20 asset = new MockERC20(18);
        asset.mint(owner, 1 ether); // ensure DOMAIN_SEPARATOR uses deployed chainid

        vm.prank(governance);
        MockFactory factory = new MockFactory(0, feeRecipient);

        vm.startPrank(address(factory));
        MultistrategyVault implementation = new MultistrategyVault();
        MultistrategyVaultFactory vaultFactory = new MultistrategyVaultFactory(
            "Test Vault",
            address(implementation),
            governance
        );
        vault = MultistrategyVault(
            vaultFactory.deployNewVault(address(asset), "Test Vault", "TVT", governance, 7 days)
        );
        vm.stopPrank();
    }

    function _deployStrategy() private returns (YieldDonatingTokenizedStrategy strategy) {
        MockERC20 asset = new MockERC20(18);

        YieldDonatingTokenizedStrategy implementation = new YieldDonatingTokenizedStrategy();
        strategy = YieldDonatingTokenizedStrategy(address(new ERC1967Proxy(address(implementation), "")));
        strategy.initialize(address(asset), "Strategy", address(0x1), address(0x2), address(0x3), address(0x4), true);
    }

    function _signPermit(
        bytes32 domainSeparator,
        address owner_,
        address spender_,
        uint256 amount_,
        uint256 nonce_,
        uint256 deadline_
    ) private view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, amount_, nonce_, deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    function _toHighS(uint8 v, bytes32 s) private pure returns (uint8 vHigh, bytes32 sHigh) {
        uint256 sValue = uint256(s);
        uint256 sHighValue = SECP256K1_N - sValue;
        require(sHighValue > sValue, "not high-s");
        return (v ^ 1, bytes32(sHighValue));
    }
}
