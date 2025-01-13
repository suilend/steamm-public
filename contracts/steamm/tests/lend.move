#[test_only]
module steamm::lend_tests;

use std::type_name;
use steamm::dummy_hook::{swap as dummy_swap};
use steamm::global_admin;
use steamm::pool::minimum_liquidity;
use steamm::test_utils::{reserve_args, reserve_args_2, assert_eq_approx, test_setup_cpmm, test_setup_dummy_no_fees};
use sui::coin;
use sui::random;
use sui::test_scenario::{Self, ctx};
use sui::test_utils::{Self, destroy, assert_eq};
use suilend::lending_market;
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use suilend::mock_pyth;
use suilend::test_sui::TEST_SUI;
use suilend::test_usdc::TEST_USDC;

const ADMIN: address = @0x10;
const POOL_CREATOR: address = @0x11;

// - Deposits liquidity with lending on coin A
// - Checks btoken reserves and funds in bank before rebalancing
// - Checks btoken reserves and funds in bank after rebalancing
#[test]
fun test_simple_deposit_with_lending_a() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend::lending_market_tests::setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();

    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
    let (mut pool, mut bank_a, mut bank_b) = test_setup_cpmm(100, 0);

    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 500_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 500_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_a.funds_available().value(), 500_000); // 500_000 * 100%
    assert_eq(bank_b.funds_available().value(), 500_000); // 500_000 * 100%

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        500_000,
        500_000,
        ctx,
    );

    // Test deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);

    // Test bank effects after rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
    assert_eq(bank_b.funds_available().value(), 500_000);

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(bank_a);
    destroy(bank_b);
    destroy(lp_coins);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

// - Swap with lending activate but without rebalancing nor burning
#[test]
fun test_swap_with_lending_without_touching_lending_market() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_cpmm(100, 0);
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 500_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 500_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        500_000,
        500_000,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);

    // No rebalance happened
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank_a.funds_available().value(), 500_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank_b.funds_available().value(), 500_000);

    destroy(btoken_a);
    destroy(btoken_b);

    // Swap
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 50_000, &clock, ctx);
    let mut btoken_b = coin::zero(ctx);

    destroy(coin_a);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank_a.funds_available().value(), 550_000);

    pool.cpmm_swap(
        &mut btoken_a,
        &mut btoken_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(reserve_a, 550_000);
    assert_eq(reserve_b, 454_910);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank_a.funds_available().value(), 550_000);
    assert_eq(bank_b.funds_available().value(), 500_000);

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);
    destroy(pool);
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

// - Deposits liquidity with lending on coin A and B
// - Checks btoken reserves and funds in bank before rebalancing
// - Checks btoken reserves and funds in bank after rebalancing
#[test]
fun test_simple_deposit_with_lending_ab() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_cpmm(100, 0);
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 500_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 500_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_a.funds_available().value(), 500_000); // 500_000 * 100%
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_b.funds_available().value(), 500_000); // 500_000 * 100%

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        500_000,
        500_000,
        ctx,
    );

    // Test deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);

    // Test bank effects after rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);
    destroy(pool);
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
fun test_swap_with_lending_within_utilization_range() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_cpmm(100, 0);
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 500_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 500_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_a.funds_available().value(), 500_000); // 500_000 * 100%
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_b.funds_available().value(), 500_000); // 500_000 * 100%

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        500_000,
        500_000,
        ctx,
    );

    // Test deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);

    // Test bank effects after rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

    destroy(btoken_a);
    destroy(btoken_b);

    // Swap
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(50_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 50_000, &clock, ctx);
    let mut btoken_b = coin::zero(ctx);

    destroy(coin_a);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // No change
    assert_eq(bank_a.funds_available().value(), 100_000 + 50_000);
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000); // No change
    assert_eq(bank_b.funds_available().value(), 100_000); // No change

    let swap_result = pool.cpmm_swap(
        &mut btoken_a,
        &mut btoken_b,
        true, // a2b
        50_000,
        0,
        ctx,
    );

    // Test swap effects
    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 550_000);
    assert_eq(reserve_b, 454_910);

    assert_eq(btoken_b.value(), 44_999);
    assert_eq(swap_result.protocol_fees(), 91);
    assert_eq(swap_result.pool_fees(), 364);
    assert_eq(swap_result.amount_out(), 44_999 + 91 + 364);

    // Burn btoken
    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 44_999);

    destroy(btoken_b);

    // Confirm that bank DOES NOT need to be rebalanced
    assert!(!bank_a.needs_rebalance(&lending_market, &clock));
    assert!(!bank_b.needs_rebalance(&lending_market, &clock));

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000);
    assert_eq(bank_a.funds_available().value(), 150_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000);
    assert_eq(bank_b.funds_available().value(), 100_000 - coin_b.value());

    // Confirm that rebalance is no-op
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert!(!bank_a.needs_rebalance(&lending_market, &clock));
    assert!(!bank_b.needs_rebalance(&lending_market, &clock));

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000);
    assert_eq(bank_a.funds_available().value(), 150_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000);
    assert_eq(bank_b.funds_available().value(), 100_000 - coin_b.value());

    destroy(btoken_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
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
fun test_swap_with_lending_beyond_utilization_range() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_cpmm(100, 0);
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(500_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(500_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 500_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 500_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_a.funds_available().value(), 500_000); // 500_000 * 100%
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 0); // 500_000 * 0%
    assert_eq(bank_b.funds_available().value(), 500_000); // 500_000 * 100%

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        500_000,
        500_000,
        ctx,
    );

    // Test deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();

    assert_eq(pool.cpmm_k(0), 500_000 * 500_000);
    assert_eq(pool.lp_supply_val(), 500_000);
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);
    assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 500_000);
    assert_eq(reserve_b, 500_000);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_a.funds_available().value(), 100_000); // 500_000 * 20%

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000); // 500_000 * 80%
    assert_eq(bank_b.funds_available().value(), 100_000); // 500_000 * 20%

    destroy(btoken_a);
    destroy(btoken_b);

    // Swap
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(200_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 200_000, &clock, ctx);
    let mut btoken_b = coin::zero(ctx);

    destroy(coin_a);

    // Test bank effects after minting btokens
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000); // No change
    assert_eq(bank_a.funds_available().value(), 100_000 + 200_000);
    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400_000); // No change
    assert_eq(bank_b.funds_available().value(), 100_000); // No change

    let swap_result = pool.cpmm_swap(
        &mut btoken_a,
        &mut btoken_b,
        true, // a2b
        200_000,
        0,
        ctx,
    );

    // Test swap effects
    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 700_000);
    assert_eq(reserve_b, 358_286);
    assert_eq(reserve_b + pool.trading_data().protocol_fees_b(), 358_572);

    assert_eq(btoken_b.value(), 141_428);
    assert_eq(swap_result.protocol_fees(), 286);
    assert_eq(swap_result.pool_fees(), 1143);
    assert_eq(swap_result.amount_out(), 141_428 + 286 + 1143);

    // Confirm that bank DOES need to be rebalanced
    assert!(bank_a.needs_rebalance(&lending_market, &clock), 1);
    assert!(bank_b.needs_rebalance_after_outflow(&lending_market, btoken_b.value(), &clock), 2);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 400_000);
    assert_eq(bank_a.funds_available().value(), 300_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 400000);
    assert_eq(bank_b.funds_available().value(), 100000);

    // Burn btoken
    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 141_428);

    destroy(btoken_b);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // This rebalance is no-op because it auto-rebalances on burn
    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 560_000);
    assert_eq(bank_a.funds_available().value(), 140_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 286_857); // 286,857.6
    assert_eq(bank_b.funds_available().value(), 71_715); // 71,714.4

    destroy(btoken_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(pool);
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
fun test_deposit_with_lending_all_scenarios() {
    let mut scenario = test_scenario::begin(ADMIN);


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 100_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 100_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000,
        100_000,
        ctx,
    );

    // Deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(pool.lp_supply_val(), 100_000);
    assert_eq(reserve_a, 100_000);
    assert_eq(reserve_b, 100_000);
    assert_eq(lp_coins.value(), 100_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 0);
    assert_eq(bank_a.funds_available().value(), 100_000);
    assert_eq(bank_b.funds_available().value(), 100_000);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000); // 100_000 * 80%
    assert_eq(bank_a.funds_available().value(), 20_000); // 500_000 * 20%
    assert_eq(bank_b.funds_available().value(), 100_000);

    assert_eq(bank_a.effective_utilisation_bps(&lending_market, &clock), 8000); // 80% target liquidity

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);

    // Deposit funds in AMM Pool - below buffer - does not lend
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(5_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(5_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 5_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 5_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        5_000,
        5_000,
        ctx,
    );

    // Deposit effects
    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(pool.lp_supply_val(), 105_000);
    assert_eq(reserve_a, 105_000);
    assert_eq(reserve_b, 105_000);
    assert_eq(lp_coins.value(), 5_000); // newly minted lp tokens

    // No need to rebalancing
    assert!(!bank_a.needs_rebalance(&lending_market, &clock));

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000); // 100_000 * 80%
    assert_eq(bank_a.funds_available().value(), 25_000); // 100_000 * 20% + 5_000
    assert_eq(bank_b.funds_available().value(), 105_000);

    assert!(
        bank_a.effective_utilisation_bps(&lending_market, &clock) < bank_a.target_utilisation_bps(),
        0,
    );
    assert!(
        bank_a.effective_utilisation_bps(&lending_market, &clock) > bank_a.target_utilisation_bps() -  bank_a.utilisation_buffer_bps(),
        0,
    );

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);

    // Deposit funds in AMM Pool - above buffer - lend
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(5_000_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(5_000_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        5_000_000,
        &clock,
        ctx,
    );
    let mut btoken_b = bank_b.mint_btokens(
        &mut lending_market,
        &mut coin_b,
        5_000_000,
        &clock,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        5_000_000,
        5_000_000,
        ctx,
    );

    // Needs rebalance
    assert!(bank_a.needs_rebalance(&lending_market, &clock));

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(pool.lp_supply_val(), 5_105_000);
    assert_eq(reserve_a, 5_105_000);
    assert_eq(reserve_b, 5_105_000);
    assert_eq(lp_coins.value(), 5_000_000); // newly minted lp tokens

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 4_084_000); // 5_105_000 * 80%
    assert_eq(bank_a.funds_available().value(), 1_021_000); // 5_125_000 * 20%
    assert_eq(bank_b.funds_available().value(), 5_105_000);

    assert_eq(bank_a.effective_utilisation_bps(&lending_market, &clock), 8000); // 80% target liquidity

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);

    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_deposit_with_lending_proptest() {
    let mut scenario = test_scenario::begin(ADMIN);


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000_000_00_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000_000_00_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        100_000_000_00_000,
        &clock,
        ctx,
    );
    let mut btoken_b = bank_b.mint_btokens(
        &mut lending_market,
        &mut coin_b,
        100_000_000_00_000,
        &clock,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000_000_00_000,
        100_000_000_00_000,
        ctx,
    );

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(lp_coins);

    // deposit loop
    let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);
    let mut deposits = 1_000;

    while (deposits > 0) {
        let amount_in = rng.generate_u64_in_range(1_000, 100_000);

        let mut coin_a = coin::mint_for_testing<TEST_USDC>(amount_in, ctx);
        let mut coin_b = coin::mint_for_testing<TEST_SUI>(amount_in, ctx);

        let mut btoken_a = bank_a.mint_btokens(
            &mut lending_market,
            &mut coin_a,
            amount_in,
            &clock,
            ctx,
        );
        let mut btoken_b = bank_b.mint_btokens(
            &mut lending_market,
            &mut coin_b,
            amount_in,
            &clock,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut btoken_a,
            &mut btoken_b,
            amount_in,
            amount_in,
            ctx,
        );

        bank_a.rebalance(
            &mut lending_market,
            &clock,
            ctx,
        );

        bank_b.rebalance(
            &mut lending_market,
            &clock,
            ctx,
        );

        assert!(
            bank_a.effective_utilisation_bps(&lending_market, &clock).max(8000) - bank_a.effective_utilisation_bps(&lending_market, &clock).min(8000) <= 1,
        ); // 80% target liquidity (with 0.001% deviation from rounding err)

        destroy(btoken_a);
        destroy(btoken_b);
        destroy(lp_coins);

        deposits = deposits - 1;
    };

    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_lend_redeem_with_lending_within_utilization() {
    let mut scenario = test_scenario::begin(ADMIN);


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 100_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 100_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (mut lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000,
        100_000,
        ctx,
    );

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(pool.lp_supply_val(), 100_000);
    assert_eq(reserve_a, 100_000);
    assert_eq(reserve_b, 100_000);
    assert_eq(lp_coins.value(), 100_000 - minimum_liquidity());
    assert_eq(pool.trading_data().pool_fees_a(), 0);
    assert_eq(pool.trading_data().pool_fees_b(), 0);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000); // 100_000 * 80%
    assert_eq(bank_a.funds_available().value(), 20_000); // 100_000 * 20%
    assert_eq(bank_b.funds_available().value(), 100_000);

    assert_eq(bank_a.effective_utilisation_bps(&lending_market, &clock), 8000); // 80% target liquidity

    destroy(btoken_a);
    destroy(btoken_b);

    // Redeem funds in AMM Pool - below buffer - does not recall
    let (mut btoken_a, mut btoken_b, _) = pool.redeem_liquidity(
        lp_coins.split(100, ctx),
        100,
        100,
        ctx,
    );

    let btoken_a_value = btoken_a.value();
    let coin_a = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a,
        btoken_a_value,
        &clock,
        ctx,
    );
    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 100);
    assert_eq(coin_b.value(), 100);

    destroy(btoken_a);
    destroy(btoken_b);

    // Dos noes need rebalance
    assert!(!bank_a.needs_rebalance(&lending_market, &clock));

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(pool.lp_supply_val(), 100_000 - 100);
    assert_eq(reserve_a, 100_000 - 100);
    assert_eq(reserve_b, 100_000 - 100);
    assert_eq(lp_coins.value(), 100_000 - 100 - 10); // extra 10 is minimum_liquidity

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000); // amount lent does not change
    assert_eq(bank_a.funds_available().value(), 19_900); // 100_000 * 20% - 100
    assert_eq(bank_b.funds_available().value(), 100_000 - 100);

    assert!(
        bank_a.effective_utilisation_bps(&lending_market, &clock) > bank_a.target_utilisation_bps(),
        0,
    );
    assert!(
        bank_a.effective_utilisation_bps(&lending_market, &clock) < bank_a.target_utilisation_bps() + bank_a.utilisation_buffer_bps(),
        0,
    );

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_lend_amm_swap_small_swap_scenario_no_rebalance() {
    let mut scenario = test_scenario::begin(ADMIN);


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );
    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 100_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 100_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000,
        100_000,
        ctx,
    );

    destroy(btoken_a);
    destroy(btoken_b);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Swap funds in AMM Pool - below buffer - does not recall
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(10, ctx);

    let mut btoken_a = coin::zero(ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 10, &clock, ctx);

    destroy(coin_b);

    let swap_result = dummy_swap(
        &mut pool,
        &mut btoken_a,
        &mut btoken_b,
        false, // a2b
        10,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 100000 - 10);
    assert_eq(reserve_b, 100000 + 10);

    assert_eq(btoken_a.value(), 10);
    assert_eq(btoken_b.value(), 0);
    assert_eq(swap_result.protocol_fees(), 0);
    assert_eq(swap_result.pool_fees(), 0);
    assert_eq(swap_result.amount_out(), 10);

    // Confirm that bank DOES NOT need to be rebalanced
    assert!(!bank_a.needs_rebalance_after_outflow(&lending_market, btoken_a.value(), &clock), 2);
    assert!(!bank_b.needs_rebalance(&lending_market, &clock), 1);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_a.funds_available().value(), 20_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_b.funds_available().value(), 20_000 + 10);

    // Burn btoken
    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 0);

    let btoken_a_value = btoken_a.value();
    let coin_a = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a,
        btoken_a_value,
        &clock,
        ctx,
    );
    assert_eq(coin_a.value(), 10);

    destroy(btoken_a);
    destroy(btoken_b);

    // Rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Assert rebalancing result - no-op
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_a.funds_available().value(), 20_000 - 10);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_b.funds_available().value(), 20_000 + 10);

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
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


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );
    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 100_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 100_000, &clock, ctx);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000,
        100_000,
        ctx,
    );

    destroy(btoken_a);
    destroy(btoken_b);
    destroy(coin_a);
    destroy(coin_b);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Swap funds in AMM Pool
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(20_000, ctx);

    let mut btoken_a = coin::zero(ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 20_000, &clock, ctx);

    destroy(coin_b);

    let swap_result = dummy_swap(
        &mut pool,
        &mut btoken_a,
        &mut btoken_b,
        false, // a2b
        20_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 100000 - 20_000);
    assert_eq(reserve_b, 100000 + 20_000);

    assert_eq(btoken_a.value(), 20_000);
    assert_eq(btoken_b.value(), 0);
    assert_eq(swap_result.protocol_fees(), 0);
    assert_eq(swap_result.pool_fees(), 0);
    assert_eq(swap_result.amount_out(), 20_000);

    // Confirm that bank DOES need to be rebalanced
    assert!(bank_a.needs_rebalance_after_outflow(&lending_market, btoken_a.value(), &clock), 2);
    assert!(bank_b.needs_rebalance(&lending_market, &clock), 1);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_a.funds_available().value(), 20_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_b.funds_available().value(), 20_000 + 20_000);

    // Burn btoken
    let btoken_a_value = btoken_a.value();
    let coin_a = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a,
        btoken_a_value,
        &clock,
        ctx,
    );
    assert_eq(coin_a.value(), 20_000);

    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 0);

    destroy(btoken_a);
    destroy(btoken_b);

    // Rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Assert rebalancing result
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 64_000);
    assert_eq(bank_a.funds_available().value(), 16_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 96_000);
    assert_eq(bank_b.funds_available().value(), 24_000);

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
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


    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    bank_a.mock_min_token_block_size(10);
    bank_b.mock_min_token_block_size(10);

    bank_a.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );
    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        500, // utilisation_bps
        ctx(&mut scenario),
    );

    // Init Pool
    test_scenario::next_tx(&mut scenario, POOL_CREATOR);
    let ctx = ctx(&mut scenario);

    // Deposit funds in AMM Pool
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(100_000, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(100_000, ctx);

    let mut btoken_a = bank_a.mint_btokens(&mut lending_market, &mut coin_a, 100_000, &clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 100_000, &clock, ctx);

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        100_000,
        100_000,
        ctx,
    );

    destroy(btoken_a);
    destroy(btoken_b);

    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Swap funds in AMM Pool
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(30_000, ctx);

    let mut btoken_a = coin::zero(ctx);
    let mut btoken_b = bank_b.mint_btokens(&mut lending_market, &mut coin_b, 30_000, &clock, ctx);

    destroy(coin_b);

    let swap_result = dummy_swap(
        &mut pool,
        &mut btoken_a,
        &mut btoken_b,
        false, // a2b
        30_000,
        0,
        ctx,
    );

    let (reserve_a, reserve_b) = pool.balance_amounts();
    assert_eq(reserve_a, 100000 - 30_000);
    assert_eq(reserve_b, 100000 + 30_000);

    assert_eq(btoken_a.value(), 30_000);
    assert_eq(btoken_b.value(), 0);
    assert_eq(swap_result.protocol_fees(), 0);
    assert_eq(swap_result.pool_fees(), 0);
    assert_eq(swap_result.amount_out(), 30_000);

    // Confirm that bank DOES need to be rebalanced
    assert!(bank_a.needs_rebalance_after_outflow(&lending_market, btoken_a.value(), &clock), 2);
    assert!(bank_b.needs_rebalance(&lending_market, &clock), 1);

    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_a.funds_available().value(), 20_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 80_000);
    assert_eq(bank_b.funds_available().value(), 20_000 + 30_000);

    // Burn btoken
    let btoken_a_value = btoken_a.value();
    let coin_a = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a,
        btoken_a_value,
        &clock,
        ctx,
    );
    assert_eq(coin_a.value(), 30_000);

    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );
    assert_eq(coin_b.value(), 0);

    destroy(btoken_a);
    destroy(btoken_b);

    // Rebalance
    bank_a.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    // Assert rebalancing result
    assert_eq(bank_a.funds_deployed(&lending_market, &clock).floor(), 56_000);
    assert_eq(bank_a.funds_available().value(), 14_000);

    assert_eq(bank_b.funds_deployed(&lending_market, &clock).floor(), 104_000);
    assert_eq(bank_b.funds_available().value(), 26_000);

    destroy(coin_a);
    destroy(coin_b);
    destroy(lp_coins);
    destroy(bank_a);
    destroy(bank_b);
    destroy(pool);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

// #[test]
// #[expected_failure(abort_code = bank::EInvalidCTokenRatio)]
// public fun test_fail_invalid_ctoken_ratio_1() {
//     let owner = @0x26;
//     let mut scenario = test_scenario::begin(owner);
//     let (mut clock, owner_cap, mut lending_market, mut prices, type_to_index) = suilend_setup(reserve_args_2(&mut scenario), &mut scenario).destruct_state();

//     let mut registry = registry::init_for_testing(ctx(&mut scenario));
//     let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
//     let mut bank_sui = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
//     bank_sui.mock_min_token_block_size(10);

//     bank_sui.deposit_for_testing(1_000_000);

//     bank_sui.init_lending<LENDING_MARKET, TEST_SUI>(
//         &global_admin,
//         &mut lending_market,
//         8_000, // utilisation_bps
//         1_000, // utilisation_bps
//         ctx(&mut scenario),
//     );

//     bank_sui.rebalance(
//         &mut lending_market,
//         &clock,
//         ctx(&mut scenario),
//     );

//     clock::set_for_testing(&mut clock, 1 * 1000);

//     // set reserve parameters and prices
//     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
//     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

//     // create obligation
//     let obligation_owner_cap = lending_market::create_obligation(
//         &mut lending_market,
//         test_scenario::ctx(&mut scenario)
//     );

//     let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
//     let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
//         &clock,
//         coins,
//         test_scenario::ctx(&mut scenario)
//     );
//     lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
//         &obligation_owner_cap,
//         &clock,
//         ctokens,
//         test_scenario::ctx(&mut scenario)
//     );

//     lending_market::refresh_reserve_price<LENDING_MARKET>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
//         &clock,
//         mock_pyth::get_price_obj<TEST_USDC>(&prices)
//     );
//     lending_market::refresh_reserve_price<LENDING_MARKET>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         &clock,
//         mock_pyth::get_price_obj<TEST_SUI>(&prices)
//     );

//     let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         &obligation_owner_cap,
//         &clock,
//         5 * 1_000_000_000,
//         test_scenario::ctx(&mut scenario)
//     );
//     test_utils::destroy(sui);

//     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 2, &clock); // $10
//     lending_market::refresh_reserve_price<LENDING_MARKET>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         &clock,
//         mock_pyth::get_price_obj<TEST_SUI>(&prices)
//     );

//     // liquidate the obligation
//     let mut sui = coin::mint_for_testing<TEST_SUI>(1 * 1_000_000_000, test_scenario::ctx(&mut scenario));
//     let (usdc, _exemption) = lending_market::liquidate<LENDING_MARKET, TEST_SUI, TEST_USDC>(
//         &mut lending_market,
//         lending_market::obligation_id(&obligation_owner_cap),
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
//         &clock,
//         &mut sui,
//         test_scenario::ctx(&mut scenario)
//     );

//     lending_market::forgive<LENDING_MARKET, TEST_SUI>(
//         &owner_cap,
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         lending_market::obligation_id(&obligation_owner_cap),
//         &clock,
//         1_000_000_000 + 10_000,
//     );

//     balance::destroy_for_testing(
//         bank_sui.withdraw_for_testing(150000)
//     );

//     bank_sui.rebalance(
//         &mut lending_market,
//         &clock,
//         ctx(&mut scenario),
//     );

//     test_utils::destroy(usdc);
//     test_utils::destroy(sui);
//     test_utils::destroy(obligation_owner_cap);
//     test_utils::destroy(owner_cap);
//     test_utils::destroy(lending_market);
//     test_utils::destroy(clock);
//     test_utils::destroy(prices);
//     test_utils::destroy(type_to_index);
//     test_utils::destroy(bank_sui);
//     test_utils::destroy(global_admin);
//     test_utils::destroy(registry);
//     test_scenario::end(scenario);
// }

// #[test]
// #[expected_failure(abort_code = bank::EInvalidCTokenRatio)]
// public fun test_fail_invalid_ctoken_ratio_2() {
//     let owner = @0x26;
//     let mut scenario = test_scenario::begin(owner);
//     let (mut clock, owner_cap, mut lending_market, mut prices, type_to_index) = suilend_setup(reserve_args_2(&mut scenario), &mut scenario).destruct_state();

//     let mut registry = registry::init_for_testing(ctx(&mut scenario));
//     let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
//     let mut bank_sui = bank::create_bank<LENDING_MARKET, TEST_SUI>(&mut registry, ctx(&mut scenario));
//     bank_sui.mock_min_token_block_size(10);

//     clock::set_for_testing(&mut clock, 1 * 1000);

//     // set reserve parameters and prices
//     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
//     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

//     // create obligation
//     let obligation_owner_cap = lending_market::create_obligation(
//         &mut lending_market,
//         test_scenario::ctx(&mut scenario)
//     );

//     let coins = coin::mint_for_testing<TEST_SUI>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
//     let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_SUI>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         &clock,
//         coins,
//         test_scenario::ctx(&mut scenario)
//     );

//     lending_market::refresh_reserve_price<LENDING_MARKET>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
//         &clock,
//         mock_pyth::get_price_obj<TEST_USDC>(&prices)
//     );
//     lending_market::refresh_reserve_price<LENDING_MARKET>(
//         &mut lending_market,
//         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
//         &clock,
//         mock_pyth::get_price_obj<TEST_SUI>(&prices)
//     );

//     let idx = lending_market.reserve_array_index<LENDING_MARKET, TEST_SUI>();
//     let reserves = lending_market.reserves_mut_for_testing();
//     let reserve = &mut reserves[idx];
//     // This is to change the underlying token ratio
//     reserve.burn_ctokens_for_testing(
//         balance::create_for_testing<CToken<LENDING_MARKET, TEST_SUI>>(52_000_000_000)
//     );

//     // Init bank lending
//     bank_sui.init_lending<LENDING_MARKET, TEST_SUI>(
//         &global_admin,
//         &mut lending_market,
//         10_000, // utilisation_bps
//         0, // utilisation_bps
//         ctx(&mut scenario),
//     );

//     // Deposit
//     bank_sui.deposit_for_testing(30);

//     bank_sui.rebalance(
//         &mut lending_market,
//         &clock,
//         ctx(&mut scenario),
//     );

//     bank_sui.set_utilisation_bps(
//         &global_admin,
//         0, // utilisation_bps
//         0, // utilisation_bps
//     );

//     // Withdraw
//     bank_sui.rebalance(
//         &mut lending_market,
//         &clock,
//         ctx(&mut scenario),
//     );

//     test_utils::destroy(obligation_owner_cap);
//     test_utils::destroy(owner_cap);
//     test_utils::destroy(lending_market);
//     test_utils::destroy(clock);
//     test_utils::destroy(prices);
//     test_utils::destroy(type_to_index);
//     test_utils::destroy(bank_sui);
//     test_utils::destroy(global_admin);
//     test_utils::destroy(registry);
//     test_utils::destroy(ctokens);
//     test_scenario::end(scenario);
// }

#[test]
public fun test_no_op_below_min_deploy_amount() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);
    let (clock, owner_cap, mut lending_market, prices, type_to_index) = suilend_setup(
        reserve_args_2(&mut scenario),
        &mut scenario,
    ).destruct_state();

    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
    let (pool, bank_usdc, mut bank_sui) = test_setup_dummy_no_fees();
    bank_sui.mock_min_token_block_size(10);

    bank_sui.deposit_for_testing(1);
    bank_sui.init_lending(
        &global_admin,
        &mut lending_market,
        10_000, // utilisation_bps
        0, // utilisation_bps
        ctx(&mut scenario),
    );

    let effective_utilisation_bps_before = bank_sui.effective_utilisation_bps(
        &lending_market,
        &clock,
    );

    bank_sui.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let effective_utilisation_bps_after = bank_sui.effective_utilisation_bps(
        &lending_market,
        &clock,
    );

    assert!(effective_utilisation_bps_before == effective_utilisation_bps_after, 0);

    test_utils::destroy(pool);
    test_utils::destroy(owner_cap);
    test_utils::destroy(lending_market);
    test_utils::destroy(clock);
    test_utils::destroy(prices);
    test_utils::destroy(type_to_index);
    test_utils::destroy(bank_sui);
    test_utils::destroy(bank_usdc);
    test_utils::destroy(global_admin);
    test_scenario::end(scenario);
}

#[test]
public fun test_interest_distribution_one_lp() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (
        mut clock,
        lend_cap,
        mut lending_market,
        mut prices,
        type_to_index,
    ) = suilend::lending_market_tests::setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    clock.set_for_testing(1733093342000);

    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
   let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();

    let ctx = ctx(&mut scenario);

    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        10_000, // utilisation_bps
        0, // utilisation_bps
        ctx,
    );

    pool.no_protocol_fees_for_testing();
    pool.no_redemption_fees_for_testing();
    bank_b.mock_min_token_block_size(10);

    // Deposit funds in AMM Pool
    let liquidity_amount = 3_000_010; // we add the +10 which is locked forever
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(liquidity_amount, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(liquidity_amount, ctx);

    let mut btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        liquidity_amount,
        &clock,
        ctx,
    );
    let mut btoken_b = bank_b.mint_btokens(
        &mut lending_market,
        &mut coin_b,
        liquidity_amount,
        &clock,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins, deposit_result) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        liquidity_amount,
        liquidity_amount,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    assert!(deposit_result.deposit_a() == 3000010, 0);
    assert!(deposit_result.deposit_b() == 3000010, 0);

    test_utils::destroy(btoken_a);
    test_utils::destroy(btoken_b);

    // == Borrow from Suilend to generate interest

    // set reserve parameters and prices
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 0, &clock); // $1

    // create obligation
    let obligation_owner_cap = lending_market::create_obligation(
        &mut lending_market,
        ctx,
    );

    // Deposit collateral
    let coins = coin::mint_for_testing<TEST_USDC>(100 * 10_000_000, ctx);
    let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        coins,
        ctx,
    );
    lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &obligation_owner_cap,
        &clock,
        ctokens,
        ctx,
    );

    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices),
    );
    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &clock,
        mock_pyth::get_price_obj<TEST_SUI>(&prices),
    );

    // Borrow SUI
    let borrow_amount = 1_500_000;
    let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &obligation_owner_cap,
        &clock,
        borrow_amount,
        ctx,
    );

    test_utils::destroy(sui);

    clock.set_for_testing(1764629342000);

    let mut sui_to_repay = coin::mint_for_testing<TEST_SUI>(2_000_000, ctx);

    lending_market::repay<LENDING_MARKET, TEST_SUI>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        obligation_owner_cap.obligation_id(),
        &clock,
        &mut sui_to_repay,
        ctx,
    );

    let interest_paid = 2_000_000 - borrow_amount - sui_to_repay.value();

    test_utils::destroy(sui_to_repay);

    // Redeem liquidity
    let (mut btoken_a, mut btoken_b, _) = pool.redeem_liquidity(
        lp_coins,
        0,
        0,
        ctx,
    );

    assert_eq(btoken_a.value(), 3_000_000);
    assert_eq(btoken_b.value(), 3_000_000);

    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 0, &clock); // $1

    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices),
    );
    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &clock,
        mock_pyth::get_price_obj<TEST_SUI>(&prices),
    );

    let btoken_a_value = btoken_a.value();
    let coin_a = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a,
        btoken_a_value,
        &clock,
        ctx,
    );
    let btoken_b_value = btoken_b.value();
    let coin_b = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b,
        btoken_b_value,
        &clock,
        ctx,
    );

    destroy(btoken_a);
    destroy(btoken_b);

    assert_eq(coin_a.value(), 3_000_000); // No lending on so it stays the same

    // Initial funds deposited on the lending market: 1000000
    let estimated_interest_to_lp = interest_paid * 3_000_000 / 4_000_000;
    let actual_interest_to_lp = coin_b.value() - 3_000_000;

    assert_eq_approx!(estimated_interest_to_lp, actual_interest_to_lp, 1);

    test_utils::destroy(coin_a);
    test_utils::destroy(coin_b);
    test_utils::destroy(obligation_owner_cap);
    test_utils::destroy(lending_market);
    test_utils::destroy(lend_cap);
    test_utils::destroy(clock);
    test_utils::destroy(type_to_index);
    test_utils::destroy(prices);
    test_utils::destroy(pool);
    test_utils::destroy(bank_a);
    test_utils::destroy(bank_b);
    test_utils::destroy(global_admin);
    test_scenario::end(scenario);
}

#[test]
public fun test_interest_distribution_multiple_lps() {
    let mut scenario = test_scenario::begin(ADMIN);

    let (
        mut clock,
        lend_cap,
        mut lending_market,
        mut prices,
        type_to_index,
    ) = suilend::lending_market_tests::setup(
        reserve_args(&mut scenario),
        &mut scenario,
    ).destruct_state();
    clock.set_for_testing(1733093342000);

    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));
    let (mut pool, mut bank_a, mut bank_b) = test_setup_dummy_no_fees();
    let ctx = ctx(&mut scenario);

    bank_b.init_lending(
        &global_admin,
        &mut lending_market,
        10_000, // utilisation_bps
        0, // utilisation_bps
        ctx,
    );

    pool.no_protocol_fees_for_testing();
    pool.no_redemption_fees_for_testing();
    bank_b.mock_min_token_block_size(10);

    // Deposit funds in AMM Pool
    let liquidity_amount = 1_500_010; // we add the +10 which is locked forever
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(liquidity_amount, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(liquidity_amount, ctx);

    let mut btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        liquidity_amount,
        &clock,
        ctx,
    );
    let mut btoken_b = bank_b.mint_btokens(
        &mut lending_market,
        &mut coin_b,
        liquidity_amount,
        &clock,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins_1, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        liquidity_amount,
        liquidity_amount,
        ctx,
    );

    test_utils::destroy(btoken_a);
    test_utils::destroy(btoken_b);

    let liquidity_amount = 1_500_000;
    let mut coin_a = coin::mint_for_testing<TEST_USDC>(liquidity_amount, ctx);
    let mut coin_b = coin::mint_for_testing<TEST_SUI>(liquidity_amount, ctx);

    let mut btoken_a = bank_a.mint_btokens(
        &mut lending_market,
        &mut coin_a,
        liquidity_amount,
        &clock,
        ctx,
    );
    let mut btoken_b = bank_b.mint_btokens(
        &mut lending_market,
        &mut coin_b,
        liquidity_amount,
        &clock,
        ctx,
    );

    destroy(coin_a);
    destroy(coin_b);

    let (lp_coins_2, _) = pool.deposit_liquidity(
        &mut btoken_a,
        &mut btoken_b,
        liquidity_amount,
        liquidity_amount,
        ctx,
    );

    bank_b.rebalance(
        &mut lending_market,
        &clock,
        ctx,
    );

    test_utils::destroy(btoken_a);
    test_utils::destroy(btoken_b);

    // == Borrow from Suilend to generate interest

    // set reserve parameters and prices
    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 0, &clock); // $1

    // create obligation
    let obligation_owner_cap = lending_market::create_obligation(
        &mut lending_market,
        ctx,
    );

    // Deposit collateral
    let coins = coin::mint_for_testing<TEST_USDC>(100 * 10_000_000, ctx);
    let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        coins,
        ctx,
    );
    lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &obligation_owner_cap,
        &clock,
        ctokens,
        ctx,
    );

    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices),
    );
    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &clock,
        mock_pyth::get_price_obj<TEST_SUI>(&prices),
    );

    // Borrow SUI
    let borrow_amount = 1_500_000;
    let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &obligation_owner_cap,
        &clock,
        borrow_amount,
        ctx,
    );

    test_utils::destroy(sui);

    clock.set_for_testing(1764629342000);

    let mut sui_to_repay = coin::mint_for_testing<TEST_SUI>(2_000_000, ctx);

    lending_market::repay<LENDING_MARKET, TEST_SUI>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        obligation_owner_cap.obligation_id(),
        &clock,
        &mut sui_to_repay,
        ctx,
    );

    let interest_paid = 2_000_000 - borrow_amount - sui_to_repay.value();

    test_utils::destroy(sui_to_repay);

    // Redeem liquidity
    let (mut btoken_a1, mut btoken_b1, _) = pool.redeem_liquidity(
        lp_coins_1,
        0,
        0,
        ctx,
    );

    assert_eq(btoken_a1.value(), 1_500_000);
    assert_eq(btoken_b1.value(), 1_500_000);

    let (mut btoken_a2, mut btoken_b2, _) = pool.redeem_liquidity(
        lp_coins_2,
        0,
        0,
        ctx,
    );

    assert_eq(btoken_a2.value(), 1_500_000);
    assert_eq(btoken_b2.value(), 1_500_000);

    mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 0, &clock); // $1

    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_USDC>()),
        &clock,
        mock_pyth::get_price_obj<TEST_USDC>(&prices),
    );
    lending_market::refresh_reserve_price<LENDING_MARKET>(
        &mut lending_market,
        *type_to_index.borrow(type_name::get<TEST_SUI>()),
        &clock,
        mock_pyth::get_price_obj<TEST_SUI>(&prices),
    );

    let btoken_a1_value = btoken_a1.value();
    let btoken_b1_value = btoken_b1.value();
    let btoken_a2_value = btoken_a2.value();
    let btoken_b2_value = btoken_b2.value();
    let coin_a1 = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a1,
        btoken_a1_value,
        &clock,
        ctx,
    );
    let coin_b1 = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b1,
        btoken_b1_value,
        &clock,
        ctx,
    );
    let coin_a2 = bank_a.burn_btokens(
        &mut lending_market,
        &mut btoken_a2,
        btoken_a2_value,
        &clock,
        ctx,
    );
    let coin_b2 = bank_b.burn_btokens(
        &mut lending_market,
        &mut btoken_b2,
        btoken_b2_value,
        &clock,
        ctx,
    );

    destroy(btoken_a1);
    destroy(btoken_b1);
    destroy(btoken_a2);
    destroy(btoken_b2);

    assert_eq(coin_a1.value(), 1_500_000); // No lending on so it stays the same
    assert_eq(coin_a2.value(), 1_500_000); // No lending on so it stays the same

    // Initial funds deposited on the lending market: 1000000
    let estimated_interest_to_lp = interest_paid * 3_000_000 / 4_000_000;
    let actual_interest_to_lp = coin_b1.value() + coin_b2.value() - 3_000_000;

    assert_eq_approx!(estimated_interest_to_lp, actual_interest_to_lp, 1);

    test_utils::destroy(coin_a1);
    test_utils::destroy(coin_a2);
    test_utils::destroy(coin_b1);
    test_utils::destroy(coin_b2);
    test_utils::destroy(obligation_owner_cap);
    test_utils::destroy(lending_market);
    test_utils::destroy(lend_cap);
    test_utils::destroy(clock);
    test_utils::destroy(type_to_index);
    test_utils::destroy(prices);
    test_utils::destroy(pool);
    test_utils::destroy(bank_a);
    test_utils::destroy(bank_b);
    test_utils::destroy(global_admin);
    test_scenario::end(scenario);
}
