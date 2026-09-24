module volo_vault::swap_request;

use std::ascii::String;
use sui::dynamic_field;
use sui::event::emit;
use sui::table::{Self, Table};
use volo_vault::vault::Vault;

public struct WithdrawSwapRequestDropped has copy, drop {
    vault_id: address,
    request_id: u64,
    recipient: address,
    target_asset_type: String,
}

public struct WithdrawSwapRequestDynamicFieldKey has copy, drop, store {}
public struct WithdrawSwapRequestDynamicField has store {
    withdraw_swap_requests: Table<u64, WithdrawSwapRequest>,
}

public struct WithdrawSwapRequest has copy, drop, store {
    vault_id: address,
    request_id: u64,
    recipient: address,
    target_asset_type: String,
    slippage_bps: u64,
}

public(package) fun new_withdraw_swap_request(
    vault_id: address,
    request_id: u64,
    recipient: address,
    target_asset_type: String,
    slippage_bps: u64,
): WithdrawSwapRequest {
    WithdrawSwapRequest {
        vault_id,
        request_id,
        recipient,
        target_asset_type,
        slippage_bps,
    }
}

// ------------- Dynamic Fields ------------- //

public(package) fun add_dynamic_field_withdraw_requests<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    vault.check_version();

    let key = WithdrawSwapRequestDynamicFieldKey {};
    let value = WithdrawSwapRequestDynamicField {
        withdraw_swap_requests: table::new<u64, WithdrawSwapRequest>(ctx),
    };
    dynamic_field::add<WithdrawSwapRequestDynamicFieldKey, WithdrawSwapRequestDynamicField>(
        vault.vault_id_mut(),
        key,
        value,
    );
}

public(package) fun withdraw_swap_requests<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
): &Table<u64, WithdrawSwapRequest> {
    let field = dynamic_field::borrow<
        WithdrawSwapRequestDynamicFieldKey,
        WithdrawSwapRequestDynamicField,
    >(
        vault.vault_uid(),
        WithdrawSwapRequestDynamicFieldKey {},
    );
    return &field.withdraw_swap_requests
}

public(package) fun withdraw_swap_requests_mut<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
): &mut Table<u64, WithdrawSwapRequest> {
    let field = dynamic_field::borrow_mut<
        WithdrawSwapRequestDynamicFieldKey,
        WithdrawSwapRequestDynamicField,
    >(
        vault.vault_id_mut(),
        WithdrawSwapRequestDynamicFieldKey {},
    );
    return &mut field.withdraw_swap_requests
}

public(package) fun delete_withdraw_swap_request<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    request_id: u64,
): WithdrawSwapRequest {
    let field = dynamic_field::borrow_mut<
        WithdrawSwapRequestDynamicFieldKey,
        WithdrawSwapRequestDynamicField,
    >(vault.vault_id_mut(), WithdrawSwapRequestDynamicFieldKey {});
    field.withdraw_swap_requests.remove(request_id)
}

public(package) fun try_delete_withdraw_swap_request<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    request_id: u64,
) {
    let key = WithdrawSwapRequestDynamicFieldKey {};
    if (!dynamic_field::exists(vault.vault_id_mut(), key)) {
        return
    };
    let field = dynamic_field::borrow_mut<
        WithdrawSwapRequestDynamicFieldKey,
        WithdrawSwapRequestDynamicField,
    >(vault.vault_id_mut(), key);
    if (field.withdraw_swap_requests.contains(request_id)) {
        let request = field.withdraw_swap_requests.remove(request_id);

        emit(WithdrawSwapRequestDropped {
            vault_id: request.vault_id,
            request_id: request.request_id,
            recipient: request.recipient,
            target_asset_type: request.target_asset_type,
        });
    };
}

// ------------- Getters ------------- //

public fun contains_withdraw_swap_request<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
    request_id: u64,
): bool {
    dynamic_field::exists_with_type<
        WithdrawSwapRequestDynamicFieldKey,
        WithdrawSwapRequestDynamicField,
    >(vault.vault_uid(), WithdrawSwapRequestDynamicFieldKey {})
        && withdraw_swap_requests(vault).contains(request_id)
}

public fun withdraw_swap_request<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
    request_id: u64,
): WithdrawSwapRequest {
    *withdraw_swap_requests(vault).borrow(request_id)
}

// Get the vault id
public fun vault_id(self: &WithdrawSwapRequest): address {
    self.vault_id
}

// Get the request id
public fun request_id(self: &WithdrawSwapRequest): u64 {
    self.request_id
}

// Get the recipient address
public fun recipient(self: &WithdrawSwapRequest): address {
    self.recipient
}

// Get the target asset type
public fun target_asset_type(self: &WithdrawSwapRequest): String {
    self.target_asset_type
}

// Get the slippage in basis points
public fun slippage_bps(self: &WithdrawSwapRequest): u64 {
    self.slippage_bps
}
