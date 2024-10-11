#[test_only]
module slamm::slamm_tests {
    use sui::{
        sui::SUI,
        coin::{Self},
        test_utils::{destroy, assert_eq},
        test_scenario::{Self, ctx},
    };
    use slamm::{
        quote,
        pool_math,
        pool::{Self, minimum_liquidity},
        registry,
        global_admin,
        bank,
        test_utils::{e9, COIN, reserve_args},
        dummy_hook::{Self, swap, intent_swap, execute_swap, quote_swap},
        cpmm::{Self, offset},
    };
    use suilend::lending_market::{Self, LENDING_MARKET};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const LP_PROVIDER: address = @0x12;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    #[test]
    fun test_slamm_deposit_redeem_swap() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.no_redemption_fees_for_testing();

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        let (bank_reserve_a, bank_reserve_b) = (bank_a.funds_available().value(), bank_b.funds_available().value());
        let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

        assert_eq(cpmm::k(&pool, 0), 500000000000000000000000000);
        assert_eq(pool.lp_supply_val(), 22360679774997);
        assert_eq(reserve_a, bank_reserve_a);
        assert_eq(reserve_b, bank_reserve_b);
        assert_eq(reserve_b, e9(500_000));
        assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        destroy(coin_a);
        destroy(coin_b);

        // Deposit liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(10), // max_a
            e9(10), // max_b
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), e9(10) - 20_000_000);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 447213595);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            0,
            0,
            ctx,
        );

        // Guarantees that roundings are in favour of the pool
        assert_eq(coin_a.value(), 20_000_000 - 1); // -1 for the rounddown
        assert_eq(coin_b.value(), e9(10) - 12); // double rounddown: inital lp tokens minted + redeed

        let (reserve_a, reserve_b) = pool.total_funds();
        let (bank_reserve_a, bank_reserve_b) = (bank_a.funds_available().value(), bank_b.funds_available().value());
        assert_eq(reserve_a, bank_reserve_a);
        assert_eq(reserve_b, bank_reserve_b);

        let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_2);

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_result = swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(200),
            0,
            true, // a2b
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        let (bank_reserve_a, bank_reserve_b) = (bank_a.funds_available().value(), bank_b.funds_available().value());
        assert_eq(reserve_a, bank_reserve_a);
        assert_eq(reserve_b, bank_reserve_b);

        assert_eq(swap_result.a2b(), true);
        assert_eq(swap_result.amount_out(), 200000000000);
        assert_eq(swap_result.pool_fees(), 1600000000);
        assert_eq(swap_result.protocol_fees(), 400000000);

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    fun test_full_amm_cycle() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.no_redemption_fees_for_testing();

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

        let (reserve_a, reserve_b) = pool.total_funds();
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

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000, // max_a
            500_000, // max_b
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), 0);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 500_000);
        assert_eq(pool.lp_supply_val(), 500_000 + 500_000);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            0,
            0,
            ctx,
        );

        // Guarantees that roundings are in favour of the pool
        assert_eq(coin_a.value(), 500_000);
        assert_eq(coin_b.value(), 500_000);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_2);

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_result = swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            50_000,
            0,
            true, // a2b
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
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();

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
        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = pool_math::EEffectiveDepositABelowMinA)]
    fun test_fail_deposit_slippage_a() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        // Initial deposit
        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let deposit_result = pool.quote_deposit(
            e9(10), // max_a
            e9(10), // max_b
        );
        
        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(10), // max_a
            e9(10), // max_b
            deposit_result.deposit_a() + 1, // min_a
            deposit_result.deposit_b() + 1, // min_b
            ctx,
        );

        assert_eq(coin_a.value(), e9(10) - 20_000_000);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 447213595);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(registry);
        destroy(coin_a);
        destroy(lp_coins_2);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool_math::EEffectiveDepositBBelowMinB)]
    fun test_fail_deposit_slippage_b() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        // Initial deposit
        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(1_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let deposit_result = pool.quote_deposit(
            e9(10), // max_a
            e9(10), // max_b
        );
        
        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(10), // max_a
            e9(10), // max_b
            deposit_result.deposit_a(), // min_a
            deposit_result.deposit_b() + 1, // min_b
            ctx,
        );

        assert_eq(coin_a.value(), e9(10) - 20_000_000);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 447213595);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(registry);
        destroy(coin_a);
        destroy(lp_coins_2);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool::ESwapExceedsSlippage)]
    fun test_fail_swap_slippage() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();

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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_result = quote_swap(
            &pool,
            e9(200),
            true, // a2b
        );

        let _ = swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(200),
            swap_result.amount_out() + 1,
            true, // a2b
            ctx,
        );

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(pool);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool::EInsufficientFunds)]
    fun test_fail_swap_insufficient_funds() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();

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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(199), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let _ = swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(200),
            0,
            true, // a2b
            ctx,
        );

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(pool);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool_math::ERedeemSlippageAExceeded)]
    fun test_fail_redeem_slippage_a() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(10), // max_a
            e9(10), // max_b
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), e9(10) - 20_000_000);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 447213595);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let redeem_result = pool.quote_redeem(
            lp_coins_2.value()
        );
        
        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            redeem_result.withdraw_a() + 1,
            redeem_result.withdraw_b() + 1,
            ctx,
        );

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(pool);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool_math::ERedeemSlippageBExceeded)]
    fun test_fail_redeem_slippage_b() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(1_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.total_funds();
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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(10), // max_a
            e9(10), // max_b
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), 0);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 10000000000);

        let (reserve_a, reserve_b) = pool.total_funds();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let redeem_result = pool.quote_redeem(
            lp_coins_2.value()
        );
        
        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            redeem_result.withdraw_a(),
            redeem_result.withdraw_b() + 1,
            ctx,
        );

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(pool);
        destroy(bank_a);
        destroy(bank_b);
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
    #[expected_failure(abort_code = pool::EFeeAbove100Percent)]
    fun test_fail_fee_above_100() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            10_000 + 1, // admin fees BPS
            ctx,
        );

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
    #[expected_failure(abort_code = registry::EDuplicatedPoolType)]
    fun test_fail_duplicated_pool_type() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );
        
        let (pool_2, pool_cap_2) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        destroy(registry);
        destroy(pool);
        destroy(pool_2);
        destroy(pool_cap);
        destroy(pool_cap_2);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_slamm_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );
        
        let (mut pool_2, pool_cap_2) = dummy_hook::new<SUI, COIN, Wit2>(
            Wit2 {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200_000_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(200_000_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(100_000_000),
            e9(100_000_000),
            0,
            0,
            ctx,
        );
        
        let (lp_coins_2, _) = pool_2.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(100_000_000),
            e9(100_000_000),
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap first pool
        let expected_pool_fees = 8_000_000_000_000;
        let expected_protocol_fees = 2_000_000_000_000;

        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_result = swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(1_000_000),
            0,
            true, // a2b
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

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let mut len = 1000;

        let mut acc_protocol_fees = 0;
        let mut acc_pool_fees = 0;

        while (len > 0) {
            let swap_result = swap(
                &mut pool_2,
                &mut bank_a,
                &mut bank_b,
                &mut coin_a,
                &mut coin_b,
                e9(10_00),
                0,
                true, // a2b
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
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );
        
        let (coin_a_2, coin_b_2, _) = pool_2.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            0,
            0,
            ctx,
        );

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(coin_a_2);
        destroy(coin_b_2);
        destroy(pool);
        destroy(pool_2);
        destroy(bank_a);
        destroy(bank_b);
        destroy(pool_cap);
        destroy(pool_cap_2);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool::EPoolGuarded)]
    fun test_try_multiple_swap_intents() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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
        let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_intent = intent_swap(
            &mut pool,
            50_000,
            true, // a2b
        );
        
        let swap_intent_2 = intent_swap(
            &mut pool,
            50_000,
            true, // a2b
        );

        execute_swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );
        
        execute_swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            swap_intent_2,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank_a);
        destroy(bank_b);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = pool::EPoolGuarded)]
    fun test_try_swap_intent_and_deposit_in_the_middle() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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
        destroy(lp_coins);

        // Swap
        let swap_intent = intent_swap(
            &mut pool,
            50_000,
            true, // a2b
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        execute_swap(
            &mut pool,
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
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank_a);
        destroy(bank_b);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = pool::EPoolGuarded)]
    fun test_try_swap_intent_and_redeem_in_the_middle() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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
        let swap_intent = intent_swap(
            &mut pool,
            50_000,
            true, // a2b
        );

        let (coin_a_, coin_b_, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );

        destroy(coin_a_);
        destroy(coin_b_);

        let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        execute_swap(
            &mut pool,
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
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank_a);
        destroy(bank_b);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    // Note: This error cannot occur unless there is a bug in the contract.
    // It provides an extra layer of security
    #[test]
    #[expected_failure(abort_code = pool::EPoolUnguarded)]
    fun test_pool_unguarded() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        // create fake intent<
        let intent = pool.intent_for_testing(
            quote::quote_for_testing(
                100,
                100,
                0,
                0,
                true,
            ),
            false
        );

        let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        execute_swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );
        
        destroy(coin_a);
        destroy(coin_b);
        destroy(registry);
        destroy(lp_coins);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank_a);
        destroy(bank_b);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = pool::EOutputExceedsLiquidity)]
    fun test_output_exceeds_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        // create fake intent<
        let intent = pool.intent_for_testing(
            quote::quote_for_testing(
                100,
                500_001, // amount above available reserve
                0,
                0,
                true,
            ),
            true
        );

        let mut coin_a = coin::mint_for_testing<SUI>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        execute_swap(
            &mut pool,
            &mut bank_a,
            &mut bank_b,
            intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );
        
        destroy(coin_a);
        destroy(coin_b);
        destroy(registry);
        destroy(lp_coins);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank_a);
        destroy(bank_b);
        destroy(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_redeem_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(100_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(100_000),
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );

        // Guarantees that roundings are in favour of the pool
        assert_eq(coin_a.value(), 99_899_999_999_990);
        assert_eq(coin_b.value(), 99_899_999_999_990);

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    fun test_min_redeem_fees_ceil() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(100_000), ctx);

        let (mut lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(100_000),
            0,
            0,
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
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), 10 - 1);
        assert_eq(coin_b.value(), 10 - 1);

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    fun test_min_redeem_fees() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.no_redemption_fees_for_testing_with_min_fee();

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(100_000), ctx);

        let (mut lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(100_000),
            0,
            0,
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
            &mut bank_a,
            &mut bank_b,
            lp_coins_2,
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), 10 - 1);
        assert_eq(coin_b.value(), 10 - 1);

        destroy(registry);
        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
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
    
    #[expected_failure(abort_code = pool_math::EEffectiveDepositBBelowMinB)]
    #[test]
    fun test_deposit_with_wrong_ratio() {
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

        let (lp_coins_1, _) = pool.deposit_liquidity(
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
        assert_eq(lp_coins_1.value(), 500_000 - minimum_liquidity());

        destroy(coin_a);
        destroy(coin_b);

        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let (lp_coins_2, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            500_000,
            200_000,
            200_000,
            ctx,
        );

        destroy(lp_coins_1);
        destroy(lp_coins_2);
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
}
