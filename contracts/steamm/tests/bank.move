module steamm::bank_tests;

use std::option::some;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::bank::{Self, Bank};
use steamm::bank_math;
use steamm::global_admin;
use steamm::test_utils::{Self, reserve_args};
use sui::coin;
use sui::test_scenario::{Self, Scenario, ctx};
use sui::test_utils::{destroy, assert_eq};
use suilend::lending_market_tests::{LENDING_MARKET, setup as suilend_setup};
use suilend::test_usdc::TEST_USDC;
use suilend::lending_market;
use suilend::reserve_config;
use suilend::reserve;
use suilend::decimal;
use suilend::liquidity_mining;
use suilend::obligation;
use sui::clock;
use sui::object_table;
use std::type_name;
use std::option::{none};
use sui::balance;
use sui::sui::SUI;
use sui_system::governance_test_utils::{
    advance_epoch_with_reward_amounts,
    create_validator_for_testing,
    create_sui_system_state_for_testing
};
use sui_system::sui_system::SuiSystemState;
use sprungsui::sprungsui::SPRUNGSUI;

public struct TEST_BSUI has drop {}

const SUILEND_VALIDATOR: address = @0xce8e537664ba5d1d5a6a857b17bd142097138706281882be6805e17065ecde89;

fun setup_sui_system(scenario: &mut Scenario) {
    test_scenario::next_tx(scenario, SUILEND_VALIDATOR);
    let validator = create_validator_for_testing(
        SUILEND_VALIDATOR,
        100,
        scenario.ctx(),
    );
    create_sui_system_state_for_testing(vector[validator], 0, 0, scenario.ctx());

    advance_epoch_with_reward_amounts(0, 0, scenario);
}

#[test_only]
fun setup_bank(scenario: &mut Scenario): Bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC> {
    let (
        pool,
        bank_a,
        bank_b,
        lending_market,
        lend_cap,
        prices,
        bag,
        clock,
    ) = test_utils::test_setup_dummy(0, scenario);

    destroy(pool);
    destroy(bank_b);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    bank_a
}

#[test]
fun test_create_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    // Create amm bank
    let bank = setup_bank(&mut scenario);

    destroy(bank);
    destroy(scenario);
}

#[test]
fun test_init_lending() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::ELendingAlreadyActive)]
fun test_fail_init_lending_twice() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_bps
        1_000, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeAboveHundredPercent)]
fun test_invalid_utilisation_liquidity_above_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        10_001, // utilisation_bps
        1_000, // buffer
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = bank::EUtilisationRangeBelowZeroPercent)]
fun test_invalid_target_liquidity_below_100() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        1_000, // utilisation_bps
        1_001, // utilisation_buffer_bps
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = bank_math::EEmptyBank)]
fun test_fail_assert_empty_bank() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();
    // Create amm bank
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    let mut bank = setup_bank(&mut scenario);

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        8_000, // utilisation_rate
        500, // utilisation_buffer
        ctx(&mut scenario),
    );

    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    destroy(bank);
    destroy(global_admin);
    destroy(lending_market);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);
    test_scenario::end(scenario);
}

#[test]
fun test_bank_rebalance_deploy() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(funds_deployed, 0);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 0);

    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_rebalance_recall() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 50 * 1_000_000);
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    bank.set_utilisation_bps_for_testing(0, 0);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert_eq(bank.funds_available().value(), 100 * 1_000_000);
    assert_eq(funds_deployed, 0);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 0);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_bank_prepare_bank_for_pending_withdraw() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    bank.mock_min_token_block_size(10);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    bank.deposit_for_testing(100 * 1_000_000);
    bank.rebalance(
        &mut lending_market,
        &clock,
        ctx(&mut scenario),
    );
    assert!(bank.funds_available().value() == 50 * 1_000_000, 0);
    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();
    assert_eq(funds_deployed, 50 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 100 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    bank.prepare_for_pending_withdraw(
        &mut lending_market,
        20 * 1_000_000,
        &clock,
        ctx(&mut scenario),
    );
    let usdc = bank.withdraw_for_testing(20 * 1_000_000);

    let ctoken_ratio = bank.ctoken_ratio(&lending_market, &clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    assert!(bank.funds_available().value() == 40 * 1_000_000, 0);
    assert_eq(funds_deployed, 40 * 1_000_000);
    assert_eq(bank.total_funds(some(ctoken_ratio)).floor(), 80 * 1_000_000);
    assert_eq(bank.effective_utilisation_bps(funds_deployed), 5_000);

    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(usdc);
    destroy(scenario);
}

#[test]
fun test_bank_withdraw_except_minimum_liquidity() {
    let mut scenario = test_scenario::begin(@0x0);

    let (clock, lend_cap, mut lending_market, prices, bag) = suilend_setup(
        reserve_args(&mut scenario),
        scenario.ctx(),
    ).destruct_state();

    // Create bank
    let mut bank = setup_bank(&mut scenario);
    let global_admin = global_admin::init_for_testing(ctx(&mut scenario));

    bank.init_lending(
        &global_admin,
        &mut lending_market,
        5_000,
        1_000,
        ctx(&mut scenario),
    );

    let mut coin = coin::mint_for_testing<TEST_USDC>(500_000, ctx(&mut scenario));
    let mut btoken = bank.mint_btokens(&mut lending_market, &mut coin, 500_000, &clock, ctx(&mut scenario));
    destroy(coin);

    let btoken_value = btoken.value();
    let coin = bank.burn_btokens(
        &mut lending_market,
        &mut btoken,
        btoken_value,
        &clock,
        ctx(&mut scenario),
    );

    assert_eq(coin.value(), 500_000 - bank::minimum_liquidity());

    destroy(coin);
    destroy(btoken);
    destroy(clock);
    destroy(bank);
    destroy(prices);
    destroy(bag);
    destroy(lend_cap);
    destroy(global_admin);
    destroy(lending_market);
    destroy(scenario);
}

#[test]
fun test_rebalance_sui_bank_with_liquidity_request() {
    let mut scenario = test_scenario::begin(@0x0);
    let lending_market_id = object::id_from_address(@0x84030d26d85eaa7035084a057f2f11f701b7e2e4eda87551becbc7c97505ece1);

    let time = 1748777367;
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(time * 1000);

    let reserve_config = reserve_config::create_reserve_config(
        70, // open_ltv_pct
        75, // close_ltv_pct
        75, // max_close_ltv_pct
        10000, // borrow_weight_bps
        100000000000000000, // deposit_limit
        80000000000000000, // borrow_limit
        300, // liquidation_bonus_bps
        300, // max_liquidation_bonus_bps
        500000000, // deposit_limit_usd
        90000000, // borrow_limit_usd
        0, // borrow_fee_bps
        2500, // spread_fee_bps
        199, // protocol_liquidation_fee_bps
        vector[0, 60, 80, 100], // interest_rate_utils
        vector[500, 1000, 1800, 30000], // interest_rate_aprs
        false, // isolated
        1000000000, // open_attributed_borrow_limit_usd
        1000000000, // close_attributed_borrow_limit_usd
        scenario.ctx() // ctx
    );

    let price_identifier: vector<u8> = vector[
        35,
        215,
        49,
        81,
        19,
        245,
        177,
        211,
        186,
        122,
        131,
        96,
        76,
        68,
        185,
        77,
        121,
        244,
        253,
        105,
        175,
        119,
        248,
        4,
        252,
        127,
        146,
        10,
        109,
        198,
        87,
        68
    ];

    let deposit_reward_manager = liquidity_mining::create_pool_reward_manager_for_testing(
        65734819628175472, // total_shares
        vector[], // pool_rewards
        1748777367408, // last_update_time_ms
        scenario.ctx(),
    );
    let borrow_reward_manager = liquidity_mining::create_pool_reward_manager_for_testing(
        21305774605619359, // total_shares
        vector[], // pool_rewards
        1748777324267, // last_update_time_ms
        scenario.ctx(),
    );

    let deposit_reward_manager_id = object::id(&deposit_reward_manager);
    let borrow_reward_manager_id = object::id(&borrow_reward_manager);

    let mut sui_reserve = reserve::mock_for_testing<LENDING_MARKET, SUI>(
        lending_market_id,
        reserve_config,
        0, // array_index
        9, // mint_decimals
        price_identifier,
        decimal::from_scaled_val(3257685640000000000), // price: Decimal,
        1748777330, // price_last_update_timestamp_s
        43828010892007133, // available_amount
        65750328645435119, // ctoken_supply
        decimal::from_scaled_val(23037522832986450928110055841477487), // borrowed_amount: 
        decimal::from_scaled_val(1081251792672888641), // cumulative_borrow_rate: 
        1748777367, // interest_last_update_timestamp_s
        decimal::from_scaled_val(22667184487310357246945449154001), // unclaimed_spread_fees: Decimal,
        decimal::from_scaled_val(0), // attributed_borrow_value: Decimal,
        deposit_reward_manager,
        borrow_reward_manager,
        // Balances
        0, // available_amount (in balance dyn field)
        68337752355870, // balance_fees
        1631719557100, // ctoken_fees
        65748664444277642, // deposited_ctokens TODO
        scenario.ctx(),
    );

    setup_sui_system(&mut scenario);

    scenario.next_tx(@0x0);
    
    let mut system_state = test_scenario::take_shared<SuiSystemState>(&scenario);

    let treasury_cap = coin::create_treasury_cap_for_testing<SPRUNGSUI>(scenario.ctx());

    sui_reserve.init_staker_for_testing(treasury_cap, scenario.ctx());
    let staker = sui_reserve.borrow_staker_for_testing();
    let sui = balance::create_for_testing<SUI>(1_36646596716698);
    staker.deposit_for_testing(sui);
    staker.rebalance_for_testing(&mut system_state, scenario.ctx());

    let deposit = obligation::create_deposit_for_testing(
        type_name::get<SUI>(), // coin_type
        0, // reserve_array_index
        319178156459500, // deposited_ctoken_amount
        decimal::from_scaled_val(1235756053105912240117095), // market_value
        0, // user_reward_manager_index
        decimal::from_scaled_val(0), // attributed_borrow_value: Decimal,
    );

    let deposit_user_reward = liquidity_mining::create_user_reward_manager_for_testing(
        deposit_reward_manager_id,
        0,
        vector[none()], // rewards
        time * 1000, // last_update_time_ms
    );
    let borrow_user_reward = liquidity_mining::create_user_reward_manager_for_testing(
        borrow_reward_manager_id,
        0,
        vector[none()], // rewards
        time * 1000, // last_update_time_ms
    );

    let obligation = obligation::mock_for_testing<LENDING_MARKET>(
        lending_market_id,
        vector[deposit], // deposits
        vector[], // borrows
        decimal::from_scaled_val(1235756053105912240117095), // deposited_value_usd
        decimal::from_scaled_val(859771545208106778279043), // allowed_borrow_value_usd
        decimal::from_scaled_val(926817039829434180087821), // unhealthy_borrow_value_usd: Decimal,
        decimal::from_scaled_val(0), // super_unhealthy_borrow_value_usd: Decimal, // unused
        decimal::from_scaled_val(0), // unweighted_borrowed_value_usd: Decimal,
        decimal::from_scaled_val(0), // weighted_borrowed_value_usd: Decimal,
        decimal::from_scaled_val(0), // weighted_borrowed_value_upper_bound_usd: Decimal,
        false, // borrowing_isolated_asset
        vector[deposit_user_reward, borrow_user_reward], // user_reward_managers
        decimal::from_scaled_val(0), // bad_debt_usd,
        false, // closable
        scenario.ctx(),
    );

    let mut obligations = object_table::new(scenario.ctx());
    let obligation_id = object::id(&obligation);

    obligations.add(obligation_id, obligation);

    let mut lending_market = lending_market::mock_for_testing(
        vector[sui_reserve],
        obligations,
        @0x0, // fee_receiver
        decimal::from_scaled_val(0), // bad_debt_usd
        decimal::from_scaled_val(0), // bad_debt_limit_usd
        scenario.ctx()
    );

    let lending_market_cap = lending_market::new_lending_market_owner_cap_for_testing<LENDING_MARKET>(
        object::id(&lending_market),
        scenario.ctx(),
    );
    
    let obligation_cap = lending_market::new_obligation_owner_cap_for_testing<LENDING_MARKET>(
        &lending_market,
        obligation_id,
        scenario.ctx(),
    );

    let (mut bank, btokens) = bank::mock_for_testing<LENDING_MARKET, SUI, TEST_BSUI>(
        59298460526863, // funds_available
        1000000000, // min_token_block_size
        382510546619429, // btoken_supply_val
        319178156459500, // ctokens
        7500, // target_utilisation_bps
        500, // utilisation_buffer_bps
        0, // reserve_array_index
        obligation_cap,
        scenario.ctx()
    );

    scenario.next_tx(@0x0);

    bank.rebalance_sui(&mut lending_market, &mut system_state, &clock, scenario.ctx());
  
    destroy(system_state);
    destroy(clock);
    destroy(bank);
    destroy(btokens);
    destroy(lending_market);
    destroy(lending_market_cap);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = sui::balance::ENotEnough)]
fun test_rebalance_sui_bank_fail_without_liquidity_request() {
    let mut scenario = test_scenario::begin(@0x0);
    let lending_market_id = object::id_from_address(@0x84030d26d85eaa7035084a057f2f11f701b7e2e4eda87551becbc7c97505ece1);

    let time = 1748777367;
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(time * 1000);

    let reserve_config = reserve_config::create_reserve_config(
        70, // open_ltv_pct
        75, // close_ltv_pct
        75, // max_close_ltv_pct
        10000, // borrow_weight_bps
        100000000000000000, // deposit_limit
        80000000000000000, // borrow_limit
        300, // liquidation_bonus_bps
        300, // max_liquidation_bonus_bps
        500000000, // deposit_limit_usd
        90000000, // borrow_limit_usd
        0, // borrow_fee_bps
        2500, // spread_fee_bps
        199, // protocol_liquidation_fee_bps
        vector[0, 60, 80, 100], // interest_rate_utils
        vector[500, 1000, 1800, 30000], // interest_rate_aprs
        false, // isolated
        1000000000, // open_attributed_borrow_limit_usd
        1000000000, // close_attributed_borrow_limit_usd
        scenario.ctx() // ctx
    );

    let price_identifier: vector<u8> = vector[
        35,
        215,
        49,
        81,
        19,
        245,
        177,
        211,
        186,
        122,
        131,
        96,
        76,
        68,
        185,
        77,
        121,
        244,
        253,
        105,
        175,
        119,
        248,
        4,
        252,
        127,
        146,
        10,
        109,
        198,
        87,
        68
    ];

    let deposit_reward_manager = liquidity_mining::create_pool_reward_manager_for_testing(
        65734819628175472, // total_shares
        vector[], // pool_rewards
        1748777367408, // last_update_time_ms
        scenario.ctx(),
    );
    let borrow_reward_manager = liquidity_mining::create_pool_reward_manager_for_testing(
        21305774605619359, // total_shares
        vector[], // pool_rewards
        1748777324267, // last_update_time_ms
        scenario.ctx(),
    );

    let deposit_reward_manager_id = object::id(&deposit_reward_manager);
    let borrow_reward_manager_id = object::id(&borrow_reward_manager);

    let mut sui_reserve = reserve::mock_for_testing<LENDING_MARKET, SUI>(
        lending_market_id,
        reserve_config,
        0, // array_index
        9, // mint_decimals
        price_identifier,
        decimal::from_scaled_val(3257685640000000000), // price: Decimal,
        1748777330, // price_last_update_timestamp_s
        43828010892007133, // available_amount
        65750328645435119, // ctoken_supply
        decimal::from_scaled_val(23037522832986450928110055841477487), // borrowed_amount: 
        decimal::from_scaled_val(1081251792672888641), // cumulative_borrow_rate: 
        1748777367, // interest_last_update_timestamp_s
        decimal::from_scaled_val(22667184487310357246945449154001), // unclaimed_spread_fees: Decimal,
        decimal::from_scaled_val(0), // attributed_borrow_value: Decimal,
        deposit_reward_manager,
        borrow_reward_manager,
        // Balances
        0, // available_amount (in balance dyn field)
        68337752355870, // balance_fees
        1631719557100, // ctoken_fees
        65748664444277642, // deposited_ctokens TODO
        scenario.ctx(),
    );

    setup_sui_system(&mut scenario);

    scenario.next_tx(@0x0);
    
    let mut system_state = test_scenario::take_shared<SuiSystemState>(&scenario);

    let treasury_cap = coin::create_treasury_cap_for_testing<SPRUNGSUI>(scenario.ctx());

    sui_reserve.init_staker_for_testing(treasury_cap, scenario.ctx());
    let staker = sui_reserve.borrow_staker_for_testing();
    let sui = balance::create_for_testing<SUI>(1_36646596716698);
    staker.deposit_for_testing(sui);
    staker.rebalance_for_testing(&mut system_state, scenario.ctx());

    let deposit = obligation::create_deposit_for_testing(
        type_name::get<SUI>(), // coin_type
        0, // reserve_array_index
        319178156459500, // deposited_ctoken_amount
        decimal::from_scaled_val(1235756053105912240117095), // market_value
        0, // user_reward_manager_index
        decimal::from_scaled_val(0), // attributed_borrow_value: Decimal,
    );

    let deposit_user_reward = liquidity_mining::create_user_reward_manager_for_testing(
        deposit_reward_manager_id,
        0,
        vector[none()], // rewards
        time * 1000, // last_update_time_ms
    );
    let borrow_user_reward = liquidity_mining::create_user_reward_manager_for_testing(
        borrow_reward_manager_id,
        0,
        vector[none()], // rewards
        time * 1000, // last_update_time_ms
    );

    let obligation = obligation::mock_for_testing<LENDING_MARKET>(
        lending_market_id,
        vector[deposit], // deposits
        vector[], // borrows
        decimal::from_scaled_val(1235756053105912240117095), // deposited_value_usd
        decimal::from_scaled_val(859771545208106778279043), // allowed_borrow_value_usd
        decimal::from_scaled_val(926817039829434180087821), // unhealthy_borrow_value_usd: Decimal,
        decimal::from_scaled_val(0), // super_unhealthy_borrow_value_usd: Decimal, // unused
        decimal::from_scaled_val(0), // unweighted_borrowed_value_usd: Decimal,
        decimal::from_scaled_val(0), // weighted_borrowed_value_usd: Decimal,
        decimal::from_scaled_val(0), // weighted_borrowed_value_upper_bound_usd: Decimal,
        false, // borrowing_isolated_asset
        vector[deposit_user_reward, borrow_user_reward], // user_reward_managers
        decimal::from_scaled_val(0), // bad_debt_usd,
        false, // closable
        scenario.ctx(),
    );

    let mut obligations = object_table::new(scenario.ctx());
    let obligation_id = object::id(&obligation);

    obligations.add(obligation_id, obligation);

    let mut lending_market = lending_market::mock_for_testing(
        vector[sui_reserve],
        obligations,
        @0x0, // fee_receiver
        decimal::from_scaled_val(0), // bad_debt_usd
        decimal::from_scaled_val(0), // bad_debt_limit_usd
        scenario.ctx()
    );

    let lending_market_cap = lending_market::new_lending_market_owner_cap_for_testing<LENDING_MARKET>(
        object::id(&lending_market),
        scenario.ctx(),
    );
    
    let obligation_cap = lending_market::new_obligation_owner_cap_for_testing<LENDING_MARKET>(
        &lending_market,
        obligation_id,
        scenario.ctx(),
    );

    let (mut bank, btokens) = bank::mock_for_testing<LENDING_MARKET, SUI, TEST_BSUI>(
        59298460526863, // funds_available
        1000000000, // min_token_block_size
        382510546619429, // btoken_supply_val
        319178156459500, // ctokens
        7500, // target_utilisation_bps
        500, // utilisation_buffer_bps
        0, // reserve_array_index
        obligation_cap,
        scenario.ctx()
    );

    scenario.next_tx(@0x0);

    bank.rebalance(&mut lending_market, &clock, scenario.ctx());
  
    destroy(system_state);
    destroy(clock);
    destroy(bank);
    destroy(btokens);
    destroy(lending_market);
    destroy(lending_market_cap);
    destroy(scenario);
}