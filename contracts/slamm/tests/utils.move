#[test_only]
module slamm::test_utils {
    use slamm::cpmm::{Self, State as CpmmState, Hook as CpmmHook};
    use slamm::registry;
    use slamm::bank::{Self, Bank};
    use slamm::pool::{Pool};
    use sui::test_utils::destroy;
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;

    public struct PoolWit has drop {}
    public struct COIN has drop {}

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
}
