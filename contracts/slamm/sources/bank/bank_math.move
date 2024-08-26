#[allow(lint(share_owned))]
module slamm::bank_math {
    // ===== Errors =====

    const EOutputExceedsTotalBankReserves: u64 = 1;
    const EEmptyBank: u64 = 2;
    
    // Only computes recall if needed, else returns zero
    public(package) fun compute_recall_for_pending_withdraw(
        funds_available: u64,
        withdraw_amount: u64,
        funds_deployed: u64,
        target_utilisation: u64,
        buffer: u64,
    ): u64 {
        assert_output(funds_available, funds_deployed, withdraw_amount);
        
        let needs_recall = if (withdraw_amount > funds_available) { true } else {
            let post_utilisation_ratio = compute_utilisation_rate(funds_available - withdraw_amount, funds_deployed) as u64;

            post_utilisation_ratio > target_utilisation + buffer
        };

        if (needs_recall) {
            return compute_amount_to_recall(
                funds_available,
                withdraw_amount,
                funds_deployed,
                target_utilisation,
            )
        } else { 0 }
    }
    
    public(package) fun compute_utilisation_rate(
        funds_available: u64,
        funds_deployed: u64,
    ): u64 {
        assert!(funds_available + funds_deployed > 0, EEmptyBank);
        (funds_deployed * 10_000) / (funds_available + funds_deployed)
    }

    // (1 - utilisation ratio) * (R + Lent - Out) + (Out * 10_000) - (R * 10_000)
    // Computes amount to recall
    public(package) fun compute_amount_to_recall(
        funds_available: u64,
        withdraw_amount: u64,
        funds_deployed: u64,
        target_utilisation: u64,
    ): u64 {
        let optimal_funds_deployed = target_utilisation * (funds_available + funds_deployed - withdraw_amount) / 10_000;
        funds_deployed - optimal_funds_deployed
    }
    
    // effective_liquidity > target_liquidity + liquidity_buffer
    // 25% > 20%
    // 5% * total_reserves =
    // (effective_liquidity - target_liquidity) * total_reserves
    // [liquid / (liquid + iliquid) - target] * (liquid + iliquid)
    // liquid - target * (liquid + iliquid)
    // Computes amount to deploy/lend
    public(package) fun compute_amount_to_deploy(
        funds_available: u64,
        funds_deployed: u64,
        target_utilisation: u64,
    ): u64 {
        let optimal_funds_deployed = target_utilisation * (funds_available + funds_deployed) / 10_000;
        optimal_funds_deployed - funds_deployed
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
        assert_eq(compute_amount_to_recall(2_000, 0, 8_000, 8_000), 0);
        assert_eq(compute_amount_to_recall(1_000, 0, 9_000, 8_000), 1000);
        assert_eq(compute_amount_to_recall(0, 0, 10_000, 8_000), 2000);
    }
    
    #[test]
    fun test_compute_recall_amount() {
        assert_eq(
            compute_recall_for_pending_withdraw(2_000, 0, 8_000, 8_000, 500), 0
        );
        
        assert_eq(
            compute_recall_for_pending_withdraw(2_000, 1_000, 8_000, 8_000, 500), 800
        );
        
        assert_eq(
            compute_recall_for_pending_withdraw(2_000, 2_000, 8_000, 8_000, 500), 1_600
        );
        
        // Does not need recall as it does not change liq. ratio beyond the bands
        assert_eq(
            compute_recall_for_pending_withdraw(2_000, 100, 8_000, 8_000, 500), 0
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
        assert_eq(compute_amount_to_deploy(2_000, 8_000, 8_000), 0);
        assert_eq(compute_amount_to_deploy(3_000, 8_000, 8_000), 800);
        assert_eq(compute_amount_to_deploy(4_000, 8_000, 8_000), 1600);
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