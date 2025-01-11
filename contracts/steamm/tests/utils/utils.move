#[test_only]
module steamm::test_utils;

use pyth::i64;
use pyth::price;
use pyth::price_feed;
use pyth::price_identifier;
use pyth::price_info::{Self, PriceInfoObject};
use std::type_name;
use steamm::bank::{Self, Bank, BToken};
use steamm::cpmm::{Self, CpQuoter};
use steamm::pool::Pool;
use steamm::registry;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::sui::SUI;
use sui::test_scenario::{Self, ctx, Scenario};
use sui::test_utils::destroy;
use suilend::lending_market_tests::{Self, LENDING_MARKET};
use suilend::reserve_config;
use suilend::test_sui::TEST_SUI;
use suilend::test_usdc::TEST_USDC;

public fun e9(amt: u64): u64 {
    1_000_000_000 * amt
}

public struct PoolWit has drop {}
public struct COIN has drop {}

#[test_only]
public macro fun assert_eq_approx($a: u64, $b: u64, $tolerance_bps: u64) {
    let diff = if ($a > $b) { $a - $b } else { $b - $a };
    let max = if ($a > $b) { $a } else { $b };
    let tolerance = (max * $tolerance_bps) / 10000;
    assert!(diff <= tolerance, 0);
}

#[test_only]
public fun reserve_args(scenario: &mut Scenario): Bag {
    let ctx = test_scenario::ctx(scenario);

    let usdc_config = {
        let config = reserve_config::default_reserve_config();
        let mut builder = reserve_config::from(&config, ctx);
        reserve_config::set_open_ltv_pct(&mut builder, 50);
        reserve_config::set_close_ltv_pct(&mut builder, 50);
        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
        sui::test_utils::destroy(config);

        reserve_config::build(builder, ctx)
    };

    let sui_config = {
        let config = reserve_config::default_reserve_config();
        let mut builder = reserve_config::from(
            &config,
            ctx,
        );

        destroy(config);

        // reserve_config::set_borrow_fee_bps(&mut builder, 500);
        // reserve_config::set_interest_rate_aprs(&mut builder, vector[315360000, 315360000]);
        reserve_config::set_interest_rate_aprs(&mut builder, vector[500, 500]);
        reserve_config::build(builder, ctx)
    };

    let mut bag = bag::new(test_scenario::ctx(scenario));

    bag::add(
        &mut bag,
        type_name::get<TEST_USDC>(),
        lending_market_tests::new_args(100 * 10_000, usdc_config),
    );

    bag::add(
        &mut bag,
        type_name::get<TEST_SUI>(),
        lending_market_tests::new_args(100 * 10_000, sui_config),
    );

    bag
}

#[test_only]
public fun reserve_args_2(scenario: &mut Scenario): Bag {
    let mut bag = bag::new(test_scenario::ctx(scenario));

    let reserve_args = {
        let config = reserve_config::default_reserve_config();
        let mut builder = reserve_config::from(&config, test_scenario::ctx(scenario));
        reserve_config::set_open_ltv_pct(&mut builder, 50);
        reserve_config::set_close_ltv_pct(&mut builder, 50);
        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
        sui::test_utils::destroy(config);
        let config = reserve_config::build(builder, test_scenario::ctx(scenario));

        lending_market_tests::new_args(100 * 1_000_000, config)
    };

    bag::add(
        &mut bag,
        type_name::get<TEST_USDC>(),
        reserve_args,
    );

    let reserve_args = {
        let config = reserve_config::default_reserve_config();
        lending_market_tests::new_args(100 * 1_000_000_000, config)
    };

    bag::add(
        &mut bag,
        type_name::get<TEST_SUI>(),
        reserve_args,
    );

    bag
}

#[test_only]
public fun new_for_testing(
    reserve_a: u64,
    reserve_b: u64,
    lp_supply: u64,
    swap_fee_bps: u64,
): (
    Pool<BToken<LENDING_MARKET, TEST_SUI>, BToken<LENDING_MARKET, TEST_USDC>, CpQuoter<PoolWit>>,
    Bank<LENDING_MARKET, TEST_SUI>,
    Bank<LENDING_MARKET, COIN>,
) {
    let mut scenario = test_scenario::begin(@0x0);
    let ctx = ctx(&mut scenario);

    let mut registry = registry::init_for_testing(ctx);
    let (treasury_cap_sui, meta_sui) = suilend::test_sui::create_currency(ctx);
    let (treasury_cap_sui, meta_sui) = steamm::lp_coin::create_currency(ctx);

    let (mut pool, pool_cap) = cpmm::new<
        BToken<LENDING_MARKET, TEST_SUI>,
        BToken<LENDING_MARKET, TEST_USDC>,
        PoolWit,
    >(

        &mut registry,
        swap_fee_bps,
        ctx,
    );

    let bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    let bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    pool.mut_reserve_a(reserve_a, true);
    pool.mut_reserve_b(reserve_b, true);
    let lp = pool.lp_supply_mut_for_testing().increase_supply(lp_supply);

    destroy(registry);
    destroy(pool_cap);
    destroy(lp);

    test_scenario::end(scenario);

    (pool, bank_a, bank_b)
}

#[test_only]
public fun set_clock_time(clock: &mut Clock) {
    clock.set_for_testing(1704067200000); //2024-01-01 00:00:00
}

#[test_only]
public fun get_price_info(
    idx: u8,
    price_: u64,
    exponent: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): PriceInfoObject {
    let mut v = vector::empty<u8>();
    vector::push_back(&mut v, idx);

    let mut i = 1;
    while (i < 32) {
        vector::push_back(&mut v, 0);
        i = i + 1;
    };

    let price_info_obj = price_info::new_price_info_object_for_testing(
        price_info::new_price_info(
            0,
            0,
            price_feed::new(
                price_identifier::from_byte_vec(v),
                price::new(
                    i64::new(price_, false),
                    0,
                    i64::new(exponent, false),
                    clock.timestamp_ms(),
                ),
                price::new(
                    i64::new(price_, false),
                    0,
                    i64::new(exponent, false),
                    clock.timestamp_ms(),
                ),
            ),
        ),
        ctx,
    );

    price_info_obj
}

#[test_only]
public fun zero_price_info(idx: u8, clock: &Clock, ctx: &mut TxContext): PriceInfoObject {
    let mut v = vector::empty<u8>();
    vector::push_back(&mut v, idx);

    let mut i = 1;
    while (i < 32) {
        vector::push_back(&mut v, 0);
        i = i + 1;
    };

    let price_info_obj = price_info::new_price_info_object_for_testing(
        price_info::new_price_info(
            0,
            0,
            price_feed::new(
                price_identifier::from_byte_vec(v),
                price::new(
                    i64::new(0, false),
                    0,
                    i64::new(0, false),
                    clock.timestamp_ms(),
                ),
                price::new(
                    i64::new(0, false),
                    0,
                    i64::new(0, false),
                    clock.timestamp_ms(),
                ),
            ),
        ),
        ctx,
    );

    price_info_obj
}

public fun update_pyth_price(
    price_info_obj: &mut PriceInfoObject,
    price: u64,
    expo: u8,
    clock: &Clock,
) {
    let price_info = price_info::get_price_info_from_price_info_object(price_info_obj);

    let price = price::new(
        i64::new(price, false),
        0,
        i64::new((expo as u64), false),
        clock.timestamp_ms() / 1000,
    );

    price_info::update_price_info_object_for_testing(
        price_info_obj,
        &price_info::new_price_info(
            0,
            0,
            price_feed::new(
                price_info::get_price_identifier(&price_info),
                price,
                price,
            ),
        ),
    );
}

public fun bump_clock(clock: &mut Clock, seconds: u64) {
    let new_ts = clock.timestamp_ms() + (1000 * seconds); // 1 second * X
    clock.set_for_testing(new_ts);
}
