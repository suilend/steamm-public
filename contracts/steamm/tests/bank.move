module steamm::bank_tests;

use std::option::some;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::bank::{Self, Bank};
use steamm::bank_math;
use steamm::global_admin;
use steamm::test_utils::{Self, reserve_args};
use sui::coin;
use sui::test_scenario::{Self, Scenario, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use suilend::test_usdc::TEST_USDC;

#[test_only]
fun setup_bank(scenario: &mut Scenario): Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC> {
    let (
        pool,
        bank_a,
        bank_b,
        lending_market,
        lend_cap,
        prices,
        bag,
        clock,
    ) = test_utils::test_setup_dummy(0, scenario);

    destroy(pool);
    destroy(bank_b);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    bank_a
}

#[test]
fun test_create_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    // Create amm bank
    let bank = setup_bank(&mut scenario);

    destroy(bank);
    destroy(scenario);
}

#[test]
fun test_init_lending() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::ELendingAlreadyActive)]
fun test_fail_init_lending_twice() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeAboveHundredPercent)]
fun test_invalid_utilisation_liquidity_above_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        10_001, // utilisation_bps
        1_000, // buffer
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeBelowZeroPercent)]
fun test_invalid_target_liquidity_below_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        1_000, // utilisation_bps
        1_001, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = bank_math::EEmptyBank)]
fun test_fail_assert_empty_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_rate
        500, // utilisation_buffer
        ctx(&mut scenario),
    );

    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_bank_rebalance_deploy() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(funds_deployed, 0);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 0);

    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_rebalance_recall() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    bank.set_utilisation_bps_for_testing(0, 0);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(funds_deployed, 0);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 0);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_prepare_bank_for_pending_withdraw() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );
    assert!(bank.funds_available().value() == 50 * 1_000_000, 0);
    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    bank.prepare_for_pending_withdraw(
        &mut lending_market,
        20 * 1_000_000,
        &clock,
        ctx(&mut scenario),
    );
    let usdc = bank.withdraw_for_testing(20 * 1_000_000);

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert!(bank.funds_available().value() == 40 * 1_000_000, 0);
    assert_eq(funds_deployed, 40 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 80 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(usdc);
    destroy(scenario);
}

#[test]
fun test_bank_withdraw_except_minimum_liquidity() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    let mut coin = coin::mint_for_testing<TEST_USDC>(500_000, ctx(&mut scenario));
    let mut btoken = bank.mint_btokens(&mut lending_market, &mut coin, 500_000, &clock, ctx(&mut scenario));
    destroy(coin);

    let btoken_value = btoken.value();
    let coin = bank.burn_btokens(
        &mut lending_market,
        &mut btoken,
        btoken_value,
        &clock,
        ctx(&mut scenario),
    );

    assert_eq(coin.value(), 500_000 - bank::minimum_liquidity());

    destroy(coin);
    destroy(btoken);
    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}