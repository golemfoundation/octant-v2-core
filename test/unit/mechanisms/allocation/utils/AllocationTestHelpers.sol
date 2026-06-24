// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenizedAllocationMechanism} from "src/mechanisms/TokenizedAllocationMechanism.sol";
import {QuadraticVotingMechanism} from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import {AllocationMechanismFactory} from "src/mechanisms/AllocationMechanismFactory.sol";
import {AllocationConfig} from "src/mechanisms/BaseAllocationMechanism.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

abstract contract AllocationTestHelpers is Test {
    function _tokenized(address mechanismAddress) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(mechanismAddress);
    }

    function _tam(address mechanismAddress) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(mechanismAddress);
    }

    function _config(
        IERC20 asset,
        string memory name,
        string memory symbol,
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 quorumShares,
        uint256 timelockDelay,
        uint256 gracePeriod,
        address owner
    ) internal pure returns (AllocationConfig memory) {
        return AllocationConfig({
            asset: asset,
            name: name,
            symbol: symbol,
            votingDelay: votingDelay,
            votingPeriod: votingPeriod,
            quorumShares: quorumShares,
            timelockDelay: timelockDelay,
            gracePeriod: gracePeriod,
            owner: owner
        });
    }

    function _deployQuadraticVoting(
        AllocationMechanismFactory factory,
        AllocationConfig memory allocationConfig,
        uint256 alphaNumerator,
        uint256 alphaDenominator
    ) internal returns (QuadraticVotingMechanism) {
        return QuadraticVotingMechanism(
            payable(factory.deployQuadraticVotingMechanism(allocationConfig, alphaNumerator, alphaDenominator))
        );
    }

    function _signupUser(ERC20Mock token, QuadraticVotingMechanism mechanism, address user, uint256 depositAmount)
        internal
    {
        vm.startPrank(user);
        token.approve(address(mechanism), depositAmount);
        _tokenized(address(mechanism)).signup(depositAmount);
        vm.stopPrank();
    }

    function _signupUser(IERC20 token, TokenizedAllocationMechanism mechanism, address user, uint256 depositAmount)
        internal
    {
        vm.startPrank(user);
        token.approve(address(mechanism), depositAmount);
        mechanism.signup(depositAmount);
        vm.stopPrank();
    }

    function _createProposal(
        TokenizedAllocationMechanism mechanism,
        address proposer,
        address recipient,
        string memory description
    ) internal returns (uint256 pid) {
        vm.prank(proposer);
        pid = mechanism.propose(recipient, description);
    }

    function _createProposal(
        QuadraticVotingMechanism mechanism,
        address proposer,
        address recipient,
        string memory description
    ) internal returns (uint256 pid) {
        pid = _createProposal(_tokenized(address(mechanism)), proposer, recipient, description);
    }

    function _castVote(
        TokenizedAllocationMechanism mechanism,
        address voter,
        uint256 pid,
        uint256 weight,
        address recipient
    ) internal {
        vm.prank(voter);
        mechanism.castVote(pid, TokenizedAllocationMechanism.VoteType.For, weight, recipient);
    }

    function _castVote(
        QuadraticVotingMechanism mechanism,
        address voter,
        uint256 pid,
        uint256 weight,
        address recipient
    ) internal {
        _castVote(_tokenized(address(mechanism)), voter, pid, weight, recipient);
    }

    function _warpToVotingPeriod(TokenizedAllocationMechanism mechanism) internal {
        vm.warp(block.timestamp + mechanism.votingDelay() + 1);
    }

    function _warpPastVotingPeriod(TokenizedAllocationMechanism mechanism) internal {
        vm.warp(block.timestamp + mechanism.votingDelay() + mechanism.votingPeriod() + 1);
    }

    function _finalizeVoteTally(TokenizedAllocationMechanism mechanism) internal {
        mechanism.finalizeVoteTally();
    }

    function _queueProposal(TokenizedAllocationMechanism mechanism, uint256 pid) internal {
        mechanism.queueProposal(pid);
    }
}
