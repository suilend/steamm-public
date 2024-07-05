module slamm::math {
    const MAX_U64: u128 = 18_446_744_073_709_551_615u128;

    const EMathOverflow: u64 = 0;
    const EDivideByZer0: u64 = 1;

    public fun safe_mul_div_u64(x: u64, y: u64, z: u64): u64 {
        assert!(z > 0, EDivideByZer0);
        let res = (x as u128) * (y as u128) / (z as u128);
        assert!(res <= MAX_U64, EMathOverflow);
        res as u64
    }
    
    public fun safe_compare_mul_u64(a1: u64, b1: u64, a2: u64, b2: u64): bool {
        let left = (a1 as u128) * (b1 as u128);
        let right = (a2 as u128) * (b2 as u128);
        left >= right
    }
}