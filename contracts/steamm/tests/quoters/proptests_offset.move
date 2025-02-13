#[test_only]
module steamm::proptests_offset;

use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::cpmm;
use steamm::cpmm_tests::setup;
use steamm::test_utils::e9;
use sui::coin;
use sui::random;
use sui::test_scenario::{Self, ctx};
use sui::test_utils::destroy;

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;
const TRADER: address = @0x13;

#[test]
fun proptest_swap_offset() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(
        100,
        5,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(100_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000),
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // Swap
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut rng = random::new_generator_from_seed_for_testing(vector[1, 4, 2, 3]);
    let mut trades = 1_000;

    while (trades > 0) {
        let a2b = if (rng.generate_u8_in_range(1_u8, 2_u8) == 1) { true } else { false };

        let amount_in = if (a2b) {
            let max_amount_in = cpmm::max_amount_in_on_a2b(&pool);

            if (max_amount_in.is_none()) {
                rng.generate_u64_in_range(1_000, 100_000_000_000_000_000)
            } else {
                if (max_amount_in.borrow() == 0) {
                    continue
                };
                rng.generate_u64_in_range(1, *max_amount_in.borrow())
            }
        } else {
            rng.generate_u64_in_range(1_000, 100_000_000_000_000_000)
        };

        let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(
            if (a2b) { amount_in } else { 0 },
            ctx,
        );
        let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(
            if (a2b) { 0 } else { amount_in },
            ctx,
        );

        let quote = pool.cpmm_quote_swap(
            amount_in,
            a2b, // a2b
        );

        if (quote.amount_out() == 0) {
            destroy(coin_a);
            destroy(coin_b);
            continue
        };

        pool.cpmm_swap(
            &mut coin_a,
            &mut coin_b,
            a2b, // a2b
            amount_in,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        trades = trades - 1;
    };

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun proptest_deposit_offset() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(
        100,
        5,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(e9(100_000), ctx);
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        e9(100_000),
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // Deposit
    test_scenario::next_tx(&mut scenario, TRADER);
    let ctx = ctx(&mut scenario);

    let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);

    let mut trades = 1_000;

    while (trades > 0) {
        let amount_in = rng.generate_u64_in_range(1_000, 100_000_000_000_000);

        let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(amount_in, ctx);
        let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(amount_in, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            amount_in,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        trades = trades - 1;
    };

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}

#[test]
fun proptest_redeem_offset() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    let (clock, lend_cap, lending_market, mut pool) = setup(
        100,
        5,
        &mut scenario,
    );

    let ctx = ctx(&mut scenario);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(
        10_000_000_000_000_000_000,
        ctx,
    );
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(
        10_000_000_000_000_000_000,
        ctx,
    );

    let (mut lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        1_000_000_000_000_000_000,
        0,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    // Deposit
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);

    let mut lp_tokens_balance = lp_coins.value();

    while (lp_tokens_balance > 0) {
        let lp_burn = rng.generate_u64_in_range(1, lp_tokens_balance);

        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            lp_coins.split(lp_burn, ctx),
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        lp_tokens_balance = lp_tokens_balance - lp_burn;
    };

    destroy(pool);
    destroy(lp_coins);
    destroy(lend_cap);
    destroy(clock);
    destroy(lending_market);
    test_scenario::end(scenario);
}
