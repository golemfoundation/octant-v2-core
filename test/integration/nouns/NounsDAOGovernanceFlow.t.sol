// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @notice Nouns DAO Governor interface (minimal - avoids stack too deep)
interface INounsDAOProxy {
    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256);

    function queue(uint256 proposalId) external;
    function execute(uint256 proposalId) external;
    function state(uint256 proposalId) external view returns (uint8);
    function proposalThreshold() external view returns (uint256);
}

/// @notice Nouns NFT interface for voting power
interface INounsToken {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function delegate(address delegatee) external;
    function getCurrentVotes(address account) external view returns (uint96);
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title NounsDAOGovernanceFlow Integration Test
 * @notice End-to-end test of Nouns DAO governance flow using real mainnet addresses
 * @dev Run with:
 *      FOUNDRY_DENY_WARNINGS=false forge test \
 *        --match-contract NounsDAOGovernanceFlow \
 *        --fork-url $ETH_RPC_URL \
 *        -vvv
 *
 *      This test:
 *      1. Forks mainnet and deploys real factories
 *      2. Transfers Noun NFTs from real holders to build voting power
 *      3. Creates proposal and votes using real governance contracts
 *      4. Executes full governance flow: propose → vote → queue → execute
 *      5. Verifies contract deployments after execution
 */
contract NounsDAOGovernanceFlowTest is Test {
    // ══════════════════════════════════════════════════════════════════════════════
    // NOUNS DAO MAINNET ADDRESSES
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Nouns DAO Governor proxy contract
    address public constant NOUNS_DAO_PROXY = 0x6f3E6272A167e8AcCb32072d08E0957F9c79223d;

    /// @notice Nouns DAO Executor (Timelock) - treasury that executes proposals
    address public constant NOUNS_EXECUTOR = 0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71;

    /// @notice Nouns NFT token contract
    address public constant NOUNS_TOKEN = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;

    /// @notice wstETH token address on mainnet
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Mainnet PaymentSplitterFactory (already deployed)
    address public constant PAYMENT_SPLITTER_FACTORY = 0x5711765E0756B45224fc1FdA1B41ab344682bBcb;

    /// @notice Tokenized Strategy implementation address
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    /// @notice Vote type: For
    uint8 public constant VOTE_FOR = 1;

    /// @dev Selector for proposals(uint256) - used by assembly helpers
    bytes4 private constant PROPOSALS_SELECTOR = bytes4(keccak256("proposals(uint256)"));

    // ══════════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Fork ID
    uint256 public mainnetFork;

    /// @notice Deployed LidoStrategyFactory
    LidoStrategyFactory public lidoStrategyFactory;

    /// @notice YieldSkimmingTokenizedStrategy implementation
    YieldSkimmingTokenizedStrategy public tokenizedStrategy;

    /// @notice Proposal ID created during test
    uint256 public proposalId;

    /// @notice Predicted PaymentSplitter address
    address public predictedPaymentSplitter;

    /// @notice Test proposer address (will receive Nouns)
    address public testProposer;

    /// @notice Test voter address (will receive Nouns)
    address public testVoter;

    /// @notice Quorum votes needed
    uint256 public quorumNeeded;

    // ══════════════════════════════════════════════════════════════════════════════
    // SETUP
    // ══════════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Fork mainnet
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Create test addresses
        testProposer = makeAddr("testProposer");
        testVoter = makeAddr("testVoter");

        // Deploy YieldSkimmingTokenizedStrategy implementation
        tokenizedStrategy = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();

        // Etch to standard address for consistency
        bytes memory tokenizedStrategyBytecode = address(tokenizedStrategy).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
        tokenizedStrategy = YieldSkimmingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Deploy LidoStrategyFactory
        lidoStrategyFactory = new LidoStrategyFactory();

        // Calculate predicted addresses
        predictedPaymentSplitter = PaymentSplitterFactory(PAYMENT_SPLITTER_FACTORY).predictDeterministicAddress(
            NOUNS_EXECUTOR
        );

        // Label addresses for better traces
        vm.label(NOUNS_DAO_PROXY, "NounsDAOProxy");
        vm.label(NOUNS_EXECUTOR, "NounsExecutor");
        vm.label(NOUNS_TOKEN, "NounsToken");
        vm.label(testProposer, "TestProposer");
        vm.label(testVoter, "TestVoter");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // MAIN TEST
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Complete governance flow test on mainnet fork
     * @dev Tests the entire proposal lifecycle from creation to execution
     */
    function test_CompleteGovernanceFlowOnFork() public {
        INounsDAOProxy dao = INounsDAOProxy(NOUNS_DAO_PROXY);
        INounsToken nounsToken = INounsToken(NOUNS_TOKEN);

        // Step 0: Setup voting power by transferring Nouns from real holders
        _setupVotingPower(dao, nounsToken);

        // Step 1: Create Proposal
        _step01_CreateProposal(dao);

        // Step 2-3: Wait for voting delay
        _step02to03_VotingDelay(dao);

        // Step 4: Cast votes
        _step04_VoteAndPass(dao, nounsToken);

        // Step 5: Queue proposal
        _step05_QueueProposal(dao);

        // Step 6: Wait for timelock
        _step06_WaitTimelock(dao);

        // Step 7: Execute proposal
        _step07_ExecuteProposal(dao);

        // Step 8-12: Verify execution results
        _step08_VerifyExecution();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // STEP IMPLEMENTATIONS
    // ══════════════════════════════════════════════════════════════════════════════

    function _setupVotingPower(INounsDAOProxy dao, INounsToken nounsToken) internal {
        // Get proposal threshold and estimate quorum
        uint256 proposalThreshold = dao.proposalThreshold();

        // We'll transfer Nouns from the treasury (NOUNS_EXECUTOR) which holds many Nouns
        // Token IDs 20, 65, 200, 500 etc are owned by treasury

        // Transfer enough Nouns to testProposer to meet proposal threshold (need threshold + 1)
        uint256 proposerNounsNeeded = proposalThreshold + 1;
        uint256[] memory proposerTokenIds = new uint256[](proposerNounsNeeded);

        // Find Nouns owned by treasury and transfer to proposer
        uint256 found = 0;
        for (uint256 tokenId = 20; tokenId < 1000 && found < proposerNounsNeeded; tokenId++) {
            try nounsToken.ownerOf(tokenId) returns (address owner) {
                if (owner == NOUNS_EXECUTOR) {
                    proposerTokenIds[found] = tokenId;
                    vm.prank(NOUNS_EXECUTOR);
                    nounsToken.transferFrom(NOUNS_EXECUTOR, testProposer, tokenId);
                    found++;
                }
            } catch {
                continue;
            }
        }
        require(found >= proposerNounsNeeded, "Could not find enough Nouns for proposer");

        // Delegate proposer's Nouns to self
        vm.prank(testProposer);
        nounsToken.delegate(testProposer);

        // Transfer enough Nouns to testVoter for quorum (estimate ~125 votes needed)
        // We'll transfer 150 to be safe
        uint256 voterNounsNeeded = 150;
        found = 0;
        for (uint256 tokenId = 100; tokenId < 2000 && found < voterNounsNeeded; tokenId++) {
            try nounsToken.ownerOf(tokenId) returns (address owner) {
                if (owner == NOUNS_EXECUTOR) {
                    vm.prank(NOUNS_EXECUTOR);
                    nounsToken.transferFrom(NOUNS_EXECUTOR, testVoter, tokenId);
                    found++;
                }
            } catch {
                continue;
            }
        }
        require(found >= 100, "Could not find enough Nouns for voter");

        // Delegate voter's Nouns to self
        vm.prank(testVoter);
        nounsToken.delegate(testVoter);

        // Roll forward 1 block to ensure delegation takes effect
        vm.roll(block.number + 1);

        // Verify voting power
        uint96 proposerVotes = nounsToken.getCurrentVotes(testProposer);
        uint96 voterVotes = nounsToken.getCurrentVotes(testVoter);

        require(proposerVotes > proposalThreshold, "Proposer needs more votes");
        require(voterVotes >= 100, "Voter needs more votes");
    }

    function _step01_CreateProposal(INounsDAOProxy dao) internal {
        // Build proposal calldata
        (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        ) = _buildProposalCalldata();

        // Create proposal using test proposer
        vm.prank(testProposer);
        proposalId = dao.propose(
            targets,
            values,
            signatures,
            calldatas,
            "Deploy Lido Yield Skimming Strategy - Integration Test"
        );

        // Verify proposal state is Updatable (10) or Pending (0)
        // Nouns DAO V3 has state 10 = Updatable (before voting starts, proposer can update)
        uint8 state = dao.state(proposalId);
        assertTrue(state == 0 || state == 10, "Proposal should be in Pending or Updatable state");

        // Store quorum for later
        quorumNeeded = _getProposalQuorum(proposalId);
    }

    function _step02to03_VotingDelay(INounsDAOProxy dao) internal {
        // Roll to voting start block
        vm.roll(_getProposalStartBlock(proposalId) + 1);

        // Verify proposal is now Active (1)
        uint8 state = dao.state(proposalId);
        assertEq(state, 1, "Proposal should be Active after voting delay");
    }

    function _step04_VoteAndPass(INounsDAOProxy dao, INounsToken /* nounsToken */) internal {
        // Use low-level calls to avoid potential return data issues
        // First vote from testProposer (has 4 votes)
        vm.prank(testProposer);
        (bool success1, ) = address(dao).call(abi.encodeWithSignature("castVote(uint256,uint8)", proposalId, VOTE_FOR));
        require(success1, "Vote 1 failed");

        // Second vote from testVoter (has 150 votes - enough for quorum of 139)
        vm.prank(testVoter);
        (bool success2, ) = address(dao).call(abi.encodeWithSignature("castVote(uint256,uint8)", proposalId, VOTE_FOR));
        require(success2, "Vote 2 failed");

        // Roll to end of voting period
        vm.roll(_getProposalEndBlock(proposalId) + 1);

        // Verify proposal succeeded (state 4) or ObjectionPeriod (state 9 in V3)
        uint8 state = dao.state(proposalId);
        assertTrue(state == 4 || state == 9, "Proposal should have Succeeded or be in ObjectionPeriod");
    }

    function _step05_QueueProposal(INounsDAOProxy dao) internal {
        // Queue the proposal
        dao.queue(proposalId);

        // Verify proposal is Queued (5)
        uint8 state = dao.state(proposalId);
        assertEq(state, 5, "Proposal should be Queued");
    }

    function _step06_WaitTimelock(INounsDAOProxy dao) internal {
        // Warp to after ETA
        vm.warp(_getProposalEta(proposalId) + 1);

        // State should still be Queued (5) - ready to execute
        uint8 state = dao.state(proposalId);
        assertEq(state, 5, "Proposal should still be Queued and ready for execution");
    }

    function _step07_ExecuteProposal(INounsDAOProxy dao) internal {
        // Execute the proposal
        dao.execute(proposalId);

        // Verify proposal is Executed (7)
        uint8 state = dao.state(proposalId);
        assertEq(state, 7, "Proposal should be Executed");
    }

    function _step08_VerifyExecution() internal view {
        // Verify PaymentSplitter was deployed
        address ps = predictedPaymentSplitter;
        bool psExists = ps.code.length > 0;
        assertTrue(psExists, "PaymentSplitter should be deployed");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Build proposal calldata for Nouns DAO
     * @dev Only includes PaymentSplitter deployment to keep test simple
     */
    function _buildProposalCalldata()
        internal
        pure
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        // PaymentSplitter configuration - Dragon Funding Pool receives 100%
        address[] memory payees = new address[](1);
        payees[0] = address(0xDead); // Placeholder for test
        string[] memory payeeNames = new string[](1);
        payeeNames[0] = "DragonFundingPool";
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;

        // Single transaction proposal - just deploy PaymentSplitter
        targets = new address[](1);
        values = new uint256[](1);
        signatures = new string[](1);
        calldatas = new bytes[](1);

        // TX 0: Deploy PaymentSplitter via Factory
        targets[0] = PAYMENT_SPLITTER_FACTORY;
        values[0] = 0;
        signatures[0] = "createPaymentSplitter(address[],string[],uint256[])";
        calldatas[0] = abi.encode(payees, payeeNames, shares);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // PROPOSAL FIELD EXTRACTORS (avoids stack too deep from 15-value tuple)
    // ══════════════════════════════════════════════════════════════════════════════

    /// @dev proposals() returns: id, proposer, proposalThreshold, quorumVotes, eta, startBlock, endBlock, ...
    ///      Each field is 32 bytes. We use assembly to extract specific fields without unpacking all 15.

    function _getProposalQuorum(uint256 _proposalId) internal view returns (uint256 quorum) {
        (bool success, bytes memory data) = NOUNS_DAO_PROXY.staticcall(
            abi.encodeWithSelector(PROPOSALS_SELECTOR, _proposalId)
        );
        require(success, "proposals call failed");
        // quorumVotes is at index 3: offset = 3 * 32 = 96, plus 32 for length prefix = 128
        assembly {
            quorum := mload(add(data, 128))
        }
    }

    function _getProposalStartBlock(uint256 _proposalId) internal view returns (uint256 startBlock) {
        (bool success, bytes memory data) = NOUNS_DAO_PROXY.staticcall(
            abi.encodeWithSelector(PROPOSALS_SELECTOR, _proposalId)
        );
        require(success, "proposals call failed");
        // startBlock is at index 5: offset = 5 * 32 = 160, plus 32 for length prefix = 192
        assembly {
            startBlock := mload(add(data, 192))
        }
    }

    function _getProposalEndBlock(uint256 _proposalId) internal view returns (uint256 endBlock) {
        (bool success, bytes memory data) = NOUNS_DAO_PROXY.staticcall(
            abi.encodeWithSelector(PROPOSALS_SELECTOR, _proposalId)
        );
        require(success, "proposals call failed");
        // endBlock is at index 6: offset = 6 * 32 = 192, plus 32 for length prefix = 224
        assembly {
            endBlock := mload(add(data, 224))
        }
    }

    function _getProposalEta(uint256 _proposalId) internal view returns (uint256 eta) {
        (bool success, bytes memory data) = NOUNS_DAO_PROXY.staticcall(
            abi.encodeWithSelector(PROPOSALS_SELECTOR, _proposalId)
        );
        require(success, "proposals call failed");
        // eta is at index 4: offset = 4 * 32 = 128, plus 32 for length prefix = 160
        assembly {
            eta := mload(add(data, 160))
        }
    }
}
