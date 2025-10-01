#[test_only]
module steamm::cpmm_offset_tests;

use std::debug::print;
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::cpmm_tests::{setup, setup_pool};
use steamm::pool;
use steamm::test_utils::reserve_args;
use sui::coin;
use sui::test_scenario::{Self, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::decimal;
use suilend::lending_market_tests::setup as suilend_setup;

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;

#[test]
fun test_optimal_offset() {
    let mut scenario = test_scenario::begin(ADMIN);

    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let price = 1; // 0.01
    let meme_reserve = 100_000_000_000;

    let offset = price * meme_reserve / 100;

    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(meme_reserve, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        meme_reserve,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let quote = pool.cpmm_quote_swap(
        10,
        false, // a2b
    );

    // 10 / 999 = ~0.01001001001001001001 > 0.01
    assert!(quote.amount_in() == 10, 0);
    assert!(quote.amount_out() == 999, 0);

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_optimal_offset_with_decimals() {
    let mut scenario = test_scenario::begin(ADMIN);

    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let price = 1; // 0.01
    let meme_reserve = 100_000_000_000 * 10_u64.pow(6);

    let offset = ((price * meme_reserve / 100) / 10_u64.pow(6)) * 10_u64.pow(9);

    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(meme_reserve, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        meme_reserve,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let quote = pool.cpmm_quote_swap(
        10 * 10_u64.pow(9),
        false, // a2b
    );

    // 10 / 999 = ~0.01001001001001001001 > 0.01
    print(&offset);
    assert!(quote.amount_in() == 10000000000, 0); // amount_sui in: 10000000000 e9; 10
    assert!(quote.amount_out() == 999999990, 0); // amount meme out: 999999990 e6; 999.99999

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_optimal_offset_with_decimals_2() {
    let mut scenario = test_scenario::begin(ADMIN);

    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    // xxx initialPriceUsd: 0.000005
    // xxx initialPriceQuote: 0.00000126135655118055
    // xxx offset: 252271310236n
    
    let price = 126135655118055 as u256; // 0.00000126135655118055
    let price_adj = 100000000000000000000_u256;
    let meme_reserve = 200_000_000  * 10_u64.pow(6);
    let offset = (price * (meme_reserve as u256) * 10_u256.pow(9) / (10_u256.pow(6) * price_adj)) as u64;

    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );
    print(&offset);

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(meme_reserve, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        meme_reserve,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let quote = pool.cpmm_quote_swap(
        10 * 10_u64.pow(9),
        false, // a2b
    );

    // 0.00020020637155399122 4.00440772
    // 0.000005
    // 0.00004999650024498285

    // // 10 / 999 = ~0.01001001001001001001 > 0.01
    // print(&offset);
    // assert!(quote.amount_in() == 10000000000, 0); // amount_sui in: 10000000000 e9; 10
    // assert!(quote.amount_out() == 999999990, 0); // amount meme out: 999999990 e6; 999.99999

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_quotes_with_consecutive_price_increase() {
    let mut scenario = test_scenario::begin(ADMIN);

    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

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

    let mut pow_n = 0;

    let mut price = decimal::from(0);

    while (pow_n <= 14) {
        let sui_in = 10_u64.pow(pow_n);

        let quote = pool.cpmm_quote_swap(
            sui_in,
            false, // a2b
        );

        let new_price = decimal::from(quote.amount_in()).div(decimal::from(quote.amount_out()));
        assert!(new_price.gt(price), 0);

        price = new_price;
        pow_n = pow_n + 1;
    };

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

// Tests that the initial instant price increases as the offset increases
#[test]
fun test_quote_lateral_price_increase_with_increasing_offset() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pow_n = 0;
    let mut price = decimal::from(0);
    let default_offset = 5;

    while (pow_n <= 5) {
        let offset = default_offset * 10_u64.pow(pow_n);
        let mut pool = setup_pool(0, offset, &mut scenario);

        pool.no_protocol_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(
            500_000,
            ctx(&mut scenario),
        );
        let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx(&mut scenario));

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            ctx(&mut scenario),
        );

        let quote = pool.cpmm_quote_swap(
            10_000_000,
            false, // a2b
        );

        let new_price = decimal::from(quote.amount_in()).div(decimal::from(quote.amount_out()));
        assert!(new_price.gt(price), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);
        destroy(pool);

        price = new_price;
        pow_n = pow_n + 1;
    };

    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

// Tests that the initial instant price decreases as the initial pool coin supply increases
#[test]
fun test_quote_lateral_price_decrease_with_increasing_initial_coin_supply() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    let mut pow_n = 0;
    let mut price = decimal::from_scaled_val(50000040000080000160); // arbitrarily large number
    let offset = 5;
    let default_outlay = 500_000;

    while (pow_n <= 5) {
        let mut pool = setup_pool(0, offset, &mut scenario);

        let outlay = default_outlay * 10_u64.pow(pow_n);

        pool.no_protocol_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(
            outlay,
            ctx(&mut scenario),
        );
        let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, ctx(&mut scenario));

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            outlay,
            0,
            ctx(&mut scenario),
        );

        let quote = pool.cpmm_quote_swap(
            10_000_000,
            false, // a2b
        );

        let new_price = decimal::from(quote.amount_in()).div(decimal::from(quote.amount_out()));
        assert!(new_price.lt(price), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);
        destroy(pool);

        price = new_price;
        pow_n = pow_n + 1;
    };

    destroy(lend_cap);
    destroy(prices);
    destroy(clock);
    destroy(bag);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun test_one_sided_deposit_swap_back_and_forth() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    pool.no_protocol_fees_for_testing();

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

    destroy(coin_a);
    destroy(coin_b);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(0, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(1_000, ctx);

    let swap_result_1 = pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        false, // a2b
        10,
        0,
        ctx,
    );

    let swap_result_2 = pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        333333,
        0,
        ctx,
    );

    assert!(swap_result_1.amount_in() >= swap_result_2.amount_out(), 0);
    assert!(swap_result_2.amount_out() == 10 - 1, 0); // -1 due to rounddown

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[expected_failure(abort_code = pool::ESwapOutputAmountIsZero)]
#[test]
fun test_try_exaust_pool() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

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

    let mut trades = 1_000;
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(0, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(10_000_000_000, ctx);

    while (trades > 0) {
        pool.cpmm_swap(
            &mut coin_a,
            &mut coin_b,
            false, // a2b
            1_000,
            0,
            ctx,
        );

        let (reserve_a, _) = pool.balance_amounts();
        assert!(reserve_a > 0, 0);

        trades = trades - 1;
    };

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

// - Tests that quotes will always lead to 0 amount out in the limit
#[test]
fun test_try_exaust_pool_2() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

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

    // Initial trade that leaves the pool with only 1 COIN
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(0, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(10_000_000, ctx);

    pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        false, // a2b
        10_000_000,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let mut pow_n = 0;

    while (pow_n < 20) {
        let sui_in = 10_u64.pow(pow_n);

        let quote = pool.cpmm_quote_swap(
            sui_in,
            false, // a2b
        );

        assert_eq(quote.amount_out(), 0);

        pow_n = pow_n + 1;
    };

    let (_, reserve_b) = pool.balance_amounts();

    let quote = pool.cpmm_quote_swap(
        18_446_744_073_709_551_615u64 - reserve_b - offset, // U64::MAX
        false, // a2b
    );

    assert_eq(quote.amount_out(), 0);

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
#[test]
fun test_one_sided_deposit_quote_swap_against_liquidity() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

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

    pool.cpmm_quote_swap(
        10_000_000,
        true, // a2b
    );

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
#[test]
fun test_one_sided_deposit_swap_against_liquidity() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let offset = 5;
    let (clock, lend_cap, lending_market, mut pool) = setup(
        0,
        offset,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    pool.no_protocol_fees_for_testing();

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

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(0, ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(1_000, ctx);

    pool.cpmm_swap(
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        10_000_000,
        0,
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
