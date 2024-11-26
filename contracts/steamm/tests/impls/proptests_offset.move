#[test_only]
module steamm::proptests_offset {
    use steamm::registry;
    use steamm::cpmm::{Self};
    use steamm::bank::{BToken};
    use steamm::test_utils::reserve_args;
    use steamm::test_utils::COIN;
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::random;
    use sui::coin::{Self};
    use sui::test_utils::{destroy};
    use suilend::lending_market::{Self, LENDING_MARKET};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    #[test]
    fun proptest_swap_offset() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit, LENDING_MARKET>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            5,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(e9(100_000), ctx);

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

            let amount_in = 
                if (a2b) {
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

            let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(if (a2b) { amount_in } else {0}, ctx);
            let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(if (a2b) { 0 } else {amount_in}, ctx);

            let quote = pool.cpmm_quote_swap(
                amount_in,
                a2b, // a2b
            );

            if (quote.amount_out() == 0) {
                destroy(coin_a);
                destroy(coin_b);
                continue
            };

            let swap_intent = pool.cpmm_intent_swap(
                amount_in,
                a2b, // a2b
            );

            pool.cpmm_execute_swap(
                swap_intent,
                &mut coin_a,
                &mut coin_b,
                0,
                ctx,
            );

            destroy(coin_a);
            destroy(coin_b);

            trades = trades - 1;
        };

        destroy(registry);
        destroy(pool);
        destroy(lp_coins);
        destroy(pool_cap);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun proptest_deposit_offset() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit, LENDING_MARKET>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            5,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(e9(100_000), ctx);

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

            let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(amount_in, ctx);
            let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(amount_in, ctx);

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

        destroy(registry);
        destroy(pool);
        destroy(lp_coins);
        destroy(pool_cap);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun proptest_redeem_offset() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit, LENDING_MARKET>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            5,
            ctx,
        );

        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(10_000_000_000_000_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(10_000_000_000_000_000_000, ctx);

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

        destroy(registry);
        destroy(pool);
        destroy(lp_coins);
        destroy(pool_cap);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
}
