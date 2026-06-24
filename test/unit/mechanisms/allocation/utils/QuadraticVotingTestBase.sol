// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { AllocationTestHelpers } from "./AllocationTestHelpers.sol";

abstract contract QuadraticVotingTestBase is AllocationTestHelpers {
    AllocationMechanismFactory internal factory;
    ERC20Mock internal token;
    QuadraticVotingMechanism internal mechanism;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address internal dave = address(0x4);
    address internal eve = address(0x5);
    address internal frank = address(0x6);
    address internal grace = address(0x7);
    address internal henry = address(0x8);
    address internal emergencyAdmin = address(0xa);
    address internal recipient1 = address(0x101);
    address internal recipient2 = address(0x102);
    address internal recipient3 = address(0x103);

    uint256 internal constant DEFAULT_VOTING_DELAY = 100;
    uint256 internal constant DEFAULT_VOTING_PERIOD = 1000;
    uint256 internal constant DEFAULT_QUORUM = 500;
    uint256 internal constant DEFAULT_TIMELOCK_DELAY = 1 days;
    uint256 internal constant DEFAULT_GRACE_PERIOD = 7 days;
    uint256 internal constant DEFAULT_ALPHA_NUMERATOR = 50;
    uint256 internal constant DEFAULT_ALPHA_DENOMINATOR = 100;

    function _setUpQuadraticVoting() internal {
        _setUpQuadraticVoting(_defaultConfig(), DEFAULT_ALPHA_NUMERATOR, DEFAULT_ALPHA_DENOMINATOR);
    }

    function _setUpQuadraticVoting(
        string memory name,
        string memory symbol,
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 quorumShares,
        uint256 timelockDelay,
        uint256 gracePeriod,
        uint256 alphaNumerator,
        uint256 alphaDenominator
    ) internal {
        token = new ERC20Mock();
        _setUpQuadraticVoting(
            _config({
                asset: IERC20(address(token)),
                name: name,
                symbol: symbol,
                votingDelay: votingDelay,
                votingPeriod: votingPeriod,
                quorumShares: quorumShares,
                timelockDelay: timelockDelay,
                gracePeriod: gracePeriod,
                owner: address(0)
            }),
            alphaNumerator,
            alphaDenominator
        );
    }

    function _setUpQuadraticVoting(
        AllocationConfig memory allocationConfig,
        uint256 alphaNumerator,
        uint256 alphaDenominator
    ) internal {
        factory = new AllocationMechanismFactory();
        token = ERC20Mock(address(allocationConfig.asset));
        mechanism = _deployQuadraticVoting(factory, allocationConfig, alphaNumerator, alphaDenominator);
    }

    function _setUpQuadraticVotingWithFreshToken(
        AllocationConfig memory allocationConfig,
        uint256 alphaNumerator,
        uint256 alphaDenominator
    ) internal {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        allocationConfig.asset = IERC20(address(token));
        mechanism = _deployQuadraticVoting(factory, allocationConfig, alphaNumerator, alphaDenominator);
    }

    function _defaultConfig() internal returns (AllocationConfig memory) {
        token = new ERC20Mock();
        return
            _config({
                asset: IERC20(address(token)),
                name: "Quadratic Voting Test",
                symbol: "QVT",
                votingDelay: DEFAULT_VOTING_DELAY,
                votingPeriod: DEFAULT_VOTING_PERIOD,
                quorumShares: DEFAULT_QUORUM,
                timelockDelay: DEFAULT_TIMELOCK_DELAY,
                gracePeriod: DEFAULT_GRACE_PERIOD,
                owner: address(0)
            });
    }

    function _standardConfig(
        string memory name,
        string memory symbol,
        uint256 quorumShares,
        uint256 timelockDelay,
        uint256 gracePeriod
    ) internal returns (AllocationConfig memory) {
        token = new ERC20Mock();
        return
            _config({
                asset: IERC20(address(token)),
                name: name,
                symbol: symbol,
                votingDelay: DEFAULT_VOTING_DELAY,
                votingPeriod: DEFAULT_VOTING_PERIOD,
                quorumShares: quorumShares,
                timelockDelay: timelockDelay,
                gracePeriod: gracePeriod,
                owner: address(0)
            });
    }

    function _setRoles(address keeper, address management) internal {
        _tokenized(address(mechanism)).setKeeper(keeper);
        _tokenized(address(mechanism)).setManagement(management);
    }

    function _fundUsers(uint256 amount) internal {
        token.mint(alice, amount);
        token.mint(bob, amount);
        token.mint(charlie, amount);
    }

    function _fundUsers(uint256 aliceAmount, uint256 bobAmount, uint256 charlieAmount) internal {
        token.mint(alice, aliceAmount);
        token.mint(bob, bobAmount);
        token.mint(charlie, charlieAmount);
    }

    function _fundMatchingPool(uint256 amount) internal {
        token.mint(address(mechanism), amount);
    }

    function _signup(address user, uint256 depositAmount) internal {
        _signupUser(token, mechanism, user, depositAmount);
    }

    function _signupUser(address user, uint256 depositAmount) internal {
        _signup(user, depositAmount);
    }

    function _propose(address proposer, address recipient, string memory description) internal returns (uint256 pid) {
        pid = _createProposal(mechanism, proposer, recipient, description);
    }

    function _createProposal(
        address proposer,
        address recipient,
        string memory description
    ) internal returns (uint256 pid) {
        pid = _propose(proposer, recipient, description);
    }

    function _createProposal(address recipient, string memory description) internal returns (uint256 pid) {
        pid = _propose(address(this), recipient, description);
    }

    function _vote(address voter, uint256 pid, uint256 weight, address recipient) internal {
        _castVote(mechanism, voter, pid, weight, recipient);
    }

    function _castVote(
        address voter,
        uint256 pid,
        uint256 weight,
        address recipient
    ) internal returns (uint256 previousPower, uint256 newPower) {
        previousPower = _tokenized().votingPower(voter);
        _vote(voter, pid, weight, recipient);
        newPower = _tokenized().votingPower(voter);
    }

    function _tokenized() internal view returns (TokenizedAllocationMechanism) {
        return _tokenized(address(mechanism));
    }

    function _moveToVotingPeriod() internal {
        _warpToVotingPeriod(_tokenized());
    }
}
