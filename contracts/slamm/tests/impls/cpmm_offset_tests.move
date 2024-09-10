#[test_only]
module slamm::cpmm_offset_tests {
    use slamm::pool::{Self, minimum_liquidity};
    use slamm::registry;
    use slamm::bank;
    use slamm::cpmm::{Self, offset};
    use slamm::test_utils::{COIN, reserve_args};
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};
    use suilend::decimal;

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const LP_PROVIDER: address = @0x12;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    #[test]
    fun test_one_sided_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            20,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );
        
        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 0);
        assert_eq(pool.cpmm_k(offset(&pool)), 500_000 * 20);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

        destroy(coin_a);
        destroy(coin_b);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
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

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            20,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );
        
        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 0);
        assert_eq(pool.cpmm_k(offset(&pool)), 500_000 * 20);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
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

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            20,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );
        
        let (reserve_a, reserve_b) = pool.total_funds();
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
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );

        assert_eq(redeem_result.burn_lp(), 499990);
        assert_eq(pool.total_funds_a(), 10);
        assert_eq(pool.total_funds_b(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_quotes_with_consecutive_price_increase() {
        let mut scenario = test_scenario::begin(ADMIN);

        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);


        let offset = 5;
        // Init Pool
        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
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
            assert!(
                new_price.gt(price), 0
            );

            price = new_price;
            pow_n = pow_n + 1;
        };

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    // Tests that the initial instant price increases as the offset increases
    #[test]
    fun test_quote_lateral_price_increase_with_increasing_offset() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let mut pow_n = 0;
        let mut price = decimal::from(0);
        let default_offset = 5;

        while (pow_n <= 5) {
            let mut registry = registry::init_for_testing(ctx(&mut scenario));
            let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
            let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));

            let offset = default_offset * 10_u64.pow(pow_n);

            let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
                Wit {},
                &mut registry,
                0, // admin fees BPS
                offset,
                ctx(&mut scenario),
            );

            pool.no_protocol_fees_for_testing();
            pool.no_redemption_fees_for_testing();

            let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx(&mut scenario));
            let mut coin_b = coin::mint_for_testing<SUI>(0, ctx(&mut scenario));

            let (lp_coins, _) = pool.deposit_liquidity(
                &mut bank_a,
                &mut bank_b,
                &mut coin_a,
                &mut coin_b,
                500_000,
                0,
                0,
                0,
                ctx(&mut scenario),
            );

            let quote = pool.cpmm_quote_swap(
                10_000_000,
                false, // a2b
            );

            let new_price = decimal::from(quote.amount_in()).div(decimal::from(quote.amount_out()));
            assert!(
                new_price.gt(price), 0
            );

            destroy(registry);
            destroy(bank_a);
            destroy(bank_b);
            destroy(coin_a);
            destroy(coin_b);
            destroy(lp_coins);
            destroy(pool_cap);
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

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let mut pow_n = 0;
        let mut price = decimal::from_scaled_val(50000040000080000160); // arbitrarily large number
        let offset = 5;
        let default_outlay = 500_000;

        while (pow_n <= 5) {
            let mut registry = registry::init_for_testing(ctx(&mut scenario));
            let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
            let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
            let outlay = default_outlay * 10_u64.pow(pow_n);

            let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
                Wit {},
                &mut registry,
                0, // admin fees BPS
                offset,
                ctx(&mut scenario),
            );

            pool.no_protocol_fees_for_testing();
            pool.no_redemption_fees_for_testing();

            let mut coin_a = coin::mint_for_testing<COIN>(outlay, ctx(&mut scenario));
            let mut coin_b = coin::mint_for_testing<SUI>(0, ctx(&mut scenario));

            let (lp_coins, _) = pool.deposit_liquidity(
                &mut bank_a,
                &mut bank_b,
                &mut coin_a,
                &mut coin_b,
                outlay,
                0,
                0,
                0,
                ctx(&mut scenario),
            );

            let quote = pool.cpmm_quote_swap(
                10_000_000,
                false, // a2b
            );

            let new_price = decimal::from(quote.amount_in()).div(decimal::from(quote.amount_out()));
            assert!(
                new_price.lt(price), 0
            );

            destroy(registry);
            destroy(bank_a);
            destroy(bank_b);
            destroy(coin_a);
            destroy(coin_b);
            destroy(lp_coins);
            destroy(pool_cap);
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

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let offset = 5;

        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        
        let mut coin_a = coin::mint_for_testing<COIN>(0, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(1_000, ctx);
        
        let swap_intent = pool.cpmm_intent_swap(
            10,
            false, // a2b
        );

        let swap_result_1 = pool.cpmm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let swap_intent = pool.cpmm_intent_swap(
            333333,
            true, // a2b
        );

        let swap_result_2 = pool.cpmm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        assert!(swap_result_1.amount_in() >= swap_result_2.amount_out(), 0);
        assert!(swap_result_2.amount_out() == 10 - 1, 0); // -1 due to rounddown

        destroy(coin_a);
        destroy(coin_b);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[expected_failure(abort_code = pool::ESwapOutputAmountIsZero)]
    #[test]
    fun test_try_exaust_pool() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let offset = 5;

        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        let mut trades = 1_000;
        let mut coin_a = coin::mint_for_testing<COIN>(0, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(10_000_000_000, ctx);

        while (trades > 0) {
            let swap_intent = pool.cpmm_intent_swap(
                1_000,
                false, // a2b
            );

            pool.cpmm_execute_swap(
                &mut bank_a,
                &mut bank_b,
                swap_intent,
                &mut coin_a,
                &mut coin_b,
                0,
                ctx,
            );

            let (reserve_a, _) = pool.total_funds();
            assert!(reserve_a > 0, 0);

            trades = trades - 1;

        };

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }

    // - Tests that quotes will always lead to 0 amount out in the limit
    #[test]
    fun test_try_exaust_pool_2() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let offset = 5;

        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Initial trade that leaves the pool with only 1 COIN
        let mut coin_a = coin::mint_for_testing<COIN>(0, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(10_000_000, ctx);

        let swap_intent = pool.cpmm_intent_swap(
            10_000_000,
            false, // a2b
        );

        pool.cpmm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
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

        let (_, reserve_b) = pool.total_funds();

        let quote = pool.cpmm_quote_swap(
            18_446_744_073_709_551_615u64 - reserve_b - offset, // U64::MAX
            false, // a2b
        );

        assert_eq(quote.amount_out(), 0);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }

    #[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
    #[test]
    fun test_one_sided_deposit_quote_swap_against_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let offset = 5;

        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        
        pool.cpmm_quote_swap(
            10_000_000,
            true, // a2b
        );

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
    #[test]
    fun test_one_sided_deposit_swap_against_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let offset = 5;

        let (mut pool, pool_cap) = cpmm::new_with_offset<COIN, SUI, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            offset,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        let mut coin_a = coin::mint_for_testing<COIN>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        
        let mut coin_a = coin::mint_for_testing<COIN>(0, ctx);
        let mut coin_b = coin::mint_for_testing<SUI>(1_000, ctx);
        
        let swap_intent = pool.cpmm_intent_swap(
            10_000_000,
            true, // a2b
        );

        pool.cpmm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
}
