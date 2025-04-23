#[test_only]
module steamm::oracle_v2_tests;

use std::debug::print;
use std::string::utf8;
use suilend::decimal;
use oracles::oracles::{Self, OracleRegistry};
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::bank::{Bank};
use steamm::lp_sui_usdc::LP_SUI_USDC;
use steamm::dummy_omm::{Self, OracleQuoter};
use steamm::omm_v2::{Self, OracleQuoterV2};
use steamm::pool::{Pool};
use steamm::test_utils::{base_setup_2};
use steamm::global_admin;
use steamm::utils::decimal_to_fixedpoint64;
use sui::clock::{Self};
use sui::coin;
use sui::balance;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market::{LendingMarket};
use suilend::lending_market_tests::{LENDING_MARKET};
use suilend::mock_pyth::{Self, PriceState};
use suilend::test_sui::{TEST_SUI};
use suilend::test_usdc::{TEST_USDC};
use steamm::test_utils::{e9, e6};
use steamm::fixed_point64::{Self as fp64};

fun setup(
    fee_bps: u64,
    amplifier: u64,
    scenario: &mut Scenario,
): (
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoter, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    OracleRegistry,
    PriceState,
    LendingMarket<LENDING_MARKET>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
) {
    let (
        bank_usdc,
        bank_sui,
        lending_market,
        lend_cap,
        price_state,
        bag,
        clock,
        mut registry,
        meta_b_usdc,
        meta_b_sui,
        meta_usdc,
        meta_sui,
        mut meta_lp_sui_usdc,
        treasury_cap_lp,
    ) = base_setup_2(option::none(), scenario);

    let (mut oracle_registry, admin_cap) = oracles::new_oracle_registry_for_testing(
        oracles::new_oracle_registry_config(
            60,
            10,
            60,
            10,
            scenario.ctx(),
        ),
        scenario.ctx(),
    );

    oracle_registry.add_pyth_oracle(
        &admin_cap,
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        scenario.ctx(),
    );

    oracle_registry.add_pyth_oracle(
        &admin_cap,
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        scenario.ctx(),
    );

    let pool = dummy_omm::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        fee_bps,
        scenario.ctx(),
    );

    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        amplifier,
        fee_bps,
        scenario.ctx(),
    );

    sui::test_utils::destroy(admin_cap);
    sui::test_utils::destroy(meta_lp_sui_usdc);
    sui::test_utils::destroy(meta_b_usdc);
    sui::test_utils::destroy(meta_b_sui);
    sui::test_utils::destroy(meta_usdc);
    sui::test_utils::destroy(meta_sui);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(lend_cap);
    sui::test_utils::destroy(clock);
    sui::test_utils::destroy(bag);

    (pool, dyn_pool, oracle_registry, price_state, lending_market, bank_sui, bank_usdc)
}

fun setup_all(
    fee_bps: u64,
    scenario: &mut Scenario,
): (
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoter, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    Pool<B_TEST_SUI, B_TEST_USDC, OracleQuoterV2, LP_SUI_USDC>,
    OracleRegistry,
    PriceState,
    LendingMarket<LENDING_MARKET>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
) {
    let (
        bank_usdc,
        bank_sui,
        lending_market,
        lend_cap,
        price_state,
        bag,
        clock,
        mut registry,
        meta_b_usdc,
        meta_b_sui,
        meta_usdc,
        meta_sui,
        mut meta_lp_sui_usdc,
        treasury_cap_lp,
    ) = base_setup_2(option::none(), scenario);

    let (mut oracle_registry, admin_cap) = oracles::new_oracle_registry_for_testing(
        oracles::new_oracle_registry_config(
            60,
            10,
            60,
            10,
            scenario.ctx(),
        ),
        scenario.ctx(),
    );

    oracle_registry.add_pyth_oracle(
        &admin_cap,
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        scenario.ctx(),
    );

    oracle_registry.add_pyth_oracle(
        &admin_cap,
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        scenario.ctx(),
    );

    let pool = dummy_omm::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        fee_bps,
        scenario.ctx(),
    );

    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool1 = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        1,
        fee_bps,
        scenario.ctx(),
    );
    
    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool10 = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        10,
        fee_bps,
        scenario.ctx(),
    );
    
    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool100 = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        100,
        fee_bps,
        scenario.ctx(),
    );
    
    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool1000 = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        1000,
        fee_bps,
        scenario.ctx(),
    );
    
    let treasury_cap_lp = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let dyn_pool8000 = omm_v2::new<
        LENDING_MARKET,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        B_TEST_USDC,
        LP_SUI_USDC,
    >(
        &mut registry,
        &lending_market,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &meta_b_usdc,
        &mut meta_lp_sui_usdc,
        treasury_cap_lp,
        &oracle_registry,
        1,
        0,
        8000,
        fee_bps,
        scenario.ctx(),
    );

    sui::test_utils::destroy(admin_cap);
    sui::test_utils::destroy(meta_lp_sui_usdc);
    sui::test_utils::destroy(meta_b_usdc);
    sui::test_utils::destroy(meta_b_sui);
    sui::test_utils::destroy(meta_usdc);
    sui::test_utils::destroy(meta_sui);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(lend_cap);
    sui::test_utils::destroy(clock);
    sui::test_utils::destroy(bag);

    (pool, dyn_pool1, dyn_pool10, dyn_pool100, dyn_pool1000, dyn_pool8000, oracle_registry, price_state, lending_market, bank_sui, bank_usdc)
}

/// Checks that the dynamic fee quotation is less than the naive oracle implementation
/// It should ALWAYS give a worst price than the given oracle price
#[test]
fun test_dmm_positive_slippage_y2x() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        1_000 * 1_000_000_000,
        1_000 * 1_000_000,
        scenario.ctx(),
    );
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        1_000 * 1_000_000_000,
        1_000 * 1_000_000,
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(0, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(10 * 1_000_000, scenario.ctx());

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    price_state.update_price<TEST_SUI>(3, 0, &clock);
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let swap_result = dummy_omm::swap(
        &mut pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        10 * 1_000_000, // 10 USDC
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(swap_result.amount_out() + swap_result.protocol_fees() + swap_result.pool_fees() == 3_333_333_333); // 3.3333 sui

    destroy(coin_sui);
    destroy(coin_usdc);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(0, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(10 * 1_000_000, scenario.ctx());

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let swap_result_2 = omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        10 * 1_000_000, // 10 USDC
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(swap_result.amount_out() > swap_result_2.amount_out(), 0);
    assert_eq(swap_result_2.amount_out() + swap_result_2.protocol_fees() + swap_result_2.pool_fees(), 3_327_783_945);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation is less than the naive oracle implementation
/// It should ALWAYS give a worst price than the given oracle price
#[test]
fun test_dmm_positive_slippage_x2y() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        1_000 * 1_000_000_000,
        1_000 * 1_000_000,
        scenario.ctx(),
    );
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        1_000 * 1_000_000_000,
        1_000 * 1_000_000,
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(1 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(0, scenario.ctx());

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    price_state.update_price<TEST_SUI>(3, 0, &clock);
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let swap_result = dummy_omm::swap(
        &mut pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        1 * 1_000_000_000, // 10 SUI
        0,
        &clock,
        scenario.ctx(),
    );

    assert_eq(swap_result.amount_out() + swap_result.protocol_fees() + swap_result.pool_fees(), 3_000_000); // 3 USDC

    destroy(coin_sui);
    destroy(coin_usdc);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(1 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(0, scenario.ctx());

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let swap_result_2 = omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        1 * 1_000_000_000, // 10 USDC
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(swap_result.amount_out() > swap_result_2.amount_out(), 0);
    assert_eq(swap_result_2.amount_out() + swap_result_2.protocol_fees() + swap_result_2.pool_fees(), 2_995_504); // 2.9955 USDC

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_a2b_consecutive_price_decrease_amp_1() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e9(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.lt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        amount_in,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        0,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (_, reserve_usdc) = dyn_pool.balance_amounts();

    assert!(reserve_usdc > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_b2a_consecutive_price_increase_amp_1() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e6(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.gt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        0,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        amount_in,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (reserve_sui, _) = dyn_pool.balance_amounts();

    assert!(reserve_sui > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_a2b_consecutive_price_decrease_amp_10() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        10,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e9(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.lt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        amount_in,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        0,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (_, reserve_usdc) = dyn_pool.balance_amounts();

    assert!(reserve_usdc > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_b2a_consecutive_price_increase_amp_10() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        10,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e6(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.gt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        0,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        amount_in,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (reserve_sui, _) = dyn_pool.balance_amounts();

    assert!(reserve_sui > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_a2b_consecutive_price_decrease_amp_100() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        100,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e9(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.lt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        amount_in,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        0,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (_, reserve_usdc) = dyn_pool.balance_amounts();

    assert!(reserve_usdc > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_b2a_consecutive_price_increase_amp_100() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        100,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e6(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.gt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        0,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        amount_in,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (reserve_sui, _) = dyn_pool.balance_amounts();

    assert!(reserve_sui > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_a2b_consecutive_price_decrease_amp_1000() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1000,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e9(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.lt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        amount_in,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        0,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (_, reserve_usdc) = dyn_pool.balance_amounts();

    assert!(reserve_usdc > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_b2a_consecutive_price_increase_amp_1000() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        1000,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e6(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.gt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        0,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        amount_in,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (reserve_sui, _) = dyn_pool.balance_amounts();

    assert!(reserve_sui > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_a2b_consecutive_price_decrease_amp_8000() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        8000,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e9(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.lt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        amount_in,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        0,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        true, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (_, reserve_usdc) = dyn_pool.balance_amounts();

    assert!(reserve_usdc > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Checks that the dynamic fee quotation progressively gives a worse quote
/// as the trade size, and therefore imbalance, increases
#[test]
fun test_b2a_consecutive_price_increase_amp_8000() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, mut dyn_pool, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup(
        100,
        8000,
        &mut scenario,
    );

    destroy(pool);

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(e6(100_000), scenario.ctx());

    let (lp_coins, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1_000;
    let mut amount_in = e6(1_000);
    let mut delta_out = 18_446_744_073_709_551_615; // Max value for u64
    let mut price = fp64::from(3 as u128);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );

        let quote_result = omm_v2::quote_swap(
            &dyn_pool,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );

        let new_delta_out = quote_result.amount_out() + quote_result.output_fees().protocol_fees() + quote_result.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));

        let new_price = dy.div(dx);

        if (delta_out == 0) {
            assert!(new_delta_out == 0);
        } else {
            assert!(new_price.gt(price), 0);
        };
        
        delta_out = new_delta_out;
        price = new_price;

        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );
    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(
        0,
        scenario.ctx(),
    );
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(
        amount_in,
        scenario.ctx(),
    );

    omm_v2::swap(
        &mut dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_sui,
        &mut coin_usdc,
        false, // a2b
        amount_in,
        0,
        &clock,
        scenario.ctx(),
    );
    let (reserve_sui, _) = dyn_pool.balance_amounts();

    assert!(reserve_sui > 0, 0);

    destroy(coin_sui);
    destroy(coin_usdc);
    destroy(dyn_pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Tests that slippage will be worse for smaller Amplifiers. It tests this accross
/// a series of increaasing trade prices
#[test]
fun test_a2b_price_slippage_comparison() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (mut pool0, mut dyn_pool1, mut dyn_pool10, mut dyn_pool100, mut dyn_pool1000, mut dyn_pool8000, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup_all(
        100,
        &mut scenario,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(6 * e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(6 * e6(100_000), scenario.ctx());

    let (lp_coins, _) = pool0.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool1.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool10.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool100.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool1000.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool8000.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1000;
    let mut amount_in = e9(1_000);

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let res0 = dummy_omm::quote_swap(
        &pool0,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        true, // a2b
        &clock,
    );

    let new_delta_out = res0.amount_out() + res0.output_fees().protocol_fees() + res0.output_fees().pool_fees();
    let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
    let price0 = dy.div(dx);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res1 = omm_v2::quote_swap(
            &dyn_pool1,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );
        let new_delta_out = res1.amount_out() + res1.output_fees().protocol_fees() + res1.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
        let price1 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res10 = omm_v2::quote_swap(
            &dyn_pool10,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );
        let new_delta_out = res10.amount_out() + res10.output_fees().protocol_fees() + res10.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
        let price10 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res100 = omm_v2::quote_swap(
            &dyn_pool100,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );
        let new_delta_out = res100.amount_out() + res100.output_fees().protocol_fees() + res100.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
        let price100 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res1000 = omm_v2::quote_swap(
            &dyn_pool1000,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );
        let new_delta_out = res1000.amount_out() + res1000.output_fees().protocol_fees() + res1000.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
        let price1000 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res8000 = omm_v2::quote_swap(
            &dyn_pool8000,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            true, // a2b
            &clock,
        );
        let new_delta_out = res8000.amount_out() + res8000.output_fees().protocol_fees() + res8000.output_fees().pool_fees();
        let dx = fp64::from(amount_in as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(new_delta_out as u128).div(fp64::from(e6(1) as u128));
        let price8000 = dy.div(dx);

        assert!(price8000.lt(price0), 0);
        assert!(price1000.lte(price8000), 0);
        assert!(price100.lte(price1000), 0);
        assert!(price10.lte(price100), 0);
        assert!(price1.lte(price10), 0);

        amount_in = amount_in + e9(1_000);
        trades = trades - 1;
    };


    destroy(pool0);
    destroy(dyn_pool1);
    destroy(dyn_pool10);
    destroy(dyn_pool100);
    destroy(dyn_pool1000);
    destroy(dyn_pool8000);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

/// Tests that slippage will be worse for smaller Amplifiers. It tests this accross
/// a series of increaasing trade prices
#[test]
fun test_b2a_price_slippage_comparison() {
    let mut scenario = test_scenario::begin(@0x26);

    // Init Pool
    test_scenario::next_tx(&mut scenario, @0x26);
    let clock = clock::create_for_testing(scenario.ctx());
    let (mut pool0, mut dyn_pool1, mut dyn_pool10, mut dyn_pool100, mut dyn_pool1000, mut dyn_pool8000, oracle_registry, mut price_state, lending_market, bank_sui, bank_usdc) = setup_all(
        100,
        &mut scenario,
    );

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(6 * e9(100_000), scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(6 * e6(100_000), scenario.ctx());

    let (lp_coins, _) = pool0.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool1.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool10.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool100.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool1000.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);
    
    let (lp_coins, _) = dyn_pool8000.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(100_000),
        e6(100_000),
        scenario.ctx(),
    );
    destroy(lp_coins);

    destroy(coin_sui);
    destroy(coin_usdc);

    // Swap
    test_scenario::next_tx(&mut scenario, @0x26);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    let mut trades = 1000;
    let mut amount_in = e6(1_000);

    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let res0 = dummy_omm::quote_swap(
        &pool0,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        false, // a2b
        &clock,
    );

    let new_delta_out = res0.amount_out() + res0.output_fees().protocol_fees() + res0.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
    let price0 = dy.div(dx);

    while (trades > 0) {
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res1 = omm_v2::quote_swap(
            &dyn_pool1,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );
        let new_delta_out = res1.amount_out() + res1.output_fees().protocol_fees() + res1.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
        let price1 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res10 = omm_v2::quote_swap(
            &dyn_pool10,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );
        let new_delta_out = res10.amount_out() + res10.output_fees().protocol_fees() + res10.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
        let price10 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res100 = omm_v2::quote_swap(
            &dyn_pool100,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );
        let new_delta_out = res100.amount_out() + res100.output_fees().protocol_fees() + res100.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
        let price100 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res1000 = omm_v2::quote_swap(
            &dyn_pool1000,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );
        let new_delta_out = res1000.amount_out() + res1000.output_fees().protocol_fees() + res1000.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
        let price1000 = dy.div(dx);
        
        let oracle_price_update_usdc = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_USDC>(&price_state),
            0,
            &clock,
        );

        let oracle_price_update_sui = oracle_registry.get_pyth_price(
            mock_pyth::get_price_obj<TEST_SUI>(&price_state),
            1,
            &clock,
        );
        let res8000 = omm_v2::quote_swap(
            &dyn_pool8000,
            &bank_sui,
            &bank_usdc,
            &lending_market,
            oracle_price_update_sui,
            oracle_price_update_usdc,
            amount_in,
            false, // a2b
            &clock,
        );
        let new_delta_out = res8000.amount_out() + res8000.output_fees().protocol_fees() + res8000.output_fees().pool_fees();
        let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
        let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128));
        let price8000 = dy.div(dx);

        assert!(price8000.gt(price0), 0);
        assert!(price1000.gte(price8000), 0);
        assert!(price100.gte(price1000), 0);
        assert!(price10.gte(price100), 0);
        assert!(price1.gte(price10), 0);


        amount_in = amount_in + e6(1_000);
        trades = trades - 1;
    };


    destroy(pool0);
    destroy(dyn_pool1);
    destroy(dyn_pool10);
    destroy(dyn_pool100);
    destroy(dyn_pool1000);
    destroy(dyn_pool8000);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);
    test_scenario::end(scenario);
}

// Checks that a lower btoken ratio for the input token does not affect slippage
// Note: Due to numerical precision, the results may be slightly different if the
// btoken ratio is a rational number with repeating decimals or an irrational number.
#[test]
fun test_dmm_input_btoken_ratio_lower_b2a_no_slippage_impact() {
    let mut scenario = test_scenario::begin(@0x26);

    let (pool, mut dyn_pool, oracle_registry, mut price_state, mut lending_market, mut bank_sui, mut bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(1_000),
        e6(1_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    // Quotes prior to btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let amount_in = e6(10);
    
    let res_b2a_dyn_prior = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        false, // a2b
        &clock,
    );

    // Manipulate btoken prices
    let admin = global_admin::init_for_testing(scenario.ctx());
    bank_sui.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());
    bank_usdc.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());

    let bsui_supply = bank_sui.btoken_supply_for_testing();
    destroy(bsui_supply.increase_supply(e9(1_000))); // 1.0x
    let funds_available_sui = bank_sui.funds_available_for_testing();
    funds_available_sui.join(balance::create_for_testing(e9(1_000)));
    
    let busdc_supply = bank_usdc.btoken_supply_for_testing();
    destroy(busdc_supply.increase_supply(e6(1_000) + e6(100)));  // 1.1x. need to add the supply from the previous deposited liquidity as we bypassed it and minted coins using test function
    let funds_available_usdc = bank_usdc.funds_available_for_testing();
    funds_available_usdc.join(balance::create_for_testing(e6(1_000)));

    let (bank_total_funds, total_btoken_supply) = bank_usdc.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_usdc_after = bank_total_funds.div(total_btoken_supply);
    
    let (bank_total_funds, total_btoken_supply) = bank_sui.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_sui_after = bank_total_funds.div(total_btoken_supply);

    // Quotes after btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let btoken_amount_in = decimal::from(amount_in).div(btoken_ratio_usdc_after).floor();
    
    let res_b2a_dyn_post = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        btoken_amount_in,
        false, // a2b
        &clock,
    );

    // Before

    let new_delta_out = res_b2a_dyn_prior.amount_out() + res_b2a_dyn_prior.output_fees().protocol_fees() + res_b2a_dyn_prior.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(e6(10) as u128).div(fp64::from(e6(1) as u128));
    let price_b2a_prior_dyn = dy.div(dx);
    assert!(price_b2a_prior_dyn.to_string_clipped(9) == utf8(b"3.005002778"), 0);
    let slippage = price_b2a_prior_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    // After
    
    let new_delta_out = res_b2a_dyn_post.amount_out() + res_b2a_dyn_post.output_fees().protocol_fees() + res_b2a_dyn_post.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128)).mul(decimal_to_fixedpoint64(btoken_ratio_sui_after)); // sui
    let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128)); // usdc
    let price_b2a_post_dyn = dy.div(dx);
    assert!(price_b2a_post_dyn.to_string() == utf8(b"3.005002778207706029"), 0);
    let slippage = price_b2a_post_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    destroy(admin);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}

// Checks that a higher btoken ratio for the input token does not affect slippage
// Note: Due to numerical precision, the results may be slightly different if the
// btoken ratio is a rational number with repeating decimals or an irrational number.
#[test]
fun test_dmm_input_btoken_ratio_higher_b2a_no_slippage_impact() {
    let mut scenario = test_scenario::begin(@0x26);

    let (pool, mut dyn_pool, oracle_registry, mut price_state, mut lending_market, mut bank_sui, mut bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(1_000),
        e6(1_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    // Quotes prior to btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let amount_in = e6(10);
    
    let res_b2a_dyn_prior = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        false, // a2b
        &clock,
    );

    // Manipulate btoken prices
    let admin = global_admin::init_for_testing(scenario.ctx());
    bank_sui.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());
    bank_usdc.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());

    let bsui_supply = bank_sui.btoken_supply_for_testing();
    destroy(bsui_supply.increase_supply(e9(1_000))); // 1.0x
    let funds_available_sui = bank_sui.funds_available_for_testing();
    funds_available_sui.join(balance::create_for_testing(e9(1_000)));
    
    let busdc_supply = bank_usdc.btoken_supply_for_testing();
    destroy(busdc_supply.increase_supply(e6(1_000)));
    let funds_available_usdc = bank_usdc.funds_available_for_testing();
    funds_available_usdc.join(balance::create_for_testing(e6(1_000) + e6(1000)));

    let (bank_total_funds, total_btoken_supply) = bank_usdc.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_usdc_after = bank_total_funds.div(total_btoken_supply);
    
    let (bank_total_funds, total_btoken_supply) = bank_sui.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_sui_after = bank_total_funds.div(total_btoken_supply);

    // Quotes after btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let btoken_amount_in = decimal::from(amount_in).div(btoken_ratio_usdc_after).floor();
    
    let res_b2a_dyn_post = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        btoken_amount_in,
        false, // a2b
        &clock,
    );

    // Before

    let new_delta_out = res_b2a_dyn_prior.amount_out() + res_b2a_dyn_prior.output_fees().protocol_fees() + res_b2a_dyn_prior.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(e6(10) as u128).div(fp64::from(e6(1) as u128));
    let price_b2a_prior_dyn = dy.div(dx);
    assert!(price_b2a_prior_dyn.to_string_clipped(9) == utf8(b"3.005002778"), 0);
    let slippage = price_b2a_prior_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    // After
    
    let new_delta_out = res_b2a_dyn_post.amount_out() + res_b2a_dyn_post.output_fees().protocol_fees() + res_b2a_dyn_post.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128)).mul(decimal_to_fixedpoint64(btoken_ratio_sui_after)); // sui
    let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128)); // usdc
    let price_b2a_post_dyn = dy.div(dx);
    assert!(price_b2a_post_dyn.to_string_clipped(9) == utf8(b"3.005002778"), 0);
    let slippage = price_b2a_post_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    destroy(admin);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}

/// Checks that a lower btoken ratio for the output token increases slippage.
/// The btoken ratio of the output has an impact on how the pool perceives
/// the scarcity of the output reserve, which itself is what controls the slippage
/// A lower bToken ratio means that the actual reserve amount is lower than the
/// btoken reserve amount, which leads to more scarcity, hence more slippage
#[test]
fun test_dmm_output_btoken_ratio_lower_b2a_higher_slippage() {
    let mut scenario = test_scenario::begin(@0x26);

    let (pool, mut dyn_pool, oracle_registry, mut price_state, mut lending_market, mut bank_sui, mut bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(1_000),
        e6(1_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    // Quotes prior to btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let amount_in = e6(10);
    
    let res_b2a_dyn_prior = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        false, // a2b
        &clock,
    );

    // Manipulate btoken prices
    let admin = global_admin::init_for_testing(scenario.ctx());
    bank_sui.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());
    bank_usdc.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());

    let bsui_supply = bank_sui.btoken_supply_for_testing();
    destroy(bsui_supply.increase_supply(e9(1_000) + e9(1_000))); // 1.0x
    let funds_available_sui = bank_sui.funds_available_for_testing();
    funds_available_sui.join(balance::create_for_testing(e9(1_000)));
    
    let busdc_supply = bank_usdc.btoken_supply_for_testing();
    destroy(busdc_supply.increase_supply(e6(1_000)));
    let funds_available_usdc = bank_usdc.funds_available_for_testing();
    funds_available_usdc.join(balance::create_for_testing(e6(1_000)));

    let (bank_total_funds, total_btoken_supply) = bank_usdc.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_usdc_after = bank_total_funds.div(total_btoken_supply);
    
    let (bank_total_funds, total_btoken_supply) = bank_sui.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_sui_after = bank_total_funds.div(total_btoken_supply);

    // Quotes after btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let btoken_amount_in = decimal::from(amount_in).div(btoken_ratio_usdc_after).floor();
    
    let res_b2a_dyn_post = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        btoken_amount_in,
        false, // a2b
        &clock,
    );

    // Before

    let new_delta_out = res_b2a_dyn_prior.amount_out() + res_b2a_dyn_prior.output_fees().protocol_fees() + res_b2a_dyn_prior.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(e6(10) as u128).div(fp64::from(e6(1) as u128));
    let price_b2a_prior_dyn = dy.div(dx);
    assert!(price_b2a_prior_dyn.to_string_clipped(9) == utf8(b"3.005002778"), 0);
    let slippage = price_b2a_prior_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    // After
    
    let new_delta_out = res_b2a_dyn_post.amount_out() + res_b2a_dyn_post.output_fees().protocol_fees() + res_b2a_dyn_post.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128)).mul(decimal_to_fixedpoint64(btoken_ratio_sui_after)); // sui
    let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128)); // usdc
    let price_b2a_post_dyn = dy.div(dx);

    assert!(price_b2a_post_dyn.gt(price_b2a_prior_dyn), 0); // Price is higher due to higher slippage
    assert!(price_b2a_post_dyn.to_string() == utf8(b"3.010011111540298562"), 0);
    let slippage_post = price_b2a_post_dyn.sub(fp64::from(3)).div(fp64::from(3));

    assert!(slippage_post.gt(slippage), 0); // Slippage is higher due to higher slippage
    assert!(slippage_post.to_string() == utf8(b"0.003337037180099520"), 0); // slippage: ~0.003337037180099520

    destroy(admin);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}

/// Checks that a lower btoken ratio for the output token increases slippage.
/// The btoken ratio of the output has an impact on how the pool perceives
/// the scarcity of the output reserve, which itself is what controls the slippage
/// A higher bToken ratio means that the actual reserve amount is higher than the
/// btoken reserve amount, which leads to less scarcity, hence less slippage
#[test]
fun test_dmm_output_btoken_ratio_higher_b2a_lower_slippage() {
    let mut scenario = test_scenario::begin(@0x26);

    let (pool, mut dyn_pool, oracle_registry, mut price_state, mut lending_market, mut bank_sui, mut bank_usdc) = setup(
        100,
        1,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_sui = coin::mint_for_testing<B_TEST_SUI>(2_000 * 1_000_000_000, scenario.ctx());
    let mut coin_usdc = coin::mint_for_testing<B_TEST_USDC>(2_000 * 1_000_000, scenario.ctx());
    
    let (lp_coins_2, _) = dyn_pool.deposit_liquidity(
        &mut coin_sui,
        &mut coin_usdc,
        e9(1_000),
        e6(1_000),
        scenario.ctx(),
    );

    destroy(coin_sui);
    destroy(coin_usdc);

    price_state.update_price<TEST_USDC>(1, 0, &clock);
    price_state.update_price<TEST_SUI>(3, 0, &clock);

    // Quotes prior to btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let amount_in = e6(10);
    
    let res_b2a_dyn_prior = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        amount_in,
        false, // a2b
        &clock,
    );

    // Manipulate btoken prices
    let admin = global_admin::init_for_testing(scenario.ctx());
    bank_sui.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());
    bank_usdc.init_lending(&admin, &mut lending_market, 0, 0, scenario.ctx());

    let bsui_supply = bank_sui.btoken_supply_for_testing();
    destroy(bsui_supply.increase_supply(e9(1_000))); // 1.0x
    let funds_available_sui = bank_sui.funds_available_for_testing();
    funds_available_sui.join(balance::create_for_testing(e9(1_000) + e9(1_000)));
    
    let busdc_supply = bank_usdc.btoken_supply_for_testing();
    destroy(busdc_supply.increase_supply(e6(1_000)));
    let funds_available_usdc = bank_usdc.funds_available_for_testing();
    funds_available_usdc.join(balance::create_for_testing(e6(1_000)));

    let (bank_total_funds, total_btoken_supply) = bank_usdc.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_usdc_after = bank_total_funds.div(total_btoken_supply);
    
    let (bank_total_funds, total_btoken_supply) = bank_sui.get_btoken_ratio(&lending_market, &clock);
    let btoken_ratio_sui_after = bank_total_funds.div(total_btoken_supply);

    // Quotes after btoken ratio manipulation
    let oracle_price_update_usdc = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_USDC>(&price_state),
        0,
        &clock,
    );

    let oracle_price_update_sui = oracle_registry.get_pyth_price(
        mock_pyth::get_price_obj<TEST_SUI>(&price_state),
        1,
        &clock,
    );

    let btoken_amount_in = decimal::from(amount_in).div(btoken_ratio_usdc_after).floor();
    
    let res_b2a_dyn_post = omm_v2::quote_swap(
        &dyn_pool,
        &bank_sui,
        &bank_usdc,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        btoken_amount_in,
        false, // a2b
        &clock,
    );

    // Before

    let new_delta_out = res_b2a_dyn_prior.amount_out() + res_b2a_dyn_prior.output_fees().protocol_fees() + res_b2a_dyn_prior.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128));
    let dy = fp64::from(e6(10) as u128).div(fp64::from(e6(1) as u128));
    let price_b2a_prior_dyn = dy.div(dx);
    assert!(price_b2a_prior_dyn.to_string_clipped(9) == utf8(b"3.005002778"), 0);
    let slippage = price_b2a_prior_dyn.sub(fp64::from(3)).div(fp64::from(3));
    assert!(slippage.to_string() == utf8(b"0.001667592735902009"), 0); // slippage: ~0.001667592735902009

    // After
    let new_delta_out = res_b2a_dyn_post.amount_out() + res_b2a_dyn_post.output_fees().protocol_fees() + res_b2a_dyn_post.output_fees().pool_fees();
    let dx = fp64::from(new_delta_out as u128).div(fp64::from(e9(1) as u128)).mul(decimal_to_fixedpoint64(btoken_ratio_sui_after)); // sui
    let dy = fp64::from(amount_in as u128).div(fp64::from(e6(1) as u128)); // usdc
    let price_b2a_post_dyn = dy.div(dx);

    assert!(price_b2a_post_dyn.lt(price_b2a_prior_dyn), 0); // Price is lower due to lower slippage
    assert!(price_b2a_post_dyn.to_string() == utf8(b"3.002500694554974418"), 0);
    let slippage_post = price_b2a_post_dyn.sub(fp64::from(3)).div(fp64::from(3));

    assert!(slippage_post.lt(slippage), 0); // Slippage is lower
    assert!(slippage_post.to_string() == utf8(b"0.000833564851658139"), 0); // slippage: ~0.000833564851658139

    destroy(admin);
    destroy(pool);
    destroy(dyn_pool);
    destroy(lp_coins_2);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_sui);
    destroy(bank_usdc);

    test_scenario::end(scenario);
}