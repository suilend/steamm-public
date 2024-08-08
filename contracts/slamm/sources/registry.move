/// Top level object that tracks all AMM pools. 
/// Ensures that there is only one AMM pool of each type.
module slamm::registry {
    use std::type_name::{Self, TypeName};
    use sui::table::{Self, Table};
    use slamm::global_admin::GlobalAdmin;

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EIncorrectVersion: u64 = 1;
    const EDuplicatedPoolType: u64 = 2;
    const EDuplicatedBankType: u64 = 3;

    public struct Registry has key {
        id: UID,
        version: u16,
        amms: Table<TypeName, ID>,
        banks: Table<TypeName, ID>,
    }

    fun init(ctx: &mut TxContext) {
        let registry = Registry {
            id: object::new(ctx),
            version: CURRENT_VERSION,
            amms: table::new(ctx),
            banks: table::new(ctx),
        };

        transfer::share_object(registry);
    }

    public(package) fun add_amm<AMM: key>(registry: &mut Registry, pool: &AMM) {
        registry.assert_version_and_upgrade();
        
        let amm_type = type_name::get<AMM>();
        assert!(!table::contains(&registry.amms, amm_type), EDuplicatedPoolType);

        table::add(&mut registry.amms, amm_type, object::id(pool));
    }
    
    public(package) fun add_bank<BANK: key>(registry: &mut Registry, bank: &BANK) {
        registry.assert_version_and_upgrade();
        
        let bank_type = type_name::get<BANK>();
        assert!(!table::contains(&registry.banks, bank_type), EDuplicatedBankType);

        table::add(&mut registry.banks, bank_type, object::id(bank));
    }

    // ===== Versioning =====
    
    entry fun migrate_as_global_admin(
        self: &mut Registry,
        _admin: &GlobalAdmin,
    ) {
        migrate_(self);
    }

    fun migrate_(
        self: &mut Registry
    ) {
        assert!(self.version < CURRENT_VERSION, EIncorrectVersion);
        self.version = CURRENT_VERSION;
    }

    fun assert_version(self: &Registry) {
        assert!(self.version == CURRENT_VERSION, EIncorrectVersion);
    }

    fun assert_version_and_upgrade(self: &mut Registry) {
        if (self.version < CURRENT_VERSION) {
            self.version = CURRENT_VERSION;
        };
        assert_version(self);
    }

    // ===== Tests =====

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext): Registry {
        let registry = Registry {
            id: object::new(ctx),
            version: CURRENT_VERSION,
            amms: table::new(ctx),
            banks: table::new(ctx),
        };

        registry
    }

    #[test_only]
    public struct AMM_1 has key { id: UID}
    #[test_only]
    public struct AMM_2 has key { id: UID}

    #[test]
    fun test_happy() {
        use sui::test_utils::{Self};
        use sui::test_scenario::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);

        init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, owner);

        let mut registry = test_scenario::take_shared<Registry>(&scenario);

        let pool_1 = AMM_1 { id : object::new(test_scenario::ctx(&mut scenario)) };
        let pool_2 = AMM_2 { id : object::new(test_scenario::ctx(&mut scenario)) };

        add_amm(
            &mut registry, 
            &pool_1,
        );
        
        add_amm(
            &mut registry, 
            &pool_2,
        );

        test_scenario::return_shared(registry);
        test_utils::destroy(pool_1);
        test_utils::destroy(pool_2);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = EDuplicatedPoolType)]
    fun test_fail_duplicate_lending_market_type() {
        use sui::test_utils::{Self};
        use sui::test_scenario::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);

        init(test_scenario::ctx(&mut scenario));
        test_scenario::next_tx(&mut scenario, owner);

        let mut registry = test_scenario::take_shared<Registry>(&scenario);

        let pool_1 = AMM_1 { id : object::new(test_scenario::ctx(&mut scenario)) };

        add_amm(
            &mut registry, 
            &pool_1,
        );
        
        add_amm(
            &mut registry, 
            &pool_1,
        );

        test_utils::destroy(pool_1);
        test_scenario::return_shared(registry);
        test_scenario::end(scenario);

    }
}