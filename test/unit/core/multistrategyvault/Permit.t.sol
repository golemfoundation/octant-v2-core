// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import "forge-std/console.sol";
import { Setup } from "test/unit/zodiac-core/vaults/Setup.sol";
import { IERC20Permit } from "src/utils/vendor/shamirlabs/IERC20Permit.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

contract PermitTest is Setup {
    uint256 constant AMOUNT = 10 ** 18;
    uint256 constant PRIVATE_KEY = 0xabcd; // Known private key for tests

    MultistrategyVault public vault;
    MultistrategyVault public vaultImplementation;
    address public bunny;
    MultistrategyVaultFactory public vaultFactory;

    function setUp() public override {
        super.setUp();

        // Setup bunny address (similar to Python test's bunny)
        bunny = address(0x1234);

        // Deploy vault implementation
        vaultImplementation = new MultistrategyVault();

        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), management);

        // Create a vault using the asset from Setup
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tVAULT", bunny, 10 days));

        // Label addresses for easier debugging
        vm.label(bunny, "bunny");
        vm.label(address(vault), "vault");
    }

    function testPermit() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        assertEq(vault.allowance(owner, bunny), 0);

        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);

        assertEq(vault.allowance(owner, bunny), AMOUNT);
    }

    function testPermitWithUsedPermit() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);

        vm.expectRevert();
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);
    }

    function testPermitWithWrongSignature() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        // Generate signature for max uint value instead of AMOUNT
        bytes32 digest = _getPermitDigest(
            address(vault),
            owner,
            bunny,
            type(uint256).max,
            vault.nonces(owner),
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        // Try to use the signature for AMOUNT instead
        vm.expectRevert(IMultistrategyVault.InvalidSignature.selector);
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);
    }

    function testPermitWithExpiredDeadline() public {
        // Set block timestamp to 1000
        vm.warp(1000);

        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp - 600; // Expired deadline

        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        vm.expectRevert(IMultistrategyVault.PermitExpired.selector);
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);
    }

    function testPermitWithBadOwner() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        vm.expectRevert(IMultistrategyVault.InvalidOwner.selector);
        vm.prank(bunny);
        vault.permit(
            address(0), // Use zero address instead of the real owner
            bunny,
            AMOUNT,
            deadline,
            v,
            r,
            s
        );
    }

    // Helper function to generate permit digest according to EIP-712
    function _getPermitDigest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        return keccak256(abi.encodePacked("\x19\x01", IMultistrategyVault(token).DOMAIN_SEPARATOR(), structHash));
    }
}
