module slamm::math {
    const MAX_U64: u128 = 18_446_744_073_709_551_615u128;

    const EMathOverflow: u64 = 0;
    const EDivideByZer0: u64 = 1;

    public(package) fun safe_mul_div(x: u64, y: u64, z: u64): u64 {
        assert!(z > 0, EDivideByZer0);
        let res = (x as u128) * (y as u128) / (z as u128);
        assert!(res <= MAX_U64, EMathOverflow);
        res as u64
    }
    
    public(package) fun safe_mul_div_up(x: u64, y: u64, z: u64): u64 {
        assert!(z > 0, EDivideByZer0);
        let res = std::macros::num_divide_and_round_up!((x as u128) * (y as u128), (z as u128));
        // let res = divide_and_round_up((x as u128) * (y as u128), (z as u128));
        assert!(res <= MAX_U64, EMathOverflow);
        res as u64
    }
    
    public(package) fun safe_compare_mul_u64(a1: u64, b1: u64, a2: u64, b2: u64): bool {
        let left = (a1 as u128) * (b1 as u128);
        let right = (a2 as u128) * (b2 as u128);
        left >= right
    }

    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_safe_mul_div_round() {
        let a = safe_mul_div(300, 1, 7);
        assert_eq(a, 42);

        let b = safe_mul_div_up(300, 1, 7);
        assert_eq(b, 43);
        
        let c = safe_mul_div(100, 2, 50);
        let d = safe_mul_div_up(100, 2, 50);
        
        assert_eq(c, 4);
        assert_eq(c, d);
    }
}