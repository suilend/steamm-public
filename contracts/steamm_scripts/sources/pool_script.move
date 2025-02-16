#[allow(lint(self_transfer))]
module steamm_scripts::pool_script;

use steamm_scripts::script_events::emit_event;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use steamm::bank::Bank;
use steamm::quote;
use steamm::pool::Pool;
use steamm::cpmm::CpQuoter;
use steamm::quote::{SwapQuote, DepositQuote, RedeemQuote};
use suilend::lending_market::{LendingMarket};

public struct MultiRouteSwapQuote has store, copy, drop {
    amount_in: u64,
    amount_out: u64,
}

public fun deposit_liquidity<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &mut LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LpType> {
    let mut btoken_a = bank_a.mint_btokens(lending_market, coin_a, max_a, clock, ctx);
    let mut btoken_b = bank_b.mint_btokens(lending_market, coin_b, max_b, clock, ctx);

    let max_ba = btoken_a.value();
    let max_bb = btoken_b.value();


    let (lp_coin, _) = pool.deposit_liquidity(&mut btoken_a, &mut btoken_b, max_ba, max_bb, ctx);

    let remaining_value_ba = btoken_a.value();
    let remaining_value_bb = btoken_b.value();

    if (remaining_value_ba > 0) {
        let coin_a_ = bank_a.burn_btokens(lending_market, &mut btoken_a, remaining_value_ba, clock, ctx);
        coin_a.join(coin_a_);
    };
    if (remaining_value_bb > 0) {
        let coin_b_ = bank_b.burn_btokens(lending_market, &mut btoken_b, remaining_value_bb, clock, ctx);
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
    lending_market: &mut LendingMarket<P>,
    lp_tokens: Coin<LpType>,
    min_a: u64,
    min_b: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    let (mut btoken_a, mut btoken_b, _) = pool.redeem_liquidity(lp_tokens, min_a, min_b, ctx);

    let (btoken_a_amount, btoken_b_amount) = (btoken_a.value(), btoken_b.value());

    let coin_a = bank_a.burn_btokens(lending_market, &mut btoken_a, btoken_a_amount, clock, ctx);
    let coin_b = bank_b.burn_btokens(lending_market, &mut btoken_b, btoken_b_amount, clock, ctx);

    destroy_or_transfer(btoken_a, ctx);
    destroy_or_transfer(btoken_b, ctx);

    (coin_a, coin_b)
}

public fun cpmm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &mut Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &mut Bank<P, A, BTokenA>,
    bank_b: &mut Bank<P, B, BTokenB>,
    lending_market: &mut LendingMarket<P>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (mut btoken_a, mut btoken_b) = if (a2b) {
        (
            bank_a.mint_btokens(lending_market, coin_a, amount_in, clock, ctx),
            coin::zero(ctx)
        )
    } else {
        (
            coin::zero(ctx),
            bank_b.mint_btokens(lending_market, coin_b, amount_in, clock, ctx)
        )
    };

    pool.cpmm_swap(&mut btoken_a, &mut btoken_b, a2b, amount_in, min_amount_out, ctx);

    let remaining_value_ba = btoken_a.value();
    let remaining_value_bb = btoken_b.value();

    if (remaining_value_ba > 0) {
        let coin_a_ = bank_a.burn_btokens(lending_market, &mut btoken_a, remaining_value_ba, clock, ctx);
        coin_a.join(coin_a_);
    };
    if (remaining_value_bb > 0) {
        let coin_b_ = bank_b.burn_btokens(lending_market, &mut btoken_b, remaining_value_bb, clock, ctx);
        coin_b.join(coin_b_);
    };

    destroy_or_transfer(btoken_a, ctx);
    destroy_or_transfer(btoken_b, ctx);
}

public fun quote_cpmm_swap<P, A, B, BTokenA, BTokenB, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, CpQuoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &mut LendingMarket<P>,
    a2b: bool,
    amount_in: u64,
    clock: &Clock,
): SwapQuote {
    bank_a.compound_interest_if_any(lending_market, clock);
    bank_b.compound_interest_if_any(lending_market, clock);

    let amount_in_ = if (a2b) {
        bank_a.to_btokens(lending_market, amount_in, clock)
    } else {
        bank_b.to_btokens(lending_market, amount_in, clock)
    };

    let btoken_quote = pool.cpmm_quote_swap(amount_in_, a2b);

    let (amount_in, amount_out, protocol_fees, pool_fees) = if (a2b) {
        (
            bank_a.from_btokens(lending_market, btoken_quote.amount_in(), clock),
            bank_b.from_btokens(lending_market, btoken_quote.amount_out(), clock),
            bank_b.from_btokens(lending_market, btoken_quote.output_fees().protocol_fees(), clock),
            bank_b.from_btokens(lending_market, btoken_quote.output_fees().pool_fees(), clock),
        )
    } else {
        (
            bank_b.from_btokens(lending_market, btoken_quote.amount_in(), clock),
            bank_a.from_btokens(lending_market, btoken_quote.amount_out(), clock),
            bank_a.from_btokens(lending_market, btoken_quote.output_fees().protocol_fees(), clock),
            bank_a.from_btokens(lending_market, btoken_quote.output_fees().pool_fees(), clock),
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

public fun quote_deposit<P, A, B, BTokenA, BTokenB, Quoter: store, LpType: drop>(
    pool: &Pool<BTokenA, BTokenB, Quoter, LpType>,
    bank_a: &Bank<P, A, BTokenA>,
    bank_b: &Bank<P, B, BTokenB>,
    lending_market: &mut LendingMarket<P>,
    max_a: u64,
    max_b: u64,
    clock: &Clock,
): DepositQuote {
    bank_a.compound_interest_if_any(lending_market, clock);
    bank_b.compound_interest_if_any(lending_market, clock);

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
    lending_market: &mut LendingMarket<P>,
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

public fun to_multi_swap_route<P, X, Y, BTokenX, BTokenY>(
    bank_x: &mut Bank<P, X, BTokenX>,
    bank_y: &mut Bank<P, Y, BTokenY>,
    lending_market: &mut LendingMarket<P>,
    x2y: bool,
    amount_in: u64,
    amount_out: u64,
    clock: &Clock,
): MultiRouteSwapQuote {
    bank_x.compound_interest_if_any(lending_market, clock);
    bank_y.compound_interest_if_any(lending_market, clock);

    let (amount_in, amount_out) = if (x2y) {
        (
            bank_x.from_btokens(lending_market, amount_in, clock),
            bank_y.from_btokens(lending_market, amount_out, clock),
        )
    } else {
        (
            bank_y.from_btokens(lending_market, amount_in, clock),
            bank_x.from_btokens(lending_market, amount_out, clock),
        )
    };

    let quote = MultiRouteSwapQuote { amount_in, amount_out };

    emit_event(quote);

    quote
}

public fun destroy_or_transfer<T>(
    token: Coin<T>,
    ctx: &TxContext,
) {
    if (token.value() > 0) {
        transfer::public_transfer(token, ctx.sender());
    } else {
        token.destroy_zero();
    };
}
