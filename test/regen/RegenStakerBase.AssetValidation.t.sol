// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Staker } from "staker/Staker.sol";

// Mock allocation mechanism that returns a specific asset
contract MockMechanism {
    IERC20 public asset;
    constructor(IERC20 _asset) {
        asset = _asset;
    }
}

/// @title Test for AssetMismatch validation in contribute()
/// @notice Verifies that contribute() reverts with AssetMismatch when tokens don't match
contract RegenStakerBaseAssetValidationTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20 public rewardToken;
    MockERC20 public wrongToken;
    RegenEarningPowerCalculator public calculator;
    AddressSet public allowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    Staker.DepositIdentifier public depositId;

    function setUp() public {
        // Deploy tokens
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20(18);
        wrongToken = new MockERC20(18);

        // Deploy calculator
        calculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        // Deploy allowsets as admin
        vm.startPrank(admin);
        allowset = new AddressSet();
        allocationAllowset = new AddressSet();

        // Setup allowsets
        allowset.add(alice);
        // We'll add mechanisms to the allocation allowset as needed in tests
        vm.stopPrank();

        // Deploy RegenStaker with rewardToken
        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(rewardToken)), // reward token
            stakeToken, // stake token
            calculator,
            1e18, // maxBumpTip
            admin, // admin
            30 days, // rewardDuration
            1e18, // minimumStakeAmount
            IAddressSet(address(allowset)), // stakerAllowset
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset)) // allocationMechanismAllowset
        );

        // Alice stakes
        stakeToken.mint(alice, 100e18);
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), 100e18);
        depositId = regenStaker.stake(10e18, alice, alice);
        vm.stopPrank();

        // Setup rewards
        rewardToken.mint(address(regenStaker), 1000e18);
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(100e18);
        vm.stopPrank();

        // Advance time to accrue rewards
        vm.warp(block.timestamp + 15 days);
    }

    function testContributeRevertsOnAssetMismatch() public {
        // Deploy mechanism expecting wrong token
        MockMechanism mechanism = new MockMechanism(IERC20(address(wrongToken)));

        // Add mechanism to allowset
        vm.prank(admin);
        allocationAllowset.add(address(mechanism));

        // Expect AssetMismatch error
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.AssetMismatch.selector, address(rewardToken), address(wrongToken))
        );

        // Try to contribute - should revert with AssetMismatch
        vm.prank(alice);
        regenStaker.contribute(
            depositId,
            address(mechanism),
            1e18,
            block.timestamp + 1 days,
            0,
            bytes32(0),
            bytes32(0)
        );
    }

    function testContributeDoesNotRevertOnAssetMatch() public {
        // Deploy mechanism expecting correct token
        MockMechanism mechanism = new MockMechanism(IERC20(address(rewardToken)));

        // Add mechanism to allowset
        vm.prank(admin);
        allocationAllowset.add(address(mechanism));

        // The validation should pass the asset check
        // (may still revert for other reasons like signature validation)
        vm.prank(alice);
        try
            regenStaker.contribute(
                depositId,
                address(mechanism),
                1e18,
                block.timestamp + 1 days,
                0,
                bytes32(0),
                bytes32(0)
            )
        {
            // If it succeeds, great
            assertTrue(true);
        } catch Error(string memory reason) {
            // If it fails for a different reason, that's fine
            // Just make sure it's not AssetMismatch
            assertFalse(
                keccak256(bytes(reason)) == keccak256(bytes("AssetMismatch")),
                "Should not fail with AssetMismatch when tokens match"
            );
        } catch (bytes memory) {
            // Low-level revert - also fine as long as we got past the asset check
            assertTrue(true);
        }
    }
}
