module volo_vault::vault_manage;

use std::ascii::String;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::event::emit;
use switchboard::aggregator::Aggregator;
use volo_vault::curator_position::{Self, CuratorConfig};
use volo_vault::manager_cap::{Self, ManagerCap};
use volo_vault::reward_manager::{Self, RewardManager};
use volo_vault::vault::{Self, Operation, Vault, AdminCap, OperatorCap};
use volo_vault::vault_oracle::OracleConfig;
use volo_vault::receipt_cancellation;

// @notice This module is used to manage the vault.
//
//         Cap System:
//            - AdminCap: Create new vaults, set key parameters, create remaining caps.
//            - ManagerCap: Set parameters for vaults.
//            - OperatorCap: Operation for its corresponding vault (1 to 1).
//            - CuratorCap: Manage curator positions for a vault.

// ------------------------ Events ------------------------ //

// ^(v1.1 upgrade - new)
public struct ParametersSetByManager has copy, drop {
    vault_id: address,
    manager_cap_id: address,
    deposit_fee: u64,
    withdraw_fee: u64,
    loss_tolerance: u256,
    locking_time_for_withdraw: u64,
    locking_time_for_cancel_request: u64,
}

// ------------------------ Vault Status ------------------------ //

public fun set_vault_enabled<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    enabled: bool,
) {
    vault.set_enabled(enabled);
}

// ^(v1.1 upgrade - new)
public fun set_vault_enabled_by_operator<PrincipalCoinType>(
    operation: &Operation,
    operator_cap: &OperatorCap,
    vault: &mut Vault<PrincipalCoinType>,
    enabled: bool,
) {
    operation.assert_operator_not_freezed(operator_cap);
    operation.assert_single_vault_operator_paired(vault.vault_id(), operator_cap);
    vault.assert_not_during_operation();

    vault.set_enabled(enabled);
}

#[allow(unused_variable)]
public fun upgrade_vault<PrincipalCoinType>(_: &AdminCap, vault: &mut Vault<PrincipalCoinType>) {
    vault.upgrade_vault();
}

public fun upgrade_reward_manager<PrincipalCoinType>(
    _: &AdminCap,
    reward_manager: &mut RewardManager<PrincipalCoinType>,
) {
    reward_manager.upgrade_reward_manager();
}

public fun upgrade_oracle_config(_: &AdminCap, oracle_config: &mut OracleConfig) {
    oracle_config.upgrade_oracle_config();
}

// ^(v1.1 upgrade - new)
public fun upgrade_curator_config(_: &AdminCap, curator_config: &mut CuratorConfig) {
    curator_config.upgrade_curator_config();
}

// ------------------------ Setters ------------------------ //

public fun set_deposit_fee<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    deposit_fee: u64,
) {
    vault.set_deposit_fee(deposit_fee);
}

public fun set_withdraw_fee<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    withdraw_fee: u64,
) {
    vault.set_withdraw_fee(withdraw_fee);
}

public fun set_loss_tolerance<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    loss_tolerance: u256,
) {
    vault.set_loss_tolerance(loss_tolerance);
}

public fun set_locking_time_for_cancel_request<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    locking_time: u64,
) {
    vault.set_locking_time_for_cancel_request(locking_time);
}

public fun set_locking_time_for_withdraw<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    locking_time: u64,
) {
    vault.set_locking_time_for_withdraw(locking_time);
}

// ^(v1.1 upgrade - new)
public fun set_parameters_by_manager<PrincipalCoinType>(
    manager_cap: &ManagerCap,
    vault: &mut Vault<PrincipalCoinType>,
    deposit_fee: u64,
    withdraw_fee: u64,
    loss_tolerance: u256,
    locking_time_for_withdraw: u64,
    locking_time_for_cancel_request: u64,
) {
    vault.set_deposit_fee(deposit_fee);
    vault.set_withdraw_fee(withdraw_fee);
    vault.set_loss_tolerance(loss_tolerance);
    vault.set_locking_time_for_withdraw(locking_time_for_withdraw);
    vault.set_locking_time_for_cancel_request(locking_time_for_cancel_request);

    emit(ParametersSetByManager {
        vault_id: vault.vault_id(),
        manager_cap_id: object::id_address(manager_cap),
        deposit_fee: deposit_fee,
        withdraw_fee: withdraw_fee,
        loss_tolerance: loss_tolerance,
        locking_time_for_withdraw: locking_time_for_withdraw,
        locking_time_for_cancel_request: locking_time_for_cancel_request,
    })
}

// ------------------------ Vault ------------------------ //

//^(v1.1 upgrade - new)
public fun add_dynamic_field_to_vault<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    receipt_cancellation::add_dynamic_field_to_vault(vault, ctx);
}

// ------------------------ Operator ------------------------ //

public fun create_operator_cap(_: &AdminCap, ctx: &mut TxContext): OperatorCap {
    vault::create_operator_cap(ctx)
}

public fun set_operator_freezed(
    _: &AdminCap,
    operation: &mut Operation,
    op_cap_id: address,
    freezed: bool,
) {
    vault::set_operator_freezed(operation, op_cap_id, freezed);
}

// ------------------------ Single Operator ------------------------ //

// ^(v1.1 upgrade - new)
// Only called once after upgrade
public fun add_dynamic_field_to_operation(
    _: &AdminCap,
    operation: &mut Operation,
    ctx: &mut TxContext,
) {
    vault::add_dynamic_field_to_operation(operation, ctx);
}

// ^(v1.1 upgrade - new)
// Add a new operator to manage a specific vault
// A vault can have multiple operators (1 to n)
// An operator can only manage one vault
public fun set_single_vault_operator(
    _: &AdminCap,
    operation: &mut Operation,
    vault_id: address,
    operator: address,
) {
    vault::set_single_vault_operator(operation, vault_id, operator);
}

// ^(v1.1 upgrade - new)
public fun remove_single_vault_operator(
    _: &AdminCap,
    operation: &mut Operation,
    vault_id: address,
    operator: address,
) {
    vault::remove_single_vault_operator(operation, vault_id, operator);
}

// ------------------------ Manager ------------------------ //

// ^(v1.1 upgrade - new)
public fun create_manager_cap(_: &AdminCap, ctx: &mut TxContext): ManagerCap {
    manager_cap::create_manager_cap(ctx)
}

// ------------------------ Curator ------------------------ //

// ^(v1.1 upgrade - new)
public fun init_curator_config(_: &AdminCap, ctx: &mut TxContext) {
    curator_position::init_curator_config(ctx);
}

// ^(v1.1 upgrade - new)
public fun add_curator_cap(
    _: &AdminCap,
    curator_config: &mut CuratorConfig,
    curator_cap_id: address,
) {
    curator_position::add_curator_cap(curator_config, curator_cap_id);
}

// ^(v1.1 upgrade - new)
public fun remove_curator_cap(
    _: &AdminCap,
    curator_config: &mut CuratorConfig,
    curator_cap_id: address,
) {
    curator_position::remove_curator_cap(curator_config, curator_cap_id);
}

// ^(v1.1 upgrade - new)
public fun set_curator_cap_paired_with_position(
    _: &AdminCap,
    curator_config: &mut CuratorConfig,
    curator_position_id: address,
    curator_cap_id: address,
) {
    curator_position::set_curator_cap_paired_with_position(
        curator_config,
        curator_position_id,
        curator_cap_id,
    );
}

// ^(v1.1 upgrade - new)
public fun remove_curator_cap_paired_with_position(
    _: &AdminCap,
    curator_config: &mut CuratorConfig,
    curator_position_id: address,
    curator_cap_id: address,
) {
    curator_position::remove_curator_cap_paired_with_position(
        curator_config,
        curator_position_id,
        curator_cap_id,
    );
}

public fun set_value_submission_min_interval(
    _: &AdminCap,
    curator_config: &mut CuratorConfig,
    value_submission_min_interval: u64,
) {
    curator_position::set_value_submission_min_interval(curator_config, value_submission_min_interval);
}

// ------------------------ Oracle ------------------------ //

public fun add_switchboard_aggregator(
    _: &AdminCap,
    oracle_config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    decimals: u8,
    aggregator: &Aggregator,
) {
    oracle_config.add_switchboard_aggregator(clock, asset_type, decimals, aggregator);
}

public fun remove_switchboard_aggregator(
    _: &AdminCap,
    oracle_config: &mut OracleConfig,
    asset_type: String,
) {
    oracle_config.remove_switchboard_aggregator(asset_type);
}

public fun change_switchboard_aggregator(
    _: &AdminCap,
    oracle_config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    aggregator: &Aggregator,
) {
    oracle_config.change_switchboard_aggregator(clock, asset_type, aggregator);
}

public fun set_update_interval(
    _: &AdminCap,
    oracle_config: &mut OracleConfig,
    update_interval: u64,
) {
    oracle_config.set_update_interval(update_interval);
}

public fun set_dex_slippage(_: &AdminCap, oracle_config: &mut OracleConfig, dex_slippage: u256) {
    oracle_config.set_dex_slippage(dex_slippage);
}

// ------------------------ Fees ------------------------ //

public fun retrieve_deposit_withdraw_fee<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    amount: u64,
): Balance<PrincipalCoinType> {
    vault.retrieve_deposit_withdraw_fee(amount)
}

// !(v1.1 upgrade - deprecated)
// !! --- [DEPRECATED FUNCTION] --- !! //
public fun retrieve_deposit_withdraw_fee_operator<PrincipalCoinType>(
    _: &OperatorCap,
    vault: &mut Vault<PrincipalCoinType>,
    _amount: u64,
): Balance<PrincipalCoinType> {
    // vault.retrieve_deposit_withdraw_fee(amount)
    vault.retrieve_deposit_withdraw_fee(0)
}

// ^(v1.1 upgrade - new)
public fun retrieve_deposit_withdraw_fee_by_operator<PrincipalCoinType>(
    operation: &Operation,
    operator_cap: &OperatorCap,
    vault: &mut Vault<PrincipalCoinType>,
    amount: u64,
): Balance<PrincipalCoinType> {
    vault::assert_operator_not_freezed(operation, operator_cap);
    vault::assert_single_vault_operator_paired(operation, vault.vault_id(), operator_cap);

    vault.retrieve_deposit_withdraw_fee(amount)
}

// ------------------------ Reward Manager ------------------------ //

public fun create_reward_manager<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    reward_manager::create_reward_manager<PrincipalCoinType>(vault, ctx);
}

// ------------------------ Reset Loss Tolerance ------------------------ //

public fun reset_loss_tolerance<PrincipalCoinType>(
    _: &AdminCap,
    vault: &mut Vault<PrincipalCoinType>,
    ctx: &TxContext,
) {
    vault.try_reset_tolerance(true, ctx);
}
