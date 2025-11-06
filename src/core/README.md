# BaseStrategies & TokenizedStrategies

## Product Vision & Motivation

**Vision:** Create defipunk funding pools that aggregate and safeguard user principal to yield and automatically donates profits to public goods and causes. Vaults funtion kind of like Kickstarter but with continuous yield generation instead of one-time contributions.

**Principal Protection + Automatic Yield Routing + Trust Minimization + Time-Delayed Changes + Proportional Distribution = Defipunk Funding Pools**

**Core Motivation:**
- **Primary Use Case:** Function like Kickstarter but with continuous yield generation instead of one-time contributions - enabling collective funding of public goods through pooled capital that generates continuous donations while preserving user principal
- **Extended Applications:** Automate treasury management, subscription models, and any scenario requiring automatic yield distribution
- **Trust Minimization:** Eliminate counterparty risk through mathematical guarantees, time-delayed changes, and transparent fund routing
- **Capital Efficiency:** Preserve principal while generating continuous cash flows for designated purposes, creating sustainable funding models

## Strategy Variants

The system provides two specialized implementations optimized for different yield generation patterns:

#### YieldDonatingTokenizedStrategy
- **Use Case:** Traditional yield strategies with discrete harvest cycles (DeFi protocols, liquidity mining, lending)
- **Mechanism:** Mints new shares to dragon router equivalent to profit generated since last report
- **Implementation:** Overrides `report()` to call `harvestAndReport()` and mint profit-based shares
- **Loss Protection:** Burns dragon router shares to absorb losses before affecting user principal if flag is enabled
- **Optimal For:** Strategies where totalAssets can be precisely calculated and profits are harvested periodically

##### Loss Tracking Mechanism

**Storage Variables:**
- `lossAmount` (uint256): Accumulated losses to offset against future profits
- `enableBurning` (bool): Whether to burn shares from dragon router during loss protection

**Loss Handling Process:**
1. When losses occur, the system first attempts to burn dragon router shares to cover the loss
2. Any remaining loss that cannot be covered by burning is tracked in `S.lossAmount`
3. Future profits first offset tracked losses before minting new shares to dragon router

**Share Burning Logic:**
- Converts loss to shares using `_convertToSharesWithLoss()` with rounding up
- Burns up to available dragon router shares
- Tracks any uncovered loss in `S.lossAmount`

**Profit Recovery:**
- If profit > lossAmount: Clears tracked losses and mints shares for net profit
- If profit ≤ lossAmount: Reduces tracked losses by profit amount, no shares minted

#### YieldSkimmingTokenizedStrategy  
- **Use Case:** Appreciating assets like liquid staking tokens (mETH, stETH) where value grows continuously
- **Mechanism:** Tracks value debt obligations to users and dragon router, skimming appreciation when total vault value exceeds total debt obligations
- **Implementation:** Uses value debt tracking system (`totalUserDebtInAssetValue`, `dragonRouterDebtInAssetValue`) with 1 share = 1 ETH value principle, tracks exchange rates in RAY precision (1e27)
- **Loss Protection:** Burns dragon router shares and reduces dragon debt during losses, includes comprehensive insolvency protection mechanisms
- **Optimal For:** Assets that appreciate in value over time with robust debt tracking and solvency protection

#### Implementation Differences

**Harvest Reporting:**
- YieldDonating: Returns `uint256 totalAssets` from `_harvestAndReport()`
- YieldSkimming: Returns `uint256 totalAssets` from `_harvestAndReport()` (via IERC4626 interface)

**Share Conversion:**
- YieldDonating: Standard ERC4626 conversion using total assets
- YieldSkimming: Dual-mode conversion - rate-based when solvent (`_currentRateRay()`), proportional distribution when insolvent, with 1 share = 1 ETH value principle 

**Exchange Rate Precision:**
- YieldDonating: No exchange rate tracking required
- YieldSkimming: RAY precision (1e27) exchange rate storage with WadRayMath library integration

**State Management:**
- YieldDonating: Standard ERC4626 state tracking + loss tracking via `S.lossAmount`
- YieldSkimming: Value debt tracking system (`totalUserDebtInAssetValue`, `dragonRouterDebtInAssetValue`) with insolvency protection and 1 share = 1 ETH value accounting

**Loss Protection:**
- YieldDonating: Burns dragon router shares when `enableBurning == true`, explicitly tracks uncovered losses in `S.lossAmount` for future offset
- YieldSkimming: Burns dragon router shares and reduces `dragonRouterDebtInAssetValue` during losses (if `enableBurning == true`), includes insolvency protection that blocks dragon operations and switches to proportional asset distribution

**Update Timing:**
- YieldDonating: Manual keeper-triggered reports at optimal intervals generate and harvest profit.
- YieldSkimming: Manual keeper-triggered reports at optimal intervals skim value appreciation above principal.

**Edge Cases & Considerations:**

**YieldDonating Strategies:**
1. **No Dragon Router Shares:** Full loss tracked in S.lossAmount
2. **Insufficient Shares:** Burns all available, tracks remainder
3. **Partial Recovery:** Reduces tracked loss, no share minting
4. **Full Recovery:** Clears tracked loss, mints net profit shares
5. **Multiple Cycles:** Accumulates losses, offsets with profits over time

**YieldSkimming Strategies:**
1. **Value Debt Tracking:** Maintains separate debt obligations for users (`totalUserDebtInAssetValue`) and dragon router (`dragonRouterDebtInAssetValue`)
2. **Insolvency Protection:** Blocks deposits/mints when vault cannot cover total debt obligations, prevents dragon operations during insolvency
3. **Loss Handling:** Burns dragon router shares and reduces `dragonRouterDebtInAssetValue`, remaining losses trigger insolvency mode with proportional asset distribution
4. **Share Value System:** 1 share = 1 ETH value (or underlying asset) principle ensures consistent debt tracking regardless of exchange rate fluctuations
5. **Transfer Controls:** Dragon router cannot transfer to itself, debt rebalancing occurs on dragon transfers, insolvency blocks dragon transfers
6. **Dual Conversion Modes:** Rate-based conversion when solvent, proportional distribution when insolvent

## Trust Minimization

#### Fee Removal
- Eliminates protocol fee extraction at the strategy level
- No management fees or performance fees charged to users at the strategy level
- Direct, defipunk, yield flow to dragon router without intermediaries 

#### Dragon Router Protection
- 14-day cooldown period for any dragon router changes
- Two-step process: initiate change → wait cooldown → finalize
- Management can cancel pending changes during cooldown
- Users have advance notice and exit window

#### Reduced Trust Requirements
- Remains composable with other 4626 vaults
- Transparent donation destination with change protection
- Yield flows directly to stated destination
- Distribution mechanics up to implementation address (see /mechanisms)

#### User Protection
- `PendingDragonRouterChange` event provides early warning
- Time to withdraw if disagreeing with new destination
- Cannot be changed instantly or without notice
- Preserves user agency in donation decisions

#### Loss Protection & Risk Distribution
- User principal protected through dragon router share burning when `enableBurning = true`
- Dragon router bears first loss through automated share burning mechanism
- YieldDonating: Uncovered losses tracked transparently in `S.lossAmount` for future offset
- YieldSkimming: Implicit recovery tracking - burns available shares, socializes remaining loss, automatically recovers through exchange rate appreciation
- Strategist responsible for ensuring dragon router compatibility with share burning


## Security Model and Trust Assumptions

### Trusted Parties

The following actors are considered **trusted** in the security model:

1. **Management**: Strategy management has administrative control and is assumed to act in good faith. Management can:
   - Modify health check parameters and disable health checks when necessary
   - Update keeper and emergency admin addresses
   - Initiate dragon router changes (subject to 14-day cooldown)

2. **Keepers**: Automated or manual actors responsible for calling `report()` functions. Keepers are trusted to:
   - Call reports at appropriate intervals
   - Not engage in MEV attacks or manipulation
   - Operate in the best interest of the strategy

3. **Emergency Admin**: Trusted party with emergency powers to:
   - Shutdown strategies in crisis situations
   - Execute emergency withdrawals when necessary

### Security Assumptions

The security model makes the following key assumptions:

1. **External Protocol Integrity**: The underlying protocols (eg. RocketPool) are assumed to operate correctly and not be compromised.

2. **Asset Contract Validity**: 
   - YieldDonating: The asset token contract is assumed to implement the expected ERC20 interface correctly
   - YieldSkimming: The asset must be a yield-bearing share token (like stETH, rETH) that represents underlying value through an exchange rate

3. **Exchange Rate Requirements (YieldSkimming)**:
   - The asset token must provide a reliable exchange rate to its underlying value
   - Value debt tracking system requires accurate exchange rate data for debt vs vault value comparisons
   - 1 share = 1 ETH value principle requires consistent exchange rate conversion to RAY precision (1e27)
   - Exchange rate data is assumed to be generally reliable, with healthcheck validation as defense-in-depth and insolvency protection as backup

4. **Dragon Router Beneficiary**: The dragon router address is assumed to be a legitimate beneficiary for donated yield.

5. **Loss Protection Mechanism**: The loss tracking and share burning mechanism assumes:
   - Dragon router shares represent risk capital that absorbs losses first
   - YieldDonating: Price-per-share calculations remain consistent through `_convertToSharesWithLoss`
   - YieldDonating: Users can recover original deposits underlying value after full recovery
   - YieldSkimming: Value debt tracking ensures accurate debt obligations, insolvency protection triggers proportional distribution when dragon buffer insufficient
   - YieldSkimming: Debt reduction mechanism explicitly tracks loss recovery through `dragonRouterDebtInAssetValue` adjustments
   - YieldSkimming: 1 share = 1 ETH value system ensures consistent debt accounting independent of exchange rate fluctuations
   - If share burning is enabled (`enableBurning = true`), it is the strategist's responsibility to ensure the dragon router can support having its shares burned

### Economic Invariants

**YieldDonating Strategies:**
The loss tracking mechanism maintains critical economic invariants:

1. **Total Value Conservation**: `totalAssets + trackedLosses = original deposits + net profits`
2. **User Principal Protection**: Users can recover original deposits after full loss recovery
3. **Dragon Router Risk**: Dragon router bears loss risk through share burning (if enabled)
4. **Fair Share Pricing**: Share conversions account for tracked losses to prevent dilution

**YieldSkimming Strategies:**
Value debt tracking and insolvency protection mechanism:

1. **Value Debt Tracking**: Total debt obligations tracked separately for users (`totalUserDebtInAssetValue`) and dragon router (`dragonRouterDebtInAssetValue`)
2. **Share Value Principle**: 1 share = 1 ETH value ensures consistent debt accounting independent of exchange rate fluctuations
3. **Solvency-Based Operations**: Vault solvency determined by comparing total vault value (assets × exchange rate) against total debt obligations
4. **Dual Conversion Modes**: Rate-based conversion when solvent, proportional distribution when insolvent
5. **Explicit Loss Recovery**: Dragon debt reduction during losses provides explicit recovery tracking vs implicit rate-based recovery
6. **Transfer Controls**: Dragon router transfers include debt rebalancing and insolvency protection to maintain debt accuracy

### Threat Model Boundaries

**In Scope Threats:**
- External attackers exploiting contract vulnerabilities
- Malicious users attempting to drain funds or manipulate calculations
- Oracle manipulation within reasonable bounds (see healthcheck mitigations)
- Precision attacks and edge case exploitation

**Out of Scope Threats:**
- Malicious management, keepers, or emergency admin actions
- Complete compromise of underlying yield source protocols (RocketPool)
- Governance attacks on trusted parties
- Social engineering or off-chain attacks

## Periphery Contracts

The system includes several utility contracts that extend strategy functionality:

#### BaseHealthCheck & BaseYieldSkimmingHealthCheck
- **Purpose:** Prevent unexpected profit/loss reporting through configurable bounds checking
- **Implementation:** Inherit from respective base contracts and override `_harvestAndReport()`
- **Configuration:** 
  - `profitLimitRatio`: Maximum acceptable profit as basis points (default 100% = 10,000 BPS)
  - `lossLimitRatio`: Maximum acceptable loss as basis points (default 0%)
  - `doHealthCheck`: Boolean flag to enable/disable checks (auto re-enables after bypass)
- **Behavior:** Transaction reverts if profit/loss exceeds configured limits, requiring manual intervention
- **Variants:** 
  - Standard version for BaseStrategy with totalAssets comparison
  - Specialized version for BaseYieldSkimmingStrategy with value debt tracking validation using total debt obligations vs current vault value (assets × exchange rate)

#### UniswapV3Swapper
- **Purpose:** Standardized Uniswap V3 integration for token swapping within strategies
- **Features:**
  - Exact input swaps (`_swapFrom`) and exact output swaps (`_swapTo`)
  - Automatic routing via base token (default WETH) for multi-hop swaps
  - Configurable minimum swap amounts to avoid dust transactions
  - Automatic allowance management with safety checks
- **Configuration:**
  - `uniFees`: Mapping of token pairs to their respective pool fees
  - `minAmountToSell`: Minimum threshold to prevent dust swaps
  - `router`: Uniswap V3 router address (customizable per chain)
  - `base`: Base token for routing (default WETH mainnet)
- **Usage:** Strategies inherit this contract and call `_setUniFees()` during initialization to configure trading pairs

#### IYieldSkimmingStrategy Interface
- **Purpose:** Standardized interface for yield skimming strategies with value debt tracking and insolvency monitoring
- **Features:**
  - Exchange rate querying (`getCurrentExchangeRate`, `getLastRateRay`, `getCurrentRateRay`, `decimalsOfExchangeRate`)
  - Value debt inspection (`getTotalValueDebtInAssetValue`)
  - Insolvency monitoring (`isVaultInsolvent`)
- **Implementation:** YieldSkimmingTokenizedStrategy implements this interface to provide transparency into debt obligations and vault health
- **Usage:** External integrations can query debt status and vault solvency for risk assessment and monitoring

## Functional Requirements
WLOG, I refer to yield donating and yield skimming strategies as 'donation strategies' as requirements generally apply to both with the exception of FR-2 for which the first two acceptance criteria do not apply to yield skimming variants.

#### FR-1: Strategy Deployment & Initialization
- **Requirement:** The system must enable permissionless deployment of donation-generating yield strategies where users pool capital to fund causes, with standardized initialization parameters including asset, management roles, and dragon router beneficiary configuration.
- **Implementation:** `BaseStrategy` constructor, `TokenizedStrategy.initialize()`, immutable proxy pattern setup
- **Acceptance Criteria:**
  - Strategy deploys with valid asset, name, management, keeper, emergency admin, and dragon router addresses
  - Storage initialization prevents double-initialization through `initialized` flag check
  - EIP-1967 proxy implementation slot correctly stores TokenizedStrategy address for Etherscan interface detection
  - All critical addresses including dragon router donation destination are validated as non-zero during initialization

#### FR-2: Asset Management & Yield Operations
- **Requirement:** Strategies must efficiently deploy pooled user capital to yield sources, enable withdrawals of principal while preserving donation flow, and report accurate yield accounting that separates user principal from donated profits.
- **Implementation:** `_deployFunds()`, `_freeFunds()`, `_harvestAndReport()` virtual functions, `deployFunds()`, `freeFunds()`, `harvestAndReport()` callbacks
- **Acceptance Criteria:**
  - Pooled assets are automatically deployed to yield sources upon user deposits via `deployFunds` callback if applicable to the strategy
  - User withdrawal requests trigger `freeFunds` callback to liquidate necessary positions while maintaining donation capacity if applicable to the strategy
  - Harvest reports provide accurate accounting that distinguishes between user principal and profits destined for dragon router
  - Loss scenarios are properly handled with configurable maxLoss parameters protecting user principal through healthchecks

#### FR-3: Role-Based Access Control
- **Requirement:** The system must implement comprehensive role-based permissions ensuring proper governance of donation strategies, with management transfer capabilities, keeper operations for yield harvesting, and emergency administration powers to protect pooled funds.
- **Implementation:** `onlyManagement`, `onlyKeepers`, `onlyEmergencyAuthorized` modifiers, `setPendingManagement()`, `acceptManagement()`, role setter functions
- **Acceptance Criteria:**
  - Management can set keeper and emergency admin addresses with zero-address validation for strategy governance
  - Management transfer requires two-step process (setPending + accept) to prevent accidental control transfers of donation flows
  - Keepers can call `report()` and `tend()` functions for strategy maintenance and donation generation
  - Emergency admin can shutdown strategies and perform emergency withdrawals to protect pooled user capital

#### FR-4: Dragon Router Donation Management
- **Requirement:** Strategies must support configurable dragon router beneficiary addresses ensuring donated yield flows to intended causes, with user protection through time-delayed changes preventing sudden redirection of donation streams.
- **Implementation:** `setDragonRouter()`, `finalizeDragonRouterChange()`, `cancelDragonRouterChange()`, 14-day cooldown mechanism
- **Acceptance Criteria:**
  - Dragon router changes require 14-day cooldown period before finalization to protect donor intent
  - Users receive `PendingDragonRouterChange` event notification with effective timestamp for donation transparency
  - Management can cancel pending changes during cooldown period if beneficiary change is inappropriate
  - Finalization only succeeds after cooldown elapsed with valid pending dragon router address

#### FR-5: Emergency Controls & Strategy Shutdown
- **Requirement:** The system must provide emergency mechanisms to halt donation strategy operations, prevent new deposits while protecting existing contributors, and enable fund recovery to safeguard pooled capital during crisis situations.
- **Implementation:** `shutdownStrategy()`, `emergencyWithdraw()`, `_emergencyWithdraw()` override, shutdown state checks
- **Acceptance Criteria:**
  - Strategy shutdown permanently prevents new deposits and mints while preserving existing donation commitments
  - Existing user withdrawals and redemptions continue functioning post-shutdown to protect contributor capital
  - Emergency withdrawals can only occur after shutdown by authorized roles to prevent fund misappropriation
  - Shutdown state is irreversible once activated to maintain contributor trust and donation integrity

#### FR-6: ERC4626 Vault Operations
- **Requirement:** Strategies must provide full ERC4626 compliance enabling users to contribute capital, track their principal, and withdraw funds while maintaining continuous donation flow to dragon router destinations.
- **Implementation:** `deposit()`, `mint()`, `withdraw()`, `redeem()` with maxLoss variants, preview functions, max functions
- **Acceptance Criteria:**
  - All ERC4626 core functions operate correctly with proper share/asset conversions maintaining separation between user principal and donated yield
  - MaxLoss parameters enable users to specify acceptable loss tolerance for withdrawals protecting their contributed capital
  - Preview functions accurately simulate transaction outcomes without affecting donation accounting or state changes
  - Max functions respect strategy-specific deposit/withdrawal limits and shutdown states while preserving donation mechanism integrity

#### FR-7: Loss Tracking & Principal Protection (YieldDonating Strategies)
- **Requirement:** YieldDonating strategies must protect user principal during loss events by burning dragon router shares first, tracking uncovered losses for future offset, and ensuring fair recovery distribution when profits return.
- **Implementation:** `_handleDragonLossProtection()`, `S.lossAmount` storage, `_convertToSharesWithLoss()`, share burning mechanism
- **Acceptance Criteria:**
  - When losses occur with `enableBurning = true`, dragon router shares are burned up to available balance to cover losses
  - Uncovered losses are tracked in `S.lossAmount` and offset against future profits before new share minting
  - Share conversions during loss periods use `_convertToSharesWithLoss()` to maintain fair pricing
  - Recovery follows priority: offset tracked losses first, then mint shares for net profit to dragon router
  - If `enableBurning = false`, all losses are tracked without share burning
  - Strategist must ensure dragon router implementation supports share burning when enabling this feature
- **Note:** YieldSkimming strategies use value debt tracking with insolvency protection - they burn available dragon router shares and reduce dragon debt, trigger insolvency mode for proportional distribution when dragon buffer insufficient, and recover through explicit debt tracking vs rate appreciation

#### FR-8: Value Debt Tracking & Insolvency Protection (YieldSkimming Strategies)
- **Requirement:** YieldSkimming strategies must maintain accurate debt obligations to users and dragon router, provide insolvency protection during losses, and ensure fair value distribution through dual conversion modes.
- **Implementation:** `totalUserDebtInAssetValue`, `dragonRouterDebtInAssetValue` storage, `_isVaultInsolvent()`, `_requireVaultSolvency()`, `_requireDragonSolvency()`, debt rebalancing on transfers
- **Acceptance Criteria:**
  - Value debt tracking maintains separate obligations for users and dragon router using 1 share = 1 ETH value principle
  - Insolvency protection blocks deposits/mints when total vault value cannot cover total debt obligations
  - Dragon router operations blocked during insolvency to protect user principal
  - Share conversions switch to proportional distribution mode during insolvency
  - Dragon router transfers include debt rebalancing to maintain accurate debt tracking
  - Loss protection burns dragon shares and reduces `dragonRouterDebtInAssetValue` providing explicit recovery tracking
  - Transfer controls prevent dragon router self-transfers and ensure solvency-aware operations

## User Lifecycle Documentation

#### Phase 1: Strategy Discovery & Impact Assessment
**User Story:** "As a contributor, I want to discover and analyze available funding pools so that I can make informed decisions about where to allocate my capital for maximum public good impact."

**Flow:**
1. User browses available strategies through frontend or direct contract queries
2. System displays strategy metadata including asset, projected donation rates, beneficiary organizations, and risk metrics
3. User analyzes strategy implementation and historical donation performance
4. User evaluates cause alignment and social impact effectiveness
5. User decides to proceed with contribution or continue research

**NOTE:**
- Dragon router changes create uncertainty about future beneficiary destinations but require a 14 day delay.

#### Phase 2: Initial Contribution & Pool Entry
**User Story:** "As a backer, I want to easily contribute assets to funding pools so that I can start generating continuous donations to causes I support while preserving my principal."

**Flow:**
1. User approves asset spending for strategy contract
2. User calls `deposit(assets, receiver)` or `mint(shares, receiver)` function
3. System validates deposit limits, strategy operational status, and vault solvency (YieldSkimming only)
4. System transfers assets, deploys to yield source via `deployFunds` callback, updates value debt tracking (YieldSkimming only)
5. System mints proportional shares and emits `Deposit` event

**NOTE:**
- Deposit limits may reject transactions due to underlying yield source state
- YieldSkimming strategies block deposits during vault insolvency to protect user principal
- Dragon router cannot deposit into YieldSkimming strategies

#### Phase 3: Donation Generation & Impact Monitoring
**User Story:** "As a funding pool participant, I want to monitor my principal preservation and the donation impact being generated so that I can make informed decisions about continued participation."

**Flow:**
1. User queries current share balance and principal value via `balanceOf` and `convertToAssets`
2. System displays real-time donation metrics and strategy health indicators
3. User monitors dragon router activities and public goods funding distributions
4. Keeper calls `report()` to harvest profits and update donation accounting
5. User observes preserved principal value and tracks donated yield to beneficiaries

**NOTE:**
- Strategy performance depends on external keeper activity for timely reporting
- Keeper should always use MEV protected mem pools to broadcast transactions safely

#### Phase 4: Principal Withdrawal & Exit Strategy
**User Story:** "As a funding pool participant, I want to withdraw my principal efficiently so that I can access my preserved capital when needed while understanding the impact on ongoing donations."

**Flow:**
1. User determines withdrawal amount and acceptable loss tolerance
2. User calls `withdraw(assets, receiver, owner, maxLoss)` or `redeem` variant
3. System checks withdrawal limits, validates maxLoss parameters, and ensures dragon solvency (YieldSkimming only)
4. System frees assets from yield source via `freeFunds` callback, updates value debt tracking (YieldSkimming only)
5. System transfers freed assets to receiver and burns corresponding shares

**NOTE:**
- Withdrawal timing depends on yield source liquidity and may incur losses without slippage checks
- YieldSkimming strategies prevent dragon router withdrawals during vault insolvency
- YieldSkimming strategies use proportional distribution during insolvency rather than full principal recovery