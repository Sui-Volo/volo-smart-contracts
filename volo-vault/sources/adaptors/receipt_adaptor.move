module volo_vault::receipt_adaptor;

use std::ascii::String;
use std::type_name;
use sui::clock::Clock;
use volo_vault::receipt::Receipt;
use volo_vault::vault::Vault;
use volo_vault::vault_oracle::{Self, OracleConfig};
use volo_vault::vault_utils;

const PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 3;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 5;

// const ERR_NO_SELF_VAULT: u64 = 1_001;

// * @dev No self receipt as defi asset (value overlap)
public fun update_receipt_value<PrincipalCoinType, PrincipalCoinTypeB>(
    vault: &mut Vault<PrincipalCoinType>,
    receipt_vault: &Vault<PrincipalCoinTypeB>,
    config: &OracleConfig,
    clock: &Clock,
    asset_type: String,
) {
    // Actually it seems no need to check this
    // "vault" and "receipt_vault" can not be passed in with the same vault object
    // assert!(
    //     type_name::get<PrincipalCoinType>() != type_name::get<PrincipalCoinTypeB>(),
    //     ERR_NO_SELF_VAULT,
    // );
    receipt_vault.assert_normal();

    let receipt = vault.get_defi_asset_inner<PrincipalCoinType, Receipt>(asset_type);

    let usd_value = get_receipt_value(receipt_vault, config, receipt, clock);

    vault.finish_update_asset_value(asset_type, usd_value, clock.timestamp_ms());
}

// * @dev Get receipt usd value
// *      USD Value = Share Value + Pending Deposit Value + Claimable Principal Value
// *      Share Value will not cover the part that is pending withdraw with auto transfer (avoid operator attack)
#[allow(deprecated_usage)]
public fun get_receipt_value<T>(
    vault: &Vault<T>,
    config: &OracleConfig,
    receipt: &Receipt,
    clock: &Clock,
): u256 {
    vault.assert_vault_receipt_matched(receipt);

    let share_ratio = vault.get_share_ratio(clock);

    let vault_receipt = vault.vault_receipt_info(receipt.receipt_id());
    let mut shares = vault_receipt.shares();

    // If the status is PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS, the share value part is 0
    if (
        vault_receipt.status() == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS || 
        vault_receipt.status() == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS
    ) {
        shares = shares - vault_receipt.pending_withdraw_shares();
    };

    let principal_price = vault_oracle::get_normalized_asset_price(
        config,
        clock,
        type_name::get<T>().into_string(),
    );

    let vault_share_value = vault_utils::mul_d(shares, share_ratio);
    let pending_deposit_value = vault_utils::mul_with_oracle_price(
        vault_receipt.pending_deposit_balance() as u256,
        principal_price,
    );
    let claimable_principal_value = vault_utils::mul_with_oracle_price(
        vault_receipt.claimable_principal() as u256,
        principal_price,
    );

    vault_share_value + pending_deposit_value + claimable_principal_value
}
