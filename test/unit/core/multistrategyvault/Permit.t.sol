// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20Permit } from "src/utils/vendor/shamirlabs/IERC20Permit.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract PermitTest is Test {
    uint256 constant AMOUNT = 10 ** 18;
    uint256 constant PRIVATE_KEY = 0xabcd; // Known private key for tests
    bytes32 constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MultistrategyVault public vault;
    MultistrategyVault public vaultImplementation;
    MockERC20 public asset;
    address public management = address(3);
    address public bunny;
    MultistrategyVaultFactory public vaultFactory;

    function setUp() public {
        // Setup bunny address (similar to Python test's bunny)
        bunny = address(0x1234);

        // Create asset
        asset = new MockERC20(18);

        // Deploy vault implementation
        vaultImplementation = new MultistrategyVault();

        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), management);

        // Create a vault
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

    function testDomainSeparatorUsesVaultName() public view {
        bytes32 nameHash = keccak256(bytes(vault.name()));
        bytes32 versionHash = keccak256(bytes(vault.API_VERSION()));
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(EIP712DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, address(vault))
        );

        assertEq(vault.DOMAIN_SEPARATOR(), expectedDomainSeparator);
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

    function testDomainSeparatorUpdatesOnNameChange() public {
        bytes32 originalDomainSeparator = vault.DOMAIN_SEPARATOR();

        // Change name
        string memory newName = "New Vault Name";
        vm.prank(bunny); // bunny is roleManager
        vault.setName(newName);

        // Verify domain separator changed
        bytes32 newDomainSeparator = vault.DOMAIN_SEPARATOR();
        assertTrue(newDomainSeparator != originalDomainSeparator, "Domain separator should change with name");

        // Verify new domain separator matches expected value
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(newName)),
                keccak256(bytes(vault.API_VERSION())),
                block.chainid,
                address(vault)
            )
        );
        assertEq(newDomainSeparator, expectedDomainSeparator, "Domain separator should use new name");
    }

    function testPermitInvalidatedAfterNameChange() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        // Sign permit with original name
        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        // Change name before using permit
        vm.prank(bunny);
        vault.setName("New Name");

        // Old permit should fail (wrong domain separator)
        vm.expectRevert(IMultistrategyVault.InvalidSignature.selector);
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);
    }

    function testPermitWorksAfterNameChange() public {
        // Change name first
        vm.prank(bunny);
        vault.setName("New Name");

        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        // Sign permit with new domain separator
        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        // Permit should work
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);

        assertEq(vault.allowance(owner, bunny), AMOUNT);
    }

    function testDomainSeparatorRebuildsOnChainFork() public {
        bytes32 originalSeparator = vault.DOMAIN_SEPARATOR();
        uint256 originalChainId = block.chainid;

        // Simulate a chain fork by changing the chain ID
        uint256 forkedChainId = originalChainId + 1;
        vm.chainId(forkedChainId);

        // Domain separator must differ from cached value
        bytes32 forkedSeparator = vault.DOMAIN_SEPARATOR();
        assertTrue(forkedSeparator != originalSeparator, "Domain separator should change on chain fork");

        // Verify it matches the expected recomputed value
        bytes32 expectedSeparator = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(vault.name())),
                keccak256(bytes(vault.API_VERSION())),
                forkedChainId,
                address(vault)
            )
        );
        assertEq(forkedSeparator, expectedSeparator, "Forked separator should match recomputed value");

        // Restore original chain ID -- cached value should be returned again
        vm.chainId(originalChainId);
        assertEq(vault.DOMAIN_SEPARATOR(), originalSeparator, "Should return cached separator on original chain");
    }

    function testPermitInvalidatedAfterChainFork() public {
        address owner = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 3600;

        // Sign permit on the original chain
        bytes32 digest = _getPermitDigest(address(vault), owner, bunny, AMOUNT, vault.nonces(owner), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        // Simulate a chain fork
        vm.chainId(block.chainid + 1);

        // Permit signed on the original chain must revert
        vm.expectRevert(IMultistrategyVault.InvalidSignature.selector);
        vm.prank(bunny);
        vault.permit(owner, bunny, AMOUNT, deadline, v, r, s);
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
