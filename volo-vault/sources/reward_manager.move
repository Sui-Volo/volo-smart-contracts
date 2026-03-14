#[allow(deprecated_usage)]
module volo_vault::reward_manager;

use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::event::emit;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use volo_vault::receipt::{Self, Receipt};
use volo_vault::vault::{Self, Operation, OperatorCap, Vault};
use volo_vault::vault_receipt_info::{Self, VaultReceiptInfo};
use volo_vault::vault_utils;

// * Workflow
// * After creating the vault in "volo_vault.move", create the corresponding RewardManager
// * When the operator trys to distribute rewards (different type of principal coin)
// *    1. Add a new reward type to the RewardManager (can choose to add buffer at the same time)
// *    2. (If step 1 has not choose to add buffer at the same time) Create a new reward buffer distribution for the reward type
// *    3. Add reward balance to vault (immediately distributed & claimable) or reward buffer (distributed linearly later)
// *
// * Concepts
// *    - `reward amount` is with extra 9 decimals
// *    - `reward balance` is with the original decimals of the reward coin
// *    - `reward index` is with 18 decimals

// ---------------------  Constants  ---------------------//

// const VERSION: u64 = 1;
// ^(v1.1 upgrade - new)
const VERSION: u64 = 3;

const NORMAL_STATUS: u8 = 0;

// ---------------------  Errors  ---------------------//

const ERR_REWARD_MANAGER_VAULT_MISMATCH: u64 = 3_001;
const ERR_REWARD_EXCEED_LIMIT: u64 = 3_002;
const ERR_REWARD_BUFFER_TYPE_EXISTS: u64 = 3_003;
const ERR_REWARD_BUFFER_TYPE_NOT_FOUND: u64 = 3_004;
const ERR_REMAINING_REWARD_IN_BUFFER: u64 = 3_005;
const ERR_WRONG_RECEIPT_STATUS: u64 = 3_006;
const ERR_INVALID_VERSION: u64 = 3_007;
const ERR_INSUFFICIENT_REWARD_AMOUNT: u64 = 3_008;
const ERR_INVALID_REWARD_RATE: u64 = 3_009;
const ERR_VAULT_HAS_NO_SHARES: u64 = 3_010;
const ERR_REWARD_TYPE_NOT_FOUND: u64 = 3_011;
const ERR_REWARD_AMOUNT_TOO_SMALL: u64 = 3_012;

// ---------------------  Events  ---------------------//

public struct RewardManagerCreated has copy, drop {
    reward_manager_id: address,
    vault_id: address,
}

public struct RewardTypeAdded has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    coin_type: TypeName,
}

public struct RewardBalanceAdded has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    coin_type: TypeName,
    reward_amount: u256,
}

public struct RewardIndicesUpdated has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    coin_type: TypeName,
    reward_amount: u256,
    inc_reward_index: u256,
    new_reward_index: u256,
}

public struct RewardClaimed has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    receipt_id: address,
    coin_type: TypeName,
    reward_amount: u64,
}

public struct RewardBufferUpdated has copy, drop {
    vault_id: address,
    coin_type: TypeName,
    reward_amount: u256,
}

public struct RewardBufferRateUpdated has copy, drop {
    vault_id: address,
    coin_type: TypeName,
    rate: u256,
}

public struct RewardAddedWithBuffer has copy, drop {
    vault_id: address,
    coin_type: TypeName,
    reward_amount: u256,
}

public struct RewardBufferDistributionCreated has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    coin_type: TypeName,
}

public struct RewardBufferDistributionRemoved has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    coin_type: TypeName,
}

public struct RewardManagerUpgraded has copy, drop {
    reward_manager_id: address,
    version: u64,
}

public struct UndistributedRewardRetrieved has copy, drop {
    reward_manager_id: address,
    vault_id: address,
    reward_type: TypeName,
    amount: u64,
}

// ---------------------  Structs  ---------------------//

public struct RewardManager<phantom PrincipalCoinType> has key, store {
    id: UID,
    version: u64,
    vault_id: address,
    // --- Reward Info --- //
    reward_balances: Bag, // <TypeName, Balance<T>>, Balance of reward coins deposited by the operator
    reward_amounts: Table<TypeName, u256>, // Rewards pending to be distributed to actual rewards (u64)
    reward_indices: VecMap<TypeName, u256>,
    // --- Reward Buffer --- //
    reward_buffer: RewardBuffer,
}

public struct RewardBuffer has store {
    reward_amounts: Table<TypeName, u256>, // Rewards pending to be distributed to actual rewards (u64)
    distributions: VecMap<TypeName, BufferDistribution>,
}

public struct BufferDistribution has copy, drop, store {
    rate: u256,
    last_updated: u64,
}

// ---------------------  Initialization  ---------------------//

public(package) fun create_reward_manager<PrincipalCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    ctx: &mut TxContext,
) {
    let vault_id = vault.vault_id();

    let reward_buffer = RewardBuffer {
        reward_amounts: table::new<TypeName, u256>(ctx),
        distributions: vec_map::empty<TypeName, BufferDistribution>(),
    };

    let reward_manager = RewardManager<PrincipalCoinType> {
        id: object::new(ctx),
        version: VERSION,
        vault_id: vault_id,
        reward_balances: bag::new(ctx),
        reward_amounts: table::new<TypeName, u256>(ctx),
        reward_indices: vec_map::empty<TypeName, u256>(),
        reward_buffer: reward_buffer,
    };

    vault.set_reward_manager(reward_manager.id.to_address());

    emit(RewardManagerCreated {
        reward_manager_id: reward_manager.id.to_address(),
        vault_id: vault_id,
    });

    transfer::share_object(reward_manager);
}

// -------------------  Version & Upgrade  -------------------//

public(package) fun check_version<PrincipalCoinType>(self: &RewardManager<PrincipalCoinType>) {
    assert!(self.version == VERSION, ERR_INVALID_VERSION);
}

public(package) fun upgrade_reward_manager<PrincipalCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
) {
    assert!(self.version < VERSION, ERR_INVALID_VERSION);
    self.version = VERSION;

    emit(RewardManagerUpgraded {
        reward_manager_id: self.id.to_address(),
        version: VERSION,
    });
}

// ---------------------  Issue Receipt  ---------------------//

public(package) fun issue_receipt<T>(self: &RewardManager<T>, ctx: &mut TxContext): Receipt {
    self.check_version();

    receipt::create_receipt(
        self.vault_id,
        ctx,
    )
}

public(package) fun issue_vault_receipt_info<T>(
    self: &RewardManager<T>,
    ctx: &mut TxContext,
): VaultReceiptInfo {
    self.check_version();

    // If the receipt is not provided, create a new one (option is "None")
    let unclaimed_rewards = table::new<TypeName, u256>(ctx);
    let reward_indices = vault_utils::clone_vecmap_table(
        &self.reward_indices(),
        ctx,
    );
    vault_receipt_info::new_vault_receipt_info(
        reward_indices,
        unclaimed_rewards,
    )
}

// ---------------------  Reward Type  ---------------------//

public fun add_new_reward_type<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    clock: &Clock,
    with_buffer: bool, // If true, create a new reward buffer distribution for the reward type
) {
    self.check_version();
    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    let reward_type = type_name::get<RewardCoinType>();

    self.reward_balances.add(reward_type, balance::zero<RewardCoinType>());
    self.reward_amounts.add(reward_type, 0);
    self.reward_indices.insert(reward_type, 0);

    if (with_buffer) {
        let buffer = &mut self.reward_buffer;
        buffer.reward_amounts.add(reward_type, 0);
        buffer
            .distributions
            .insert(
                reward_type,
                BufferDistribution {
                    rate: 0,
                    last_updated: clock.timestamp_ms(),
                },
            );

        emit(RewardBufferDistributionCreated {
            reward_manager_id: self.id.to_address(),
            vault_id: self.vault_id,
            coin_type: reward_type,
        });
    };

    emit(RewardTypeAdded {
        reward_manager_id: self.id.to_address(),
        vault_id: self.vault_id,
        coin_type: reward_type,
    });
}

public fun create_reward_buffer_distribution<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    clock: &Clock,
) {
    self.check_version();
    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    let buffer = &mut self.reward_buffer;
    let reward_type = type_name::get<RewardCoinType>();
    let now = clock.timestamp_ms();

    assert!(!buffer.reward_amounts.contains(reward_type), ERR_REWARD_BUFFER_TYPE_EXISTS);

    buffer.reward_amounts.add(reward_type, 0);
    buffer
        .distributions
        .insert(
            reward_type,
            BufferDistribution {
                rate: 0,
                last_updated: now,
            },
        );

    emit(RewardBufferDistributionCreated {
        reward_manager_id: self.id.to_address(),
        vault_id: self.vault_id,
        coin_type: reward_type,
    });
}

public fun remove_reward_buffer_distribution<PrincipalCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    clock: &Clock,
    reward_type: TypeName,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    self.update_reward_buffer(vault, clock, reward_type);

    let remaining_reward_amount = self.reward_buffer.reward_amounts[reward_type];
    assert!(remaining_reward_amount == 0, ERR_REMAINING_REWARD_IN_BUFFER);

    self.reward_buffer.reward_amounts.remove(reward_type);
    self.reward_buffer.distributions.remove(&reward_type);

    emit(RewardBufferDistributionRemoved {
        reward_manager_id: self.id.to_address(),
        vault_id: vault.vault_id(),
        coin_type: reward_type,
    });
}

// ---------------------  Add Reward Balance  ---------------------//

/// Add reward balance to the vault (actually added, immediately distributed & claimable)
/// This function should be called only by the operator
public fun add_reward_balance<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    reward: Balance<RewardCoinType>,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    let reward_type = type_name::get<RewardCoinType>();
    let reward_amount = vault_utils::to_decimals(reward.value() as u256);

    // If the reward amount is too small to make the index increase,
    // the reward will be lost.
    let minimum_reward_amount = vault_utils::mul_with_oracle_price(vault.total_shares(), 1);
    assert!(reward_amount>= minimum_reward_amount, ERR_REWARD_AMOUNT_TOO_SMALL);

    // New reward balance goes into the bag
    let reward_balance = self
        .reward_balances
        .borrow_mut<TypeName, Balance<RewardCoinType>>(reward_type);
    reward_balance.join(reward);

    let reward_amounts = self.reward_amounts.borrow_mut(reward_type);
    *reward_amounts = *reward_amounts + reward_amount;

    self.update_reward_indices(vault, reward_type, reward_amount);

    emit(RewardBalanceAdded {
        reward_manager_id: self.id.to_address(),
        vault_id: vault.vault_id(),
        coin_type: reward_type,
        reward_amount: reward_amount,
    })
}

// Add reward balance to the reward buffer
public fun add_reward_to_buffer<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    clock: &Clock,
    reward: Balance<RewardCoinType>,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    let reward_type = type_name::get<RewardCoinType>();
    let reward_amount = vault_utils::to_decimals(reward.value() as u256);

    // Update reward buffer's current distribution
    self.update_reward_buffer(vault, clock, reward_type);

    let buffer_reward_amount = self.reward_buffer.reward_amounts[reward_type];
    *self.reward_buffer.reward_amounts.borrow_mut(reward_type) =
        buffer_reward_amount + reward_amount;

    // New reward balance is not stored in the buffer
    let reward_balance = self
        .reward_balances
        .borrow_mut<TypeName, Balance<RewardCoinType>>(reward_type);
    reward_balance.join(reward);

    emit(RewardAddedWithBuffer {
        vault_id: vault.vault_id(),
        coin_type: reward_type,
        reward_amount: reward_amount,
    });
}

// Set the reward rate for a reward buffer distribution
public fun set_reward_rate<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    clock: &Clock,
    rate: u256,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    // assert!(rate >= DECIMALS, ERR_RATE_DECIMALS_TOO_SMALL);
    assert!(rate < std::u256::max_value!() / 86_400_000, ERR_INVALID_REWARD_RATE);

    let reward_type = type_name::get<RewardCoinType>();

    // Update the reward buffer for this reward type first
    self.update_reward_buffer<PrincipalCoinType>(vault, clock, reward_type);

    // Update the reward rate
    let distribution = &mut self.reward_buffer.distributions[&reward_type];
    distribution.rate = rate;

    emit(RewardBufferRateUpdated {
        vault_id: vault.vault_id(),
        coin_type: reward_type,
        rate: rate,
    });
}

// ---------------------  Update Reward  ---------------------//

// Update all reward buffers (different reward types)
public fun update_reward_buffers<PrincipalCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    let buffer_reward_types = self.reward_buffer.distributions.keys();

    buffer_reward_types.do_ref!(|reward_type| {
        self.update_reward_buffer<PrincipalCoinType>(vault, clock, *reward_type);
    });
}

// Update the reward buffer distribution status
// For a specific reward type
public fun update_reward_buffer<PrincipalCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    reward_type: TypeName,
) {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);
    assert!(
        self.reward_buffer.reward_amounts.contains(reward_type),
        ERR_REWARD_BUFFER_TYPE_NOT_FOUND,
    );

    let now = clock.timestamp_ms();
    let distribution = &self.reward_buffer.distributions[&reward_type];

    if (now > distribution.last_updated) {
        if (distribution.rate == 0) {
            self.reward_buffer.distributions.get_mut(&reward_type).last_updated = now;
            emit(RewardBufferUpdated {
                vault_id: vault.vault_id(),
                coin_type: reward_type,
                reward_amount: 0,
            });
        } else {
            let total_shares = vault.total_shares();

            // Newly generated reward from last update time to current time
            let reward_rate = distribution.rate;
            let last_update_time = distribution.last_updated;

            // New reward amount is with extra 9 decimals
            let new_reward = reward_rate * ((now - last_update_time) as u256);

            // Total remaining reward in the buffer
            // Newly generated reward from last update time to current time
            // Minimum reward amount that will make the index increase (total shares / 1e18)
            let remaining_reward_amount = self.reward_buffer.reward_amounts[reward_type];
            if (remaining_reward_amount == 0) {
                self.reward_buffer.distributions.get_mut(&reward_type).last_updated = now;
                emit(RewardBufferUpdated {
                    vault_id: vault.vault_id(),
                    coin_type: reward_type,
                    reward_amount: 0,
                });
            } else {
                let reward_amount = std::u256::min(remaining_reward_amount, new_reward);
                let minimum_reward_amount = vault_utils::mul_with_oracle_price(total_shares, 1);

                let actual_reward_amount = if (reward_amount >= minimum_reward_amount) {
                    reward_amount
                } else {
                    0
                };

                // If there is enough reward in the buffer, add the reward to the vault
                // Otherwise, add all the remaining reward to the vault (remaining reward = balance::zero)
                if (actual_reward_amount > 0) {
                    if (total_shares > 0) {
                        // If the vault has no shares, only update the last update time
                        // i.e. It means passing this period of time
                        // Miminum reward amount that will make the index increase
                        // e.g. If the reward amount is too small and the add_index is 0,
                        //      this part of reward should not be updated now (or the funds will be lost).
                        self.update_reward_indices(vault, reward_type, actual_reward_amount);

                        *self.reward_buffer.reward_amounts.borrow_mut(reward_type) =
                            remaining_reward_amount - actual_reward_amount;
                    };

                    self.reward_buffer.distributions.get_mut(&reward_type).last_updated = now;
                };

                emit(RewardBufferUpdated {
                    vault_id: vault.vault_id(),
                    coin_type: reward_type,
                    reward_amount: actual_reward_amount,
                });
            }
        }
    }
}

// ---------------------  Update Reward Indices  ---------------------//

public(package) fun update_reward_indices<PrincipalCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &Vault<PrincipalCoinType>,
    reward_type: TypeName,
    reward_amount: u256,
) {
    self.check_version();
    // assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    // Check if the reward type exists in the rewards & reward_indices bag
    assert!(self.reward_amounts.contains(reward_type), ERR_REWARD_TYPE_NOT_FOUND);

    // Update reward index
    // Reward amount normally is 1e9 decimals (token amount)
    // Shares is normally 1e9 decimals
    // The index is 1e18 decimals
    let total_shares = vault.total_shares();
    assert!(total_shares > 0, ERR_VAULT_HAS_NO_SHARES);

    // Index precision
    // reward_amount * 1e18 / total_shares
    // vault has 1e9 * 1e9 shares (1b TVL)
    // reward amount only needs to be larger than 1
    let add_index = vault_utils::div_with_oracle_price(
        reward_amount,
        total_shares,
    );
    let new_reward_index = *self.reward_indices.get(&reward_type) + add_index;

    *self.reward_indices.get_mut(&reward_type) = new_reward_index;

    emit(RewardIndicesUpdated {
        reward_manager_id: self.id.to_address(),
        vault_id: vault.vault_id(),
        coin_type: reward_type,
        reward_amount: reward_amount,
        inc_reward_index: add_index,
        new_reward_index: new_reward_index,
    })
}

// ---------------------  User/Receipt Reward  ---------------------//

// Update all types of reward buffers and all types of rewards inside receipt
// But can only claim one type of reward at a time
public fun claim_reward<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    clock: &Clock,
    receipt: &mut Receipt,
): Balance<RewardCoinType> {
    self.check_version();
    vault.assert_enabled();
    vault.assert_vault_receipt_matched(receipt);
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    let receipt_id = receipt.receipt_id();

    let vault_receipt = vault.vault_receipt_info(receipt_id);
    assert!(vault_receipt.status() == NORMAL_STATUS, ERR_WRONG_RECEIPT_STATUS);

    // Update all reward buffers
    self.update_reward_buffers<PrincipalCoinType>(vault, clock);
    // Update the pending reward for the receipt
    self.update_receipt_reward(vault, receipt_id);

    let reward_type = type_name::get<RewardCoinType>();

    let vault_receipt_mut = vault.vault_receipt_info_mut(receipt_id);
    let reward_amount =
        vault_utils::from_decimals(
            vault_receipt_mut.reset_unclaimed_rewards<RewardCoinType>() as u256,
        ) as u64;

    let vault_reward_balance = self
        .reward_balances
        .borrow_mut<TypeName, Balance<RewardCoinType>>(reward_type);
    assert!(reward_amount <= vault_reward_balance.value(), ERR_REWARD_EXCEED_LIMIT);

    emit(RewardClaimed {
        reward_manager_id: self.id.to_address(),
        vault_id: receipt.vault_id(),
        receipt_id: receipt.receipt_id(),
        coin_type: reward_type,
        reward_amount: reward_amount,
    });

    vault_reward_balance.split(reward_amount)
}

// Accumulate the reward to unclaimed_reward for a receipt
// Update all reward indices for a receipt
// reward = share * (cur_reward_index - previous_reward_index)
public(package) fun update_receipt_reward<PrincipalCoinType>(
    self: &RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    receipt_id: address,
) {
    self.check_version();

    let vault_receipt_mut = vault.vault_receipt_info_mut(receipt_id);

    // loop all reward in self.cur_reward_indices
    let reward_tokens = self.reward_indices.keys();

    reward_tokens.do_ref!(|reward_type| {
        let new_reward_idx = *self.reward_indices.get(reward_type);
        vault_receipt_mut.update_reward(*reward_type, new_reward_idx);
    });
}

//------------- Reward Buffer-----------------//

public fun retrieve_undistributed_reward<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    vault: &mut Vault<PrincipalCoinType>,
    operation: &Operation,
    cap: &OperatorCap,
    amount: u64,
    clock: &Clock,
): Balance<RewardCoinType> {
    self.check_version();
    assert!(self.vault_id == vault.vault_id(), ERR_REWARD_MANAGER_VAULT_MISMATCH);

    vault::assert_operator_not_freezed(operation, cap);
    vault::assert_single_vault_operator_paired(operation, self.vault_id, cap);

    let reward_type = type_name::get<RewardCoinType>();

    self.update_reward_buffer(vault, clock, reward_type);

    let remaining_reward_amount = self.reward_buffer.reward_amounts[reward_type];
    let amount_with_decimals = vault_utils::to_decimals(amount as u256);
    assert!(remaining_reward_amount >= amount_with_decimals, ERR_INSUFFICIENT_REWARD_AMOUNT);

    *self.reward_buffer.reward_amounts.borrow_mut(reward_type) =
        remaining_reward_amount - amount_with_decimals;

    let reward_balance = self
        .reward_balances
        .borrow_mut<TypeName, Balance<RewardCoinType>>(reward_type);

    emit(UndistributedRewardRetrieved {
        reward_manager_id: self.id.to_address(),
        vault_id: vault.vault_id(),
        reward_type,
        amount,
    });

    reward_balance.split(amount)
}

// ---------------------  Getters  ---------------------//

public fun vault_id<PrincipalCoinType>(self: &RewardManager<PrincipalCoinType>): address {
    self.vault_id
}

public fun reward_indices<PrincipalCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): VecMap<TypeName, u256> {
    self.reward_indices
}

public fun reward_balance<PrincipalCoinType, RewardCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): &Balance<RewardCoinType> {
    let reward_type = type_name::get<RewardCoinType>();
    self.reward_balances.borrow<TypeName, Balance<RewardCoinType>>(reward_type)
}

public fun reward_amount<PrincipalCoinType, RewardCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): u256 {
    let reward_type = type_name::get<RewardCoinType>();
    *self.reward_amounts.borrow(reward_type)
}

public fun reward_buffer_amount<PrincipalCoinType, RewardCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): u256 {
    let reward_type = type_name::get<RewardCoinType>();
    *self.reward_buffer.reward_amounts.borrow(reward_type)
}

public fun reward_buffer_distribution_rate<PrincipalCoinType, RewardCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): u256 {
    let reward_type = type_name::get<RewardCoinType>();
    self.reward_buffer.distributions[&reward_type].rate
}

public fun reward_buffer_distribution_last_updated<PrincipalCoinType, RewardCoinType>(
    self: &RewardManager<PrincipalCoinType>,
): u64 {
    let reward_type = type_name::get<RewardCoinType>();
    self.reward_buffer.distributions[&reward_type].last_updated
}

#[test_only]
public fun remove_reward_balance<PrincipalCoinType, RewardCoinType>(
    self: &mut RewardManager<PrincipalCoinType>,
    reward_type: TypeName,
    amount: u64,
): Balance<RewardCoinType> {
    let reward_balance = self
        .reward_balances
        .borrow_mut<TypeName, Balance<RewardCoinType>>(reward_type);
    reward_balance.split(amount)
}
