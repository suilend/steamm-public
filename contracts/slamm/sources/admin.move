module slamm::pool_admin {
  // === Structs ===

  // Can be stored in a governance mechanism
  public struct PoolAdmin has key, store {
    id: UID
  }

  // === Public Functions ===

  public fun destroy(self: PoolAdmin) {
    let PoolAdmin { id } = self;
    
    id.delete();
  }

  // === Package Functions ===

  public(package) fun new(ctx: &mut TxContext): PoolAdmin {
    PoolAdmin { id: object::new(ctx) }
  }

  // === View Functions ===

  public fun addy(self: &PoolAdmin): address {
    self.id.to_address()
  }  

  // === Test Functions ===

  #[test_only]
  public fun new_for_testing(ctx: &mut TxContext): PoolAdmin {
    new(ctx)
  }
}