// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenizedAllocationMechanism, IBaseAllocationStrategy } from "src/mechanisms/TokenizedAllocationMechanism.sol";

/**
 * @notice Configuration parameters for allocation mechanism initialization
 * @dev All timing parameters are in seconds
 */
struct AllocationConfig {
    /// @notice Underlying ERC20 asset token for deposits
    IERC20 asset;
    /// @notice Name for allocation mechanism shares (ERC20 metadata)
    string name;
    /// @notice Symbol for allocation mechanism shares (ERC20 metadata)
    string symbol;
    /// @notice Delay before voting begins after proposal creation
    /// @dev In seconds. Provides time for proposal review before voting starts
    uint256 votingDelay;
    /// @notice Duration of the voting period
    /// @dev In seconds. Time window during which users can cast votes
    uint256 votingPeriod;
    /// @notice Minimum voting power required for proposal to pass
    /// @dev In share units. Proposal needs >= quorumShares total votes to succeed
    uint256 quorumShares;
    /// @notice Delay before redemptions can begin after vote finalization
    /// @dev In seconds. Security buffer before funds can be withdrawn
    uint256 timelockDelay;
    /// @notice Duration of redemption window
    /// @dev In seconds. Time window during which shares can be redeemed
    uint256 gracePeriod;
    /// @notice Address that owns/controls the allocation mechanism
    /// @dev Typically the deployer. Has admin privileges
    address owner;
}

/**
 * @title Base Allocation Mechanism
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract base for allocation/voting mechanisms using lightweight proxy pattern
 * @dev Follows Yearn V3 architecture: minimal proxy delegating to shared TokenizedAllocationMechanism
 *
 *      ARCHITECTURE PATTERN:
 *      ═══════════════════════════════════
 *      - Inheritors only implement custom hooks (no shared logic duplication)
 *      - Shared logic lives in TokenizedAllocationMechanism (implementation)
 *      - Each mechanism is a lightweight proxy with custom behavior via hooks
 *      - Delegatecall pattern: proxy storage, implementation logic
 *
 *      HOOK SYSTEM:
 *      ═══════════════════════════════════
 *      13 abstract hooks to implement:
 *
 *      Registration:
 *      - _beforeSignupHook: Allow/block user registration
 *      - _getVotingPowerHook: Calculate voting power on signup
 *
 *      Proposing:
 *      - _beforeProposeHook: Allow/block proposal creation
 *      - _validateProposalHook: Validate proposal exists
 *
 *      Voting:
 *      - _processVoteHook: Process vote and update voting power
 *      - _hasQuorumHook: Check if proposal reached quorum
 *
 *      Distribution:
 *      - _convertVotesToShares: Convert votes to vault shares
 *      - _getRecipientAddressHook: Get recipient for proposal
 *      - _requestCustomDistributionHook: Custom share distribution
 *
 *      Finalization:
 *      - _beforeFinalizeVoteTallyHook: Pre-finalization checks
 *
 *      Withdrawal:
 *      - _availableWithdrawLimit: Enforce timelock/grace period
 *
 *      Accounting:
 *      - _calculateTotalAssetsHook: Total assets including matching pools
 *
 *      LIFECYCLE:
 *      ═══════════════════════════════════
 *      1. Deploy: Constructor calls TokenizedAllocationMechanism.initialize()
 *      2. Registration: Users deposit assets and receive voting power
 *      3. Propose: Create proposals for funding allocation
 *      4. Vote: Users cast votes (Against/For/Abstain)
 *      5. Finalize: Tally votes, determine winning proposals
 *      6. Queue: Mint shares for successful proposals (after timelock)
 *      7. Redeem: Recipients redeem shares for assets (during grace period)
 *
 *      TIMELOCK & GRACE PERIOD:
 *      ═══════════════════════════════════
 *      - Timelock: Security delay before redemptions begin
 *      - Grace Period: Window during which redemptions are allowed
 *      - After grace period: Unredeemed shares become non-withdrawable
 *
 * @custom:security All hooks called via delegatecall from implementation
 * @custom:security onlySelf modifier prevents direct external calls to hooks
 */
abstract contract BaseAllocationMechanism is IBaseAllocationStrategy {
    // ---------- Immutable Storage ----------

    /// @notice Address of the shared TokenizedAllocationMechanism implementation
    address internal immutable tokenizedAllocationAddress;

    /// @notice Underlying asset for the allocation mechanism
    IERC20 internal immutable asset;

    // ---------- Events ----------

    /// @notice Emitted when the allocation mechanism is initialized
    event AllocationMechanismInitialized(
        address indexed implementation,
        address indexed asset,
        string name,
        string symbol
    );

    // ---------- Constructor ----------

    /// @notice Initializes the allocation mechanism with implementation and configuration
    /// @param _implementation Address of the TokenizedAllocationMechanism implementation
    /// @param _config Configuration parameters for the allocation mechanism
    constructor(address _implementation, AllocationConfig memory _config) {
        // Store immutable values
        tokenizedAllocationAddress = _implementation;
        asset = _config.asset;

        // Initialize the TokenizedAllocationMechanism storage via delegatecall
        (bool success, ) = _implementation.delegatecall(
            abi.encodeCall(
                TokenizedAllocationMechanism.initialize,
                (
                    _config.owner, // owner
                    _config.asset,
                    _config.name,
                    _config.symbol,
                    _config.votingDelay,
                    _config.votingPeriod,
                    _config.quorumShares,
                    _config.timelockDelay,
                    _config.gracePeriod
                )
            )
        );
        require(success, "Initialization failed");

        emit AllocationMechanismInitialized(_implementation, address(_config.asset), _config.name, _config.symbol);
    }

    // ============================================
    // ABSTRACT HOOKS - REGISTRATION
    // ============================================

    /**
     * @notice REQUIRED: Determines if a user can register
     * @dev Called before signup to implement access control
     *
     *      IMPLEMENTATION GUIDANCE:
     *      - Return true to allow registration
     *      - Return false to block (will revert signup)
     *      - Can check allowlists, blocklists, KYC status, etc.
     *
     *      COMMON PATTERNS:
     *      - Open: Always return true (permissionless)
     *      - Allowlist: Check mapping(address => bool) allowedUsers
     *      - Minimum deposit: Check deposit >= minimumAmount
     *
     * @param user Address attempting to register
     * @return allow True to allow registration, false to block
     */
    function _beforeSignupHook(address user) internal virtual returns (bool);

    /**
     * @notice REQUIRED: Determines if an address can create proposals
     * @dev Called before propose to implement proposer restrictions
     *
     *      IMPLEMENTATION GUIDANCE:
     *      - Return true to allow proposal creation
     *      - Return false to block (will revert)
     *      - Can check minimum voting power, specific roles, etc.
     *
     *      COMMON PATTERNS:
     *      - Open: Always return true
     *      - Minimum power: Check votingPower >= threshold
     *      - Registered only: Check user has deposited
     *
     * @param proposer Address attempting to create proposal
     * @return allow True to allow proposal, false to block
     */
    function _beforeProposeHook(address proposer) internal view virtual returns (bool);

    /**
     * @notice REQUIRED: Calculates voting power assigned on registration
     * @dev Called during signup to determine user's initial voting power
     *
     *      IMPLEMENTATION GUIDANCE:
     *      - Must return value > 0 for successful registration
     *      - Should be deterministic based on deposit amount
     *      - Consider manipulation resistance (flash loan protection)
     *
     *      COMMON PATTERNS:
     *      - Linear: power = deposit (1 token = 1 vote)
     *      - Quadratic: power = sqrt(deposit) (reduces whale influence)
     *      - Capped: power = min(deposit, maxPower)
     *      - Time-weighted: power = f(deposit, stakeDuration)
     *
     *      SECURITY CONSIDERATIONS:
     *      - Prevent flash loan manipulation (use checkpoints/locks)
     *      - Validate deposit amount > 0
     *      - Ensure calculation cannot overflow
     *
     * @param user Address registering (can be used for user-specific logic)
     * @param deposit Amount of underlying tokens deposited (in asset base units)
     * @return power Voting power to assign (0 = registration fails)
     */
    function _getVotingPowerHook(address user, uint256 deposit) internal view virtual returns (uint256);

    // ============================================
    // ABSTRACT HOOKS - PROPOSAL VALIDATION
    // ============================================

    /**
     * @notice REQUIRED: Validates that a proposal ID exists
     * @dev Called to verify proposal exists before operations
     *
     * @param pid Proposal ID to validate
     * @return valid True if proposal exists and is valid
     */
    function _validateProposalHook(uint256 pid) internal view virtual returns (bool);

    // ============================================
    // ABSTRACT HOOKS - VOTING
    // ============================================

    /**
     * @notice REQUIRED: Processes a vote and updates voting power
     * @dev Called when user casts a vote. Must update vote tallies and return updated voting power
     *
     *      IMPLEMENTATION GUIDANCE:
     *      - Record vote in proposal's tally
     *      - Deduct used voting power from voter's available power
     *      - Return new voting power (must be <= oldPower)
     *      - Prevent double voting or power overflow
     *
     *      VOTING MODELS:
     *      - One-time: Use full power once (newPower = 0)
     *      - Proportional: Deduct weight from power (newPower = oldPower - weight)
     *      - Quadratic: Deduct weight squared (cost increases with usage)
     *
     * @param pid Proposal ID being voted on
     * @param voter Address casting the vote
     * @param choice Vote type (Against=0, For=1, Abstain=2)
     * @param weight Amount of voting power to use
     * @param oldPower Voter's current voting power before this vote
     * @return newPower Voter's voting power after this vote (must be <= oldPower)
     */
    function _processVoteHook(
        uint256 pid,
        address voter,
        TokenizedAllocationMechanism.VoteType choice,
        uint256 weight,
        uint256 oldPower
    ) internal virtual returns (uint256 newPower);

    /**
     * @notice REQUIRED: Checks if proposal reached quorum
     * @dev Called to determine if proposal has enough votes to pass
     *
     * @param pid Proposal ID
     * @return hasQuorum True if proposal has sufficient votes
     */
    function _hasQuorumHook(uint256 pid) internal view virtual returns (bool);

    // ============================================
    // ABSTRACT HOOKS - DISTRIBUTION
    // ============================================

    /**
     * @notice REQUIRED: Converts votes to vault shares for winning proposal
     * @dev Called when queuing successful proposal. Determines funding allocation
     *
     *      COMMON PATTERNS:
     *      - Direct: shares = votes (1 vote = 1 asset)
     *      - Quadratic: shares = votes^2 (quadratic funding)
     *      - Matched: shares = votes + matching(votes)
     *
     * @param pid Proposal ID being queued
     * @return sharesToMint Vault shares to allocate (in share base units)
     */
    function _convertVotesToShares(uint256 pid) internal view virtual returns (uint256 sharesToMint);

    /**
     * @notice REQUIRED: Pre-finalization validation hook
     * @dev Called before finalizeVoteTally to enforce any custom rules
     *
     * @return allow True to proceed with finalization
     */
    function _beforeFinalizeVoteTallyHook() internal virtual returns (bool);

    /**
     * @notice REQUIRED: Returns recipient address for a proposal
     * @dev Called during redemption to determine where shares go
     *
     * @param pid Proposal ID
     * @return recipient Address to receive the minted shares
     */
    function _getRecipientAddressHook(uint256 pid) internal view virtual returns (address recipient);

    /**
     * @notice OPTIONAL: Custom distribution instead of standard share minting
     * @dev Called during queue. Return (true, amount) to skip default minting
     *
     *      USE CASES:
     *      - Direct asset transfer instead of shares
     *      - Multi-recipient distribution
     *      - Custom vesting schedules
     *
     *      DEFAULT BEHAVIOR:
     *      Return (false, 0) to use standard share minting
     *
     * @param recipient Address of the recipient
     * @param sharesToMint Number of shares to distribute
     * @return handled True if custom distribution performed (skips default minting)
     * @return assetsTransferred Amount of assets transferred (for totalAssets accounting)
     */
    function _requestCustomDistributionHook(
        address recipient,
        uint256 sharesToMint
    ) internal virtual returns (bool handled, uint256 assetsTransferred);

    /// @dev Hook to get the available withdraw limit for a share owner
    /// @dev Default implementation enforces timelock and grace period boundaries
    /// @dev Can be overridden for custom withdrawal limit logic
    /// @return limit Available withdraw limit (type(uint256).max for unlimited, 0 for blocked)
    function _availableWithdrawLimit(address /* shareOwner */) internal view virtual returns (uint256) {
        // Get the global redemption start time
        uint256 globalRedemptionStart = _getGlobalRedemptionStart();

        // If no global redemption time set (not finalized), no withdrawals allowed
        if (globalRedemptionStart == 0) {
            return 0;
        }

        // Check if still in timelock period
        if (block.timestamp < globalRedemptionStart) {
            return 0; // Cannot withdraw during timelock
        }

        // Check if grace period has expired
        uint256 gracePeriod = _getGracePeriod();
        if (block.timestamp > globalRedemptionStart + gracePeriod) {
            return 0; // Cannot withdraw after grace period expires
        }

        // Within valid redemption window - no limit
        return type(uint256).max;
    }

    /// @dev Hook to calculate total assets including any matching pools or custom logic
    /// @return totalAssets Total assets for this allocation mechanism
    function _calculateTotalAssetsHook() internal view virtual returns (uint256);

    // ---------- External Hook Functions (Yearn V3 Pattern) ----------
    // These are called by TokenizedAllocationMechanism via delegatecall
    // and use onlySelf modifier to ensure security

    /// @notice Ensures function can only be called via delegatecall from TokenizedAllocationMechanism
    /// @dev In delegatecall context, msg.sender is the proxy address (address(this)), not the caller
    modifier onlySelf() {
        // In delegatecall context, msg.sender must be address(this) to ensure
        // hooks can only be called via delegatecall from TokenizedAllocationMechanism
        require(msg.sender == address(this), "!self");
        _;
    }

    /// @notice External wrapper for _beforeSignupHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param user Address attempting to register
    /// @return allow True to allow registration, false to block
    function beforeSignupHook(address user) external onlySelf returns (bool) {
        return _beforeSignupHook(user);
    }

    /// @notice External wrapper for _beforeProposeHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param proposer Address attempting to create proposal
    /// @return allow True to allow proposal, false to block
    function beforeProposeHook(address proposer) external view onlySelf returns (bool) {
        return _beforeProposeHook(proposer);
    }

    /// @notice External wrapper for _getVotingPowerHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param user Address registering
    /// @param deposit Amount deposited in asset base units
    /// @return power Voting power to assign
    function getVotingPowerHook(address user, uint256 deposit) external view onlySelf returns (uint256) {
        return _getVotingPowerHook(user, deposit);
    }

    /// @notice External wrapper for _validateProposalHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param pid Proposal ID to validate
    /// @return valid True if proposal exists and is valid
    function validateProposalHook(uint256 pid) external view onlySelf returns (bool) {
        return _validateProposalHook(pid);
    }

    /// @notice External wrapper for _processVoteHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param pid Proposal ID being voted on
    /// @param voter Address casting the vote
    /// @param choice Vote type (0=Against, 1=For, 2=Abstain)
    /// @param weight Amount of voting power to use
    /// @param oldPower Voter's current voting power
    /// @return newPower Voter's voting power after this vote
    function processVoteHook(
        uint256 pid,
        address voter,
        uint8 choice,
        uint256 weight,
        uint256 oldPower
    ) external onlySelf returns (uint256) {
        return _processVoteHook(pid, voter, TokenizedAllocationMechanism.VoteType(choice), weight, oldPower);
    }

    /// @notice External wrapper for _hasQuorumHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param pid Proposal ID
    /// @return hasQuorum True if proposal has sufficient votes
    function hasQuorumHook(uint256 pid) external view onlySelf returns (bool) {
        return _hasQuorumHook(pid);
    }

    /// @notice External wrapper for _convertVotesToShares, called by TokenizedAllocationMechanism via delegatecall
    /// @param pid Proposal ID being queued
    /// @return sharesToMint Vault shares to allocate in share base units
    function convertVotesToShares(uint256 pid) external view onlySelf returns (uint256) {
        return _convertVotesToShares(pid);
    }

    /// @notice External wrapper for _beforeFinalizeVoteTallyHook, called by TokenizedAllocationMechanism via delegatecall
    /// @return allow True to proceed with finalization
    function beforeFinalizeVoteTallyHook() external onlySelf returns (bool) {
        return _beforeFinalizeVoteTallyHook();
    }

    /// @notice External wrapper for _getRecipientAddressHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param pid Proposal ID
    /// @return recipient Address to receive the minted shares
    function getRecipientAddressHook(uint256 pid) external view onlySelf returns (address) {
        return _getRecipientAddressHook(pid);
    }

    /// @notice External wrapper for _requestCustomDistributionHook, called by TokenizedAllocationMechanism via delegatecall
    /// @param recipient Address of the recipient
    /// @param sharesToMint Number of shares to distribute
    /// @return handled True if custom distribution performed
    /// @return assetsTransferred Amount of assets transferred
    function requestCustomDistributionHook(
        address recipient,
        uint256 sharesToMint
    ) external onlySelf returns (bool handled, uint256 assetsTransferred) {
        return _requestCustomDistributionHook(recipient, sharesToMint);
    }

    /// @notice External wrapper for _availableWithdrawLimit, called by TokenizedAllocationMechanism via delegatecall
    /// @param shareOwner Address to check withdraw limit for
    /// @return limit Available withdraw limit (type(uint256).max for unlimited, 0 for blocked)
    function availableWithdrawLimit(address shareOwner) external view onlySelf returns (uint256) {
        return _availableWithdrawLimit(shareOwner);
    }

    /// @notice External wrapper for _calculateTotalAssetsHook, called by TokenizedAllocationMechanism via delegatecall
    /// @return totalAssets Total assets for this allocation mechanism
    function calculateTotalAssetsHook() external view onlySelf returns (uint256) {
        return _calculateTotalAssetsHook();
    }

    // ---------- Internal Helpers ----------

    /// @notice Access TokenizedAllocationMechanism interface for internal calls
    /// @dev Uses current contract address since storage is local
    function _tokenizedAllocation() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(this));
    }

    /// @notice Get grace period from configuration
    /// @return Grace period in seconds
    function _getGracePeriod() internal view returns (uint256) {
        return _tokenizedAllocation().gracePeriod();
    }

    /// @dev Get global redemption start timestamp
    /// @return Timestamp when redemption window opens (0 if not finalized)
    function _getGlobalRedemptionStart() internal view returns (uint256) {
        return _tokenizedAllocation().globalRedemptionStart();
    }

    // ---------- Fallback Function ----------

    /// @notice Delegates all undefined function calls to TokenizedAllocationMechanism
    /// @dev This enables the proxy pattern where shared logic lives in the implementation
    fallback() external payable virtual {
        address _impl = tokenizedAllocationAddress;
        assembly {
            // Copy calldata to memory
            calldatacopy(0, 0, calldatasize())

            // Delegatecall to implementation contract
            let result := delegatecall(gas(), _impl, 0, calldatasize(), 0, 0)

            // Copy return data
            returndatacopy(0, 0, returndatasize())

            // Handle result
            switch result
            case 0 {
                // Delegatecall failed, revert with error data
                revert(0, returndatasize())
            }
            default {
                // Delegatecall succeeded, return data
                return(0, returndatasize())
            }
        }
    }

    /// @notice Receive function to accept ETH
    receive() external payable virtual {}

    // ---------- View Helpers for Inheritors ----------

    /// @notice Get the current proposal count
    /// @dev Helper for concrete implementations to access storage
    function _getProposalCount() internal view returns (uint256) {
        return _tokenizedAllocation().getProposalCount();
    }

    /// @notice Check if a proposal exists
    /// @dev Helper for concrete implementations
    function _proposalExists(uint256 pid) internal view returns (bool) {
        return pid > 0 && pid <= _getProposalCount();
    }

    /// @notice Get proposal details
    /// @dev Helper for concrete implementations
    function _getProposal(uint256 pid) internal view returns (TokenizedAllocationMechanism.Proposal memory) {
        return _tokenizedAllocation().proposals(pid);
    }

    /// @notice Get voting power for an address
    /// @dev Helper for concrete implementations
    function _getVotingPower(address user) internal view returns (uint256) {
        return _tokenizedAllocation().votingPower(user);
    }

    /// @notice Get quorum shares requirement
    /// @dev Helper for concrete implementations
    function _getQuorumShares() internal view returns (uint256) {
        return _tokenizedAllocation().quorumShares();
    }
}
