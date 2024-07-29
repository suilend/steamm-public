#[test_only]
module slamm::test_utils {
    use slamm::cpmm::{Self, State as CpmmState, Hook as CpmmHook};
    use slamm::registry;
    use slamm::bank::{Self, Bank};
    use slamm::pool::{Pool};
    use sui::test_utils::destroy;
    use sui::clock::Clock;
    use sui::test_scenario::{Self, ctx, Scenario};
    use sui::sui::SUI;
    use sui::bag::{Self, Bag};
    use std::type_name;
    use suilend::test_usdc::{TEST_USDC};
    use suilend::test_sui::{TEST_SUI};
    use suilend::lending_market;
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price_feed;
    use pyth::price_identifier;
    use pyth::price;
    use pyth::i64;

    public struct PoolWit has drop {}
    public struct COIN has drop {}

    #[test_only]
    public fun reserve_args(scenario: &mut Scenario): Bag {
        let mut bag = bag::new(test_scenario::ctx(scenario));
        bag::add(
            &mut bag, 
            type_name::get<TEST_USDC>(), 
            lending_market::new_args(100 * 1_000_000),
        );
            
        bag::add(
            &mut bag, 
            type_name::get<TEST_SUI>(), 
            lending_market::new_args(100 * 1_000_000),
        );

        bag
    }
    
    
    #[test_only]
    public fun new_for_testing(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        swap_fee_bps: u64,
    ): (Pool<SUI, COIN, CpmmHook<PoolWit>, CpmmState>, Bank<SUI>, Bank<COIN>) {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<SUI, COIN, PoolWit>(
            PoolWit {},
            &mut registry,
            swap_fee_bps,
            ctx,
        );

        let mut bank_a = bank::create_bank<SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<COIN>(&mut registry, ctx);

        pool.mut_reserve_a(&mut bank_a, reserve_a, true);
        pool.mut_reserve_b(&mut bank_b, reserve_b, true);
        let lp = pool.lp_supply_mut_for_testing().increase_supply(lp_supply);

        destroy(registry);
        destroy(pool_cap);
        destroy(lp);

        test_scenario::end(scenario);

        (pool, bank_a, bank_b)
    }

    #[test_only]
    public fun get_price_info(
        idx: u8,
        price_: u64,
        exponent: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceInfoObject {
        let mut v = vector::empty<u8>();
        vector::push_back(&mut v, idx);

        let mut i = 1;
        while (i < 32) {
            vector::push_back(&mut v, 0);
            i = i + 1;
        };

        let price_info_obj = price_info::new_price_info_object_for_testing(
            price_info::new_price_info(
                0,
                0,
                price_feed::new(
                    price_identifier::from_byte_vec(v),
                    price::new(
                        i64::new(price_, false),
                        0,
                        i64::new(exponent, false),
                        clock.timestamp_ms(),
                    ),
                    price::new(
                        i64::new(price_, false),
                        0,
                        i64::new(exponent, false),
                        clock.timestamp_ms(),
                    )
                )
            ),
            ctx
        );

        price_info_obj
    }
    
    #[test_only]
    public fun zero_price_info(
        idx: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceInfoObject {
        let mut v = vector::empty<u8>();
        vector::push_back(&mut v, idx);

        let mut i = 1;
        while (i < 32) {
            vector::push_back(&mut v, 0);
            i = i + 1;
        };

        let price_info_obj = price_info::new_price_info_object_for_testing(
            price_info::new_price_info(
                0,
                0,
                price_feed::new(
                    price_identifier::from_byte_vec(v),
                    price::new(
                        i64::new(0, false),
                        0,
                        i64::new(0, false),
                        clock.timestamp_ms(),
                    ),
                    price::new(
                        i64::new(0, false),
                        0,
                        i64::new(0, false),
                        clock.timestamp_ms(),
                    )
                )
            ),
            ctx
        );

        price_info_obj
    }
}
