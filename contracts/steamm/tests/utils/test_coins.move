#[test_only]
module steamm::lp_usdc_sui {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use sui::url;

    public struct LP_USDC_SUI has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<LP_USDC_SUI>, 
        CoinMetadata<LP_USDC_SUI>, 
    ) {

        coin::create_currency(
            LP_USDC_SUI {}, 
            9, 
            b"steammLP bUSDC-bSUI",
            b"Steamm LP Token bUSDC-bSUI",
            vector::empty(),
            option::some(url::new_unsafe_from_bytes(b"NONE")),
            ctx
        )
    }
}

#[test_only]
module steamm::lp_sui_usdc {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use sui::url;

    public struct LP_SUI_USDC has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<LP_SUI_USDC>, 
        CoinMetadata<LP_SUI_USDC>, 
    ) {

        coin::create_currency(
            LP_SUI_USDC {}, 
            9, 
            b"steammLP bSUI-bUSDC",
            b"Steamm LP Token bSUI-bUSDC",
            vector::empty(),
            option::some(url::new_unsafe_from_bytes(b"NONE")),
            ctx
        )
    }
}

#[test_only]
module steamm::b_test_usdc {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use sui::url;

    public struct B_TEST_USDC has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<B_TEST_USDC>, 
        CoinMetadata<B_TEST_USDC>, 
    ) {
        coin::create_currency(
            B_TEST_USDC {}, 
            9, 
            b"bTEST_USDC ",
            b"bToken TEST_USDC",
            vector::empty(),
            option::some(url::new_unsafe_from_bytes(b"NONE")),
            ctx
        )
    }
}

#[test_only]
module steamm::b_test_sui {
    use sui::coin::{Self, TreasuryCap, CoinMetadata};
    use sui::url;

    public struct B_TEST_SUI has drop {}

    #[test_only]
    public fun create_currency(ctx: &mut TxContext): (
        TreasuryCap<B_TEST_SUI>, 
        CoinMetadata<B_TEST_SUI>, 
    ) {
        coin::create_currency(
            B_TEST_SUI {}, 
            9, 
            b"bTEST_SUI ",
            b"bToken TEST_SUI",
            vector::empty(),
            option::some(url::new_unsafe_from_bytes(b"NONE")),
            ctx
        )
    }
}