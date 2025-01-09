module steamm::bank_tests;

use steamm::bank;
use steamm::bank_math;
use steamm::global_admin;
use steamm::registry;
use steamm::test_utils::{COIN, reserve_args};
use sui::test_scenario::{Self, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use suilend::test_usdc::TEST_USDC;

public struct FAKE_LENDING has drop {}

#[test]
fun test_create_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));

    // Create amm bank
    let bank = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

    destroy(bank);
    destroy(registry);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = registry::EDuplicatedBankType)]
fun test_fail_create_duplicate_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));

    // Create bank
    let bank_1 = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
    let bank_2 = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

    destroy(bank_1);
    destroy(bank_2);
    destroy(registry);
    destroy(scenario);
}

#[test]
fun test_init_lending() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));
    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
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
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::ELendingAlreadyActive)]
fun test_fail_init_lending_twice() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));
    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
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
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeAboveHundredPercent)]
fun test_invalid_utilisation_liquidity_above_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(
        &mut registry,
        ctx(&mut scenario),
    );

    bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
        &global_admin,
        &mut lending_market,
        10_001, // utilisation_bps
        1_000, // buffer
        ctx(&mut scenario),
    );

    destroy(bank_a);
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeBelowHundredPercent)]
fun test_invalid_target_liquidity_below_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(
        &mut registry,
        ctx(&mut scenario),
    );

    bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
        &global_admin,
        &mut lending_market,
        1_000, // utilisation_bps
        1_001, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(bank_a);
    destroy(registry);
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

    let mut registry = registry::init_for_testing(ctx(&mut scenario));

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
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
    destroy(registry);
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

    let mut registry = registry::init_for_testing(ctx(&mut scenario));
    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 0);

    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 50 * 1_000_000);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_rebalance_recall() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));
    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
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

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 50 * 1_000_000);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 5_000);

    bank.set_utilisation_bps_for_testing(0, 0);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 0);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_prepare_bank_for_pending_withdraw() {
    let mut scenario = test_scenario::begin(@0x0);

    let mut registry = registry::init_for_testing(ctx(&mut scenario));
    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create bank
    let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending<LENDING_MARKET, TEST_USDC>(
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
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 50 * 1_000_000);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 5_000);

    bank.prepare_for_pending_withdraw(
        &mut lending_market,
        20 * 1_000_000,
        &clock,
        ctx(&mut scenario),
    );
    let usdc = bank.withdraw_for_testing(20 * 1_000_000);

    assert!(bank.funds_available().value() == 40 * 1_000_000, 0);
    assert_eq(bank.funds_deployed(&lending_market, &clock).floor(), 40 * 1_000_000);
    assert_eq(bank.total_funds(&lending_market, &clock).floor(), 80 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(&lending_market, &clock), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(registry);
    destroy(global_admin);
    destroy(lending_market);
    destroy(usdc);
    destroy(scenario);
}
