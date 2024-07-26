/// Module for informative structs which provide the input/outputs of a given quotation.
module slamm::quote {
    use std::option::{some, none};

    public use fun slamm::pool::as_intent as SwapQuote.as_intent;
    public use fun slamm::quote::swap_input_amount_in_net as SwapInputs.amount_in_net;
    public use fun slamm::quote::swap_input_protocol_fees as SwapInputs.protocol_fees;
    public use fun slamm::quote::swap_input_pool_fees as SwapInputs.pool_fees;
    public use fun slamm::pool::swap_inner as SwapQuote.swap_inner;
    public use fun slamm::quote::swap_quote_from_input as SwapInputs.to_quote;
    public use fun slamm::quote::swap_quote_from_output as SwapOutputs.to_quote;


    public struct SwapInputs has drop {
        amount_in_net: u64,
        protocol_fees: u64,
        pool_fees: u64,
    }
    
    public struct SwapOutputs has drop {
        amount_out_net: u64,
        protocol_fees: u64,
        pool_fees: u64,
    }

    public struct SwapQuote has store, drop {
        amount_in: u64,
        amount_out: u64,
        input_fees: Option<SwapFee>,
        output_fees: Option<SwapFee>,
        a2b: bool,
    }

    public struct SwapFee has store, drop, copy {
        protocol_fees: u64,
        pool_fees: u64,
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
    
    public(package) fun swap_outputs(
        amount_out_net: u64,
        protocol_fees: u64,
        pool_fees: u64,
    ): SwapOutputs {
        SwapOutputs {
            amount_out_net,
            protocol_fees,
            pool_fees,
        }
    }
    
    public(package) fun swap_quote_from_input(
        swap_inputs: SwapInputs,
        amount_out: u64,
        a2b: bool,
    ): SwapQuote {
        SwapQuote {
            amount_in: swap_inputs.amount_in_net + swap_inputs.protocol_fees + swap_inputs.pool_fees,
            amount_out,
            input_fees: some(SwapFee {
                protocol_fees: swap_inputs.protocol_fees,
                pool_fees: swap_inputs.pool_fees,
            }),
            output_fees: none(),
            a2b,
        }
    }

    public(package) fun swap_quote_from_output(
        swap_outputs: SwapOutputs,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        SwapQuote {
            amount_in: amount_in,
            amount_out: swap_outputs.amount_out_net + swap_outputs.protocol_fees + swap_outputs.pool_fees,
            input_fees: none(),
            output_fees: some(SwapFee {
                protocol_fees: swap_outputs.protocol_fees,
                pool_fees: swap_outputs.pool_fees,
            }),
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

    // public(package) fun input_fees_mut(self: &mut SwapQuote): &mut SwapFee { &mut self.input_fees }
    // public(package) fun set_output_fees(
    //     self: &mut SwapQuote,
    //     protocol_fees: u64,
    //     pool_fees: u64
    // ) {
    //     assert!(protocol_fees + pool_fees < self.amount_out(), 0);

    //     self.output_fees.fill(SwapFee { protocol_fees, pool_fees });
    // }
    
    public(package) fun add_protocol_fees(self: &SwapFee): u64 { self.protocol_fees }
    public(package) fun add_pool_fees(self: &SwapFee): u64 { self.pool_fees }
    

    // ===== Public View Methods =====

    public fun protocol_fees(self: &SwapFee): u64 { self.protocol_fees }
    public fun pool_fees(self: &SwapFee): u64 { self.pool_fees }

    public fun swap_input_amount_in_net(self: &SwapInputs): u64 { self.amount_in_net }
    public fun swap_input_protocol_fees(self: &SwapInputs): u64 { self.protocol_fees }
    public fun swap_input_pool_fees(self: &SwapInputs): u64 { self.pool_fees }
    
    // public fun output_fees(self: &SwapQuote): &Option<SwapFee> { &self.output_fees }


    public fun amount_in(self: &SwapQuote): u64 { self.amount_in }
    public fun amount_out(self: &SwapQuote): u64 { self.amount_out }
    public fun a2b(self: &SwapQuote): bool { self.a2b }
    
    public fun amount_in_net(self: &SwapQuote): u64 {
        let (protocol_fees, pool_fees) = if (self.input_fees.is_some()) {
            (self.input_fees.borrow().protocol_fees, self.input_fees.borrow().pool_fees)
        } else {
            (0, 0)
        };

        self.amount_in - protocol_fees - pool_fees
    }
    
    public fun amount_out_net(self: &SwapQuote): u64 {
        let (protocol_fees, pool_fees) = if (self.output_fees.is_some()) {
            (self.output_fees.borrow().protocol_fees, self.output_fees.borrow().pool_fees)
        } else {
            (0, 0)
        };

        self.amount_out - protocol_fees - pool_fees
    }

    public fun input_fees(self: &SwapQuote): &Option<SwapFee> { &self.input_fees }
    public fun output_fees(self: &SwapQuote): &Option<SwapFee> { &self.output_fees }
    
    public fun initial_deposit(self: &DepositQuote): bool { self.initial_deposit }
    public fun deposit_a(self: &DepositQuote): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositQuote): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositQuote): u64 { self.mint_lp }
    
    public fun withdraw_a(self: &RedeemQuote): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemQuote): u64 { self.withdraw_b }
    public fun burn_lp(self: &RedeemQuote): u64 { self.burn_lp }
}
