// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @notice Interface for base allocation mechanism strategy implementations
/// @dev Follows Yearn V3 pattern where shared implementation calls base strategy via interface
interface IBaseAllocationStrategy {
    /// @notice Hook to allow or block registration
    function beforeSignupHook(address user) external returns (bool);

    /// @notice Hook to allow or block proposal creation
    function beforeProposeHook(address proposer) external view returns (bool);

    /// @notice Hook to calculate new voting power on registration
    function getVotingPowerHook(address user, uint256 deposit) external view returns (uint256);

    /// @notice Hook to validate existence and integrity of a proposal ID
    function validateProposalHook(uint256 pid) external view returns (bool);

    /// @notice Hook to process a vote
    function processVoteHook(
        uint256 pid,
        address voter,
        uint8 choice,
        uint256 weight,
        uint256 oldPower
    ) external returns (uint256 newPower);

    /// @notice Check if proposal met quorum requirement
    function hasQuorumHook(uint256 pid) external view returns (bool);

    /// @notice Hook to convert final vote tallies into vault shares to mint
    function convertVotesToShares(uint256 pid) external view returns (uint256 sharesToMint);

    /// @notice Hook to modify the behavior of finalizeVoteTally
    function beforeFinalizeVoteTallyHook() external returns (bool);

    /// @notice Hook to fetch the recipient address for a proposal
    function getRecipientAddressHook(uint256 pid) external view returns (address recipient);

    /// @notice Hook to perform custom distribution of shares when a proposal is queued
    /// @dev If this returns (true, assetsTransferred), default share minting is skipped and totalAssets is updated
    /// @param recipient Address of the recipient for the proposal
    /// @param sharesToMint Number of shares to distribute/mint to the recipient
    /// @return handled True if custom distribution was handled, false to use default minting
    /// @return assetsTransferred Amount of assets transferred directly to recipient (to update totalAssets)
    function requestCustomDistributionHook(
        address recipient,
        uint256 sharesToMint
    ) external returns (bool handled, uint256 assetsTransferred);

    /// @notice Hook to get the available withdraw limit for a share owner
    function availableWithdrawLimit(address shareOwner) external view returns (uint256);

    /// @notice Hook to calculate total assets including any matching pools or custom logic
    function calculateTotalAssetsHook() external view returns (uint256);
}

/**
 * @title TokenizedAllocationMechanism
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Shared implementation for allocation/voting mechanisms (Yearn V3 pattern)
 * @dev Handles all standard voting logic via delegatecall from mechanism proxies
 *
 *      PROPOSAL STATE MACHINE:
 *      ═══════════════════════════════════
 *      Pending → Active → Tallying → Defeated/Succeeded → Queued → Redeemable → Expired
 *             ↓
 *          Canceled
 *
 *      STATE DESCRIPTIONS:
 *      - Pending: Proposal created, waiting for votingDelay
 *      - Active: Voting period active, users can cast votes
 *      - Tallying: Voting ended, waiting for finalization
 *      - Defeated: Voting ended, failed quorum
 *      - Succeeded: Voting ended, passed quorum
 *      - Queued: Shares minted, waiting for timelock
 *      - Redeemable: Timelock passed, within grace period
 *      - Expired: Grace period passed, redemptions closed
 *      - Canceled: Proposer canceled (terminal state)
 *
 *      LIFECYCLE TIMELINE:
 *      ═══════════════════════════════════
 *      T0: Proposal created (Pending)
 *      T0 + votingDelay: Voting opens (Active)
 *      T0 + votingDelay + votingPeriod: Voting closes (Tallying)
 *      Anyone calls finalizeVoteTally(): Defeated or Succeeded
 *      If Succeeded, anyone calls queue(): Queued (shares minted)
 *      Queued + timelockDelay: Redeemable (redemptions allowed)
 *      Redeemable + gracePeriod: Expired (redemptions closed)
 *
 *      VOTING MECHANICS:
 *      ═══════════════════════════════════
 *      1. Users signup (deposit assets, get voting power)
 *      2. Proposals created during registration period
 *      3. Users cast votes (Against/For/Abstain)
 *      4. Votes finalized after votingPeriod
 *      5. Successful proposals get shares minted
 *      6. Recipients redeem shares for assets
 *
 *      SECURITY FEATURES:
 *      ═══════════════════════════════════
 *      - Timelock: Delay before redemptions (security buffer)
 *      - Grace Period: Limited redemption window
 *      - Quorum: Minimum votes required
 *      - EIP-712: Gasless signups and votes
 *      - Reentrancy protection
 *      - Pausability
 *
 * @custom:security State machine enforces proper proposal progression
 * @custom:security Timelock provides security delay before fund distribution
 */
contract TokenizedAllocationMechanism is IERC20 {
    using SafeERC20 for IERC20;
    using SafeERC20 for ERC20;
    using Math for uint256;

    // Custom Errors
    error ZeroAssetAddress();
    error ZeroVotingDelay();
    error ZeroVotingPeriod();
    error ZeroQuorumShares();
    error ZeroTimelockDelay();
    error ZeroGracePeriod();
    error ZeroStartBlock();
    /// @param startTime Proposed start timestamp in seconds
    /// @param currentTime Current block timestamp in seconds
    error InvalidStartTime(uint256 startTime, uint256 currentTime);
    error EmptyName();
    error EmptySymbol();
    /// @param user Address attempting to register
    error RegistrationBlocked(address user);
    /// @param currentTime Current block timestamp in seconds
    /// @param endTime Voting end timestamp in seconds
    error VotingEnded(uint256 currentTime, uint256 endTime);
    /// @param user Address that is already registered
    error AlreadyRegistered(address user);
    /// @param deposit Deposit amount in asset base units (token decimals)
    /// @param maxAllowed Maximum allowed deposit in asset base units
    error DepositTooLarge(uint256 deposit, uint256 maxAllowed);
    /// @param votingPower Voting power in shares units in share base units
    /// @param maxAllowed Maximum allowed voting power in share base units
    error VotingPowerTooLarge(uint256 votingPower, uint256 maxAllowed);
    /// @param deposit Deposit amount in asset base units (token decimals)
    error InsufficientDeposit(uint256 deposit);
    /// @param proposer Address attempting to propose
    error ProposeNotAllowed(address proposer);
    /// @param recipient Invalid recipient address
    error InvalidRecipient(address recipient);
    /// @param user Invalid user address
    error InvalidUser(address user);
    /// @param recipient Recipient with an active proposal
    error RecipientUsed(address recipient);
    /// @param pid Proposal id
    /// @param expected Expected recipient address
    /// @param actual Provided recipient address
    error RecipientMismatch(uint256 pid, address expected, address actual);
    /// @param pid Proposal id
    error DescriptionMismatch(uint256 pid);
    error EmptyDescription();
    /// @param length Provided description length in bytes
    /// @param maxLength Maximum allowed length in bytes
    error DescriptionTooLong(uint256 length, uint256 maxLength);
    /// @param currentTime Current block timestamp in seconds
    /// @param endTime Voting end timestamp in seconds
    error VotingNotEnded(uint256 currentTime, uint256 endTime);
    error TallyAlreadyFinalized();
    error FinalizationBlocked();
    error TallyNotFinalized();
    /// @param pid Invalid proposal id
    error InvalidProposal(uint256 pid);
    /// @param pid Canceled proposal id
    error ProposalCanceledError(uint256 pid);
    /// @param pid Proposal id
    /// @param forVotes Total for votes in share base units
    /// @param againstVotes Total against votes in share base units
    /// @param required Quorum threshold in shares in share base units
    error NoQuorum(uint256 pid, uint256 forVotes, uint256 againstVotes, uint256 required);
    /// @param pid Proposal id
    error AlreadyQueued(uint256 pid);
    error QueueingClosedAfterRedemption();
    /// @param pid Proposal id
    /// @param sharesToMint Calculated shares to mint in share base units
    error NoAllocation(uint256 pid, uint256 sharesToMint);
    /// @param requested Assets requested in base units (token decimals)
    /// @param available Available assets in base units (token decimals)
    error InsufficientAssets(uint256 requested, uint256 available);
    /// @param currentTime Current block timestamp in seconds
    /// @param startTime Voting start timestamp in seconds
    /// @param endTime Voting end timestamp in seconds
    error VotingClosed(uint256 currentTime, uint256 startTime, uint256 endTime);
    /// @param weight Vote weight in shares in share base units
    /// @param votingPower Voter's voting power in shares in share base units
    error InvalidWeight(uint256 weight, uint256 votingPower);
    /// @param weight Vote weight in shares in share base units
    /// @param maxAllowed Maximum allowed weight in shares in share base units
    error WeightTooLarge(uint256 weight, uint256 maxAllowed);
    /// @param oldPower Previous voting power in shares in share base units
    /// @param newPower New voting power in shares in share base units
    error PowerIncreased(uint256 oldPower, uint256 newPower);
    /// @param caller Caller address
    /// @param proposer Expected proposer address
    error NotProposer(address caller, address proposer);
    /// @param pid Proposal id
    error AlreadyCanceled(uint256 pid);
    error Unauthorized();
    error AlreadyInitialized();
    error PausedError();
    error ReentrantCall();
    /// @param deadline Signature deadline timestamp in seconds
    /// @param currentTime Current block timestamp in seconds
    error ExpiredSignature(uint256 deadline, uint256 currentTime);
    error InvalidSignature();
    /// @param recovered Address recovered from signature
    /// @param expected Expected signer address
    error InvalidSigner(address recovered, address expected);

    /// @notice Maximum safe value for internal math to avoid overflows
    /// @dev Capped at uint128.max to keep intermediate operations within safe bounds
    uint256 public constant MAX_SAFE_VALUE = type(uint128).max;

    /// @notice Storage slot for allocation mechanism data (EIP-1967-like deterministic slot)
    /// @dev Calculated as keccak256("tokenized.allocation.storage") - 1 to minimize collision risk
    bytes32 private constant ALLOCATION_STORAGE_SLOT = bytes32(uint256(keccak256("tokenized.allocation.storage")) - 1);

    /// @notice EIP-712 Domain separator typehash
    /// @dev Used to compute domain separator for structured data signing
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Signup typehash for EIP-712 structured data
    /// @dev Typed data: Signup(user, payer, deposit, nonce, deadline)
    bytes32 private constant SIGNUP_TYPEHASH =
        keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");

    /// @notice CastVote typehash for EIP-712 structured data
    /// @dev Typed data: CastVote(voter, proposalId, choice, weight, expectedRecipient, nonce, deadline)
    bytes32 private constant CAST_VOTE_TYPEHASH =
        keccak256(
            "CastVote(address voter,uint256 proposalId,uint8 choice,uint256 weight,address expectedRecipient,uint256 nonce,uint256 deadline)"
        );

    /// @notice EIP-712 version string used in domain separator
    /// @dev Update only with extreme caution; changing breaks signature domain
    string private constant EIP712_VERSION = "1";

    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Vote types for proposal voting
     * @dev Used in castVote() to indicate vote direction
     */
    enum VoteType {
        /// @notice Vote against the proposal
        Against,
        /// @notice Vote in favor of the proposal
        For,
        /// @notice Abstain from voting (recorded but doesn't affect outcome)
        Abstain
    }

    /**
     * @notice Proposal lifecycle states
     * @dev State machine progression enforced by contract logic
     */
    enum ProposalState {
        /// @notice Created, waiting for votingDelay to pass
        Pending,
        /// @notice Voting period active, can cast votes
        Active,
        /// @notice Proposer canceled, terminal state
        Canceled,
        /// @notice Voting ended, awaiting finalization
        Tallying,
        /// @notice Finalized, failed quorum (terminal)
        Defeated,
        /// @notice Finalized, passed quorum, ready to queue
        Succeeded,
        /// @notice Shares minted, waiting for timelock
        Queued,
        /// @notice Timelock passed, in grace period (can redeem)
        Redeemable,
        /// @notice Grace period ended (redemptions closed)
        Expired
    }

    /**
     * @notice Core proposal data used throughout the allocation mechanism
     * @dev Stores immutable metadata for a proposal; dynamic tallies are kept elsewhere
     */
    struct Proposal {
        /// @notice Number of shares requested if proposal succeeds in share base units
        uint256 sharesRequested;
        /// @notice Address that created the proposal
        address proposer;
        /// @notice Intended recipient of minted shares upon queue
        address recipient;
        /// @notice Human-readable description or rationale for the proposal
        string description;
        /// @notice True if the proposer canceled the proposal (terminal state)
        bool canceled;
    }

    /// @notice Main storage struct containing all allocation mechanism state
    /// @dev Stored at a deterministic slot; see {ALLOCATION_STORAGE_SLOT}
    struct AllocationStorage {
        // Basic information
        /// @notice ERC20 name for the shares token
        string name;
        /// @notice ERC20 symbol for the shares token
        string symbol;
        /// @notice Underlying ERC20 asset used for deposits and redemptions
        IERC20 asset;
        // Configuration (immutable after initialization)
        /// @notice Block number at initialization for legacy compatibility (blocks)
        uint256 startBlock;
        /// @notice Voting delay after start before voting opens (seconds)
        uint256 votingDelay;
        /// @notice Voting duration once opened (seconds)
        uint256 votingPeriod;
        /// @notice Timelock duration after queue before redemptions (seconds)
        uint256 timelockDelay;
        /// @notice Grace period during which redemptions are allowed (seconds)
        uint256 gracePeriod;
        /// @notice Quorum threshold in shares required for success in share base units
        uint256 quorumShares;
        /// @notice Mechanism start timestamp (seconds)
        uint256 startTime;
        /// @notice Timestamp when voting opens (startTime + votingDelay) (seconds)
        uint256 votingStartTime;
        /// @notice Timestamp when voting ends (startTime + votingDelay + votingPeriod) (seconds)
        uint256 votingEndTime;
        /// @notice Timestamp when {finalizeVoteTally} was called (seconds)
        uint256 tallyFinalizedTime;
        // Access control
        /// @notice Current contract owner authorized to manage configuration
        address owner;
        /// @notice Pending owner waiting to accept ownership
        address pendingOwner;
        /// @notice Global pause flag to disable mutating actions
        bool paused;
        /// @notice True once {initialize} has been successfully called
        bool initialized;
        // Reentrancy protection
        /// @notice Reentrancy guard flag (1 = NOT_ENTERED, 2 = ENTERED)
        uint8 reentrancyStatus;
        // Voting state
        /// @notice True if vote tally is finalized (post-voting)
        bool tallyFinalized;
        /// @notice Monotonic counter used to assign new proposal ids
        uint256 proposalIdCounter;
        /// @notice Global timestamp when all redemptions and transfers can begin (seconds)
        uint256 globalRedemptionStart;
        /// @notice Global timestamp when the redemption period ends (seconds)
        uint256 globalRedemptionEndTime;
        // Allocation Mechanism Vault Storage (merged from DistributionMechanism)
        /// @notice Per-address sequential nonces for EIP-712 signatures
        mapping(address => uint256) nonces;
        /// @notice Share balances per account in share base units
        mapping(address => uint256) balances;
        /// @notice Allowances mapping for share spenders in share base units
        mapping(address => mapping(address => uint256)) allowances;
        /// @notice Total number of shares in circulation in share base units
        uint256 totalSupply;
        /// @notice Total assets under management in underlying base units
        /// @dev Manually tracked to prevent PPS manipulation through airdrops
        uint256 totalAssets;
        // Strategy Management
        /// @notice Address permitted to perform keeper operations
        address keeper;
        /// @notice Management address authorized to update configuration
        address management;
        /// @notice Decimals used by asset and this shares token
        uint8 decimals;
        // Mappings
        /// @notice Mapping from proposal id to stored {Proposal}
        mapping(uint256 => Proposal) proposals;
        /// @notice Tracks active proposal id for a given recipient (if any)
        mapping(address => uint256) activeProposalByRecipient;
        /// @notice Voting power per user in shares in share base units
        mapping(address => uint256) votingPower;
        /// @notice Shares allocated to each proposal in share base units
        mapping(uint256 => uint256) proposalShares;
        // EIP712 storage
        /// @notice Cached EIP-712 domain separator for signatures
        bytes32 domainSeparator; // Cached domain separator
        /// @notice Chain id used in domain separator to provide fork protection
        uint256 initialChainId; // Chain ID at deployment for fork protection
    }

    // ---------- Storage Access for Hooks ----------

    /// @notice Emitted when a user completes registration
    /// @param user Address of the registered user
    /// @param votingPower Voting power granted (shares, 18 decimals)
    event UserRegistered(address indexed user, uint256 votingPower);
    /// @notice Emitted when a new proposal is created
    /// @param pid Newly assigned proposal id
    /// @param proposer Address that created the proposal
    /// @param recipient Intended recipient of minted shares upon queue
    /// @param description Human-readable proposal description
    event ProposalCreated(uint256 indexed pid, address indexed proposer, address indexed recipient, string description);
    /// @notice Emitted when a vote is cast
    /// @param voter Address casting the vote
    /// @param pid Proposal id being voted on
    /// @param weight Vote weight used (shares, 18 decimals)
    event VotesCast(address indexed voter, uint256 indexed pid, uint256 weight);
    /// @notice Emitted when vote tally is finalized
    event VoteTallyFinalized();
    /// @notice Emitted when a proposal is queued and shares minted
    /// @param pid Proposal id being queued
    /// @param eta Timestamp when timelock elapses and redemptions can begin (seconds)
    /// @param shareAmount Number of shares minted/allocated in share base units
    event ProposalQueued(uint256 indexed pid, uint256 eta, uint256 shareAmount);
    /// @notice Emitted when a proposal is canceled
    /// @param pid Proposal id that was canceled
    /// @param proposer Address of the canceling proposer
    event ProposalCanceled(uint256 indexed pid, address indexed proposer);
    /// @notice Emitted when ownership transfer is initiated
    /// @param currentOwner Current owner address
    /// @param pendingOwner Address nominated to become the new owner
    event OwnershipTransferInitiated(address indexed currentOwner, address indexed pendingOwner);
    /// @notice Emitted when ownership transfer is canceled
    /// @param currentOwner Current owner address
    /// @param canceledPendingOwner Previously pending owner whose transfer was canceled
    event OwnershipTransferCanceled(address indexed currentOwner, address indexed canceledPendingOwner);
    /// @notice Emitted when ownership is transferred
    /// @param previousOwner Address of the previous owner
    /// @param newOwner Address of the new owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted when keeper is updated
    /// @param previousKeeper Old keeper address
    /// @param newKeeper New keeper address
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    /// @notice Emitted when management is updated
    /// @param previousManagement Old management address
    /// @param newManagement New management address
    event ManagementUpdated(address indexed previousManagement, address indexed newManagement);
    /// @notice Emitted when contract is paused/unpaused
    /// @param paused True if paused, false if unpaused
    event PausedStatusChanged(bool paused);
    /// @notice Emitted when global redemption period is set
    /// @param redemptionStart Timestamp when global redemptions can begin (seconds)
    /// @param redemptionEnd Timestamp when global redemptions end (seconds)
    event GlobalRedemptionPeriodSet(uint256 redemptionStart, uint256 redemptionEnd);
    /// @notice Emitted when tokens are swept after grace period
    /// @param token Token address that was swept
    /// @param receiver Recipient of swept tokens
    /// @param amount Amount swept in token base units
    event Swept(address indexed token, address indexed receiver, uint256 amount);

    // Additional events from DistributionMechanism
    /// @param caller Address initiating the redemption
    /// @param receiver Address receiving the underlying assets
    /// @param owner Owner of the shares being redeemed
    /// @param assets Amount of underlying assets transferred (asset base units)
    /// @param shares Amount of shares burned in share base units
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    // ---------- Storage Access ----------

    /// @notice Get the storage struct from the predefined slot
    /// @return s Storage struct containing all mutable state
    function _getStorage() internal pure returns (AllocationStorage storage s) {
        bytes32 slot = ALLOCATION_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Constructor to prevent initialization of the library implementation
    constructor() {
        AllocationStorage storage s = _getStorage();
        s.initialized = true; // Prevent initialization on the library contract
        s.reentrancyStatus = 1; // Initialize reentrancy guard to NOT_ENTERED
    }

    /// @notice Returns the domain separator, updating it if chain ID changed (fork protection)
    function DOMAIN_SEPARATOR() public returns (bytes32) {
        AllocationStorage storage s = _getStorage();
        if (block.chainid == s.initialChainId) {
            return s.domainSeparator;
        } else {
            s.initialChainId = block.chainid;

            bytes32 domainSeparator = _computeDomainSeparator(s);
            s.domainSeparator = domainSeparator;
            return domainSeparator;
        }
    }

    /// @dev Computes the domain separator
    function _computeDomainSeparator(AllocationStorage storage s) private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TYPE_HASH,
                    keccak256(bytes(s.name)),
                    keccak256(bytes(EIP712_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }

    // ---------- Modifiers ----------

    modifier onlyOwner() {
        AllocationStorage storage s = _getStorage();
        if (msg.sender != s.owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_getStorage().paused) revert PausedError();
        _;
    }

    modifier nonReentrant() {
        AllocationStorage storage s = _getStorage();
        if (s.reentrancyStatus == 2) revert ReentrantCall();
        s.reentrancyStatus = 2;
        _;
        s.reentrancyStatus = 1;
    }

    // ---------- Initialization ----------

    /// @notice Initialize the allocation mechanism with configuration
    /// @dev Can only be called once by the strategy/clone proxy; subsequent calls revert
    /// @param _owner Address that will become the owner and management
    /// @param _asset Underlying ERC20 asset used for deposits/redemptions
    /// @param _name ERC20 name for the shares token
    /// @param _symbol ERC20 symbol for the shares token
    /// @param _votingDelay Delay before voting opens (seconds)
    /// @param _votingPeriod Duration of the voting phase (seconds)
    /// @param _quorumShares Quorum threshold (shares, 18 decimals)
    /// @param _timelockDelay Delay after queueing before redemptions (seconds)
    /// @param _gracePeriod Duration of redemption window (seconds)
    /// @custom:security Initialization guarded by `AlreadyInitialized` check
    function initialize(
        address _owner,
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _quorumShares,
        uint256 _timelockDelay,
        uint256 _gracePeriod
    ) external {
        _initializeAllocation(
            _owner,
            _asset,
            _name,
            _symbol,
            _votingDelay,
            _votingPeriod,
            _quorumShares,
            _timelockDelay,
            _gracePeriod
        );
    }

    /// @notice Internal allocation mechanism initialization
    /// @dev Shared initializer used by {initialize}
    /// @param _owner Address that will become the owner and management
    /// @param _asset Underlying ERC20 asset used for deposits/redemptions
    /// @param _name ERC20 name for the shares token
    /// @param _symbol ERC20 symbol for the shares token
    /// @param _votingDelay Delay before voting opens (seconds)
    /// @param _votingPeriod Duration of the voting phase (seconds)
    /// @param _quorumShares Quorum threshold (shares, 18 decimals)
    /// @param _timelockDelay Delay after queueing before redemptions (seconds)
    /// @param _gracePeriod Duration of redemption window (seconds)
    function _initializeAllocation(
        address _owner,
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _quorumShares,
        uint256 _timelockDelay,
        uint256 _gracePeriod
    ) internal {
        AllocationStorage storage s = _getStorage();

        // Validate inputs
        if (_owner == address(0)) revert Unauthorized();
        if (address(_asset) == address(0)) revert ZeroAssetAddress();
        if (_votingDelay == 0) revert ZeroVotingDelay();
        if (_votingPeriod == 0) revert ZeroVotingPeriod();
        if (_quorumShares == 0) revert ZeroQuorumShares();
        if (_timelockDelay == 0) revert ZeroTimelockDelay();
        if (_gracePeriod == 0) revert ZeroGracePeriod();
        if (bytes(_name).length == 0) revert EmptyName();
        if (bytes(_symbol).length == 0) revert EmptySymbol();
        if (s.initialized == true) revert AlreadyInitialized();

        // Set configuration
        s.owner = _owner;
        s.asset = _asset;
        s.name = _name;
        s.symbol = _symbol;
        s.votingDelay = _votingDelay;
        s.votingPeriod = _votingPeriod;
        s.quorumShares = _quorumShares;
        s.timelockDelay = _timelockDelay;
        s.gracePeriod = _gracePeriod;
        s.startBlock = block.number; // Keep for legacy getter compatibility
        s.initialized = true;
        s.reentrancyStatus = 1; // Initialize reentrancy guard to NOT_ENTERED

        // Set timestamp-based timeline starting from deployment time
        s.startTime = block.timestamp;
        s.votingStartTime = s.startTime + _votingDelay;
        s.votingEndTime = s.votingStartTime + _votingPeriod;

        // Set management roles to owner
        s.management = _owner;
        s.keeper = _owner;
        s.decimals = ERC20(address(_asset)).decimals();

        // Initialize EIP712 domain separator
        s.initialChainId = block.chainid;
        s.domainSeparator = _computeDomainSeparator(s);

        emit OwnershipTransferred(address(0), _owner);
    }

    // ---------- Registration ----------

    /// @notice Register to gain voting power by depositing underlying tokens
    /// @param deposit Amount of underlying to deposit (asset base units, may be zero)
    /// @custom:security Reentrancy protected; callable only when not paused
    function signup(uint256 deposit) external nonReentrant whenNotPaused {
        _executeSignup(msg.sender, deposit, msg.sender);
    }

    /// @notice Register on behalf of another user using EIP-712 signature
    /// @param user Address of the user signing up
    /// @param deposit Amount of underlying to deposit (asset base units)
    /// @param deadline Expiration timestamp for the signature (seconds)
    /// @param v Signature parameter
    /// @param r Signature parameter
    /// @param s Signature parameter
    /// @dev The deposit will be taken from msg.sender, not the user. Increments `nonces[user]`.
    /// @custom:security Reentrancy protected; callable only when not paused
    function signupOnBehalfWithSignature(
        address user,
        uint256 deposit,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        _validateSignature(
            user,
            keccak256(abi.encode(SIGNUP_TYPEHASH, user, msg.sender, deposit, _getStorage().nonces[user]++, deadline)),
            deadline,
            v,
            r,
            s
        );
        _executeSignup(user, deposit, msg.sender);
    }

    /// @notice Register with voting power using EIP-712 signature
    /// @param user Address of the user signing up
    /// @param deposit Amount of underlying to deposit (asset base units)
    /// @param deadline Expiration timestamp for the signature (seconds)
    /// @param v Signature parameter
    /// @param r Signature parameter
    /// @param s Signature parameter
    /// @dev The deposit will be taken from the user themselves. Increments `nonces[user]`.
    /// @custom:security Reentrancy protected; callable only when not paused
    function signupWithSignature(
        address user,
        uint256 deposit,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        _validateSignature(
            user,
            keccak256(abi.encode(SIGNUP_TYPEHASH, user, user, deposit, _getStorage().nonces[user]++, deadline)),
            deadline,
            v,
            r,
            s
        );
        _executeSignup(user, deposit, user);
    }

    /// @dev Validates signature parameters with ERC1271 support for contract signers
    function _validateSignature(
        address expectedSigner,
        bytes32 structHash,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        // Check deadline
        if (block.timestamp > deadline) revert ExpiredSignature(deadline, block.timestamp);

        // Compute EIP712 digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        // Try ECDSA recovery first
        (address recovered, , ) = ECDSA.tryRecover(digest, v, r, s);

        // If ECDSA recovery matches expected signer, we're done
        if (recovered == expectedSigner) {
            return;
        }

        // If expectedSigner is a contract, try ERC1271 validation
        if (expectedSigner.code.length > 0) {
            // Pack signature components for ERC1271
            bytes memory signature = abi.encodePacked(r, s, v);

            try IERC1271(expectedSigner).isValidSignature(digest, signature) returns (bytes4 magicValue) {
                if (magicValue == 0x1626ba7e) {
                    return; // Valid ERC1271 signature
                }
            } catch {
                // Fall through to revert
            }
        }

        // Neither ECDSA nor ERC1271 validation succeeded
        revert InvalidSigner(recovered, expectedSigner);
    }

    /// @dev Internal signup execution logic
    function _executeSignup(address user, uint256 deposit, address payer) private {
        AllocationStorage storage s = _getStorage();

        // Prevent zero address registration
        if (user == address(0)) revert InvalidUser(user);

        // Call hook for validation via interface (Yearn V3 pattern)
        if (!IBaseAllocationStrategy(address(this)).beforeSignupHook(user)) {
            revert RegistrationBlocked(user);
        }

        if (block.timestamp > s.votingEndTime) revert VotingEnded(block.timestamp, s.votingEndTime);

        if (deposit > MAX_SAFE_VALUE) revert DepositTooLarge(deposit, MAX_SAFE_VALUE);

        if (deposit > 0) s.asset.safeTransferFrom(payer, address(this), deposit);

        uint256 newPower = IBaseAllocationStrategy(address(this)).getVotingPowerHook(user, deposit);
        if (newPower > MAX_SAFE_VALUE) revert VotingPowerTooLarge(newPower, MAX_SAFE_VALUE);

        // Prevent registration with zero voting power when deposit is non-zero
        if (newPower == 0 && deposit > 0) revert InsufficientDeposit(deposit);

        // Add to existing voting power to support multiple signups
        uint256 totalPower = s.votingPower[user] + newPower;
        if (totalPower > MAX_SAFE_VALUE) revert VotingPowerTooLarge(totalPower, MAX_SAFE_VALUE);

        s.votingPower[user] = totalPower;
        emit UserRegistered(user, newPower);
    }

    // ---------- Proposal Creation ----------

    /// @notice Create a new proposal targeting `recipient`
    /// @param recipient Address to receive allocated vault shares upon queue
    /// @param description Human-readable description or rationale for the proposal
    /// @return pid Unique identifier for the new proposal
    /// @custom:security Reentrancy protected; callable only when not paused; subject to strategy hook
    function propose(
        address recipient,
        string calldata description
    ) external whenNotPaused nonReentrant returns (uint256 pid) {
        address proposer = msg.sender;

        // Call hook for validation - Potential DoS risk - malicious keeper/management contracts could revert these calls
        if (!IBaseAllocationStrategy(address(this)).beforeProposeHook(proposer)) revert ProposeNotAllowed(proposer);

        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);

        AllocationStorage storage s = _getStorage();

        // Proposing only allowed before voting period ends
        if (block.timestamp > s.votingEndTime) {
            revert VotingEnded(block.timestamp, s.votingEndTime);
        }

        if (s.activeProposalByRecipient[recipient] != 0) {
            revert RecipientUsed(recipient);
        }
        if (bytes(description).length == 0) revert EmptyDescription();
        if (bytes(description).length > 1000) revert DescriptionTooLong(bytes(description).length, 1000);

        pid = ++s.proposalIdCounter;

        s.proposals[pid] = Proposal(0, proposer, recipient, description, false);
        s.activeProposalByRecipient[recipient] = pid;

        emit ProposalCreated(pid, proposer, recipient, description);
    }

    // ---------- Voting ----------

    /// @notice Cast a vote on a proposal
    /// @param pid Proposal ID
    /// @param choice VoteType (Against, For, Abstain)
    /// @param weight Amount of voting power to apply (shares, 18 decimals)
    /// @param expectedRecipient Expected recipient address to prevent reorganization attacks
    /// @custom:security Reentrancy protected; callable only when not paused; only during voting window
    function castVote(
        uint256 pid,
        VoteType choice,
        uint256 weight,
        address expectedRecipient
    ) external nonReentrant whenNotPaused {
        _executeCastVote(msg.sender, pid, choice, weight, expectedRecipient);
    }

    /// @notice Cast vote using EIP-712 signature
    /// @param voter Address of the voter
    /// @param pid Proposal ID
    /// @param choice Vote choice (Against, For, Abstain)
    /// @param weight Voting weight to use (shares, 18 decimals)
    /// @param expectedRecipient Expected recipient address for the proposal
    /// @param deadline Expiration timestamp for the signature (seconds)
    /// @param v Signature parameter
    /// @param r Signature parameter
    /// @param s Signature parameter
    /// @custom:security Reentrancy protected; callable only when not paused; only during voting window
    function castVoteWithSignature(
        address voter,
        uint256 pid,
        VoteType choice,
        uint256 weight,
        address expectedRecipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        uint256 nonce = _getStorage().nonces[voter]++;
        _validateSignature(
            voter,
            keccak256(
                abi.encode(CAST_VOTE_TYPEHASH, voter, pid, uint8(choice), weight, expectedRecipient, nonce, deadline)
            ),
            deadline,
            v,
            r,
            s
        );
        _executeCastVote(voter, pid, choice, weight, expectedRecipient);
    }

    /// @dev Internal vote execution logic
    function _executeCastVote(
        address voter,
        uint256 pid,
        VoteType choice,
        uint256 weight,
        address expectedRecipient
    ) private {
        AllocationStorage storage s = _getStorage();

        // Validate proposal
        if (!IBaseAllocationStrategy(address(this)).validateProposalHook(pid)) revert InvalidProposal(pid);

        // Check if proposal is canceled
        Proposal storage p = s.proposals[pid];
        if (p.canceled) revert ProposalCanceledError(pid);

        // Verify recipient matches voter's expectation to prevent reorganization attacks
        if (p.recipient != expectedRecipient) revert RecipientMismatch(pid, expectedRecipient, p.recipient);

        // Cache storage timestamps to avoid multiple reads in error message
        uint256 votingStart = s.votingStartTime;
        uint256 votingEnd = s.votingEndTime;

        // Check voting window
        if (block.timestamp < votingStart || block.timestamp > votingEnd) {
            revert VotingClosed(block.timestamp, votingStart, votingEnd);
        }

        uint256 oldPower = s.votingPower[voter];
        if (weight == 0) revert InvalidWeight(weight, oldPower);
        if (weight > MAX_SAFE_VALUE) revert WeightTooLarge(weight, MAX_SAFE_VALUE);

        // Note: weight > oldPower check is redundant with processVoteHook's quadratic cost validation
        // The hook will revert with InsufficientVotingPowerForQuadraticCost if weight^2 > oldPower
        uint256 newPower = IBaseAllocationStrategy(address(this)).processVoteHook(
            pid,
            voter,
            uint8(choice),
            weight,
            oldPower
        );
        if (newPower > oldPower) revert PowerIncreased(oldPower, newPower);

        s.votingPower[voter] = newPower;
        emit VotesCast(voter, pid, weight);
    }

    // ---------- Vote Tally Finalization ----------

    /// @notice Finalize vote tally once voting period has ended
    /// @custom:security Only owner; reentrancy protected
    function finalizeVoteTally() external onlyOwner nonReentrant {
        AllocationStorage storage s = _getStorage();

        if (block.timestamp <= s.votingEndTime) revert VotingNotEnded(block.timestamp, s.votingEndTime);

        if (s.tallyFinalized) revert TallyAlreadyFinalized();

        if (!IBaseAllocationStrategy(address(this)).beforeFinalizeVoteTallyHook()) revert FinalizationBlocked();

        // Set total assets using strategy-specific calculation
        // This allows for custom logic like matching pools in quadratic funding
        s.totalAssets = IBaseAllocationStrategy(address(this)).calculateTotalAssetsHook();

        // Set global redemption start time for all proposals
        s.globalRedemptionStart = block.timestamp + s.timelockDelay;
        s.globalRedemptionEndTime = s.globalRedemptionStart + s.gracePeriod;
        s.tallyFinalizedTime = block.timestamp;

        s.tallyFinalized = true;
        emit VoteTallyFinalized();
        emit GlobalRedemptionPeriodSet(s.globalRedemptionStart, s.globalRedemptionEndTime);
    }

    // ---------- Queue Proposal ----------

    /// @notice Queue proposal and trigger share distribution
    /// @param pid Proposal ID to queue
    /// @custom:security Reentrancy protected; callable only after tally finalized and before redemption
    function queueProposal(uint256 pid) external nonReentrant {
        AllocationStorage storage s = _getStorage();

        if (!s.tallyFinalized) revert TallyNotFinalized();
        // Check if redemption period has started - no new queuing after redemption begins
        if (s.globalRedemptionStart != 0 && block.timestamp >= s.globalRedemptionStart) {
            revert QueueingClosedAfterRedemption();
        }
        if (!IBaseAllocationStrategy(address(this)).validateProposalHook(pid)) revert InvalidProposal(pid);

        Proposal storage p = s.proposals[pid];
        if (p.canceled) revert ProposalCanceledError(pid);

        if (!IBaseAllocationStrategy(address(this)).hasQuorumHook(pid)) revert NoQuorum(pid, 0, 0, s.quorumShares);

        if (s.proposalShares[pid] != 0) revert AlreadyQueued(pid);

        uint256 sharesToMint = IBaseAllocationStrategy(address(this)).convertVotesToShares(pid);
        if (sharesToMint == 0) revert NoAllocation(pid, sharesToMint);

        s.proposalShares[pid] = sharesToMint;

        address recipient = IBaseAllocationStrategy(address(this)).getRecipientAddressHook(pid);

        // Try custom distribution hook first
        (bool customDistributionHandled, uint256 assetsTransferred) = IBaseAllocationStrategy(address(this))
            .requestCustomDistributionHook(recipient, sharesToMint);

        // If custom distribution was handled, update totalAssets to reflect assets transferred out
        if (customDistributionHandled) {
            if (assetsTransferred > s.totalAssets) revert InsufficientAssets(assetsTransferred, s.totalAssets);
            s.totalAssets -= assetsTransferred;
        } else {
            // If custom distribution wasn't handled, mint shares by default
            _mint(s, recipient, sharesToMint);
        }

        emit ProposalQueued(pid, s.globalRedemptionStart, sharesToMint);
    }

    // ---------- State Machine ----------

    /// @notice Get the current state of a proposal
    /// @param pid Proposal ID
    /// @return Current state of the proposal
    function state(uint256 pid) external view returns (ProposalState) {
        if (!IBaseAllocationStrategy(address(this)).validateProposalHook(pid)) revert InvalidProposal(pid);
        return _state(pid);
    }

    /// @dev Internal state computation for a proposal with direct time range checks
    function _state(uint256 pid) internal view returns (ProposalState) {
        AllocationStorage storage s = _getStorage();
        Proposal storage p = s.proposals[pid];

        if (p.canceled) return ProposalState.Canceled;

        // Check if proposal failed quorum (defeated proposals never change state)
        if (s.tallyFinalized && !IBaseAllocationStrategy(address(this)).hasQuorumHook(pid)) {
            return ProposalState.Defeated;
        }

        // Before voting starts (Pending or Delay phases)
        if (block.timestamp < s.votingStartTime) {
            return ProposalState.Pending;
        }
        // During voting period or before tally finalized
        else if (block.timestamp <= s.votingEndTime) {
            return ProposalState.Active;
        }
        // After voting ends but before tally finalized
        else if (!s.tallyFinalized) {
            return ProposalState.Tallying;
        }

        uint256 shares = s.proposalShares[pid];

        // After tally finalized - check if queued or succeeded
        if (s.globalRedemptionStart != 0 && block.timestamp < s.globalRedemptionStart) {
            return shares == 0 ? ProposalState.Succeeded : ProposalState.Queued;
        }
        // During redemption period
        else if (s.globalRedemptionEndTime != 0 && block.timestamp <= s.globalRedemptionEndTime) {
            return shares == 0 ? ProposalState.Succeeded : ProposalState.Redeemable;
        }
        // After redemption period (grace period expired)
        else {
            return ProposalState.Expired;
        }
    }

    // ---------- Proposal Management ----------

    /// @notice Cancel a proposal
    /// @dev Can only be called before vote tally is finalized. After finalization, all proposals are immutable.
    /// @dev This prevents race conditions and ensures coordinators can verify all proposals before committing.
    /// @param pid Proposal ID to cancel
    function cancelProposal(uint256 pid) external nonReentrant {
        AllocationStorage storage s = _getStorage();

        // Prevent cancellation after finalization - proposals become immutable
        if (s.tallyFinalized) revert TallyAlreadyFinalized();

        if (!IBaseAllocationStrategy(address(this)).validateProposalHook(pid)) revert InvalidProposal(pid);

        Proposal storage p = s.proposals[pid];
        if (msg.sender != p.proposer) revert NotProposer(msg.sender, p.proposer);
        if (p.canceled) revert AlreadyCanceled(pid);

        p.canceled = true;
        uint256 trackedPid = s.activeProposalByRecipient[p.recipient];
        if (trackedPid == pid) {
            delete s.activeProposalByRecipient[p.recipient];
        }
        emit ProposalCanceled(pid, p.proposer);
    }

    // ---------- View Functions ----------

    /// @notice Get total number of proposals created
    function getProposalCount() external view returns (uint256) {
        return _getStorage().proposalIdCounter;
    }

    // Public getters for storage access
    /// @notice Returns the mechanism name
    function name() external view returns (string memory) {
        return _getStorage().name;
    }

    /// @notice Returns the mechanism symbol
    function symbol() external view returns (string memory) {
        return _getStorage().symbol;
    }

    /// @notice Returns the underlying asset
    function asset() external view returns (IERC20) {
        return _getStorage().asset;
    }

    /// @notice Returns the current owner
    function owner() external view returns (address) {
        return _getStorage().owner;
    }

    /// @notice Returns the pending owner awaiting acceptance
    function pendingOwner() external view returns (address) {
        return _getStorage().pendingOwner;
    }

    /// @notice Returns whether vote tally has been finalized
    function tallyFinalized() external view returns (bool) {
        return _getStorage().tallyFinalized;
    }

    /// @notice Returns proposal data for a given proposal ID
    function proposals(uint256 pid) external view returns (Proposal memory) {
        return _getStorage().proposals[pid];
    }

    /// @notice Returns the voting power for a user
    function votingPower(address user) external view returns (uint256) {
        return _getStorage().votingPower[user];
    }

    /// @notice Returns allocated shares for a proposal
    function proposalShares(uint256 pid) external view returns (uint256) {
        return _getStorage().proposalShares[pid];
    }

    // Configuration getters
    /// @notice Returns the block number when mechanism was initialized
    function startBlock() external view returns (uint256) {
        return _getStorage().startBlock;
    }

    /// @notice Returns the voting delay period in blocks
    function votingDelay() external view returns (uint256) {
        return _getStorage().votingDelay;
    }

    /// @notice Returns the voting period duration in blocks
    function votingPeriod() external view returns (uint256) {
        return _getStorage().votingPeriod;
    }

    /// @notice Returns the minimum shares required for quorum
    function quorumShares() external view returns (uint256) {
        return _getStorage().quorumShares;
    }

    /// @notice Returns the timelock delay in seconds
    function timelockDelay() external view returns (uint256) {
        return _getStorage().timelockDelay;
    }

    /// @notice Returns the grace period duration in seconds
    function gracePeriod() external view returns (uint256) {
        return _getStorage().gracePeriod;
    }

    /// @notice Returns the global redemption start timestamp
    function globalRedemptionStart() external view returns (uint256) {
        return _getStorage().globalRedemptionStart;
    }

    /// @notice Returns the voting start timestamp
    function votingStartTime() external view returns (uint256) {
        return _getStorage().votingStartTime;
    }

    /// @notice Returns the voting end timestamp
    function votingEndTime() external view returns (uint256) {
        return _getStorage().votingEndTime;
    }

    /// @notice Returns the mechanism start timestamp
    function startTime() external view returns (uint256) {
        return _getStorage().startTime;
    }

    /// @notice Returns the current nonce for an address
    /// @param account Address to check nonce for
    /// @return Current nonce for permit operations
    function nonces(address account) external view returns (uint256) {
        return _getStorage().nonces[account];
    }

    // ---------- Emergency Functions ----------

    /// @notice Initiate ownership transfer to a new address (step 1 of 2)
    /// @param newOwner Address to transfer ownership to
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        AllocationStorage storage s = _getStorage();
        s.pendingOwner = newOwner;
        emit OwnershipTransferInitiated(s.owner, newOwner);
    }

    /// @notice Accept ownership transfer (step 2 of 2)
    /// @dev Must be called by the pending owner to complete the transfer
    function acceptOwnership() external {
        AllocationStorage storage s = _getStorage();
        address pending = s.pendingOwner;
        if (msg.sender != pending) revert Unauthorized();

        address oldOwner = s.owner;
        s.owner = pending;
        s.pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, pending);
    }

    /// @notice Cancel pending ownership transfer
    /// @dev Can only be called by current owner
    function cancelOwnershipTransfer() external onlyOwner {
        AllocationStorage storage s = _getStorage();
        if (s.pendingOwner == address(0)) revert Unauthorized();

        address canceledPendingOwner = s.pendingOwner;
        s.pendingOwner = address(0);
        emit OwnershipTransferCanceled(s.owner, canceledPendingOwner);
    }

    /// @notice Update keeper address
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert Unauthorized();
        AllocationStorage storage s = _getStorage();
        address oldKeeper = s.keeper;
        s.keeper = newKeeper;
        emit KeeperUpdated(oldKeeper, newKeeper);
    }

    /// @notice Update management address
    function setManagement(address newManagement) external onlyOwner {
        if (newManagement == address(0)) revert Unauthorized();
        AllocationStorage storage s = _getStorage();
        address oldManagement = s.management;
        s.management = newManagement;
        emit ManagementUpdated(oldManagement, newManagement);
    }

    /// @notice Emergency pause all operations
    function pause() external onlyOwner {
        AllocationStorage storage s = _getStorage();
        s.paused = true;
        emit PausedStatusChanged(true);
    }

    /// @notice Resume operations after pause
    function unpause() external onlyOwner {
        AllocationStorage storage s = _getStorage();
        s.paused = false;
        emit PausedStatusChanged(false);
    }

    /// @notice Check if contract is paused
    function paused() external view returns (bool) {
        return _getStorage().paused;
    }

    /// @notice Sweep remaining tokens after grace period expires
    /// @dev Can only be called by owner after global grace period ends
    /// @param token Token to sweep (use address(0) for ETH)
    /// @param receiver Address to receive swept tokens
    function sweep(address token, address receiver) external onlyOwner nonReentrant {
        AllocationStorage storage s = _getStorage();

        // Ensure grace period has expired for everyone
        require(s.globalRedemptionStart != 0, "Redemption period not started");
        require(block.timestamp > s.globalRedemptionEndTime, "Grace period not expired");
        require(receiver != address(0), "Invalid receiver");

        if (token == address(0)) {
            // Sweep ETH
            uint256 balance = address(this).balance;
            require(balance > 0, "No ETH to sweep");
            (bool success, ) = receiver.call{ value: balance }("");
            require(success, "ETH transfer failed");
            emit Swept(token, receiver, balance);
        } else {
            // Sweep any ERC20 token
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            require(balance > 0, "No tokens to sweep");
            tokenContract.safeTransfer(receiver, balance);
            emit Swept(token, receiver, balance);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ALLOCATION VAULT FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeems exactly `shares` from `shareOwner` and
     * sends `assets` of underlying tokens to `receiver`.
     * @param shares Amount of shares to burn
     * @param receiver Address to receive withdrawn assets
     * @param shareOwner Address whose shares are burned
     * @return assetsWithdrawn Actual amount of underlying withdrawn in asset base units
     * @dev Reverts with "ZERO_ASSETS" if shares amount rounds to 0 assets
     * @dev Reverts with "redeem more than max" if shares > maxRedeem(shareOwner)
     */
    function redeem(uint256 shares, address receiver, address shareOwner) external nonReentrant returns (uint256) {
        // Get the storage slot for all following calls.
        AllocationStorage storage S = _getStorage();
        require(shares <= _maxRedeem(S, shareOwner), "Allocation: redeem more than max");
        // slither-disable-next-line uninitialized-local
        uint256 assets;
        // Check for rounding error or 0 value.
        require((assets = _convertToAssets(S, shares, Math.Rounding.Floor)) != 0, "ZERO_ASSETS");

        // We need to return the actual amount withdrawn.
        return _withdraw(S, receiver, shareOwner, assets, shares);
    }

    /**
     * @notice Get the total amount of assets this strategy holds
     * as of the last report.
     *
     * We manually track `totalAssets` to avoid any PPS manipulation.
     *
     * @return totalAssets_ Total assets the strategy holds.
     */
    function totalAssets() external view returns (uint256) {
        return _totalAssets(_getStorage());
    }

    /**
     * @notice Get the current supply of the strategies shares.
     *
     * Locked shares issued to the strategy from profits are not
     * counted towards the full supply until they are unlocked.
     *
     * As more shares slowly unlock the totalSupply will decrease
     * causing the PPS of the strategy to increase.
     *
     * @return totalSupply_ Total amount of shares outstanding.
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply(_getStorage());
    }

    /**
     * @notice The amount of shares that the strategy would
     *  exchange for the amount of assets provided, in an
     * ideal scenario where all the conditions are met.
     *
     * @param assets Amount of underlying assets
     * @return shares_ Expected shares that assets represent
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(_getStorage(), assets, Math.Rounding.Floor);
    }

    /**
     * @notice The amount of assets that the strategy would
     * exchange for the amount of shares provided, in an
     * ideal scenario where all the conditions are met.
     *
     * @param shares Amount of strategy shares
     * @return assets_ Expected assets the shares represent in asset base units
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(_getStorage(), shares, Math.Rounding.Floor);
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate
     * the effects of their redemption at the current block,
     * given current on-chain conditions.
     * @dev This will round down.
     *
     * @param shares Amount of shares to redeem
     * @return assets_ Amount of assets that would be returned in asset base units
     */
    function previewRedeem(uint256 shares) external view returns (uint256) {
        AllocationStorage storage s = _getStorage();

        // Return 0 if outside redemption period [t_r_start, t_r_end]
        if (s.globalRedemptionStart == 0 || block.timestamp < s.globalRedemptionStart) {
            return 0; // Before redemption period starts
        }

        if (s.globalRedemptionEndTime != 0 && block.timestamp > s.globalRedemptionEndTime) {
            return 0; // After redemption period ends
        }

        return _convertToAssets(s, shares, Math.Rounding.Floor);
    }

    /**
     * @notice Total number of strategy shares that can be
     * redeemed from the strategy by `shareOwner`, where `shareOwner`
     * corresponds to the msg.sender of a {redeem} call.
     *
     * @param shareOwner Address that owns the shares
     * @return _maxRedeem Maximum shares that can be redeemed
     */
    function maxRedeem(address shareOwner) external view returns (uint256) {
        return _maxRedeem(_getStorage(), shareOwner);
    }

    /// @notice Returns the management address
    function management() external view returns (address) {
        return _getStorage().management;
    }

    /// @notice Returns the keeper address
    function keeper() external view returns (address) {
        return _getStorage().keeper;
    }

    /// @notice Returns the decimals used for the token (always 18)
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the balance of an account
    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf(_getStorage(), account);
    }

    /// @notice Returns the allowance of a spender for a token owner
    function allowance(address tokenOwner, address spender) external view returns (uint256) {
        return _allowance(_getStorage(), tokenOwner, spender);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL VAULT VIEW METHODS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal implementation of {totalAssets}.
    function _totalAssets(AllocationStorage storage S) internal view returns (uint256) {
        return S.totalAssets;
    }

    /// @dev Internal implementation of {totalSupply}.
    function _totalSupply(AllocationStorage storage S) internal view returns (uint256) {
        return S.totalSupply;
    }

    /// @dev Internal implementation of {convertToShares}.
    function _convertToShares(
        AllocationStorage storage S,
        uint256 assets,
        Math.Rounding _rounding
    ) internal view returns (uint256) {
        // Saves an extra SLOAD if values are non-zero.
        uint256 totalSupply_ = _totalSupply(S);
        // If supply is 0, convert assets from asset decimals to 18 decimals (share decimals)
        if (totalSupply_ == 0) {
            uint8 assetDecimals = S.decimals;
            if (assetDecimals == 18) {
                return assets;
            } else if (assetDecimals < 18) {
                // Scale up: multiply by 10^(18 - assetDecimals)
                uint256 scaleFactor = 10 ** (18 - assetDecimals);
                return assets * scaleFactor;
            } else {
                // Scale down: divide by 10^(assetDecimals - 18)
                uint256 scaleFactor = 10 ** (assetDecimals - 18);
                return assets / scaleFactor;
            }
        }

        uint256 totalAssets_ = _totalAssets(S);
        // If assets are 0 but supply is not PPS = 0.
        if (totalAssets_ == 0) return 0;

        return assets.mulDiv(totalSupply_, totalAssets_, _rounding);
    }

    /// @dev Internal implementation of {convertToAssets}.
    function _convertToAssets(
        AllocationStorage storage S,
        uint256 shares,
        Math.Rounding _rounding
    ) internal view returns (uint256) {
        // Saves an extra SLOAD if totalSupply() is non-zero.
        uint256 supply = _totalSupply(S);

        if (supply == 0) {
            // Convert shares from 18 decimals to asset decimals
            uint8 assetDecimals = S.decimals;
            if (assetDecimals == 18) {
                return shares;
            } else if (assetDecimals < 18) {
                // Scale down: divide by 10^(18 - assetDecimals)
                uint256 scaleFactor = 10 ** (18 - assetDecimals);
                return shares / scaleFactor;
            } else {
                // Scale up: multiply by 10^(assetDecimals - 18)
                uint256 scaleFactor = 10 ** (assetDecimals - 18);
                return shares * scaleFactor;
            }
        }

        return shares.mulDiv(_totalAssets(S), supply, _rounding);
    }

    /// @dev Internal implementation of {maxRedeem}.
    function _maxRedeem(AllocationStorage storage S, address shareOwner) internal view returns (uint256 maxRedeem_) {
        // Get the max the owner could withdraw currently.
        maxRedeem_ = IBaseAllocationStrategy(address(this)).availableWithdrawLimit(shareOwner);

        // Conversion would overflow and saves a min check if there is no withdrawal limit.
        if (maxRedeem_ == type(uint256).max) {
            maxRedeem_ = _balanceOf(S, shareOwner);
        } else {
            maxRedeem_ = Math.min(
                // Can't redeem more than the balance.
                _convertToShares(S, maxRedeem_, Math.Rounding.Floor),
                _balanceOf(S, shareOwner)
            );
        }
    }

    /// @dev Internal implementation of {balanceOf}.
    function _balanceOf(AllocationStorage storage S, address account) internal view returns (uint256) {
        return S.balances[account];
    }

    /// @dev Internal implementation of {allowance}.
    function _allowance(
        AllocationStorage storage S,
        address tokenOwner,
        address spender
    ) internal view returns (uint256) {
        return S.allowances[tokenOwner][spender];
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL VAULT WRITE METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev To be called during {redeem} and {withdraw}.
     *
     * This will handle all logic, transfers and accounting
     * in order to service the withdraw request.
     */
    function _withdraw(
        AllocationStorage storage S,
        address receiver,
        address shareOwner,
        uint256 assets,
        uint256 shares
    ) internal returns (uint256) {
        require(receiver != address(0), "ZERO ADDRESS");

        // Spend allowance if applicable.
        if (msg.sender != shareOwner) {
            _spendAllowance(S, shareOwner, msg.sender, shares);
        }

        // Cache `asset` since it is used multiple times..
        ERC20 _asset = ERC20(address(S.asset));

        // Ensure sufficient balance for withdrawal
        uint256 idle = _asset.balanceOf(address(this));
        require(idle >= assets, "Insufficient balance for withdrawal");

        // Update assets based on how much we took.
        S.totalAssets -= assets;

        _burn(S, shareOwner, shares);

        // Transfer the amount of underlying to the receiver.
        _asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, shareOwner, assets, shares);

        // Return the actual amount of assets withdrawn.
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer '_amount` of shares from `msg.sender` to `to`.
     * @dev
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - the caller must have a balance of at least `_amount`.
     *
     * @param to Address receiving the shares
     * @param amount Amount of shares to transfer
     * @return success True if operation succeeded
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(_getStorage(), msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     * @dev
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     *
     * @param spender the address to allow the shares to be moved by.
     * @param amount the amount of shares to allow `spender` to move.
     * @return success True if the operation succeeded.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(_getStorage(), msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * @dev
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     *
     * Emits a {Transfer} event.
     *
     * @param from the address to be moving shares from.
     * @param to the address to be moving shares to.
     * @param amount the quantity of shares to move.
     * @return success True if the operation succeeded.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        AllocationStorage storage S = _getStorage();
        _spendAllowance(S, from, msg.sender, amount);
        _transfer(S, from, to, amount);
        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `to` cannot be the strategies address
     * - `from` must have a balance of at least `amount`.
     *
     */
    function _transfer(AllocationStorage storage S, address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(to != address(this), "ERC20 transfer to strategy");

        // Only allow transfers during redemption period [globalRedemptionStart, globalRedemptionEndTime]
        // Before finalization: globalRedemptionEndTime is 0, so block.timestamp > 0 blocks transfers
        // After finalization: both timestamps are set, creating the valid redemption window
        if (block.timestamp < S.globalRedemptionStart || block.timestamp > S.globalRedemptionEndTime) {
            revert("Transfers only allowed during redemption period");
        }

        S.balances[from] -= amount;
        unchecked {
            S.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     *
     */
    function _mint(AllocationStorage storage S, address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        S.totalSupply += amount;
        unchecked {
            S.balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(AllocationStorage storage S, address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        S.balances[account] -= amount;
        unchecked {
            S.totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(AllocationStorage storage S, address tokenOwner, address spender, uint256 amount) internal {
        require(tokenOwner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        S.allowances[tokenOwner][spender] = amount;
        emit Approval(tokenOwner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        AllocationStorage storage S,
        address tokenOwner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = _allowance(S, tokenOwner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(S, tokenOwner, spender, currentAllowance - amount);
            }
        }
    }
}
