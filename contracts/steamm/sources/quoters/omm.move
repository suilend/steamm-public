/// Oracle AMM Hook implementation. This quoter can only be initialized with btoken types.
module steamm::omm;
use oracles::oracles::{OracleRegistry, OraclePriceUpdate};
use oracles::oracle_decimal::{OracleDecimal};
use steamm::pool::{Self, Pool, SwapResult};
use steamm::quote::SwapQuote;
use steamm::registry::Registry;
use steamm::version::{Self, Version};
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};
use suilend::decimal::{Decimal, Self};
use suilend::lending_market::LendingMarket;
use std::type_name::{Self};
use steamm::bank::Bank;
use steamm::events::emit_event;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;

// ===== Errors =====
const EInvalidBankType: u64 = 0;
const EInvalidOracleIndex: u64 = 1;
const EInvalidOracleRegistry: u64 = 2;

public struct OracleQuoter has store {
    version: Version,

    // oracle params
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,

    // coin info
    decimals_a: u8,
    decimals_b: u8,
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
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): Pool<B_A, B_B, OracleQuoter, LpType> {
    // ensure that this quoter can only be initialized with btoken types
    let bank_data_a = registry.get_bank_data<A>(object::id(lending_market));
    assert!(type_name::get<B_A>() == bank_data_a.btoken_type(), EInvalidBankType);

    let bank_data_b = registry.get_bank_data<B>(object::id(lending_market));
    assert!(type_name::get<B_B>() == bank_data_b.btoken_type(), EInvalidBankType);

    let quoter = OracleQuoter {
        version: version::new(CURRENT_VERSION),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        decimals_a: meta_a.get_decimals(),
        decimals_b: meta_b.get_decimals(),
    };

    let pool = pool::new<B_A, B_B, OracleQuoter, LpType>(
        registry,
        swap_fee_bps,
        quoter,
        meta_b_a,
        meta_b_b,
        meta_lp,
        lp_treasury,
        ctx,
    );

    let result = NewOracleQuoter {
        pool_id: object::id(&pool),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        
    };

    emit_event(result);

    return pool
}

public fun swap<P, A, B, B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoter, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    coin_a: &mut Coin<B_A>,
    coin_b: &mut Coin<B_B>,
    a2b: bool,
    amount_in: u64,
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
    pool: &Pool<B_A, B_B, OracleQuoter, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
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

    let mut amount_out = if (a2b) {
        quote_swap_impl(
            amount_in,
            decimals_a,
            decimals_b,
            price_a,
            price_b,
            btoken_ratio_a,
            btoken_ratio_b,
        )
    } else {
        quote_swap_impl(
            amount_in,
            decimals_b,
            decimals_a,
            price_b,
            price_a,
            btoken_ratio_b,
            btoken_ratio_a,
        )
    };

    amount_out = if (a2b) {
        if (amount_out >= pool.balance_amount_b()) {
            0
        } else {
            amount_out
        }
    } else {
        if (amount_out >= pool.balance_amount_a()) {
            0
        } else {
            amount_out
        }
    };

    pool.get_quote(amount_in, amount_out, a2b)
}
public(package) fun quote_swap_impl(
    btoken_amount_in: u64,
    decimals_in: u8,
    decimals_out: u8,
    price_in: Decimal,
    price_out: Decimal,
    btoken_ratio_in: Decimal,
    btoken_ratio_out: Decimal,
): u64 {
    /* More intuitive calculation here:
        // 1. convert from btoken_in to regular token_in
        let amount_in = decimal::from(btoken_amount_in).mul(btoken_ratio_in);

        // 2. convert to dollar value
        let dollar_value = amount_in
            .div(decimal::from(10u64.pow(decimals_in as u8)))
            .mul(price_in);

        // 3. convert to token_out
        let amount_out = dollar_value
            .div(price_out)
            .mul(decimal::from(10u64.pow(decimals_out as u8)));

        // 4. convert to btoken_out
        let btoken_amount_out = amount_out
            .div(btoken_ratio_out)
            .floor();

        btoken_amount_out
    */

    let btoken_amount_out_unshifted= decimal::from(btoken_amount_in)
        .mul(btoken_ratio_in)
        .mul(price_in)
        .div(price_out)
        .div(btoken_ratio_out);

    if (decimals_in > decimals_out) {
        btoken_amount_out_unshifted.div(decimal::from(10u64.pow((decimals_in - decimals_out) as u8))).floor()
    } else {
        btoken_amount_out_unshifted.mul(decimal::from(10u64.pow((decimals_out - decimals_in) as u8))).floor()
    }
}

fun oracle_decimal_to_decimal(price: OracleDecimal): Decimal {
    if (price.is_expo_negative()) {
        decimal::from_u128(price.base()).div(decimal::from(10u64.pow(price.expo() as u8)))
    } else {
        decimal::from_u128(price.base()).mul(decimal::from(10u64.pow(price.expo() as u8)))
    }
}

// ===== Events =====

public struct NewOracleQuoter has copy, drop, store {
    pool_id: ID,
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,
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
fun test_quote_swap_impl() {
    use sui::test_utils::assert_eq;

    // swap 10 bsui for usdc. how much should i get?
    // 10 bsui => 30 bsui => $90 => 90 usdc => 45 busdc
    let amount_out = quote_swap_impl(
        10_000_000_001, 
        9, 
        6, 
        decimal::from(3), 
        decimal::from(1), 
        decimal::from(3),
        decimal::from(2),
    );

    assert_eq(amount_out, 45_000_000);

    // swap 12 busdc for bsui. how much should i get?
    // 12 busdc => 24 usdc => $24 => 8 sui => 8/3 bsui
    let amount_out = quote_swap_impl(
        12_000_000, 
        6, 
        9, 
        decimal::from(1), 
        decimal::from(3), 
        decimal::from(2), 
        decimal::from(3), 
    );

    assert_eq(amount_out, 2_666_666_666);
}