module steamm::sync_rewards_tests;

use steamm::{registry, test_utils::e9};
use sui::{coin, test_scenario::{Self, ctx}, test_utils::destroy};
use suilend::{test_usdc::TEST_USDC};

/// Tests that bank::sync_obligation_and_bank is correctly handling
/// a ctoken discrepancy between bank and suilend obligation
#[test]
fun test_sync_rewards() {
    let sender = @0xDDD;

    let mut scenario = test_scenario::begin(sender);

    let (
        pool,
        mut bank_a,
        bank_b,
        mut lending_market,
        lend_cap,
        prices,
        type_to_index,
        mut clock,
    ) = steamm::test_utils::test_setup_dummy(
        0, //swap_fee_bps
        &mut scenario,
    );
    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let ctx = scenario.ctx();
    let global_admin = steamm::global_admin::init_for_testing(ctx);

    // === Setup rewards ===
    let reward_len_ms = 1_000_000_000;
    let reserve_array_index = 0;
    let reward_amount = e9(100); // 100 TEST_USDC rewards

    let reward_coin = coin::mint_for_testing<TEST_USDC>(reward_amount, ctx);
    suilend::lending_market::add_pool_reward(
        &lend_cap,
        &mut lending_market,
        reserve_array_index,
        true, // is_deposit_reward
        reward_coin,
        clock.timestamp_ms(),
        clock.timestamp_ms() + reward_len_ms,
        &clock,
        ctx,
    );

    // Setup bank for lending
    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx,
    );

    // Deposit funds and deploy to Suilend
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(e9(100_000), ctx);
    let btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        e9(100_000),
        &clock,
        ctx,
    );

    bank_a.rebalance(&mut lending_market, &clock, ctx);

    // Setup reward receiver
    registry.set_fee_receivers(
        &global_admin,
        vector[sender],
        vector[1],
    );

    // Advance time to complete reward period
    clock.increment_for_testing(reward_len_ms + 1);

    // Manually create a discrepancy by depositing additional cTokens
    // directly to the obligation without updating the bank's internal tracking.
    let excess_amount = e9(50);
    let excess_coin = coin::mint_for_testing<TEST_USDC>(excess_amount, ctx);
    let excess_ctokens = lending_market.deposit_liquidity_and_mint_ctokens<_, TEST_USDC>(
        reserve_array_index,
        &clock,
        excess_coin,
        ctx,
    );

    // Get the obligation and deposit the excess cTokens directly
    // This creates the discrepancy that sync_obligation_and_bank should detect
    let obligation_cap = bank_a.extract_obligation_cap_for_testing();
    let obligation_id = obligation_cap.obligation_id();

    lending_market.deposit_ctokens_into_obligation<_, TEST_USDC>(
        reserve_array_index,
        obligation_cap,
        &clock,
        excess_ctokens,
        ctx,
    );

    // Verify the discrepancy exists
    let actual_ctoken_amount = lending_market
        .obligation(obligation_id)
        .deposited_ctoken_amount<_, TEST_USDC>();
    let expected_ctoken_amount = bank_a.extract_ctokens_for_testing();

    // Ensure we have the precondition for the test
    assert!(actual_ctoken_amount > expected_ctoken_amount);

    bank_a.claim_rewards<_, _, _, TEST_USDC>(
        &mut lending_market,
        &registry,
        reserve_array_index,
        &clock,
        ctx,
    );

    scenario.next_tx(sender);

    let actual_after = lending_market
        .obligation(obligation_id)
        .deposited_ctoken_amount<_, TEST_USDC>();
    let expected_after = bank_a.extract_ctokens_for_testing();

    assert!(actual_after == expected_after);

    destroy(type_to_index);
    destroy(bank_a);
    destroy(bank_b);
    destroy(btoken_a);
    destroy(clock);
    destroy(coin_a);
    destroy(global_admin);
    destroy(lend_cap);
    destroy(lending_market);
    destroy(pool);
    destroy(prices);
    destroy(registry);
    destroy(scenario);
}

#[test]
fun test_sync_zero_rewards_noop() {
    let sender = @0xDDD;

    let mut scenario = test_scenario::begin(sender);

    let (
        pool,
        mut bank_a,
        bank_b,
        mut lending_market,
        lend_cap,
        prices,
        type_to_index,
        mut clock,
    ) = steamm::test_utils::test_setup_dummy(
        0, //swap_fee_bps
        &mut scenario,
    );
    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let ctx = scenario.ctx();
    let global_admin = steamm::global_admin::init_for_testing(ctx);

    // === Setup rewards ===
    let reward_len_ms = 1_000_000_000;
    let reserve_array_index = 0;
    let reward_amount = e9(100); // 100 TEST_USDC rewards

    let reward_coin = coin::mint_for_testing<TEST_USDC>(reward_amount, ctx);
    suilend::lending_market::add_pool_reward(
        &lend_cap,
        &mut lending_market,
        reserve_array_index,
        true, // is_deposit_reward
        reward_coin,
        clock.timestamp_ms(),
        clock.timestamp_ms() + reward_len_ms,
        &clock,
        ctx,
    );

    // Setup bank for lending
    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx,
    );

    // Deposit funds and deploy to Suilend
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(e9(100_000), ctx);
    let btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        e9(100_000),
        &clock,
        ctx,
    );

    bank_a.rebalance(&mut lending_market, &clock, ctx);

    // Setup reward receiver
    registry.set_fee_receivers(
        &global_admin,
        vector[sender],
        vector[1],
    );

    // Advance time to complete reward period
    clock.increment_for_testing(reward_len_ms + 1);

    // Get the obligation and deposit the excess cTokens directly
    // This creates the discrepancy that sync_obligation_and_bank should detect
    let obligation_cap = bank_a.extract_obligation_cap_for_testing();
    let obligation_id = obligation_cap.obligation_id();

    // Verify the discrepancy exists
    let actual_ctoken_amount = lending_market
        .obligation(obligation_id)
        .deposited_ctoken_amount<_, TEST_USDC>();
    let expected_ctoken_amount = bank_a.extract_ctokens_for_testing();

    // Ensure we have the precondition for the test
    assert!(actual_ctoken_amount == expected_ctoken_amount);

    bank_a.claim_rewards<_, _, _, TEST_USDC>(
        &mut lending_market,
        &registry,
        reserve_array_index,
        &clock,
        ctx,
    );

    scenario.next_tx(sender);

    let actual_after = lending_market
        .obligation(obligation_id)
        .deposited_ctoken_amount<_, TEST_USDC>();
    let expected_after = bank_a.extract_ctokens_for_testing();

    assert!(actual_after == expected_after);

    destroy(type_to_index);
    destroy(bank_a);
    destroy(bank_b);
    destroy(btoken_a);
    destroy(clock);
    destroy(coin_a);
    destroy(global_admin);
    destroy(lend_cap);
    destroy(lending_market);
    destroy(pool);
    destroy(prices);
    destroy(registry);
    destroy(scenario);
}
