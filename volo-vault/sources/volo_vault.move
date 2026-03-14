#[allow(deprecated_usage)]
module volo_vault::vault;

use std::ascii::String;
use std::type_name::{Self, TypeName};
use sui::address;
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::dynamic_field;
use sui::event::emit;
use sui::table::{Self, Table};
use volo_vault::deposit_request::{Self, DepositRequest};
use volo_vault::receipt::Receipt;
use volo_vault::vault_oracle::{Self, OracleConfig};
use volo_vault::vault_receipt_info::VaultReceiptInfo;
use volo_vault::vault_utils;
use volo_vault::withdraw_request::{Self, WithdrawRequest};

// ---------------------  Constants  ---------------------//

const VERSION: u64 = 6;

const VAULT_NORMAL_STATUS: u8 = 0;
const VAULT_DURING_OPERATION_STATUS: u8 = 1;
const VAULT_DISABLED_STATUS: u8 = 2;

// For rates, 1 = 10_000, 1bp = 1
const RATE_SCALING: u64 = 10_000;

const DEPOSIT_FEE_RATE: u64 = 10; // default 10bp (0.1%)
const WITHDRAW_FEE_RATE: u64 = 10; // default 10bp (0.1%)
const MAX_DEPOSIT_FEE_RATE: u64 = 500; // max 500bp (5%)
const MAX_WITHDRAW_FEE_RATE: u64 = 500; // max 500bp (5%)

const DEFAULT_LOCKING_TIME_FOR_WITHDRAW: u64 = 12 * 3600 * 1_000; // 12 hours to withdraw after a deposit
const DEFAULT_LOCKING_TIME_FOR_CANCEL_REQUEST: u64 = 5 * 60 * 1_000; // 5 minutes to cancel a submitted request

const DEFAULT_TOLERANCE: u256 = 10; // principal loss tolerance at every epoch (0.1%)

const MAX_UPDATE_INTERVAL: u64 = 0; // max update interval 0

const NORMAL_STATUS: u8 = 0;
const PENDING_DEPOSIT_STATUS: u8 = 1;
#[allow(unused_const)]
const PENDING_WITHDRAW_STATUS: u8 = 2;
#[allow(unused_const)]
const PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 3;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS: u8 = 4;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 5;

// --------------------- Errors ---------------------//

const ERR_EXCEED_LIMIT: u64 = 5_001;
const ERR_VAULT_ID_MISMATCH: u64 = 5_002;
const ERR_RECEIPT_ID_MISMATCH: u64 = 5_003;
const ERR_ZERO_SHARE: u64 = 5_004;
const ERR_VAULT_NOT_ENABLED: u64 = 5_005;
const ERR_VAULT_RECEIPT_NOT_MATCH: u64 = 5_006;
const ERR_USD_VALUE_NOT_UPDATED: u64 = 5_007;
const ERR_EXCEED_LOSS_LIMIT: u64 = 5_008;
const ERR_UNEXPECTED_SLIPPAGE: u64 = 5_009;
const ERR_REQUEST_NOT_FOUND: u64 = 5_010;
const ERR_ASSET_TYPE_ALREADY_EXISTS: u64 = 5_011;
const ERR_ASSET_TYPE_NOT_FOUND: u64 = 5_012;
const ERR_INVALID_VERSION: u64 = 5_013;
const ERR_REWARD_MANAGER_ALREADY_SET: u64 = 5_014;
const ERR_OPERATOR_FREEZED: u64 = 5_015;
const ERR_COIN_BUFFER_NOT_FOUND: u64 = 5_016;
const ERR_WRONG_RECEIPT_STATUS: u64 = 5_017;
const ERR_REQUEST_CANCEL_TIME_NOT_REACHED: u64 = 5_018;
const ERR_EXCEED_RECEIPT_SHARES: u64 = 5_019;
const ERR_RECEIPT_NOT_FOUND: u64 = 5_020;
const ERR_INSUFFICIENT_CLAIMABLE_PRINCIPAL: u64 = 5_021;
const ERR_VAULT_NOT_NORMAL: u64 = 5_022;
const ERR_RECIPIENT_MISMATCH: u64 = 5_023;
const ERR_VAULT_NOT_DURING_OPERATION: u64 = 5_024;
const ERR_VAULT_DURING_OPERATION: u64 = 5_025;
const ERR_INVALID_COIN_ASSET_TYPE: u64 = 5_026;
const ERR_OP_VALUE_UPDATE_NOT_ENABLED: u64 = 5_027;
const ERR_NO_FREE_PRINCIPAL: u64 = 5_028;
const ERR_SINGLE_VAULT_OPERATOR_NOT_FOUND: u64 = 5_029;
const ERR_SINGLE_VAULT_OPERATOR_NOT_PAIRED: u64 = 5_030;
const ERR_SINGLE_VAULT_OPERATOR_ALREADY_PAIRED: u64 = 5_031;

// ---------------------  Roles  ---------------------//

public struct AdminCap has key, store {
    id: UID,
}

public struct OperatorCap has key, store {
    id: UID,
}

// Operation operation
public struct Operation has key, store {
    id: UID,
    freezed_operators: Table<address, bool>,
    // dynamic fields
    // - single_vault_operator_config: SingleVaultOperatorConfig,
}

// @note
public struct SingleVaultOperatorConfig has store {
    vault_to_operators: Table<address, vector<address>>,
}

// ---------------------  Objects  ---------------------//

public struct Vault<phantom T> has key, store {
    id: UID,
    version: u64,
    // ---- Pool Info ---- //
    status: u8,
    total_shares: u256,
    locking_time_for_withdraw: u64, // Locking time for withdraw (ms)
    locking_time_for_cancel_request: u64, // Time to cancel a request (ms)
    // ---- Fee ---- //
    deposit_withdraw_fee_collected: Balance<T>,
    // ---- Principal Info ---- //
    free_principal: Balance<T>,
    claimable_principal: Balance<T>,
    // ---- Config ---- //
    deposit_fee_rate: u64,
    withdraw_fee_rate: u64,
    // ---- Assets ---- //
    asset_types: vector<String>, // All assets types, used for looping
    assets: Bag, // <asset_type, asset_object>, asset_object can be balance or DeFi assets
    assets_value: Table<String, u256>, // Assets value in USD
    assets_value_updated: Table<String, u64>, // Last updated timestamp of assets value
    // ---- Loss Tolerance ---- //
    cur_epoch: u64,
    cur_epoch_loss_base_usd_value: u256,
    cur_epoch_loss: u256,
    loss_tolerance: u256,
    // ---- Request Buffer ---- //
    request_buffer: RequestBuffer<T>,
    // ---- Reward Info ---- //
    reward_manager: address,
    // ---- Receipt Info ---- //
    receipts: Table<address, VaultReceiptInfo>,
    // ---- Operation Value Update Record ---- //
    op_value_update_record: OperationValueUpdateRecord,
    // ---- Dynamic Field ---- //
    // - inner_assets: Bag
}

public struct RequestBuffer<phantom T> has store {
    // ---- Deposit Request ---- //
    deposit_id_count: u64,
    deposit_requests: Table<u64, DepositRequest>,
    deposit_coin_buffer: Table<u64, Coin<T>>,
    // ---- Withdraw Request ---- //
    withdraw_id_count: u64,
    withdraw_requests: Table<u64, WithdrawRequest>,
}

public struct OperationValueUpdateRecord has store {
    asset_types_borrowed: vector<String>,
    value_update_enabled: bool,
    asset_types_updated: Table<String, bool>,
}

//^ (v1.1Upgrade - new)
public struct ReceiptCanBeCancelledFieldKey has copy, drop, store {}

//^ (v1.1Upgrade - new)
public struct ReceiptCanBeCancelled has store {
    can_be_cancelled: bool,
}

// ---------------------  Events  ---------------------//

public struct VaultCreated has copy, drop {
    vault_id: address,
    principal: TypeName,
}

public struct OperatorCapCreated has copy, drop {
    cap_id: address,
}

public struct VaultEnabled has copy, drop {
    vault_id: address,
    enabled: bool,
}

public struct DepositRequested has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    amount: u64,
    expected_shares: u256,
}

public struct DepositCancelled has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    amount: u64,
}

public struct DepositExecuted has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    amount: u64,
    shares: u256,
}

public struct WithdrawRequested has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    shares: u256,
    expected_amount: u64,
}

public struct WithdrawCancelled has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    shares: u256,
}

public struct WithdrawExecuted has copy, drop {
    request_id: u64,
    receipt_id: address,
    recipient: address,
    vault_id: address,
    shares: u256,
    amount: u64,
}

public struct ToleranceChanged has copy, drop {
    vault_id: address,
    tolerance: u256,
}

public struct WithdrawFeeChanged has copy, drop {
    vault_id: address,
    fee: u64,
}

public struct DepositFeeChanged has copy, drop {
    vault_id: address,
    fee: u64,
}

public struct RewardManagerSet has copy, drop {
    vault_id: address,
    reward_manager_id: address,
}

public struct VaultUpgraded has copy, drop {
    vault_id: address,
    version: u64,
}

public struct FreePrincipalReturned has copy, drop {
    vault_id: address,
    amount: u64,
}

public struct FreePrincipalBorrowed has copy, drop {
    vault_id: address,
    amount: u64,
}

public struct LossToleranceReset has copy, drop {
    vault_id: address,
    epoch: u64,
}

public struct LossToleranceUpdated has copy, drop {
    vault_id: address,
    current_loss: u256,
    loss_limit: u256,
}

public struct OperatorDeposited has copy, drop {
    vault_id: address,
    amount: u64,
}

public struct NewAssetTypeAdded has copy, drop {
    vault_id: address,
    asset_type: String,
}

public struct DefiAssetRemoved has copy, drop {
    vault_id: address,
    asset_type: String,
}

public struct CoinTypeAssetRemoved has copy, drop {
    vault_id: address,
    asset_type: String,
}

public struct AssetValueUpdated has copy, drop {
    vault_id: address,
    asset_type: String,
    usd_value: u256,
    timestamp: u64,
}

public struct TotalUSDValueUpdated has copy, drop {
    vault_id: address,
    total_usd_value: u256,
    timestamp: u64,
}

public struct ShareRatioUpdated has copy, drop {
    vault_id: address,
    share_ratio: u256,
    timestamp: u64,
}

public struct DepositWithdrawFeeRetrieved has copy, drop {
    vault_id: address,
    amount: u64,
}

public struct DefiAssetBorrowed has copy, drop {
    vault_id: address,
    asset_type: String,
}

public struct DefiAssetReturned has copy, drop {
    vault_id: address,
    asset_type: String,
}

public struct ClaimablePrincipalAdded has copy, drop {
    vault_id: address,
    amount: u64,
}

public struct ClaimablePrincipalClaimed has copy, drop {
    vault_id: address,
    receipt_id: address,
    amount: u64,
}

public struct OperatorFreezed has copy, drop {
    operator_id: address,
    freezed: bool,
}

public struct VaultStatusChanged has copy, drop {
    vault_id: address,
    status: u8,
}

public struct LockingTimeForWithdrawChanged has copy, drop {
    vault_id: address,
    locking_time: u64,
}

public struct LockingTimeForCancelRequestChanged has copy, drop {
    vault_id: address,
    locking_time: u64,
}

public struct SingleVaultOperatorAdded has copy, drop {
    vault_id: address,
    operator_id: address,
}

public struct SingleVaultOperatorRemoved has copy, drop {
    vault_id: address,
    operator_id: address,
}

public struct SingleVaultOperatorConfigFieldKey has copy, drop, store {}
public struct InnerAssetsKey has copy, drop, store {}

// ---------------------  Init  ---------------------//

fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::public_transfer(admin_cap, ctx.sender());

    let operation = Operation {
        id: object::new(ctx),
        freezed_operators: table::new(ctx),
    };
    transfer::share_object(operation);
}

// ---------------------  Rules  ---------------------//

public(package) fun set_operator_freezed(
    operation: &mut Operation,
    op_cap_id: address,
    freezed: bool,
) {
    if (operation.freezed_operators.contains(op_cap_id)) {
        let v = operation.freezed_operators.borrow_mut(op_cap_id);
        *v = freezed;
    } else {
        operation.freezed_operators.add(op_cap_id, freezed);
    };

    emit(OperatorFreezed {
        operator_id: op_cap_id,
        freezed: freezed,
    });
}

public(package) fun assert_operator_not_freezed(operation: &Operation, cap: &OperatorCap) {
    let cap_id = cap.operator_id();
    // If the operator has ever been freezed, it will be in the freezed_operator map, check its value
    // If the operator has never been freezed, no error will be emitted
    assert!(!operator_freezed(operation, cap_id), ERR_OPERATOR_FREEZED);
}

public(package) fun assert_operator_not_freezed_by_id(operation: &Operation, cap_id: address) {
    assert!(!operator_freezed(operation, cap_id), ERR_OPERATOR_FREEZED);
}

public fun operator_freezed(operation: &Operation, op_cap_id: address): bool {
    if (operation.freezed_operators.contains(op_cap_id)) {
        *operation.freezed_operators.borrow(op_cap_id)
    } else {
        false
    }
}

// ^(v1.1 upgrade - new)
public(package) fun operation_id_mut(operation: &mut Operation): &mut UID {
    &mut operation.id
}

// ^(v1.1 upgrade - new)
public fun vault_uid<PrincipalCoinType>(vault: &Vault<PrincipalCoinType>): &UID {
    &vault.id
}

// ^(v1.1 upgrade - new)
public(package) fun vault_id_mut<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
): &mut UID {
    &mut vault.id
}

// ^(v1.1 upgrade - new)
public fun get_single_vault_operator_config_by_dynamic_field(
    operation: &Operation,
): &Table<address, vector<address>> {
    let dynamic_field_key = SingleVaultOperatorConfigFieldKey {};
    let dynamic_field_value = dynamic_field::borrow<
        SingleVaultOperatorConfigFieldKey,
        SingleVaultOperatorConfig,
    >(
        &operation.id,
        dynamic_field_key,
    );
    &dynamic_field_value.vault_to_operators
}

// ^(v1.1 upgrade - new)
public fun get_single_vault_operator_by_dynamic_field(
    operation: &Operation,
    vault_id: address,
): &vector<address> {
    let dynamic_field_key = SingleVaultOperatorConfigFieldKey {};
    let dynamic_field_value = dynamic_field::borrow<
        SingleVaultOperatorConfigFieldKey,
        SingleVaultOperatorConfig,
    >(
        &operation.id,
        dynamic_field_key,
    );

    // let operators = table::borrow<address, vector<address>>(dynamic_field_value, vault_id);
    let operators = dynamic_field_value.vault_to_operators.borrow(vault_id);
    operators
}

// ^(v1.1 upgrade - new)
public fun assert_single_vault_operator_paired(
    operation: &Operation,
    vault_id: address,
    operator_cap: &OperatorCap,
) {
    let operator_cap_id = operator_cap.operator_id();

    let single_vault_operator_config = get_single_vault_operator_config_by_dynamic_field(operation);
    let operators = table::borrow<address, vector<address>>(single_vault_operator_config, vault_id);

    let (contains, _) = operators.index_of(&operator_cap_id);
    assert!(contains, ERR_SINGLE_VAULT_OPERATOR_NOT_PAIRED);
}

// ^(v1.1 upgrade - new)
public(package) fun add_dynamic_field_to_operation(operation: &mut Operation, ctx: &mut TxContext) {
    let dynamic_field_key = SingleVaultOperatorConfigFieldKey {};
    let dynamic_field_value = SingleVaultOperatorConfig {
        vault_to_operators: table::new<address, vector<address>>(ctx),
    };

    dynamic_field::add(operation.operation_id_mut(), dynamic_field_key, dynamic_field_value);
}

// ^(v1.1 upgrade - new)
public(package) fun set_single_vault_operator(
    operation: &mut Operation,
    vault_id: address,
    operator: address,
) {
    let dynamic_field_key = SingleVaultOperatorConfigFieldKey {};
    let dynamic_field_value = dynamic_field::borrow_mut<
        SingleVaultOperatorConfigFieldKey,
        SingleVaultOperatorConfig,
    >(
        operation.operation_id_mut(),
        dynamic_field_key,
    );

    if (!dynamic_field_value.vault_to_operators.contains(vault_id)) {
        dynamic_field_value.vault_to_operators.add(vault_id, vector::empty<address>());
    };

    let operators = dynamic_field_value.vault_to_operators.borrow_mut(vault_id);
    assert!(!operators.contains(&operator), ERR_SINGLE_VAULT_OPERATOR_ALREADY_PAIRED);
    operators.push_back(operator);

    emit(SingleVaultOperatorAdded {
        vault_id: vault_id,
        operator_id: operator,
    });
}

// ^(v1.1 upgrade - new)
public(package) fun remove_single_vault_operator(
    operation: &mut Operation,
    vault_id: address,
    operator: address,
) {
    // let dynamic_field_key = b"single_vault_operator_config";
    let dynamic_field_key = SingleVaultOperatorConfigFieldKey {};
    let dynamic_field_value = dynamic_field::borrow_mut<
        SingleVaultOperatorConfigFieldKey,
        SingleVaultOperatorConfig,
    >(
        operation.operation_id_mut(),
        dynamic_field_key,
    );
    let operators = dynamic_field_value.vault_to_operators.borrow_mut(vault_id);
    let (contains, index) = operators.index_of(&operator);
    assert!(contains, ERR_SINGLE_VAULT_OPERATOR_NOT_FOUND);
    operators.swap_remove(index);

    emit(SingleVaultOperatorRemoved {
        vault_id: vault_id,
        operator_id: operator,
    });
}

// ------------------  Admin Functions  ------------------------//

public(package) fun create_operator_cap(ctx: &mut TxContext): OperatorCap {
    let cap = OperatorCap { id: object::new(ctx) };
    emit(OperatorCapCreated {
        cap_id: object::id_address(&cap),
    });
    cap
}

// Create a new vault (differnet vault varies in its principal asset)
// <PrincipalCoinType> is the type of the principal asset
// It may have multiple underlying assets but only one principal asset
public fun create_vault<PrincipalCoinType>(_: &AdminCap, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let id_address = id.to_address();

    let request_buffer = RequestBuffer<PrincipalCoinType> {
        deposit_id_count: 0,
        deposit_requests: table::new<u64, DepositRequest>(ctx),
        deposit_coin_buffer: table::new<u64, Coin<PrincipalCoinType>>(ctx),
        withdraw_id_count: 0,
        withdraw_requests: table::new<u64, WithdrawRequest>(ctx),
    };

    let op_value_update_record = OperationValueUpdateRecord {
        asset_types_borrowed: vector::empty<String>(),
        value_update_enabled: false,
        asset_types_updated: table::new<String, bool>(ctx),
    };

    let mut vault = Vault<PrincipalCoinType> {
        id: id,
        version: VERSION,
        status: VAULT_NORMAL_STATUS,
        total_shares: 0,
        locking_time_for_withdraw: DEFAULT_LOCKING_TIME_FOR_WITHDRAW,
        locking_time_for_cancel_request: DEFAULT_LOCKING_TIME_FOR_CANCEL_REQUEST,
        deposit_withdraw_fee_collected: balance::zero<PrincipalCoinType>(),
        free_principal: balance::zero<PrincipalCoinType>(),
        claimable_principal: balance::zero<PrincipalCoinType>(),
        deposit_fee_rate: DEPOSIT_FEE_RATE,
        withdraw_fee_rate: WITHDRAW_FEE_RATE,
        asset_types: vector::empty<String>(),
        assets: bag::new(ctx),
        assets_value: table::new<String, u256>(ctx),
        assets_value_updated: table::new<String, u64>(ctx),
        cur_epoch: ctx.epoch(),
        cur_epoch_loss_base_usd_value: 0,
        cur_epoch_loss: 0,
        loss_tolerance: DEFAULT_TOLERANCE,
        request_buffer: request_buffer,
        reward_manager: address::from_u256(0),
        receipts: table::new<address, VaultReceiptInfo>(ctx),
        op_value_update_record: op_value_update_record,
    };

    // PrincipalCoinType is added by default
    // vault.add_new_coin_type_asset<PrincipalCoinType, PrincipalCoinType>();
    vault.set_new_asset_type(type_name::get<PrincipalCoinType>().into_string());

    vault.init_inner_assets(ctx);

    transfer::share_object(vault);

    emit(VaultCreated {
        vault_id: id_address,
        principal: type_name::get<PrincipalCoinType>(),
    });
}

public(package) fun upgrade_vault<PrincipalCoinType>(self: &mut Vault<PrincipalCoinType>) {
    assert!(self.version < VERSION, ERR_INVALID_VERSION);
    self.version = VERSION;

    emit(VaultUpgraded { vault_id: self.id.to_address(), version: VERSION });
}

public(package) fun set_reward_manager<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    reward_manager_id: address,
) {
    self.check_version();
    assert!(self.reward_manager == address::from_u256(0), ERR_REWARD_MANAGER_ALREADY_SET);
    self.reward_manager = reward_manager_id;

    emit(RewardManagerSet {
        vault_id: self.vault_id(),
        reward_manager_id: reward_manager_id,
    });
}

// Set the loss tolerance rate (each epoch) for the vault
public(package) fun set_loss_tolerance<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    tolerance: u256,
) {
    self.check_version();
    assert!(tolerance <= (RATE_SCALING as u256), ERR_EXCEED_LIMIT);
    self.loss_tolerance = tolerance;
    emit(ToleranceChanged { vault_id: self.vault_id(), tolerance: tolerance })
}

// Set the deposit fee rate for the vault
public(package) fun set_deposit_fee<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    fee: u64,
) {
    self.check_version();
    assert!(fee <= MAX_DEPOSIT_FEE_RATE, ERR_EXCEED_LIMIT);
    self.deposit_fee_rate = fee;
    emit(DepositFeeChanged { vault_id: self.vault_id(), fee: fee })
}

// Set the withdraw fee rate for the vault
public(package) fun set_withdraw_fee<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    fee: u64,
) {
    self.check_version();
    assert!(fee <= MAX_WITHDRAW_FEE_RATE, ERR_EXCEED_LIMIT);
    self.withdraw_fee_rate = fee;
    emit(WithdrawFeeChanged { vault_id: self.vault_id(), fee: fee })
}

public(package) fun set_enabled<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    enabled: bool,
) {
    self.check_version();
    assert!(self.status() != VAULT_DURING_OPERATION_STATUS, ERR_VAULT_DURING_OPERATION);

    if (enabled) {
        self.set_status(VAULT_NORMAL_STATUS);
    } else {
        self.set_status(VAULT_DISABLED_STATUS);
    };
    emit(VaultEnabled { vault_id: self.vault_id(), enabled: enabled })
}

public(package) fun set_status<PrincipalCoinType>(self: &mut Vault<PrincipalCoinType>, status: u8) {
    self.check_version();
    self.status = status;

    emit(VaultStatusChanged {
        vault_id: self.vault_id(),
        status: status,
    });
}

public(package) fun set_locking_time_for_withdraw<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    locking_time: u64,
) {
    self.check_version();
    self.locking_time_for_withdraw = locking_time;

    emit(LockingTimeForWithdrawChanged {
        vault_id: self.vault_id(),
        locking_time: locking_time,
    });
}

public(package) fun set_locking_time_for_cancel_request<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    locking_time: u64,
) {
    self.check_version();
    self.locking_time_for_cancel_request = locking_time;

    emit(LockingTimeForCancelRequestChanged {
        vault_id: self.vault_id(),
        locking_time: locking_time,
    });
}

// --------------- Free Principal  ---------------//

// Operators can get free principal from the vault
public(package) fun borrow_free_principal<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    amount: u64,
): Balance<PrincipalCoinType> {
    self.check_version();
    self.assert_enabled();

    if (self.status() == VAULT_DURING_OPERATION_STATUS) {
        let principal_asset_type = type_name::get<PrincipalCoinType>().into_string();
        self.op_value_update_record.asset_types_borrowed.push_back(principal_asset_type);
    };

    let ret = self.free_principal.split(amount);
    emit(FreePrincipalBorrowed {
        vault_id: self.vault_id(),
        amount: amount,
    });
    ret
}

public(package) fun return_free_principal<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    balance: Balance<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_enabled();

    emit(FreePrincipalReturned {
        vault_id: self.vault_id(),
        amount: balance.value(),
    });
    self.free_principal.join(balance);
}

//------------- Epoch Loss Tolerance -----------------//

public(package) fun try_reset_tolerance<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    by_admin: bool,
    ctx: &TxContext,
) {
    self.check_version();

    if (by_admin || self.cur_epoch < tx_context::epoch(ctx)) {
        self.cur_epoch_loss = 0;
        self.cur_epoch = tx_context::epoch(ctx);
        self.cur_epoch_loss_base_usd_value = self.get_total_usd_value_without_update();
        emit(LossToleranceReset {
            vault_id: self.vault_id(),
            epoch: self.cur_epoch,
        });
    };
}

public(package) fun update_tolerance<T0>(self: &mut Vault<T0>, loss: u256) {
    self.check_version();

    self.cur_epoch_loss = self.cur_epoch_loss + loss;

    // let loss_limit = usd_value_before * (self.loss_tolerance as u256) / (RATE_SCALING as u256);
    let loss_limit =
        self.cur_epoch_loss_base_usd_value * (self.loss_tolerance as u256) / (RATE_SCALING as u256);

    assert!(loss_limit >= self.cur_epoch_loss, ERR_EXCEED_LOSS_LIMIT);
    emit(LossToleranceUpdated {
        vault_id: self.vault_id(),
        current_loss: self.cur_epoch_loss,
        loss_limit: loss_limit,
    });
}

// ---------------------  Checks  ---------------------//

public(package) fun assert_enabled<PrincipalCoinType>(self: &Vault<PrincipalCoinType>) {
    assert!(self.status() != VAULT_DISABLED_STATUS, ERR_VAULT_NOT_ENABLED);
}

public(package) fun assert_normal<PrincipalCoinType>(self: &Vault<PrincipalCoinType>) {
    assert!(self.status() == VAULT_NORMAL_STATUS, ERR_VAULT_NOT_NORMAL);
}

public(package) fun assert_during_operation<PrincipalCoinType>(self: &Vault<PrincipalCoinType>) {
    assert!(self.status() == VAULT_DURING_OPERATION_STATUS, ERR_VAULT_NOT_DURING_OPERATION);
}

public(package) fun assert_not_during_operation<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
) {
    assert!(self.status() != VAULT_DURING_OPERATION_STATUS, ERR_VAULT_DURING_OPERATION);
}

public(package) fun check_version<PrincipalCoinType>(self: &Vault<PrincipalCoinType>) {
    assert!(self.version == VERSION, ERR_INVALID_VERSION);
}

// The receipt is for withdraw from the correct vault
public(package) fun assert_vault_receipt_matched<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    receipt: &Receipt,
) {
    assert!(self.vault_id() == receipt.vault_id(), ERR_VAULT_RECEIPT_NOT_MATCH);
}

// Locking time between a request and a cancel
public fun check_locking_time_for_cancel_request<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    is_deposit: bool,
    request_id: u64,
    clock: &Clock,
): bool {
    self.check_version();

    if (is_deposit) {
        let request = self.request_buffer.deposit_requests.borrow(request_id);
        request.request_time() + self.locking_time_for_cancel_request() <= clock.timestamp_ms()
    } else {
        let request = self.request_buffer.withdraw_requests.borrow(request_id);
        request.request_time() + self.locking_time_for_cancel_request() <= clock.timestamp_ms()
    }
}

// Locking time between a deposit and a withdraw
public fun check_locking_time_for_withdraw<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    receipt_id: address,
    clock: &Clock,
): bool {
    self.check_version();

    let receipt = self.receipts.borrow(receipt_id);
    self.locking_time_for_withdraw() + receipt.last_deposit_time() <= clock.timestamp_ms()
}

// ---------------------  Request Deposit  ---------------------//

public(package) fun request_deposit<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    coin: Coin<PrincipalCoinType>,
    clock: &Clock,
    expected_shares: u256,
    receipt_id: address,
    recipient: address,
): u64 {
    self.check_version();
    self.assert_normal();
    assert!(self.contains_vault_receipt_info(receipt_id), ERR_RECEIPT_NOT_FOUND);

    let vault_receipt = &mut self.receipts[receipt_id];
    assert!(
        vault_receipt.status() == NORMAL_STATUS || 
        vault_receipt.status() == PENDING_WITHDRAW_STATUS || 
        vault_receipt.status() == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS,
        ERR_WRONG_RECEIPT_STATUS,
    );

    // Generate current request id
    let current_deposit_id = self.request_buffer.deposit_id_count;
    self.request_buffer.deposit_id_count = current_deposit_id + 1;

    // Deposit amount
    let amount = coin.value();

    // Generate the new deposit request and add it to the vault storage
    let new_request = deposit_request::new(
        current_deposit_id,
        receipt_id,
        recipient,
        self.id.to_address(),
        amount,
        expected_shares,
        clock.timestamp_ms(),
    );
    self.request_buffer.deposit_requests.add(current_deposit_id, new_request);

    emit(DepositRequested {
        request_id: current_deposit_id,
        receipt_id: receipt_id,
        recipient: recipient,
        vault_id: self.id.to_address(),
        amount: amount,
        expected_shares: expected_shares,
    });

    // Temporary buffer the coins from user
    // Operator will retrieve this coin and execute the deposit
    self.request_buffer.deposit_coin_buffer.add(current_deposit_id, coin);

    vault_receipt.update_after_request_deposit(amount);

    current_deposit_id
}

// ---------------------  Cancel Deposit  ---------------------//

public(package) fun cancel_deposit<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    request_id: u64,
    receipt_id: address,
    recipient: address,
): Coin<PrincipalCoinType> {
    self.check_version();
    self.assert_not_during_operation();

    assert!(self.contains_vault_receipt_info(receipt_id), ERR_RECEIPT_NOT_FOUND);
    assert!(self.request_buffer.deposit_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);

    let vault_receipt = &mut self.receipts[receipt_id];
    assert!(
        vault_receipt.status() == PENDING_DEPOSIT_STATUS || 
        vault_receipt.status() == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS || 
        vault_receipt.status() == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS,
        ERR_WRONG_RECEIPT_STATUS,
    );

    let deposit_request = &mut self.request_buffer.deposit_requests[request_id];
    assert!(receipt_id == deposit_request.receipt_id(), ERR_RECEIPT_ID_MISMATCH);
    assert!(
        deposit_request.request_time() + self.locking_time_for_cancel_request <= clock.timestamp_ms(),
        ERR_REQUEST_CANCEL_TIME_NOT_REACHED,
    );
    // assert!(deposit_request.recipient() == recipient, ERR_RECIPIENT_MISMATCH);

    // deposit_request.cancel(clock.timestamp_ms());
    vault_receipt.update_after_cancel_deposit(deposit_request.amount());

    // Retrieve the receipt and coin from the buffer
    let coin = self.request_buffer.deposit_coin_buffer.remove(request_id);

    emit(DepositCancelled {
        request_id: request_id,
        receipt_id: deposit_request.receipt_id(),
        recipient: recipient,
        vault_id: self.id.to_address(),
        amount: deposit_request.amount(),
    });

    self.delete_deposit_request(request_id);

    coin
}

// ---------------------  Execute Deposit  ---------------------//

public(package) fun execute_deposit<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    config: &OracleConfig,
    request_id: u64,
    max_shares_received: u256,
) {
    self.check_version();
    self.assert_normal();

    assert!(self.request_buffer.deposit_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);

    // Current share ratio (before counting the new deposited coin)
    // This update should generate performance fee if the total usd value is increased
    let total_usd_value_before = self.get_total_usd_value(clock);
    let share_ratio_before = self.get_share_ratio(clock);

    let deposit_request = *self.request_buffer.deposit_requests.borrow(request_id);
    assert!(deposit_request.vault_id() == self.id.to_address(), ERR_VAULT_ID_MISMATCH);

    // Get the coin from the buffer
    let coin = self.request_buffer.deposit_coin_buffer.remove(request_id);
    let coin_amount = deposit_request.amount();

    let deposit_fee = coin_amount * self.deposit_fee_rate / RATE_SCALING;

    // let actual_deposit_amount = coin_amount - deposit_fee;
    let mut coin_balance = coin.into_balance();
    // Split the deposit fee to the fee collected
    let deposit_fee_balance = coin_balance.split(deposit_fee as u64);
    self.deposit_withdraw_fee_collected.join(deposit_fee_balance);

    self.free_principal.join(coin_balance);
    update_free_principal_value(self, config, clock);

    let total_usd_value_after = self.get_total_usd_value(clock);
    let new_usd_value_deposited = total_usd_value_after - total_usd_value_before;

    let user_shares = vault_utils::div_d(new_usd_value_deposited, share_ratio_before);
    let expected_shares = deposit_request.expected_shares();
    // Negative slippage is determined by the "expected_shares"
    // Positive slippage is determined by the "max_shares_received"
    assert!(user_shares > 0, ERR_ZERO_SHARE);
    assert!(user_shares >= expected_shares, ERR_UNEXPECTED_SLIPPAGE);
    assert!(user_shares <= max_shares_received, ERR_UNEXPECTED_SLIPPAGE);

    // Update total shares in the vault
    self.total_shares = self.total_shares + user_shares;

    emit(DepositExecuted {
        request_id: request_id,
        receipt_id: deposit_request.receipt_id(),
        recipient: deposit_request.recipient(),
        vault_id: self.id.to_address(),
        amount: coin_amount,
        shares: user_shares,
    });

    let vault_receipt = &mut self.receipts[deposit_request.receipt_id()];
    vault_receipt.update_after_execute_deposit(
        deposit_request.amount(),
        user_shares,
        clock.timestamp_ms(),
    );

    self.delete_deposit_request(request_id);
}

public(package) fun deposit_by_operator<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    config: &OracleConfig,
    coin: Coin<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_normal();

    let deposit_amount = coin.value();

    self.free_principal.join(coin.into_balance());
    update_free_principal_value(self, config, clock);

    emit(OperatorDeposited {
        vault_id: self.vault_id(),
        amount: deposit_amount,
    });
}

// --------------------- Request Withdraw  ---------------------//

public(package) fun request_withdraw<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    receipt_id: address,
    shares: u256,
    expected_amount: u64,
    recipient: address,
): u64 {
    self.check_version();
    self.assert_normal();
    assert!(self.contains_vault_receipt_info(receipt_id), ERR_RECEIPT_NOT_FOUND);

    let vault_receipt = &mut self.receipts[receipt_id];
    assert!(
        vault_receipt.status() == NORMAL_STATUS || vault_receipt.status() == PENDING_DEPOSIT_STATUS,
        ERR_WRONG_RECEIPT_STATUS,
    );
    assert!(vault_receipt.shares() >= shares, ERR_EXCEED_RECEIPT_SHARES);

    // Generate request id
    let current_request_id = self.request_buffer.withdraw_id_count;
    self.request_buffer.withdraw_id_count = current_request_id + 1;

    // Record this new request in Vault
    let new_request = withdraw_request::new(
        current_request_id,
        receipt_id,
        recipient,
        self.id.to_address(),
        shares,
        expected_amount,
        clock.timestamp_ms(),
    );
    self.request_buffer.withdraw_requests.add(current_request_id, new_request);

    emit(WithdrawRequested {
        request_id: current_request_id,
        receipt_id: receipt_id,
        recipient: recipient,
        vault_id: self.id.to_address(),
        shares: shares,
        expected_amount: expected_amount,
    });

    vault_receipt.update_after_request_withdraw(shares, recipient);

    current_request_id
}

// ---------------------  Cancel Withdraw  ---------------------//

public(package) fun cancel_withdraw<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    request_id: u64,
    receipt_id: address,
    recipient: address,
): u256 {
    self.check_version();
    self.assert_normal();
    assert!(self.contains_vault_receipt_info(receipt_id), ERR_RECEIPT_NOT_FOUND);
    assert!(self.request_buffer.withdraw_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);

    let vault_receipt = &mut self.receipts[receipt_id];
    assert!(
        vault_receipt.status() == PENDING_WITHDRAW_STATUS || 
        vault_receipt.status() == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS ||
        vault_receipt.status() == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS ||
        vault_receipt.status() == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS,
        ERR_WRONG_RECEIPT_STATUS,
    );

    let withdraw_request = &mut self.request_buffer.withdraw_requests[request_id];
    assert!(receipt_id == withdraw_request.receipt_id(), ERR_RECEIPT_ID_MISMATCH);
    assert!(
        withdraw_request.request_time() + self.locking_time_for_cancel_request <= clock.timestamp_ms(),
        ERR_REQUEST_CANCEL_TIME_NOT_REACHED,
    );
    assert!(
        withdraw_request.recipient() == recipient || withdraw_request.recipient() == address::from_u256(0),
        ERR_RECIPIENT_MISMATCH,
    );

    // withdraw_request.cancel(clock.timestamp_ms());
    vault_receipt.update_after_cancel_withdraw(withdraw_request.shares());

    emit(WithdrawCancelled {
        request_id: request_id,
        receipt_id: withdraw_request.receipt_id(),
        recipient: recipient,
        vault_id: self.id.to_address(),
        shares: withdraw_request.shares(),
    });

    let cancelled_shares = withdraw_request.shares();

    self.delete_withdraw_request(request_id);

    cancelled_shares
}

// ---------------------  Execute Withdraw  ---------------------//

// Only operator can execute withdraw
public(package) fun execute_withdraw<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    config: &OracleConfig,
    request_id: u64,
    max_amount_received: u64,
): (Balance<PrincipalCoinType>, address) {
    self.check_version();
    self.assert_normal();
    assert!(self.request_buffer.withdraw_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);

    // Get the current share ratio
    let ratio = self.get_share_ratio(clock);

    // Get the corresponding withdraw request from the vault
    let withdraw_request = self.request_buffer.withdraw_requests[request_id];

    // Shares and amount to withdraw
    let shares_to_withdraw = withdraw_request.shares();
    let usd_value_to_withdraw = vault_utils::mul_d(shares_to_withdraw, ratio);
    let amount_to_withdraw =
        vault_utils::div_with_oracle_price(
            usd_value_to_withdraw,
            vault_oracle::get_normalized_asset_price(
                config,
                clock,
                type_name::get<PrincipalCoinType>().into_string(),
            ),
        ) as u64;

    // Check the slippage (less than 100bps)
    let expected_amount = withdraw_request.expected_amount();

    // Negative slippage is determined by the "expected_amount"
    // Positive slippage is determined by the "max_amount_received"
    assert!(amount_to_withdraw >= expected_amount, ERR_UNEXPECTED_SLIPPAGE);
    assert!(amount_to_withdraw <= max_amount_received, ERR_UNEXPECTED_SLIPPAGE);

    // Decrease the share in vault and receipt
    self.total_shares = self.total_shares - shares_to_withdraw;

    // Split balances from the vault
    assert!(amount_to_withdraw <= self.free_principal.value(), ERR_NO_FREE_PRINCIPAL);
    let mut withdraw_balance = self.free_principal.split(amount_to_withdraw);

    // Protocol fee
    let fee_amount = amount_to_withdraw * self.withdraw_fee_rate / RATE_SCALING;
    let fee_balance = withdraw_balance.split(fee_amount as u64);
    self.deposit_withdraw_fee_collected.join(fee_balance);

    emit(WithdrawExecuted {
        request_id: request_id,
        receipt_id: withdraw_request.receipt_id(),
        recipient: withdraw_request.recipient(),
        vault_id: self.id.to_address(),
        shares: shares_to_withdraw,
        amount: amount_to_withdraw - fee_amount,
    });

    // Update total usd value after withdraw executed
    // This update should not generate any performance fee
    // (actually the total usd value will decrease, so there is no performance fee)
    self.update_free_principal_value(config, clock);

    // Update the vault receipt info
    let vault_receipt = &mut self.receipts[withdraw_request.receipt_id()];

    let recipient = withdraw_request.recipient();
    if (recipient != address::from_u256(0)) {
        vault_receipt.update_after_execute_withdraw(
            shares_to_withdraw,
            0,
        )
    } else {
        vault_receipt.update_after_execute_withdraw(
            shares_to_withdraw,
            withdraw_balance.value(),
        )
    };

    self.delete_withdraw_request(request_id);

    (withdraw_balance, recipient)
}

// -------------------  Delete Request  ---------------------//

public(package) fun delete_deposit_request<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    request_id: u64,
) {
    self.check_version();

    self.request_buffer.deposit_requests.remove(request_id);
}

public(package) fun delete_withdraw_request<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    request_id: u64,
) {
    self.check_version();

    self.request_buffer.withdraw_requests.remove(request_id);
}

// -----------  Global Value Update  ------------//

public fun update_free_principal_value<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    config: &OracleConfig,
    clock: &Clock,
) {
    self.check_version();
    self.assert_enabled();

    let principal_price = vault_oracle::get_normalized_asset_price(
        config,
        clock,
        type_name::get<PrincipalCoinType>().into_string(),
    );

    let principal_usd_value = vault_utils::mul_with_oracle_price(
        self.free_principal.value() as u256,
        principal_price,
    );

    let principal_asset_type = type_name::get<PrincipalCoinType>().into_string();

    finish_update_asset_value(
        self,
        principal_asset_type,
        principal_usd_value,
        clock.timestamp_ms(),
    );
}

public fun update_coin_type_asset_value<PrincipalCoinType, CoinType>(
    self: &mut Vault<PrincipalCoinType>,
    config: &OracleConfig,
    clock: &Clock,
) {
    self.check_version();
    self.assert_enabled();
    assert!(
        type_name::get<CoinType>() != type_name::get<PrincipalCoinType>(),
        ERR_INVALID_COIN_ASSET_TYPE,
    );

    let asset_type = type_name::get<CoinType>().into_string();
    let now = clock.timestamp_ms();

    let coin_amount =
        self.inner_assets_mut().borrow<String, Balance<CoinType>>(asset_type).value() as u256;
    let price = vault_oracle::get_normalized_asset_price(
        config,
        clock,
        asset_type,
    );
    let coin_usd_value = vault_utils::mul_with_oracle_price(coin_amount, price);

    finish_update_asset_value(self, asset_type, coin_usd_value, now);
}

public fun validate_total_usd_value_updated<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    clock: &Clock,
) {
    self.check_version();

    let now = clock.timestamp_ms();

    self.asset_types.do_ref!(|asset_type| {
        let last_update_time = self.assets_value_updated[*asset_type];
        assert!(now - last_update_time <= MAX_UPDATE_INTERVAL, ERR_USD_VALUE_NOT_UPDATED);
    });
}

// * @dev Finish the value update process (will be called at the end of each asset value update)
// *      This function will update the asset value and the last update time
// *      Also, it will update the "op_value_update_record" if the vault is during operation (step3)
// *      This update will ensure the operation has been correctly done (i.e. each borrowed asset has been returned and updated)
public(package) fun finish_update_asset_value<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    usd_value: u256,
    now: u64,
) {
    self.check_version();
    self.assert_enabled();

    let last_update_time = &mut self.assets_value_updated[asset_type];
    *last_update_time = now;

    let position_value = &mut self.assets_value[asset_type];
    *position_value = usd_value;

    if (
        self.status() == VAULT_DURING_OPERATION_STATUS 
        && self.op_value_update_record.value_update_enabled 
        && self.op_value_update_record.asset_types_borrowed.contains(&asset_type)
    ) {
        self.op_value_update_record.asset_types_updated.add(asset_type, true);
    };

    emit(AssetValueUpdated {
        vault_id: self.vault_id(),
        asset_type: asset_type,
        usd_value: usd_value,
        timestamp: now,
    });
}

// * @dev Check if the value of each borrowed asset during operation is updated correctly
public(package) fun check_op_value_update_record<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_enabled();
    assert!(self.op_value_update_record.value_update_enabled, ERR_OP_VALUE_UPDATE_NOT_ENABLED);

    let record = &self.op_value_update_record;

    record.asset_types_borrowed.do_ref!(|asset_type| {
        assert!(record.asset_types_updated.contains(*asset_type), ERR_USD_VALUE_NOT_UPDATED);
        assert!(*record.asset_types_updated.borrow(*asset_type), ERR_USD_VALUE_NOT_UPDATED);
    });
}

// * @dev Clear all temporary records during operation after the operation is finished
public(package) fun clear_op_value_update_record<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_enabled();

    // Table clear: remove all elements
    let record = &mut self.op_value_update_record;
    record.asset_types_borrowed.do_ref!(|asset_type| {
        record.asset_types_updated.remove(*asset_type);
    });

    // Vector clear: push all elements out
    while (record.asset_types_borrowed.length() > 0) {
        record.asset_types_borrowed.pop_back();
    };

    record.value_update_enabled = false;
}

public(package) fun enable_op_value_update<PrincipalCoinType>(self: &mut Vault<PrincipalCoinType>) {
    self.check_version();
    self.assert_enabled();

    self.op_value_update_record.value_update_enabled = true;
}

// --------------  Global State Getters  --------------//

// * @dev Share Ratio = Total Assets USD Value / Total Shares
// *      The usd value of each asset need to be updated within MAX_UPDATE_INTERVAL
// *      The correct process is to call the update function of each asset and then call this function
public(package) fun get_total_usd_value<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    clock: &Clock,
): u256 {
    self.check_version();
    self.assert_enabled();

    let now = clock.timestamp_ms();
    let mut total_usd_value = 0;

    self.asset_types.do_ref!(|asset_type| {
        let last_update_time = *self.assets_value_updated.borrow(*asset_type);
        assert!(now - last_update_time <= MAX_UPDATE_INTERVAL, ERR_USD_VALUE_NOT_UPDATED);

        let usd_value = *self.assets_value.borrow(*asset_type);
        total_usd_value = total_usd_value + usd_value;
    });

    emit(TotalUSDValueUpdated {
        vault_id: self.vault_id(),
        total_usd_value: total_usd_value,
        timestamp: now,
    });

    total_usd_value
}

// * @dev Just get the total usd value without checking the update time (not correct & latest value)
public fun get_total_usd_value_without_update<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
): u256 {
    self.check_version();

    let mut total_usd_value = 0;

    self.asset_types.do_ref!(|asset_type| {
        let usd_value = *self.assets_value.borrow(*asset_type);
        total_usd_value = total_usd_value + usd_value;
    });

    total_usd_value
}

public(package) fun get_share_ratio<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    clock: &Clock,
): u256 {
    self.check_version();
    self.assert_enabled();

    if (self.total_shares == 0) {
        return vault_utils::to_decimals(1)
    };

    let total_usd_value = self.get_total_usd_value(clock);
    let share_ratio = vault_utils::div_d(total_usd_value, self.total_shares);

    emit(ShareRatioUpdated {
        vault_id: self.vault_id(),
        share_ratio: share_ratio,
        timestamp: clock.timestamp_ms(),
    });

    share_ratio
}

public fun get_share_ratio_without_update<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
): u256 {
    self.check_version();

    if (self.total_shares == 0) {
        return vault_utils::to_decimals(1)
    };

    let total_usd_value = self.get_total_usd_value_without_update();
    vault_utils::div_d(total_usd_value, self.total_shares)
}

public fun get_asset_value<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    asset_type: String,
): (u256, u64) {
    self.check_version();

    let usd_value = *self.assets_value.borrow(asset_type);
    let last_update_time = *self.assets_value_updated.borrow(asset_type);
    (usd_value, last_update_time)
}

// -----------------  Asset Type  -----------------//

public(package) fun contains_asset_type<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    asset_type: String,
): bool {
    self.inner_assets().contains(asset_type)
}

public(package) fun set_new_asset_type<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
) {
    self.check_version();
    // self.assert_normal();
    self.assert_enabled();

    assert!(!self.asset_types.contains(&asset_type), ERR_ASSET_TYPE_ALREADY_EXISTS);

    self.asset_types.push_back(asset_type);
    self.assets_value.add(asset_type, 0);
    self.assets_value_updated.add(asset_type, 0);

    emit(NewAssetTypeAdded {
        vault_id: self.vault_id(),
        asset_type: asset_type,
    });
}

public(package) fun add_new_defi_asset<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    idx: u8,
    asset: AssetType,
) {
    self.check_version();
    // self.assert_normal();
    self.assert_enabled();

    let asset_type = vault_utils::parse_key<AssetType>(idx);
    set_new_asset_type(self, asset_type);
    self.inner_assets_mut().add<String, AssetType>(asset_type, asset);
}

// Remove a supported defi asset from the vault (only by operator)
// The asset must be added by mistake
public(package) fun remove_defi_asset_support<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    idx: u8,
): AssetType {
    self.check_version();
    self.assert_normal();

    let asset_type = vault_utils::parse_key<AssetType>(idx);

    let (contains, index) = self.asset_types.index_of(&asset_type);
    assert!(contains, ERR_ASSET_TYPE_NOT_FOUND);
    self.asset_types.remove(index);

    let asset_value = self.assets_value[asset_type];
    let asset_value_updated = self.assets_value_updated[asset_type];
    assert!(asset_value == 0 || asset_value_updated == 0, ERR_ASSET_TYPE_NOT_FOUND);

    emit(DefiAssetRemoved {
        vault_id: self.vault_id(),
        asset_type: asset_type,
    });

    self.inner_assets_mut().remove<String, AssetType>(asset_type)
}

public(package) fun borrow_defi_asset<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
): AssetType {
    self.check_version();
    self.assert_enabled();

    assert!(contains_asset_type(self, asset_type), ERR_ASSET_TYPE_NOT_FOUND);

    if (self.status() == VAULT_DURING_OPERATION_STATUS) {
        self.op_value_update_record.asset_types_borrowed.push_back(asset_type);
    };

    emit(DefiAssetBorrowed {
        vault_id: self.vault_id(),
        asset_type: asset_type,
    });

    self.inner_assets_mut().remove<String, AssetType>(asset_type)
}

public(package) fun return_defi_asset<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    asset: AssetType,
) {
    self.check_version();

    emit(DefiAssetReturned {
        vault_id: self.vault_id(),
        asset_type: asset_type,
    });

    self.inner_assets_mut().add<String, AssetType>(asset_type, asset);
}

// deprecated
#[allow(unused_variable)]
public fun get_defi_asset<PrincipalCoinType, AssetType: key + store>(
    self: &Vault<PrincipalCoinType>,
    asset_type: String,
): &AssetType {
    abort 0
}

public(package) fun get_defi_asset_inner<PrincipalCoinType, AssetType: key + store>(
    self: &Vault<PrincipalCoinType>,
    asset_type: String,
): &AssetType {
    self.inner_assets().borrow<String, AssetType>(asset_type)
}

// ---------- Inner Assets ---------- //
fun inner_assets<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): &Bag {
    dynamic_field::borrow<InnerAssetsKey, Bag>(&self.id, InnerAssetsKey {})
}

fun inner_assets_mut<PrincipalCoinType>(self: &mut Vault<PrincipalCoinType>): &mut Bag {
    dynamic_field::borrow_mut<InnerAssetsKey, Bag>(&mut self.id, InnerAssetsKey {})
}

public fun init_inner_assets_by_admin<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    _: &AdminCap,
    ctx: &mut TxContext,
) {
    self.init_inner_assets(ctx)
}

fun init_inner_assets<PrincipalCoinType>(self: &mut Vault<PrincipalCoinType>, ctx: &mut TxContext) {
    dynamic_field::add<InnerAssetsKey, Bag>(&mut self.id, InnerAssetsKey {}, bag::new(ctx));
}

public fun migrate_defi_asset<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    _: &AdminCap,
) {
    self.check_version();

    let asset = self.assets.remove<String, AssetType>(asset_type);
    self.inner_assets_mut().add(asset_type, asset);
}

public fun migrate_coin_type_asset<PrincipalCoinType, CoinType>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    _: &AdminCap,
) {
    self.check_version();

    let asset = self.assets.remove<String, Balance<CoinType>>(asset_type);
    self.inner_assets_mut().add(asset_type, asset);
}

//------------- Coin-Type Asset -----------------//
// Add a new supported asset type to the vault
// Every asset must be added to the vault before it can be used for the investment strategy
public(package) fun add_new_coin_type_asset<PrincipalCoinType, AssetType>(
    self: &mut Vault<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_normal();
    assert!(
        type_name::get<AssetType>() != type_name::get<PrincipalCoinType>(),
        ERR_INVALID_COIN_ASSET_TYPE,
    );

    let asset_type = type_name::get<AssetType>().into_string();
    set_new_asset_type(self, asset_type);

    // Add the asset to the assets table (initial as 0 balance)
    self.inner_assets_mut().add(asset_type, balance::zero<AssetType>());
}

public(package) fun remove_coin_type_asset<PrincipalCoinType, AssetType>(
    self: &mut Vault<PrincipalCoinType>,
) {
    self.check_version();
    self.assert_normal();
    assert!(
        type_name::get<AssetType>() != type_name::get<PrincipalCoinType>(),
        ERR_INVALID_COIN_ASSET_TYPE,
    );

    let asset_type = type_name::get<AssetType>().into_string();

    let (contains, index) = self.asset_types.index_of(&asset_type);
    assert!(contains, ERR_ASSET_TYPE_NOT_FOUND);
    self.asset_types.remove(index);

    // The coin type asset must have 0 balance
    let removed_balance = self.inner_assets_mut().remove<String, Balance<AssetType>>(asset_type);
    removed_balance.destroy_zero();

    self.assets_value.remove(asset_type);
    self.assets_value_updated.remove(asset_type);

    emit(CoinTypeAssetRemoved {
        vault_id: self.vault_id(),
        asset_type: asset_type,
    });
}

// Borrow a coin-type asset from the vault (during an op, only by operator)
public(package) fun borrow_coin_type_asset<PrincipalCoinType, AssetType>(
    self: &mut Vault<PrincipalCoinType>,
    amount: u64,
): Balance<AssetType> {
    self.check_version();
    self.assert_enabled();

    let asset_type = type_name::get<AssetType>().into_string();

    if (self.status() == VAULT_DURING_OPERATION_STATUS) {
        self.op_value_update_record.asset_types_borrowed.push_back(asset_type);
    };

    let current_balance = self
        .inner_assets_mut()
        .borrow_mut<String, Balance<AssetType>>(asset_type);
    current_balance.split(amount)
}

// Return a coin-type asset to the vault (only by operator)
// The asset type should already be added to the vault
public(package) fun return_coin_type_asset<PrincipalCoinType, AssetType>(
    self: &mut Vault<PrincipalCoinType>,
    amount: Balance<AssetType>,
) {
    self.check_version();
    self.assert_enabled();

    let asset_type = type_name::get<AssetType>().into_string();

    let current_balance = self
        .inner_assets_mut()
        .borrow_mut<String, Balance<AssetType>>(asset_type);
    current_balance.join(amount);
}

// ---------------------  Deposit & Withdraw Fee  ---------------------//

// Retrieve deposit & withdraw fee from the vault in the form of principal coin
// Only called by the admin
public(package) fun retrieve_deposit_withdraw_fee<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    amount: u64,
): Balance<PrincipalCoinType> {
    self.check_version();
    self.assert_normal();

    emit(DepositWithdrawFeeRetrieved {
        vault_id: self.vault_id(),
        amount: amount,
    });

    self.deposit_withdraw_fee_collected.split(amount)
}

// ---------------------  Claimable Principal  ---------------------//

public fun add_claimable_principal<T>(self: &mut Vault<T>, balance: Balance<T>) {
    self.check_version();
    self.assert_normal();

    emit(ClaimablePrincipalAdded {
        vault_id: self.vault_id(),
        amount: balance.value(),
    });

    self.claimable_principal.join(balance);
}

public(package) fun claim_claimable_principal<T>(
    self: &mut Vault<T>,
    receipt_id: address,
    amount: u64,
): Balance<T> {
    self.check_version();
    self.assert_normal();

    let vault_receipt = self.receipts.borrow_mut(receipt_id);

    let claimable_amount = vault_receipt.claimable_principal();
    assert!(claimable_amount >= amount, ERR_INSUFFICIENT_CLAIMABLE_PRINCIPAL);
    assert!(self.claimable_principal.value() >= amount, ERR_INSUFFICIENT_CLAIMABLE_PRINCIPAL);

    vault_receipt.update_after_claim_principal(amount);

    emit(ClaimablePrincipalClaimed {
        vault_id: self.vault_id(),
        receipt_id: receipt_id,
        amount: amount,
    });

    self.claimable_principal.split(amount)
}

// -------------- Vault Receipt Info  --------------//

public(package) fun contains_vault_receipt_info<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    receipt_id: address,
): bool {
    self.receipts.contains(receipt_id)
}

public(package) fun add_vault_receipt_info<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    receipt_id: address,
    vault_receipt_info: VaultReceiptInfo,
) {
    self.check_version();
    self.assert_normal();

    self.receipts.add(receipt_id, vault_receipt_info);
}

// ---------------------  Getters  ---------------------//

public fun vault_id<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): address {
    self.id.to_address()
}

public fun status<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u8 {
    self.status
}

public fun cur_epoch<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.cur_epoch
}

public fun cur_epoch_loss<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u256 {
    self.cur_epoch_loss
}

public fun loss_tolerance<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u256 {
    self.loss_tolerance
}

public fun total_shares<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u256 {
    self.total_shares
}

public fun deposit_fee_rate<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.deposit_fee_rate
}

public fun withdraw_fee_rate<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.withdraw_fee_rate
}

public fun deposit_withdraw_fee_collected<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.deposit_withdraw_fee_collected.value()
}

public fun reward_manager_id<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): address {
    self.reward_manager
}

public fun deposit_coin_buffer<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    request_id: u64,
): &Coin<PrincipalCoinType> {
    let request_buffer = &self.request_buffer;
    assert!(request_buffer.deposit_coin_buffer.contains(request_id), ERR_COIN_BUFFER_NOT_FOUND);
    &request_buffer.deposit_coin_buffer[request_id]
}

public fun deposit_request<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    request_id: u64,
): &DepositRequest {
    let request_buffer = &self.request_buffer;
    assert!(request_buffer.deposit_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);
    &request_buffer.deposit_requests[request_id]
}

public fun withdraw_request<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    request_id: u64,
): &WithdrawRequest {
    let request_buffer = &self.request_buffer;
    assert!(request_buffer.withdraw_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);
    &request_buffer.withdraw_requests[request_id]
}

public fun operator_id(self: &OperatorCap): address {
    self.id.to_address()
}

public fun free_principal<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.free_principal.value()
}

public fun claimable_principal<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.claimable_principal.value()
}

public fun deposit_id_count<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    let request_buffer = &self.request_buffer;
    request_buffer.deposit_id_count
}

public fun withdraw_id_count<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    let request_buffer = &self.request_buffer;
    request_buffer.withdraw_id_count
}

public fun vault_receipt_info<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    receipt_id: address,
): &VaultReceiptInfo {
    let vault_receipt = self.receipts.borrow(receipt_id);
    vault_receipt
}

public(package) fun vault_receipt_info_mut<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    receipt_id: address,
): &mut VaultReceiptInfo {
    let vault_receipt = self.receipts.borrow_mut(receipt_id);
    vault_receipt
}

public fun op_value_update_record<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
): &OperationValueUpdateRecord {
    &self.op_value_update_record
}

public fun op_value_update_record_assets_borrowed(
    record: &OperationValueUpdateRecord,
): &vector<String> {
    &record.asset_types_borrowed
}

public fun op_value_update_record_assets_updated(
    record: &OperationValueUpdateRecord,
): &Table<String, bool> {
    &record.asset_types_updated
}

public fun op_value_update_record_value_update_enabled(record: &OperationValueUpdateRecord): bool {
    record.value_update_enabled
}

public fun locking_time_for_withdraw<PrincipalCoinType>(self: &Vault<PrincipalCoinType>): u64 {
    self.locking_time_for_withdraw
}

public fun locking_time_for_cancel_request<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
): u64 {
    self.locking_time_for_cancel_request
}

// ---------------------  Test Functions  ---------------------//

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public(package) fun deposit_request_mut<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    request_id: u64,
): &mut DepositRequest {
    let request_buffer = &mut self.request_buffer;
    assert!(request_buffer.deposit_requests.contains(request_id), ERR_REQUEST_NOT_FOUND);
    &mut request_buffer.deposit_requests[request_id]
}

#[test_only]
public fun set_total_shares<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    total_shares: u256,
) {
    self.total_shares = total_shares;
}

#[test_only]
public fun set_vault_receipt_info<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    receipt_id: address,
    vault_receipt_info: VaultReceiptInfo,
) {
    self.receipts.add(receipt_id, vault_receipt_info);
}

#[test_only]
public fun set_asset_value<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    value: u256,
    last_update_time: u64,
) {
    *self.assets_value.borrow_mut(asset_type) = value;
    *self.assets_value_updated.borrow_mut(asset_type) = last_update_time;
}

#[test_only]
public fun remove_claimable_principal<T>(self: &mut Vault<T>, amount: u64): Balance<T> {
    self.claimable_principal.split(amount)
}

#[test_only]
public fun add_legacy_defi_asset_for_testing<PrincipalCoinType, AssetType: key + store>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    asset: AssetType,
) {
    self.assets.add<String, AssetType>(asset_type, asset);
}

#[test_only]
public fun legacy_assets_contains<PrincipalCoinType>(
    self: &Vault<PrincipalCoinType>,
    asset_type: String,
): bool {
    self.assets.contains<String>(asset_type)
}

#[test_only]
public fun set_new_asset_type_for_testing<PrincipalCoinType>(
    self: &mut Vault<PrincipalCoinType>,
    asset_type: String,
) {
    set_new_asset_type(self, asset_type);
}
