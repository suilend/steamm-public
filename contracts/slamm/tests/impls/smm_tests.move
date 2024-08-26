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
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
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
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
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
        assert_eq(swap_result.pool_fees(), 9); // hook fees
        assert_eq(swap_result.protocol_fees(), 3); // hook fees
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
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
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
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
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
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
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
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
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
            166_666 + 100, // we add 100 here to go outside the bounds
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
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
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
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
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
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
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
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            0,
            0,
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
            166_666 + 100, // we 100 here to go outside the bounds
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
}
