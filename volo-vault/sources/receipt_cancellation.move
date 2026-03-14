module volo_vault::receipt_cancellation;

use sui::dynamic_field;
use sui::table::{Self, Table};
use volo_vault::receipt::Receipt;
use volo_vault::vault::Vault;

const ERR_RECEIPT_CAN_BE_CANCELLED: u64 = 6_001;
const ERR_RECEIPT_CANNOT_BE_CANCELLED: u64 = 6_002;

public struct ReceiptCanBeCancelledFieldKey has copy, drop, store {}

public struct ReceiptCanBeCancelled has store {
    can_be_cancelled: bool,
}

public struct VaultReceiptCanBeCancelled has store {
    receipt_can_be_cancelled: Table<address, bool>,
}

// ------------------  Receipt Dynamic Field  ------------------//

public fun add_dynamic_field_to_receipt(receipt: &mut Receipt) {
    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let dynamic_field_value = ReceiptCanBeCancelled {
        can_be_cancelled: true,
    };

    dynamic_field::add(receipt.receipt_id_mut(), dynamic_field_key, dynamic_field_value);
}

public fun set_receipt_can_not_be_cancelled<PrincipalCoinType>(
    receipt: &mut Receipt,
    vault: &mut Vault<PrincipalCoinType>,
) {
    vault.assert_vault_receipt_matched(receipt);

    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let dynamic_field_value = dynamic_field::borrow_mut<
        ReceiptCanBeCancelledFieldKey,
        ReceiptCanBeCancelled,
    >(
        receipt.receipt_id_mut(),
        dynamic_field_key,
    );

    dynamic_field_value.can_be_cancelled = false;

    set_vault_receipt_info_can_be_cancelled(vault, receipt.receipt_id(), false);
}

// ^(v1.1 upgrade - new)
public fun set_receipt_can_be_cancelled<PrincipalCoinType>(
    receipt: &mut Receipt,
    vault: &mut Vault<PrincipalCoinType>,
) {
    vault.assert_vault_receipt_matched(receipt);

    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let dynamic_field_value = dynamic_field::borrow_mut<
        ReceiptCanBeCancelledFieldKey,
        ReceiptCanBeCancelled,
    >(
        receipt.receipt_id_mut(),
        dynamic_field_key,
    );

    dynamic_field_value.can_be_cancelled = true;

    set_vault_receipt_info_can_be_cancelled(vault, receipt.receipt_id(), true);
}

public fun receipt_can_be_cancelled(receipt: &Receipt): bool {
    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let mut can_be_cancelled = true;

    if (dynamic_field::exists_(receipt.receipt_uid(), dynamic_field_key)) {
        let dynamic_field_value = dynamic_field::borrow<
            ReceiptCanBeCancelledFieldKey,
            ReceiptCanBeCancelled,
        >(
            receipt.receipt_uid(),
            dynamic_field_key,
        );
        can_be_cancelled = dynamic_field_value.can_be_cancelled
    };

    can_be_cancelled
}

public fun assert_receipt_can_not_be_cancelled(receipt: &Receipt) {
    assert!(!receipt_can_be_cancelled(receipt), ERR_RECEIPT_CAN_BE_CANCELLED);
}

public fun assert_receipt_can_be_cancelled(receipt: &Receipt) {
    assert!(receipt_can_be_cancelled(receipt), ERR_RECEIPT_CANNOT_BE_CANCELLED);
}

// ---------------------- Vault Dynamic Field -------------------- //

//^(v1.1 upgrade - new)
public(package) fun add_dynamic_field_to_vault<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let dynamic_field_value = VaultReceiptCanBeCancelled {
        receipt_can_be_cancelled: table::new<address, bool>(ctx),
    };

    dynamic_field::add(self.vault_id_mut(), dynamic_field_key, dynamic_field_value);
}

public(package) fun set_vault_receipt_info_can_be_cancelled<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    receipt_id: address,
    can_be_cancelled: bool,
) {
    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let dynamic_field_value = dynamic_field::borrow_mut<
        ReceiptCanBeCancelledFieldKey,
        VaultReceiptCanBeCancelled,
    >(
        self.vault_id_mut(),
        dynamic_field_key,
    );

    if (!dynamic_field_value.receipt_can_be_cancelled.contains(receipt_id)) {
        dynamic_field_value.receipt_can_be_cancelled.add(receipt_id, false);
    };

    let can_be_cancelled_value = dynamic_field_value
        .receipt_can_be_cancelled
        .borrow_mut(receipt_id);
    *can_be_cancelled_value = can_be_cancelled;
}

// ^(v1.1 upgrade - new)
public fun vault_receipt_info_can_be_cancelled<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
    receipt_id: address,
): bool {
    let dynamic_field_key = ReceiptCanBeCancelledFieldKey {};
    let mut can_be_cancelled = true;

    if (dynamic_field::exists_(vault.vault_uid(), dynamic_field_key)) {
        let dynamic_field_value = dynamic_field::borrow<
            ReceiptCanBeCancelledFieldKey,
            VaultReceiptCanBeCancelled,
        >(
            vault.vault_uid(),
            dynamic_field_key,
        );

        // By default, the receipt can be cancelled
        if (dynamic_field_value.receipt_can_be_cancelled.contains(receipt_id)) {
            can_be_cancelled = dynamic_field_value.receipt_can_be_cancelled[receipt_id]
        } else {
            can_be_cancelled = true
        }
    };
    can_be_cancelled
}

// ^(v1.1 upgrade - new)
public fun assert_receipt_can_not_be_cancelled_from_vault<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
    receipt_id: address,
) {
    assert!(!vault_receipt_info_can_be_cancelled(vault, receipt_id), ERR_RECEIPT_CAN_BE_CANCELLED);
}

// ^(v1.1 upgrade - new)
public fun assert_receipt_can_be_cancelled_from_vault<PrincipalCoinType>(
    vault: &Vault<PrincipalCoinType>,
    receipt_id: address,
) {
    assert!(
        vault_receipt_info_can_be_cancelled(vault, receipt_id),
        ERR_RECEIPT_CANNOT_BE_CANCELLED,
    );
}
