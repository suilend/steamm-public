#[test_only]
module slamm::cpmm_offset_tests {
    use slamm::pool::minimum_liquidity;
    use slamm::registry;
    use slamm::bank;
    use slamm::cpmm::{Self, offset};
    use slamm::test_utils::{COIN, reserve_args};
    use sui::test_scenario::{Self, ctx};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use sui::test_utils::{destroy, assert_eq};
    use suilend::lending_market::{Self, LENDING_MARKET};

    const ADMIN: address = @0x10;
    const POOL_CREATOR: address = @0x11;
    const LP_PROVIDER: address = @0x12;

    public struct Wit has drop {}
    public struct Wit2 has drop {}

    #[test]
    fun test_one_sided_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            20,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(0, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );
        
        let (reserve_a, reserve_b) = pool.total_funds();
        assert_eq(reserve_a, 500_000);
        assert_eq(reserve_b, 0);
        assert_eq(pool.cpmm_k(offset(&pool)), 500_000 * 20);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

        destroy(coin_a);
        destroy(coin_b);

        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_one_sided_deposit_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);

        // Init Pool
        test_scenario::next_tx(&mut scenario, POOL_CREATOR);

        let mut registry = registry::init_for_testing(ctx(&mut scenario));
        let (clock, lend_cap, lending_market, prices, bag) = lending_market::setup(reserve_args(&mut scenario), &mut scenario).destruct_state();
        
        let ctx = ctx(&mut scenario);

        let (mut pool, pool_cap) = cpmm::new_with_offset<SUI, COIN, Wit>(
            Wit {},
            &mut registry,
            100, // admin fees BPS
            20,
            ctx,
        );

        let mut coin_a = coin::mint_for_testing<SUI>(500_000, ctx);
        let mut coin_b = coin::mint_for_testing<COIN>(500_000, ctx);

        let mut bank_a = bank::create_bank<LENDING_MARKET, SUI>(&mut registry, ctx);
        let mut bank_b = bank::create_bank<LENDING_MARKET, COIN>(&mut registry, ctx);

        let (lp_coins, _) = pool.deposit_liquidity(
            &mut bank_a,
            &mut bank_b,
            &mut coin_a,
            &mut coin_b,
            500_000,
            0,
            0,
            0,
            ctx,
        );
        
        let (reserve_a, reserve_b) = pool.total_funds();
        assert!(reserve_a == 500_000, 0);
        assert!(reserve_b == 0, 0);
        assert!(pool.cpmm_k(offset(&pool)) == 500000 * 20, 0);
        assert_eq(pool.lp_supply_val(), 500_000);
        assert_eq(lp_coins.value(), 500_000 - minimum_liquidity());

        destroy(coin_a);
        destroy(coin_b);

        test_scenario::next_tx(&mut scenario, LP_PROVIDER);
        let ctx = ctx(&mut scenario);

        let (coin_a, coin_b, redeem_result) = pool.redeem_liquidity(
            &mut bank_a,
            &mut bank_b,
            lp_coins,
            0,
            0,
            ctx,
        );

        assert_eq(redeem_result.burn_lp(), 499990);
        assert_eq(pool.total_funds_a(), 10);
        assert_eq(pool.total_funds_b(), 0);

        destroy(coin_a);
        destroy(coin_b);
        destroy(bank_a);
        destroy(bank_b);
        destroy(registry);
        destroy(pool);
        destroy(pool_cap);
        // destroy(lp_coins);
        destroy(lend_cap);
        destroy(prices);
        destroy(clock);
        destroy(bag);
        destroy(lending_market);
        test_scenario::end(scenario);
    }
}
