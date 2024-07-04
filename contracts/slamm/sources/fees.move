module slamm::fees {
    use sui::balance::{Self, Balance};

    public use fun slamm::fees::fee_ratio_ as FeeData.fee_ratio;

    public struct Fees<phantom A, phantom B> has store {
        data: FeeData,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    }
    
    public struct FeeData has store {
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        acc_fees_a: u64,
        acc_fees_b: u64,
    }

    public(package) fun new<A, B>(
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
    ): Fees<A, B> {
        Fees {
            data: FeeData {
                swap_fee_numerator,
                swap_fee_denominator,
                acc_fees_a: 0,
                acc_fees_b: 0,
            },
            balance_a: balance::zero(),
            balance_b: balance::zero(),
        }
    }
    
    public(package) fun new_(
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
    ): FeeData {
        FeeData {
            swap_fee_numerator,
            swap_fee_denominator,
            acc_fees_a: 0,
            acc_fees_b: 0,
        }
    }
    
    public fun fee_ratio<A, B>(
        self: &Fees<A, B>,
    ): (u64, u64) {
        (self.data.swap_fee_numerator, self.data.swap_fee_denominator)
    }
    
    public fun fee_ratio_(
        self: &FeeData,
    ): (u64, u64) {
        (self.swap_fee_numerator, self.swap_fee_denominator)
    }
    
    public(package) fun deposit_a<A, B>(
        self: &mut Fees<A, B>,
        balance: Balance<A>,
    ) {
        self.data.acc_fees_a = self.data.acc_fees_a + balance.value();
        self.balance_a.join(balance);
    }
    
    public(package) fun deposit_b<A, B>(
        self: &mut Fees<A, B>,
        balance: Balance<B>,
    ) {
        self.data.acc_fees_b = self.data.acc_fees_b + balance.value();
        self.balance_b.join(balance);
    }
    
    public(package) fun increment_fee_a(
        self: &mut FeeData,
        amount: u64,
    ) {
        self.acc_fees_a = self.acc_fees_a + amount;
    }
    
    public(package) fun increment_fee_b(
        self: &mut FeeData,
        amount: u64,
    ) {
        self.acc_fees_b = self.acc_fees_b + amount;
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

    // ===== Public View Functions =====

    public fun balances<A, B>(
        self: &Fees<A, B>,
    ): (&Balance<A>, &Balance<B>) {
        (
            &self.balance_a,
            &self.balance_b,
        )
    }
    
    public fun fee_data<A, B>(
        self: &Fees<A, B>,
    ): &FeeData {
        &self.data
    }
    
    public fun swap_fee_numerator(self: &FeeData): u64 { self.swap_fee_numerator }
    public fun swap_fee_denominator(self: &FeeData): u64 { self.swap_fee_denominator }
    public fun acc_fees_a(self: &FeeData): u64 { self.acc_fees_a }
    public fun acc_fees_b(self: &FeeData): u64 { self.acc_fees_b }

    // ===== Test-Only =====

    #[test_only]
    public(package) fun balances_mut_for_testing<A, B>(
        self: &mut Fees<A, B>,
    ): (&mut Balance<A>, &mut Balance<B>) {
        (
            &mut self.balance_a,
            &mut self.balance_b,
        )
    }
}
