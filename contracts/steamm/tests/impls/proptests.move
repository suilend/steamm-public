#[test_only]
module steamm::proptests {
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
    use suilend::{
        lending_market_tests::{LENDING_MARKET, setup as suilend_setup},
    };

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    #[test]
    fun proptest_swap() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<BToken<LENDING_MARKET, SUI>, BToken<LENDING_MARKET, COIN>, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(e9(100_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(100_000),
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);

        let mut trades = 1_000;

        while (trades > 0) {
            let amount_in = rng.generate_u64_in_range(1_000, 100_000_000_000_000_000);
            let a2b = if (rng.generate_u8_in_range(1_u8, 2_u8) == 1) { true } else { false };

            let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(if (a2b) { amount_in } else {0}, ctx);
            let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(if (a2b) { 0 } else {amount_in}, ctx);

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
    fun proptest_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<BToken<LENDING_MARKET, SUI>, BToken<LENDING_MARKET, COIN>, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(e9(100_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(25_000),
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
                amount_in,
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
    fun proptest_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = suilend_setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<BToken<LENDING_MARKET, SUI>, BToken<LENDING_MARKET, COIN>, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<BToken<LENDING_MARKET, SUI>>(10_000_000_000_000_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<BToken<LENDING_MARKET, COIN>>(10_000_000_000_000_000_000, ctx);

        let (mut lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            1_000_000_000_000_000_000,
            2_000_000_000_000_000_000,
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
