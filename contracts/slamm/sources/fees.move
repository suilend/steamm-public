module slamm::fees {
    use std::option::{some, none};
    use sui::balance::{Self, Balance};

    public use fun slamm::fees::fee_ratio_ as FeeConfig.fee_ratio;

    public struct Fees<phantom A, phantom B> has store {
        config: FeeConfig,
        fee_a: FeeReserve<A>,
        fee_b: FeeReserve<B>,
    }

    public struct FeeReserve<phantom T> has store {
        balance: Option<Balance<T>>,
        acc_fees: u64,
    }

    public struct FeeConfig has store {
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
    }

    // ===== Package Functions =====

    public(package) fun new<A, B>(
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        with_reserve: bool,
    ): Fees<A, B> {
        let (balance_a, balance_b) = if (with_reserve) {
            (some(balance::zero()), some(balance::zero()))
        } else {
            (none(), none())
        };

        Fees {
            config: FeeConfig {
                swap_fee_numerator,
                swap_fee_denominator,
            },
            fee_a: FeeReserve { balance: balance_a, acc_fees: 0 },
            fee_b: FeeReserve { balance: balance_b, acc_fees: 0 },
        }
    }
    
    // public(package) fun new_(
    //     swap_fee_numerator: u64,
    //     swap_fee_denominator: u64,
    // ): FeeConfig {
    //     FeeConfig {
    //         swap_fee_numerator,
    //         swap_fee_denominator,
    //     }
    // }
    
    public fun fee_ratio<A, B>(
        self: &Fees<A, B>,
    ): (u64, u64) {
        (self.config.swap_fee_numerator, self.config.swap_fee_denominator)
    }
    
    public fun fee_ratio_(
        self: &FeeConfig,
    ): (u64, u64) {
        (self.swap_fee_numerator, self.swap_fee_denominator)
    }
    
    public(package) fun deposit<T>(
        self: &mut FeeReserve<T>,
        balance: Balance<T>,
    ) {
        self.acc_fees = self.acc_fees + balance.value();
        self.balance.borrow_mut().join(balance);
    }
    
    public(package) fun register_fee<T>(
        self: &mut FeeReserve<T>,
        amount: u64,
    ) {
        self.acc_fees = self.acc_fees + amount;
    }
    
    public(package) fun withdraw<A, B>(
        self: &mut Fees<A, B>,
    ): (Balance<A>, Balance<B>) {

        let (bal_a, bal_b) = (self.fee_a.balance.borrow().value(), self.fee_b.balance.borrow().value());
        (
            self.fee_a.balance.borrow_mut().split(bal_a),
            self.fee_b.balance.borrow_mut().split(bal_b)
        )
    }

    public(package) fun fee_b_mut<A, B>(self: &mut Fees<A, B>,): &mut FeeReserve<B> { &mut self.fee_b }
    public(package) fun fee_a_mut<A, B>(self: &mut Fees<A, B>,): &mut FeeReserve<A> { &mut self.fee_a }

    // ===== View Functions =====

    public fun balances<A, B>(
        self: &Fees<A, B>,
    ): (&Balance<A>, &Balance<B>) {
        (
            self.fee_a.balance.borrow(),
            self.fee_b.balance.borrow(),
        )
    }
    
    public fun config<A, B>(self: &Fees<A, B>): &FeeConfig { &self.config }
    public fun swap_fee_numerator(self: &FeeConfig): u64 { self.swap_fee_numerator }
    public fun swap_fee_denominator(self: &FeeConfig): u64 { self.swap_fee_denominator }
    public fun acc_fees<T>(self: &FeeReserve<T>): u64 { self.acc_fees }
    public fun fee_a<A, B>(self: &Fees<A, B>,): &FeeReserve<A> { &self.fee_a }
    public fun fee_b<A, B>(self: &Fees<A, B>,): &FeeReserve<B> { &self.fee_b }

    // ===== Test-Only =====

    #[test_only]
    public(package) fun balances_mut_for_testing<A, B>(
        self: &mut Fees<A, B>,
    ): (&mut Balance<A>, &mut Balance<B>) {
        (
            self.fee_a.balance.borrow_mut(),
            self.fee_b.balance.borrow_mut(),
        )
    }
    
    #[test_only]
    public(package) fun config_mut<A, B>(self: &mut Fees<A, B>): &mut FeeConfig { &mut self.config }
    #[test_only]
    public(package) fun swap_fee_numerator_mut(self: &mut FeeConfig): &mut u64 { &mut self.swap_fee_numerator }
}
