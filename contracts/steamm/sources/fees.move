module steamm::fees {
    use sui::balance::{Self, Balance};

    public use fun steamm::fees::fee_ratio_ as FeeConfig.fee_ratio;

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
        fees: &Fees<A, B>,
    ): (u64, u64) {
        (fees.config.fee_numerator, fees.config.fee_denominator)
    }
    
    public fun fee_ratio_(
        fee_config: &FeeConfig,
    ): (u64, u64) {
        (fee_config.fee_numerator, fee_config.fee_denominator)
    }
    
    public(package) fun withdraw<A, B>(
        fees: &mut Fees<A, B>,
    ): (Balance<A>, Balance<B>) {

        let (bal_a, bal_b) = (fees.fee_a.value(), fees.fee_b.value());
        (
            fees.fee_a.split(bal_a),
            fees.fee_b.split(bal_b)
        )
    }

    public(package) fun balances_mut<A, B>(
        fees: &mut Fees<A, B>,
    ): (&mut Balance<A>, &mut Balance<B>) {
        (
            &mut fees.fee_a,
            &mut fees.fee_b,
        )
    }

    public(package) fun set_config<A, B>(
        fees: &mut Fees<A, B>,
        fee_numerator: u64,
        fee_denominator: u64,
        min_fee: u64,
    ) {
        fees.config = new_config(fee_numerator, fee_denominator, min_fee)
    }

    // ===== View Functions =====

    public fun balances<A, B>(
        fees: &Fees<A, B>,
    ): (&Balance<A>, &Balance<B>) {
        (
            &fees.fee_a,
            &fees.fee_b,
        )
    }
    
    public fun config<A, B>(fees: &Fees<A, B>): &FeeConfig { &fees.config }
    public fun fee_numerator(fee_config: &FeeConfig): u64 { fee_config.fee_numerator }
    public fun fee_denominator(fee_config: &FeeConfig): u64 { fee_config.fee_denominator }
    public fun min_fee(fee_config: &FeeConfig): u64 { fee_config.min_fee }
    public fun fee_a<A, B>(fees: &Fees<A, B>,): &Balance<A> { &fees.fee_a }
    public fun fee_b<A, B>(fees: &Fees<A, B>,): &Balance<B> { &fees.fee_b }

    // ===== Test-Only =====
    
    #[test_only]
    public(package) fun config_mut<A, B>(fees: &mut Fees<A, B>): &mut FeeConfig { &mut fees.config }
    #[test_only]
    public(package) fun fee_numerator_mut(fee_config: &mut FeeConfig): &mut u64 { &mut fee_config.fee_numerator }
    #[test_only]
    public(package) fun min_fee_mut(fee_config: &mut FeeConfig): &mut u64 { &mut fee_config.min_fee }
}
