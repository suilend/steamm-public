// module slamm::rolling_window {
//     // use std::vector::{tabulate};
//     use sui::clock::Clock;
    
//     public struct RollingWindow<T> has store {
//         start_ts: u64,
//         timespan: u64,
//         default_t: T,
//         vec: vector<T>,
//         tail: u64,
//         capacity: u64,
//     }

//     public(package) fun new<T: copy + drop>(
//         capacity: u64,
//         timespan: u64,
//         default_t: T,
//         clock: &Clock,
//     ): RollingWindow<T> {
//         let mut vec = vector::empty();
//         let mut i = capacity;

//         while (i > 0) {
//             vec.push_back(default_t);
//             i = i - 1;
//         };

//         RollingWindow {
//             start_ts: clock.timestamp_ms(),
//             default_t,
//             timespan,
//             tail: 0,
//             vec,
//             capacity,
//         }
//     }

//     public(package) fun crank_window<T>(rw: &mut RollingWindow<T>, clock: &Clock) {
//         let tail_ts = rw.start_ts + (rw.capacity * rw.timespan);
//         let needs_crank = clock.timestamp_ms() > tail_ts;


//         if (!needs_crank) {
//             // no-op
//             return
//         };

//         let time_delta = clock.timestamp_ms() - tail_ts;

//         // if time_delta < timestan then it's one block, else compute how many blocks...
        


//     }
// }