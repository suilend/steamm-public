module steamm::global_admin;

public struct GlobalAdmin has key, store {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        GlobalAdmin {
            id: object::new(ctx),
        },
        tx_context::sender(ctx),
    );
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext): GlobalAdmin {
    GlobalAdmin {
        id: object::new(ctx),
    }
}
