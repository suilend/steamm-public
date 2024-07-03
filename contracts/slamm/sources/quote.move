/// Module for informative structs which provide the output of a given quotation.
module slamm::quote {
    public struct SwapQuote has store, drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
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

    public(package) fun swap_quote(
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
    ): SwapQuote {
        SwapQuote {
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
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

    public fun amount_in(self: &SwapQuote): u64 { self.amount_in }
    public fun amount_out(self: &SwapQuote): u64 { self.amount_out }
    public fun protocol_fees(self: &SwapQuote): u64 { self.protocol_fees }
    public fun admin_fees(self: &SwapQuote): u64 { self.admin_fees }
    public fun a2b(self: &SwapQuote): bool { self.a2b }
    
    public fun initial_deposit(self: &DepositQuote): bool { self.initial_deposit }
    public fun deposit_a(self: &DepositQuote): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositQuote): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositQuote): u64 { self.mint_lp }
    
    public fun withdraw_a(self: &RedeemQuote): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemQuote): u64 { self.withdraw_b }
    public fun burn_lp(self: &RedeemQuote): u64 { self.burn_lp }
}
