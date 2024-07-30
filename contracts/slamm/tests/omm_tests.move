// TODO: test swaps accross different timestamps
#[test_only]
module slamm::omm_tests {
    use std::debug::print;
    use slamm::registry;
    use slamm::bank;
    use slamm::test_utils::{COIN, reserve_args, update_price};
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::random;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market;
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            4_000, // max_vol_accumulated_bps: 0.4
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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

        let _swap_result = pool.omm_swap(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            50_000,
            0,
            true, // a2b
            &clock,
            ctx,
        );

        assert_eq(pool.inner().reference_val(), decimal::from(0));
        assert_eq(pool.inner().accumulator(), decimal::from_scaled_val(189847865296485492)); // 18..%
        assert_eq(pool.inner().reference_price(), decimal::from(1)); // price = 1
        assert_eq(pool.inner().reference_price(), decimal::from(1)); // price = 1
        assert_eq(pool.inner().last_trade_ts(), clock.timestamp_ms());

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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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
            let (quote, vol) = omm::quote_swap_for_testing(
                &pool,
                swap_amts[len - 1],
                true, // a2b
            );

            let total_fees = decimal::from(
                quote.output_fees().borrow().pool_fees() + quote.output_fees().borrow().protocol_fees()
            );

            let fee_rate = total_fees
            .div(
                decimal::from(
                    quote.amount_out()
                )
            );

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
            let (quote, vol) = omm::quote_swap_for_testing(
                &pool,
                swap_amts[len - 1],
                false, // a2b
            );

            let fee_rate = decimal::from(
                quote.output_fees().borrow().pool_fees()
            )
            .add(
                decimal::from(
                    quote.output_fees().borrow().protocol_fees()
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            100, // max_vol_accumulated_bps: 1%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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
        
        let (_, vol) = omm::quote_swap_for_testing(
            &pool,
            100_000_000,
            true, // a2b
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
    fun test_handle_fail_to_refresh_price() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            100, // max_vol_accumulated_bps: 1%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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

        update_price(
            &mut price_info_a,
            5,
            1,
            &clock,
        );
        
        let (_, vol) = omm::quote_swap_for_testing(
            &pool,
            100_000_000,
            true, // a2b
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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
        
        let (_quote_1, vol_1) = omm::quote_swap_for_testing(
            &pool,
            112_372,
            true, // a2b
        );
        
        let (_quote_2, vol_2) = omm::quote_swap_for_testing(
            &pool,
            112_372,
            false, // b2a
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            400_000, // max_vol_accumulated_bps: 4000%
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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

            let (_quote_1, vol_1) = omm::quote_swap_for_testing(
                &pool,
                amount_in,
                true, // a2b
            );
        
            let (_quote_2, vol_2) = omm::quote_swap_for_testing(
                &pool,
                amount_in,
                false, // b2a
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
            600000, // filter_period: 10 minutes
            10_000, // fee_control_bps: 1
            9_000, // reduction_factor_bps: 0.9
            2_000, // max_vol_accumulated_bps: 0.2
            &clock,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

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

        let _ = pool.omm_swap(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            50_000,
            0,
            true, // a2b
            &clock,
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
}
