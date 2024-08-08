
module slamm::bank_tests {
    use sui::{
        test_scenario::{Self, ctx},
        test_utils::destroy,
    };
    use slamm::{
        bank,
        registry,
        global_admin,
        test_utils::{COIN, reserve_args},
    };
    use suilend::{
        lending_market::{Self, LENDING_MARKET},
    };
    use suilend::test_usdc::{TEST_USDC};

    public struct FAKE_LENDING has drop {}

    #[test]
    fun test_create_bank() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        // Create amm bank
        let bank = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        destroy(bank);
        destroy(registry);
        destroy(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = registry::EDuplicatedBankType)]
    fun test_fail_create_duplicate_bank() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        // Create bank
        let bank_1 = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));
        let bank_2 = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx(&mut scenario));

        destroy(bank_1);
        destroy(bank_2);
        destroy(registry);
        destroy(scenario);
    }

    #[test]
    fun test_init_lending() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();

        // Create bank
        let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        bank.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_rate
            1_000, // utilisation_buffer
            ctx(&mut scenario),
        );

        destroy(clock);
        destroy(bank);
        destroy(prices);
        destroy(bag);
        destroy(lend_cap);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = bank::ELendingAlreadyActive)]
    fun test_fail_init_lending_twice() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();

        // Create bank
        let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        bank.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_rate
            1_000, // utilisation_buffer
            ctx(&mut scenario),
        );
        
        bank.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_rate
            1_000, // utilisation_buffer
            ctx(&mut scenario),
        );

        destroy(clock);
        destroy(bank);
        destroy(prices);
        destroy(bag);
        destroy(lend_cap);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(scenario);
    }

    #[test]
    #[expected_failure(abort_code = bank::EUtilisationRangeAboveHundredPercent)]
    fun test_invalid_utilisation_liquidity_above_100() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            10_001, // utilisation_rate
            1_000, // buffer
            ctx(&mut scenario),
        );

        destroy(bank_a);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = bank::EUtilisationRangeBelowHundredPercent)]
    fun test_invalid_target_liquidity_below_100() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank_a = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));

        bank_a.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            1_000, // utilisation_rate
            1_001, // utilisation_buffer
            ctx(&mut scenario),
        );

        destroy(bank_a);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = bank::EEmptyBank)]
    fun test_fail_assert_empty_bank() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));

        bank.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_rate
            500, // utilisation_buffer
            ctx(&mut scenario),
        );

        bank.assert_utilisation();

        destroy(bank);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = bank::EUtilisationRateOffTarget)]
    fun test_fail_assert_utilisation_rate() {
        let mut scenario = test_scenario::begin(@0x0);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));

        let (clock, lend_cap, mut lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        // Create amm bank
        let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

        let mut bank = bank::create_bank<LENDING_MARKET, TEST_USDC>(&mut registry, ctx(&mut scenario));

        bank.init_lending<LENDING_MARKET, TEST_USDC>(
            &global_admin,
            &mut lending_market,
            8_000, // utilisation_rate
            500, // utilisation_buffer
            ctx(&mut scenario),
        );

        bank.mock_amount_lent(1_000);

        bank.assert_utilisation();

        destroy(bank);
        destroy(registry);
        destroy(global_admin);
        destroy(lending_market);
        destroy(lend_cap);
        destroy(prices);
        destroy(bag);
        destroy(clock);
        test_scenario::end(scenario);
    }
}