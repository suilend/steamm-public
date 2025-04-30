/// OracleV2 AMM Hook implementation. This quoter can only be initialized with btoken types.
module steamm::omm_v2;

use oracles::oracles::{OracleRegistry, OraclePriceUpdate};
use steamm::pool::{Self, Pool, SwapResult};
use steamm::quote::SwapQuote;
use steamm::registry::Registry;
use steamm::version::{Self, Version};
use steamm::utils::oracle_decimal_to_decimal;
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};
use suilend::decimal::{Decimal, Self};
use suilend::lending_market::LendingMarket;
use std::type_name::{Self};
use steamm::bank::Bank;
use steamm::events::emit_event;
use steamm::quoter_math;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;

// ===== Errors =====
const EInvalidBankType: u64 = 0;
const EInvalidOracleIndex: u64 = 1;
const EInvalidOracleRegistry: u64 = 2;
const EInvalidDecimalsDifference: u64 = 3;

public struct OracleQuoterV2 has store {
    version: Version,

    // oracle params
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,

    // coin info
    decimals_a: u8,
    decimals_b: u8,

    // amplifier
    amp: u64,
}

// ===== Public Methods =====

public fun new<P, A, B, B_A, B_B, LpType: drop>(
    registry: &mut Registry,
    lending_market: &LendingMarket<P>,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_b_a: &CoinMetadata<B_A>,
    meta_b_b: &CoinMetadata<B_B>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    oracle_registry: &OracleRegistry,
    oracle_index_a: u64,
    oracle_index_b: u64,
    amplifier: u64,
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): Pool<B_A, B_B, OracleQuoterV2, LpType> {
    // ensure that this quoter can only be initialized with btoken types
    let bank_data_a = registry.get_bank_data<A>(object::id(lending_market));
    assert!(type_name::get<B_A>() == bank_data_a.btoken_type(), EInvalidBankType);

    let bank_data_b = registry.get_bank_data<B>(object::id(lending_market));
    assert!(type_name::get<B_B>() == bank_data_b.btoken_type(), EInvalidBankType);

    let decimals_a = meta_a.get_decimals();
    let decimals_b = meta_b.get_decimals();

    if (decimals_a >= decimals_b) {
        assert!(decimals_a - decimals_b <= 10, EInvalidDecimalsDifference);
    } else {
        assert!(decimals_b - decimals_a <= 10, EInvalidDecimalsDifference);
    };

    let quoter = OracleQuoterV2 {
        version: version::new(CURRENT_VERSION),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        decimals_a: meta_a.get_decimals(),
        decimals_b: meta_b.get_decimals(),
        amp: amplifier,
    };

    let pool = pool::new<B_A, B_B, OracleQuoterV2, LpType>(
        registry,
        swap_fee_bps,
        quoter,
        meta_b_a,
        meta_b_b,
        meta_lp,
        lp_treasury,
        ctx,
    );

    let result = NewOracleQuoterV2 {
        pool_id: object::id(&pool),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        amplifier,
    };

    emit_event(result);

    return pool
}

public fun swap<P, A, B, B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    coin_a: &mut Coin<B_A>,
    coin_b: &mut Coin<B_B>,
    a2b: bool,
    // Amount in (btoken)
    amount_in: u64,
    // Min amount in (btoken)
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): SwapResult {
    pool.quoter_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

    assert!(oracle_price_update_a.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_a.oracle_index() == pool.quoter().oracle_index_a, EInvalidOracleIndex);

    assert!(oracle_price_update_b.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_b.oracle_index() == pool.quoter().oracle_index_b, EInvalidOracleIndex);

    let quote = quote_swap(
        pool, 
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        amount_in, 
        a2b,
        clock,
    );

    let response = pool.swap(
        coin_a,
        coin_b,
        quote,
        min_amount_out,
        ctx,
    );

    response
}

public fun quote_swap<P, A, B, B_A, B_B, LpType: drop>(
    pool: &Pool<B_A, B_B, OracleQuoterV2, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    // Amount in (btoken)
    amount_in: u64,
    a2b: bool,
    clock: &Clock,
): SwapQuote {
    let quoter = pool.quoter();

    let decimals_a = quoter.decimals_a;
    let decimals_b = quoter.decimals_b; 

    let price_a = oracle_decimal_to_decimal(oracle_price_update_a.price());
    let price_b = oracle_decimal_to_decimal(oracle_price_update_b.price());

    let (bank_total_funds_a, total_btoken_supply_a) = bank_a.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_a = bank_total_funds_a.div(total_btoken_supply_a);

    let (bank_total_funds_b, total_btoken_supply_b) = bank_b.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_b = bank_total_funds_b.div(total_btoken_supply_b);


    let amount_out = if (a2b) {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_a);
        let underlying_reserve_in = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);
        let underlying_reserve_out = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);

        // quote_swap_impl uses the underlying values instead of btoken values
        let amount_out_underlying = quote_swap_impl(
            underlying_amount_in,
            underlying_reserve_in,
            underlying_reserve_out,
            decimals_a,
            decimals_b,
            price_a,
            price_b,
            quoter.amp,
            a2b,
        );

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_b).floor();

        if (amount_out >= pool.balance_amount_b()) {
            amount_out = 0
        };

        amount_out
    } else {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_b);
        let underlying_reserve_in = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);
        let underlying_reserve_out = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);

        // quote_swap_impl uses the underlying values instead of btoken values
        let amount_out_underlying = quote_swap_impl(
            underlying_amount_in,
            underlying_reserve_in,
            underlying_reserve_out,
            decimals_b,
            decimals_a,
            price_b,
            price_a,
            quoter.amp,
            a2b,
        );

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_a).floor();

        if (amount_out >= pool.balance_amount_a()) {
            amount_out = 0;
        };

        amount_out
    };

    pool.get_quote(amount_in, amount_out, a2b)
}

fun quote_swap_impl(
    // Amount in (underlying)
    amount_in: Decimal,
    // Reserve in (underlying)
    reserve_in: Decimal,
    // Reserve out (underlying)
    reserve_out: Decimal,
    decimals_in: u8,
    decimals_out: u8,
    // Price In (underlying)
    price_in: Decimal,
    // Price Out (underlying)
    price_out: Decimal,
    amplifier: u64,
    a2b: bool,
): u64 {
    // quoter_math::swap uses the underlying values instead of btoken values
    if (a2b) {
        quoter_math::swap(
            amount_in, // input_a
            reserve_in, // reserve_a
            reserve_out, // reserve_b
            price_in, // price_a
            price_out, // price_b
            decimals_in as u64, // decimals_a
            decimals_out as u64, // decimals_b
            amplifier,
            true, // a2b
        )
    } else {
        quoter_math::swap(
            amount_in, // input_b
            reserve_out, // reserve_a
            reserve_in, // reserve_b
            price_out, // price_a
            price_in, // price_b
            decimals_out as u64, // decimals_a
            decimals_in as u64, // decimals_b
            amplifier,
            false, // a2b
        )
    }
}

// ===== Events =====

public struct NewOracleQuoterV2 has copy, drop, store {
    pool_id: ID,
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,
    amplifier: u64,
}

// ===== Tests =====

#[test]
fun test_oracle_decimal_to_decimal() {
    use sui::test_utils::assert_eq;
    use oracles::oracle_decimal::{Self};

    let price = oracle_decimal_to_decimal(oracle_decimal::new(140, 4, false));
    assert_eq(price, decimal::from(1_400_000));

    let price = oracle_decimal_to_decimal(oracle_decimal::new(140, 3, true));
    assert_eq(price, decimal::from(140).div(decimal::from(1000)));
}

#[test]
fun test_quote_swap_impl_amp_1() {
    use sui::test_utils::assert_eq;
    use std::debug::print;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 951);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 6321);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_10() {
    use sui::test_utils::assert_eq;
    use std::debug::print;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 994);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 8776);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_100() {
    use sui::test_utils::assert_eq;
    use std::debug::print;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 999);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9734);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
}

#[test]
fun test_quote_swap_impl_amp_1000() {
    use sui::test_utils::assert_eq;
    use std::debug::print;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9

    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1000, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 999);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1000, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9955);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}