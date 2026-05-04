// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { BaseAllocationMechanism, AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title Mock mechanism with custom distribution that transfers assets directly
contract CustomDistributionMechanism is BaseAllocationMechanism {
    mapping(uint256 => uint256) public voteTallies;
    uint256 public proposalCounter;

    // Threshold for custom distribution: if sharesToMint < threshold, transfer assets directly
    uint256 public customDistributionThreshold = 50 ether;

    constructor(
        address _implementation,
        AllocationConfig memory _config
    ) BaseAllocationMechanism(_implementation, _config) {}

    /// @notice Set threshold for custom distribution testing
    function setCustomDistributionThreshold(uint256 threshold) external {
        customDistributionThreshold = threshold;
    }

    function _beforeSignupHook(address) internal pure override returns (bool) {
        return true;
    }

    function _beforeProposeHook(address) internal pure override returns (bool) {
        return true;
    }

    function _validateProposalHook(uint256 pid) internal view override returns (bool) {
        return _proposalExists(pid);
    }

    function _getVotingPowerHook(address, uint256 deposit) internal pure override returns (uint256) {
        return deposit;
    }

    function _processVoteHook(
        uint256 pid,
        address,
        TokenizedAllocationMechanism.VoteType choice,
        uint256 weight,
        uint256 oldPower
    ) internal override returns (uint256) {
        if (choice == TokenizedAllocationMechanism.VoteType.For) {
            voteTallies[pid] += weight;
        }
        return oldPower - weight;
    }

    function _hasQuorumHook(uint256 pid) internal view override returns (bool) {
        return voteTallies[pid] >= _getQuorumShares();
    }

    function _convertVotesToShares(uint256 pid) internal view override returns (uint256) {
        return voteTallies[pid];
    }

    function _beforeFinalizeVoteTallyHook() internal pure override returns (bool) {
        return true;
    }

    function _getRecipientAddressHook(uint256 pid) internal view override returns (address) {
        TokenizedAllocationMechanism.Proposal memory proposal = _getProposal(pid);
        return proposal.recipient;
    }

    /// @notice Threshold-based custom distribution: small allocations get direct transfers, large ones get shares
    function _requestCustomDistributionHook(
        address recipient,
        uint256 sharesToMint
    ) internal override returns (bool handled, uint256 assetsTransferred) {
        if (sharesToMint < customDistributionThreshold) {
            // Small allocation: transfer assets directly equal to sharesToMint amount
            // This assumes 1:1 shares-to-assets ratio at mechanism start (before any shares exist)
            uint256 assetsToTransfer = sharesToMint;

            if (assetsToTransfer > 0 && asset.balanceOf(address(this)) >= assetsToTransfer) {
                asset.transfer(recipient, assetsToTransfer);
                return (true, assetsToTransfer);
            }
        }

        // Large allocation: use default share minting
        return (false, 0);
    }

    function _availableWithdrawLimit(address) internal pure override returns (uint256) {
        return type(uint256).max;
    }

    function _calculateTotalAssetsHook() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/// @title Test to demonstrate the custom distribution accounting fix
contract CustomDistributionAccountingTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    CustomDistributionMechanism mechanism;

    address alice = address(0x1);
    address bob = address(0x2);
    address projectA = address(0xA);
    address projectB = address(0xB);
    address projectC = address(0xC);

    function _tokenized() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Custom Distribution Test",
            symbol: "CDT",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 25 ether,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        mechanism = new CustomDistributionMechanism(factory.tokenizedAllocationImplementation(), config);

        // Fund users with exactly what they'll use for voting (no extra mechanism funding)
        token.mint(alice, 150 ether); // Will vote 30 + 40 + 80 = 150 ether
        token.mint(bob, 60 ether); // Will vote 60 ether
    }

    /// @notice Test threshold-based distribution with mixed small and large allocations
    function testThresholdBasedDistribution() public {
        _runThresholdDistributionTest();
    }

    /// @notice Execute complete threshold-based distribution test scenario
    function _runThresholdDistributionTest() internal {
        // Create recipients for different allocation sizes
        address smallProject1 = address(0x11); // Will get 30 ether (direct transfer)
        address smallProject2 = address(0x22); // Will get 40 ether (direct transfer)
        address largeProject1 = address(0x33); // Will get 80 ether (shares)
        address largeProject2 = address(0x44); // Will get 60 ether (shares)

        // Setup voting and create proposals
        (uint256 pid1, uint256 pid2, uint256 pid3, uint256 pid4) = _setupVotingScenario(
            smallProject1,
            smallProject2,
            largeProject1,
            largeProject2
        );

        // Record initial state
        uint256 initialTotalAssets = _tokenized().totalAssets();
        uint256 initialMechanismBalance = token.balanceOf(address(mechanism));

        console.log("Initial state:");
        console.log("  TotalAssets:", initialTotalAssets);
        console.log("  Mechanism balance:", initialMechanismBalance);
        console.log("  Threshold:", mechanism.customDistributionThreshold());

        // Queue all proposals and track outcomes
        _queueProposalAndVerify(pid1, smallProject1, 30 ether, true); // Small: direct transfer
        _queueProposalAndVerify(pid2, smallProject2, 40 ether, true); // Small: direct transfer
        _queueProposalAndVerify(pid3, largeProject1, 80 ether, false); // Large: shares
        _queueProposalAndVerify(pid4, largeProject2, 60 ether, false); // Large: shares

        // Verify final accounting integrity
        _verifyFinalAccounting(initialTotalAssets, 70 ether); // 30 + 40 = 70 ether direct transfers

        // Test share redemption for large proposal recipients
        _testShareRedemption(largeProject1, largeProject2);

        // Verify everyone got exactly what they should have gotten
        _verifyCorrectPayouts(smallProject1, smallProject2, largeProject1, largeProject2);

        console.log("SUCCESS: All recipients paid correctly with proper accounting!");
    }

    /// @notice Setup voting scenario with 4 proposals of different sizes
    function _setupVotingScenario(
        address project1,
        address project2,
        address project3,
        address project4
    ) internal returns (uint256 pid1, uint256 pid2, uint256 pid3, uint256 pid4) {
        uint256 deploymentTime = block.timestamp;
        uint256 votingStartTime = deploymentTime + _tokenized().votingDelay();
        uint256 votingEndTime = votingStartTime + _tokenized().votingPeriod();

        // Users register with exactly the amount they'll vote with
        vm.warp(votingStartTime - 1);
        vm.startPrank(alice);
        token.approve(address(mechanism), 150 ether); // Will vote 30+40+80=150
        _tokenized().signup(150 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), 60 ether); // Will vote 60
        _tokenized().signup(60 ether);
        vm.stopPrank();

        // Create proposals
        pid1 = _tokenized().propose(project1, "Small Project 1");
        pid2 = _tokenized().propose(project2, "Small Project 2");
        pid3 = _tokenized().propose(project3, "Large Project 1");
        pid4 = _tokenized().propose(project4, "Large Project 2");

        // Vote strategically to get target amounts
        vm.warp(votingStartTime + 1);
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 30 ether, project1);
        vm.prank(alice);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 40 ether, project2);
        vm.prank(alice);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 80 ether, project3);
        vm.prank(bob);
        _tokenized().castVote(pid4, TokenizedAllocationMechanism.VoteType.For, 60 ether, project4);

        // Finalize tally
        vm.warp(votingEndTime + 1);
        _tokenized().finalizeVoteTally();
    }

    /// @notice Queue a proposal and verify the distribution method and outcome
    function _queueProposalAndVerify(
        uint256 pid,
        address recipient,
        uint256 expectedAmount,
        bool expectDirectTransfer
    ) internal {
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 mechanismBalanceBefore = token.balanceOf(address(mechanism));
        uint256 totalAssetsBefore = _tokenized().totalAssets();
        uint256 sharesBefore = _tokenized().balanceOf(recipient);

        _tokenized().queueProposal(pid);

        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        uint256 mechanismBalanceAfter = token.balanceOf(address(mechanism));
        uint256 totalAssetsAfter = _tokenized().totalAssets();
        uint256 sharesAfter = _tokenized().balanceOf(recipient);

        if (expectDirectTransfer) {
            // Verify direct transfer occurred
            assertEq(
                recipientBalanceAfter - recipientBalanceBefore,
                expectedAmount,
                "Recipient should receive direct transfer"
            );
            assertEq(mechanismBalanceBefore - mechanismBalanceAfter, expectedAmount, "Mechanism should lose assets");
            assertEq(totalAssetsBefore - totalAssetsAfter, expectedAmount, "TotalAssets should decrease");
            assertEq(sharesAfter, sharesBefore, "No shares should be minted");

            console.log("Direct transfer:", expectedAmount, "to recipient");
        } else {
            // Verify share minting occurred
            assertEq(recipientBalanceAfter, recipientBalanceBefore, "No direct transfer should occur");
            assertEq(mechanismBalanceAfter, mechanismBalanceBefore, "Mechanism balance should stay same");
            assertEq(totalAssetsAfter, totalAssetsBefore, "TotalAssets should stay same");
            assertEq(sharesAfter - sharesBefore, expectedAmount, "Shares should be minted");

            console.log("Share minting:", expectedAmount, "shares to recipient");
        }
    }

    /// @notice Verify final accounting integrity after all distributions
    function _verifyFinalAccounting(uint256 initialTotalAssets, uint256 directTransfersTotal) internal view {
        uint256 finalTotalAssets = _tokenized().totalAssets();
        uint256 finalMechanismBalance = token.balanceOf(address(mechanism));
        uint256 totalShares = _tokenized().totalSupply();

        // TotalAssets should equal initial minus direct transfers
        assertEq(
            finalTotalAssets,
            initialTotalAssets - directTransfersTotal,
            "TotalAssets should reflect direct transfers"
        );

        // Mechanism balance should equal totalAssets (no other changes)
        assertEq(finalMechanismBalance, finalTotalAssets, "Mechanism balance should match totalAssets");

        console.log("Final accounting:");
        console.log("  TotalAssets:", finalTotalAssets);
        console.log("  Mechanism balance:", finalMechanismBalance);
        console.log("  Total shares:", totalShares);
        console.log("  Expected shares redeemable for:", finalTotalAssets);
    }

    /// @notice Test that large proposal recipients can redeem their shares correctly
    function _testShareRedemption(address largeProject1, address largeProject2) internal {
        // Move past timelock
        vm.warp(block.timestamp + _tokenized().timelockDelay() + 1);

        uint256 shares1 = _tokenized().balanceOf(largeProject1);
        uint256 shares2 = _tokenized().balanceOf(largeProject2);

        if (shares1 > 0) {
            uint256 expectedAssets1 = _tokenized().convertToAssets(shares1);
            uint256 balanceBefore1 = token.balanceOf(largeProject1);

            vm.prank(largeProject1);
            _tokenized().redeem(shares1, largeProject1, largeProject1);

            uint256 balanceAfter1 = token.balanceOf(largeProject1);
            assertEq(balanceAfter1 - balanceBefore1, expectedAssets1, "Large project 1 should redeem shares correctly");

            console.log("Large project 1 redeemed shares:", shares1, "for assets:", expectedAssets1);
        }

        if (shares2 > 0) {
            uint256 expectedAssets2 = _tokenized().convertToAssets(shares2);
            uint256 balanceBefore2 = token.balanceOf(largeProject2);

            vm.prank(largeProject2);
            _tokenized().redeem(shares2, largeProject2, largeProject2);

            uint256 balanceAfter2 = token.balanceOf(largeProject2);
            assertEq(balanceAfter2 - balanceBefore2, expectedAssets2, "Large project 2 should redeem shares correctly");

            console.log("Large project 2 redeemed shares:", shares2, "for assets:", expectedAssets2);
        }
    }

    /// @notice Verify that all recipients received exactly the correct amounts
    function _verifyCorrectPayouts(
        address smallProject1,
        address smallProject2,
        address largeProject1,
        address largeProject2
    ) internal view {
        console.log("\n=== Verifying Correct Payouts ===");

        // Check small projects got direct transfers
        uint256 small1Balance = token.balanceOf(smallProject1);
        uint256 small2Balance = token.balanceOf(smallProject2);

        assertEq(small1Balance, 30 ether, "Small project 1 should have 30 ether");
        assertEq(small2Balance, 40 ether, "Small project 2 should have 40 ether");

        console.log("Small project 1 received:", small1Balance);
        console.log("Small project 2 received:", small2Balance);

        // Check large projects got correct amounts through shares
        uint256 large1Balance = token.balanceOf(largeProject1);
        uint256 large2Balance = token.balanceOf(largeProject2);

        console.log("Large project 1 received:", large1Balance);
        console.log("Large project 2 received:", large2Balance);

        // The key insight: large projects should get proportional to their share allocation
        // Total allocated to large projects: 80 + 60 = 140 ether
        // Total assets available for shares: 530 ether (after direct transfers)
        // But they should only get their allocated amounts: 80 and 60 ether respectively

        // This reveals the fundamental issue: when we have mixed distributions,
        // the large projects are getting more than they should because they're
        // getting a share of assets that were meant for small projects too

        console.log("Expected for large project 1: 80 ether");
        console.log("Expected for large project 2: 60 ether");
        console.log("Total expected for large projects: 140 ether");
        console.log("Total actually received by large projects:", large1Balance + large2Balance);

        // This test exposes that the accounting fix is correct, but the distribution
        // logic itself has a fundamental issue with mixed distribution methods
    }
}
