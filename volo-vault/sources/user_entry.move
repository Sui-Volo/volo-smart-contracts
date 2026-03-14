module volo_vault::user_entry;

use sui::address;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::Coin;
use volo_vault::receipt::Receipt;
use volo_vault::reward_manager::RewardManager;
use volo_vault::vault::Vault;
use volo_vault::receipt_cancellation;

// ---------------------  Errors  ---------------------//
const ERR_INSUFFICIENT_BALANCE: u64 = 4_001;
const ERR_VAULT_ID_MISMATCH: u64 = 4_002;
const ERR_WITHDRAW_LOCKED: u64 = 4_003;
const ERR_INVALID_AMOUNT: u64 = 4_004;

// ---------------------  Public Functions  ---------------------//

public fun deposit<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    reward_manager: &mut RewardManager<PrincipalCoinType>,
    mut coin: Coin<PrincipalCoinType>,
    amount: u64,
    expected_shares: u256,
    mut original_receipt: Option<Receipt>,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, Receipt, Coin<PrincipalCoinType>) {
    assert!(amount > 0, ERR_INVALID_AMOUNT);
    assert!(coin.value() >= amount, ERR_INSUFFICIENT_BALANCE);
    assert!(vault.vault_id() == reward_manager.vault_id(), ERR_VAULT_ID_MISMATCH);

    // Split the coin and request a deposit
    let split_coin = coin.split(amount, ctx);

    // Update receipt info (extract from Option<Receipt>)
    let ret_receipt = if (!option::is_some(&original_receipt)) {
        reward_manager.issue_receipt(ctx)
    } else {
        original_receipt.extract()
    };
    original_receipt.destroy_none();

    vault.assert_vault_receipt_matched(&ret_receipt);

    // If there is no receipt before, create a new vault receipt info record in vault
    let receipt_id = ret_receipt.receipt_id();
    if (!vault.contains_vault_receipt_info(receipt_id)) {
        vault.add_vault_receipt_info(receipt_id, reward_manager.issue_vault_receipt_info(ctx));
    };

    let request_id = vault.request_deposit(
        split_coin,
        clock,
        expected_shares,
        receipt_id,
        ctx.sender(),
    );

    (request_id, ret_receipt, coin)
}

#[allow(lint(self_transfer))]
public fun deposit_with_auto_transfer<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    reward_manager: &mut RewardManager<PrincipalCoinType>,
    coin: Coin<PrincipalCoinType>,
    amount: u64,
    expected_shares: u256,
    original_receipt: Option<Receipt>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let (request_id, ret_receipt, coin) = deposit(
        vault,
        reward_manager,
        coin,
        amount,
        expected_shares,
        original_receipt,
        clock,
        ctx,
    );

    transfer::public_transfer(ret_receipt, ctx.sender());
    transfer::public_transfer(coin, ctx.sender());

    request_id
}

public fun cancel_deposit<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    receipt: &mut Receipt,
    request_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<PrincipalCoinType> {
    vault.assert_vault_receipt_matched(receipt);
    vault.assert_normal();
    receipt_cancellation::assert_receipt_can_be_cancelled(receipt);

    let coin = vault.cancel_deposit(clock, request_id, receipt.receipt_id(), ctx.sender());

    coin
}

#[allow(lint(self_transfer))]
public fun cancel_deposit_with_auto_transfer<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    receipt: &mut Receipt,
    request_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let coin = cancel_deposit(
        vault,
        receipt,
        request_id,
        clock,
        ctx,
    );

    transfer::public_transfer(coin, ctx.sender());
}

public fun withdraw<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    shares: u256,
    expected_amount: u64,
    receipt: &mut Receipt,
    clock: &Clock,
    _ctx: &mut TxContext,
): u64 {
    vault.assert_vault_receipt_matched(receipt);
    assert!(
        vault.check_locking_time_for_withdraw(receipt.receipt_id(), clock),
        ERR_WITHDRAW_LOCKED,
    );
    assert!(shares > 0, ERR_INVALID_AMOUNT);

    let request_id = vault.request_withdraw(
        clock,
        receipt.receipt_id(),
        shares,
        expected_amount,
        address::from_u256(0),
    );

    request_id
}

public fun withdraw_with_auto_transfer<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    shares: u256,
    expected_amount: u64,
    receipt: &mut Receipt,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    vault.assert_vault_receipt_matched(receipt);
    assert!(
        vault.check_locking_time_for_withdraw(receipt.receipt_id(), clock),
        ERR_WITHDRAW_LOCKED,
    );
    assert!(shares > 0, ERR_INVALID_AMOUNT);

    let request_id = vault.request_withdraw(
        clock,
        receipt.receipt_id(),
        shares,
        expected_amount,
        ctx.sender(),
    );

    request_id
}

public fun cancel_withdraw<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    receipt: &mut Receipt,
    request_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    vault.assert_vault_receipt_matched(receipt);
    vault.assert_normal();

    let cancelled_shares = vault.cancel_withdraw(
        clock,
        request_id,
        receipt.receipt_id(),
        ctx.sender(),
    );

    cancelled_shares
}

public fun claim_claimable_principal<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    receipt: &mut Receipt,
    amount: u64,
): Balance<PrincipalCoinType> {
    vault.assert_vault_receipt_matched(receipt);
    vault.claim_claimable_principal(receipt.receipt_id(), amount)
}
