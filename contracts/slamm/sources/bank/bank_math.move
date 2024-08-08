#[allow(lint(share_owned))]
module slamm::bank_math {
    // ===== Errors =====

    const EOutputExceedsTotalBankReserves: u64 = 1;
    const EEmptyBank: u64 = 2;
    
    // Only computes recall if needed, else returns zero
    public(package) fun compute_recall_amount(
        reserve: u64,
        amount: u64,
        lent: u64,
        target_utilisation: u64,
        buffer: u64,
    ): u64 {
        assert_output(reserve, lent, amount);
        
        let needs_recall = if (amount > reserve) { true } else {
            let post_utilisation_ratio = compute_utilisation_rate(reserve - amount, lent) as u64;

            post_utilisation_ratio > target_utilisation + buffer
        };

        if (needs_recall) {
            return compute_recall_with_amount(
                reserve,
                amount,
                lent,
                target_utilisation,
            )
        } else { 0 }
    }
    
    public(package) fun compute_utilisation_rate(
        liquid_reserve: u64,
        lent: u64,
    ): u64 {
        assert!(liquid_reserve + lent > 0, EEmptyBank);
        10_000 - ( (liquid_reserve * 10_000) / (liquid_reserve + lent) )
    }

    // only called when the ratio is above... otherwise fails
    public(package) fun compute_recall(
        reserve: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        compute_recall_with_amount(reserve, 0, lent, target_utilisation)
    }
    

    // (1 - utilisation ratio) * (R + Lent - Out) + (Out * 10_000) - (R * 10_000)
    public(package) fun compute_recall_with_amount(
        reserve: u64,
        output: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        (
            (10_000 - target_utilisation) * (reserve + lent - output) + (output * 10_000) - (reserve * 10_000)
        ) / 10_000
    }
    
    // effective_liquidity > target_liquidity + liquidity_buffer
    // 25% > 20%
    // 5% * total_reserves =
    // (effective_liquidity - target_liquidity) * total_reserves
    // [liquid / (liquid + iliquid) - target] * (liquid + iliquid)
    // liquid - target * (liquid + iliquid)
    public(package) fun compute_lend(
        reserve_t1: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        reserve_t1 - ((10_000 - target_utilisation) * (reserve_t1 + lent) / 10_000)
    }

    public(package) fun assert_output(
        liquid_reserve: u64,
        lent: u64,
        output: u64,
    ) {
        assert!(liquid_reserve + lent >= output, EOutputExceedsTotalBankReserves);
    }

    // ===== Tests =====

    #[test_only]
    use sui::test_utils::assert_eq;
    
    #[test]
    fun test_compute_recall() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_recall(2_000, 8_000, 8_000), 0);
        assert_eq(compute_recall(1_000, 9_000, 8_000), 1000);
        assert_eq(compute_recall(0, 10_000, 8_000), 2000);
    }
    
    #[test]
    fun test_compute_recall_amount() {
        assert_eq(
            compute_recall_amount(2_000, 0, 8_000, 8_000, 500), 0
        );
        
        assert_eq(
            compute_recall_amount(2_000, 1_000, 8_000, 8_000, 500), 800
        );
        
        assert_eq(
            compute_recall_amount(2_000, 2_000, 8_000, 8_000, 500), 1_600
        );
        
        // Does not need recall as it does not change liq. ratio beyond the bands
        assert_eq(
            compute_recall_amount(2_000, 100, 8_000, 8_000, 500), 0
        );
    }
    
    #[test]
    fun test_assert_output_ok() {
        assert_output(1_000, 1_000, 500);
    }
    
    #[test]
    #[expected_failure(abort_code = EOutputExceedsTotalBankReserves)]
    fun test_assert_output_not_ok() {
        assert_output(1_000, 1_000, 5_000);
    }

    #[test]
    fun test_compute_lend() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_lend(2_000, 8_000, 8_000), 0);
        assert_eq(compute_lend(3_000, 8_000, 8_000), 800);
        assert_eq(compute_lend(4_000, 8_000, 8_000), 1600);
    }
    
    #[test]
    fun test_compute_utilisation_rate() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_utilisation_rate(10_000, 0), 0); // 100%
        assert_eq(compute_utilisation_rate(7_000, 3_000), 3_000); // 70%
        assert_eq(compute_utilisation_rate(5_000, 5_000), 5_000); // 50%
        assert_eq(compute_utilisation_rate(3_000, 7_000), 7_000); // 30%
        assert_eq(compute_utilisation_rate(0, 10_000), 10_000); // 0%
    }
}