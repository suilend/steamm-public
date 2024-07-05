#[test_only]
module slamm::test_utils {
    use slamm::cpmm::{Self, State as CpmmState, Hook as CpmmHook};
    use slamm::registry;
    use slamm::pool::{Pool};
    use sui::test_utils::destroy;
    use sui::test_scenario::{Self, ctx};
    use sui::balance;
    use sui::sui::SUI;

    public struct PoolWit has drop {}
    public struct COIN has drop {}

    #[test_only]
    public fun new_for_testing(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        swap_fee_bps: u64,
    ): Pool<SUI, COIN, CpmmHook<PoolWit>, CpmmState> {
        let mut scenario = test_scenario::begin(@0x0);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<SUI, COIN, PoolWit>(
            PoolWit {},
            &mut registry,
            swap_fee_bps,
            ctx,
        );

        pool.reserve_a_mut_for_testing().join(balance::create_for_testing(reserve_a));
        pool.reserve_b_mut_for_testing().join(balance::create_for_testing(reserve_b));
        let lp = pool.lp_supply_mut_for_testing().increase_supply(lp_supply);

        destroy(registry);
        destroy(pool_cap);
        destroy(lp);

        test_scenario::end(scenario);

        pool
    }
}
