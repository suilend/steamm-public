#[test_only]
module slamm::smm_tests {
    use slamm::registry;
    use slamm::bank;
    use slamm::smm;
    use slamm::test_utils::{COIN, reserve_args, e9};
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    #[test]
    fun test_smm_trade_within_bounds() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            20_000, // 200%
            5_000, // 50%
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


        let swap_intent = pool.smm_intent_swap(
            50_000,
            true, // a2b
        );

        let swap_result = pool.smm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        assert_eq(swap_result.a2b(), true);
        assert_eq(swap_result.pool_fees(), 0);
        assert_eq(swap_result.protocol_fees(), 0);
        assert_eq(swap_result.amount_out(), 50_000);

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
    fun test_smm_trade_at_the_upper_bounds() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            20_000, // 200%
            5_000, // 50%
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

        let swap_intent = pool.smm_intent_swap(
            166_666,
            true, // a2b
        );

        pool.smm_execute_swap(
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
    #[expected_failure(abort_code = smm::EInvalidReserveRatio)]
    fun test_smm_trade_outside_upper_bound() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            20_000, // 200%
            5_000, // 50%
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

        let swap_intent = pool.smm_intent_swap(
            166_666 + 1, // we add one here to go outside the bounds
            true, // a2b
        );

        pool.smm_execute_swap(
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
    fun test_smm_trade_at_the_lower_bound() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            20_000, // 200%
            5_000, // 50%
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

        let mut coin_a = coin::mint_for_testing<SUI>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(200), ctx);

        let swap_intent = pool.smm_intent_swap(
            166_666,
            false, // a2b
        );

        pool.smm_execute_swap(
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
    #[expected_failure(abort_code = smm::EInvalidReserveRatio)]
    fun test_smm_trade_outside_lower_bound() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            20_000, // 200%
            5_000, // 50%
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

        let mut coin_a = coin::mint_for_testing<SUI>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(200), ctx);

        let swap_intent = pool.smm_intent_swap(
            166_666 + 1, // we add one here to go outside the bounds
            false, // a2b
        );

        pool.smm_execute_swap(
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
    
    // #[test]
    // fun test_smm_deposit_redeem_swap() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(1_000),
    //         e9(500_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    //     assert_eq(pool.cpmm_k(), 500000000000000000000000000);
    //     assert_eq(pool.lp_supply_val(), 22360679774997);
    //     assert_eq(reserve_a, e9(1_000));
    //     assert_eq(reserve_b, e9(500_000));
    //     assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    //     assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
    //     assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Deposit liquidity
    //     test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

    //     let (lp_coins_2, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(10), // max_a
    //         e9(10), // max_b
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     assert_eq(coin_a.value(), e9(10) - 20_000_000);
    //     assert_eq(coin_b.value(), 0);
    //     assert_eq(lp_coins_2.value(), 447213595);

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    //     assert_eq(reserve_ratio_0, reserve_ratio_1);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Redeem liquidity
    //     test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    //     let ctx = ctx(&mut scenario);

    //     let (coin_a, coin_b, _) = pool.redeem_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         lp_coins_2,
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     // Guarantees that roundings are in favour of the pool
    //     assert_eq(coin_a.value(), 20_000_000 - 1); // -1 for the rounddown
    //     assert_eq(coin_b.value(), e9(10) - 12); // double rounddown: inital lp tokens minted + redeed

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    //     assert_eq(reserve_ratio_0, reserve_ratio_2);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Swap
    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

    //     let swap_result = pool.smm_swap(
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(200),
    //         0,
    //         true, // a2b
    //         ctx,
    //     );

    //     assert_eq(swap_result.a2b(), true);
    //     assert_eq(swap_result.amount_out(), 83333333333265);
    //     assert_eq(swap_result.pool_fees(), 666666666666);
    //     assert_eq(swap_result.protocol_fees(), 166666666667);

    //     destroy(registry);
    //     destroy(coin_a);
    //     destroy(coin_b);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(pool);
    //     destroy(lp_coins);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }

    // #[test]
    // #[expected_failure(abort_code = pool::ESwapOutputAmountIsZero)]
    // fun test_fail_handle_full_precision_loss_from_highly_imbalanced_pool() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(500_000_000_000_000, ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(1, ctx);

    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         500_000_000_000_000,
    //         1,
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // // Swap
    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

    //     let _swap_result = pool.smm_swap(
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         50_000,
    //         0,
    //         true, // a2b
    //         ctx,
    //     );

    //     destroy(coin_a);
    //     destroy(coin_b);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(registry);
    //     destroy(lp_coins);
    //     destroy(pool);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // fun test_trade_that_balances_highly_imbalanced_pool() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(500_000_000_000_000, ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(1, ctx);

    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         500_000_000_000_000,
    //         1,
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Swap
    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(0, ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(10_000_000_000_000, ctx);

    //     let swap_result = pool.smm_swap(
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         10_000_000_000_000,
    //         0,
    //         false, // a2b
    //         ctx,
    //     );

    //     assert_eq(swap_result.amount_out(), 499999999999950);
    //     assert_eq(swap_result.amount_in(), 10000000000000);
    //     assert_eq(swap_result.protocol_fees(), 1000000000000);
    //     assert_eq(swap_result.pool_fees(), 4000000000000);
    //     assert_eq(swap_result.a2b(), false);

    //     destroy(coin_a);
    //     destroy(coin_b);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(registry);
    //     destroy(lp_coins);
    //     destroy(pool);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // #[expected_failure(abort_code = pool::EInsufficientDepositA)]
    // fun test_fail_deposit_slippage_a() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

    //     // Initial deposit
    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(1_000),
    //         e9(500_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    //     assert_eq(pool.cpmm_k(), 500000000000000000000000000);
    //     assert_eq(pool.lp_supply_val(), 22360679774997);
    //     assert_eq(reserve_a, e9(1_000));
    //     assert_eq(reserve_b, e9(500_000));
    //     assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
    //     assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
    //     assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Deposit liquidity
    //     test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

    //     let deposit_result = pool.quote_deposit(
    //         e9(10), // max_a
    //         e9(10), // max_b
    //     );
        
    //     let (lp_coins_2, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(10), // max_a
    //         e9(10), // max_b
    //         deposit_result.deposit_a() + 1, // min_a
    //         deposit_result.deposit_b() + 1, // min_b
    //         &clock,
    //         ctx,
    //     );

    //     assert_eq(coin_a.value(), e9(10) - 20_000_000);
    //     assert_eq(coin_b.value(), 0);
    //     assert_eq(lp_coins_2.value(), 447213595);

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    //     assert_eq(reserve_ratio_0, reserve_ratio_1);

    //     destroy(registry);
    //     destroy(coin_a);
    //     destroy(lp_coins_2);
    //     destroy(coin_b);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(pool);
    //     destroy(lp_coins);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // #[expected_failure(abort_code = pool::EInsufficientDepositB)]
    // fun test_fail_deposit_slippage_b() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

    //     // Initial deposit
    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(1_000),
    //         e9(1_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

    //     assert_eq(pool.cpmm_k(), 1000000000000000000000000);
    //     assert_eq(pool.lp_supply_val(), 1000000000000);
    //     assert_eq(reserve_a, e9(1_000));
    //     assert_eq(reserve_b, e9(1_000));
    //     assert_eq(lp_coins.value(), 1000000000000 - minimum_liquidity());
    //     assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
    //     assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Deposit liquidity
    //     test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

    //     let deposit_result = pool.quote_deposit(
    //         e9(10), // max_a
    //         e9(10), // max_b
    //     );
        
    //     let (lp_coins_2, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(10), // max_a
    //         e9(10), // max_b
    //         deposit_result.deposit_a(), // min_a
    //         deposit_result.deposit_b() + 1, // min_b
    //         &clock,
    //         ctx,
    //     );

    //     assert_eq(coin_a.value(), e9(10) - 20_000_000);
    //     assert_eq(coin_b.value(), 0);
    //     assert_eq(lp_coins_2.value(), 447213595);

    //     let (reserve_a, reserve_b) = pool.total_funds();
    //     let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
    //     assert_eq(reserve_ratio_0, reserve_ratio_1);

    //     destroy(registry);
    //     destroy(coin_a);
    //     destroy(lp_coins_2);
    //     destroy(coin_b);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(pool);
    //     destroy(lp_coins);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // #[expected_failure(abort_code = pool::ESwapExceedsSlippage)]
    // fun test_fail_swap_slippage() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(1_000),
    //         e9(500_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Swap
    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

    //     let swap_result = pool.smm_quote_swap(
    //         e9(200),
    //         true, // a2b
    //     );

    //     let _ = pool.smm_swap(
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(200),
    //         swap_result.amount_out() + 1,
    //         true, // a2b
    //         ctx,
    //     );

    //     destroy(registry);
    //     destroy(coin_a);
    //     destroy(coin_b);
    //     destroy(pool);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(lp_coins);
    //     destroy(pool_cap);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // fun test_smm_fees() {
    //     let mut scenario = test_scenario::begin(ADMIN);

    //     // Init Pool
    //     test_scenario::next_tx(&mut scenario, POOL_CREATOR);

    //     let mut registry = registry::init_for_testing(ctx(&mut scenario));
    //     let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
    //     let ctx = ctx(&mut scenario);

    //     let (mut pool, pool_cap) = smm::new<SUI, COIN, Wit>(
    //         Wit {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );
        
    //     let (mut pool_2, pool_cap_2) = smm::new<SUI, COIN, Wit2>(
    //         Wit2 {},
    //         &mut registry,
    //         100, // admin fees BPS
    //         ctx,
    //     );

    //     let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
    //     let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(200_000_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(e9(200_000_000), ctx);

    //     let (lp_coins, _) = pool.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(100_000_000),
    //         e9(100_000_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );
        
    //     let (lp_coins_2, _) = pool_2.deposit_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(100_000_000),
    //         e9(100_000_000),
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Swap first pool
    //     let expected_pool_fees = 7_920_792_079_208;
    //     let expected_protocol_fees = 1_980_198_019_802;

    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

    //     let swap_result = pool.smm_swap(
    //         &mut bank_a,
    //         &mut bank_b,
    //         &mut coin_a,
    //         &mut coin_b,
    //         e9(1_000_000),
    //         0,
    //         true, // a2b
    //         ctx,
    //     );

    //     assert_eq(swap_result.a2b(), true);
    //     assert_eq(swap_result.pool_fees(), expected_pool_fees);
    //     assert_eq(swap_result.protocol_fees(), expected_protocol_fees);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Swap second pool
    //     test_scenario::next_tx(&mut scenario, TRADER);
    //     let ctx = ctx(&mut scenario);

    //     let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000_000), ctx);
    //     let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

    //     let mut len = 1000;

    //     let mut acc_protocol_fees = 0;
    //     let mut acc_pool_fees = 0;

    //     while (len > 0) {
    //         let swap_result = pool_2.smm_swap(
    //             &mut bank_a,
    //             &mut bank_b,
    //             &mut coin_a,
    //             &mut coin_b,
    //             e9(10_00),
    //             0,
    //             true, // a2b
    //             ctx,
    //         );

    //         acc_protocol_fees = acc_protocol_fees + swap_result.protocol_fees();
    //         acc_pool_fees = acc_pool_fees + swap_result.pool_fees();

    //         len = len - 1;
    //     };

    //     // Assert that cumulative fees from small swaps are not smaller
    //     // than a bigger swap
    //     assert!(acc_protocol_fees >= expected_protocol_fees, 0);
    //     assert!(acc_pool_fees >= expected_pool_fees, 0);

    //     destroy(coin_a);
    //     destroy(coin_b);

    //     // Redeem liquidity
    //     test_scenario::next_tx(&mut scenario, LP_PROVIDER);
    //     let ctx = ctx(&mut scenario);

    //     let (coin_a, coin_b, _) = pool.redeem_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         lp_coins,
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );
        
    //     let (coin_a_2, coin_b_2, _) = pool_2.redeem_liquidity(
    //         &mut lending_market,
    //         &mut bank_a,
    //         &mut bank_b,
    //         lp_coins_2,
    //         0,
    //         0,
    //         &clock,
    //         ctx,
    //     );

    //     destroy(registry);
    //     destroy(coin_a);
    //     destroy(coin_b);
    //     destroy(coin_a_2);
    //     destroy(coin_b_2);
    //     destroy(pool);
    //     destroy(pool_2);
    //     destroy(bank_a);
    //     destroy(bank_b);
    //     destroy(pool_cap);
    //     destroy(pool_cap_2);
    //     destroy(lend_cap);
    //     destroy(prices);
    //     destroy(clock);
    //     destroy(bag);
    //     destroy(lending_market);
    //     test_scenario::end(scenario);
    // }
}
