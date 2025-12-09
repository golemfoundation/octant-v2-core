# Product Requirements Document: Allocation Mechanism System

This implementation serves as a comprehensive reference for applying the Yearn V3 tokenized strategy pattern to other allocation mechanisms.

## Product Vision & Motivation

**Vision:** Create a modular, secure, and transparent allocation mechanism that enables communities to democratically distribute resources through customizable voting strategies while maintaining strong governance safeguards using the Yearn V3 tokenized strategy pattern.

**Core Motivation:**
- **Democratic Resource Allocation**: Enable communities to fairly distribute funds/resources through transparent voting processes
- **Modular Architecture**: Provide a flexible framework that supports multiple voting strategies through a hook-based system implemented via Yearn V3 pattern
- **Code Reuse & Efficiency**: Leverage shared implementation contracts to reduce deployment costs and improve maintainability
- **Security & Governance**: Implement timelock mechanisms and validation hooks to prevent attacks and ensure proper governance
- **User Experience**: Simplify the complex process of on-chain voting while maintaining transparency and auditability

## Technical Architecture Overview

The allocation mechanism system follows the **Yearn V3 Tokenized Strategy Pattern** with four main components:

1. **TokenizedAllocationMechanism.sol** - Shared implementation containing all standard logic (voting, proposals, vault share functionality, storage management)
2. **BaseAllocationMechanism.sol** - Lightweight proxy contract with fallback delegation and hook definitions
3. **ProperQF.sol** - Abstract contract providing incremental quadratic funding algorithm with alpha-weighted distribution (used by quadratic voting strategies)
4. **QuadraticVotingMechanism.sol** - Concrete implementation of quadratic funding using the ProperQF strategy

The system uses a hook-based architecture that allows implementers to customize voting behaviors while maintaining core security and flow invariants. This pattern provides significant gas savings and code reuse compared to traditional inheritance patterns.

### QuadraticVotingMechanism Implementation

QuadraticVotingMechanism.sol is an **abstract base contract** that provides the foundation for both Quadratic Funding (QF) and Quadratic Voting (QV) implementations:

**Key Features:**
- **Quadratic Cost Voting**: To cast W votes, users pay W² voting power (prevents plutocracy)
- **Alpha-Weighted Funding**: Configurable blend of quadratic (α) and linear (1-α) funding components
- **Role-Based Proposing**: Only keeper or management can create proposals (prevents spam)
- **Single Vote Per Proposal**: Users can only vote once per proposal (prevents vote splitting attacks)
- **Decimal Normalization**: Converts all voting power to 18 decimals for consistent calculations

**Implementation Variants:**
- **Quadratic Funding (QF)**: Users pay for voice credits → multiple signups appropriate for topping up
**Hook Implementations:**
1. **`_beforeProposeHook`**: Restricts proposal creation to keeper/management roles
2. **`_getVotingPowerHook`**: Normalizes deposit amounts to 18 decimals regardless of asset decimals
3. **`_processVoteHook`**: Implements quadratic cost (W² power for W votes) and enforces single-vote rule
4. **`_hasQuorumHook`**: Checks if total funding (quadratic + linear) meets threshold
5. **`_convertVotesToShares`**: Returns alpha-weighted funding as share amount
6. **`_availableWithdrawLimit`**: Enforces global timelock and grace period for redemptions

**Alpha Parameter:**
- Controls the balance between quadratic and linear funding: `F_j = α × (sum_sqrt)² + (1-α) × sum_contributions`
- Can be dynamically calculated via `calculateOptimalAlpha()` to ensure 1:1 shares-to-assets ratio (ignoring decimals)
- Adjustable by owner via `setAlpha()` for fine-tuning funding distribution

**Rounding Discrepancy (Mathematical Precision):**
- Due to integer division, total funding calculation differs from sum of individual project funding
- **Global**: `F(c) = ⌊α × ||Φ^LR(c)||₁⌋ + ⌊(1-α) × ||Φ^CAP(c)||₁⌋` (alpha applied to aggregated sums)
- **Individual**: `Fp(c) = ⌊α × Φ^LR(c)_p⌋ + ⌊(1-α) × Φ^CAP(c)_p⌋` (alpha applied per project)
- **Invariant**: `∑p∈P Fp(c) ≤ F(c)` with error bound `ε ∈ {0, 1, ..., 2(|P| - 1)}`
- **Practical Impact**: The discrepancy is negligible dust (≤ 2 wei per project) that ensures no over-allocation
- **Fund Distribution**: All available funds are still distributed - the error bound represents minimal rounding loss

**Security Features:**
- Rejects ETH deposits via custom `receive()` function (prevents permanent fund loss)
- Validates all mathematical operations to prevent overflow/underflow
- Enforces strict role-based access control for sensitive operations
- Integrates ProperQF's incremental update algorithm for gas-efficient tallying

### Yearn V3 Pattern Benefits
- **Gas Efficiency**: Deploy shared implementation once, reuse for all strategies
- **Reduced Audit Surface**: Core logic audited once, strategies only need hook review  
- **Code Reuse**: All standard functionality (signup, propose, castVote) shared across strategies
- **Storage Isolation**: Each strategy maintains independent storage despite shared implementation

### Delegation Pattern Architecture

1. **Storage Location**: All storage lives in the proxy contract (e.g., QuadraticVotingMechanism) following TokenizedAllocationMechanism's layout and whatever is added by the mechanism designer
2. **Logic Execution**: Shared logic executes in TokenizedAllocationMechanism's context via delegatecall
3. **Access Pattern**: Proxy contracts access storage through helper functions that return interfaces at `address(this)`

#### How It Works:
- When a proxy calls `_tokenizedAllocation().management()`, it casts `address(this)` to the TokenizedAllocationMechanism interface
- The call to `management()` on the proxy triggers the fallback function, which delegates to TokenizedAllocationMechanism
- TokenizedAllocationMechanism's code executes in the proxy's context, reading from the proxy's storage slots
- This returns the management address stored in the proxy's storage, enabling role-based access control
- This pattern works for all roles (`owner`, `management`, `keeper`, `emergencyAdmin`) across all mechanisms

#### Role Hierarchy:
- **Owner**: Primary admin with full control (can transfer ownership, pause/unpause)
- **Management**: Can configure operational parameters and settings
- **Keeper**: Can execute routine maintenance operations
- **Emergency Admin**: Can act in emergencies alongside management

### Hook-Based Modular Approach

The contract defines 11 strategic hooks that implementers must override to create specific voting mechanisms, but in practice they will take most of them from the type of voting they want to support and only implement a handful to shape the details like participation, timeline, and rules on fund distribution:

**Key Architectural Decision - Permissionless Queuing:**
The system implements **permissionless proposal queuing**, enabling flexible governance models:
- **Community-Driven**: Anyone can queue successful proposals, removing admin bottlenecks
- **Custom Access Control**: Mechanisms can enforce restrictions via `_requestCustomDistributionHook()` if needed
- **Governance Flexibility**: Supports both permissionless and permissioned models through hook customization

#### Core Validation Hooks
- **`_beforeSignupHook(address user)`** - Controls user registration eligibility
  - **Security Assumptions**: 
    - CAN be stateful to implement custom registration tracking
    - SHOULD implement consistent eligibility criteria that cannot be gamed
    - CAN implement mechanism-specific access control (e.g., allowset validation)
  - **Note**: Zero address validation and re-registration handling are performed in `_executeSignup`, not in this hook.
- **`_beforeProposeHook(address proposer)`** - Validates proposal creation rights
  - **Security Assumptions**:
    - MUST verify proposer has legitimate right to create proposals (e.g., voting power > 0, role-based access)
    - MUST be view function to prevent state changes during validation
    - SHOULD prevent spam by implementing appropriate restrictions
    - MAY restrict to specific roles (e.g., QuadraticVotingMechanism restricts to keeper/management only)
- **`_validateProposalHook(uint256 pid)`** - Ensures proposal ID validity
  - **Security Assumptions**:
    - MUST validate pid is within valid range (1 <= pid <= proposalCount)
    - MUST be view function for gas efficiency and security
    - SHOULD be used consistently before any proposal state access
- **`_beforeFinalizeVoteTallyHook()`** - Guards vote tally finalization
  - **Security Assumptions**:
    - CAN implement additional timing or state checks before finalization
    - MUST NOT revert unless finalization should be blocked
    - MAY update state if needed (e.g., snapshot values)
    - SHOULD return true in most implementations unless specific conditions aren't met

#### Voting Power & Processing Hooks
- **`_getVotingPowerHook(address user, uint256 deposit)`** - Calculates initial voting power
  - **Security Assumptions**:
    - MUST return deterministic voting power based on deposit amount
    - MUST be view function to ensure consistency
    - SHOULD implement fair and transparent power calculation
    - MAY normalize decimals for consistent voting power across different assets
  - **Note**: Overflow protection is performed in `_executeSignup`, not in this hook:
    - Overflow check: `if (newPower > MAX_SAFE_VALUE) revert VotingPowerTooLarge(newPower, MAX_SAFE_VALUE);`
- **`_processVoteHook(pid, voter, choice, weight, oldPower)`** - Processes vote and updates tallies
  - **Security Assumptions**:
    - MUST accurately update vote tallies based on weight and choice
    - MUST prevent double voting by checking hasVoted mapping
    - MUST validate quadratic cost (weight²) does not exceed voter's available power
    - SHOULD implement vote cost calculation (e.g., quadratic cost in QF)
    - MUST handle all VoteType choices appropriately (Against/For/Abstain)
  - **Note**: Power conservation invariant (newPower <= oldPower) and voting period validation are performed upstream in `TokenizedAllocationMechanism`, not in this hook
- **`_hasQuorumHook(uint256 pid)`** - Determines if proposal meets quorum requirements
  - **Security Assumptions**:
    - MUST implement consistent quorum calculation logic
    - MUST be view function for deterministic results
    - SHOULD base quorum on objective metrics (vote count, funding amount, etc.)
    - MUST NOT change quorum logic after voting has started
    - SHOULD return false for proposals with zero votes

#### Distribution Hooks
- **`_convertVotesToShares(uint256 pid)`** - Converts vote tallies to vault shares
  - **Security Assumptions**:
    - MUST implement fair and consistent vote-to-share conversion
    - MUST be view function for predictable outcomes
    - **Note**: Quorum enforcement is handled by `queueProposal()` which calls `hasQuorumHook()` before `convertVotesToShares()`
    - SHOULD consider total available assets to prevent over-allocation
    - MUST handle mathematical operations safely (no overflow/underflow)
    - MAY implement complex formulas (e.g., quadratic funding with alpha)
- **`_getRecipientAddressHook(uint256 pid)`** - Retrieves proposal recipient
  - **Security Assumptions**:
    - MUST return the correct recipient address for the proposal
    - MUST be view function to prevent manipulation
    - MUST NOT return address(0) for valid proposals
    - SHOULD revert with descriptive error for invalid proposals
    - MUST return consistent recipient throughout proposal lifecycle
- **`_requestCustomDistributionHook(address recipient, uint256 shares)`** - Handles custom share distribution
  - **Security Assumptions**:
    - MUST return (true, assetsTransferred) ONLY if custom distribution is fully handled
    - MUST transfer exact asset amount and report it for totalAssets accounting if returning true
    - MUST return (false, 0) if using default minting (shares will be minted automatically)
    - MAY implement vesting, splitting, threshold-based distribution, or other distribution logic
    - MUST handle reentrancy safely if making external calls
    - MUST ensure totalAssets accounting remains accurate by reporting transferred amounts
  - **Threshold-Based Distribution Pattern**: Common implementation strategy for conditional distribution:
    - **Direct Transfer Mode**: Transfer assets directly based on allocation criteria to optimize gas or implement custom logic
    - **Share Minting Mode**: Use default share minting for standard lifecycle management
    - **Asset Conversion**: Use `convertToAssets(sharesToMint)` to determine equivalent asset amount for direct transfers
    - **Conditional Logic**: Implement custom criteria to determine which distribution method to use
  - **Access Control Pattern**: Since `queueProposal()` is permissionless, this hook can enforce custom access control:
    - **Example**: `require(msg.sender == owner || hasRole(QUEUER_ROLE, msg.sender), "Unauthorized queuing")`
    - **Governance Models**: Can implement community-driven queuing, role-based access, or other patterns
    - **Flexibility**: Enables different governance models without requiring core contract changes
- **`_availableWithdrawLimit(address shareOwner)`** - Controls withdrawal limits with timelock enforcement
  - **Security Assumptions**:
    - MUST enforce timelock by returning 0 before globalRedemptionStart
    - MUST enforce grace period by returning 0 after `globalRedemptionStart + gracePeriod`
    - SHOULD return type(uint256).max for no limit (within valid redemption window)
    - MUST be view function for consistent results
    - Creates mutually exclusive windows: users can withdraw OR owner can sweep, never both
  - **Implementation Note**: This hook is what prevents withdrawals after grace period, enabling safe sweep
- **`_calculateTotalAssetsHook()`** - Calculates total assets including matching pools
  - **Security Assumptions**:
    - MUST accurately reflect total assets available for distribution
    - MUST include any external funding sources (matching pools, grants)
    - MUST be view function when called during finalization

### BaseAllocationMechanism Deep Dive

BaseAllocationMechanism.sol serves as the lightweight proxy contract in the Yearn V3 pattern. It contains minimal code while enabling full functionality through delegation:

**Core Architecture:**
- **Immutable Storage**: Only stores `tokenizedAllocationAddress` and `asset` as immutable values
- **Constructor Initialization**: Initializes TokenizedAllocationMechanism storage via delegatecall during deployment
- **Hook Definitions**: Defines 12 abstract internal hooks that concrete implementations must override
- **External Hook Wrappers**: Provides external versions of hooks with `onlySelf` modifier for security
- **Fallback Delegation**: Implements assembly-based fallback to delegate all undefined calls to TokenizedAllocationMechanism

**Security Pattern - onlySelf Modifier:**
```solidity
modifier onlySelf() {
    require(msg.sender == address(this), "!self");
    _;
}
```
This ensures hooks can only be called via delegatecall from TokenizedAllocationMechanism where `msg.sender == address(this)`. This prevents external actors from directly calling the TokenizedAllocationMechanism contract to invoke hooks, maintaining strict security boundaries.

**Hook Implementation Pattern:**
Each hook follows a three-layer pattern:
1. **Abstract Internal**: `function _hookName(...) internal virtual returns (...)`
2. **External Wrapper**: `function hookName(...) external onlySelf returns (...) { return _hookName(...); }`
3. **Interface Call**: TokenizedAllocationMechanism calls via `IBaseAllocationStrategy(address(this)).hookName(...)`

**Helper Functions for Implementers:**
- `_tokenizedAllocation()`: Returns TokenizedAllocationMechanism interface at current address
- `_getProposalCount()`: Get total number of proposals
- `_proposalExists(pid)`: Check if proposal ID is valid
- `_getProposal(pid)`: Retrieve proposal details
- `_getVoteTally(pid)`: Get current vote tallies
- `_getVotingPower(user)`: Check user's voting power
- `_getQuorumShares()`: Get quorum requirement
- `_getRedeemableAfter(shareOwner)`: Check timelock status
- `_getGracePeriod()`: Get grace period configuration

**Fallback Function:**
The fallback uses inline assembly for gas-efficient delegation:
1. Copies calldata to memory
2. Performs delegatecall to TokenizedAllocationMechanism
3. Copies return data
4. Returns data or reverts based on delegatecall result

This pattern enables complete code reuse while maintaining storage isolation and upgrade safety through immutability.

## Functional Requirements

#### FR-1: User Registration & Voting Power
- **Requirement:** Users must be able to register with optional asset deposits to gain voting power
- **Implementation:** `signup(uint256 deposit)` function in TokenizedAllocationMechanism with `_beforeSignupHook()` and `_getVotingPowerHook()` in strategy
- **Acceptance Criteria:**
  - Registration restrictions are mechanism-specific via `_beforeSignupHook()` implementation
  - Registration requires hook validation to pass via `IBaseAllocationStrategy` interface
  - Voting power is calculated through customizable hook in strategy contract
  - Multiple signups accumulate voting power (implemented in `_executeSignup` - appropriate for QF)
  - Asset deposits are transferred securely using ERC20 transferFrom
  - Operation blocked when contract is paused (`whenNotPaused` modifier)

#### FR-2: Proposal Creation & Management
- **Requirement:** Authorized users must be able to create proposals targeting specific recipients
- **Implementation:** `propose(address recipient, string description)` function in TokenizedAllocationMechanism with `_beforeProposeHook()` in strategy
- **Acceptance Criteria:**
  - Each recipient address can only be used once across all proposals
  - Proposal creation requires hook-based authorization via interface
  - Proposals receive unique incremental IDs
  - Recipients cannot be zero address
  - In QuadraticVotingMechanism: Only keeper or management roles can create proposals

#### FR-3: Democratic Voting Process
- **Requirement:** Registered users must be able to cast weighted votes (For/Against/Abstain) on proposals
- **Implementation:** `castVote(uint256 pid, VoteType choice, uint256 weight)` in TokenizedAllocationMechanism with `_processVoteHook()` in strategy
- **Acceptance Criteria:**
  - Users can only vote once per proposal
  - Quadratic cost (weight²) cannot exceed user's current voting power
  - Votes can only be cast during active voting period (validated upstream)

#### FR-4: Vote Tally Finalization
- **Requirement:** System must provide mechanism to finalize vote tallies after voting period ends
- **Implementation:** `finalizeVoteTally()` function with `_beforeFinalizeVoteTallyHook()` and owner-only access control
- **Acceptance Criteria:**
  - Can only be called after voting period ends
  - Can only be called once per voting round
  - Requires hook validation before proceeding
  - Sets tallyFinalized flag to true

#### FR-5: Proposal Queuing & Share Allocation
- **Requirement:** Successful proposals must be queued and vault shares minted to recipients
- **Implementation:** `queueProposal(uint256 pid)` with `_requestCustomDistributionHook()` and direct `_mint()` calls
- **Access Control Design:** `queueProposal` is **permissionless** to enable flexible governance models, but access control can be enforced via `_requestCustomDistributionHook()` if needed
- **Acceptance Criteria:**
  - Can only queue proposals after tally finalization
  - Proposals must meet quorum requirements via `_hasQuorumHook()`
  - Share amount determined by `_convertVotesToShares()` hook
  - Shares actually minted to recipient via internal `_mint()` function OR custom distribution via hook
  - **Custom Distribution Accounting**: If `_requestCustomDistributionHook()` returns `(true, assetsTransferred)`, then:
    - `totalAssets` is reduced by `assetsTransferred` to maintain accurate accounting
    - Prevents accounting discrepancies between actual balance and `totalAssets` tracking
  - Timelock delay applied before redemption eligibility
  - **Permissionless queuing** enables community-driven execution without admin bottlenecks
  - **Custom distribution hook** can implement access control or other types of distributions altogether

#### FR-6: Proposal State Management
- **Requirement:** System must track and expose proposal states throughout lifecycle
- **Implementation:** `state(uint256 pid)` and `_state()` functions with comprehensive state machine
- **Acceptance Criteria:**
  - States: Pending, Active, Canceled, Defeated, Succeeded, Queued, Redeemable, Expired
  - State transitions follow predefined rules based on timing and votes
  - Canceled proposals remain permanently canceled
  - Grace period handling for expired proposals

#### FR-7: Proposal Cancellation
- **Requirement:** Proposals must be cancellable before queuing
- **Implementation:** `cancelProposal(uint256 pid)` function with proposer authorization
- **Acceptance Criteria:**
  - Can only cancel valid, non-canceled proposals
  - Cannot cancel already queued proposals
  - Cancellation is permanent and irreversible
  - Only proposer can cancel their proposals

#### FR-8: Share Redemption & Asset Distribution
- **Requirement:** Recipients must be able to redeem allocated shares for underlying assets after timelock
- **Implementation:** Share redemption `redeem(shares, receiver, owner)` function with timelock validation
- **Acceptance Criteria:**
  - Recipients can redeem shares only after timelock period expires
  - Shares are burned upon redemption, reducing total supply
  - Underlying assets transferred to recipient from mechanism vault
  - Redemption amount follows standard share-to-asset conversion
  - Recipients can redeem partial amounts or full allocation
  - **Grace Period Enforcement**: Shares become unredeemable after `globalRedemptionStart + gracePeriod`

#### FR-9: Asset Recovery via Sweep Function
- **Requirement:** Owner must be able to recover unclaimed tokens and ETH after grace period expires to prevent permanent fund lock
- **Implementation:** `sweep(address token, address receiver)` function in TokenizedAllocationMechanism (shared implementation level)
- **Acceptance Criteria:**
  - Can only be called by owner role
  - Requires grace period to be fully expired: `block.timestamp > globalRedemptionStart + gracePeriod`
  - Can sweep any ERC20 token or ETH (address(0))
  - Prevents sweeping before grace period ends to protect late redeemers
  - Emits `Swept` event for transparency
  - **Enforcement Level**: TokenizedAllocationMechanism (core shared implementation)
  - **Grace Period Check**: Enforced at mechanism level via `_availableWithdrawLimit()` hook

#### FR-10: Emergency Controls & Admin Functions
- **Requirement:** System must provide emergency controls for critical situations and admin functions for operational management
- **Implementation:** Multiple admin functions in TokenizedAllocationMechanism (shared implementation level)
- **Functions:**
  - `pause()` / `unpause()`: Emergency stop mechanism for all operations
  - `transferOwnership(newOwner)` / `acceptOwnership()`: Two-step ownership transfer
  - `cancelOwnershipTransfer()`: Cancel pending ownership transfer
  - `setKeeper(address)`: Update keeper role
  - `setManagement(address)`: Update management role
- **Acceptance Criteria:**
  - All functions restricted to owner role (except acceptOwnership for pending owner)
  - Pause blocks all state-changing operations via `whenNotPaused` modifier
  - Two-step ownership transfer prevents accidental loss of ownership
  - All role updates emit corresponding events
  
#### FR-11: EIP-712 Signature Support
- **Requirement:** System must support gasless transactions via EIP-712 signatures for key user operations
- **Implementation:** Signature functions in TokenizedAllocationMechanism with domain separator and nonce management
- **Functions:**
  - `signupWithSignature()`: Register with voting power using signature
  - `castVoteWithSignature()`: Cast votes using signature
  - `DOMAIN_SEPARATOR()`: Returns EIP-712 domain separator with fork protection
  - `nonces(address)`: Track signature nonces for replay protection
- **Acceptance Criteria:**
  - Signatures include deadline parameter to prevent old signature reuse
  - Nonces increment atomically to prevent replay attacks
  - Domain separator includes chain ID
  - Invalid signatures revert with appropriate errors
 
#### FR-12: Share Transfer Restrictions
- **Requirement:** Share transfers must be blocked until redemption period starts to prevent early trading
- **Implementation:** Transfer restriction logic in `_transfer()` function of TokenizedAllocationMechanism
- **Acceptance Criteria:**
  - Shares cannot be transferred before `globalRedemptionStart`
  - After redemption starts, shares are freely transferable
  - Restriction applies to both `transfer()` and `transferFrom()`
  
#### FR-13: Optimal Alpha Calculation for Quadratic Funding
- **Requirement:** System must support dynamic calculation of optimal alpha parameter to ensure 1:1 shares-to-assets ratio (ignoring decimals) given a fixed matching pool
- **Implementation:** `calculateOptimalAlpha(matchingPoolAmount, totalUserDeposits)` in QuadraticVotingMechanism and `_calculateOptimalAlpha()` in ProperQF
- **Acceptance Criteria:**
  - Calculates alpha that ensures total funding equals total available assets (ignoring decimal precision differences)
  - Handles edge cases: no quadratic advantage (α=0), insufficient assets (α=0), excess assets (α=1)
  - Returns fractional alpha as numerator/denominator for precision
  - Can be called before finalization to determine optimal funding parameters
  - Supports dynamic adjustment of alpha via `setAlpha()` by mechanism owner

## System Invariants & Constraints

### Timing Invariants
1. **Voting Window**: `startTime + votingDelay ≤ voting period ≤ startTime + votingDelay + votingPeriod`
2. **Registration Cutoff**: Users can only register before `startTime + votingDelay + votingPeriod`
3. **Tally Finalization**: Can only occur after `startTime + votingDelay + votingPeriod`
4. **Timelock Enforcement**: Shares redeemable only after `block.timestamp ≥ eta`
5. **Grace Period**: 
   - Share redemption window: From `globalRedemptionStart` to `globalRedemptionStart + gracePeriod`
   - Proposals transition to `Expired` state after grace period ends
   - `_availableWithdrawLimit()` returns 0 after grace period (enforced at mechanism level)
   - Owner can call `sweep()` only after grace period expires (enforced in TokenizedAllocationMechanism)

### Power Conservation Invariants
1. **Non-Increasing Power**: `_processVoteHook()` must return `newPower ≤ oldPower`
2. **Multiple Registration Policy**: Multiple signups are allowed in `_executeSignup` with voting power accumulation
   - **Implementation**: `uint256 totalPower = s.votingPower[user] + newPower;` in `_executeSignup`
   - **QuadraticVotingMechanism (Abstract)**: Allows multiple signups by default - serves as base for both QF and QV variants
   - **Quadratic Funding (QF) Variants**: Multiple signups appropriate since users pay for additional voice credits  
   - **Quadratic Voting (QV) Variants**: Multiple signups allowed but may not align with QV assumptions
   - **Custom Mechanisms**: Can implement access control via `_beforeSignupHook()` but cannot prevent re-registration

### State Consistency Invariants
1. **Unique Recipients**: Each recipient address used in at most one proposal
2. **Tally Finality**: `tallyFinalized` can only transition from false to true
3. **Proposal ID Monotonicity**: Proposal IDs increment sequentially starting from 1
4. **Cancellation Finality**: Canceled proposals cannot be un-canceled

### Security Invariants
1. **Hook Validation**: All critical operations protected by appropriate hooks
2. **Asset Safety**: ERC20 transfers use SafeERC20 for secure token handling
3. **Access Control**: Sensitive operations require proper validation
4. **Reentrancy Protection**: TokenizedAllocationMechanism uses ReentrancyGuard modifier
5. **Storage Isolation**: ProperQF uses EIP-1967 storage pattern to prevent collisions

## Complete User Journey Documentation

This section maps the full end-to-end experience for all three primary user types in the allocation mechanism system.

### 🗳️ VOTER JOURNEY

Voters are community members who deposit assets to gain voting power and participate in democratic resource allocation.

#### Phase 1: Registration & Deposit
**User Story:** "As a community member, I want to register and stake tokens so I can vote on funding allocations"

**Actions:**
1. **Approve Tokens**: `token.approve(mechanism, depositAmount)`
2. **Register**: `mechanism.signup(depositAmount)` 
3. **Receive Voting Power**: System calculates power via `_getVotingPowerHook()`

**System Response:**
- Assets transferred from voter to mechanism vault
- Voting power assigned
- UserRegistered event emitted
- Voter can now participate in voting

**Key Constraints:**
- Registration policy varies by mechanism (see Multiple Registration Policy in System Invariants)
- Must register before voting period ends
- **No asset recovery** - deposited tokens locked until mechanism concludes
- Voting power calculation customizable per mechanism
- QuadraticVotingMechanism: Voting power normalized to 18 decimals regardless of asset decimals

#### Phase 2: Proposal Discovery & Voting
**User Story:** "As a registered voter, I want to review proposals and cast weighted votes to influence fund distribution"

**Actions:**
1. **Review Proposals**: Check proposal details via `mechanism.proposals(pid)`
2. **Cast Votes**: `mechanism.castVote(pid, VoteType.For/Against/Abstain, voteWeight)`
3. **Monitor Progress**: Track remaining voting power via `mechanism.votingPower(address)`

**System Response:**
- Vote tallies updated through `_processVoteHook()`
- Voter's remaining power reduced by quadratic cost (weight²)
- VotesCast event emitted
- Vote recorded (cannot be changed)

**Key Constraints:**
- Can only vote during active voting window
- One vote per proposal per voter (immutable)
- Quadratic cost (weight²) cannot exceed remaining voting power
- Must manage power across multiple proposals strategically
- QuadraticVotingMechanism: To cast W votes costs W² voting power (quadratic cost)
- QuadraticVotingMechanism: Only "For" votes supported (no Against/Abstain)

#### Phase 3: Post-Voting Monitoring  
**User Story:** "As a voter, I want to see voting results and understand how my votes influenced the outcome"

**Actions:**
- **Monitor Results**: View vote tallies via `mechanism.getVoteTally(pid)`
- **Check Proposal States**: Track proposal outcomes via `mechanism.state(pid)`
- **Await Asset Recovery**: Wait for mechanism conclusion or asset recovery mechanism

**System Response:**
- Real-time vote tally visibility
- Proposal state transitions (Defeated/Succeeded/Queued)
- Final allocation determined by successful proposals

**Asset Recovery:**
- **Voter deposits**: No direct recovery mechanism for voters after voting concludes
- **Unclaimed shares**: Owner can recover unclaimed assets via `sweep()` after grace period expires
- **Timeline protection**: Sweep is blocked during redemption window to protect recipients

---

### 👨‍💼 ADMIN JOURNEY

Admins are trusted operators who manage the voting lifecycle and ensure proper governance execution.

#### Phase 1: Mechanism Deployment & Setup
**User Story:** "As a funding round operator, I want to deploy and configure a voting mechanism for my community"

**Actions:**
1. **Deploy Mechanism**: Use `AllocationMechanismFactory.deploySimpleVotingMechanism(config)` or `deployQuadraticVotingMechanism(config, alphaNumerator, alphaDenominator)`
2. **Configure Parameters**: Set voting delays, periods, quorum requirements, timelock, and alpha (for quadratic)
3. **Announce Round**: Communicate mechanism address and voting schedule to community

**System Response:**
- Lightweight proxy deployed using shared TokenizedAllocationMechanism
- Admin becomes owner with privileged access
- AllocationMechanismInitialized event emitted
- Mechanism ready for user registration

**Key Responsibilities:**
- Choose appropriate voting parameters for community size
- Ensure sufficient timelock for security
- Communicate timing and rules clearly to participants

#### Phase 2: Round Monitoring & Validation
**User Story:** "As an admin, I want to monitor voting progress and ensure fair process execution"

**Actions:**
- **Monitor Registration**: Track user signups and voting power distribution
- **Validate Proposals**: Ensure proposal creation follows rules
- **Watch Voting**: Monitor vote casting and detect any irregularities
- **Prepare for Finalization**: Ensure readiness when voting period ends

**System Response:**
- Events provide real-time monitoring capabilities
- Vote tallies visible throughout voting period
- Proposal state tracking enables intervention if needed

**Key Responsibilities:**
- Ensure fair access to registration and voting
- Monitor for gaming or manipulation attempts
- Prepare community for finalization timeline

#### Phase 3: Finalization & Execution
**User Story:** "As an admin, I want to finalize voting results and execute successful proposals"

**Actions:**
1. **Calculate Optimal Alpha** (Optional): `mechanism.calculateOptimalAlpha(matchingPoolAmount, totalUserDeposits)` to determine optimal funding parameters
2. **Set Alpha** (Optional): `mechanism.setAlpha(alphaNumerator, alphaDenominator)` to adjust quadratic vs linear weighting
3. **Finalize Voting**: `mechanism.finalizeVoteTally()` (after voting period ends)
4. **Queue Successful Proposals** (Optional): `mechanism.queueProposal(pid)` for each successful proposal - **Note: This is permissionless by default and can be done by anyone**
5. **Monitor Redemption**: Track recipient share redemption after timelock

**System Response:**
- Optimal alpha calculated to ensure 1:1 shares-to-assets ratio
- Alpha parameter updated if admin chooses to adjust
- Vote tallies permanently finalized (tallyFinalized = true)
- Successful proposals transition to Queued state
- Shares minted to recipients with timelock enforcement
- ProposalQueued events emitted with redemption timeline

**Key Responsibilities:**
- **Consider optimal alpha** to maximize quadratic funding within budget constraints
- **Must finalize promptly** after voting period to enable queuing
- **Permissionless queuing** means anyone can queue successful proposals - admins can facilitate but are not required
- Communicate redemption timeline to recipients
- Ensure proper execution of funding round outcomes

#### Phase 4: Asset Recovery & Cleanup
**User Story:** "As an admin, I want to recover any unclaimed funds after the grace period to prevent permanent lock"

**Actions:**
1. **Monitor Redemptions**: Track which recipients have claimed their shares
2. **Wait for Grace Period**: Ensure `block.timestamp > globalRedemptionStart + gracePeriod`
3. **Sweep Unclaimed Assets**: Call `mechanism.sweep(tokenAddress, receiverAddress)` for each token
4. **Sweep ETH if needed**: Call `mechanism.sweep(address(0), receiverAddress)` for ETH

**System Response:**
- Sweep function validates grace period has expired
- Transfers all remaining tokens/ETH to specified receiver
- Emits Swept events for each recovery
- Contract is now clean of stuck funds

**Key Responsibilities:**
- **Wait for full grace period** to ensure all recipients had fair chance to claim
- **Document swept assets** for transparency and accounting
- **Communicate to community** about unclaimed fund recovery

---

### 💰 RECIPIENT JOURNEY

Recipients are the beneficiaries of successful funding proposals who receive allocated vault shares.

#### Phase 1: Proposal Advocacy
**User Story:** "As a project seeking funding, I want to get my proposal created and advocate for community support"

**Actions:**
- **Find Proposer**: Work with user who can create proposal accourding to mechanism design
- **Proposal Creation**: Proposer calls `mechanism.propose(recipientAddress, description)`
- **Campaign**: Advocate to voters during voting period

**System Response:**
- Proposal created with unique ID
- Recipient address locked to this proposal (cannot be reused)
- ProposalCreated event emitted
- Proposal enters Active state when voting begins

**Key Constraints:**
- Each address can only be recipient of one proposal
- Cannot modify recipient address after proposal creation
- **QuadraticVotingMechanism**: Only keeper or management can propose (not regular voters)

#### Phase 2: Voting Period & Outcome
**User Story:** "As a recipient, I want to track voting progress and understand if my proposal will succeed"

**Actions:**
- **Monitor Votes**: Track vote tallies via `mechanism.getVoteTally(proposalId)`
- **Check Status**: Monitor proposal state via `mechanism.state(proposalId)`
- **Await Results**: Wait for voting finalization and outcome determination

**System Response:**
- Real-time vote tracking available
- Proposal state updates based on vote progress
- Final outcome determined by quorum and net vote calculation

**Possible Outcomes:**
- **Succeeded**: Net votes meet quorum requirement
- **Defeated**: Failed to meet quorum
- **Canceled**: Proposer canceled before completion

#### Phase 3: Share Allocation & Redemption
**User Story:** "As a successful recipient, I want to claim my allocated shares and redeem them for underlying assets"

**Actions (for Successful Proposals):**
1. **Wait for Queuing**: Call `queueProposal(pid)` after finalization
2. **Receive Shares**: Shares automatically minted to recipient address
3. **Wait for Timelock**: Cannot redeem until after end of redemption window
4. **Redeem Assets**: `mechanism.redeem(shares, recipient, recipient)` to claim underlying tokens

**System Response:**
- Shares minted directly to recipient (ERC20-compatible)
- Timelock enforced (typically 1+ days for security)
- Share-to-asset conversion follows standard vault accounting
- Assets transferred from mechanism vault to recipient

**Key Benefits:**
- **ERC20 Shares**: Become transferable once redemption period starts (not before)
- **Flexible Redemption**: Can redeem partial amounts over time
- **Timelock Protection**: Prevents immediate extraction, enables intervention if needed
- **Fair Conversion**: Share value based on actual vote allocation
- **Transfer Timeline**: Shares locked until `globalRedemptionStart`, then freely transferable

#### Phase 4: Asset Utilization
**User Story:** "As a funded recipient, I want to use allocated resources for the intended purpose"

**Actions:**
- **Claim Underlying Assets**: Redeem shares for tokens (USDC, ETH, etc.)
- **Execute Project**: Use funds according to proposal description
- **Report Back**: Provide community updates on fund utilization (off-chain)

**System Response:**
- Assets transferred to recipient's control
- Share supply reduced, maintaining vault accounting
- Allocation mechanism completes its role

**Long-term Considerations:**
- Recipients have full control over redeemed assets
- Can potentially redeem incrementally based on project milestones*
- **Soft enforcement** of fund usage (social/legal layer responsibility)

---

## Cross-Journey Integration Points

### 🔄 Multi-User Interactions

1. **Admin-Community Coordination**: Admins manage timing while community participates
2. **Voter-Recipient Dynamics**: Voting decisions directly impact recipient funding
3. **Timelock Security**: Protects all parties by preventing immediate extraction

### 📊 System-Wide Invariants

- **Fairness Guarantee**: All participants operate under same rules and timing
- **Transparency**: All votes, proposals, and allocations are publicly visible
- **Immutability**: Key decisions (votes, proposals) cannot be reversed once committed

### 🛡️ Security & Governance Features

- **Timelock Protection**: Delays execution to enable intervention if needed
- **Grace Period Protection**: Defines clear redemption window with automatic expiration
- **Hook Customization**: Allows different voting strategies while maintaining security
- **Two-Step Ownership Transfer**: Prevents accidental loss of admin control
- **Emergency Pause**: Owner can halt all operations in critical situations
- **Role-Based Access**: Separate roles for owner, management, keeper, and emergency admin
- **EIP-712 Signatures**: Gasless transactions with replay protection
- **Transfer Restrictions**: Shares locked until redemption period starts
- **Asset Recovery**: Sweep function prevents permanent fund lock after grace period
- **Event Transparency**: Complete audit trail via blockchain events

## Hook Implementation Guidelines

### Critical Implementation Pattern (Yearn V3)
All hooks follow a dual-layer pattern:
1. **Internal Hook**: `function _hookName(...) internal virtual returns (...)`
2. **External Interface**: `function hookName(...) external onlySelf returns (...) { return _hookName(...); }`
3. **Interface Call**: TokenizedAllocationMechanism calls via `IBaseAllocationStrategy(address(this)).hookName(...)`

### Security-Critical Hooks
- **`_beforeSignupHook()`**: MUST validate user eligibility to prevent unauthorized registration
- **`_beforeProposeHook()`**: MUST validate proposer authority to prevent spam/invalid proposals  
- **`_validateProposalHook()`**: MUST validate proposal ID integrity to prevent invalid state access

### Mathematical Hooks
- **`_getVotingPowerHook()`**: Should implement consistent power allocation based on deposits/eligibility
- **`_processVoteHook()`**: MUST maintain vote tally accuracy and ensure power conservation. For quadratic funding implementations, integrates with ProperQF's incremental update algorithm
- **`_convertVotesToShares()`**: Should implement fair conversion from votes to economic value. In quadratic funding, uses alpha-weighted formula: `α × quadraticFunding + (1-α) × linearFunding`
- **`_hasQuorumHook()`**: Must implement consistent quorum calculation based on total funding for the proposal

### Integration Hooks
- **`_getRecipientAddressHook()`**: Should return consistent recipient for share distribution
- **`_requestDistributionHook()`**: Should handle integration with external distribution systems
- **`_beforeFinalizeVoteTallyHook()`**: Can implement additional safety checks or state validation

## Technical Constraints

### Integration Requirements
- ERC20 asset must be specified at deployment time via AllocationConfig
- Vault share minting system integrated into TokenizedAllocationMechanism with standard accounting
- Event emission provides off-chain integration points for monitoring and indexing
- Factory pattern ensures proper owner context (deployer becomes owner, not factory)
