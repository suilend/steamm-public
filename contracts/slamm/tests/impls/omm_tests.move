#[test_only]
module slamm::omm_tests {
    // use std::debug::print;
    use slamm::registry;
    use slamm::bank;
    use slamm::test_utils::{
        COIN, reserve_args, update_pyth_price, set_clock_time, bump_clock,
        update_pool_oracle_price_ahead_of_trade,
    };
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::random;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};
    use suilend::decimal;
    use slamm::omm;
    use slamm::test_utils;

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    #[test]
    fun test_full_omm_cycle() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 5

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            4_000, // max_vol_accumulated_bps: 0.4
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_intent = pool.omm_intent_swap(
            50_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        assert_eq(pool.inner().ema().reference_val(), decimal::from(0));
        assert_eq(pool.inner().ema().accumulator(), decimal::from_scaled_val(189845685556076473)); // 18..%
        assert_eq(pool.inner().reference_price(), decimal::from(1)); // price = 1
        assert_eq(pool.inner().reference_price(), decimal::from(1)); // price = 1
        assert_eq(pool.inner().last_update_ms(), clock.timestamp_ms());

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_quote_fee_with_incremental_volatility_and_symmetry() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000_000,
            500_000_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);

        let swap_amts = vector[
            1_000_000,
            2_000_000,
            3_000_000,
            4_000_000,
            5_000_000,
            50_000_000,
            500_000_000,
        ];

        let expected_vol = vector[
            decimal::from_scaled_val(3995998019991953), // 0.00039%
            decimal::from_scaled_val(7983998375516945), // 0.0079%
            decimal::from_scaled_val(11963999928149285), // 0.0119%
            decimal::from_scaled_val(15936000079805465), // 0.159%
            decimal::from_scaled_val(1_9900004850259887), // 1.99%
            decimal::from_scaled_val(19_0045247877807580), // 19%
            decimal::from_scaled_val(120_0000000000000000), // 120%
        ];
        
        let expected_fee_rate = vector[
            decimal::from_scaled_val(1002000995988),
            decimal::from_scaled_val(1004000439752),
            decimal::from_scaled_val(1676666866748),
            decimal::from_scaled_val(2772000676368),
            decimal::from_scaled_val(4040000040400),
            decimal::from_scaled_val(361174003611740),
            decimal::from_scaled_val(14400000000000000), // 1.44%
        ];

        let mut len = swap_amts.length();
        let mut fee = decimal::from(1);

        while (len > 0) {
            let (quote, _, _, vol, _) = omm::quote_swap_impl(
                &pool,
                swap_amts[len - 1],
                true, // a2b
                clock.timestamp_ms(),
            );

            
            let fee_rate = quote.output_fee_rate();

            assert!(fee_rate.lt(fee), 0);
            assert_eq(fee_rate, expected_fee_rate[len - 1]);
            assert_eq(vol, expected_vol[len - 1]);

            fee = fee_rate;
            len = len - 1;
        };
        
        // b2a

        let mut len = swap_amts.length();
        let mut fee = decimal::from(1);

        while (len > 0) {
            let (quote, _, _, vol, _) = omm::quote_swap_impl(
                &pool,
                swap_amts[len - 1],
                false, // a2b
                clock.timestamp_ms(),
            );

            let fee_rate = decimal::from(
                quote.output_fees().pool_fees()
            )
            .add(
                decimal::from(
                    quote.output_fees().protocol_fees()
                )
            )
            .div(
                decimal::from(
                    quote.amount_out()
                )
            );

            assert!(fee_rate.lt(fee), 0);
            assert_eq(fee_rate, expected_fee_rate[len - 1]);
            // We divide by ten to remove rounding differences in the last digit
            assert_eq(vol.div(decimal::from(10)), expected_vol[len - 1].div(decimal::from(10)));

            fee = fee_rate;
            len = len - 1;
        };

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_quote_max_vol() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            100, // max_vol_accumulated_bps: 1%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        
        let (_, _, _, vol, _) = omm::quote_swap_impl(
            &pool,
            100_000_000,
            true, // a2b
            clock.timestamp_ms(),
        );

        assert_eq(vol, decimal::from_percent(1));

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_handle_refresh_price() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        set_clock_time(&mut clock);
        let ctx = ctx(&mut scenario);

        let mut price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            100, // max_vol_accumulated_bps: 1%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);

        bump_clock(&mut clock, 1); // 1 seconds

        update_pyth_price(
            &mut price_info_a,
            5,
            1,
            &clock,
        );

        omm::refresh_reserve_prices(
            &mut pool,
            &price_info_a,
            &price_info_b,
            &clock,
        );
        
        let (_, _, _, vol, _) = omm::quote_swap_impl(
            &pool,
            100_000_000,
            true, // a2b
            clock.timestamp_ms(),
        );

        assert_eq(vol, decimal::from_percent(1));

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    #[expected_failure(abort_code = omm::EPriceStale)]
    fun test_handle_fail_to_refresh_price() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        set_clock_time(&mut clock);
        let ctx = ctx(&mut scenario);

        let mut price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            100, // max_vol_accumulated_bps: 1%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);

        let new_ts = clock.timestamp_ms() + 1000; // 1 second
        clock.set_for_testing(new_ts);

        update_pyth_price(
            &mut price_info_a,
            5,
            1,
            &clock,
        );
        
        let (_, _, _, vol, _) = omm::quote_swap_impl(
            &pool,
            100_000_000,
            true, // a2b
            clock.timestamp_ms(),
        );

        assert_eq(vol, decimal::from_percent(1));

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    
    // We set fee_control to zero and swap fee to zero such that we can remove the impact
    // of fees in the internal pricing of the amm, making it easier to analyse the state transitions
    // of variables such as reference_vol, reference_price, and accumulated_vol.
    //
    // - We assert that the reference price does not change in the filter period
    // - No carryover vol
    // - Asserts that accumulated_vol adds up. As prices move against the static reference price,
    // accumulated vol grows, and vice-versa
    #[test]
    fun test_trades_in_filter_period_with_leading_oracle_no_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();
        let initial_accumulator = pool.inner().ema().accumulator();

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100_000,
            true, // a2b,
            1,
            &mut clock,
        );


        let swap_intent = pool.omm_intent_swap(
            100_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        let mid_accumulator = pool.inner().ema().accumulator();
        assert!(mid_accumulator.gt(initial_accumulator));

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            1_000,
            true, // a2b,
            1,
            &mut clock,
        );
   
        let swap_intent = pool.omm_intent_swap(
            1_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let mid_accumulator_2 = pool.inner().ema().accumulator();
        assert!(mid_accumulator_2.gt(mid_accumulator));
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            10_000,
            false, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            10_000,
            false, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let end_accumulator = pool.inner().ema().accumulator();
        assert!(end_accumulator.lt(mid_accumulator_2));
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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

    // - We assert that the reference price does not change in the filter period
    // - No carryover vol
    // - Asserts that accumulated_vol adds up. As prices move against the static reference price,
    // accumulated vol grows, and vice-versa
    // We assert that variable fees increase and decrease according to changes in the accumulated vol
    #[test]
    fun test_trades_in_filter_period_with_leading_oracle_with_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);
        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 100%
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();
        let initial_accumulator = pool.inner().ema().accumulator();

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100_000,
            true, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100_000,
            true, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let mid_accumulator = pool.inner().ema().accumulator();
        let fee_rate_1 = swap_result.to_quote().output_fee_rate();

        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert!(mid_accumulator.gt(initial_accumulator));

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            1_000,
            true, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            1_000,
            true, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let mid_accumulator_2 = pool.inner().ema().accumulator();
        let fee_rate_2 = swap_result.to_quote().output_fee_rate();

        assert!(mid_accumulator_2.gt(mid_accumulator));
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert!(fee_rate_2.gt(fee_rate_1));

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            10_000,
            false, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            10_000,
            false, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let end_accumulator = pool.inner().ema().accumulator();
        let fee_rate_3 = swap_result.to_quote().output_fee_rate();

        assert!(end_accumulator.lt(mid_accumulator_2));
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert!(fee_rate_3.lt(fee_rate_2));

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    
    // We set fee_control to zero and swap fee to zero such that we can remove the impact
    // of fees in the internal pricing of the amm, making it easier to analyse the state transitions
    // other variables such as reference_vol, reference_price, and accumulated_vol.
    //
    // - We assert that the reference price does not change in the filter period
    // - No carryover vol
    // - Asserts that accumulated_vol adds up. As prices move against the static reference price,
    // accumulated vol grows, however, when the internal price moves in the direction of the reference price
    // the decrease in vol is not felt due to the fact that the oracle is lagging and therefore does not reflect
    // that price change. Since we compute the max of the price difference between (ref price - internal price) and
    // (ref price - oracle price), the accumulated vol does not change
    #[test]
    fun test_trades_in_filter_period_with_lagging_oracle_no_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();
        let initial_accumulator = pool.inner().ema().accumulator();

        let swap_intent = pool.omm_intent_swap(
            100_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        let mid_accumulator = pool.inner().ema().accumulator();
        assert!(mid_accumulator.gt(initial_accumulator));

        let swap_intent = pool.omm_intent_swap(
            1_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        let mid_accumulator_2 = pool.inner().ema().accumulator();
        assert!(mid_accumulator_2.gt(mid_accumulator));
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());

        let swap_intent = pool.omm_intent_swap(
            10_000,
            false, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        let end_accumulator = pool.inner().ema().accumulator();

        assert!(end_accumulator.eq(mid_accumulator_2)); // they are equal here
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    
    // - We assert that the reference price does not change in the filter period
    // - No carryover vol
    // - Asserts that accumulated_vol adds up. As prices move against the static reference price,
    // accumulated vol grows, however, when the internal price moves in the direction of the reference price
    // the decrease in vol is not felt due to the fact that the oracle is lagging and therefore does not reflect
    // that price change. Since we compute the max of the price difference between (ref price - internal price) and
    // (ref price - oracle price), the accumulated vol does not change (if no fees - with fees it will decrease slightly)
    #[test]
    fun test_trades_in_filter_period_with_lagging_oracle_with_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();
        let initial_accumulator = pool.inner().ema().accumulator();

        let swap_intent = pool.omm_intent_swap(
            100_000,
            true, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        let mid_accumulator = pool.inner().ema().accumulator();
        let fee_rate_1 = swap_result.to_quote().output_fee_rate();
        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert!(mid_accumulator.gt(initial_accumulator));

        let swap_intent = pool.omm_intent_swap(
            1_000,
            true, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        let mid_accumulator_2 = pool.inner().ema().accumulator();
        let fee_rate_2 = swap_result.to_quote().output_fee_rate();
        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert!(mid_accumulator_2.gt(mid_accumulator));
        assert!(fee_rate_2.gt(fee_rate_1));

        let swap_intent = pool.omm_intent_swap(
            10_000,
            false, // a2b
            &clock,
        );

        let swap_result = pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        bump_clock(&mut clock, 1);
        omm::set_oracle_price_as_internal_for_testing(&mut pool, &clock);

        let end_accumulator = pool.inner().ema().accumulator();
        let fee_rate_3 = swap_result.to_quote().output_fee_rate();

        assert_eq(initial_reference_vol, pool.inner().ema().reference_val());
        assert_eq(initial_reference_price, pool.inner().reference_price());
        assert!(end_accumulator.eq(mid_accumulator_2));
        assert!(fee_rate_3.lt(fee_rate_2));

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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

    // Assert that:
    // - Reference price gets updated after filter period
    // - Reference vol gets updated after filter period
    // - Accumulated vol is reduced from filter period to decay period to
    // reflect the reduction factor
    // - Volatility accumulatives with trades in one direction
    // - Accumulated vol decreases with trades which bring price closer to reference price
    #[test]
    fun test_trades_in_decay_period_with_leading_oracle_no_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        
        // Initial trade to create some accumulated volatility
        let swap_intent = pool.omm_intent_swap(
            10_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();
        let initial_accumulator = pool.inner().ema().accumulator();

        // Move beyond the filter period of 60 seconds
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            60,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let vol_accumulator_1 = pool.inner().ema().accumulator();
        let ref_price_1 = pool.inner().reference_price();
        let ref_vol_1 = pool.inner().ema().reference_val();
        assert!(vol_accumulator_1.lt(initial_accumulator), 0);
        assert!(ref_price_1.gt(initial_reference_price), 0); // reference price gets updated
        assert!(ref_vol_1.gt(initial_reference_vol), 0); // reference vol gets updated

        // Second trade
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let vol_accumulator_2 = pool.inner().ema().accumulator();
        let ref_price_2 = pool.inner().reference_price();
        let ref_vol_2 = pool.inner().ema().reference_val();
        assert!(vol_accumulator_2.gt(vol_accumulator_1), 0); // vol increases with accumulated directional trades
        assert!(ref_price_2.eq(ref_price_1), 0); // reference price the same
        assert!(ref_vol_2.eq(ref_vol_1), 0); // reference vol the same

        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            1,
            &mut clock,
        );
        
        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let vol_accumulator_3 = pool.inner().ema().accumulator();
        let ref_price_3 = pool.inner().reference_price();
        let ref_vol_3 = pool.inner().ema().reference_val();

        assert!(vol_accumulator_3.gt(vol_accumulator_2), 0); // vol increases with accumulated directional trades
        assert!(ref_price_3.eq(ref_price_1), 0); // reference price the same
        assert!(ref_vol_3.eq(ref_vol_1), 0); // reference vol the same

        // Now opposite trade should decrease vol
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            false, // a2b,
            1,
            &mut clock,
        );
        
        let swap_intent = pool.omm_intent_swap(
            100,
            false, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let vol_accumulator_4 = pool.inner().ema().accumulator();
        let ref_price_4 = pool.inner().reference_price();
        let ref_vol_4 = pool.inner().ema().reference_val();

        assert!(vol_accumulator_4.lt(vol_accumulator_3), 0); // vol decreases with opposite direction trade
        assert!(ref_price_4.eq(ref_price_1), 0); // reference price the same
        assert!(ref_vol_4.eq(ref_vol_1), 0); // reference vol the same

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_trades_in_post_decay_period_with_leading_oracle_no_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        
        // Initial trade to create some accumulated volatility
        let swap_intent = pool.omm_intent_swap(
            10_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        // Move to decay period
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            61,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );


        let initial_accumulator = pool.inner().ema().accumulator();
        let initial_reference_price = pool.inner().reference_price();
        let initial_reference_vol = pool.inner().ema().reference_val();

        assert!(initial_reference_vol.gt(decimal::from(0)), 0);
        assert!(initial_reference_price.gt(decimal::from(0)), 0);
        assert!(initial_accumulator.gt(decimal::from(0)), 0);

        // Move beyond the decay period
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            601,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let new_vol_accumulator = pool.inner().ema().accumulator();
        let new_reference_price = pool.inner().reference_price();
        let new_reference_vol = pool.inner().ema().reference_val();
        assert!(new_reference_vol.eq(decimal::from(0)), 0);
        assert!(new_vol_accumulator.eq(decimal::from(0)), 0);
        assert_eq(new_reference_price, omm::new_instant_price_oracle(&pool));

        // Second trade - back into filter period
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let new_vol_accumulator_2 = pool.inner().ema().accumulator();
        let new_reference_price_2 = pool.inner().reference_price();
        let new_reference_vol_2 = pool.inner().ema().reference_val();

        assert!(new_reference_vol_2.eq(decimal::from(0)), 0); // ref vol still reset
        assert!(new_vol_accumulator.eq(decimal::from(0)), 0); // new vol accumulator > 0
        assert_eq(new_reference_price_2, new_reference_price); // reference price is set at the begining of new filter period
        
        // Third trade - confirm vol accumulation
        update_pool_oracle_price_ahead_of_trade(
            &mut pool,
            100,
            true, // a2b,
            1,
            &mut clock,
        );

        let swap_intent = pool.omm_intent_swap(
            100,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let new_vol_accumulator_3 = pool.inner().ema().accumulator();
        let new_reference_price_3 = pool.inner().reference_price();
        let new_reference_vol_3 = pool.inner().ema().reference_val();
        assert!(new_vol_accumulator_3.gt(new_vol_accumulator_2), 0);
        assert!(new_reference_price_3.eq(new_reference_price_2), 0);
        assert!(new_reference_vol_3.eq(decimal::from(0)), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    
    // Assert that:
    // - Reference price does not change in filter period
    // - Reference price updates after filter period
    #[test]
    fun test_reference_price_change_in_frequent_trades() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);
        
        let mut trades = 60;
        let mut i = 1;
        let mut previous_reference_price = 10_000; // 1

        while (trades > 0) {
            update_pool_oracle_price_ahead_of_trade(
                &mut pool,
                100,
                true, // a2b,
                10, // 10 seconds
                &mut clock,
            );
        
            let swap_intent = pool.omm_intent_swap(
                100,
                true, // a2b
                &clock,
            );

            pool.omm_execute_swap(
                &mut bank_a,
                &mut bank_b,
                swap_intent,
                &mut coin_a,
                &mut coin_b,
                0,
                ctx,
            );

            let ref_price = pool.inner().reference_price().mul(decimal::from(10_000)).floor();

            if (i % 6 == 0) {
                assert!(ref_price > previous_reference_price, 0);

            } else {
                assert_eq(ref_price, previous_reference_price);
            };

            previous_reference_price = ref_price;
            trades = trades - 1;
            i = i + 1;
        };

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_quote_symmetric_vol() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        
        let (_quote_1, vol_1, _, _, _) = omm::quote_swap_impl(
            &pool,
            112_372,
            true, // a2b,
            clock.timestamp_ms(),
        );
        
        let (_quote_2, vol_2, _, _, _) = omm::quote_swap_impl(
            &pool,
            112_372,
            false, // b2a
            clock.timestamp_ms(),
        );

        // we divide by ten to remove the rounding difference in the last digit
        assert_eq(vol_1.div(decimal::from(10)), vol_2.div(decimal::from(10)));

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    fun test_quote_symmetric_vol_proptest() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);

        let mut rng = random::new_generator_from_seed_for_testing(vector[0, 0, 0, 0]);
        let mut trades = 1_000;
        let precision_err = decimal::from(1);

        while (trades > 0) {
            let amount_in = rng.generate_u64_in_range(1_000, 500_000_000);

            let (_, vol_1, _, _, _) = omm::quote_swap_impl(
                &pool,
                amount_in,
                true, // a2b
                clock.timestamp_ms(),
            );
        
            let (_, vol_2, _, _, _) = omm::quote_swap_impl(
                &pool,
                amount_in,
                false, // b2a
                clock.timestamp_ms(),
            );

            if (vol_1.gt(vol_2)) {
                assert!(
                    vol_1.le(vol_2.add(precision_err)),
                    0
                );
            };

            if (vol_2.gt(vol_1)) {
                assert!(
                    vol_2.le(vol_1.add(precision_err)),
                    0
                );
            };

            trades = trades - 1;
        };

        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
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
    #[expected_failure(abort_code = omm::EPriceInfoIsZero)]
    fun test_handle_fail_price_info_zero() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::zero_price_info(1, &clock, ctx);
        let price_info_b = test_utils::zero_price_info(2, &clock, ctx);

        let (mut pool, pool_cap) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            2_000, // max_vol_accumulated_bps: 0.2
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_intent = pool.omm_intent_swap(
            50_000,
            true, // a2b
            &clock,
        );

        pool.omm_execute_swap(
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
        destroy(price_info_a);
        destroy(price_info_b);
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

    // tests test-utils for mocking oracle price ahead of a trade that converges
    // towards it.
    #[test]
    fun test_update_pool_price_ahead_of_time() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry_1 = registry::init_for_testing(ctx(&mut scenario));
        let mut registry_2 = registry::init_for_testing(ctx(&mut scenario));
        let (mut clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        let ctx = ctx(&mut scenario);

        
        let price_info_a = test_utils::get_price_info(1, 1, 2, &clock, ctx); // price: 10
        let price_info_b = test_utils::get_price_info(2, 1, 2, &clock, ctx); // price: 10

        let (mut pool_1, pool_cap_1) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry_1,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            0, // reduction_factor_bps: 0.1
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );
        
        let (mut pool_2, pool_cap_2) = omm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry_2,
            0, // swap fees BPS
            &price_info_a,
            &price_info_b,
            60000, // filter_period: 1 minute
            600000, // decay_period: 10 minutes
            0, // fee_control_bps: 0
            0, // reduction_factor_bps: 0.1
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(1_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(1_000_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry_1, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry_2, ctx);

        let (lp_coins_1, _) = pool_1.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );
        
        let (lp_coins_2, _) = pool_2.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(100_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        update_pool_oracle_price_ahead_of_trade(
            &mut pool_1,
            100_000,
            true, // a2b,
            0,
            &mut clock,
        );

        let price_0 = omm::new_instant_price_oracle(&pool_1);

        let swap_intent = pool_2.omm_intent_swap(
            100_000,
            true, // a2b
            &clock,
        );

        pool_2.omm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        let price_1 = omm::instant_price_internal(&pool_2);
        assert_eq(price_0, price_1);

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(price_info_a);
        destroy(price_info_b);
        destroy(registry_1);
        destroy(registry_2);
        destroy(pool_1);
        destroy(pool_cap_1);
        destroy(lp_coins_1);
        destroy(pool_2);
        destroy(pool_cap_2);
        destroy(lp_coins_2);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
}
