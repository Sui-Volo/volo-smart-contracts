module volo_vault::manager_cap;

use sui::event::emit;

public struct ManagerCap has key, store {
    id: UID,
}

public struct ManagerCapCreated has copy, drop {
    cap_id: address,
}

public(package) fun create_manager_cap(ctx: &mut TxContext): ManagerCap {
    let cap = ManagerCap { id: object::new(ctx) };
    emit(ManagerCapCreated {
        cap_id: object::id_address(&cap),
    });
    cap
}

public fun manager_cap_id(self: &ManagerCap): address {
    self.id.to_address()
}
