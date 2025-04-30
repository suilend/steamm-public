#[test_only]
module steamm::omm_tests;

use oracles::oracles::{Self, OracleRegistry};
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::bank::{Bank};
use steamm::lp_usdc_sui::LP_USDC_SUI;
use steamm::omm::{Self, OracleQuoter};
use steamm::pool::{Pool};
use steamm::test_utils::{base_setup};
use sui::clock::{Self};
use sui::coin;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils::{destroy};
use suilend::lending_market::{LendingMarket};
use suilend::lending_market_tests::{LENDING_MARKET};
use suilend::mock_pyth::{Self, PriceState};
use suilend::test_sui::{TEST_SUI};
use suilend::test_usdc::{TEST_USDC};

fun setup(
    fee_bps: u64,
    scenario: &mut Scenario,
): (
    Pool<B_TEST_USDC, B_TEST_SUI, OracleQuoter, LP_USDC_SUI>,
    OracleRegistry,
    PriceState,
    LendingMarket<LENDING_MARKET>,
    Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>,
    Bank<LENDING_MARKET, TEST_SUI, B_TEST_SUI>,
) {
    let (
        bank_a,
        bank_b,
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
        mut meta_lp_usdc_sui,
        treasury_cap_lp,
    ) = base_setup(option::none(), scenario);

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

    let pool = omm::new<
        LENDING_MARKET,
        TEST_USDC,
        TEST_SUI,
        B_TEST_USDC,
        B_TEST_SUI,
        LP_USDC_SUI,
    >(
        &mut registry,
        &lending_market,
        &meta_usdc,
        &meta_sui,
        &meta_b_usdc,
        &meta_b_sui,
        &mut meta_lp_usdc_sui,
        treasury_cap_lp,
        &oracle_registry,
        0,
        1,
        fee_bps,
        scenario.ctx(),
    );

    sui::test_utils::destroy(admin_cap);
    sui::test_utils::destroy(meta_lp_usdc_sui);
    sui::test_utils::destroy(meta_b_usdc);
    sui::test_utils::destroy(meta_b_sui);
    sui::test_utils::destroy(meta_usdc);
    sui::test_utils::destroy(meta_sui);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(lend_cap);
    sui::test_utils::destroy(clock);
    sui::test_utils::destroy(bag);

    (pool, oracle_registry, price_state, lending_market, bank_a, bank_b)
}

#[test]
fun test_omm_basic() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, oracle_registry, mut price_state, lending_market, bank_a, bank_b) = setup(
        100,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(1_000 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(20 * 1_000_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        1_000 * 1_000_000,
        20 * 1_000_000_000,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(6 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, scenario.ctx());

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

    let _swap_result = omm::swap(
        &mut pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_usdc,
        oracle_price_update_sui,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        6 * 1_000_000,
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(coin_a.value() == 0);
    assert!(coin_b.value() == 2 * 1_000_000_000 - 20_000_000);

    // Swap other direction 
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

    let old_coin_b_value = coin_b.value();
    let _swap_result = omm::swap(
        &mut pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_usdc,
        oracle_price_update_sui,
        &mut coin_a,
        &mut coin_b,
        false ,
        1_500_000_000, // 1.5 sui
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(coin_a.value() == 4_500_000 - 45_000);
    assert!(coin_b.value() == old_coin_b_value - 1_500_000_000);

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_a);
    destroy(bank_b);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = steamm::omm::EInvalidOracleIndex)]
fun test_omm_fail_wrong_oracle() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, oracle_registry, mut price_state, lending_market, bank_a, bank_b) = setup(
        100,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(1_000 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(20 * 1_000_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        1_000 * 1_000_000,
        20 * 1_000_000_000,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);

    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(6 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, scenario.ctx());

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

    // oracle updates are switched
    let _swap_result = omm::swap(
        &mut pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_sui,
        oracle_price_update_usdc,
        &mut coin_a,
        &mut coin_b,
        true, // a2b
        6 * 1_000_000,
        0,
        &clock,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(pool);
    destroy(lp_coins);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_a);
    destroy(bank_b);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = steamm::omm::EInvalidBankType)]
fun test_omm_fail_not_a_btoken() {
    let mut scenario = test_scenario::begin(@0x26);

    let (
        bank_a,
        bank_b,
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
        mut meta_lp_usdc_sui,
        treasury_cap_lp,
    ) = base_setup(option::none(), &mut scenario);

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

    let pool = omm::new<
        LENDING_MARKET,
        TEST_USDC,
        TEST_SUI,
        TEST_USDC,
        B_TEST_SUI,
        LP_USDC_SUI,
    >(
        &mut registry,
        &lending_market,
        &meta_usdc,
        &meta_sui,
        &meta_usdc,
        &meta_b_sui,
        &mut meta_lp_usdc_sui,
        treasury_cap_lp,
        &oracle_registry,
        0,
        1,
        100,
        scenario.ctx(),
    );

    sui::test_utils::destroy(admin_cap);
    sui::test_utils::destroy(meta_lp_usdc_sui);
    sui::test_utils::destroy(meta_b_usdc);
    sui::test_utils::destroy(meta_b_sui);
    sui::test_utils::destroy(meta_usdc);
    sui::test_utils::destroy(meta_sui);
    sui::test_utils::destroy(registry);
    sui::test_utils::destroy(lend_cap);
    sui::test_utils::destroy(clock);
    sui::test_utils::destroy(bag);
    sui::test_utils::destroy(pool);
    sui::test_utils::destroy(oracle_registry);
    sui::test_utils::destroy(price_state);
    sui::test_utils::destroy(lending_market);
    sui::test_utils::destroy(bank_a);
    sui::test_utils::destroy(bank_b);

    test_scenario::end(scenario);
}

#[test]
fun test_omm_quote_swap_insufficient_liquidity() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, oracle_registry, mut price_state, lending_market, bank_a, bank_b) = setup(
        100,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    // Add some initial liquidity to the pool
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(100 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(10 * 1_000_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        100 * 1_000,
        100 * 1_000,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);

    // Update oracle prices
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

    // Try to quote a swap with an amount much larger than pool liquidity
    // Attempting to swap 1000 USDC when pool only has 100
    let quote = omm::quote_swap(
        &pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_usdc,
        oracle_price_update_sui,
        1000 * 1_000_000, // 1000 USDC, much larger than pool liquidity
        true, // a2b (USDC to SUI)
        &clock,
    );

    // Verify that amount_out is 0 due to insufficient liquidity
    assert!(quote.amount_out() == 0, 0);
    assert!(quote.output_fees().pool_fees() == 0, 0);
    assert!(quote.output_fees().protocol_fees() == 0, 0);

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

    // Check the opposite direction as well - trying to swap more SUI than available
    let quote = omm::quote_swap(
        &pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_usdc,
        oracle_price_update_sui,
        100 * 1_000_000_000, // 100 SUI, much larger than pool liquidity
        false, // b2a (SUI to USDC)
        &clock,
    );

    // Verify that amount_out is 0 due to insufficient liquidity
    assert!(quote.amount_out() == 0, 0);
    assert!(quote.output_fees().pool_fees() == 0, 0);
    assert!(quote.output_fees().protocol_fees() == 0, 0);

    destroy(lp_coins);
    destroy(pool);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_a);
    destroy(bank_b);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = steamm::pool::ESwapOutputAmountIsZero)]
fun test_omm_swap_insufficient_liquidity() {
    let mut scenario = test_scenario::begin(@0x26);

    let (mut pool, oracle_registry, mut price_state, lending_market, bank_a, bank_b) = setup(
        100,
        &mut scenario,
    );
    let clock = clock::create_for_testing(scenario.ctx());

    // Add some initial liquidity to the pool - deliberately small amount
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(100 * 1_000_000, scenario.ctx());
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(10 * 1_000_000_000, scenario.ctx());

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut coin_a,
        &mut coin_b,
        100 * 1_000_000,
        10 * 1_000_000_000,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);

    // Update oracle prices
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

    // Create coins for swapping - attempting to swap more than the pool has
    let mut coin_a = coin::mint_for_testing<B_TEST_USDC>(1000 * 1_000_000, scenario.ctx()); // 1000 USDC
    let mut coin_b = coin::mint_for_testing<B_TEST_SUI>(0, scenario.ctx());

    // This should fail with EInsufficientLiquidity (or similar error)
    // as we're trying to swap 1000 USDC when pool only has 100 USDC
    let _swap_result = omm::swap(
        &mut pool,
        &bank_a,
        &bank_b,
        &lending_market,
        oracle_price_update_usdc,
        oracle_price_update_sui,
        &mut coin_a,
        &mut coin_b,
        true, // a2b (USDC to SUI)
        1000 * 1_000_000, // 1000 USDC, much larger than pool liquidity
        0, // min amount out - doesn't matter as we expect failure
        &clock,
        scenario.ctx(),
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(oracle_registry);
    destroy(clock);
    destroy(price_state);
    destroy(lending_market);
    destroy(bank_a);
    destroy(bank_b);

    test_scenario::end(scenario);
}