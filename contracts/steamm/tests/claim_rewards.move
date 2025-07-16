module steamm::claim_rewards_tests;

use steamm::test_utils::e9;
use steamm::registry;
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::test_sui::TEST_SUI;
use suilend::test_usdc::TEST_USDC;

/// Sets up a reward in Suilend and distributes it to two reward receivers.
#[test]
fun test_claim_rewards() {
    let mut scenario = test_scenario::begin(@0x0);

    let (
        mut pool,
        mut bank_a,
        mut bank_b,
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

    // === setup rewards ===

    let reward_len_ms = 1_000_000_000;
    let reserve_array_index = 0;
    let hundred_percent = e9(100);
    let one_third = hundred_percent / 3;
    let two_thirds = hundred_percent - one_third;

    let reward_coin = coin::mint_for_testing<TEST_USDC>(hundred_percent, ctx);
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

    // === setup bank that is eligible for rewards ===

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx,
    );

    let mut coin_a = coin::mint_for_testing<TEST_USDC>(e9(500_000), ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(e9(500_000), ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, e9(500_000), &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, e9(500_000), &clock, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        e9(500_000),
        e9(500_000),
        ctx,
    );

    assert!(bank_a.needs_rebalance(&lending_market, &clock).needs_rebalance_());
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    let expected_reserve_index = *sui::bag::borrow(&type_to_index, std::type_name::get<TEST_USDC>());
    assert_eq(bank_a.reserve_array_index(), expected_reserve_index);

    // === claim rewards ===

    clock.increment_for_testing(reward_len_ms + 1); // ends

    // set two reward receivers, 1/3 and 2/3
    let receiver_1 = @0x1;
    let receiver_2 = @0x2;
    registry.set_fee_receivers(
        &global_admin,
        vector[receiver_1, receiver_2],
        vector[1,          2],
    );
    
    bank_a.claim_rewards<_, _, _, TEST_USDC>( // matches reward coin
        &mut lending_market,
        &registry,
        reserve_array_index,
        &clock,
        ctx,
    );

    scenario.next_tx(@0x0);

    // now we assert that the two receivers got the correct amounts

    let reward_coin_for_receiver_1: Coin<TEST_USDC> = scenario.take_from_address(receiver_1);
    assert_eq(reward_coin_for_receiver_1.value(), one_third);

    let reward_coin_for_receiver_2: Coin<TEST_USDC> = scenario.take_from_address(receiver_2);
    assert_eq(reward_coin_for_receiver_2.value(), two_thirds);

    destroy(type_to_index);
    destroy(bank_a);
    destroy(bank_b);
    destroy(btoken_a);
    destroy(btoken_b);
    destroy(clock);
    destroy(coin_a);
    destroy(coin_b);
    destroy(global_admin);
    destroy(lend_cap);
    destroy(lending_market);
    destroy(lp_coins);
    destroy(pool);
    destroy(prices);
    destroy(reward_coin_for_receiver_1);
    destroy(reward_coin_for_receiver_2);
    destroy(registry);
    destroy(scenario);
}