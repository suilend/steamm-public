#[test_only]
module slamm::lend_tests {
    use std::debug::print;
    use slamm::pool::{Self, minimum_liquidity};
    use slamm::registry;
    use slamm::global_admin;
    use slamm::cpmm::{Self};
    use slamm::test_utils::COIN;
    use slamm::lend;
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};
    use suilend::lending_market_registry;

    use suilend::test_usdc::{TEST_USDC};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const LP_PROVIDER: address = @0x12;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    #[test]
    fun test_lend_amm_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup_external(&mut scenario);
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = lend::init_bank<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.init_lending_a<TEST_USDC, COIN, cpmm::Hook<Wit>, cpmm::State, LENDING_MARKET>(&pool_cap, &bank);

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut intent = pool.intent_deposit(
            500_000,
            500_000,
            0,
            0,
        );

        let (lp_coins, _) = pool.execute_deposit(&mut coin_a, &mut coin_b, &mut intent, ctx);

        pool.push_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        pool.consume(intent);

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().acc_fees_a(), 0);
        assert_eq(pool.pool_fees().acc_fees_b(), 0);

        let (fractional_reserve_a, fractional_reserve_b) = pool.fractional_reserves();
        print(&fractional_reserve_a);
        print(&fractional_reserve_b);
        assert_eq(fractional_reserve_a, 0);
        assert_eq(fractional_reserve_b, 500_000);

        assert_eq(bank.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank.reserve().value(), 100_000); // 500_000 * 20%

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
        destroy(bank);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_lend_amm_deposit_and_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Create lending registry and market
        // let lending_registry = lending_market_registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup_external(&mut scenario);
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = lend::init_bank<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.init_lending_a<TEST_USDC, COIN, cpmm::Hook<Wit>, cpmm::State, LENDING_MARKET>(&pool_cap, &bank);

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut intent = pool.intent_deposit(
            500_000,
            500_000,
            0,
            0,
        );

        let (lp_coins, _) = pool.execute_deposit(&mut coin_a, &mut coin_b, &mut intent, ctx);

        pool.push_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        pool.consume(intent);

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().acc_fees_a(), 0);
        assert_eq(pool.pool_fees().acc_fees_b(), 0);

        let (fractional_reserve_a, fractional_reserve_b) = pool.fractional_reserves();
        assert_eq(fractional_reserve_a, 0);
        assert_eq(fractional_reserve_b, 500_000);

        assert_eq(bank.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Redeem
        let mut intent = pool.intent_redeem(&lp_coins, 499_990, 499_990);

        pool.pull_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        let (coin_a, coin_b, _) = pool.execute_redeem(
            lp_coins,
            &mut intent,
            ctx,
        );

        pool.consume(intent);

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 10 * 10);
        assert_eq(pool.lp_supply_val(), 10);
        assert_eq(reserve_a, 10);
        assert_eq(reserve_b, 10);
        assert_eq(pool.pool_fees().acc_fees_a(), 0);
        assert_eq(pool.pool_fees().acc_fees_b(), 0);

        let (fractional_reserve_a, fractional_reserve_b) = pool.fractional_reserves();
        assert_eq(fractional_reserve_a, 0);
        assert_eq(fractional_reserve_b, 10);

        assert_eq(bank.lent(), 8); // 10 * 80%
        assert_eq(bank.reserve().value(), 2); // 10 * 20%

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
        destroy(bank);
        destroy(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_lend_amm_deposit_redeem_and_swap() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup_external(&mut scenario);
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = lend::init_bank<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.init_lending_a<TEST_USDC, COIN, cpmm::Hook<Wit>, cpmm::State, LENDING_MARKET>(&pool_cap, &bank);

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut intent = pool.intent_deposit(
            500_000,
            500_000,
            0,
            0,
        );

        let (lp_coins, _) = pool.execute_deposit(&mut coin_a, &mut coin_b, &mut intent, ctx);

        pool.push_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        pool.consume(intent);

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.pool_fees().acc_fees_a(), 0);
        assert_eq(pool.pool_fees().acc_fees_b(), 0);

        let (fractional_reserve_a, fractional_reserve_b) = pool.fractional_reserves();
        assert_eq(fractional_reserve_a, 0);
        assert_eq(fractional_reserve_b, 500_000);

        assert_eq(bank.lent(), 400_000); // 500_000 * 80%
        assert_eq(bank.reserve().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Redeem
        let mut intent = pool.intent_redeem(&lp_coins, 499_990, 499_990);

        pool.pull_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        let (coin_a, coin_b, _) = pool.execute_redeem(
            lp_coins,
            &mut intent,
            ctx,
        );

        pool.consume(intent);

        let (reserve_a, reserve_b) = pool.reserves();

        assert_eq(pool.cpmm_k(), 10 * 10);
        assert_eq(pool.lp_supply_val(), 10);
        assert_eq(reserve_a, 10);
        assert_eq(reserve_b, 10);
        assert_eq(pool.pool_fees().acc_fees_a(), 0);
        assert_eq(pool.pool_fees().acc_fees_b(), 0);

        let (fractional_reserve_a, fractional_reserve_b) = pool.fractional_reserves();
        assert_eq(fractional_reserve_a, 0);
        assert_eq(fractional_reserve_b, 10);

        assert_eq(bank.lent(), 8); // 10 * 80%
        assert_eq(bank.reserve().value(), 2); // 10 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let mut swap_intent = pool.cpmm_intent_swap(
            50_000,
            true, // a2b
        );

        let res = pool.cpmm_execute_swap(
            &mut swap_intent,
            &mut coin_a,
            &mut coin_b,
            0,
            ctx,
        );

        pool.push_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut swap_intent,
            &clock,
            ctx
        );

        pool.consume(swap_intent);


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
        destroy(bank);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_lend_full_amm_cycle() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup_external(&mut scenario);
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = lend::init_bank<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &lending_market,
            2_000, // liquidity_ratio_bps
            1_000, // liquidity_buffer_bps
            0, // reserve_array_index
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        pool.init_lending_a<TEST_USDC, COIN, cpmm::Hook<Wit>, cpmm::State, LENDING_MARKET>(&pool_cap, &bank);

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut intent = pool.intent_deposit(
            500_000,
            500_000,
            0,
            0,
        );

        let (lp_coin, deposit_result) = pool.execute_deposit(&mut coin_a, &mut coin_b, &mut intent, ctx);

        pool.push_bank_a_checked(
            &mut bank,
            &mut lending_market,
            &mut intent,
            &clock,
            ctx
        );

        pool.consume(intent);

        // destroy(intent);

        // let (lp_coin, deposit_result) = pool.execute_deposit(
        //     &mut coin_a,
        //     &mut coin_b,
        //     &mut intent,
        //     ctx,
        // );

        // pool.push_bank_a(&mut bank, &mut intent);

        // let (reserve_a, reserve_b) = pool.reserves();
        // let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

        // assert_eq(pool.cpmm_k(), 500_000 * 500_000);
        // assert_eq(pool.lp_supply_val(), 500_000);
        // assert_eq(reserve_a, 500_000);
        // assert_eq(reserve_b, 500_000);
        // assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        // assert_eq(pool.pool_fees().acc_fees_a(), 0);
        // assert_eq(pool.pool_fees().acc_fees_b(), 0);

        // destroy(coin_a);
        // destroy(coin_b);

        // // Deposit liquidity
        // test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        // let ctx = ctx(&mut scenario);

        // let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        // let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        // let (lp_coins_2, _) = pool.deposit_liquidity(
        //     &mut coin_a,
        //     &mut coin_b,
        //     500_000, // max_a
        //     500_000, // max_b
        //     0,
        //     0,
        //     ctx,
        // );

        // assert_eq(coin_a.value(), 0);
        // assert_eq(coin_b.value(), 0);
        // assert_eq(lp_coins_2.value(), 500_000);
        // assert_eq(pool.lp_supply_val(), 500_000 + 500_000);

        // let (reserve_a, reserve_b) = pool.reserves();
        // let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        // assert_eq(reserve_ratio_0, reserve_ratio_1);

        // destroy(coin_a);
        // destroy(coin_b);

        // // Redeem liquidity
        // test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        // let ctx = ctx(&mut scenario);

        // let (coin_a, coin_b, _) = pool.redeem_liquidity(
        //     lp_coins_2,
        //     0,
        //     0,
        //     ctx,
        // );

        // // Guarantees that roundings are in favour of the pool
        // assert_eq(coin_a.value(), 500_000);
        // assert_eq(coin_b.value(), 500_000);

        // let (reserve_a, reserve_b) = pool.reserves();
        // let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        // assert_eq(reserve_ratio_0, reserve_ratio_2);

        // destroy(coin_a);
        // destroy(coin_b);

        // // Swap
        // test_scenario::next_tx(&mut scenario, TRADER);
        // let ctx = ctx(&mut scenario);

        // let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        // let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        // let swap_result = pool.cpmm_swap(
        //     &mut coin_a,
        //     &mut coin_b,
        //     50_000,
        //     0,
        //     true, // a2b
        //     ctx,
        // );

        // assert_eq(swap_result.a2b(), true);
        // assert_eq(swap_result.pool_fees(), 400);
        // assert_eq(swap_result.protocol_fees(), 100);
        // assert_eq(swap_result.amount_out(), 45040);

        // destroy(coin_a);
        // destroy(coin_b);

        // // Redeem remaining liquidity
        // test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        // let ctx = ctx(&mut scenario);

        // let (coin_a, coin_b, _) = pool.redeem_liquidity(
        //     lp_coins,
        //     0,
        //     0,
        //     ctx,
        // );

        // let (reserve_a, reserve_b) = pool.reserves();

        // // Guarantees that roundings are in favour of the pool
        // assert_eq(coin_a.value(), 549_889);
        // assert_eq(coin_b.value(), 454_950);
        // assert_eq(reserve_a, 11);
        // assert_eq(reserve_b, 10);
        // assert_eq(pool.lp_supply_val(), minimum_liquidity());

        // destroy(coin_a);
        // destroy(coin_b);

        // // Collect Protocol fees
        // let global_admin = global_admin::init_for_testing(ctx);
        // let (coin_a, coin_b) = pool.collect_protocol_fees(&global_admin, ctx);

        // assert_eq(coin_a.value(), 100);
        // assert_eq(coin_b.value(), 0);
        // assert_eq(pool.protocol_fees().fee_data().acc_fees_a(), 100);
        // assert_eq(pool.protocol_fees().fee_data().acc_fees_b(), 0);
        // assert_eq(pool.pool_fees().acc_fees_a(), 400);
        // assert_eq(pool.pool_fees().acc_fees_b(), 0);
        
        // assert_eq(pool.trading_data().total_swap_a_in_amount(), 50_000);
        // assert_eq(pool.trading_data().total_swap_b_out_amount(), 45040);
        // assert_eq(pool.trading_data().total_swap_a_out_amount(), 0);
        // assert_eq(pool.trading_data().total_swap_b_in_amount(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coin);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(bank);
        destroy(clock);
        test_scenario::end(scenario);
    }
}
