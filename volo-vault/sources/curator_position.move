// ^(v1.1 upgrade - new)
module volo_vault::curator_position;

use std::ascii::String;
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event::emit;
use sui::table::{Self, Table};
use volo_vault::vault::{Self, AdminCap, OperatorCap, Vault, Operation};
use volo_vault::vault_oracle::{Self, OracleConfig};
use volo_vault::vault_utils;

// const VERSION: u64 = 1;
const VERSION: u64 = 3;

const DEFAULT_VALUE_SUBMISSION_MIN_INTERVAL: u64 = 10 * 60 * 1_000; // 10 minutes
const MINIMUM_POSITION_VALUE_VALID_TIME: u64 = 60 * 60 * 1_000; // 1 hour

const ERR_CURATOR_CAP_NOT_FOUND: u64 = 8_001;
const ERR_CURATOR_CAP_ALREADY_EXISTS: u64 = 8_002;
const ERR_CURATOR_CAP_NOT_PAIRED: u64 = 8_003;
const ERR_CURATOR_CAP_PAIRED_WITH_WRONG_POSITION_ID: u64 = 8_004;
const ERR_CURATOR_CAP_ALREADY_PAIRED: u64 = 8_005;
const ERR_CURATOR_POSITION_VALUE_NOT_VALID: u64 = 8_006;
const ERR_POSITION_VALUE_EXPIRED: u64 = 8_007;
const ERR_INVALID_VERSION: u64 = 8_008;
const ERR_SAME_CURATOR_ADDRESS: u64 = 8_009;
const ERR_VALUE_SUBMISSION_TOO_LATE: u64 = 8_010;
const ERR_CURATOR_POSITION_NOT_PAIRED_WITH_VAULT: u64 = 8_011;
const ERR_POSITION_VALUE_VALID_TIME_TOO_SHORT: u64 = 8_012;

// --------------------- Events --------------------- //

public struct CuratorConfigUpgraded has copy, drop {
    curator_config_id: address,
    version: u64,
}

public struct CuratorCapCreated has copy, drop {
    curator_cap_id: address,
    curator: address,
}

public struct CuratorCapInfoTransferred has copy, drop {
    curator_cap_id: address,
    old_curator: address,
    new_curator: address,
}

public struct CuratorPositionCreated has copy, drop {
    curator_position_id: address,
    curator_cap_id: address,
    init_curator: address,
}

public struct CuratorCapAdded has copy, drop { curator_cap_id: address }

public struct CuratorCapRemoved has copy, drop { curator_cap_id: address }

public struct CuratorCapPairedWithPosition has copy, drop {
    curator_cap_id: address,
    curator_position_id: address,
}

public struct CuratorCapRemovedFromPosition has copy, drop {
    curator_cap_id: address,
    curator_position_id: address,
}

public struct CuratorPositionValueSubmitted has copy, drop {
    curator_position_id: address,
    curator_cap_id: address,
    position_value: u256,
    timestamp_ms: u64,
    valid_time: u64,
}

public struct CuratorPositionValueApproved has copy, drop {
    curator_position_id: address,
    position_value: u256,
}

public struct CuratorPositionValueDenied has copy, drop {
    curator_position_id: address,
    position_value: u256,
}

public struct CuratorPositionLoopedIn has copy, drop {
    curator_position_id: address,
    curator_cap_id: address,
    curator: address,
    principal_coin_type: TypeName,
    principal_amount: u64,
    total_usd_value: u256,
    total_shares: u256,
}

public struct CuratorPositionLoopedOut has copy, drop {
    curator_position_id: address,
    curator_cap_id: address,
    curator: address,
    principal_coin_type: TypeName,
    principal_amount: u64,
    total_usd_value: u256,
    total_shares: u256,
}

public struct CuratorPositionValueUpdated has copy, drop {
    curator_position_id: address,
    position_value: u256,
    timestamp_ms: u64,
}

public struct ValueSubmissionMinIntervalSet has copy, drop {
    value_submission_min_interval: u64,
}

// --------------------- Structs --------------------- //

public struct CuratorCap has key, store {
    id: UID,
    curator: address,
}

// Curation Positon -> [curator, curator, ...]
public struct CuratorPosition has key, store {
    id: UID,
}

public struct CuratorConfig has key, store {
    id: UID,
    version: u64,
    value_submission_min_interval: u64,
    // Curators info
    valid_curator_caps: Table<address, bool>, // All valid curator addresses
    curator_position_pairs: Table<address, address>, // Curator Cap ID -> CuratorPosition ID
    // Curator Cap Info
    curator_cap_to_curator: Table<address, address>, // Curator Cap ID -> Curator Address
    // Curator positions info
    curator_position_values: Table<address, CuratorPositionValue>, // Curator Position ID -> CuratorPositionValue
    curator_position_to_vault: Table<address, address>, // Curator Position ID -> Vault ID
    curator_position_to_curator_caps: Table<address, vector<address>>, // Curator Position ID -> Curator Cap Ids
    // Claimable Balance for Curator Position
    curator_position_claimable_balance: Bag, // Curator Position ID -> Claimable Balance
}

public struct CuratorPositionValue has copy, drop, store {
    position_value: u256,
    position_value_updated: u64,
    position_value_valid_time: u64,
    valid: bool,
}

// --------------------- Init --------------------- //

public(package) fun init_curator_config(ctx: &mut TxContext) {
    let valid_curator_caps = table::new<address, bool>(ctx);
    let curator_position_pairs = table::new<address, address>(ctx);
    let curator_cap_to_curator = table::new<address, address>(ctx);
    let curator_position_values = table::new<address, CuratorPositionValue>(ctx);
    let curator_position_to_vault = table::new<address, address>(ctx);
    let curator_position_to_curator_caps = table::new<address, vector<address>>(ctx);
    let curator_position_claimable_balance = bag::new(ctx);

    transfer::share_object(CuratorConfig {
        id: object::new(ctx),
        version: VERSION,
        value_submission_min_interval: DEFAULT_VALUE_SUBMISSION_MIN_INTERVAL,
        valid_curator_caps: valid_curator_caps,
        curator_position_pairs: curator_position_pairs,
        curator_cap_to_curator: curator_cap_to_curator,
        curator_position_values: curator_position_values,
        curator_position_to_vault: curator_position_to_vault,
        curator_position_to_curator_caps: curator_position_to_curator_caps,
        curator_position_claimable_balance: curator_position_claimable_balance,
    });
}

public(package) fun upgrade_curator_config(self: &mut CuratorConfig) {
    assert!(self.version < VERSION, ERR_INVALID_VERSION);
    self.version = VERSION;

    emit(CuratorConfigUpgraded {
        curator_config_id: self.id.to_address(),
        version: VERSION,
    });
}

public(package) fun check_version(self: &CuratorConfig) {
    assert!(self.version == VERSION, ERR_INVALID_VERSION);
}

public fun create_curator_cap(
    self: &mut CuratorConfig,
    _: &AdminCap,
    init_curator: address,
    ctx: &mut TxContext,
): CuratorCap {
    self.check_version();
    
    let id = object::new(ctx);
    let id_address = object::uid_to_address(&id);
    let cap = CuratorCap { id: id, curator: init_curator };

    self.curator_cap_to_curator.add(id_address, init_curator);

    emit(CuratorCapCreated {
        curator_cap_id: id_address,
        curator: init_curator,
    });
    cap
}

public fun create_curator_position_with_auto_transfer<PrincipalCoinType>(
    self: &mut CuratorConfig,
    admin_cap: &AdminCap,
    curator_cap: CuratorCap,
    vault: &Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    self.check_version();

    let curator_cap_id = curator_cap.curator_cap_id();
    let init_curator_address = self.curator_cap_to_curator(curator_cap_id);

    let curator_position = self.create_curator_position(
        admin_cap,
        curator_cap,
        vault,
        ctx,
    );

    transfer::public_transfer(curator_position, init_curator_address);
}

// @notice Create a new curator position and transfer the curator cap to the init curator address
//
//         This function can be called by admin, after admin creates the curator cap
//         `create_curator_cap`
//          -> admin holds the Cap
//          -> `create_curator_position`
//          -> admin transfers the Cap to the init curator address
//          -> init curator address can use the Cap to loop in and out the position
public fun create_curator_position<PrincipalCoinType>(
    self: &mut CuratorConfig,
    _: &AdminCap,
    curator_cap: CuratorCap,
    vault: &Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
): CuratorPosition {
    self.check_version();

    let id = object::new(ctx);
    let id_address = object::uid_to_address(&id);

    let vault_id = vault.vault_id();

    let curator_cap_id = curator_cap.curator_cap_id();
    let init_curator_address = curator_cap.curator_cap_curator_address();

    let curator_position = CuratorPosition {
        id: id,
    };

    // Init curator position info
    self.curator_position_to_vault.add(id_address, vault_id);
    self.curator_position_to_curator_caps.add(id_address, vector::singleton(curator_cap_id));
    self
        .curator_position_values
        .add(
            id_address,
            CuratorPositionValue {
                position_value: 0,
                position_value_updated: 0,
                position_value_valid_time: 0,
                valid: false,
            },
        );

    self.set_curator_cap_paired_with_position(
        id_address,
        curator_cap_id,
    );
    self
        .curator_position_claimable_balance
        .add<address, Balance<PrincipalCoinType>>(id_address, balance::zero<PrincipalCoinType>());

    transfer::public_transfer(curator_cap, init_curator_address);

    emit(CuratorPositionCreated {
        curator_position_id: id_address,
        curator_cap_id: curator_cap_id,
        init_curator: init_curator_address,
    });

    curator_position
}

public(package) fun add_curator_cap(self: &mut CuratorConfig, curator_cap_id: address) {
    self.check_version();

    let valid_curator_caps = &mut self.valid_curator_caps;
    assert!(!valid_curator_caps.contains(curator_cap_id), ERR_CURATOR_CAP_ALREADY_EXISTS);

    valid_curator_caps.add(curator_cap_id, true);

    emit(CuratorCapAdded {
        curator_cap_id: curator_cap_id,
    });
}

public(package) fun set_curator_cap_paired_with_position(
    self: &mut CuratorConfig,
    curator_position_id: address,
    curator_cap_id: address,
) {
    self.check_version();

    let curator_position_pairs = &mut self.curator_position_pairs;
    let curator_position_to_curator_caps = &mut self.curator_position_to_curator_caps;

    assert!(!curator_position_pairs.contains(curator_cap_id), ERR_CURATOR_CAP_ALREADY_PAIRED);
    curator_position_pairs.add(curator_cap_id, curator_position_id);

    if (!curator_position_to_curator_caps.contains(curator_position_id)) {
        curator_position_to_curator_caps.add(curator_position_id, vector::empty<address>());
    };
    curator_position_to_curator_caps.borrow_mut(curator_position_id).push_back(curator_cap_id);

    emit(CuratorCapPairedWithPosition {
        curator_cap_id: curator_cap_id,
        curator_position_id: curator_position_id,
    });
}

public(package) fun remove_curator_cap_paired_with_position(
    self: &mut CuratorConfig,
    curator_position_id: address,
    curator_cap_id: address,
) {
    self.check_version();

    let curator_position_pairs = &mut self.curator_position_pairs;
    assert!(curator_position_pairs.contains(curator_cap_id), ERR_CURATOR_CAP_NOT_PAIRED);
    assert!(
        curator_position_pairs[curator_cap_id] == curator_position_id,
        ERR_CURATOR_CAP_PAIRED_WITH_WRONG_POSITION_ID,
    );

    curator_position_pairs.remove(curator_cap_id);

    emit(CuratorCapRemovedFromPosition {
        curator_cap_id: curator_cap_id,
        curator_position_id: curator_position_id,
    });
}

public(package) fun remove_curator_cap(self: &mut CuratorConfig, curator_cap_id: address) {
    self.check_version();

    let valid_curator_caps = &mut self.valid_curator_caps;
    assert!(valid_curator_caps.contains(curator_cap_id), ERR_CURATOR_CAP_NOT_FOUND);

    valid_curator_caps.remove(curator_cap_id);

    let curator_position_id = self.curator_cap_paired_position(curator_cap_id);
    self.remove_curator_cap_paired_with_position(
        curator_position_id,
        curator_cap_id,
    );

    emit(CuratorCapRemoved {
        curator_cap_id: curator_cap_id,
    });
}

public fun submit_curator_position_value(
    self: &mut CuratorConfig,
    curator_cap: &CuratorCap,
    curator_position_id: address,
    position_value: u256,
    valid_time: u64,
    clock: &Clock,
) {
    self.check_version();

    // Must be a valid curator cap and paired with the position
    let curator_cap_id = curator_cap.curator_cap_id();
    self.assert_valid_curator_cap(curator_position_id, curator_cap_id);

    let now = clock.timestamp_ms();
    assert!(valid_time >= MINIMUM_POSITION_VALUE_VALID_TIME, ERR_POSITION_VALUE_VALID_TIME_TOO_SHORT);

    self.update_position_value(
        curator_position_id,
        position_value,
        now,
        valid_time,
    );

    emit(CuratorPositionValueSubmitted {
        curator_position_id: curator_position_id,
        curator_cap_id: curator_cap_id,
        position_value: position_value,
        timestamp_ms: now,
        valid_time: valid_time,
    });
}

public fun validate_curator_position_value(
    self: &mut CuratorConfig,
    operation: &Operation,
    operator_cap: &OperatorCap,
    curator_position_id: address,
    approved: bool,
    clock: &Clock,
) {
    self.check_version();

    let now = clock.timestamp_ms();

    let vault_id = self.curator_position_to_vault[curator_position_id];

    vault::assert_operator_not_freezed(operation, operator_cap);
    vault::assert_single_vault_operator_paired(operation, vault_id, operator_cap);

    let curator_position_values = &mut self.curator_position_values;
    let curator_position_value = curator_position_values.borrow_mut(curator_position_id);

    assert!(
        curator_position_value.position_value_updated + self.value_submission_min_interval <= now,
        ERR_VALUE_SUBMISSION_TOO_LATE,
    );

    if (approved) {
        curator_position_value.valid = true;

        emit(CuratorPositionValueApproved {
            curator_position_id: curator_position_id,
            position_value: curator_position_value.position_value,
        });
    } else {
        curator_position_value.valid = false;

        emit(CuratorPositionValueDenied {
            curator_position_id: curator_position_id,
            position_value: curator_position_value.position_value,
        });
    }
}

public fun transfer_curator_cap_info(
    self: &mut CuratorConfig,
    mut curator_cap: CuratorCap,
    new_curator: address,
) {
    self.check_version();

    let curator_cap_id = curator_cap.curator_cap_id();
    let old_curator = curator_cap.curator_cap_curator_address();

    assert!(old_curator != new_curator, ERR_SAME_CURATOR_ADDRESS);

    let curator_mut = self.curator_cap_to_curator.borrow_mut(curator_cap_id);
    *curator_mut = new_curator;

    curator_cap.transfer_curator(new_curator);

    transfer::public_transfer(curator_cap, new_curator);

    emit(CuratorCapInfoTransferred {
        curator_cap_id: curator_cap_id,
        old_curator: old_curator,
        new_curator: new_curator,
    });
}

// ------- Update Functions ------- //

public fun update_curator_position_value<PrincipalCoinType>(
    self: &mut CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    asset_type: String,
    curator_position_id: address,
    oracle_config: &OracleConfig,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();

    assert!(self.curator_position_to_vault[curator_position_id] == vault.vault_id(), ERR_CURATOR_POSITION_NOT_PAIRED_WITH_VAULT);
    self.assert_valid_curator_position_value(curator_position_id, now);

    let principal_based_position_value = self.position_value(curator_position_id);
    let principal_price = vault_oracle::get_normalized_asset_price(
        oracle_config,
        clock,
        type_name::with_defining_ids<PrincipalCoinType>().into_string(),
    );
    let position_value = vault_utils::mul_with_oracle_price(
        principal_based_position_value,
        principal_price,
    );

    vault.finish_update_asset_value(asset_type, position_value, now);

    emit(CuratorPositionValueUpdated {
        curator_position_id: curator_position_id,
        position_value: position_value,
        timestamp_ms: now,
    });
}

public(package) fun update_position_value(
    self: &mut CuratorConfig,
    curator_position_id: address,
    position_value: u256,
    timestamp: u64,
    valid_time: u64,
) {
    self.check_version();

    let curator_position_values = &mut self.curator_position_values;
    let curator_position_value = curator_position_values.borrow_mut(curator_position_id);

    curator_position_value.valid = false;
    curator_position_value.position_value = position_value;
    curator_position_value.position_value_updated = timestamp;
    curator_position_value.position_value_valid_time = valid_time;
}

public(package) fun transfer_curator(curator_cap: &mut CuratorCap, new_curator: address) {
    curator_cap.curator = new_curator;
}

public(package) fun set_value_submission_min_interval(self: &mut CuratorConfig, value_submission_min_interval: u64) {
    self.check_version();
    self.value_submission_min_interval = value_submission_min_interval;

    emit(ValueSubmissionMinIntervalSet {
        value_submission_min_interval: value_submission_min_interval,
    });
}

// ------- Curator Operation ------- //

public fun loop_in_curator_position_with_claimable_balance<PrincipalCoinType>(
    self: &mut CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    operator_cap: &OperatorCap,
    curator_cap_id: address,
    defi_asset_id: u8,
    principal_amount: u64,
) {
    self.check_version();

    vault::assert_operator_not_freezed(operation, operator_cap);
    vault::assert_single_vault_operator_paired(operation, vault.vault_id(), operator_cap);

    let curator_position_asset_type = vault_utils::parse_key<CuratorPosition>(defi_asset_id);
    let curator_position = vault.borrow_defi_asset<PrincipalCoinType, CuratorPosition>(
        curator_position_asset_type,
    );

    let curator_position_id = curator_position.id.to_address();
    self.assert_valid_curator_cap(curator_position_id, curator_cap_id);

    vault.return_defi_asset(curator_position_asset_type, curator_position);

    let principal_balance = if (principal_amount > 0) {
        vault.borrow_free_principal(principal_amount)
    } else {
        balance::zero<PrincipalCoinType>()
    };
    let curator_address = self.curator_cap_to_curator(curator_cap_id);

    let curator_position_claimable_balance = self
        .curator_position_claimable_balance
        .borrow_mut<address, Balance<PrincipalCoinType>>(curator_position_id);
    curator_position_claimable_balance.join(principal_balance);

    let total_usd_value = vault.get_total_usd_value_without_update();
    let total_shares = vault.total_shares();

    emit(CuratorPositionLoopedIn {
        curator_position_id: curator_position_id,
        curator_cap_id: curator_cap_id,
        curator: curator_address,
        principal_coin_type: type_name::with_defining_ids<PrincipalCoinType>(),
        principal_amount: principal_amount,
        total_usd_value: total_usd_value,
        total_shares: total_shares,
    })
}

public fun claim_curator_position_claimable_balance<PrincipalCoinType>(
    self: &mut CuratorConfig,
    curator_position_id: address,
    curator_cap: &CuratorCap,
    amount: u64,
): Balance<PrincipalCoinType> {
    self.check_version();

    let curator_cap_id = curator_cap.curator_cap_id();
    self.assert_valid_curator_cap(curator_position_id, curator_cap_id);

    let mut curator_position_claimable_balance = self
        .curator_position_claimable_balance
        .remove<address, Balance<PrincipalCoinType>>(curator_position_id);

    let claimed_balance = curator_position_claimable_balance.split(amount);

    // Add back the remaining balance to the bag
    self
        .curator_position_claimable_balance
        .add(curator_position_id, curator_position_claimable_balance);

    claimed_balance
}

// Directly loop assets into curator address
public fun loop_in_curator_position<PrincipalCoinType>(
    self: &mut CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    operator_cap: &OperatorCap,
    curator_cap_id: address,
    defi_asset_id: u8,
    principal_amount: u64,
    ctx: &mut TxContext,
) {
    self.check_version();

    vault::assert_operator_not_freezed(operation, operator_cap);
    vault::assert_single_vault_operator_paired(operation, vault.vault_id(), operator_cap);

    let curator_position_asset_type = vault_utils::parse_key<CuratorPosition>(defi_asset_id);
    let curator_position = vault.borrow_defi_asset<PrincipalCoinType, CuratorPosition>(
        curator_position_asset_type,
    );

    let curator_position_id = curator_position.id.to_address();
    self.assert_valid_curator_cap(curator_position_id, curator_cap_id);

    vault.return_defi_asset(curator_position_asset_type, curator_position);

    let principal_balance = if (principal_amount > 0) {
        vault.borrow_free_principal(principal_amount)
    } else {
        balance::zero<PrincipalCoinType>()
    };
    let curator_address = self.curator_cap_to_curator(curator_cap_id);
    transfer::public_transfer(principal_balance.into_coin(ctx), curator_address);

    let total_usd_value = vault.get_total_usd_value_without_update();
    let total_shares = vault.total_shares();

    emit(CuratorPositionLoopedIn {
        curator_position_id: curator_position_id,
        curator_cap_id: curator_cap_id,
        curator: curator_address,
        principal_coin_type: type_name::with_defining_ids<PrincipalCoinType>(),
        principal_amount: principal_amount,
        total_usd_value: total_usd_value,
        total_shares: total_shares,
    })
}

public fun loop_out_curator_position<PrincipalCoinType>(
    self: &mut CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    defi_asset_id: u8,
    principal_coin: Coin<PrincipalCoinType>,
    curator_cap: &CuratorCap
) {
    self.check_version();

    // let sender = ctx.sender();
    let curator_cap_id = curator_cap.curator_cap_id();
    self.loop_out_curator_position_internal(
        vault,
        defi_asset_id,
        curator_cap_id,
        principal_coin
    );
}

public fun loop_out_curator_position_by_operator<PrincipalCoinType>(
    self: &mut CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    operator_cap: &OperatorCap,
    defi_asset_id: u8,
    curator_cap_id: address,
    principal_coin: Coin<PrincipalCoinType>
) {
    self.check_version();

    vault::assert_operator_not_freezed(operation, operator_cap);
    vault::assert_single_vault_operator_paired(operation, vault.vault_id(), operator_cap);

    self.loop_out_curator_position_internal(
        vault,
        defi_asset_id,
        curator_cap_id,
        principal_coin
    );
}

public(package) fun loop_out_curator_position_internal<PrincipalCoinType>(
    self: &CuratorConfig,
    vault: &mut Vault<PrincipalCoinType>,
    defi_asset_id: u8,
    curator_cap_id: address,
    principal_coin: Coin<PrincipalCoinType>
) {
    let principal_amount = principal_coin.value();
    let curator_address = self.curator_cap_to_curator(curator_cap_id);

    let curator_position_asset_type = vault_utils::parse_key<CuratorPosition>(defi_asset_id);
    let curator_position = vault.borrow_defi_asset<PrincipalCoinType, CuratorPosition>(
        curator_position_asset_type,
    );

    let curator_position_id = curator_position.id.to_address();
    self.assert_valid_curator_cap(curator_position_id, curator_cap_id);

    vault.return_defi_asset(curator_position_asset_type, curator_position);
    vault.return_free_principal(principal_coin.into_balance());

    let total_usd_value = vault.get_total_usd_value_without_update();
    let total_shares = vault.total_shares();

    emit(CuratorPositionLoopedOut {
        curator_position_id: curator_position_id,
        curator_cap_id: curator_cap_id,
        curator: curator_address,
        principal_coin_type: type_name::with_defining_ids<PrincipalCoinType>(),
        principal_amount: principal_amount,
        total_usd_value: total_usd_value,
        total_shares: total_shares,
    });
}

// ------- Getter Functions ------- //

public fun curator_cap_id(cap: &CuratorCap): address {
    cap.id.to_address()
}

public fun curator_cap_curator_address(cap: &CuratorCap): address {
    cap.curator
}

public fun position_id(curator_position: &CuratorPosition): address {
    curator_position.id.to_address()
}

public fun curator_cap_paired_position(self: &CuratorConfig, curator_cap_id: address): address {
    self.curator_position_pairs[curator_cap_id]
}

public fun curator_cap_to_curator(self: &CuratorConfig, curator_cap_id: address): address {
    self.curator_cap_to_curator[curator_cap_id]
}

public fun position_value_info(
    self: &CuratorConfig,
    curator_position_id: address,
): CuratorPositionValue {
    self.curator_position_values[curator_position_id]
}

public fun position_value(self: &CuratorConfig, curator_position_id: address): u256 {
    self.curator_position_values[curator_position_id].position_value
}

public fun position_value_updated(self: &CuratorConfig, curator_position_id: address): u64 {
    self.curator_position_values[curator_position_id].position_value_updated
}

public fun position_value_valid_time(self: &CuratorConfig, curator_position_id: address): u64 {
    self.curator_position_values[curator_position_id].position_value_valid_time
}

public fun is_valid_curator_cap(self: &CuratorConfig, curator_cap_id: address): bool {
    self.valid_curator_caps.contains(curator_cap_id)
}

// ------- Assert Functions ------- //

// Curator must be:
//  1) a valid curator
//  2) paired with a position
//  3) paired with the correct position
public fun assert_valid_curator_cap(
    self: &CuratorConfig,
    curator_position_id: address,
    curator_cap_id: address,
) {
    self.check_version();

    let valid_curator_caps = &self.valid_curator_caps;
    assert!(valid_curator_caps.contains(curator_cap_id), ERR_CURATOR_CAP_NOT_FOUND);

    assert!(self.curator_position_pairs.contains(curator_cap_id), ERR_CURATOR_CAP_NOT_PAIRED);

    let paired_curator_position = &self.curator_position_pairs[curator_cap_id];
    assert!(
        paired_curator_position == curator_position_id,
        ERR_CURATOR_CAP_PAIRED_WITH_WRONG_POSITION_ID,
    );
}

public fun assert_valid_curator_position_value(
    self: &CuratorConfig,
    curator_position_id: address,
    timestamp: u64,
) {
    self.check_version();

    let curator_position_value = &self.curator_position_values[curator_position_id];

    // The value must: 1) already been approved 2) still in valid time range
    assert!(curator_position_value.valid, ERR_CURATOR_POSITION_VALUE_NOT_VALID);
    assert!(
        curator_position_value.position_value_updated + curator_position_value.position_value_valid_time >= timestamp,
        ERR_POSITION_VALUE_EXPIRED,
    );
}

// ------- Test Helpers ------- //

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    // init_curator_config(ctx);
    let curator_config = create_curator_config_for_testing(ctx);
    transfer::public_share_object(curator_config);
}

#[test_only]
public fun create_curator_config_for_testing(ctx: &mut TxContext): CuratorConfig {
    CuratorConfig {
        id: object::new(ctx),
        version: VERSION,
        value_submission_min_interval: 0,
        valid_curator_caps: table::new<address, bool>(ctx),
        curator_position_pairs: table::new<address, address>(ctx),
        curator_cap_to_curator: table::new<address, address>(ctx),
        curator_position_values: table::new<address, CuratorPositionValue>(ctx),
        curator_position_to_vault: table::new<address, address>(ctx),
        curator_position_to_curator_caps: table::new<address, vector<address>>(ctx),
        curator_position_claimable_balance: bag::new(ctx),
    }
}

#[test_only]
public fun ensure_position_value_entry_for_testing(
    curator_config: &mut CuratorConfig,
    curator_position_id: address,
) {
    if (!curator_config.curator_position_values.contains(curator_position_id)) {
        curator_config
            .curator_position_values
            .add(
                curator_position_id,
                CuratorPositionValue {
                    position_value: 0,
                    position_value_updated: 0,
                    position_value_valid_time: 0,
                    valid: false,
                },
            );
    };
}
