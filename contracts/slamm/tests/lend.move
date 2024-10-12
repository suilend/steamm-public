#[test_only]
module slamm::lend_tests {
    use sui::test_utils::{Self};
    use suilend::mock_pyth::{Self};
    use std::type_name::{Self};
    use slamm::pool::{Self, minimum_liquidity};
    use slamm::registry;
    use slamm::global_admin;
    use slamm::cpmm::{Self};
    use slamm::dummy_hook::{Self, intent_swap, execute_swap};
    use slamm::test_utils::{COIN, reserve_args, reserve_args_2};
    use slamm::bank;
    use sui::{
        test_scenario::{Self, ctx},
        balance,
        bag,
        clock,
        coin,
    };
    use sui::test_utils::{destroy, assert_eq};
    use suilend::{
        lending_market::{Self, LENDING_MARKET},
        reserve::CToken,
    };
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

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
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

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();

        assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.funds_available().value(), 500_000);

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
    fun test_lend_swap_without_touching_lending_market() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
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

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();

        assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let swap_intent = pool.cpmm_intent_swap(
            50_000,
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

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 550_000);
        assert_eq(reserve_b, 454_910);

        assert_eq(bank_a.funds_deployed(), 400_000);
        assert_eq(bank_a.funds_available().value(), 150_000);
        assert_eq(bank_b.funds_available().value(), 454_910);

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
        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario)
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
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

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();

        assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

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
    fun test_lend_amm_deposit_and_swap_both_below_threshold() {
        let mut scenario = test_scenario::begin(ADMIN);

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
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


        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();

        assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(0, ctx);

        let swap_intent = pool.cpmm_intent_swap(
            50_000,
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

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 550_000);
        assert_eq(reserve_b, 454_910);

        assert_eq(bank_a.funds_deployed(), 400_000);
        assert_eq(bank_a.funds_available().value(), 150_000);
        
        assert_eq(bank_b.funds_deployed(), 400_000);
        assert_eq(bank_b.funds_available().value(), 54_910);

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
        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
        );
        
        bank_b.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
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

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();

        assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 500_000);

        assert_eq(bank_a.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
        assert_eq(bank_b.funds_deployed(), 400_000); // 500_000 * 80%
        assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(200_000, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(0, ctx);

        let mut swap_intent = pool.cpmm_intent_swap(
            200_000,
            true, // a2b
        );

        pool::prepare_bank_for_pending_withdraw(
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

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 700_000);
        assert_eq(reserve_b, 358_286);
        assert_eq(reserve_b + pool.trading_data().protocol_fees_b(), 358_572);

        assert_eq(bank_a.funds_deployed(), 400_000);
        assert_eq(bank_a.funds_available().value(), 300_000);
        
        assert_eq(bank_b.funds_deployed(), 286_628);
        assert_eq(bank_b.funds_available().value(), 71_658);

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

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(pool.lp_supply_val(), 100_000);
        assert_eq(reserve_a, 100_000);
        assert_eq(reserve_b, 100_000);
        assert_eq(lp_coins.value(), 100_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        assert_eq(bank_a.funds_deployed(), 80_000); // 100_000 * 80%
        assert_eq(bank_a.funds_available().value(), 20_000); // 500_000 * 20%
        assert_eq(bank_b.funds_available().value(), 100_000);
        
        assert_eq(bank_a.effective_utilisation_bps(), 8000); // 80% target liquidity

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);

        // Deposit funds in AMM Pool - below buffer - does not lent
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(5_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(5_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            5_000,
            5_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(pool.lp_supply_val(), 105_000);
        assert_eq(reserve_a, 105_000);
        assert_eq(reserve_b, 105_000);
        assert_eq(lp_coins.value(), 5_000); // newly minted lp tokens
        
        assert_eq(bank_a.funds_deployed(), 80_000); // 100_000 * 80%
        assert_eq(bank_a.funds_available().value(), 25_000); // 100_000 * 20% + 5_000
        assert_eq(bank_b.funds_available().value(), 105_000);
        
        assert!(bank_a.effective_utilisation_bps() < bank_a.target_utilisation_bps(), 0);
        assert!(bank_a.effective_utilisation_bps() > bank_a.target_utilisation_bps() -  bank_a.utilisation_buffer_bps(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(lp_coins);
        
        // Deposit funds in AMM Pool - above buffer - lend
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(5_000_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(5_000_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            5_000_000,
            5_000_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(pool.lp_supply_val(), 5_105_000);
        assert_eq(reserve_a, 5_105_000);
        assert_eq(reserve_b, 5_105_000);
        assert_eq(lp_coins.value(), 5_000_000); // newly minted lp tokens
        
        assert_eq(bank_a.funds_deployed(), 4_084_000); // 5_105_000 * 80%
        assert_eq(bank_a.funds_available().value(), 1_021_000); // 5_125_000 * 20%
        assert_eq(bank_b.funds_available().value(), 5_105_000);
        
        assert_eq(bank_a.effective_utilisation_bps(), 8000); // 80% target liquidity

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

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000_000_00_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000_000_00_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000_000_00_000,
            100_000_000_00_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
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
                &mut bank_a,
                &mut bank_b,
                &mut coin_a,
                &mut coin_b,
                amount_in,
                amount_in,
                0,
                0,
                ctx,
            );

            bank_a.rebalance(
                &mut lending_market,
                &clock,
                ctx
            );

            bank_b.rebalance(
                &mut lending_market,
                &clock,
                ctx
            );

            assert!(
                bank_a.effective_utilisation_bps().max(8000) - bank_a.effective_utilisation_bps().min(8000) <= 1
            ); // 80% target liquidity (with 0.001% deviation from rounding err)

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

    #[test]
    fun test_lend_amm_redeem_all_scenarios() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000, ctx);

        let (mut lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(pool.lp_supply_val(), 100_000);
        assert_eq(reserve_a, 100_000);
        assert_eq(reserve_b, 100_000);
        assert_eq(lp_coins.value(), 100_000 - minimum_liquidity());
        assert_eq(pool.trading_data().pool_fees_a(), 0);
        assert_eq(pool.trading_data().pool_fees_b(), 0);

        assert_eq(bank_a.funds_deployed(), 80_000); // 100_000 * 80%
        assert_eq(bank_a.funds_available().value(), 20_000); // 100_000 * 20%
        assert_eq(bank_b.funds_available().value(), 100_000);
        
        assert_eq(bank_a.effective_utilisation_bps(), 8000); // 80% target liquidity

        destroy(coin_a);
        destroy(coin_b);

        // Redeem funds in AMM Pool - below buffer - does not recall
        let (coin_a, coin_b, _) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins.split(100, ctx),
            100,
            100,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(pool.lp_supply_val(), 100_000 - 100);
        assert_eq(reserve_a, 100_000 - 100);
        assert_eq(reserve_b, 100_000 - 100);
        assert_eq(lp_coins.value(), 100_000 - 100 - 10); // extra 10 is minimum_liquidity
        
        assert_eq(bank_a.funds_deployed(), 80_000); // amount lent does not change
        assert_eq(bank_a.funds_available().value(), 19_900); // 100_000 * 20% - 100
        assert_eq(bank_b.funds_available().value(), 100_000 - 100);
        
        assert!(bank_a.effective_utilisation_bps() > bank_a.target_utilisation_bps(), 0);
        assert!(bank_a.effective_utilisation_bps() < bank_a.target_utilisation_bps() + bank_a.utilisation_buffer_bps(), 0);

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
    fun test_lend_amm_swap_small_swap_scenarios() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap funds in AMM Pool - below buffer - does not recall
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(10, ctx);

        let swap_intent = intent_swap(
            &mut pool,
            10,
            false, // a2b
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
    fun test_lend_amm_swap_small_swap_scenario_no_op() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap funds in AMM Pool - below buffer - does not recall
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(10, ctx);

        let mut swap_intent = intent_swap(
            &mut pool,
            10,
            false, // a2b
        );

        pool::prepare_bank_for_pending_withdraw(
            &mut bank_a,
            &mut bank_b,
            &mut lending_market,
            &mut swap_intent,
            &clock,
            ctx,
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
    fun test_lend_amm_swap_medium_swap_scenario() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap funds in AMM Pool - above buffer - does not recall
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(20_000, ctx);

        let mut swap_intent = intent_swap(
            &mut pool,
            20_000,
            false, // a2b
        );

        pool::prepare_bank_for_pending_withdraw(
            &mut bank_a,
            &mut bank_b,
            &mut lending_market,
            &mut swap_intent,
            &clock,
            ctx,
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

        assert!(bank_a.effective_utilisation_bps() == bank_a.target_utilisation_bps(), 0);
        
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
    fun test_lend_amm_swap_large_swap_scenario() {
        let mut scenario = test_scenario::begin(ADMIN);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        bank_a.mock_min_token_block_size(10);
        bank_b.mock_min_token_block_size(10);

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            500, // utilisation_bps
            ctx(&mut scenario),
        );

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = dummy_hook::new_no_fees<TEST_USDC, COIN, Wit>(
            Wit {},
            &mut registry,
            0, // admin fees BPS
            ctx,
        );

        // Deposit funds in AMM Pool
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(100_000, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            100_000,
            100_000,
            0,
            0,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );
        
        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap funds in AMM Pool - above buffer - does not recall
        let mut coin_a = coin::mint_for_testing<TEST_USDC>(0, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(30_000, ctx);

        let mut swap_intent = intent_swap(
            &mut pool,
            30_000,
            false, // a2b
        );

        pool::prepare_bank_for_pending_withdraw(
            &mut bank_a,
            &mut bank_b,
            &mut lending_market,
            &mut swap_intent,
            &clock,
            ctx,
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

        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 100_000 - 30_000);
        assert_eq(reserve_b, 100_000 + 30_000);

        assert_eq(bank_a.funds_deployed(), (100_000 - 30_000) * 80 / 100);
        assert_eq(bank_a.funds_available().value(), (100_000 - 30_000) * 20 / 100);
        assert_eq(bank_b.funds_available().value(), 100_000 + 30_000);
        
        assert!(bank_a.effective_utilisation_bps() == bank_a.target_utilisation_bps(), 0);
        
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
    #[expected_failure(abort_code = bank::EInvalidCTokenRatio)]
    public fun test_fail_invalid_ctoken_ratio() {
        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let (mut clock, owner_cap, mut lending_market, mut prices, type_to_index) = lending_market::setup(reserve_args_2(&mut scenario), &mut scenario).destruct_state();

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
        let mut bank_sui = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_sui.mock_min_token_block_size(10);

        bank_sui.deposit_for_testing(1_000_000);
        
        bank_sui.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_bps
            1_000, // utilisation_bps
            ctx(&mut scenario),
        );
        
        bank_sui.rebalance(
            &mut lending_market,
            &clock,
            ctx(&mut scenario),
        );

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            5 * 1_000_000_000,
            test_scenario::ctx(&mut scenario)
        );
        test_utils::destroy(sui);

        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 2, &clock); // $10
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        // liquidate the obligation
        let mut sui = coin::mint_for_testing<TEST_SUI>(1 * 1_000_000_000, test_scenario::ctx(&mut scenario));
        let (usdc, _exemption) = lending_market::liquidate<LENDING_MARKET, TEST_SUI, TEST_USDC>(
            &mut lending_market,
            lending_market::obligation_id(&obligation_owner_cap),
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            &mut sui,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::forgive<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            lending_market::obligation_id(&obligation_owner_cap),
            &clock,
            1_000_000_000 + 10_000,
        );

        balance::destroy_for_testing(
            bank_sui.withdraw_for_testing(150000)
        );

        bank_sui.rebalance(
            &mut lending_market,
            &clock,
            ctx(&mut scenario),
        );

        test_utils::destroy(usdc);
        test_utils::destroy(sui);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_utils::destroy(bank_sui);
        test_utils::destroy(global_admin);
        test_utils::destroy(registry);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = bank::EInvalidCTokenRatio)]
    public fun test_fail_invalid_ctoken_ratio_2() {
        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let (mut clock, owner_cap, mut lending_market, mut prices, type_to_index) = lending_market::setup(reserve_args_2(&mut scenario), &mut scenario).destruct_state();

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
        let mut bank_sui = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_sui.mock_min_token_block_size(10);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_SUI>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let idx = lending_market.reserve_array_index<LENDING_MARKET, TEST_SUI>();
        let reserves = lending_market.reserves_mut_for_testing();
        let reserve = &mut reserves[idx];
        // This is to change the underlying token ratio
        reserve.burn_ctokens_for_testing(
            balance::create_for_testing<CToken<LENDING_MARKET, TEST_SUI>>(52_000_000_000)
        );

        // Init bank lending
        bank_sui.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            10_000, // utilisation_bps
            0, // utilisation_bps
            ctx(&mut scenario),
        );

        // Deposit
        bank_sui.deposit_for_testing(30);
        
        bank_sui.rebalance(
            &mut lending_market,
            &clock,
            ctx(&mut scenario),
        );

        bank_sui.set_utilisation_bps(
            &global_admin,
            0, // utilisation_bps
            0, // utilisation_bps
        );

        // Withdraw
        bank_sui.rebalance(
            &mut lending_market,
            &clock,
            ctx(&mut scenario),
        );

        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_utils::destroy(bank_sui);
        test_utils::destroy(global_admin);
        test_utils::destroy(registry);
        test_utils::destroy(ctokens);
        test_scenario::end(scenario);
    }
    
    #[test]
    public fun test_no_op_below_min_deploy_amount() {
        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let (clock, owner_cap, mut lending_market, prices, type_to_index) = lending_market::setup(reserve_args_2(&mut scenario), &mut scenario).destruct_state();

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
        let mut bank_sui = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
        bank_sui.mock_min_token_block_size(10);

        bank_sui.deposit_for_testing(1);
        bank_sui.init_lending<LENDING_MARKET, TEST_SUI>(
            &global_admin,
            &mut lending_market,
            10_000, // utilisation_bps
            0, // utilisation_bps
            ctx(&mut scenario),
        );

        let effective_utilisation_bps_before = bank_sui.effective_utilisation_bps();

        bank_sui.rebalance(
            &mut lending_market,
            &clock,
            ctx(&mut scenario),
        );

        let effective_utilisation_bps_after = bank_sui.effective_utilisation_bps();

        assert!(effective_utilisation_bps_before == effective_utilisation_bps_after, 0);

        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_utils::destroy(bank_sui);
        test_utils::destroy(global_admin);
        test_utils::destroy(registry);
        test_scenario::end(scenario);
    }
}
