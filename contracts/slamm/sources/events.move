module slamm::events {
    use sui::event;

    public struct Event<T: copy + drop> has copy, drop {
        event: T,
    }

    public(package) fun emit_event<T: copy + drop>(event: T) {
        event::emit(Event { event });
    }
}
