#[test_only]
module steamm::lp_coin {
    use std::ascii;
    use std::string;
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use std::vector::{Self};
    use std::option::{Self};
    use sui::tx_context::{TxContext};
    use sui::url;

    public struct LP_COUN has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<LP_COUN>, 
        CoinMetadata<LP_COUN>, 
    ) {

        coin::create_currency(
            LP_COUN {}, 
            9, 
            b"steammLP -",
            b"Steamm LP Token ",
            vector::empty(),
            option::some(url::new_unsafe_from_bytes(b"TODO")),
            ctx
        )
    }
}
