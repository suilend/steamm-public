#[test_only]
module steamm::cpmm_tests;

use steamm::cpmm::{CpQuoter};
use steamm::global_admin;
use steamm::pool::{Self, Pool, minimum_liquidity};
use steamm::test_utils::{test_setup_cpmm, reserve_args, e9};
use sui::clock::Clock;
use sui::coin;
use sui::test_scenario::{Self, Scenario, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market::{LendingMarketOwnerCap, LendingMarket};
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use steamm::lp_usdc_sui::{LP_USDC_SUI};
use steamm::b_test_sui::{B_TEST_SUI};
use steamm::b_test_usdc::{B_TEST_USDC};

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;
const LP_PROVIDER: address = @0x12;
const TRADER: address = @0x13;

#[test_only]
public fun setup(
    fee: u64,
    offset: u64,
    scenario: &mut Scenario,
): (
    Clock,
    LendingMarketOwnerCap<LENDING_MARKET>,
    LendingMarket<LENDING_MARKET>,
    Pool<B_TEST_USDC, B_TEST_SUI, CpQuoter, LP_USDC_SUI>,
) {
    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(scenario),
        scenario,
    ).destruct_state();

    let pool = setup_pool(fee, offset);
    destroy(bag);
    destroy(prices);

    (clock, lend_cap, lending_market, pool)
}

#[test_only]
public fun setup_pool(
    fee: u64,
    offset: u64,
): (
    Pool<B_TEST_USDC, B_TEST_SUI, CpQuoter, LP_USDC_SUI>,
) {

    let (pool, bank_a, bank_b) = test_setup_cpmm(fee, offset);
    destroy(bank_a);
    destroy(bank_b);

    pool
}


#[test]
fun test_full_cpmm_cycle() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(100, 0, &mut scenario);

    let ctx = ctx(&mut scenario);
    pool.no_redemption_fees_for_testing();

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

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
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

    let swap_result = pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.pool_fees(), 364);
    assert_eq(swap_result.protocol_fees(), 91);
    assert_eq(swap_result.amount_out(), 45_454);

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
    assert_eq(coin_a.value(), 549_989);
    assert_eq(coin_b.value(), 454_900);
    assert_eq(reserve_a, 11);
    assert_eq(reserve_b, 10);
    assert_eq(pool.lp_supply_val(), minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    // Collect Protocol fees
    let global_admin = global_admin::init_for_testing(ctx);
    let (coin_a, coin_b) = pool.collect_protocol_fees(&global_admin, ctx);

    assert_eq(coin_a.value(), 0);
    assert_eq(coin_b.value(), 91);
    assert_eq(pool.trading_data().protocol_fees_a(), 0);
    assert_eq(pool.trading_data().protocol_fees_b(), 91);
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 364);

    assert_eq(pool.trading_data().total_swap_a_in_amount(), 50_000);
    assert_eq(pool.trading_data().total_swap_b_out_amount(), 45_454);
    assert_eq(pool.trading_data().total_swap_a_out_amount(), 0);
    assert_eq(pool.trading_data().total_swap_b_in_amount(), 0);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lend_cap);
    // destroy(prices);
    destroy(clock);
    // destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_cpmm_deposit_redeem_swap() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(100, 0, &mut scenario);

    let ctx = ctx(&mut scenario);
    pool.no_redemption_fees_for_testing();

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

    assert_eq(pool.cpmm_k(0), 500000000000000000000000000);
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
    assert_eq(coin_b.value(), e9(10) - 12); // double rounddown: inital lp tokens minted + redeem

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

    let swap_result = pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        e9(200),
        0,
        ctx,
    );

    assert_eq(swap_result.a2b(), true);
    assert_eq(swap_result.amount_out(), 83333333333265);
    assert_eq(swap_result.pool_fees(), 666666666666);
    assert_eq(swap_result.protocol_fees(), 166666666667);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::ESwapOutputAmountIsZero)]
fun test_fail_handle_full_precision_loss_from_highly_imbalanced_pool() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(100, 0, &mut scenario);

    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000_000_000_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(1, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000_000_000_000,
        1,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(50_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_trade_that_balances_highly_imbalanced_pool() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(100, 0, &mut scenario);

    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(500_000_000_000_000, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(1, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        500_000_000_000_000,
        1,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(0, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(10_000_000_000_000, ctx);

    let swap_result = pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        false, // a2b
        10_000_000_000_000,
        0,
        ctx,
    );

    assert_eq(swap_result.amount_out(), 499999999999950);
    assert_eq(swap_result.amount_in(), 10000000000000);
    assert_eq(swap_result.protocol_fees(), 1000000000000);
    assert_eq(swap_result.pool_fees(), 4000000000000);
    assert_eq(swap_result.a2b(), false);

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::ESwapExceedsSlippage)]
fun test_fail_swap_slippage() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(100, 0, &mut scenario);

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

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(200), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = pool.cpmm_quote_swap(
        e9(200),
        true, // a2b
    );

    pool.cpmm_swap(
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
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_cpmm_fees() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(
        100,
        0,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    let mut pool_2 = setup_pool(100, 0);

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
    let expected_pool_fees = 7_920_792_079_208;
    let expected_protocol_fees = 1_980_198_019_802;

    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(1_000_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let swap_result = pool.cpmm_swap(
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
        let swap_result = pool_2.cpmm_swap(
            &mut coin_a,
            &mut coin_b,
            true, // a2b
            e9(10_00),
            0,
            ctx,
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
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}
