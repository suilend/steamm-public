#[test_only]
module steamm::deposit_redeem;

use std::u128::sqrt;
use steamm::b_test_sui::B_TEST_SUI;
use steamm::b_test_usdc::B_TEST_USDC;
use steamm::cpmm::CpQuoter;
use steamm::lp_usdc_sui::LP_USDC_SUI;
use steamm::math as steamm_math;
use steamm::pool::Pool;
use steamm::pool_math::{Self, quote_deposit_test, quote_redeem_test};
use steamm::test_utils;
use sui::test_utils::{destroy, assert_eq};

#[test_only]
fun setup_pool(
    reserve_a: u64,
    reserve_b: u64,
    lp_supply: u64,
    swap_fee_bps: u64,
): (Pool<B_TEST_USDC, B_TEST_SUI, CpQuoter, LP_USDC_SUI>) {
    let (mut pool, bank_a, bank_b) = test_utils::test_setup_cpmm(swap_fee_bps, 0);

    pool.mut_reserve_a(reserve_a, true);
    pool.mut_reserve_b(reserve_b, true);
    let lp = pool.lp_supply_mut_for_testing().increase_supply(lp_supply);

    destroy(lp);
    destroy(bank_a);
    destroy(bank_b);

    pool
}

#[test]
fun test_initial_deposit() {
    let pool = setup_pool(
        0,
        0,
        0,
        0,
    );

    let quote = pool.quote_deposit_impl_test(
        5, // max_base
        5, // max_quote,
    );

    assert_eq(quote.initial_deposit(), true);
    assert_eq(quote.deposit_a(), 5);
    assert_eq(quote.deposit_b(), 5);
    assert_eq(quote.mint_lp(), 5);

    destroy(pool);
}

#[test]
fun test_simple_deposit() {
    let pool = setup_pool(
        5,
        1,
        sqrt(5 as u128) as u64,
        0,
    );

    let quote = pool.quote_deposit_impl_test(
        5, // max_base
        5, // max_quote,
    );

    assert_eq(quote.initial_deposit(), false);
    assert_eq(quote.deposit_a(), 5);
    assert_eq(quote.deposit_b(), 1);
    assert_eq(quote.mint_lp(), 2);

    destroy(pool);
}

#[test]
fun test_simple_redeem() {
    let pool = setup_pool(
        6,
        6,
        6,
        0,
    );

    let quote = pool.quote_redeem_impl_test(
        2, // lp_tokens
        0, // min_a
        0, // min_b
    );

    assert_eq(quote.withdraw_a(), 2);
    assert_eq(quote.withdraw_b(), 2);

    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool_math::ERedeemSlippageAExceeded)]
fun test_fail_min_a_too_high() {
    let pool = setup_pool(
        6,
        6,
        6,
        0,
    );

    let quote = pool.quote_redeem_impl_test(
        2, // lp_tokens
        99_999, // min_a
        0, // min_b
    );

    assert_eq(quote.withdraw_a(), 2);
    assert_eq(quote.withdraw_b(), 2);

    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool_math::ERedeemSlippageBExceeded)]
fun test_fail_min_b_too_high() {
    let pool = setup_pool(
        6,
        6,
        6,
        0,
    );

    let quote = pool.quote_redeem_impl_test(
        2, // lp_tokens
        0, // min_a
        99_999, // min_b
    );

    assert_eq(quote.withdraw_a(), 2);
    assert_eq(quote.withdraw_b(), 2);

    destroy(pool);
}

#[test]
fun test_last_redeem() {
    let pool = setup_pool(
        6,
        6,
        6,
        0,
    );

    let quote = pool.quote_redeem_impl_test(
        6, // lp_tokens
        0, // min_a
        0, // min_b
    );

    assert_eq(quote.withdraw_a(), 6);
    assert_eq(quote.withdraw_b(), 6);

    destroy(pool);
}

#[test]
fun test_deposit_liquidity_inner() {
    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        50_000_000, // reserve_a
        50_000_000, // reserve_b
        1_000_000_000, // lp_supply
        50_000_000, // max_base
        250_000_000, // max_quote,
    );

    assert_eq(delta_a, 50_000_000);
    assert_eq(delta_b, 50_000_000);
    assert_eq(lp_tokens, 1_000_000_000);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        995904078539, // reserve_a
        433683167230, // reserve_b
        1_000_000_000, // lp_supply
        993561515, // max_base
        4685420547, // max_quote,
    );

    assert_eq(delta_a, 993561515);
    assert_eq(delta_b, 432663059);
    assert_eq(lp_tokens, 997647);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        431624541156, // reserve_a
        136587560238, // reserve_b
        1_000_000_000, // lp_supply
        167814009, // max_base
        5776084236, // max_quote,
    );

    assert_eq(delta_a, 167814009);
    assert_eq(delta_b, 53104734);
    assert_eq(lp_tokens, 388796);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        814595492359, // reserve_a
        444814121159, // reserve_b
        1_000_000_000, // lp_supply
        5792262291, // max_base
        6821001626, // max_quote,
    );

    assert_eq(delta_a, 5792262291);
    assert_eq(delta_b, 3162895063);
    assert_eq(lp_tokens, 7110599);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        6330406121, // reserve_a
        45207102784, // reserve_b
        1_000_000_000, // lp_supply
        1432889520, // max_base
        1335572325, // max_quote,
    );

    assert_eq(delta_a, 187021833);
    assert_eq(delta_b, 1335572325);
    assert_eq(lp_tokens, 29543417);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        420297244854,
        316982205287,
        6_606_760_618_411_090,
        4995214965,
        3570130297,
    );

    assert_eq(delta_a, 4733754459);
    assert_eq(delta_b, 3570130297);
    assert_eq(lp_tokens, 74411105277849);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        413062764570,
        603795453491,
        1_121_070_850_572_460,
        1537859755,
        8438693476,
    );

    assert_eq(delta_a, 1537859755);
    assert_eq(delta_b, 2247970062);
    assert_eq(lp_tokens, 4173820279815);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        307217683947,
        761385620952,
        4_042_886_943_071_790,
        3998100768,
        108790920,
    );

    assert_eq(delta_a, 43896935);
    assert_eq(delta_b, 108790920);
    assert_eq(lp_tokens, 577669682601);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        42698336282,
        948435467841,
        2_431_942_296_016_960,
        6236994835,
        8837546234,
    );

    assert_eq(delta_a, 397864203);
    assert_eq(delta_b, 8837546234);
    assert_eq(lp_tokens, 22660901250767);

    let (delta_a, delta_b, lp_tokens) = quote_deposit_test(
        861866936755,
        638476503150,
        244_488_474_179_102,
        886029611,
        7520096624,
    );

    assert_eq(delta_a, 886029611);
    assert_eq(delta_b, 656376366);
    assert_eq(lp_tokens, 251342775123);
}

#[test]
#[expected_failure(abort_code = pool_math::EDepositMaxAParamCantBeZero)]
fun test_fail_max_params_as_zero() {
    let pool = setup_pool(
        5,
        5,
        sqrt(5 as u128) as u64,
        0,
    );

    let _quote = pool.quote_deposit_impl_test(
        0, // max_base
        0, // max_quote,
    );

    destroy(pool);
}

#[test]
#[expected_failure(abort_code = steamm_math::EMathOverflow)]
fun test_fail_deposit_maximally_imbalanced_pool() {
    let pool = setup_pool(
        1,
        5_000_000_000_000_000,
        sqrt(5_000_000_000_000_00 as u128) as u64,
        0,
    );

    let _quote = pool.quote_deposit_impl_test(
        50_000_000, // max_a
        50, // max_b,
    );

    destroy(pool);
}

#[test]
fun test_redeem_liquidity_inner() {
    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        50_000_000, // reserve_a
        50_000_000, // reserve_b
        1_000_000_000, // lp_supply
        542816471, // lp_tokens
        0, // min_base
        0, // min_quote
    );

    assert_eq(base_withdraw, 27140823);
    assert_eq(quote_withdraw, 27140823);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        995904078539,
        433683167230,
        1000000000,
        389391649,
        0,
        0,
    );
    assert_eq(quote_withdraw, 168872603631);
    assert_eq(base_withdraw, 387796731388);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        431624541156,
        136587560238,
        1000000000,
        440552590,
        0,
        0,
    );
    assert_eq(base_withdraw, 190153309513);
    assert_eq(quote_withdraw, 60174003424);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        814595492359,
        444814121159,
        1000000000,
        996613035,
        0,
        0,
    );
    assert_eq(base_withdraw, 811836485937);
    assert_eq(quote_withdraw, 443307551299);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        6330406121,
        45207102784,
        1000000000,
        12810274,
        0,
        0,
    );
    assert_eq(base_withdraw, 81094236);
    assert_eq(quote_withdraw, 579115373);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        420297244854,
        316982205287,
        6606760618411090,
        2045717643009200,
        0,
        0,
    );
    assert_eq(base_withdraw, 130140857035);
    assert_eq(quote_withdraw, 98150383724);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        413062764570,
        603795453491,
        1121070850572460,
        551538827364816,
        0,
        0,
    );
    assert_eq(base_withdraw, 203216551998);
    assert_eq(quote_withdraw, 297052265890);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        307217683947,
        761385620952,
        4042886943071790,
        2217957798004580,
        0,
        0,
    );
    assert_eq(base_withdraw, 168541902702);
    assert_eq(quote_withdraw, 417701805432);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        42698336282,
        948435467841,
        2431942296016960,
        59368562297754,
        0,
        0,
    );
    assert_eq(base_withdraw, 1042351556);
    assert_eq(quote_withdraw, 23153201558);

    let (base_withdraw, quote_withdraw) = quote_redeem_test(
        861866936755,
        638476503150,
        244488474179102,
        129992518389093,
        0,
        0,
    );
    assert_eq(base_withdraw, 458247588158);
    assert_eq(quote_withdraw, 339472725065);
}
