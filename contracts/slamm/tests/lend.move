#[test_only]
module slamm::lend_tests {
    // use std::debug::print;
    use slamm::pool::{Self, minimum_liquidity};
    use slamm::registry;
    use slamm::global_admin;
    use slamm::cpmm::{Self};
    use slamm::dummy_hook::{Self};
    use slamm::test_utils::{COIN, reserve_args};
    use slamm::bank;
    use sui::test_scenario::{Self, ctx};
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};
    use sui::random;

    use suilend::test_usdc::{TEST_USDC};
    use suilend::test_sui::{TEST_SUI};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    #[test]
    fun test_lend_amm_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.reserve().value(), 500_000);

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(lp_coins);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_lend_amm_deposit_and_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.reserve().value(), 500_000);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem
        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            499_990,
            499_990,
            &clock,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 10 * 10);
        assert_eq(pool.lp_supply_val(), 10);
        assert_eq(reserve_a, 10);
        assert_eq(reserve_b, 10);
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 10);
        assert_eq(reserve_b, 10);

        assert_eq(bank_a.lent(), 8); // 10 * 80%
        assert_eq(bank_a.reserve().value(), 2); // 10 * 20%
        assert_eq(bank_b.reserve().value(), 10);

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

    #[test]
    fun test_lend_swap_without_touching_lending_market() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let _ = pool.cpmm_swap(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            50_000,
            0,
            true, // a2b
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 549_900);
        assert_eq(reserve_b, 454_960);

        assert_eq(bank_a.lent(), 400_000);
        assert_eq(bank_a.reserve().value(), 149_900);
        assert_eq(bank_b.reserve().value(), 454_960);

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
    fun test_lend_amm_deposit_both() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<TEST_SUI>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            1, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, TEST_SUI, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.reserve().value(), 100_000); // 500_000 * 20%

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
    fun test_lend_amm_deposit_and_redeem_both() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<TEST_SUI>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            1, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, TEST_SUI, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Redeem
        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            499_990,
            499_990,
            &clock,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 10 * 10);
        assert_eq(pool.lp_supply_val(), 10);
        assert_eq(reserve_a, 10);
        assert_eq(reserve_b, 10);
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

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

    #[test]
    fun test_lend_amm_deposit_and_swap_both_below_threshold() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<TEST_SUI>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            1, // reserve_array_index
        );


        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, TEST_SUI, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(0, ctx);

        let swap_intent = pool.cpmm_intent_swap(
            50_000,
            true, // a2b
        );

        assert!(!swap_intent.quote().needs_sync(&bank_a,&bank_b));

        pool.cpmm_execute_swap(
            &mut bank_a,
            &mut bank_b,
            swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );


        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 549_900);
        assert_eq(reserve_b, 454_960);

        assert_eq(bank_a.lent(), 400_000);
        assert_eq(bank_a.reserve().value(), 149_900);
        
        assert_eq(bank_b.lent(), 400_000);
        assert_eq(bank_b.reserve().value(), 54_960);

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
    fun test_lend_amm_deposit_and_swap_both_above_threshold() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<TEST_SUI>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            1, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, TEST_SUI, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

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

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.reserve().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(200_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(0, ctx);

        let mut swap_intent = pool.cpmm_intent_swap(
            200_000,
            true, // a2b
        );

        pool::sync_bank(
            &mut bank_a,
            &mut bank_b,
            &mut lending_market,
            &mut swap_intent,
            &clock,
            ctx,
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

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(reserve_a, 699_600);
        assert_eq(reserve_b, 358_167);

        assert_eq(bank_a.lent(), 400_000);
        assert_eq(bank_a.reserve().value(), 299_600);
        
        assert_eq(bank_b.lent(), 286_534);
        assert_eq(bank_b.reserve().value(), 71_633);

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
    fun test_lend_amm_deposit_all_scenarios() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            500, // liquidity_buffer_bps
            0, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            &clock,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(pool.lp_supply_val(), 100_000);
        assert_eq(reserve_a, 100_000);
        assert_eq(reserve_b, 100_000);
        assert_eq(lp_coins.value(), 100_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().fee_a().acc_fees(), 0);
        assert_eq(pool.pool_fees().fee_b().acc_fees(), 0);

        assert_eq(bank_a.lent(), 80_000); // 100_000 * 80%
        assert_eq(bank_a.reserve().value(), 20_000); // 500_000 * 20%
        assert_eq(bank_b.reserve().value(), 100_000);
        
        assert_eq(bank_a.effective_liquidity_ratio_bps(), 2000); // 20% target liquidity
        assert!(bank_a.compute_lending_action().is_none(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        // Deposit funds in AMM Pool - below buffer - still lend
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            25_000,
            25_000,
            0,
            0,
            &clock,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(pool.lp_supply_val(), 125_000);
        assert_eq(reserve_a, 125_000);
        assert_eq(reserve_b, 125_000);
        assert_eq(lp_coins.value(), 25_000); // newly minted lp tokens
        
        assert_eq(bank_a.lent(), 100_000); // 125_000 * 80%
        assert_eq(bank_a.reserve().value(), 25_000); // 500_000 * 20%
        assert_eq(bank_b.reserve().value(), 125_000);
        
        assert_eq(bank_a.effective_liquidity_ratio_bps(), 2000); // 20% target liquidity
        assert!(bank_a.compute_lending_action().is_none(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);
        
        // Deposit funds in AMM Pool - above buffer - lend
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(5_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(5_000_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            5_000_000,
            5_000_000,
            0,
            0,
            &clock,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();
        assert_eq(pool.lp_supply_val(), 5_125_000);
        assert_eq(reserve_a, 5_125_000);
        assert_eq(reserve_b, 5_125_000);
        assert_eq(lp_coins.value(), 5_000_000); // newly minted lp tokens
        
        assert_eq(bank_a.lent(), 4_100_000); // 5_125_000 * 80%
        assert_eq(bank_a.reserve().value(), 1_025_000); // 5_125_000 * 20%
        assert_eq(bank_b.reserve().value(), 5_125_000);
        
        assert_eq(bank_a.effective_liquidity_ratio_bps(), 2000); // 20% target liquidity
        assert!(bank_a.compute_lending_action().is_none(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_lend_deposit_proptest() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            500, // liquidity_buffer_bps
            0, // reserve_array_index
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000_000_00_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000_000_00_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut lending_market,
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000_000_00_000,
            100_000_000_00_000,
            0,
            0,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        // deposit loop
        let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);
        let mut deposits = 1_000;

        while (deposits > 0) {
            let amount_in = rng.generate_u64_in_range(1_000, 100_000);

            let mut coin_a = coin::mint_for_testing<TEST_USDC>(amount_in, ctx);
            let mut coin_b = coin::mint_for_testing<COIN>(amount_in, ctx);

            let (lp_coins, _) = pool.deposit_liquidity(
                &mut lending_market,
                &mut bank_a,
                &mut bank_b,
                &mut coin_a,
                &mut coin_b,
                amount_in,
                amount_in,
                0,
                0,
                &clock,
                ctx,
            );

            assert_eq(bank_a.effective_liquidity_ratio_bps(), 2000); // 20% target liquidity
            assert!(bank_a.compute_lending_action().is_none(), 0);

            destroy(coin_a);
            destroy(coin_b);
            destroy(lp_coins);

            deposits = deposits - 1;
        };

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
}
