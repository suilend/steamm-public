/// Top level object that tracks all AMM pools.
/// Ensures that there is only one AMM pool of each type.
module steamm::registry;

use std::type_name::{TypeName, Self};
use sui::vec_set::{Self, VecSet};
use steamm::global_admin::GlobalAdmin;
use steamm::version::{Self, Version};
use sui::bag::{Self, Bag};
use sui::dynamic_field;

public use fun steamm::registry::fee_receivers as FeeReceivers.receivers;
public use fun steamm::registry::fee_weights as FeeReceivers.weights;
public use fun steamm::registry::fee_total_weight as FeeReceivers.total_weight;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;

public struct BankKey has copy, store, drop { lending_market_id: ID, coin_type: TypeName }
public struct PoolKey has copy, store, drop { coin_type_a: TypeName, coin_type_b: TypeName }

// === Dynamic Fields ===

public struct FeeReceiversKey has copy, drop, store {}

/// Determines how are deposit fees and rewards distributed.
public struct FeeReceivers has store {
    receivers: vector<address>,
    weights: vector<u64>,
    total_weight: u64,
}

// ===== Errors =====

const EDuplicatedBankType: u64 = 1;
// Invalid reward receivers configuration
const EInvalidRewardReceivers: u64 = 2;

public struct Registry has key {
    id: UID,
    version: Version,
    banks: Bag,
    pools: Bag,
}

public struct BankData has store {
    bank_id: ID,
    btoken_type: TypeName,
    lending_market_type: TypeName,
}

public struct PoolData has copy, drop, store {
    pool_id: ID,
    quoter_type: TypeName,
    swap_fee_bps: u64,
    lp_token_type: TypeName,
}


fun init(ctx: &mut TxContext) {
    let registry = Registry {
        id: object::new(ctx),
        version: version::new(CURRENT_VERSION),
        banks: bag::new(ctx),
        pools: bag::new(ctx),
    };

    transfer::share_object(registry);
}

// ===== Public Functions =====

/// Admin can configure who can receive fees and rewards that the bank accrues from trading and lending.
public fun set_fee_receivers(
    registry: &mut Registry,
    _: &GlobalAdmin,
    receivers: vector<address>,
    weights: vector<u64>,
) {
    registry.version.assert_version_and_upgrade(CURRENT_VERSION);

    assert!(vector::length(&receivers) == vector::length(&weights), EInvalidRewardReceivers);
    assert!(vector::length(&receivers) > 0, EInvalidRewardReceivers);

    let total_weight = vector::fold!(weights, 0, |acc, weight| acc + weight);
    assert!(total_weight > 0, EInvalidRewardReceivers);

    if (dynamic_field::exists_(&registry.id, FeeReceiversKey {})) {
        let FeeReceivers { .. } = dynamic_field::remove<FeeReceiversKey, FeeReceivers>(
            &mut registry.id,
            FeeReceiversKey {},
        );
    };

    dynamic_field::add(
        &mut registry.id,
        FeeReceiversKey {},
        FeeReceivers { receivers, weights, total_weight },
    );
}


public(package) fun register_pool(
    registry: &mut Registry,
    pool_id: ID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    lp_token_type: TypeName,
    swap_fee_bps: u64,
    quoter_type: TypeName,
) {
    registry.version.assert_version_and_upgrade(CURRENT_VERSION);

    let key = PoolKey {
        coin_type_a,
        coin_type_b,
    };

    if (!registry.pools.contains(key)) {
        registry.pools.add(key, vec_set::empty<PoolData>());
    };

    let pools: &mut VecSet<PoolData> = registry.pools.borrow_mut(key);
    
    pools.insert(PoolData {
        pool_id,
        quoter_type,
        swap_fee_bps,
        lp_token_type,
    });
}

public(package) fun register_bank(
    registry: &mut Registry,
    bank_id: ID,
    coin_type: TypeName,
    btoken_type: TypeName,
    lending_market_id: ID,
    lending_market_type: TypeName,
) {
    registry.version.assert_version_and_upgrade(CURRENT_VERSION);

    let key = BankKey {
        lending_market_id: lending_market_id,
        coin_type: coin_type,
    };

    assert!(!registry.banks.contains(key), EDuplicatedBankType);

    registry.banks.add(key, BankData {
        bank_id,
        btoken_type,
        lending_market_type,
    });
}

// ===== View Functions =====

public(package) fun get_bank_data<T>(registry: &Registry, lending_market_id: ID): &BankData {
    let key = BankKey {
        lending_market_id,
        coin_type: type_name::get<T>(),
    };

    registry.banks.borrow(key)
}

public(package) fun btoken_type(bank_data: &BankData): TypeName {
    bank_data.btoken_type
}

public fun get_fee_receivers(registry: &Registry): &FeeReceivers {
    dynamic_field::borrow(
        &registry.id,
        FeeReceiversKey {},
    )
}

public fun fee_receivers(fee_receivers: &FeeReceivers): &vector<address> {
    &fee_receivers.receivers
}

public fun fee_weights(fee_receivers: &FeeReceivers): &vector<u64> {
    &fee_receivers.weights
}

public fun fee_total_weight(fee_receivers: &FeeReceivers): u64 {
    fee_receivers.total_weight
}

// ===== Versioning =====

entry fun migrate(registry: &mut Registry, _admin: &GlobalAdmin) {
    registry.version.migrate_(CURRENT_VERSION);
}

// ===== Tests =====

#[test_only]
public fun init_for_testing(ctx: &mut TxContext): Registry {
    let registry = Registry {
        id: object::new(ctx),
        version: version::new(CURRENT_VERSION),
        pools: bag::new(ctx),
        banks: bag::new(ctx),
    };

    registry
}
