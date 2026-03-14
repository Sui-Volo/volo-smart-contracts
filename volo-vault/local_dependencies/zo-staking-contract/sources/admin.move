module zo_staking::admin {
    use sui::table::{Self, Table};

    use zo_staking::event;

    const ERR_ROLE_ALREADY_EXISTS: u64 = 1001;
    const ERR_ROLE_NOT_FOUND: u64 = 1002;
    const ERR_ADDRESS_ALREADY_IN_ROLE: u64 = 1003;
    const ERR_ADDRESS_NOT_FOUND_IN_ROLE: u64 = 1004;

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct AclControl has key, store {
        id: UID,
        roles: Table<vector<u8>, vector<address>>,
    }

    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {id: object::new(ctx)};
        let acl_control = AclControl {
            id: object::new(ctx),
            roles: table::new(ctx),
        };
        event::initialize(
            object::uid_to_inner(&admin_cap.id),
            object::uid_to_inner(&acl_control.id),
        );
        transfer::transfer(admin_cap, tx_context::sender(ctx));
        transfer::public_share_object(acl_control);
    }

    public fun add_role(
        _cap: &AdminCap,
        _acl: &mut AclControl,
        _role_name: vector<u8>,
    ) {
        assert!(
            !table::contains(&_acl.roles, _role_name),
            ERR_ROLE_ALREADY_EXISTS
        );
        table::add(
            &mut _acl.roles,
            _role_name,
            vector::empty<address>()
        );
    }

    public fun add_address_to_role(
        _cap: &AdminCap,
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        _user_address: address,
    ) {
        assert!(
            table::contains(&_acl.roles, _role_name),
            ERR_ROLE_NOT_FOUND
        );
        let addresses = table::borrow_mut(&mut _acl.roles, _role_name);
        assert!(
            !vector::contains(addresses, &_user_address),
            ERR_ADDRESS_ALREADY_IN_ROLE
        );
        vector::push_back(addresses, _user_address);
    }

    public fun remove_address_from_role(
        _cap: &AdminCap,
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        _user_address: address,
    ) {
        assert!(
            table::contains(&_acl.roles, _role_name),
            ERR_ROLE_NOT_FOUND
        );
        let addresses = table::borrow_mut(&mut _acl.roles, _role_name);
        let (found, index) = vector::index_of(addresses, &_user_address);
        assert!(
            found,
            ERR_ADDRESS_NOT_FOUND_IN_ROLE
        );
        vector::remove(addresses, index);
    }

    public fun has_role(
        _acl: &AclControl,
        _role_name: vector<u8>,
        _user_address: address
    ): bool {
        if (!table::contains(&_acl.roles, _role_name)) {
            return false
        };
        let addresses = table::borrow(&_acl.roles, _role_name);
        vector::contains(addresses, &_user_address)
    }

    #[test_only]
    public fun new_for_testing(ctx: &mut TxContext): (AdminCap, AclControl) {
        let admin_cap = AdminCap {id: object::new(ctx)};
        let acl_control = AclControl {
            id: object::new(ctx),
            roles: table::new(ctx),
        };
        (admin_cap, acl_control)
    }
}
