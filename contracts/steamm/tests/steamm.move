#[test_only]
module steamm::steamm_tests;

use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::cpmm::{Self, offset};
use steamm::dummy_quoter::{swap as dummy_swap, quote_swap, DummyQuoter};
use steamm::global_admin;
use steamm::lp_usdc_sui::LP_USDC_SUI;
use steamm::pool::{Self, Pool, minimum_liquidity};
use steamm::pool_math;
use steamm::quote;
use steamm::test_utils::{test_setup_dummy, test_setup_cpmm, e9, reserve_args};
use sui::coin;
use sui::test_scenario::{Self, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market_tests::setup as suilend_setup;

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;
const LP_PROVIDER: address = @0x12;
const TRADER: address = @0x13;

#[test_only]
fun test_setup_dummy_no_banks(
    swap_fee_bps: u64,
): Pool<B_TEST_USDC, B_TEST_SUI, DummyQuoter, LP_USDC_SUI> {
    let (pool, bank_a, bank_b) = test_setup_dummy(swap_fee_bps);

    destroy(bank_a);
    destroy(bank_b);

    pool
}

#[test]
fun test_steamm_deposit_redeem_swap() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 500000000000000000000000000);
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
    assert_eq(swap_result.amount_out(), 200000000000);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 500_000 * 500_000);
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
    assert_eq(swap_result.amount_out(), 50_000);

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
    assert_eq(coin_b.value(), 450_390);
    assert_eq(reserve_a, 11);
    assert_eq(reserve_b, 10);
    assert_eq(pool.lp_supply_val(), minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    // Collect Protocol fees
    let global_admin = global_admin::init_for_testing(ctx);
    let (coin_a, coin_b) = pool.collect_protocol_fees(&global_admin, ctx);

    assert_eq(coin_a.value(), 0);
    assert_eq(coin_b.value(), 100);
    assert_eq(pool.trading_data().protocol_fees_a(), 0);
    assert_eq(pool.trading_data().protocol_fees_b(), 100);
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 400);

    assert_eq(pool.trading_data().total_swap_a_in_amount(), 50_000);
    assert_eq(pool.trading_data().total_swap_b_out_amount(), 50_000);
    assert_eq(pool.trading_data().total_swap_a_out_amount(), 0);
    assert_eq(pool.trading_data().total_swap_b_in_amount(), 0);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 500000000000000000000000000);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 500000000000000000000000000);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 500000000000000000000000000);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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

    assert_eq(cpmm::k(&pool, 0), 1000000000000000000000000);
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
#[expected_failure(abort_code = pool::EFeeAbove100Percent)]
fun test_fail_fee_above_100() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let pool = test_setup_dummy_no_banks(10_000 + 1);

    destroy(pool);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);
    let mut pool_2 = test_setup_dummy_no_banks(100);

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
        let swap_result = dummy_swap(
            &mut pool_2,
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
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

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
fun test_redeem_fees() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(100_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000),
        e9(100_000),
        ctx,
    );

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

    // Guarantees that roundings are in favour of the pool
    assert_eq(coin_a.value(), 99_899_999_999_990);
    assert_eq(coin_b.value(), 99_899_999_999_990);

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
fun test_min_redeem_fees_ceil() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(100_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), ctx);

    let (mut lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000),
        e9(100_000),
        ctx,
    );

    let lp_coins_2 = lp_coins.split(10, ctx);

    destroy(lp_coins);
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

    assert_eq(coin_a.value(), 10 - 1);
    assert_eq(coin_b.value(), 10 - 1);

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
fun test_min_redeem_fees() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let mut pool = test_setup_dummy_no_banks(100);

    pool.no_redemption_fees_for_testing_with_min_fee();

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(100_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), ctx);

    let (mut lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000),
        e9(100_000),
        ctx,
    );

    let lp_coins_2 = lp_coins.split(10, ctx);

    destroy(lp_coins);
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

    assert_eq(coin_a.value(), 10 - 1);
    assert_eq(coin_b.value(), 10 - 1);

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
fun test_one_sided_deposit() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let (mut pool, bank_a, bank_b) = test_setup_cpmm(100, 20);

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
    assert_eq(pool.cpmm_k(offset(&pool)), 500_000 * 20);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

    destroy(coin_a);
    destroy(coin_b);

    destroy(bank_a);
    destroy(bank_b);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let (mut pool, bank_a, bank_b) = test_setup_cpmm(100, 20);

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
    assert_eq(pool.cpmm_k(offset(&pool)), 500_000 * 20);
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

    destroy(bank_a);
    destroy(bank_b);
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
        &mut scenario,
    ).destruct_state();

    let ctx = ctx(&mut scenario);

    let (mut pool, bank_a, bank_b) = test_setup_cpmm(100, 20);

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
    assert!(pool.cpmm_k(offset(&pool)) == 500000 * 20, 0);
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

    assert_eq(redeem_result.burn_lp(), 499990);
    assert_eq(pool.balance_amount_a(), 10);
    assert_eq(pool.balance_amount_b(), 0);

    destroy(bank_a);
    destroy(bank_b);
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
