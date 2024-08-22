module slamm::fees {
    use sui::balance::{Self, Balance};

    public use fun slamm::fees::fee_ratio_ as FeeConfig.fee_ratio;

    public struct Fees<phantom A, phantom B> has store {
        config: FeeConfig,
        fee_a: Balance<A>,
        fee_b: Balance<B>,
    }

    public struct FeeConfig has store, copy, drop {
        fee_numerator: u64,
        fee_denominator: u64,
        min_fee: u64,
    }

    // ===== Package Functions =====

    public(package) fun new<A, B>(
        fee_numerator: u64,
        fee_denominator: u64,
        min_fee: u64,
    ): Fees<A, B> {

        Fees {
            config: FeeConfig {
                fee_numerator,
                fee_denominator,
                min_fee,
            },
            fee_a: balance::zero(),
            fee_b: balance::zero(),
        }
    }
    
    public(package) fun new_config(
        fee_numerator: u64,
        fee_denominator: u64,
        min_fee: u64,
    ): FeeConfig {
        FeeConfig {
            fee_numerator,
            fee_denominator,
            min_fee,
        }
    }
    
    public fun fee_ratio<A, B>(
        self: &Fees<A, B>,
    ): (u64, u64) {
        (self.config.fee_numerator, self.config.fee_denominator)
    }
    
    public fun fee_ratio_(
        self: &FeeConfig,
    ): (u64, u64) {
        (self.fee_numerator, self.fee_denominator)
    }
    
    public(package) fun withdraw<A, B>(
        self: &mut Fees<A, B>,
    ): (Balance<A>, Balance<B>) {

        let (bal_a, bal_b) = (self.fee_a.value(), self.fee_b.value());
        (
            self.fee_a.split(bal_a),
            self.fee_b.split(bal_b)
        )
    }

    public(package) fun balances_mut<A, B>(
        self: &mut Fees<A, B>,
    ): (&mut Balance<A>, &mut Balance<B>) {
        (
            &mut self.fee_a,
            &mut self.fee_b,
        )
    }

    public(package) fun set_config<A, B>(
        self: &mut Fees<A, B>,
        fee_numerator: u64,
        fee_denominator: u64,
        min_fee: u64,
    ) {
        self.config = new_config(fee_numerator, fee_denominator, min_fee)
    }

    // ===== View Functions =====

    public fun balances<A, B>(
        self: &Fees<A, B>,
    ): (&Balance<A>, &Balance<B>) {
        (
            &self.fee_a,
            &self.fee_b,
        )
    }
    
    public fun config<A, B>(self: &Fees<A, B>): &FeeConfig { &self.config }
    public fun fee_numerator(self: &FeeConfig): u64 { self.fee_numerator }
    public fun fee_denominator(self: &FeeConfig): u64 { self.fee_denominator }
    public fun min_fee(self: &FeeConfig): u64 { self.min_fee }
    public fun fee_a<A, B>(self: &Fees<A, B>,): &Balance<A> { &self.fee_a }
    public fun fee_b<A, B>(self: &Fees<A, B>,): &Balance<B> { &self.fee_b }

    // ===== Test-Only =====
    
    #[test_only]
    public(package) fun config_mut<A, B>(self: &mut Fees<A, B>): &mut FeeConfig { &mut self.config }
    #[test_only]
    public(package) fun fee_numerator_mut(self: &mut FeeConfig): &mut u64 { &mut self.fee_numerator }
    #[test_only]
    public(package) fun min_fee_mut(self: &mut FeeConfig): &mut u64 { &mut self.min_fee }
}
