#[test_only]
module steamm::test_registry;

use std::type_name::get;
use steamm::registry;
use steamm::b_test_usdc::B_TEST_USDC;
use sui::coin;
use std::option::none;
use steamm::bank::{create_bank};
use steamm::test_utils::{setup_currencies, setup_lending_market};
use sui::test_scenario::{Self, ctx};
use sui::test_utils::destroy;
use suilend::lending_market_tests::LENDING_MARKET;
use suilend::test_usdc::TEST_USDC;

public struct A has drop {}
public struct B has drop {}

public struct B_A has drop {}
public struct B_B has drop {}
public struct LpType has drop {}

public struct B_A2 has drop {}
public struct B_B2 has drop {}
public struct LpType2 has drop {}

public struct Quoter has drop {}
public struct Quoter2 has drop {}
public struct LendingMarket1 has drop {}
public struct LendingMarket2 has drop {}

#[test]
fun test_happy_registry_pool() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let pool_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter>(),
    );

    let pool2_id = object::id_from_address(scenario.ctx().fresh_object_address());
    
    registry.register_pool(
        pool2_id,
        get<B_A2>(),
        get<B_B2>(),
        get<LpType2>(),
        100,
        get<Quoter>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_happy_registry_pools() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let pool_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter>(),
    );


    let pool_id_2 = object::id_from_address(scenario.ctx().fresh_object_address());
    registry.register_pool(
        pool_id_2,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_happy_registry_bank() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let bank_id = object::id_from_address(scenario.ctx().fresh_object_address());
    let lending_market_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_bank(
        bank_id,
        get<A>(),
        get<B_A>(),
        lending_market_id,
        get<LendingMarket1>(),
    );

    let bank2_id = object::id_from_address(scenario.ctx().fresh_object_address());
    let lending_market2_id = object::id_from_address(scenario.ctx().fresh_object_address());
    
    registry.register_bank(
        bank2_id,
        get<A>(),
        get<B_A>(),
        lending_market2_id,
        get<LendingMarket2>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_registry_pool_ok_same_fee_different_quoter() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let pool_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter>(),
    );

    scenario.next_tx(owner);
    
    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter2>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_registry_pool_ok_different_fee_same_quoter() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let pool_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        100,
        get<Quoter>(),
    );

    scenario.next_tx(owner);
    
    registry.register_pool(
        pool_id,
        get<B_A>(),
        get<B_B>(),
        get<LpType>(),
        200,
        get<Quoter>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = registry::EDuplicatedBankType)]
fun test_duplicated_registry_bank() {
    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let mut registry = registry::init_for_testing(test_scenario::ctx(&mut scenario));

    let bank_id = object::id_from_address(scenario.ctx().fresh_object_address());
    let lending_market_id = object::id_from_address(scenario.ctx().fresh_object_address());

    registry.register_bank(
        bank_id,
        get<A>(),
        get<B_A>(),
        lending_market_id,
        get<LendingMarket1>(),
    );

    let bank2_id = object::id_from_address(scenario.ctx().fresh_object_address());
    
    registry.register_bank(
        bank2_id,
        get<A>(),
        get<B_A>(),
        lending_market_id,
        get<LendingMarket1>(),
    );

    destroy(registry);
    test_scenario::end(scenario);
}


#[test]
#[expected_failure(abort_code = registry::EDuplicatedBankType)]
fun test_fail_duplicate_bank_full() {

    let owner = @0x26;
    let mut scenario = test_scenario::begin(owner);

    let (
        meta_usdc,
        meta_sui,
        meta_lp_usdc_sui,
        mut meta_b_usdc,
        meta_b_sui,
        treasury_cap_lp,
        treasury_cap_b_usdc,
        treasury_cap_b_sui,
    ) = setup_currencies(&mut scenario);

    let mut registry = registry::init_for_testing(scenario.ctx());

    // Lending market
    // Create lending market
    let (clock, lend_cap, lending_market, prices, bag) = setup_lending_market(
        none(),
        &mut scenario,
    );

    // Create banks
    let bank_1 = create_bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>(
        &mut registry,
        &meta_usdc,
        &mut meta_b_usdc,
        treasury_cap_b_usdc,
        &lending_market,
        scenario.ctx(),
    );

    let treasury_cap_b_usdc = coin::create_treasury_cap_for_testing(scenario.ctx());
    
    let bank_2 = create_bank<LENDING_MARKET, TEST_USDC, B_TEST_USDC>(
        &mut registry,
        &meta_usdc,
        &mut meta_b_usdc,
        treasury_cap_b_usdc,
        &lending_market,
        scenario.ctx(),
    );

    destroy(registry);
    destroy(meta_lp_usdc_sui);
    destroy(meta_b_sui);
    destroy(meta_b_usdc);
    destroy(meta_sui);
    destroy(meta_usdc);
    destroy(bank_1);
    destroy(bank_2);
    destroy(lending_market);
    destroy(treasury_cap_lp);
    destroy(treasury_cap_b_sui);
    destroy(lend_cap);
    destroy(prices);
    destroy(bag);
    destroy(clock);

    test_scenario::end(scenario);
}
