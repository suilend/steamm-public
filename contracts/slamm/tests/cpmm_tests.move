#[test_only]
module slamm::slamm_tests {
    // use std::debug::print;
    use slamm::cpmm::{Self, minimum_liquidity};
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const LP_PROVIDER: address = @0x12;
    const TRADER: address = @0x13;

    public struct Wit has drop {}
    public struct COIN has drop {}

    fun e9(amt: u64): u64 {
        1_000_000_000 * amt
    }

    #[test]
    fun test_slamm() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new<SUI, COIN, Wit>(
            Wit {},
            100, // admin fees BPS
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(e9(1_000), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(500_000), ctx);

        let (lp_coins, _) = pool.cpmm_deposit(
            &mut coin_a,
            &mut coin_b,
            e9(1_000),
            e9(500_000),
            0,
            0,
            ctx,
        );

        let (reserve_a, reserve_b) = pool.reserves();
        let reserve_ratio_0 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);

        let (fees_a, fees_b) = pool.admin_fees().balances();

        assert_eq(pool.cpmm_k(), 500000000000000000000000000);
        assert_eq(pool.lp_supply_val(), 22360679774997);
        assert_eq(reserve_a, e9(1_000));
        assert_eq(reserve_b, e9(500_000));
        assert_eq(lp_coins.value(), 22360679774997 - minimum_liquidity());
        assert_eq(fees_a.value(), 0);
        assert_eq(fees_b.value(), 0);

        destroy(coin_a);
        destroy(coin_b);

        // Deposit liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(10), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(e9(10), ctx);

        let (lp_coins_2, _) = pool.cpmm_deposit(
            &mut coin_a,
            &mut coin_b,
            e9(10), // ideal_a
            e9(10), // ideal_b
            0,
            0,
            ctx,
        );

        assert_eq(coin_a.value(), e9(10) - 20_000_000);
        assert_eq(coin_b.value(), 0);
        assert_eq(lp_coins_2.value(), 447213595);

        let (reserve_a, reserve_b) = pool.reserves();
        let reserve_ratio_1 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_1);

        destroy(coin_a);
        destroy(coin_b);

        // Redeem liquidity
        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let (coin_a, coin_b) = pool.cpmm_redeem(
            lp_coins_2,
            0,
            0,
            ctx,
        );

        // Guarantees that roundings are in favour of the pool
        assert_eq(coin_a.value(), 20_000_000 - 1); // -1 for the rounddown
        assert_eq(coin_b.value(), e9(10) - 12); // double rounddown: inital lp tokens minted + redeed

        let (reserve_a, reserve_b) = pool.reserves();
        let reserve_ratio_2 = (reserve_a as u256) * (e9(1) as u256) / (reserve_b as u256);
        assert_eq(reserve_ratio_0, reserve_ratio_2);

        destroy(coin_a);
        destroy(coin_b);

        // Swap
        test_scenario::next_tx(&mut scenario, TRADER);
        let ctx = ctx(&mut scenario);

        let mut coin_a = coin::mint_for_testing<SUI>(e9(200), ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        // public fun swap_request<A, B, Hook: drop, State: store>(
        // self: &mut Pool<A, B, Hook, State>,
        // coin_a: &mut Coin<A>,
        // coin_b: &mut Coin<B>,
        // amount_in: u64,
        // min_amount_out: u64,
        // a2b: bool,

        let swap_request = pool.swap_request(
            &mut coin_a,
            &mut coin_b,
            e9(200),
            0,
            true, // a2b
        );

        let swap_result = pool.cpmm_swap(
            &mut coin_a,
            &mut coin_b,
            swap_request,
            ctx,
        );

        assert_eq(swap_result.a2b(), true);
        assert_eq(swap_result.protocol_fees(), 4000000000);
        assert_eq(swap_result.admin_fees(), 2000000000);
        assert_eq(swap_result.amount_out(), 81239530988208);

        destroy(coin_a);
        destroy(coin_b);
        destroy(pool);
        destroy(lp_coins);
        destroy(pool_cap);
        test_scenario::end(scenario);
    }
}
