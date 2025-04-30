#[allow(lint(self_transfer))]
module steamm_scripts::pool_script_v2;

use steamm_scripts::script_events::emit_event;
use steamm_scripts::pool_script::destroy_or_transfer;

use oracles::oracles::OraclePriceUpdate;
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use steamm::bank::Bank;
use steamm::quote;
use steamm::pool::Pool;
use steamm::cpmm::CpQuoter;
use steamm::omm::OracleQuoter;
use steamm::omm_v2::OracleQuoterV2;
use steamm::quote::{SwapQuote, DepositQuote, RedeemQuote};
use suilend::lending_market::{LendingMarket};

const ESlippageExceeded: u64 = 0;

// ===== Swap Functions =====

public fun cpmm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut btoken_a, mut btoken_b, btoken_amount_in) = to_btokens(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        a2b,
        amount_in,
        clock,
        ctx,
    );

    pool.cpmm_swap(&mut btoken_a, &mut btoken_b, a2b, btoken_amount_in, 0, ctx);

    cleanup_swap(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        btoken_a,
        btoken_b,
        min_amount_out,
        clock,
        ctx,
    );
}

public fun omm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, OracleQuoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut btoken_a, mut btoken_b, btoken_amount_in) = to_btokens(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        a2b,
        amount_in,
        clock,
        ctx,
    );

    pool.omm_swap(
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        &mut btoken_a,
        &mut btoken_b,
        a2b,
        btoken_amount_in,
        0,
        clock,
        ctx,
    );

    cleanup_swap(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        btoken_a,
        btoken_b,
        min_amount_out,
        clock,
        ctx,
    );
}

public fun omm_v2_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, OracleQuoterV2, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut btoken_a, mut btoken_b, btoken_amount_in) = to_btokens(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        a2b,
        amount_in,
        clock,
        ctx,
    );

    pool.omm_v2_swap(
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        &mut btoken_a,
        &mut btoken_b,
        a2b,
        btoken_amount_in,
        0,
        clock,
        ctx,
    );

    cleanup_swap(
        bank_a,
        bank_b,
        lending_market,
        coin_a,
        coin_b,
        btoken_a,
        btoken_b,
        min_amount_out,
        clock,
        ctx,
    );
}

// ===== Quote Swap Functions =====

public fun quote_cpmm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    a2b: bool,
    amount_in: u64,
    clock: &Clock,
): SwapQuote {
    let amount_in_ = to_btoken_amount_in(
        bank_a,
        bank_b,
        lending_market,
        a2b,
        amount_in,
        clock,
    );

    let btoken_quote = pool.cpmm_quote_swap(amount_in_, a2b);

    to_underlying_quote(
        btoken_quote,
        bank_a,
        bank_b,
        lending_market,
        a2b,
        clock
    )
}


public fun quote_omm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, OracleQuoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    amount_in: u64,
    a2b: bool,
    clock: &Clock,
): SwapQuote {
    let amount_in_ = to_btoken_amount_in(
        bank_a,
        bank_b,
        lending_market,
        a2b,
        amount_in,
        clock,
    );

    let btoken_quote = pool.omm_quote_swap(
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        amount_in_,
        a2b,
        clock,
    );

    to_underlying_quote(
        btoken_quote,
        bank_a,
        bank_b,
        lending_market,
        a2b,
        clock
    )
}

public fun quote_omm_v2_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, OracleQuoterV2, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    amount_in: u64,
    a2b: bool,
    clock: &Clock,
): SwapQuote {
    let amount_in_ = to_btoken_amount_in(
        bank_a,
        bank_b,
        lending_market,
        a2b,
        amount_in,
        clock,
    );

    let btoken_quote = pool.omm_v2_quote_swap(
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        amount_in_,
        a2b,
        clock,
    );

    to_underlying_quote(
        btoken_quote,
        bank_a,
        bank_b,
        lending_market,
        a2b,
        clock
    )
}

// ===== Liquidity Functions =====

public fun deposit_liquidity<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LpType> {
    let mut btoken_a = bank_a.mint_btoken(lending_market, coin_a, max_a, clock, ctx);
    let mut btoken_b = bank_b.mint_btoken(lending_market, coin_b, max_b, clock, ctx);

    let max_ba = btoken_a.value();
    let max_bb = btoken_b.value();

    let (lp_coin, _) = pool.deposit_liquidity(&mut btoken_a, &mut btoken_b, max_ba, max_bb, ctx);

    let remaining_value_ba = btoken_a.value();
    let remaining_value_bb = btoken_b.value();

    if (remaining_value_ba > 0) {
        let coin_a_ = bank_a.burn_btoken(lending_market, &mut btoken_a, remaining_value_ba, clock, ctx);
        coin_a.join(coin_a_);
    };
    if (remaining_value_bb > 0) {
        let coin_b_ = bank_b.burn_btoken(lending_market, &mut btoken_b, remaining_value_bb, clock, ctx);
        coin_b.join(coin_b_);
    };
    
    destroy_or_transfer(btoken_a, ctx);
    destroy_or_transfer(btoken_b, ctx);

    lp_coin
}

public fun redeem_liquidity<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    lp_tokens: Coin<LpType>,
    min_a: u64,
    min_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    let min_ba = bank_a.to_btokens(lending_market, min_a, clock);
    let min_bb = bank_b.to_btokens(lending_market, min_b, clock);

    let (mut btoken_a, mut btoken_b, _) = pool.redeem_liquidity(lp_tokens, min_ba, min_bb, ctx);

    let (btoken_a_amount, btoken_b_amount) = (btoken_a.value(), btoken_b.value());

    let coin_a = bank_a.burn_btoken(lending_market, &mut btoken_a, btoken_a_amount, clock, ctx);
    let coin_b = bank_b.burn_btoken(lending_market, &mut btoken_b, btoken_b_amount, clock, ctx);

    destroy_or_transfer(btoken_a, ctx);
    destroy_or_transfer(btoken_b, ctx);

    (coin_a, coin_b)
}


// ===== Quote Liquidity Functions =====

public fun quote_deposit<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
): DepositQuote {
    let btoken_amount_a = bank_a.to_btokens(lending_market, max_a, clock);
    let btoken_amount_b = bank_b.to_btokens(lending_market, max_b, clock);

    let btoken_quote = pool.quote_deposit(btoken_amount_a, btoken_amount_b);

    let quote = quote::deposit_quote(
        btoken_quote.initial_deposit(),
        bank_a.from_btokens(lending_market, btoken_quote.deposit_a(), clock),
        bank_b.from_btokens(lending_market, btoken_quote.deposit_b(), clock),
        btoken_quote.mint_lp(),
    );

    emit_event(quote);

    quote
}

public fun quote_redeem<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    lp_tokens: u64,
    clock: &Clock,
): RedeemQuote {
    let btoken_quote = pool.quote_redeem(lp_tokens);

    let quote = quote::redeem_quote(
        bank_a.from_btokens(lending_market, btoken_quote.withdraw_a(), clock),
        bank_b.from_btokens(lending_market, btoken_quote.withdraw_b(), clock),
        btoken_quote.burn_lp()
    );

    emit_event(quote);

    quote
}

// ===== Private Functions =====

fun to_btoken_amount_in<P, A, B, BTokenA, BTokenB>(
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    a2b: bool,
    amount_in: u64,
    clock: &Clock,
): u64 {
    if (a2b) {
        bank_a.to_btokens(lending_market, amount_in, clock)
    } else {
        bank_b.to_btokens(lending_market, amount_in, clock)
    }
}

fun to_underlying_quote<P, A, B, BTokenA, BTokenB>(
    swap_quote: SwapQuote,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    a2b: bool,
    clock: &Clock,
): SwapQuote {
    let (amount_in, amount_out, protocol_fees, pool_fees) = if (a2b) {
        (
            bank_a.from_btokens(lending_market, swap_quote.amount_in(), clock),
            bank_b.from_btokens(lending_market, swap_quote.amount_out(), clock),
            bank_b.from_btokens(lending_market, swap_quote.output_fees().protocol_fees(), clock),
            bank_b.from_btokens(lending_market, swap_quote.output_fees().pool_fees(), clock),
        )
    } else {
        (
            bank_b.from_btokens(lending_market, swap_quote.amount_in(), clock),
            bank_a.from_btokens(lending_market, swap_quote.amount_out(), clock),
            bank_a.from_btokens(lending_market, swap_quote.output_fees().protocol_fees(), clock),
            bank_a.from_btokens(lending_market, swap_quote.output_fees().pool_fees(), clock),
        )
    };

    let quote = quote::quote(
        amount_in,
        amount_out,
        protocol_fees,
        pool_fees,
        a2b,
    );

    emit_event(quote);

    quote
}

fun to_btokens<P, A, B, BTokenA, BTokenB>(
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BTokenA>, Coin<BTokenB>, u64) {
    let (btoken_a, btoken_b) = if (a2b) {
        (
            bank_a.mint_btoken(lending_market, coin_a, amount_in, clock, ctx),
            coin::zero(ctx),
        )
    } else {
        (
            coin::zero(ctx),
            bank_b.mint_btoken(lending_market, coin_b, amount_in, clock, ctx)
        )
    };

    let btoken_amount_in = if (a2b) { btoken_a.value() } else { btoken_b.value() };

    (btoken_a, btoken_b, btoken_amount_in)
}

fun cleanup_swap<P, A, B, BTokenA, BTokenB>(
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    mut btoken_a: Coin<BTokenA>,
    mut btoken_b: Coin<BTokenB>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let remaining_value_ba = btoken_a.value();
    let remaining_value_bb = btoken_b.value();

    if (remaining_value_ba > 0) {
        let coin_a_ = bank_a.burn_btoken(lending_market, &mut btoken_a, remaining_value_ba, clock, ctx);
        assert!(coin_a_.value() >= min_amount_out, ESlippageExceeded);
        coin_a.join(coin_a_);
    };
    if (remaining_value_bb > 0) {
        let coin_b_ = bank_b.burn_btoken(lending_market, &mut btoken_b, remaining_value_bb, clock, ctx);
        assert!(coin_b_.value() >= min_amount_out, ESlippageExceeded);
        coin_b.join(coin_b_);
    };

    destroy_or_transfer(btoken_a, ctx);
    destroy_or_transfer(btoken_b, ctx);
}