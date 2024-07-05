#[test_only]
module slamm::proptests {
    use slamm::registry;
    use slamm::cpmm::{Self};
    use slamm::test_utils::COIN;
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::random;
    use sui::coin::{Self};
    use sui::test_utils::{destroy};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    
    #[test]
    fun proptest_swap() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let mut registry = registry::init_for_testing(ctx);

        let (mut pool, pool_cap) = cpmm::new<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(e9(100_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(100_000), ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut coin_a,
            &mut coin_b,
            e9(100_000),
            e9(100_000),
            0,
            0,
            ctx,
        );

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut rng = random::new_generator_from_seed_for_testing(vector[0, 1, 2, 3]);

        let mut trades = 1_000;

        while (trades > 0) {
            let amount_in = rng.generate_u64_in_range(1_000, 100_000_000_000_000_000);
            let a2b = if (rng.generate_u8_in_range(1_u8, 2_u8) == 1) { true } else { false };

            let mut coin_a = coin::mint_for_testing<SUI>(if (a2b) { amount_in } else {0}, ctx);
            let mut coin_b = coin::mint_for_testing<COIN>(if (a2b) { 0 } else {amount_in}, ctx);

            let _swap_result = pool.cpmm_swap(
                &mut coin_a,
                &mut coin_b,
                amount_in,
                0,
                a2b,
                ctx,
            );

            destroy(coin_a);
            destroy(coin_b);

            trades = trades - 1;
        };

        destroy(registry);
        destroy(pool);
        destroy(lp_coins);
        destroy(pool_cap);
        test_scenario::end(scenario);
    }
}
