# STEAMM Developer Integration Guide

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [Pool Types](#pool-types)
5. [Creating Pools](#creating-pools)
6. [Liquidity Operations](#liquidity-operations)
7. [Swapping](#swapping)
8. [Suilend Integration](#suilend-integration)
9. [Advanced Usage](#advanced-usage)
10. [Error Handling](#error-handling)
11. [Practical Integration](#practical-integration)
12. [Code Examples](#code-examples)
13. [Reference](#reference)

## Overview

STEAMM is a next-generation Automated Market Maker (AMM) protocol on Sui that maximizes capital efficiency through:

- **Modular Quoter System**: Support for multiple AMM types (Constant Product, Oracle-based, Stable)
- **Liquidity Reutilization**: Optional integration with Suilend lending markets for yield generation
- **Shared Liquidity Model**: Banks aggregate liquidity across pools for improved efficiency
- **Yield-bearing LP Tokens**: LPs earn both trading fees and lending yields

### Key Benefits for Developers

1. **Flexible Integration**: All pools use banks for liquidity management, with optional yield farming via Suilend
2. **Capital Efficiency**: Up to 80% of idle liquidity can earn lending yields (when enabled)
3. **Multiple AMM Types**: Constant product, oracle-based, and stable coin AMMs
4. **Composable Design**: Easy integration with existing DeFi protocols

## Architecture

### Core Components

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│    Registry     │    │      Pool       │    │      Bank       │
│   (Global)      │◄───┤   (Per Pair)    │◄───┤  (Per Token)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                ▲                        ▲
                                │                        │
                       ┌─────────────────┐    ┌─────────────────┐
                       │     Quoter      │    │  Suilend Market │
                       │  (AMM Logic)    │    │   (Optional)    │
                       └─────────────────┘    └─────────────────┘
```

- **Registry**: Global tracker of all pools and banks
- **Pool**: Core AMM logic with modular quoter system
- **Bank**: Manages liquidity and optional Suilend integration
- **Quoter**: Pluggable AMM algorithms (CPMM, Oracle, Stable)

### Token Flow

```
User Tokens (USDC, SUI)
    ↓ (mint_btoken)
bTokens (bUSDC, bSUI)
    ↓ (Pool operations)
LP Tokens
    ↓ (Optionally deployed to)
Suilend cTokens (earning yield)
```

## Quick Start

### Dependencies

Add to your `Move.toml`:

```toml
[dependencies]
steamm = { git = "https://github.com/solendprotocol/steamm.git", subdir = "contracts/steamm", rev = "main" }
steamm_scripts = { git = "https://github.com/solendprotocol/steamm.git", subdir = "contracts/steamm_scripts", rev = "main" }
suilend = { git = "https://github.com/solendprotocol/suilend.git", subdir = "contracts/suilend", rev = "main" }
oracles = { git = "https://github.com/solendprotocol/suilend.git", subdir = "contracts/oracles", rev = "main" }
```

### Basic Pool Creation

**Important:** All pools require banks and use bToken types. Banks must be created first.

```move
use steamm::{cpmm, bank};
use steamm::registry::Registry;
use suilend::lending_market::LendingMarket;

// Create a CPMM pool (banks required)
public fun create_basic_pool<P, A, B, BTokenA, BTokenB, LpType: drop>(
    registry: &mut Registry,
    lending_market: &LendingMarket<P>,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_b_a: &mut CoinMetadata<BTokenA>,
    meta_b_b: &mut CoinMetadata<BTokenB>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    b_a_treasury: TreasuryCap<BTokenA>,
    b_b_treasury: TreasuryCap<BTokenB>,
    swap_fee_bps: u64,  // e.g., 30 = 0.3%
    offset: u64,        // Usually 0 for standard pools
    ctx: &mut TxContext,
): (Pool<BTokenA, BTokenB, CpQuoter, LpType>, ID, ID) {
    // Create banks for both tokens
    let bank_a_id = bank::create_bank_and_share<P, A, BTokenA>(
        registry, meta_a, meta_b_a, b_a_treasury, lending_market, ctx
    );

    let bank_b_id = bank::create_bank_and_share<P, B, BTokenB>(
        registry, meta_b, meta_b_b, b_b_treasury, lending_market, ctx
    );

    // Create pool using bToken types
    let pool = cpmm::new<BTokenA, BTokenB, LpType>(
        registry,
        swap_fee_bps,
        offset,
        meta_b_a,    // bToken A metadata
        meta_b_b,    // bToken B metadata
        meta_lp,
        lp_treasury,
        ctx,
    );

    (pool, bank_a_id, bank_b_id)
}
```

### Basic Liquidity Operations

**Note:** Use `pool_script_v2` functions for all pools as they handle the required bank operations:

```move
use steamm_scripts::pool_script_v2;

// Add liquidity using banks (recommended for all pools)
public fun add_liquidity<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LpType> {
    pool_script_v2::deposit_liquidity(
        pool, bank_a, bank_b, lending_market,
        coin_a, coin_b, max_a, max_b, clock, ctx
    )
}
```

## Pool Types

STEAMM supports three main quoter types:

### 1. Constant Product AMM (CPMM)

Best for: General trading pairs, volatile assets

**Requirements:** Banks and bTokens are required for all tokens. You only need to create banks for tokens that don't already have them.

```move
// Formula: (x + offset) * y = k
// Note: Pool uses bToken types, not underlying token types
use steamm::cpmm::CpQuoter;

let pool = cpmm::new<BTokenA, BTokenB, LpToken>(
    registry,
    30,    // 0.3% fee
    0,     // No offset
    meta_b_a,   // bToken A metadata
    meta_b_b,   // bToken B metadata
    meta_lp,
    lp_treasury,
    ctx,
);
```

**Features:**

- Classic x\*y=k formula with optional offset
- Suitable for most token pairs
- Predictable slippage curves
- Requires banks for liquidity management

### 2. Oracle AMM (OMM)

Best for: Stablecoin pairs, reduced impermanent loss

```move
use steamm::omm_v2::OracleQuoterV2;
use oracles::oracles::OracleRegistry;

// Complete Oracle AMM creation - requires all parameters
let pool = omm_v2::new<P, A, B, B_A, B_B, LpType>(
    registry,
    lending_market,
    meta_a,           // Underlying token A metadata
    meta_b,           // Underlying token B metadata
    meta_b_a,         // bToken A metadata
    meta_b_b,         // bToken B metadata
    meta_lp,          // LP token metadata
    lp_treasury,      // LP token treasury cap
    oracle_registry,  // Oracle registry instance
    oracle_index_a,   // Oracle index for token A
    oracle_index_b,   // Oracle index for token B
    amplifier,        // Higher = more stable pricing (e.g., 10-1000)
    swap_fee_bps,     // Swap fee in basis points
    ctx,
);
```

**Features:**

- Uses external price feeds
- Better for correlated assets
- Requires Suilend integration (bTokens only)

### 3. Stable AMM (Oracle Quoter V2 with High Amplifier)

Best for: Highly correlated assets (USDC/USDT)

**Current Implementation:** Oracle Quoter V2 with amplifier A = 1000

**Features:**

- Uses Curve StableSwap invariant with oracle prices
- High amplifier (A = 1000) provides minimal slippage for stable pairs
- Combines oracle price feeds with stable swap mathematics
- Dynamic amplifier adjustment based on pool balance ratios
- Requires Suilend integration (bTokens only)

```move
// Oracle Quoter V2 configured for stable pairs
let stable_pool = omm_v2::new<P, USDC, USDT, bUSDC, bUSDT, LP>(
    registry,
    lending_market,
    usdc_metadata,
    usdt_metadata,
    busdc_metadata,
    busdt_metadata,
    lp_metadata,
    lp_treasury,
    oracle_registry,
    oracle_index_usdc, // Oracle index for USDC
    oracle_index_usdt, // Oracle index for USDT
    amplifier: 1000,   // High amplifier for stable pairs
    swap_fee_bps: 5,   // 0.05% swap fee
    ctx
);
```

## Creating Pools

### Bank Creation Methods

Before creating pools, you need to create banks for any tokens that don't already have them. STEAMM provides two methods for bank creation:

#### Method 1: Simple Bank Creation (Recommended for most cases)

```move
use steamm::bank;

// Create and share a bank in one call
let bank_id: ID = bank::create_bank_and_share<P, USDC, bUSDC>(
    registry,
    &meta_usdc,
    &mut meta_b_usdc,
    b_usdc_treasury,
    lending_market,
    ctx,
);

// The bank is automatically shared and can be accessed via the registry
```

#### Method 2: Bank Builder Pattern (For advanced setup)

The `create_bank()` function is package-only, so external protocols must use the builder pattern:

```move
use steamm::bank;

// Step 1: Create a bank builder
let mut builder = bank::new<P, USDC, bUSDC>(
    registry,
    &meta_usdc,
    &mut meta_b_usdc,
    b_usdc_treasury,
    lending_market,
    ctx,
);

// Step 2: Optionally perform setup operations on the bank before sharing
// (Advanced use cases - most developers can skip this)
let bank_mut = builder.bank_mut();
// ... perform any pre-sharing setup ...

// Step 3: Share the bank and get its ID
let bank_id: ID = builder.build();
```

**When to use each method:**

- **Use `create_bank_and_share()`** for standard bank creation
- **Use the builder pattern** only when you need to configure the bank before it becomes shared (advanced use cases)

### Fee Tiers

STEAMM supports multiple fee tiers to accommodate different asset pairs and trading scenarios. All fees are specified in basis points (bps), where 100 bps = 1%.

**Available Fee Tiers:**

| Fee (bps) | Fee (%) | Recommended Use Case                 |
| --------- | ------- | ------------------------------------ |
| 1         | 0.01%   | Ultra-stable pairs (e.g., USDC/USDT) |
| 5         | 0.05%   | Stable pairs with high correlation   |
| 10        | 0.10%   | Correlated assets                    |
| 20        | 0.20%   | Standard stable pairs                |
| 25        | 0.25%   | Slightly volatile pairs              |
| 30        | 0.30%   | Standard trading pairs (most common) |
| 50        | 0.50%   | Volatile asset pairs                 |
| 100       | 1.00%   | High volatility pairs                |
| 200       | 2.00%   | Very volatile or exotic pairs        |
| 1000      | 10.00%  | Extremely high risk pairs            |
| 5000      | 50.00%  | Experimental or very high risk       |

**Fee Selection Guidelines:**

- **Stable pairs (USDC/USDT):** Use 1-10 bps for minimal slippage
- **Standard pairs (ETH/USDC):** Use 30 bps (0.3%) as the default
- **Volatile pairs:** Use 50-100 bps to compensate for higher risk
- **Exotic pairs:** Use higher fees (200+ bps) for increased LP protection

### Pool Creation with Existing Banks

When creating pools for tokens that already have banks (like SUI):

```move
module my_protocol::usdc_sui_pool {
    use steamm::cpmm;
    use steamm::pool::Pool;
    use steamm::registry::Registry;

    public struct MyLpToken has drop {}
    public struct MyBTokenUSDC has drop {}

    public fun create_usdc_sui_pool(
        registry: &mut Registry,
        lending_market: &LendingMarket<P>,
        ctx: &mut TxContext,
    ): (Pool<MyBTokenUSDC, bSUI, CpQuoter, MyLpToken>, ID) {
        // Setup coin metadata (implementation details omitted)
        let (meta_usdc, meta_sui, mut meta_lp, mut meta_b_usdc, meta_b_sui,
             lp_treasury, b_usdc_treasury) = setup_coin_metadata(ctx);

        // Create bank only for USDC since SUI bank already exists
        let bank_usdc_id = bank::create_bank_and_share<P, USDC, MyBTokenUSDC>(
            registry,
            &meta_usdc,
            &mut meta_b_usdc,
            b_usdc_treasury,
            lending_market,
            ctx,
        );

        // Create pool using bToken types
        let pool = cpmm::new<MyBTokenUSDC, bSUI, MyLpToken>(
            registry,
            30,     // 0.3% swap fee
            0,      // No offset
            &meta_b_usdc,   // bToken USDC metadata
            &meta_b_sui,    // Existing bToken SUI metadata
            &mut meta_lp,
            lp_treasury,
            ctx,
        );

        (pool, bank_usdc_id)
    }
}
```

### Advanced Pool with Suilend Integration

For yield-bearing pools that earn lending yields:

```move
module my_protocol::yield_amm {
    use steamm::bank;
    use steamm::cpmm;
    use suilend::lending_market::LendingMarket;

    public struct MyBTokenUSDC has drop {}
    public struct MyBTokenSUI has drop {}
    public struct MyLpToken has drop {}

    public fun create_yield_pool<P>(
        registry: &mut Registry,
        lending_market: &LendingMarket<P>,
        global_admin: &GlobalAdmin,
        ctx: &mut TxContext,
    ): (
        Pool<MyBTokenUSDC, MyBTokenSUI, CpQuoter, MyLpToken>,
        ID, // Bank USDC ID
        ID, // Bank SUI ID
    ) {
        // Setup metadata
        let (
            meta_usdc, meta_sui, mut meta_lp,
            mut meta_b_usdc, mut meta_b_sui,
            lp_treasury, b_usdc_treasury, b_sui_treasury
        ) = setup_all_metadata(ctx);

        // Create banks (they become shared objects)
        let bank_usdc_id = bank::create_bank_and_share<P, USDC, MyBTokenUSDC>(
            registry,
            &meta_usdc,
            &mut meta_b_usdc,
            b_usdc_treasury,
            lending_market,
            ctx,
        );

        let bank_sui_id = bank::create_bank_and_share<P, SUI, MyBTokenSUI>(
            registry,
            &meta_sui,
            &mut meta_b_sui,
            b_sui_treasury,
            lending_market,
            ctx,
        );

        // Banks are now shared objects and must be accessed via separate transactions
        // The bank IDs can be used to reference the banks later

        // Note: Lending initialization and pool creation would typically happen
        // in separate transactions since banks are shared objects

        // Create pool with bToken types
        let pool = cpmm::new<MyBTokenUSDC, MyBTokenSUI, MyLpToken>(
            registry,
            30,     // 0.3% swap fee
            0,      // No offset
            &meta_b_usdc,
            &meta_b_sui,
            &mut meta_lp,
            lp_treasury,
            ctx,
        );

        (pool, bank_usdc_id, bank_sui_id)
    }
}
```

## Liquidity Operations

### Adding Liquidity

All pools require banks and should use the script functions:

```move
use steamm_scripts::pool_script_v2;

public fun add_liquidity_with_yield<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LpType> {
    pool_script_v2::deposit_liquidity(
        pool, bank_a, bank_b, lending_market,
        coin_a, coin_b, max_a, max_b, clock, ctx
    )
}
```

### Removing Liquidity

All pools require banks and should use the script functions:

```move
public fun remove_liquidity_with_yield<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    lp_tokens: Coin<LpType>,
    min_a: u64,
    min_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    pool_script_v2::redeem_liquidity(
        pool, bank_a, bank_b, lending_market,
        lp_tokens, min_a, min_b, clock, ctx
    )
}
```

## Swapping

### Understanding STEAMM's Swap Model

STEAMM uses a **direct swap model** where swaps are executed immediately:

1. **Quote**: Get a quote for the intended swap amount
2. **Provision**: Banks automatically provision necessary liquidity from Suilend (for yield pools)
3. **Swap**: Perform the swap in a single transaction
4. **Rebalance**: Banks automatically rebalance utilization as needed

### Pool Swaps

**Always use `pool_script_v2` for all pools** - it handles the required bank operations and bToken conversions:

```move
use steamm_scripts::pool_script_v2;

public fun swap_cpmm_with_yield<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    pool_script_v2::cpmm_swap(
        pool, bank_a, bank_b, lending_market,
        coin_a, coin_b, a2b, amount_in, min_amount_out,
        clock, ctx
    );
}
```

### Oracle Pool Swaps

```move
public fun swap_oracle<P, A, B, B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    bank_a: &mut Bank<P, A, B_A>,
    bank_b: &mut Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_a: OraclePriceUpdate,
    oracle_price_b: OraclePriceUpdate,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    pool_script_v2::omm_v2_swap(
        pool, bank_a, bank_b, lending_market,
        oracle_price_a, oracle_price_b,
        coin_a, coin_b, a2b, amount_in, min_amount_out,
        clock, ctx
    );
}
```

### Getting Quotes

**Always get quotes before executing swaps:**
**Important:** Quote functions return amounts in **bToken values**, not underlying token values. For pools without lending, bTokens have a 1:1 ratio with underlying tokens. For yield pools with active lending, the bToken:underlying ratio may differ due to accrued lending returns.

```move
// For all pools - RECOMMENDED (handles bank operations)
public fun get_yield_swap_quote<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    a2b: bool,
    amount_in: u64,          // In underlying token units
    clock: &Clock,
): SwapQuote {
    pool_script_v2::quote_cpmm_swap(
        pool, bank_a, bank_b, lending_market,
        a2b, amount_in, clock   // Returns bToken amounts
    )
}

// Converting between bToken and underlying token values
public fun btoken_to_underlying<P, T, BT>(
    bank: &Bank<P, T, BT>,
    lending_market: &LendingMarket<P>,
    btoken_amount: u64,
): u64 {
    bank.redeem_shares_for_amount(lending_market, btoken_amount)
}

public fun underlying_to_btoken<P, T, BT>(
    bank: &Bank<P, T, BT>,
    lending_market: &LendingMarket<P>,
    underlying_amount: u64,
): u64 {
    bank.amount_to_shares(lending_market, underlying_amount)
}
```

### Script Versions: When to Use Which

The choice between script versions depends on gas costs and lending market access requirements:

- **`pool_script_v2`**: **RECOMMENDED** - Uses immutable `&LendingMarket`

  - **Lower gas costs** due to immutable reference
  - Suitable for most swap operations
  - Cannot perform preemptive rebalancing

- **`pool_script`**: Uses mutable `&mut LendingMarket`

  - **Higher gas costs** due to mutable reference
  - Required when large withdrawals need preemptive rebalancing
  - Allows modification of lending market state
  - Use only when `pool_script_v2` fails due to rebalancing needs

- **Direct pool calls**: Not recommended - use script functions instead

**When to use `pool_script`:**

- Large withdrawal operations that trigger rebalancing requirements
- When you encounter errors related to insufficient liquidity that require preemptive rebalancing
- As a fallback when `pool_script_v2` operations fail

**Default recommendation:** Always try `pool_script_v2` first for better gas efficiency, fallback to `pool_script` only when necessary.

## Suilend Integration

### Understanding Banks

Banks are the key component that enables Suilend integration:

- **Purpose**: Aggregate liquidity from multiple pools
- **Yield Generation**: Deploy idle liquidity to Suilend for lending yields
- **bTokens**: Yield-bearing representations of underlying tokens (note: singular "btoken")
- **Utilization Management**: Maintain liquidity buffers for instant swaps

### Bank Lifecycle

1. **Creation**: `bank::create_bank_and_share()` or builder pattern - Creates bank for a token type
2. **Lending Setup**: `bank.init_lending()` - Enables Suilend integration (admin-gated, only Suilend can toggle)
3. **Operation**: Automatic yield generation and liquidity management
4. **Rebalancing**: Periodic adjustment of Suilend exposure

### Working with bTokens

```move
// Convert underlying tokens to bTokens
let btokens = bank.mint_btoken(
    lending_market,
    &mut coin,
    amount,
    clock,
    ctx
);

// Convert bTokens back to underlying tokens
let underlying = bank.burn_btoken(
    lending_market,
    &mut btokens,
    btoken_amount,
    clock,
    ctx
);
```

### Utilization Parameters

**Admin Access Required**: `init_lending` is admin-gated and can only be called by Suilend administrators.

```move
// Configure how much liquidity gets deployed to Suilend
bank.init_lending(
    global_admin,        // Must be Suilend admin account
    lending_market,
    8000,  // target_utilization_bps: 80% deployed to Suilend
    1000,  // utilization_buffer_bps: 10% buffer (70-90% range)
    ctx,
);
```

**Target Utilization**: Percentage of bank funds deployed to Suilend  
**Buffer**: Allowed deviation before rebalancing occurs

### Benefits of Suilend Integration

1. **Additional Yield**: LPs earn trading fees + lending yields
2. **Capital Efficiency**: Up to 80% of idle liquidity generates yield
3. **Shared Liquidity**: Multiple pools share deeper liquidity
4. **Automatic Management**: Protocol handles Suilend interactions

### When to Enable Suilend Lending

All pools use banks, but lending integration is optional and requires admin permission:

**Enable Lending Integration When:**

- You want maximum yield for LPs
- Pool expects significant idle periods
- Working with established tokens (USDC, SUI, etc.)
- Token has an active Suilend market

**Keep Lending Disabled When:**

- Working with new/experimental tokens
- Token doesn't have a Suilend market
- Minimizing yield complexity
- Rapid prototyping phases

## Error Handling

### Common Error Codes

| Error                    | Code | Description                          | Solution                                  |
| ------------------------ | ---- | ------------------------------------ | ----------------------------------------- |
| `ESlippageExceeded`      | 0    | Output below minimum                 | Increase slippage tolerance               |
| `EInsufficientBankFunds` | 9    | Bank liquidity too low               | Wait for rebalancing or provide liquidity |
| `ELendingAlreadyActive`  | 5    | Bank already has lending initialized | Check bank state before init              |
| `EInvalidBTokenDecimals` | 1    | bToken must have 9 decimals          | Fix token metadata                        |
| `EInvalidLpDecimals`     | 0    | LP token must have 9 decimals        | Fix LP token metadata                     |
| `EEmptyBank`             | 1    | Bank has no funds                    | Add liquidity first                       |
| `EInvariantViolation`    | 0    | CPMM invariant broken                | Check swap parameters                     |

### Error Handling Patterns

```move
// Always check for sufficient liquidity before large operations
public fun safe_swap_with_check<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    amount_in: u64,
    a2b: bool,
    clock: &Clock,
) {
    // Get quote first to check if swap is possible
    let quote = pool_script_v2::quote_cpmm_swap(
        pool, bank_a, bank_b, lending_market,
        a2b, amount_in, clock
    );

    // Check if we got a reasonable output
    assert!(quote.amount_out() > 0, EInsufficientLiquidity);

    // Proceed with actual swap...
}

// Check bank utilization before large operations
public fun check_bank_health<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): bool {
    bank.needs_rebalance(lending_market, clock).needs_rebalance()
}
```

## Practical Integration

### Integrating STEAMM into Your DeFi Protocol

#### 1. Simple Swap Integration

```move
module my_protocol::simple_swaps {
    use steamm_scripts::pool_script_v2;

    public fun execute_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
        pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
        bank_a: &mut Bank<P, A, BTokenA>,
        bank_b: &mut Bank<P, B, BTokenB>,
        lending_market: &LendingMarket<P>,
        coin_in: Coin<A>,
        min_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<B> {
        let amount_in = coin_in.value();
        let mut coin_a = coin_in;
        let mut coin_b = coin::zero<B>(ctx);

        pool_script_v2::cpmm_swap(
            pool, bank_a, bank_b, lending_market,
            &mut coin_a, &mut coin_b,
            true, amount_in, min_out,
            clock, ctx
        );

        // Clean up remaining input coin
        if (coin_a.value() > 0) {
            transfer::public_transfer(coin_a, ctx.sender());
        } else {
            coin::destroy_zero(coin_a);
        };

        coin_b
    }
}
```

#### 2. Yield Farming Integration

```move
module my_protocol::yield_farm {
    use steamm_scripts::pool_script_v2;

    public struct FarmPosition<phantom LpType> has store {
        lp_tokens: Balance<LpType>,
        deposited_at: u64,
        rewards_earned: u64,
    }

    public fun stake_in_farm<P, A, B, BTokenA, BTokenB, LpType: drop>(
        pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
        bank_a: &mut Bank<P, A, BTokenA>,
        bank_b: &mut Bank<P, B, BTokenB>,
        lending_market: &LendingMarket<P>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): FarmPosition<LpType> {
        let mut coin_a = coin_a;
        let mut coin_b = coin_b;

        // Add liquidity to STEAMM pool
        let lp_tokens = pool_script_v2::deposit_liquidity(
            pool, bank_a, bank_b, lending_market,
            &mut coin_a, &mut coin_b,
            coin_a.value(), coin_b.value(),
            clock, ctx
        );

        // Handle any remaining coins
        if (coin_a.value() > 0) {
            transfer::public_transfer(coin_a, ctx.sender());
        } else {
            coin::destroy_zero(coin_a);
        };

        if (coin_b.value() > 0) {
            transfer::public_transfer(coin_b, ctx.sender());
        } else {
            coin::destroy_zero(coin_b);
        };

        FarmPosition {
            lp_tokens: lp_tokens.into_balance(),
            deposited_at: clock.timestamp_ms(),
            rewards_earned: 0,
        }
    }
}
```

#### 3. Arbitrage Bot Integration

```move
module my_protocol::arbitrage {
    use steamm_scripts::pool_script_v2;

    public fun execute_arbitrage<P, A, B, BTokenA, BTokenB, LpType: drop>(
        steamm_pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
        bank_a: &mut Bank<P, A, BTokenA>,
        bank_b: &mut Bank<P, B, BTokenB>,
        lending_market: &LendingMarket<P>,
        external_price: u64,  // Price from external source
        min_profit: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Get STEAMM price
        let test_amount = 1_000_000; // 1 token for price discovery
        let quote = pool_script_v2::quote_cpmm_swap(
            steamm_pool, bank_a, bank_b, lending_market,
            true, test_amount, clock
        );

        let steamm_price = (quote.amount_out() * 1_000_000) / test_amount;

        // Check for arbitrage opportunity
        if (steamm_price < external_price) {
            // Buy on STEAMM, sell elsewhere
            let profit_estimate = external_price - steamm_price;
            if (profit_estimate > min_profit) {
                // Execute arbitrage...
            }
        }
    }
}
```

## Advanced Usage

### Multi-Pool Routing

```move
public fun multi_hop_swap<P, A, B, C>(
    pool_ab: &mut Pool<A, B, CpQuoter, LpType1>,
    pool_bc: &mut Pool<B, C, CpQuoter, LpType2>,
    coin_a: &mut Coin<A>,
    amount_in: u64,
    min_amount_out: u64,
    ctx: &mut TxContext,
): Coin<C> {
    // Get intermediate quote
    let quote_ab = pool_ab.cpmm_quote_swap(amount_in, true);
    let amount_b = quote_ab.amount_out();

    // First swap: A -> B
    let mut coin_b = coin::zero<B>(ctx);
    pool_ab.cpmm_swap(coin_a, &mut coin_b, true, amount_in, 0, ctx);

    // Second swap: B -> C
    let mut coin_c = coin::zero<C>(ctx);
    pool_bc.cpmm_swap(&mut coin_b, &mut coin_c, true, amount_b, min_amount_out, ctx);

    // Clean up intermediate token
    coin::destroy_zero(coin_b);

    coin_c
}
```

### Fee Management and Revenue

```move
public fun collect_protocol_fees<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
) {
    // Fees are automatically moved to banks for distribution
    steamm::fee_crank::crank_fees(pool, bank_a, bank_b);
}

// Claim trading fees earned by the bank
public fun claim_trading_fees<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    registry: &Registry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    bank.claim_fees(lending_market, registry, clock, ctx);
}

// Claim lending rewards from Suilend
public fun claim_lending_rewards<P, T, BToken, RToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    registry: &Registry,
    reward_index: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    bank.claim_rewards<P, T, BToken, RToken>(
        lending_market, registry, reward_index, clock, ctx
    );
}
```

### Monitoring Pool Health

```move
public fun get_comprehensive_pool_info<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): PoolHealthInfo {
    let (reserve_a, reserve_b) = pool.balance_amounts();
    let lp_supply = pool.lp_supply_val();

    // Get bank utilizations
    let util_a = get_bank_utilization(bank_a, lending_market, clock);
    let util_b = get_bank_utilization(bank_b, lending_market, clock);

    // Check if rebalancing is needed
    let needs_rebalance_a = bank_a.needs_rebalance(lending_market, clock);
    let needs_rebalance_b = bank_b.needs_rebalance(lending_market, clock);

    PoolHealthInfo {
        reserve_a,
        reserve_b,
        lp_supply,
        utilization_a: util_a,
        utilization_b: util_b,
        needs_rebalance_a: needs_rebalance_a.needs_rebalance(),
        needs_rebalance_b: needs_rebalance_b.needs_rebalance(),
    }
}

public struct PoolHealthInfo has copy, drop {
    reserve_a: u64,
    reserve_b: u64,
    lp_supply: u64,
    utilization_a: u64,
    utilization_b: u64,
    needs_rebalance_a: bool,
    needs_rebalance_b: bool,
}

public fun get_bank_utilization<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): u64 {
    if (bank.lending().is_none()) {
        return 0
    };

    let (total_funds, _) = bank.get_btoken_ratio(lending_market, clock);
    let funds_available = balance::value(bank.funds_available());
    let total = total_funds.floor();

    if (total == 0) 0
    else ((total - funds_available) * 10000) / total  // Return utilization in bps
}
```

## Code Examples

### Complete Pool Setup

```move
module my_protocol::complete_example {
    use steamm::{registry, bank, cpmm, global_admin};
    use steamm::pool::Pool;
    use steamm_scripts::pool_script_v2;
    use suilend::lending_market::LendingMarket;

    // Token types
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct B_USDC has drop {}
    public struct B_SUI has drop {}
    public struct LP_USDC_SUI has drop {}

    /// Complete setup for a yield-bearing USDC/SUI pool
    public fun setup_complete_pool<P>(
        registry: &mut Registry,
        lending_market: &mut LendingMarket<P>,
        global_admin: &GlobalAdmin,
        ctx: &mut TxContext,
    ): (
        Pool<B_USDC, B_SUI, CpQuoter, LP_USDC_SUI>,
        ID, // Bank USDC ID
        ID, // Bank SUI ID
    ) {
        // 1. Setup all coin metadata (implementation details omitted)
        let (
            meta_usdc, meta_sui, mut meta_lp,
            mut meta_b_usdc, mut meta_b_sui,
            lp_treasury, b_usdc_treasury, b_sui_treasury
        ) = setup_all_coin_metadata(ctx);

        // 2. Create banks using builder pattern (needed for lending setup)
        let mut builder_usdc = bank::new<P, USDC, B_USDC>(
            registry, &meta_usdc, &mut meta_b_usdc,
            b_usdc_treasury, lending_market, ctx
        );

        let mut builder_sui = bank::new<P, SUI, B_SUI>(
            registry, &meta_sui, &mut meta_b_sui,
            b_sui_treasury, lending_market, ctx
        );

        // 3. Initialize lending with 80% utilization before sharing
        builder_usdc.bank_mut().init_lending(
            global_admin, lending_market,
            8000, 1000, ctx  // 80% ± 10%
        );

        builder_sui.bank_mut().init_lending(
            global_admin, lending_market,
            8000, 1000, ctx  // 80% ± 10%
        );

        // 4. Share the banks
        let bank_usdc_id = builder_usdc.build();
        let bank_sui_id = builder_sui.build();

        // 5. Create the AMM pool
        let pool = cpmm::new<B_USDC, B_SUI, LP_USDC_SUI>(
            registry,
            30,    // 0.3% swap fee
            0,     // No offset
            &meta_b_usdc,
            &meta_b_sui,
            &mut meta_lp,
            lp_treasury,
            ctx,
        );

        (pool, bank_usdc_id, bank_sui_id)
    }

    /// Add initial liquidity to the pool
    public fun bootstrap_liquidity<P>(
        pool: &mut Pool<B_USDC, B_SUI, CpQuoter, LP_USDC_SUI>,
        bank_usdc: &mut Bank<P, USDC, B_USDC>,
        bank_sui: &mut Bank<P, SUI, B_SUI>,
        lending_market: &LendingMarket<P>,
        usdc_amount: u64,
        sui_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<LP_USDC_SUI> {
        // Create coins for initial liquidity
        let mut usdc_coin = coin::mint_for_testing<USDC>(usdc_amount, ctx);
        let mut sui_coin = coin::mint_for_testing<SUI>(sui_amount, ctx);

        // Add liquidity through the script helper
        let lp_tokens = pool_script_v2::deposit_liquidity(
            pool, bank_usdc, bank_sui, lending_market,
            &mut usdc_coin, &mut sui_coin,
            usdc_amount, sui_amount,
            clock, ctx
        );

        // Clean up remaining coins
        if (usdc_coin.value() > 0) {
            transfer::public_transfer(usdc_coin, ctx.sender());
        } else {
            coin::destroy_zero(usdc_coin);
        };

        if (sui_coin.value() > 0) {
            transfer::public_transfer(sui_coin, ctx.sender());
        } else {
            coin::destroy_zero(sui_coin);
        };

        lp_tokens
    }
}
```

### Trading Interface

```move
module my_protocol::trading_interface {
    use steamm_scripts::pool_script_v2;

    /// Execute a swap with proper slippage protection
    public fun execute_swap<P>(
        pool: &mut Pool<B_USDC, B_SUI, CpQuoter, LP_USDC_SUI>,
        bank_usdc: &mut Bank<P, USDC, B_USDC>,
        bank_sui: &mut Bank<P, SUI, B_SUI>,
        lending_market: &LendingMarket<P>,
        input_coin: Coin<USDC>,
        expected_output: u64,
        slippage_bps: u64,  // e.g., 100 = 1%
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let amount_in = input_coin.value();
        let min_amount_out = expected_output * (10000 - slippage_bps) / 10000;

        let mut usdc_coin = input_coin;
        let mut sui_coin = coin::zero<SUI>(ctx);

        pool_script_v2::cpmm_swap(
            pool, bank_usdc, bank_sui, lending_market,
            &mut usdc_coin, &mut sui_coin,
            true,  // USDC -> SUI
            amount_in,
            min_amount_out,
            clock, ctx
        );

        // Handle remaining USDC (should be 0)
        if (usdc_coin.value() > 0) {
            transfer::public_transfer(usdc_coin, ctx.sender());
        } else {
            coin::destroy_zero(usdc_coin);
        };

        sui_coin
    }

    /// Get accurate quote for a potential swap
    public fun get_quote<P>(
        pool: &Pool<B_USDC, B_SUI, CpQuoter, LP_USDC_SUI>,
        bank_usdc: &Bank<P, USDC, B_USDC>,
        bank_sui: &Bank<P, SUI, B_SUI>,
        lending_market: &LendingMarket<P>,
        amount_in: u64,
        usdc_to_sui: bool,
        clock: &Clock,
    ): (u64, u64) {  // (amount_out, fees)
        let quote = pool_script_v2::quote_cpmm_swap(
            pool, bank_usdc, bank_sui, lending_market,
            usdc_to_sui, amount_in, clock
        );

        (quote.amount_out(), quote.output_fees().pool_fees())
    }
}
```

## Reference

### Key Functions by Component

#### Registry

- `registry::init_for_testing()` - Create registry for testing
- Auto-registration happens when creating pools/banks

#### Bank

- `bank::create_bank_and_share()` - Create and share new bank (simple method)
- `bank::new()` / `builder.build()` - Create bank via builder pattern (advanced method)
- `bank.init_lending()` - Enable Suilend integration (admin-gated)
- `bank.mint_btoken()` - Convert tokens to bTokens (singular!)
- `bank.burn_btoken()` - Convert bTokens back to tokens (singular!)
- `bank.rebalance()` - Manual rebalancing trigger

#### Pool

- `pool.deposit_liquidity()` - Add liquidity
- `pool.redeem_liquidity()` - Remove liquidity
- `pool.cpmm_swap()` - Execute CPMM swap
- `pool.cpmm_quote_swap()` - Get CPMM quote

#### Quoters

- `cpmm::new()` - Create constant product pool
- `omm_v2::new()` - Create oracle AMM pool (requires full parameters)
- Various `swap()` and `quote_swap()` functions

#### Scripts (Recommended)

- `pool_script_v2::deposit_liquidity()` - **PREFERRED** - Add liquidity with banks
- `pool_script_v2::redeem_liquidity()` - **PREFERRED** - Remove liquidity with banks
- `pool_script_v2::cpmm_swap()` - **PREFERRED** - Swap with banks
- `pool_script_v2::quote_cpmm_swap()` - **PREFERRED** - Quote with banks

### Gas Optimization Tips

1. **Use Scripts**: Always use `pool_script_v2` functions for yield pools
2. **Batch Operations**: Combine multiple operations when possible
3. **Pre-calculate**: Get quotes off-chain when possible
4. **Rebalance Timing**: Banks auto-rebalance, but manual triggers available
5. **Avoid Micro-transactions**: Respect minimum token block sizes

### Testing

```move
#[test_only]
use steamm::test_utils;

#[test]
fun test_my_pool() {
    let mut scenario = test_scenario::begin(@0x0);

    // Use test utilities for quick setup
    let (pool, bank_a, bank_b, lending_market, lend_cap, prices, bag, clock) =
        test_utils::test_setup_cpmm(30, 0, &mut scenario);

    // Your test logic here

    // Clean up
    destroy(pool);
    destroy(bank_a);
    // ... destroy other objects
    test_scenario::end(scenario);
}
```

### Migration and Versioning

STEAMM uses versioned contracts. When integrating:

1. Always check current versions in Move.toml files
2. Use the latest published package addresses
3. Handle version upgrades gracefully
4. Test with the exact versions you'll use in production

### Best Practices

1. **Start Simple**: Begin with basic CPMM pools, add yield later
2. **Use Scripts**: Always prefer `pool_script_v2` for yield pools
3. **Monitor Health**: Regularly check bank utilization and rebalancing needs
4. **Handle Errors**: Implement proper error handling for common failure modes
5. **Test Thoroughly**: Use the provided test utilities extensively
6. **Gas Awareness**: Be mindful of gas costs, especially for bank operations
