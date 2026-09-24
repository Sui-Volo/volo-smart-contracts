#[test_only]
module volo_vault::init_vault;

use lending_core::lending;
use sui::clock::Clock;
use sui::test_scenario::{Self, Scenario};
use volo_vault::curator_position::CuratorConfig;
use volo_vault::init_lending;
use volo_vault::reward_manager;
use volo_vault::vault::{Self, Vault, AdminCap, Operation, OperatorCap};
use volo_vault::vault_manage;
use volo_vault::vault_oracle;

const OWNER: address = @0xa;
#[allow(unused_const)]
const ALICE: address = @0xb;
const BOB: address = @0xc;

#[test_only]
public fun init_vault(s: &mut Scenario, clock: &mut Clock) {
    let owner = s.sender();

    init_lending::init_protocol(s, clock);

    // Init vault
    s.next_tx(owner);
    {
        vault::init_for_testing(s.ctx());
    };

    // Init oracle
    s.next_tx(owner);
    {
        vault_oracle::init_for_testing(s.ctx());
    };

    // Create operator cap and transfer to owner
    s.next_tx(owner);
    {
        let admin_cap = s.take_from_sender<AdminCap>();
        let op_cap = vault::create_operator_cap(s.ctx());
        transfer::public_transfer(op_cap, owner);
        s.return_to_sender(admin_cap);
    };
}

#[test_only]
public fun init_create_vault<PrincipalCoinType>(s: &mut Scenario) {
    let owner = s.sender();

    // Create vault
    s.next_tx(owner);
    {
        let admin_cap = s.take_from_sender<AdminCap>();
        vault::create_vault<PrincipalCoinType>(&admin_cap, s.ctx());
        s.return_to_sender(admin_cap);
    };

    s.next_tx(owner);
    {
        let mut vault = s.take_shared<Vault<PrincipalCoinType>>();
        vault.set_deposit_fee(0);
        vault.set_withdraw_fee(0);
        vault.set_locking_time_for_withdraw(12 * 3600 * 1_000);
        vault.set_locking_time_for_cancel_request(0);
        test_scenario::return_shared(vault);
    };
}

#[test_only]
public fun init_create_reward_manager<PrincipalCoinType>(s: &mut Scenario) {
    let owner = s.sender();

    s.next_tx(owner);
    {
        let mut vault = s.take_shared<Vault<PrincipalCoinType>>();
        reward_manager::create_reward_manager<PrincipalCoinType>(&mut vault, s.ctx());
        test_scenario::return_shared(vault);
    };
}

#[test_only]
public fun init_navi_account_cap<PrincipalCoinType>(
    s: &mut Scenario,
    vault: &mut Vault<PrincipalCoinType>,
) {
    let owner = s.sender();

    s.next_tx(owner);
    {
        let navi_account_cap = lending::create_account(s.ctx());
        vault.add_new_defi_asset(
            0,
            navi_account_cap,
        );
    }
}

#[test_only]
public fun init_single_operator_config_for_owner<PrincipalCoinType>(
    s: &mut Scenario,
    add_field: bool,
) {
    let owner = s.sender();

    s.next_tx(owner);
    {
        let admin_cap = s.take_from_sender<AdminCap>();
        let mut operation = s.take_shared<Operation>();
        let vault = s.take_shared<Vault<PrincipalCoinType>>();
        let operator_cap = s.take_from_sender<OperatorCap>();

        if (add_field) {
            vault_manage::add_dynamic_field_to_operation(&admin_cap, &mut operation, s.ctx());
        };

        vault_manage::set_single_vault_operator(
            &admin_cap,
            &mut operation,
            vault.vault_id(),
            operator_cap.operator_id(),
        );

        test_scenario::return_shared(operation);
        test_scenario::return_shared(vault);
        s.return_to_sender(operator_cap);
        s.return_to_sender(admin_cap);
    };
}

#[test_only]
public fun init_create_curator_cap(curator_address: address, s: &mut Scenario) {
    s.next_tx(OWNER);
    {
        let mut curator_config = s.take_shared<CuratorConfig>();
        let admin_cap = s.take_from_sender<AdminCap>();

        let curator_cap = curator_config.create_curator_cap(&admin_cap, curator_address, s.ctx());
        transfer::public_transfer(curator_cap, OWNER);

        test_scenario::return_shared(curator_config);
        s.return_to_sender(admin_cap);
    };
}
