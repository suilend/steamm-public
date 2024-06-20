module slamm::global_config {
    const EAmmIsGloballyPaused: u64 = 0;

    public struct GlobalAdmin has key, store {
        id: UID
    }

    public struct GlobalConfig has key, store {
        id: UID,
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        pause: bool,
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            GlobalAdmin{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        transfer::share_object(
            GlobalConfig {
                id: object::new(ctx),
                swap_fee_numerator: 200,
                swap_fee_denominator: 10_000,
                pause: false,
            }
        );
    }
    
    public fun get_fees(
        self: &GlobalConfig,
    ): (u64, u64) {
        (self.swap_fee_numerator, self.swap_fee_denominator)
    }
    
    public fun set_fees(
        _: &GlobalAdmin,
        config: &mut GlobalConfig,
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
    ) {
        assert!(swap_fee_numerator < swap_fee_denominator, 0);
        config.swap_fee_numerator = swap_fee_numerator;
        config.swap_fee_denominator = swap_fee_denominator;
    }
    
    public fun emergency_pause(
        _: &GlobalAdmin,
        config: &mut GlobalConfig,
        pause: bool,
    ) {
        config.pause = pause;
    }

    public fun assert_not_paused(config: &GlobalConfig) {
        assert!(config.pause == false, EAmmIsGloballyPaused);
    }
    
    #[test_only]
    public fun init_for_testing(
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        ctx: &mut TxContext,
    ): (GlobalConfig, GlobalAdmin) {
        let config = GlobalConfig {
            id: object::new(ctx),
            swap_fee_numerator,
            swap_fee_denominator,
            pause: false,
        };

        let admin = GlobalAdmin{
            id: object::new(ctx)
        };

        (config, admin)
    }
}
