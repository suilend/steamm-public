#[test_only]
module steamm::test_utils;

use pyth::i64;
use pyth::price;
use pyth::price_feed;
use pyth::price_identifier;
use pyth::price_info::{Self, PriceInfoObject};
use std::ascii;
use std::string::utf8;
use std::type_name;
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::bank::{Self, Bank};
use steamm::cpmm::{Self, CpQuoter};
use steamm::dummy_quoter::{Self, DummyQuoter};
use steamm::lp_usdc_sui::LP_USDC_SUI;
use steamm::pool::Pool;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::coin::{CoinMetadata, TreasuryCap};
use sui::test_scenario::{Self, ctx, Scenario};
use sui::test_utils::destroy;
use suilend::lending_market_tests::{Self, LENDING_MARKET};
use suilend::reserve_config;
use suilend::test_sui::{Self, TEST_SUI};
use suilend::test_usdc::{Self, TEST_USDC};

public fun e9(amt: u64): u64 {
    1_000_000_000 * amt
}

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
public fun test_setup_cpmm(
    swap_fee_bps: u64,
    offset: u64,
): (
    Pool<B_TEST_USDC, B_TEST_SUI, CpQuoter, LP_USDC_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
) {
    let mut scenario = test_scenario::begin(@0x0);

    let (treasury_cap_sui, meta_sui, treasury_cap_usdc, meta_usdc) = init_currencies(&mut scenario);

    let ctx = ctx(&mut scenario);
    let (treasury_cap_lp, mut meta_lp_usdc_sui) = steamm::lp_usdc_sui::create_currency(ctx);
    let (treasury_cap_b_usdc, mut meta_b_usdc) = steamm::b_test_usdc::create_currency(ctx);
    let (treasury_cap_b_sui, mut meta_b_sui) = steamm::b_test_sui::create_currency(ctx);

    // Create banks
    let bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>(
        &meta_usdc,
        &mut meta_b_usdc,
        treasury_cap_b_usdc,
        ctx,
    );
    let bank_b = bank::create_bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>(
        &meta_sui,
        &mut meta_b_sui,
        treasury_cap_b_sui,
        ctx,
    );

    // Create pool

    let (pool, pool_cap) = cpmm::new<B_TEST_USDC, B_TEST_SUI, LP_USDC_SUI>(
        &meta_b_usdc,
        &meta_b_sui,
        &mut meta_lp_usdc_sui,
        treasury_cap_lp,
        swap_fee_bps,
        offset,
        ctx,
    );

    destroy(treasury_cap_sui);
    destroy(treasury_cap_usdc);
    destroy(meta_lp_usdc_sui);
    destroy(meta_b_sui);
    destroy(meta_b_usdc);
    destroy(meta_sui);
    destroy(meta_usdc);
    destroy(pool_cap);

    test_scenario::end(scenario);

    (pool, bank_a, bank_b)
}

#[test_only]
public fun test_setup_dummy(
    swap_fee_bps: u64,
): (
    Pool<B_TEST_USDC, B_TEST_SUI, DummyQuoter, LP_USDC_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
) {
    let mut scenario = test_scenario::begin(@0x0);

    let (treasury_cap_sui, meta_sui, treasury_cap_usdc, meta_usdc) = init_currencies(&mut scenario);

    let ctx = ctx(&mut scenario);
    let (treasury_cap_lp, mut meta_lp_usdc_sui) = steamm::lp_usdc_sui::create_currency(ctx);
    let (treasury_cap_b_usdc, mut meta_b_usdc) = steamm::b_test_usdc::create_currency(ctx);
    let (treasury_cap_b_sui, mut meta_b_sui) = steamm::b_test_sui::create_currency(ctx);

    // Create banks
    let bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>(
        &meta_usdc,
        &mut meta_b_usdc,
        treasury_cap_b_usdc,
        ctx,
    );
    let bank_b = bank::create_bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>(
        &meta_sui,
        &mut meta_b_sui,
        treasury_cap_b_sui,
        ctx,
    );

    // Create pool

    let (pool, pool_cap) = dummy_quoter::new<B_TEST_USDC, B_TEST_SUI, LP_USDC_SUI>(
        &meta_b_usdc,
        &meta_b_sui,
        &mut meta_lp_usdc_sui,
        treasury_cap_lp,
        swap_fee_bps,
        ctx,
    );

    destroy(treasury_cap_sui);
    destroy(treasury_cap_usdc);
    destroy(meta_lp_usdc_sui);
    destroy(meta_b_sui);
    destroy(meta_b_usdc);
    destroy(meta_sui);
    destroy(meta_usdc);
    destroy(pool_cap);

    test_scenario::end(scenario);

    (pool, bank_a, bank_b)
}

#[test_only]
public fun test_setup_dummy_no_fees(): (
    Pool<B_TEST_USDC, B_TEST_SUI, DummyQuoter, LP_USDC_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
) {
    let (mut pool, bank_a, bank_b) = test_setup_dummy(0);

    pool.no_protocol_fees_for_testing();
    pool.no_redemption_fees_for_testing();

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

public fun init_currencies(
    scenario: &mut Scenario,
): (
    TreasuryCap<TEST_SUI>,
    CoinMetadata<TEST_SUI>,
    TreasuryCap<TEST_USDC>,
    CoinMetadata<TEST_USDC>,
) {
    // Setup base currencies
    let (sui_cap, mut sui_meta) = test_sui::create_currency(ctx(scenario));
    let (usdc_cap, mut usdc_meta) = test_usdc::create_currency(ctx(scenario));

    sui_cap.update_name(&mut sui_meta, utf8(b"Test SUI"));
    usdc_cap.update_name(&mut usdc_meta, utf8(b"Test USDC"));

    sui_cap.update_symbol(&mut sui_meta, ascii::string(b"TEST_SUI"));
    usdc_cap.update_symbol(&mut usdc_meta, ascii::string(b"TEST_USDC"));

    (sui_cap, sui_meta, usdc_cap, usdc_meta)
}
