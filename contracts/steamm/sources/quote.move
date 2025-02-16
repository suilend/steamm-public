/// Module for informative structs which provide the input/outputs of a given quotation.
module steamm::quote;

public use fun steamm::pool::swap_inner as SwapQuote.swap_inner;

public struct SwapQuote has drop, store, copy {
    amount_in: u64,
    amount_out: u64,
    output_fees: SwapFee,
    a2b: bool,
}

public struct SwapFee has copy, drop, store {
    protocol_fees: u64,
    pool_fees: u64,
}

public struct DepositQuote has copy, drop, store {
    initial_deposit: bool,
    deposit_a: u64,
    deposit_b: u64,
    mint_lp: u64,
}

public struct RedeemQuote has copy, drop, store {
    withdraw_a: u64,
    withdraw_b: u64,
    burn_lp: u64,
}

public fun quote(
    amount_in: u64,
    amount_out: u64,
    protocol_fees: u64,
    pool_fees: u64,
    a2b: bool,
): SwapQuote {
    SwapQuote {
        amount_in,
        amount_out,
        output_fees: SwapFee {
            protocol_fees,
            pool_fees,
        },
        a2b,
    }
}

public fun deposit_quote(
    initial_deposit: bool,
    deposit_a: u64,
    deposit_b: u64,
    mint_lp: u64,
): DepositQuote {
    DepositQuote {
        initial_deposit,
        deposit_a,
        deposit_b,
        mint_lp,
    }
}

public fun redeem_quote(
    withdraw_a: u64,
    withdraw_b: u64,
    burn_lp: u64,
): RedeemQuote {
    RedeemQuote {
        withdraw_a,
        withdraw_b,
        burn_lp,
    }
}

// ===== Package Methods =====

public(package) fun add_extra_fees(swap_quote: &mut SwapQuote, protocol_fees: u64, pool_fees: u64) {
    swap_quote.output_fees.protocol_fees = swap_quote.output_fees.protocol_fees + protocol_fees;
    swap_quote.output_fees.pool_fees = swap_quote.output_fees.pool_fees + pool_fees;
}

// ===== Public View Methods =====

public fun protocol_fees(swap_fee: &SwapFee): u64 { swap_fee.protocol_fees }

public fun pool_fees(swap_fee: &SwapFee): u64 { swap_fee.pool_fees }

public fun amount_in(swap_quote: &SwapQuote): u64 { swap_quote.amount_in }

public fun amount_out(swap_quote: &SwapQuote): u64 { swap_quote.amount_out }

public fun a2b(swap_quote: &SwapQuote): bool { swap_quote.a2b }

public fun amount_out_net(swap_quote: &SwapQuote): u64 {
    swap_quote.amount_out - swap_quote.output_fees.protocol_fees - swap_quote.output_fees.pool_fees
}

public fun amount_out_net_of_protocol_fees(swap_quote: &SwapQuote): u64 {
    swap_quote.amount_out - swap_quote.output_fees.protocol_fees
}

public fun amount_out_net_of_pool_fees(swap_quote: &SwapQuote): u64 {
    swap_quote.amount_out - swap_quote.output_fees.pool_fees
}

public fun output_fees(swap_quote: &SwapQuote): &SwapFee { &swap_quote.output_fees }

public fun initial_deposit(deposit_quote: &DepositQuote): bool { deposit_quote.initial_deposit }

public fun deposit_a(deposit_quote: &DepositQuote): u64 { deposit_quote.deposit_a }

public fun deposit_b(deposit_quote: &DepositQuote): u64 { deposit_quote.deposit_b }

public fun mint_lp(deposit_quote: &DepositQuote): u64 { deposit_quote.mint_lp }

public fun withdraw_a(redeem_quote: &RedeemQuote): u64 { redeem_quote.withdraw_a }

public fun withdraw_b(redeem_quote: &RedeemQuote): u64 { redeem_quote.withdraw_b }

public fun burn_lp(redeem_quote: &RedeemQuote): u64 { redeem_quote.burn_lp }

#[test_only]
public(package) fun quote_for_testing(
    amount_in: u64,
    amount_out: u64,
    protocol_fees: u64,
    pool_fees: u64,
    a2b: bool,
): SwapQuote {
    SwapQuote {
        amount_in,
        amount_out,
        // input_fees,
        output_fees: SwapFee {
            protocol_fees: protocol_fees,
            pool_fees: pool_fees,
        },
        a2b,
    }
}
