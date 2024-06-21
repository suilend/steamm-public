module slamm::fees {
        use sui::balance::{Self, Balance};

    public struct Fees<phantom A, phantom B> has store {
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        acc_fees_a: u64,
        acc_fees_b: u64,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    }
    
    public fun new<A, B>(
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
    ): Fees<A, B> {
        Fees {
            swap_fee_numerator,
            swap_fee_denominator,
            acc_fees_a: 0,
            acc_fees_b: 0,
            balance_a: balance::zero(),
            balance_b: balance::zero(),
        }
    }
    
    public fun fee_ratio<A, B>(
        self: &Fees<A, B>,
    ): (u64, u64) {
        (self.swap_fee_numerator, self.swap_fee_denominator)
    }
    
    public(package) fun deposit_a<A, B>(
        self: &mut Fees<A, B>,
        balance: Balance<A>,
    ) {
        self.acc_fees_a = self.acc_fees_a + balance.value();
        self.balance_a.join(balance);
    }
    
    public(package) fun deposit_b<A, B>(
        self: &mut Fees<A, B>,
        balance: Balance<B>,
    ) {
        self.acc_fees_b = self.acc_fees_b + balance.value();
        self.balance_b.join(balance);
    }
    
    public(package) fun withdraw<A, B>(
        self: &mut Fees<A, B>,
    ): (Balance<A>, Balance<B>) {

        let (bal_a, bal_b) = (self.balance_a.value(), self.balance_b.value());
        (
            self.balance_a.split(bal_a),
            self.balance_b.split(bal_b)
        )
    }
    
    public fun balances<A, B>(
        self: &Fees<A, B>,
    ): (&Balance<A>, &Balance<B>) {
        (
            &self.balance_a,
            &self.balance_b,
        )
    }
}
