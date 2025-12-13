# Code Review Checklist

**Purpose**: Comprehensive review guide for human and AI reviewers. For high-level philosophy and principles, see [copilot-instructions.md](copilot-instructions.md).

---

## Critical Rules

### Error Handling
- **ALWAYS** use `require` with custom errors (Solidity 0.8.26+)
- **NEVER** use `if + revert` pattern

### ERC-4626 Rounding (CRITICAL - Can Drain Vaults)
- **Deposit/mint**: Round DOWN shares (favors vault)
- **Withdraw/redeem**: Round UP shares (favors vault)
- Use `Math.mulDiv` with explicit `Rounding.Down` or `Rounding.Up`
- ALWAYS ROUND IN FAVOR OF THE PROTOCOL

### Naming Conventions
- Contracts: `PascalCase`
- Functions: `mixedCase`, `_privateInternal()`
- Variables: `mixedCase`, `_privateState`
- Constants: `ALL_CAPS`
- Errors: `PascalCase`, module-prefixed: `ModuleName__SpecificError`

---

## Security Review Checklist

### Red Flags (Always Flag)
- ❌ Unchecked `call` without error handling
- ❌ Missing access control on privileged functions
- ❌ Silent asset movement (no events)
- ❌ Direct `tx.origin` authorization
- ❌ Infinite/unbounded loops
- ❌ State updates after external calls (CEI violation)
- ❌ Re-initialization vulnerabilities (missing `initialized` checks)
- ❌ Conversion operations before burns/transfers (incorrect order)
- ❌ Asymmetric conversion functions (deposit vs withdraw math mismatch)
- ❌ Time-based accrual logic that skips updates on zero amounts
- ❌ Accounting variables not updated after direct asset transfers (bypassing share mechanism)
- ❌ Multi-step decimal conversions (e.g., 27→18→27 decimals loses precision)
- ❌ Parameters used for checks differ from parameters used for execution
- ❌ Operations that fail when external protocols pause/revert (no graceful handling)
- ❌ Same asset serving multiple roles (stake token == reward token enables privilege escalation)

### Asset Safety
- Vaults/strategies CANNOT transfer, burn, or misaccount user assets outside audited flows
- All asset movements MUST emit indexed events
- Track balance changes in state BEFORE external calls (CEI pattern)

### Access Control
- ALL privileged functions use explicit role checks
- Use: `Ownable2Step`, `AccessControl`, Safe modules, or Hats
- NEVER bare `msg.sender` checks for admin functions
- Role bitmask pattern for multiple roles

### External Calls
- Use ONLY `SafeERC20` for token transfers
- ALL unchecked low-level calls are vulnerabilities
- Always check return values
- NEVER use raw `.transfer()` or `.send()`

### Reentrancy (CEI Pattern)
- REQUIRE `ReentrancyGuard` on all external flows moving assets
- Order: Checks → Effects → Interactions
- NEVER send funds before updating storage
- Protect against strategy callback reentrancy (strategies can give callbacks to attackers)
- Update debt/state BEFORE external calls, not after

### State Machines
- Validate ALL transitions in vault/round/strategy logic
- Require explicit state checks before state changes
- No implicit state assumptions

### ERC-4626 Compliance
- Validate edge cases: zero deposit/withdraw, max values, first depositor
- Correct rounding (deposit: DOWN, withdraw: UP)
- Check precision loss in multi-step decimal conversions (avoid 27→18→27)
- CRITICAL: Ensure `_convertToShares()` and `_convertToAssets()` are mathematical inverses
- Avoid asymmetric conversion logic that creates arbitrage opportunities
- Account for idle assets in `totalAssets` calculations
- Never compare exchange rates with mismatched decimals
- Edge cases with accumulated state: Check `totalAssets + lossAmount` not just `totalAssets`
- Update `totalAssets` immediately when bypassing share mechanism (direct transfers)

### Health Checks
- All yield harvest/rebalance/allocation verifies limits
- Emit events for significant state changes
- Slippage protection on all swaps

### Testing Requirements
- Test edge cases: zero/max deposit, withdrawal
- Fuzz test all user-facing functions
- Test admin function access control
- Test external call failures (protocol paused, reverts)
- Test with accumulated state (non-zero loss/debt)
- Test parameter mismatches (check vs execution)
- Test cross-chain timing issues (blocks vs timestamps)
- Test underflow scenarios (loss + fees > totalAssets)
- Check CI for coverage targets

---

## Anti-Patterns (Flag These)

1. ❌ Using `if + revert` instead of `require` with custom errors
2. ❌ Wrong rounding direction in ERC-4626 conversions
3. ❌ Duplicating NatSpec instead of using `@inheritdoc`
4. ❌ Specifying units for standard ERC-4626 parameters
5. ❌ Skipping validation on user inputs
6. ❌ Using blocklists instead of allowlists for critical operations
7. ❌ Hardcoding addresses instead of immutables/constants
8. ❌ State updates after external calls (CEI violation)
9. ❌ Missing events on asset movements or admin actions
10. ❌ Unchecked external calls
11. ❌ Mocking the system under test (only mock dependencies)
12. ❌ Missing re-initialization protection in `initialize()` functions
13. ❌ Burning/transferring before converting (convert first, then burn/transfer)
14. ❌ Conditional state updates that skip time elapsed (update time even if amount is zero)
15. ❌ Forgetting to account for idle assets in harvest/report functions
16. ❌ Using `transferFrom()` when `from == address(this)` (use `transfer()` instead)
17. ❌ Applying configuration changes retroactively to already-earned fees
18. ❌ Off-by-one errors in time-based state transitions (voting periods, etc.)
19. ❌ Sandwich-vulnerable admin functions without private mempool protection
20. ❌ Loss tracking that doesn't account for new depositors diluting losses
21. ❌ Not updating accounting variables (`totalAssets`) after direct asset transfers
22. ❌ Multi-step decimal conversions that lose precision (convert directly, not via intermediate precision)
23. ❌ Checking parameters that differ from execution parameters (array mismatch, flag mismatch)
24. ❌ Operations failing when external protocols pause (add paused state checks, graceful degradation)
25. ❌ Zero checks without accounting for accumulated state (`totalAssets == 0` but `lossAmount > 0`)
26. ❌ Same asset used for multiple purposes without isolation (stake == reward enables theft)
27. ❌ Allowing operations on unreported state (sync/report before dependent operations)
28. ❌ Block-based timing on multi-chain deployments (use timestamps for cross-chain consistency)
29. ❌ Arithmetic operations without underflow protection (e.g., `loss + fees > totalAssets`)

---

## Required Patterns

### Input Validation
- Validate: `asset != address(0)`, `shares != 0`, `feeBps <= MAX_BPS`

### Safe Math
- Use `Math.mulDiv` for precision (OpenZeppelin)
- ALWAYS ROUND IN FAVOR OF THE PROTOCOL

### Proxy Deployment
- Use `Clones.cloneDeterministic` (EIP-1167)
- Salt: `keccak256(abi.encodePacked(deployer, params))`

### Test Naming
- Files: `ContractName.t.sol`, `ContractNameIntegration.t.sol`
- Functions: `test_scenario()`, `testFuzz_scenario(uint x)`, `test_RevertWhen_condition()`

---

## NatSpec Requirements

**See [CONTRIBUTING.md](../CONTRIBUTING.md) for full standards.**

### Required Tags
- Contracts: `@title`, `@author`, `@custom:security-contact`
- Functions: `@notice`, `@param`, `@return`
- Modified code: `@custom:origin`
- Security-sensitive: `@custom:security`

### Key Rules
- Use `@inheritdoc` for overrides (DON'T duplicate)
- Document WHY, not WHAT
- Units only when ambiguous: `@param feeBps Fee in basis points (10000 = 100%)`
- NO units for standard ERC-4626: `@param assets Amount of assets` ✓
- Errors are self-documenting (NO `@notice`)

---

## Octant-Specific Requirements

- **Safe/Dragon Modules**: ALL privileged execution verifies sender/module context. Module functions have full Safe permissions.
- **Factories**: ALL deployments transfer control to Safe/multisig (NEVER EOA)
- **Yield/Donation**: Assets redirected MUST update accounting

---

---

## Core Contracts (Vaults & Strategies)

### Initialization Protection
- ALL `initialize()` functions MUST prevent re-initialization
- Require `s.initialized == false` before setting state
- Example: `require(!s.initialized, "Already initialized");`

### BaseStrategy Implementation
All strategies MUST implement:
- `_deployFunds(uint256 amount)` - Deploy assets to protocol
- `_freeFunds(uint256 amount)` - Withdraw assets from protocol
- `_harvestAndReport()` returns `(uint256 profit, uint256 loss)` - Report performance

**CRITICAL `_harvestAndReport()` Requirements:**
- MUST account for idle assets (not just deployed assets)
- Include `balanceOf(asset)` in total assets calculation
- Handle emergency withdrawal scenarios where funds are freed but not yet redeployed
- Handle external protocol paused/unavailable states gracefully (check paused before deposits)
- Example: `totalAssets = deployedAssets + IERC20(asset).balanceOf(address(this))`

### TokenizedStrategy Pattern
- Use immutable proxy pattern
- Store `ITokenizedStrategy public immutable TokenizedStrategy`
- Delegatecall to TokenizedStrategy for all ERC-4626 operations
- Implement strategy-specific logic in override functions

### Role Management
- Use bitmask pattern for roles
- Enum for role types: `ADD_STRATEGY_MANAGER`, `DEBT_MANAGER`, `EMERGENCY_MANAGER`, etc.
- `mapping(address => uint256) public roles` - Store as bitmask
- Check: `(roles[account] & (1 << uint256(role))) != 0`
- Grant: `roles[account] |= (1 << uint256(role))`
- Revoke: `roles[account] &= ~(1 << uint256(role))`

### Debt Management
- Track `StrategyParams`: `activation`, `lastReport`, `currentDebt`, `maxDebt`
- Update debt atomically (either deploy or withdraw, never both)
- Update `currentDebt` state BEFORE external calls, not after (prevents reentrancy exploits)
- Protect against strategy callback reentrancy with ReentrancyGuard

### Fee Calculations
- Always use basis points: `10000 = 100%`
- Constant: `MAX_BPS = 10_000`
- Calculate: `fee = (amount * feeBps) / MAX_BPS`
- Protect against underflow: if `loss + fees > totalAssets`, cap fees or handle gracefully

### Decimal Conversions
- Avoid multi-step conversions that lose precision (e.g., 27→18→27 decimals)
- Convert directly to target precision in single operation
- Document expected decimal bases for all rate/exchange calculations

### Parameter Validation
- Ensure parameters used in checks match parameters used in execution
- Example: if checking `availableWithdrawLimit(strategiesA)`, execute with same `strategiesA`
- Validate flags are consistent: if `useDefaultQueue == false`, don't use default queue

### Emergency Controls
- Implement `isShutdown` flag
- `shutdown()` function for emergency stops
- `notShutdown` modifier on critical functions

---

## Strategies (Yield Generation)

### Required Implementation
All strategies MUST implement:
- `_deployFunds(uint256 amount)` - Deploy to yield source
- `_freeFunds(uint256 amount)` - Withdraw from yield source
- `_harvestAndReport()` returns `(uint256 profit, uint256 loss)` - Harvest and report

### Yield Donating Pattern
- ALL yield goes to beneficiary
- Track `baselineAssets` (principal)
- On harvest: if `currentBalance > baselineAssets`, profit = excess
- Transfer profit to beneficiary
- On deploy: `baselineAssets += amount`
- On free: `baselineAssets -= amount`

### Yield Skimming Pattern
- Retain baseline yield rate, donate excess
- Track: `baselineYieldBps` (e.g., 400 = 4% APY), `lastHarvestTimestamp`, `baselineAssets`
- Calculate expected baseline growth based on elapsed time
- If `currentBalance > expectedBaseline`, skim excess profit
- Keep baseline profit in strategy, donate excess
- Update `lastHarvestTimestamp` after harvest

### Protocol Integration Requirements
- Use protocol constants (addresses) as `constant` or `immutable`
- Implement `_getProtocolBalance()` to query actual balance
- Handle protocol-specific precision (e.g., RAY for DSR)
- Handle paused/reverted states gracefully

### Reward Token Handling
- Claim rewards from protocol distributor
- Swap to asset using DEX (Uniswap V3)
- ALWAYS use slippage protection (`amountOutMinimum`)
- Use oracle or TWAP for min-out calculation
- Return swapped amount as profit

### Emergency Controls
- Implement `isPaused` and `isShutdown` flags
- `pause()` / `unpause()` functions
- `shutdown()` withdraws all funds from protocol (irreversible)
- `notPaused` / `notShutdown` modifiers on deposit/mint

---

## Dragon Protocol (Safe Modules)

### Critical Security Warning
**MODULE DANGER**: Module functions execute arbitrary code through Safe with full permissions. Validate ALL inputs rigorously.

### Safe Module Pattern
- Store `address public immutable safe`
- `onlySafe` modifier checks `msg.sender == safe`
- Execute via `IAvatar(safe).execTransactionFromModule(to, value, data, operation)`
- Always check return value, revert if false

### Access Control Patterns

#### Allowlist/Blocklist
- Enum: `AccessMode { Allowlist, Blocklist, Open }`
- Allowlist: Only listed addresses can call
- Blocklist: All except listed addresses can call
- Open: Anyone can call
- **CRITICAL**: Prefer Allowlist for high-value operations

#### Passport System
- Track: `isActive`, `expiresAt`, `hasPermission` mapping
- Validate: passport active, not expired, has required permission
- Grant permissions via admin function

### Lockup Mechanism
- Track: `shares` locked, `unlockTimestamp`
- On deposit: Lock shares, set `unlockTimestamp = now + LOCKUP_PERIOD`
- On redeem: Check `now >= unlockTimestamp`, check sufficient unlocked shares
- Decrement locked shares after redemption
- Non-transferable: Block transfers via `_beforeTokenTransfer` (only mint/burn allowed)

### Rage Quit (Emergency Exit)
- Constant penalty: `RAGE_QUIT_PENALTY_BPS = 1000` (10%)
- Convert shares to assets
- Apply penalty: `netAssets = assets - (assets * penalty / MAX_BPS)`
- Burn shares, transfer penalty to treasury, transfer net to user

### Router-Adapter Pattern
- `mapping(bytes4 => address) public adapters` - Function selector → adapter
- Execute: Extract selector from calldata, lookup adapter, delegatecall
- Register: Only Safe can register new adapters
- **CRITICAL**: Adapters execute via delegatecall with full Safe context

### Batch Operations
- Accept array of: `target`, `value`, `data`, `operation` (0=Call, 1=DelegateCall)
- Execute all operations in loop
- Revert entire batch if any operation fails (atomic)

### Security Requirements
- ALL operations validate target against allowlist
- Implement rate limiting for value transfers
- Use multi-sig threshold for adapter registration
- Log all executions with indexed events
- Test with Safe deployment in fork environment

### Reentrancy in Module Calls
- Module calls through Safe can reenter
- Follow CEI pattern strictly
- Update state BEFORE calling `execTransactionFromModule`

### Access Control Layering
- Layer 1: Passport check (if using passports)
- Layer 2: Allowlist check
- Layer 3: Rate limit check
- Layer 4: Value limit check
- Multiple layers provide defense in depth

---

## Testing Requirements

### Test File Naming
- **Files**: `ContractName.t.sol`, `ContractNameIntegration.t.sol`, `ContractNameInvariants.t.sol`
- **Functions**: `test_scenario()`, `testFuzz_scenario(uint256 x)`, `test_RevertWhen_condition()`

### Unit Tests
- Test each function with valid inputs
- Test edge cases: zero values, max values, boundary conditions
- Test access control with `vm.prank()`
- Test expected reverts with custom errors
- Test events are emitted correctly
- Use assertion messages for all checks

### Critical Edge Cases to Test
- Re-initialization attempts (should revert)
- Operations with `totalAssets == 0` but `totalSupply > 0` (loss scenarios)
- Conversion symmetry: deposit amount → shares → assets should preserve value within rounding
- Share burns/transfers: verify conversion happens BEFORE state changes
- Time-based accrual with very small rates (test rounding to zero doesn't break accounting)
- Race conditions on time boundaries: cooldown periods, voting periods (off-by-one errors)
- Decimal mismatches: never compare values with different decimal bases
- Idle asset accounting: harvest/report must include both deployed and idle assets
- Reentrancy via strategy callbacks during deposits/withdrawals
- Loss dilution: new depositors shouldn't dilute losses meant for existing users
- Sandwich attacks on admin functions that change share price
- Direct asset transfers bypassing shares: verify `totalAssets` updated immediately
- Multi-step decimal conversions: test precision loss (e.g., 27→18→27)
- Parameter mismatches: what's checked vs what's executed (strategies array, flags)
- External protocol paused/reverted: operations must handle gracefully
- Accumulated state edge cases: `totalAssets + lossAmount == 0` not just `totalAssets == 0`
- Same asset multiple roles: if stake token == reward token, test privilege boundaries
- Unreported state exploitation: deposit into strategy with unreported losses
- Cross-chain timing: block-based logic behaves differently on different chains
- Underflow scenarios: `loss + fees > totalAssets` should not revert entire operation

### Fuzz Tests
- Bound inputs to valid ranges using `bound()`
- Test invariants hold across random inputs
- Avoid magic numbers - use named constants

### Invariant Tests
- Use Handler pattern to manage test state
- Track ghost variables for cumulative operations
- Target handler, not vault directly
- Test critical invariants: no loss of funds, accounting consistency

### Fork Tests
- Use mainnet fork for protocol integration tests
- Test with actual protocol contracts at specific blocks
- Use known token holders via `vm.prank()` for realistic scenarios
- Test harvest after time progression (`vm.warp`)
- Verify profit calculations
- Test emergency shutdown withdraws all funds

### Coverage
- Run `yarn coverage` before submitting PRs
- Check uncovered branches and add tests for critical paths
- View detailed reports with `yarn coverage:genhtml`
- Focus on security-critical functions (access control, asset handling, state transitions)

### Critical Anti-Patterns in Tests
1. ❌ **Mocking the system under test** - Never mock what you're testing, only dependencies
2. ❌ Not using `vm.prank()` for access control tests
3. ❌ Testing multiple unrelated things in one test
4. ❌ Using magic numbers instead of named constants
5. ❌ Skipping edge cases (0, max, boundary values)
6. ❌ Missing assertion messages
7. ❌ Not testing with different token decimals
8. ❌ Skipping mainnet fork tests for protocol integrations

**Rule**: If testing Contract X, deploy real Contract X. Only mock external contracts that X depends on.

---

## Domain-Specific Anti-Patterns

### Core Contracts
1. ❌ Wrong rounding direction in ERC-4626 conversions
2. ❌ Not validating strategy addresses before adding
3. ❌ Forgetting to update debt accounting after deploy/withdraw
4. ❌ Skipping emergency shutdown mechanisms
5. ❌ Hardcoding fee recipients instead of making them configurable
6. ❌ Missing re-initialization protection in `initialize()` functions
7. ❌ Asymmetric `_convertToShares()` / `_convertToAssets()` implementations
8. ❌ Ignoring idle assets in `_harvestAndReport()` calculations
9. ❌ Burning/transferring shares before converting to assets (convert first!)
10. ❌ Comparing exchange rates with mismatched decimals
11. ❌ Using `transferFrom()` when `from == address(this)` (use `transfer()`)
12. ❌ Updating debt after external calls instead of before
13. ❌ Applying fee configuration changes retroactively to earned fees
14. ❌ Not updating `totalAssets` when assets transferred directly (bypassing shares)
15. ❌ Multi-step decimal conversions losing precision (27→18→27)
16. ❌ Parameters for checks differ from parameters for execution
17. ❌ Operations failing when external protocols pause (no graceful fallback)
18. ❌ Zero checks ignoring accumulated state (`totalAssets == 0` but `lossAmount > 0`)
19. ❌ Same asset as stake and reward without privilege isolation
20. ❌ Allowing operations on unreported losses (report before allowing new deposits)
21. ❌ No underflow protection when `loss + fees > totalAssets`

### Strategies
1. ❌ Skipping slippage protection on swaps
2. ❌ Not tracking baseline assets correctly
3. ❌ Forgetting to update timestamps in harvest
4. ❌ Hardcoding protocol addresses (use immutables with comments)
5. ❌ Skipping emergency shutdown mechanism
6. ❌ Not handling different token decimals
7. ❌ Assuming protocol solvency (always verify actual balances)

### Dragon Protocol
1. ❌ Using blocklist instead of allowlist for critical operations
2. ❌ Skipping rate limiting on high-value operations
3. ❌ Not validating operation targets against allowlist
4. ❌ Forgetting reentrancy protection (module calls can reenter)
5. ❌ Allowing adapter registration without multi-sig approval
6. ❌ Not implementing emergency pause/shutdown
