/// Module for informative structs which provide the input/outputs of a given quotation.
module slamm::quote {
    public use fun slamm::pool::as_intent as SwapQuote.as_intent;
    public use fun slamm::quote::swap_input_amount_in_net as SwapInputs.amount_in_net;
    public use fun slamm::quote::swap_input_protocol_fees as SwapInputs.protocol_fees;
    public use fun slamm::quote::swap_input_pool_fees as SwapInputs.pool_fees;
    public use fun slamm::pool::swap_inner as SwapQuote.swap_inner;

    public struct SwapInputs has drop {
        amount_in_net: u64,
        protocol_fees: u64,
        pool_fees: u64,
    }

    public struct SwapQuote has store, drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        pool_fees: u64,
        a2b: bool,
    }

    public struct DepositQuote has store, drop {
        initial_deposit: bool,
        deposit_a: u64,
        deposit_b: u64,
        mint_lp: u64,
    }
    
    public struct RedeemQuote has store, drop {
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64
    }

    // ===== Package Methods =====

    public(package) fun flatten(quote: &SwapQuote): (u64, bool, u64, bool) {
        let (amount_a, a_in, amount_b, b_in) = if (quote.a2b() == true) {
            (quote.amount_in() - quote.protocol_fees(), true, quote.amount_out(), false)
        } else {
            (quote.amount_out(), false, quote.amount_in() - quote.protocol_fees(), true)
        };

        (amount_a, a_in, amount_b, b_in)
    }

    public(package) fun swap_inputs(
        amount_in_net: u64,
        protocol_fees: u64,
        pool_fees: u64,
    ): SwapInputs {
        SwapInputs {
            amount_in_net,
            protocol_fees,
            pool_fees,
        }
    }
    
    public(package) fun swap_quote(
        swap_inputs: SwapInputs,
        amount_out: u64,
        a2b: bool,
    ): SwapQuote {
        SwapQuote {
            amount_in: swap_inputs.amount_in_net + swap_inputs.protocol_fees + swap_inputs.pool_fees,
            amount_out,
            protocol_fees: swap_inputs.protocol_fees,
            pool_fees: swap_inputs.pool_fees,
            a2b,
        }
    }
    
    public(package) fun deposit_quote(
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
    
    public(package) fun redeem_quote(
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64
    ): RedeemQuote {
        RedeemQuote {
            withdraw_a,
            withdraw_b,
            burn_lp,
        }
    }

    // ===== Public View Methods =====

    public fun swap_input_amount_in_net(self: &SwapInputs): u64 { self.amount_in_net }
    public fun swap_input_protocol_fees(self: &SwapInputs): u64 { self.protocol_fees }
    public fun swap_input_pool_fees(self: &SwapInputs): u64 { self.pool_fees }
    
    public fun amount_in(self: &SwapQuote): u64 { self.amount_in }
    public fun amount_in_net(self: &SwapQuote): u64 { self.amount_in - self.protocol_fees - self.pool_fees }
    public fun amount_out(self: &SwapQuote): u64 { self.amount_out }
    public fun protocol_fees(self: &SwapQuote): u64 { self.protocol_fees }
    public fun pool_fees(self: &SwapQuote): u64 { self.pool_fees }
    public fun a2b(self: &SwapQuote): bool { self.a2b }
    
    public fun initial_deposit(self: &DepositQuote): bool { self.initial_deposit }
    public fun deposit_a(self: &DepositQuote): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositQuote): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositQuote): u64 { self.mint_lp }
    
    public fun withdraw_a(self: &RedeemQuote): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemQuote): u64 { self.withdraw_b }
    public fun burn_lp(self: &RedeemQuote): u64 { self.burn_lp }
}
