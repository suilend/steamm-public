/// AMM Pool module. It contains the core logic of the of the AMM,
/// such as the deposit and redeem logic, which is exposed and should be
/// called directly. Is also exports an intializer and swap method to be
/// called by the quoter modules.
module steamm::pool;

use std::ascii;
use std::string;
use std::type_name::{get, TypeName};
use steamm::events::emit_event;
use steamm::registry::Registry;
use steamm::fees::{Self, Fees, FeeConfig};
use steamm::global_admin::GlobalAdmin;
use steamm::math::safe_mul_div_up;
use steamm::pool_math;
use steamm::quote::{Self, SwapQuote, SwapFee, DepositQuote, RedeemQuote};
use steamm::version::{Self, Version};
use sui::balance::{Self, Balance, Supply};
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::transfer::public_transfer;
use sui::tx_context::sender;

public use fun steamm::cpmm::swap as Pool.cpmm_swap;
public use fun steamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
public use fun steamm::cpmm::k as Pool.cpmm_k;

// ===== Constants =====

// Protocol Fee numerator in basis points
const SWAP_FEE_NUMERATOR: u64 = 2_000;
// Protocol Fee denominator in basis points (100%)
const BPS_DENOMINATOR: u64 = 10_000;
// Minimum liquidity burned during
// the seed depositing phase
const MINIMUM_LIQUIDITY: u64 = 1_000;

const CURRENT_VERSION: u16 = 1;
const LP_ICON_URL: vector<u8> = b"https://suilend-assets.s3.us-east-2.amazonaws.com/steamm/STEAMM+LP+Token.svg";

// ===== Errors =====

/// Error when LP token decimals are not 9
const EInvalidLpDecimals: u64 = 0;
/// Error when trying to initialize a pool with non-zero LP supply
const ELpSupplyMustBeZero: u64 = 1;
/// Error when swap fee bps is not one of the allowed values
const EInvalidSwapFeeBpsType: u64 = 2;
// Occurs when the swap amount_out is below the
// minimum amount out declared
const ESwapExceedsSlippage: u64 = 3;
// When the coin output exceeds the amount of reserves
// available
const EOutputExceedsLiquidity: u64 = 4;
// Assert that the reserve to lp supply ratio updates
// in favor of of the pool. This error should not occur
const ELpSupplyToReserveRatioViolation: u64 = 5;
// The swap leads to zero output amount
const ESwapOutputAmountIsZero: u64 = 6;
// When the user coin object does not have enough balance to fulfil the swap
const EInsufficientFunds: u64 = 7;
// When creating a pool and the type `A` and `B` are duplicated
const ETypeAandBDuplicated: u64 = 8;
// Empty LP Token when redeeming liquidity
const ELpTokenEmpty: u64 = 9;
// Empty coin A and B when depositing or swapping
const EEmptyCoins: u64 = 9;
const EEmptyLpCoin: u64 = 10;

// ===== Structs =====

/// AMM pool object. This object is the top-level object and sits at the
/// core of the protocol. The generic types `A` and `B` correspond to the
/// associated coin types of the AMM. The `Quoter` type corresponds to the
/// type of the associated quoter module, which is itself the state object of said
/// quoter, meant to store implementation-specific data. The pool object contains
/// the core of the AMM logic, which all quoters rely on.
///
/// It stores the pool's liquidity, protocol fees, the lp supply object
/// as well as the inner state of the associated Quoter.
///
/// The pool object is mostly responsible to providing the liquidity depositing
/// and withdrawal logic, which can be directly called without relying on a quoter's wrapper,
/// as well as the computation of the fees for a given swap. From a perspective of the pool
/// module, the Pool does not rely on the quoter as a trustfull oracle for computing fees.
/// Instead the Pool will compute fees on the amount_out of the swap and therefore
/// inform the quoter on what the fees will be for the given swap.
///
/// Moreover this object also exports an initalizer and a swap method which
/// are meant to be called by the associated quoter module.
public struct Pool<phantom A, phantom B, Quoter: store, phantom LpType: drop> has key, store {
    id: UID,
    // Inner state of the quoter
    quoter: Quoter,
    balance_a: Balance<A>,
    balance_b: Balance<B>,
    // Tracks the supply of lp tokens
    lp_supply: Supply<LpType>,
    protocol_fees: Fees<A, B>,
    // Pool fee configuration
    pool_fee_config: FeeConfig,
    // Lifetime trading and fee data
    trading_data: TradingData,
    version: Version,
}

public struct TradingData has store {
    // swap a2b
    swap_a_in_amount: u128,
    swap_b_out_amount: u128,
    // swap b2a
    swap_a_out_amount: u128,
    swap_b_in_amount: u128,
    // protocol fees
    protocol_fees_a: u64,
    protocol_fees_b: u64,
    // pool fees
    pool_fees_a: u64,
    pool_fees_b: u64,
}

// ===== Public Functions =====

/// Adds liquidity to the AMM Pool and mints LP tokens for the depositor.
/// In respect to the initial deposit, the first supply value `minimum_liquidity`
/// is frozen to prevent inflation attacks.
/// This function ensures that liquidity is added to the pool in a
/// balanced manner, maintaining the pool's reserves and LP supply ratio.
///
/// # Arguments
///
/// * `pool` - The AMM pool to deposit liquidity into
/// * `coin_a` - The first coin to deposit
/// * `coin_b` - The second coin to deposit
/// * `max_a` - Maximum amount of coin A to deposit
/// * `max_b` - Maximum amount of coin B to deposit
///
/// # Returns
///
/// A tuple containing:
/// - `Coin<LpType>`: The minted LP tokens for the depositor.
/// - `DepositResult`: An object containing details of the deposit, including the amounts of coins `A` and `B` deposited and the number of LP tokens minted.
///
/// # Panics
///
/// - If `max` params lead to an invalid ratio
/// - If resulting deposit amounts violate slippage defined by `min` params
/// - If results in an inconsisten reserve-to-LP supply ratio
public fun deposit_liquidity<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    max_a: u64,
    max_b: u64,
    ctx: &mut TxContext,
): (Coin<LpType>, DepositResult) {
    pool.version.assert_version_and_upgrade(CURRENT_VERSION);
    assert!(!(coin_a.value() == 0 && coin_b.value() == 0), EEmptyCoins);

    // Compute token deposits and delta lp tokens
    let quote = quote_deposit_(
        pool,
        max_a,
        max_b,
    );

    let initial_lp_supply = pool.lp_supply.supply_value();
    let (initial_total_funds_a, initial_total_funds_b) = pool.balance_amounts();

    let balance_a = coin_a.balance_mut().split(quote.deposit_a());
    let balance_b = coin_b.balance_mut().split(quote.deposit_b());

    // Add liquidity to pool
    pool.balance_a.join(balance_a);
    pool.balance_b.join(balance_b);

    // Mint LP Tokens
    let mut lp_coins = coin::from_balance(
        pool.lp_supply.increase_supply(quote.mint_lp()),
        ctx,
    );

    // Emit event
    let result = DepositResult {
        user: sender(ctx),
        pool_id: object::id(pool),
        deposit_a: quote.deposit_a(),
        deposit_b: quote.deposit_b(),
        mint_lp: quote.mint_lp(),
        balance_a: pool.balance_a.value(),
        balance_b: pool.balance_b.value(),
    };

    emit_event(result);

    // Lock minimum liquidity if initial seed liquidity - prevents inflation attack
    if (quote.initial_deposit()) {
        public_transfer(lp_coins.split(MINIMUM_LIQUIDITY, ctx), @0x0);
    };

    assert!(lp_coins.value() > 0, EEmptyLpCoin);

    assert_lp_supply_reserve_ratio(
        initial_total_funds_a,
        initial_lp_supply,
        pool.balance_amount_a(),
        pool.lp_supply.supply_value(),
    );

    assert_lp_supply_reserve_ratio(
        initial_total_funds_b,
        initial_lp_supply,
        pool.balance_amount_b(),
        pool.lp_supply.supply_value(),
    );

    (lp_coins, result)
}

/// Redeems liquidity from the AMM Pool by burning LP tokens and
/// withdrawing the corresponding coins `A` and `B`.
///
/// Liquidity is redeemed from the pool in a balanced manner,
/// maintaining the pool's reserves and LP supply ratio.
///
/// # Arguments
///
/// * `pool` - The pool object to redeem liquidity from
/// * `lp_tokens` - The LP tokens to burn
/// * `min_a` - Minimum amount of coin A to receive (for slippage protection)
/// * `min_b` - Minimum amount of coin B to receive (for slippage protection)
///
/// # Returns
///
/// A tuple containing:
/// - `Coin<A>`: The withdrawn amount of coin `A`.
/// - `Coin<B>`: The withdrawn amount of coin `B`.
/// - `RedeemResult`: An object containing details of the redeem transaction,
/// including the amounts of coins `A` and `B` withdrawn and the
/// number of LP tokens burned.
///
/// # Panics
///
/// - If it results in an inconsistent reserve-to-LP supply ratio
/// - If it results in withdraw amounts that violate the slippage `min` params
public fun redeem_liquidity<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    lp_tokens: Coin<LpType>,
    min_a: u64,
    min_b: u64,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>, RedeemResult) {
    assert!(lp_tokens.value() > 0, ELpTokenEmpty);
    pool.version.assert_version_and_upgrade(CURRENT_VERSION);

    // Compute amounts to withdraw
    let quote = quote_redeem_(
        pool,
        lp_tokens.value(),
        min_a,
        min_b,
    );

    let initial_lp_supply = pool.lp_supply.supply_value();
    let initial_reserve_a = pool.balance_amount_a();
    let initial_reserve_b = pool.balance_amount_b();
    let lp_burn = lp_tokens.value();

    assert!(quote.burn_lp() == lp_burn, 0);

    // Burn LP Tokens
    pool.lp_supply.decrease_supply(lp_tokens.into_balance());

    // Withdraw
    let balance_a = pool.balance_a.split(quote.withdraw_a());
    let balance_b = pool.balance_b.split(quote.withdraw_b());

    // Prepare tokens to send
    let tokens_a = coin::from_balance(
        balance_a,
        ctx,
    );
    let tokens_b = coin::from_balance(
        balance_b,
        ctx,
    );

    assert_lp_supply_reserve_ratio(
        initial_reserve_a,
        initial_lp_supply,
        pool.balance_amount_a(),
        pool.lp_supply.supply_value(),
    );

    assert_lp_supply_reserve_ratio(
        initial_reserve_b,
        initial_lp_supply,
        pool.balance_amount_b(),
        pool.lp_supply.supply_value(),
    );

    // Emit events
    let result = RedeemResult {
        user: sender(ctx),
        pool_id: object::id(pool),
        withdraw_a: tokens_a.value(),
        withdraw_b: tokens_b.value(),
        burn_lp: lp_burn,
        balance_a: pool.balance_a.value(),
        balance_b: pool.balance_b.value(),
    };

    emit_event(result);

    (tokens_a, tokens_b, result)
}

/// Quotes the amount of LP tokens that will be minted for a given deposit of tokens A and B.
/// This function calculates the optimal deposit amounts while respecting the maximum amounts specified.
///
/// # Arguments
///
/// * `pool` - The pool object containing current reserves and LP supply
/// * `max_a` - Maximum amount of token A to deposit
/// * `max_b` - Maximum amount of token B to deposit
///
/// # Returns
///
/// `DepositQuote`: A quote containing the optimal deposit amounts and expected LP tokens to be minted
public fun quote_deposit<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    max_a: u64,
    max_b: u64,
): DepositQuote {
    quote_deposit_(
        pool,
        max_a,
        max_b,
    )
}

/// Quotes the redemption of LP tokens for underlying tokens A and B.
/// This function calculates how many tokens A and B will be received when burning LP tokens.
///
/// # Arguments
///
/// * `pool` - The pool object containing current reserves and LP supply
/// * `lp_tokens` - Amount of LP tokens to burn
///
/// # Returns
///
/// `RedeemQuote`: A quote containing the amounts of tokens A and B to be received and any fees
public fun quote_redeem<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    lp_tokens: u64,
): RedeemQuote {
    quote_redeem_(
        pool,
        lp_tokens,
        0,
        0,
    )
}

// ===== Admin Functions =====

public fun collect_protocol_fees<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    _global_admin: &GlobalAdmin,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    pool.version.assert_version_and_upgrade(CURRENT_VERSION);

    let (fees_a, fees_b) = pool.protocol_fees.withdraw();

    (coin::from_balance(fees_a, ctx), coin::from_balance(fees_b, ctx))
}

entry fun migrate<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    _admin: &GlobalAdmin,
) {
    pool.version.migrate_(CURRENT_VERSION);
}

// ===== Package Functions =====

/// Initializes and returns a new AMM Pool along with its associated PoolCap.
/// The pool is initialized with zero balances for both coin types `A` and `B`,
/// specified protocol fees, and the provided swap fee. The pool's LP supply
/// object is initialized at zero supply.
///
/// This function is meant to be called by the quoter module and therefore it
/// it witness-protected.
///
/// # Arguments
///
/// * `meta_a` - Coin metadata for token A
/// * `meta_b` - Coin metadata for token B
/// * `meta_lp` - Mutable coin metadata for LP token
/// * `lp_treasury` - Treasury capability for LP token
/// * `swap_fee_bps` - Pool swap fee in basis points
/// * `quoter` - Quoter implementation for pool
///
/// # Returns
///
/// A tuple containing:
/// - `Pool<A, B, Quoter, LpType>`: The created AMM pool object.
/// - `PoolCap<A, B, Quoter, LpType>`: The associated pool capability object.
///
/// # Panics
///
/// This function will panic if:
/// - `swap_fee_bps` is greater than or equal to `BPS_DENOMINATOR`
/// - `lp_treasury` has non-zero total supply
public(package) fun new<A, B, Quoter: store, LpType: drop>(
    registry: &mut Registry,
    swap_fee_bps: u64,
    quoter: Quoter,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    ctx: &mut TxContext,
): Pool<A, B, Quoter, LpType> {
    assert!(lp_treasury.total_supply() == 0, ELpSupplyMustBeZero);
    assert_swap_fee_bps(swap_fee_bps);
    assert!(get<A>() != get<B>(), ETypeAandBDuplicated);

    update_lp_metadata(meta_a, meta_b, meta_lp, &lp_treasury);

    let lp_supply = lp_treasury.treasury_into_supply();

    let pool = Pool {
        id: object::new(ctx),
        quoter,
        balance_a: balance::zero(),
        balance_b: balance::zero(),
        protocol_fees: fees::new(SWAP_FEE_NUMERATOR, BPS_DENOMINATOR, 0),
        pool_fee_config: fees::new_config(swap_fee_bps, BPS_DENOMINATOR, 0),
        lp_supply,
        trading_data: TradingData {
            swap_a_in_amount: 0,
            swap_b_out_amount: 0,
            swap_a_out_amount: 0,
            swap_b_in_amount: 0,
            protocol_fees_a: 0,
            protocol_fees_b: 0,
            pool_fees_a: 0,
            pool_fees_b: 0,
        },
        version: version::new(CURRENT_VERSION),
    };

    let event = NewPoolResult {
        pool_id: object::id(&pool),
        coin_type_a: get<A>(),
        coin_type_b: get<B>(),
        lp_token_type: get<LpType>(),
        quoter_type: get<Quoter>(),
        swap_fee_bps
    };

    emit_event(event);

    registry.register_pool(
        event.pool_id,
        event.coin_type_a,
        event.coin_type_b,
        event.lp_token_type,
        event.swap_fee_bps,
        event.quoter_type,
    );

    pool
}

/// Executes inner swap logic that is generalised accross all quoters. It takes
/// care of fee handling, management of fund inputs and outputs as well
/// as slippage protections.
///
/// This function is meant to be called by the quoter module and therefore it
/// it witness-protected.
///
/// # Arguments
///
/// * `pool` - The pool object containing balances and trading data
/// * `coin_a` - Coin A to be swapped
/// * `coin_b` - Coin B to be swapped
/// * `quote` - Quote object containing swap parameters and amounts
/// * `min_amount_out` - Minimum output amount for slippage protection
///
/// # Returns
///
/// `SwapResult`: An object containing details of the executed swap,
/// including input and output amounts, fees, and the direction of the swap.
///
/// # Panics
///
/// This function will panic if:
/// - `quote.amount_out()` is zero
/// - `quote.amount_out()` is less than `min_amount_out`
/// - if the `quote.amount_out()` exceeds the funds in the assocatied bank
#[allow(unused_mut_parameter)]
public(package) fun swap<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    quote: SwapQuote,
    min_amount_out: u64,
    ctx: &mut TxContext,
): SwapResult {
    pool.version.assert_version_and_upgrade(CURRENT_VERSION);
    assert!(!(coin_a.value() == 0 && coin_b.value() == 0), EEmptyCoins);

    assert!(quote.amount_out() > 0, ESwapOutputAmountIsZero);
    assert!(quote.amount_out() >= min_amount_out, ESwapExceedsSlippage);

    let (protocol_fee_a, protocol_fee_b) = pool.protocol_fees.balances_mut();

    if (quote.a2b()) {
        quote.swap_inner(
            // Inputs
            &mut pool.balance_a, // total_funds_in
            coin_a, // coin_in
            &mut pool.trading_data.swap_a_in_amount, // swap_in_amount
            // Outputs
            protocol_fee_b, // protocol_fees
            &mut pool.balance_b, // total_funds_out
            coin_b, // coin_out
            &mut pool.trading_data.swap_b_out_amount, // swap_out_amount
            &mut pool.trading_data.protocol_fees_b, // protocol_fees
            &mut pool.trading_data.pool_fees_b, // pool_fees
        );
    } else {
        quote.swap_inner(
            // Inputs
            &mut pool.balance_b, // total_funds_in
            coin_b, // coin_in
            &mut pool.trading_data.swap_b_in_amount, // swap_in_amount
            // Outputs
            protocol_fee_a, // protocol_fees
            &mut pool.balance_a, // total_funds_out
            coin_a, // coin_out
            &mut pool.trading_data.swap_a_out_amount, // swap_out_amount
            &mut pool.trading_data.protocol_fees_a, // protocol_fees
            &mut pool.trading_data.pool_fees_a, // pool_fees
        );
    };

    // Emit event
    let result = SwapResult {
        user: sender(ctx),
        pool_id: object::id(pool),
        amount_in: quote.amount_in(),
        amount_out: quote.amount_out(),
        output_fees: *quote.output_fees(),
        a2b: quote.a2b(),
        balance_a: pool.balance_a.value(),
        balance_b: pool.balance_b.value(),
    };

    emit_event(result);

    result
}

public(package) fun assert_liquidity(reserve_out: u64, amount_out: u64) {
    assert!(amount_out <= reserve_out, EOutputExceedsLiquidity);
}

public(package) fun get_quote<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    amount_in: u64,
    amount_out: u64,
    a2b: bool,
): SwapQuote {
    let (protocol_fees, pool_fees) = pool.compute_swap_fees_(amount_out);
    let amount_out_net = amount_out - protocol_fees - pool_fees;

    quote::quote(
        amount_in,
        amount_out_net,
        protocol_fees,
        pool_fees,
        a2b,
    )
}

public(package) fun compute_swap_fees_<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    amount: u64,
): (u64, u64) {
    let (protocol_fee_num, protocol_fee_denom) = pool.protocol_fees.fee_ratio();
    let (pool_fee_num, pool_fee_denom) = pool.pool_fee_config.fee_ratio();

    let total_fees = safe_mul_div_up(amount, pool_fee_num, pool_fee_denom);
    let protocol_fees = safe_mul_div_up(total_fees, protocol_fee_num, protocol_fee_denom);
    let pool_fees = total_fees - protocol_fees;

    (protocol_fees, pool_fees)
}

public(package) fun quoter_mut<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
): &mut Quoter {
    &mut pool.quoter
}

// ===== View & Getters =====

public fun balance_amounts<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): (u64, u64) {
    (pool.balance_amount_a(), pool.balance_amount_b())
}

public fun balance_amount_a<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): u64 {
    pool.balance_a.value()
}

public fun balance_amount_b<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): u64 {
    pool.balance_b.value()
}

public fun protocol_fees<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): &Fees<A, B> {
    &pool.protocol_fees
}

public fun pool_fee_config<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): &FeeConfig {
    &pool.pool_fee_config
}

public fun lp_supply_val<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): u64 {
    pool.lp_supply.supply_value()
}

public fun trading_data<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
): &TradingData {
    &pool.trading_data
}

public fun quoter<A, B, Quoter: store, LpType: drop>(pool: &Pool<A, B, Quoter, LpType>): &Quoter {
    &pool.quoter
}

public fun total_swap_a_in_amount(trading_data: &TradingData): u128 {
    trading_data.swap_a_in_amount
}

public fun total_swap_b_out_amount(trading_data: &TradingData): u128 {
    trading_data.swap_b_out_amount
}

public fun total_swap_a_out_amount(trading_data: &TradingData): u128 {
    trading_data.swap_a_out_amount
}

public fun total_swap_b_in_amount(trading_data: &TradingData): u128 {
    trading_data.swap_b_in_amount
}

public fun protocol_fees_a(trading_data: &TradingData): u64 { trading_data.protocol_fees_a }

public fun protocol_fees_b(trading_data: &TradingData): u64 { trading_data.protocol_fees_b }

public fun pool_fees_a(trading_data: &TradingData): u64 { trading_data.pool_fees_a }

public fun pool_fees_b(trading_data: &TradingData): u64 { trading_data.pool_fees_b }

public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

// ===== Private functions =====

fun swap_inner<In, Out>(
    quote: &SwapQuote,
    // In
    reserve_in: &mut Balance<In>,
    coin_in: &mut Coin<In>,
    lifetime_in_amount: &mut u128,
    // Out
    protocol_fee_balance: &mut Balance<Out>,
    reserve_out: &mut Balance<Out>,
    coin_out: &mut Coin<Out>,
    lifetime_out_amount: &mut u128,
    lifetime_protocol_fee: &mut u64,
    lifetime_pool_fee: &mut u64,
) {
    assert!(quote.amount_out() <= reserve_out.value(), EOutputExceedsLiquidity);
    assert!(coin_in.value() >= quote.amount_in(), EInsufficientFunds);

    let balance_in = coin_in.balance_mut().split(quote.amount_in());

    // Transfers amount in
    reserve_in.join(balance_in);

    // Transfers amount out - post fees if any
    let protocol_fees = quote.output_fees().protocol_fees();
    let pool_fees = quote.output_fees().pool_fees();

    // Transfer protocol fees out
    protocol_fee_balance.join(reserve_out.split(protocol_fees));

    // Transfers amount out
    coin_out.balance_mut().join(reserve_out.split(quote.amount_out()));

    // Update trading data
    *lifetime_protocol_fee = *lifetime_protocol_fee + protocol_fees;
    *lifetime_pool_fee = *lifetime_pool_fee + pool_fees;

    *lifetime_in_amount = *lifetime_in_amount + (quote.amount_in() as u128);

    *lifetime_out_amount = *lifetime_out_amount + (quote.amount_out() as u128);
}

fun quote_deposit_<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    max_a: u64,
    max_b: u64,
): DepositQuote {
    let is_initial_deposit = pool.lp_supply_val() == 0;

    // We consider the liquidity available for trading
    // as well as the net accumulated fees, as these belong to LPs
    let (reserve_a, reserve_b) = pool.balance_amounts();

    // Compute token deposits and delta lp tokens
    let (deposit_a, deposit_b, lp_tokens) = pool_math::quote_deposit(
        reserve_a,
        reserve_b,
        pool.lp_supply_val(),
        max_a,
        max_b,
    );

    quote::deposit_quote(
        is_initial_deposit,
        deposit_a,
        deposit_b,
        lp_tokens,
    )
}

fun quote_redeem_<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    lp_tokens: u64,
    min_a: u64,
    min_b: u64,
): RedeemQuote {
    // We need to consider the liquidity available for trading
    // as well as the net accumulated fees, as these belong to LPs
    let (reserve_a, reserve_b) = pool.balance_amounts();

    // Compute amounts to withdraw
    let (withdraw_a, withdraw_b) = pool_math::quote_redeem(
        reserve_a,
        reserve_b,
        pool.lp_supply_val(),
        lp_tokens,
        min_a,
        min_b,
    );

    quote::redeem_quote(
        withdraw_a,
        withdraw_b,
        lp_tokens,
    )
}

fun assert_lp_supply_reserve_ratio(
    initial_reserve_a: u64,
    initial_lp_supply: u64,
    final_reserve_a: u64,
    final_lp_supply: u64,
) {
    assert!(
        (final_reserve_a as u128) * (initial_lp_supply as u128) >=
            (initial_reserve_a as u128) * (final_lp_supply as u128),
        ELpSupplyToReserveRatioViolation,
    );
}

fun assert_swap_fee_bps(swap_fee_bps: u64) {
    assert!(
        swap_fee_bps == 1 || 
        swap_fee_bps == 5 || 
        swap_fee_bps == 30 || 
        swap_fee_bps == 100 ||
        swap_fee_bps == 200,
        EInvalidSwapFeeBpsType,
    );
}

fun update_lp_metadata<A, B, LpType: drop>(
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &mut CoinMetadata<LpType>,
    treasury_lp: &TreasuryCap<LpType>,
) {
    assert!(meta_lp.get_decimals() == 9, EInvalidLpDecimals);

    // Construct and set the LP token name
    let mut lp_name = string::utf8(b"STEAMM LP ");
    lp_name.append(meta_a.get_symbol().to_string());
    lp_name.append(string::utf8(b"-"));
    lp_name.append(meta_b.get_symbol().to_string());
    treasury_lp.update_name(meta_lp, lp_name);

    // Construct and set the LP token symbol
    let mut lp_symbol = ascii::string(b"STEAMM LP ");
    lp_symbol.append(meta_a.get_symbol());
    lp_symbol.append(ascii::string(b"-"));
    lp_symbol.append(meta_b.get_symbol());
    treasury_lp.update_symbol(meta_lp, lp_symbol);

    // Set the description
    treasury_lp.update_description(meta_lp, string::utf8(b"STEAMM LP Token"));

    // Set the icon URL
    treasury_lp.update_icon_url(meta_lp, ascii::string(LP_ICON_URL));
}

// ===== Events =====

public struct NewPoolResult has copy, drop, store {
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    quoter_type: TypeName,
    lp_token_type: TypeName,
    swap_fee_bps: u64,
}

public struct SwapResult has copy, drop, store {
    user: address,
    pool_id: ID,
    amount_in: u64,
    amount_out: u64,
    output_fees: SwapFee,
    a2b: bool,

    balance_a: u64,
    balance_b: u64,
}

public struct DepositResult has copy, drop, store {
    user: address,
    pool_id: ID,
    deposit_a: u64,
    deposit_b: u64,
    mint_lp: u64,

    balance_a: u64,
    balance_b: u64,
}

public struct RedeemResult has copy, drop, store {
    user: address,
    pool_id: ID,
    withdraw_a: u64,
    withdraw_b: u64,
    burn_lp: u64,

    balance_a: u64,
    balance_b: u64,
}

public use fun swap_result_user as SwapResult.user;
public use fun swap_result_pool_id as SwapResult.pool_id;
public use fun swap_result_amount_in as SwapResult.amount_in;
public use fun swap_result_amount_out as SwapResult.amount_out;
public use fun swap_result_protocol_fees as SwapResult.protocol_fees;
public use fun swap_result_pool_fees as SwapResult.pool_fees;
public use fun swap_result_a2b as SwapResult.a2b;

public use fun deposit_result_user as DepositResult.user;
public use fun deposit_result_pool_id as DepositResult.pool_id;
public use fun deposit_result_deposit_a as DepositResult.deposit_a;
public use fun deposit_result_deposit_b as DepositResult.deposit_b;
public use fun deposit_result_mint_lp as DepositResult.mint_lp;

public use fun redeem_result_user as RedeemResult.user;
public use fun redeem_result_pool_id as RedeemResult.pool_id;
public use fun redeem_result_withdraw_a as RedeemResult.withdraw_a;
public use fun redeem_result_withdraw_b as RedeemResult.withdraw_b;
public use fun redeem_result_burn_lp as RedeemResult.burn_lp;

public fun swap_result_user(swap_result: &SwapResult): address { swap_result.user }

public fun swap_result_pool_id(swap_result: &SwapResult): ID { swap_result.pool_id }

public fun swap_result_amount_in(swap_result: &SwapResult): u64 { swap_result.amount_in }

public fun swap_result_amount_out(swap_result: &SwapResult): u64 { swap_result.amount_out }

public fun swap_result_protocol_fees(swap_result: &SwapResult): u64 {
    swap_result.output_fees.protocol_fees()
}

public fun swap_result_pool_fees(swap_result: &SwapResult): u64 {
    swap_result.output_fees.pool_fees()
}

public fun swap_result_a2b(swap_result: &SwapResult): bool { swap_result.a2b }

public fun deposit_result_user(deposit_result: &DepositResult): address { deposit_result.user }

public fun deposit_result_pool_id(deposit_result: &DepositResult): ID { deposit_result.pool_id }

public fun deposit_result_deposit_a(deposit_result: &DepositResult): u64 {
    deposit_result.deposit_a
}

public fun deposit_result_deposit_b(deposit_result: &DepositResult): u64 {
    deposit_result.deposit_b
}

public fun deposit_result_mint_lp(deposit_result: &DepositResult): u64 { deposit_result.mint_lp }

public fun redeem_result_user(redeem_result: &RedeemResult): address { redeem_result.user }

public fun redeem_result_pool_id(redeem_result: &RedeemResult): ID { redeem_result.pool_id }

public fun redeem_result_withdraw_a(redeem_result: &RedeemResult): u64 { redeem_result.withdraw_a }

public fun redeem_result_withdraw_b(redeem_result: &RedeemResult): u64 { redeem_result.withdraw_a }

public fun redeem_result_burn_lp(redeem_result: &RedeemResult): u64 { redeem_result.burn_lp }

// ===== Test-Only =====

#[test_only]
public fun new_for_testing<A, B, Quoter: store, LpType: drop>(
    swap_fee_bps: u64,
    quoter: Quoter,
    ctx: &mut TxContext,
): Pool<A, B, Quoter, LpType> {
    let lp_treasury = coin::create_treasury_cap_for_testing(ctx);
    let lp_supply = lp_treasury.treasury_into_supply();

    Pool {
        id: object::new(ctx),
        quoter,
        balance_a: balance::zero(),
        balance_b: balance::zero(),
        protocol_fees: fees::new(SWAP_FEE_NUMERATOR, BPS_DENOMINATOR, 0),
        pool_fee_config: fees::new_config(swap_fee_bps, BPS_DENOMINATOR, 0),
        lp_supply,
        trading_data: TradingData {
            swap_a_in_amount: 0,
            swap_b_out_amount: 0,
            swap_a_out_amount: 0,
            swap_b_in_amount: 0,
            protocol_fees_a: 0,
            protocol_fees_b: 0,
            pool_fees_a: 0,
            pool_fees_b: 0,
        },
        version: version::new(CURRENT_VERSION),
    }
}

#[test_only]
public(package) fun no_protocol_fees_for_testing<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
) {
    let fee_num = pool.protocol_fees.config_mut().fee_numerator_mut();
    *fee_num = 0;
}

#[test_only]
public(package) fun no_swap_fees_for_testing<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
) {
    let fee_num = pool.pool_fee_config.fee_numerator_mut();
    *fee_num = 0;
}

#[test_only]
public(package) fun mut_reserve_a<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    amount: u64,
    increase: bool,
) {
    if (increase) {
        pool.balance_a.join(balance::create_for_testing(amount));
    } else {
        balance::destroy_for_testing(pool.balance_a.split(amount));
    };
}

#[test_only]
public(package) fun mut_reserve_b<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
    amount: u64,
    increase: bool,
) {
    if (increase) {
        pool.balance_b.join(balance::create_for_testing(amount));
    } else {
        balance::destroy_for_testing(pool.balance_b.split(amount));
    };
}

#[test_only]
public(package) fun lp_supply_mut_for_testing<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
): &mut Supply<LpType> {
    &mut pool.lp_supply
}

#[test_only]
public(package) fun protocol_fees_mut_for_testing<A, B, Quoter: store, LpType: drop>(
    pool: &mut Pool<A, B, Quoter, LpType>,
): &mut Fees<A, B> {
    &mut pool.protocol_fees
}

#[test_only]
public(package) fun quote_deposit_impl_test<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    ideal_a: u64,
    ideal_b: u64,
): DepositQuote {
    quote_deposit_(
        pool,
        ideal_a,
        ideal_b,
    )
}

#[test_only]
public(package) fun quote_redeem_impl_test<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    lp_tokens: u64,
    min_a: u64,
    min_b: u64,
): RedeemQuote {
    quote_redeem_(
        pool,
        lp_tokens,
        min_a,
        min_b,
    )
}

#[test_only]
public(package) fun to_quote(result: SwapResult): SwapQuote {
    let SwapResult {
        user: _,
        pool_id: _,
        amount_in,
        amount_out,
        output_fees,
        a2b,
        balance_a: _,
        balance_b: _,
    } = result;

    quote::quote_for_testing(
        amount_in,
        amount_out,
        output_fees.protocol_fees(),
        output_fees.pool_fees(),
        a2b,
    )
}

// ===== Tests =====

#[test]
fun test_assert_lp_supply_reserve_ratio_ok() {
    // Perfect ratio
    assert_lp_supply_reserve_ratio(
        10, // initial_reserve_a
        10, // initial_lp_supply
        100, // final_reserve_a
        100, // final_lp_supply
    );

    // Ratio gets better in favor of the pool
    assert_lp_supply_reserve_ratio(
        10, // initial_reserve_a
        10, // initial_lp_supply
        100, // final_reserve_a
        99, // final_lp_supply
    );
}

// Note: This error cannot occur unless there is a bug in the contract.
// It provides an extra layer of security
#[test]
#[expected_failure(abort_code = ELpSupplyToReserveRatioViolation)]
fun test_assert_lp_supply_reserve_ratio_not_ok() {
    // Ratio gets worse in favor of the pool
    assert_lp_supply_reserve_ratio(
        10, // initial_reserve_a
        10, // initial_lp_supply
        100, // final_reserve_a
        101, // final_lp_supply
    );
}
