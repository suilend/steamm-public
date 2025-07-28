#[test_only]
module steamm::steamm_tests;

use steamm::registry;
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::cpmm::{Self, CpQuoter};
use steamm::dummy_quoter::{swap as dummy_swap, quote_swap, DummyQuoter};
use steamm::global_admin;
use steamm::lp_usdc_sui::LP_USDC_SUI;
use steamm::pool::{Self, Pool, minimum_liquidity};
use steamm::pool_math;
use steamm::quote;
use steamm::bank::Bank;
use steamm::fee_crank::crank_fees;
use steamm::dummy_quoter;
use steamm::test_utils::{test_setup_dummy, test_setup_cpmm, e9, reserve_args};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self, Scenario, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use suilend::test_sui::TEST_SUI;
use suilend::test_usdc::TEST_USDC;

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;
const LP_PROVIDER: address = @0x12;
const TRADER: address = @0x13;

#[test_only]
fun test_setup_dummy_(
    swap_fee_bps: u64,
    scenario: &mut Scenario,
): (
    Pool<B_TEST_USDC, B_TEST_SUI, DummyQuoter, LP_USDC_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
) {
    let (pool, bank_a, bank_b, lending_market, lend_cap, prices, bag, clock) = test_setup_dummy(
        swap_fee_bps,
        scenario,
    );

    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    (pool, bank_a, bank_b)
}

#[test_only]
fun test_setup_dummy_no_banks(
    swap_fee_bps: u64,
    scenario: &mut Scenario,
): Pool<B_TEST_USDC, B_TEST_SUI, DummyQuoter, LP_USDC_SUI> {
    let (pool, bank_a, bank_b, lending_market, lend_cap, prices, bag, clock) = test_setup_dummy(
        swap_fee_bps,
        scenario,
    );

    destroy(bank_a);
    destroy(bank_b);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    pool
}

#[test_only]
fun test_setup_cpmm_no_banks(
    swap_fee_bps: u64,
    offset: u64,
    scenario: &mut Scenario,
): Pool<B_TEST_USDC, B_TEST_SUI, CpQuoter, LP_USDC_SUI> {
    let (pool, bank_a, bank_b, lending_market, lend_cap, prices, bag, clock) = test_setup_cpmm(
        swap_fee_bps,
        offset,
        scenario,
    );

    destroy(bank_a);
    destroy(bank_b);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    pool
}

#[test]
fun test_steamm_deposit_redeem_swap() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(500_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(1_000),
        e9(500_000),
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    assert_eq(cpmm::k_external(&pool, 0), 500000000000000000000000000);
    assert_eq(pool.lp_supply_val(), 22360679774997);
    assert_eq(reserve_a, e9(1_000));
    assert_eq(reserve_b, e9(500_000));
    assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Deposit liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(10), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(10), ctx);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(10), // max_a
        e9(10), // max_b
        ctx,
    );

    assert_eq(coin_a.value(), e9(10) - 20_000_000);
    assert_eq(coin_b.value(), 0);
    assert_eq(lp_coins_2.value(), 447213595);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_1);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins_2,
        0,
        0,
        ctx,
    );

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 20_000_000 - 1); // -1 for the rounddown
    assert_eq(coin_b.value(), e9(10) - 12); // double rounddown: inital lp tokens minted + redeed

    let (reserve_a, reserve_b) = pool.balance_amounts();

    let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_2);

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        e9(200),
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.amount_out(), 198000000000);
    assert_eq(swap_result.pool_fees(), 1600000000);
    assert_eq(swap_result.protocol_fees(), 400000000);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_full_amm_cycle() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        500_000,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    assert_eq(cpmm::k_external(&pool, 0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Deposit liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000, // max_a
        500_000, // max_b
        ctx,
    );

    assert_eq(coin_a.value(), 0);
    assert_eq(coin_b.value(), 0);
    assert_eq(lp_coins_2.value(), 500_000);
    assert_eq(pool.lp_supply_val(), 500_000 + 500_000);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_1);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins_2,
        0,
        0,
        ctx,
    );

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 500_000);
    assert_eq(coin_b.value(), 500_000);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_2);

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.pool_fees(), 400);
    assert_eq(swap_result.protocol_fees(), 100);
    assert_eq(swap_result.amount_out(), 49_500);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem remaining liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins,
        0,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 548_900);
    assert_eq(coin_b.value(), 449_499);
    assert_eq(reserve_a, 1_100);
    assert_eq(reserve_b, 901);
    assert_eq(pool.lp_supply_val(), minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    assert_eq(pool.trading_data().protocol_fees_a(), 0);
    assert_eq(pool.trading_data().protocol_fees_b(), 100);
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 400);

    assert_eq(pool.trading_data().total_swap_a_in_amount(), 50_000);
    assert_eq(pool.trading_data().total_swap_b_out_amount(), 49_500);
    assert_eq(pool.trading_data().total_swap_a_out_amount(), 0);
    assert_eq(pool.trading_data().total_swap_b_in_amount(), 0);

    destroy(pool);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_collect_protocol_fee_from_bank() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_(100, &mut scenario);
    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));
    let global_admin = steamm::global_admin::init_for_testing(scenario.ctx());
    let ctx = ctx(&mut scenario);

    let mut coin_a_ = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b_ = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let coin_a_value = coin_a_.value();
    let mut coin_a = bank_a.mint_btoken(&lending_market, &mut coin_a_, coin_a_value, &clock, ctx);
    destroy(coin_a_);

    let coin_b_value = coin_b_.value();
    let mut coin_b = bank_b.mint_btoken(&lending_market, &mut coin_b_, coin_b_value, &clock, ctx);
    destroy(coin_b_);

    // let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    // let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        500_000,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    assert_eq(cpmm::k_external(&pool, 0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Deposit liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000, // max_a
        500_000, // max_b
        ctx,
    );

    assert_eq(coin_a.value(), 0);
    assert_eq(coin_b.value(), 0);
    assert_eq(lp_coins_2.value(), 500_000);
    assert_eq(pool.lp_supply_val(), 500_000 + 500_000);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_1);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins_2,
        0,
        0,
        ctx,
    );

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 500_000);
    assert_eq(coin_b.value(), 500_000);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_2);

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.pool_fees(), 400);
    assert_eq(swap_result.protocol_fees(), 100);
    assert_eq(swap_result.amount_out(), 49_500);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem remaining liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins,
        0,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 548_900);
    assert_eq(coin_b.value(), 449_499);
    assert_eq(reserve_a, 1_100);
    assert_eq(reserve_b, 901);
    assert_eq(pool.lp_supply_val(), minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    // Collect Protocol fees
    // set two reward receivers, 1/3 and 2/3
    let receiver_1 = @0x1;
    let receiver_2 = @0x2;
    registry.set_fee_receivers(
        &global_admin,
        vector[receiver_1, receiver_2],
        vector[1,          1],
    );
    
    crank_fees(&mut pool, &mut bank_a, &mut bank_b);
    bank_a.claim_fees(&lending_market, &registry, &clock, ctx);
    bank_b.claim_fees(&lending_market, &registry, &clock, scenario.ctx());

    scenario.next_tx(@0x0);

    let reward_coin_for_receiver_1: Coin<TEST_SUI> = scenario.take_from_address(receiver_1);
    assert_eq(reward_coin_for_receiver_1.value(), 50);

    let reward_coin_for_receiver_2: Coin<TEST_SUI> = scenario.take_from_address(receiver_2);
    assert_eq(reward_coin_for_receiver_2.value(), 50);

    assert_eq(pool.trading_data().protocol_fees_a(), 0);
    assert_eq(pool.trading_data().protocol_fees_b(), 100);
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 400);

    assert_eq(pool.trading_data().total_swap_a_in_amount(), 50_000);
    assert_eq(pool.trading_data().total_swap_b_out_amount(), 49_500);
    assert_eq(pool.trading_data().total_swap_a_out_amount(), 0);
    assert_eq(pool.trading_data().total_swap_b_in_amount(), 0);

    // destroy(coin_a);
    // destroy(coin_b);
    destroy(reward_coin_for_receiver_1);
    destroy(reward_coin_for_receiver_2);
    destroy(pool);
    destroy(global_admin);
    destroy(registry);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    destroy(bank_a);
    destroy(bank_b);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::ESwapExceedsSlippage)]
fun test_fail_swap_slippage() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(500_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(1_000),
        e9(500_000),
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(cpmm::k_external(&pool, 0), 500000000000000000000000000);
    assert_eq(pool.lp_supply_val(), 22360679774997);
    assert_eq(reserve_a, e9(1_000));
    assert_eq(reserve_b, e9(500_000));
    assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = quote_swap(
        &pool,
        e9(200),
        true, // a2b
    );

    let _ = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        e9(200),
        swap_result.amount_out() + 1,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EInsufficientFunds)]
fun test_fail_swap_insufficient_funds() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(500_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(1_000),
        e9(500_000),
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(cpmm::k_external(&pool, 0), 500000000000000000000000000);
    assert_eq(pool.lp_supply_val(), 22360679774997);
    assert_eq(reserve_a, e9(1_000));
    assert_eq(reserve_b, e9(500_000));
    assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(199), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let _ = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        e9(200),
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool_math::ERedeemSlippageAExceeded)]
fun test_fail_redeem_slippage_a() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(500_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(1_000),
        e9(500_000),
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    assert_eq(cpmm::k_external(&pool, 0), 500000000000000000000000000);
    assert_eq(pool.lp_supply_val(), 22360679774997);
    assert_eq(reserve_a, e9(1_000));
    assert_eq(reserve_b, e9(500_000));
    assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Deposit liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(10), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(10), ctx);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(10), // max_a
        e9(10), // max_b
        ctx,
    );

    assert_eq(coin_a.value(), e9(10) - 20_000_000);
    assert_eq(coin_b.value(), 0);
    assert_eq(lp_coins_2.value(), 447213595);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_1);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let redeem_result = pool.quote_redeem(lp_coins_2.value());

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins_2,
        redeem_result.withdraw_a() + 1,
        redeem_result.withdraw_b() + 1,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool_math::ERedeemSlippageBExceeded)]
fun test_fail_redeem_slippage_b() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(500_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(1_000),
        e9(1_000),
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    assert_eq(cpmm::k_external(&pool, 0), 1000000000000000000000000);
    assert_eq(pool.lp_supply_val(), 1000000000000);
    assert_eq(reserve_a, e9(1_000));
    assert_eq(reserve_b, e9(1_000));
    assert_eq(lp_coins.value(), 1000000000000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    destroy(coin_a);
    destroy(coin_b);

    // Deposit liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(10), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(10), ctx);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(10), // max_a
        e9(10), // max_b
        ctx,
    );

    assert_eq(coin_a.value(), 0);
    assert_eq(coin_b.value(), 0);
    assert_eq(lp_coins_2.value(), 10000000000);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    assert_eq(reserve_ratio_0, reserve_ratio_1);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let redeem_result = pool.quote_redeem(lp_coins_2.value());

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins_2,
        redeem_result.withdraw_a(),
        redeem_result.withdraw_b() + 1,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidSwapFeeBpsType)]
fun test_fail_fee_above_100() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let pool = test_setup_dummy_no_banks(10_000 + 1, &mut scenario);

    destroy(pool);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidSwapFeeBpsType)]
fun test_fail_invalid_fee_type() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let pool = test_setup_dummy_no_banks(31, &mut scenario);

    destroy(pool);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_valid_fee_types() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    destroy(test_setup_dummy_no_banks(1, &mut scenario));
    destroy(test_setup_dummy_no_banks(5, &mut scenario));
    destroy(test_setup_dummy_no_banks(30, &mut scenario));
    destroy(test_setup_dummy_no_banks(100, &mut scenario));
    destroy(test_setup_dummy_no_banks(200, &mut scenario));

    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_steamm_fees() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);

    let mut pool_2 = test_setup_dummy_no_banks(100, &mut scenario);

    let ctx = ctx(&mut scenario);
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200_000_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(200_000_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000_000),
        e9(100_000_000),
        ctx,
    );

    let (lp_coins_2, _) = pool_2.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000_000),
        e9(100_000_000),
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // Swap first pool
    let expected_pool_fees = 8_000_000_000_000;
    let expected_protocol_fees = 2_000_000_000_000;

    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = dummy_swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        e9(1_000_000),
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.pool_fees(), expected_pool_fees);
    assert_eq(swap_result.protocol_fees(), expected_protocol_fees);

    destroy(coin_a);
    destroy(coin_b);

    // Swap second pool
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let mut len = 1000;

    let mut acc_protocol_fees = 0;
    let mut acc_pool_fees = 0;

    while (len > 0) {
        test_scenario::next_tx(&mut scenario, TRADER);
        let swap_result = dummy_swap(
            &mut pool_2,
            &mut coin_a,
            &mut coin_b,
            true, // a2b
            e9(10_00),
            0,
            scenario.ctx(),
        );

        acc_protocol_fees = acc_protocol_fees + swap_result.protocol_fees();
        acc_pool_fees = acc_pool_fees + swap_result.pool_fees();

        len = len - 1;
    };

    // Assert that cumulative fees from small swaps are not smaller
    // than a bigger swap
    assert!(acc_protocol_fees >= expected_protocol_fees, 0);
    assert!(acc_pool_fees >= expected_pool_fees, 0);

    destroy(coin_a);
    destroy(coin_b);

    // Redeem liquidity
    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, _) = pool.redeem_liquidity(
        lp_coins,
        0,
        0,
        ctx,
    );

    let (coin_a_2, coin_b_2, _) = pool_2.redeem_liquidity(
        lp_coins_2,
        0,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(coin_a_2);
    destroy(coin_b_2);
    destroy(pool);
    destroy(pool_2);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
fun test_output_exceeds_liquidity() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let mut pool = test_setup_dummy_no_banks(100, &mut scenario);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        500_000,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let quote = quote::quote_for_testing(
        100,
        500_001, // amount above available reserve
        0,
        0,
        true,
    );

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(50_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    pool::swap(
        &mut pool,
        &mut coin_a,
        &mut coin_b,
        quote,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_one_sided_deposit() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_cpmm_no_banks(100, 20, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 0);
    assert_eq(pool.cpmm_k(), 500_000 * 20);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_one_sided_deposit_twice() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_cpmm_no_banks(100, 20, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 0);
    assert_eq(pool.cpmm_k(), 500_000 * 20);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_one_sided_deposit_redeem() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pool = test_setup_cpmm_no_banks(100, 20, &mut scenario);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(500_000, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert!(reserve_a == 500_000, 0);
    assert!(reserve_b == 0, 0);
    assert!(pool.cpmm_k() == 500000 * 20, 0);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    let ctx = ctx(&mut scenario);

    let (coin_a, coin_b, redeem_result) = pool.redeem_liquidity(
        lp_coins,
        0,
        0,
        ctx,
    );

    assert_eq(redeem_result.burn_lp(), 499000);
    assert_eq(pool.balance_amount_a(), 1000);
    assert_eq(pool.balance_amount_b(), 0);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::ETypeAandBDuplicated)]
fun test_fail_create_pool_duplicated_type() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let ctx = ctx(&mut scenario);
    let (treasury_cap_lp, mut meta_lp_usdc_sui) = steamm::lp_usdc_sui::create_currency(ctx);
    let (treasury_cap_b_usdc, meta_b_usdc) = steamm::b_test_usdc::create_currency(ctx);

    // Create pool
    let mut registry = registry::init_for_testing(ctx);

    let pool = dummy_quoter::new<B_TEST_USDC, B_TEST_USDC, LP_USDC_SUI>(
        &mut registry,
        100,
        &meta_b_usdc,
        &meta_b_usdc,
        &mut meta_lp_usdc_sui,
        treasury_cap_lp,
        ctx,
    );

    destroy(pool);
    destroy(registry);
    destroy(treasury_cap_b_usdc);
    destroy(meta_lp_usdc_sui);
    destroy(meta_b_usdc);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}