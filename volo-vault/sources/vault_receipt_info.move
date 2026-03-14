#[allow(deprecated_usage)]
module volo_vault::vault_receipt_info;

use std::type_name::{Self, TypeName};
use sui::address;
use sui::event::emit;
use sui::table::Table;
use volo_vault::vault_utils;

// status
// - normal: no pending requests
// - pending_deposit: a deposit request is pending
// - pending_withdraw: a withdraw request is pending
// - pending_withdraw_with_auto_transfer: a withdraw request with auto transfer is pending
// - parallel_pending_deposit_withdraw: a deposit and withdraw request are pending
// - parallel_pending_deposit_withdraw_with_auto_transfer: a deposit and withdraw request with auto transfer are pending
const NORMAL_STATUS: u8 = 0;
const PENDING_DEPOSIT_STATUS: u8 = 1;
const PENDING_WITHDRAW_STATUS: u8 = 2;
const PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 3;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS: u8 = 4;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 5;

public struct VaultReceiptInfoUpdated has copy, drop {
    new_reward: u256,
    unclaimed_reward: u256,
}

public struct VaultReceiptInfo has store {
    status: u8, // 0: normal, 1: pending_deposit, 2: pending_withdraw, 3: pending_withdraw_with_auto_transfer
    shares: u256,
    pending_deposit_balance: u64,
    pending_withdraw_shares: u256,
    last_deposit_time: u64,
    claimable_principal: u64,
    // ---- Reward Info ---- //
    reward_indices: Table<TypeName, u256>,
    unclaimed_rewards: Table<TypeName, u256>, // store unclaimed rewards, decimal: reward coin
}

public(package) fun new_vault_receipt_info(
    reward_indices: Table<TypeName, u256>,
    unclaimed_rewards: Table<TypeName, u256>,
): VaultReceiptInfo {
    VaultReceiptInfo {
        status: NORMAL_STATUS,
        shares: 0,
        pending_deposit_balance: 0,
        pending_withdraw_shares: 0,
        last_deposit_time: 0,
        claimable_principal: 0,
        reward_indices,
        unclaimed_rewards,
    }
}

// Request deposit: shares =, pending_deposit_balance ↑
public(package) fun update_after_request_deposit(
    self: &mut VaultReceiptInfo,
    pending_deposit_balance: u64,
) {
    let current_status = self.status;
    if (current_status == NORMAL_STATUS) {
        self.status = PENDING_DEPOSIT_STATUS;
    } else if (current_status == PENDING_WITHDRAW_STATUS) {
        self.status = PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS;
    } else if (current_status == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS;
    };
    self.pending_deposit_balance = self.pending_deposit_balance + pending_deposit_balance;
}

// Cancel deposit: shares =, pending_deposit_balance ↓
public(package) fun update_after_cancel_deposit(
    self: &mut VaultReceiptInfo,
    cancelled_deposit_balance: u64,
) {
    let current_status = self.status;
    if (current_status == PENDING_DEPOSIT_STATUS) {
        self.status = NORMAL_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS) {
        self.status = PENDING_WITHDRAW_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS;
    };
    self.pending_deposit_balance = self.pending_deposit_balance - cancelled_deposit_balance;
}

// Execute deposit: shares ↑, pending_deposit_balance ↓
public(package) fun update_after_execute_deposit(
    self: &mut VaultReceiptInfo,
    executed_deposit_balance: u64,
    new_shares: u256,
    last_deposit_time: u64,
) {
    let current_status = self.status;
    if (current_status == PENDING_DEPOSIT_STATUS) {
        self.status = NORMAL_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS) {
        self.status = PENDING_WITHDRAW_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS;
    };
    self.shares = self.shares + new_shares;
    self.pending_deposit_balance = self.pending_deposit_balance - executed_deposit_balance;
    self.last_deposit_time = last_deposit_time;
}

// Request withdraw: shares =, pending_withdraw_shares ↑
public(package) fun update_after_request_withdraw(
    self: &mut VaultReceiptInfo,
    pending_withdraw_shares: u256,
    recipient: address,
) {
    let current_status = self.status;
    let is_with_auto_transfer = recipient != address::from_u256(0);
    if (current_status == NORMAL_STATUS) {
        self.status = if (is_with_auto_transfer) {
            PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS
        } else {
            PENDING_WITHDRAW_STATUS
        };
    } else if (current_status == PENDING_DEPOSIT_STATUS) {
        self.status = if (is_with_auto_transfer) {
            PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS
        } else {
            PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS
        };
    };
    self.pending_withdraw_shares = self.pending_withdraw_shares + pending_withdraw_shares;
}

// Cancel withdraw: shares =, pending_withdraw_shares ↓
public(package) fun update_after_cancel_withdraw(
    self: &mut VaultReceiptInfo,
    cancelled_withdraw_shares: u256,
) {
    let current_status = self.status;
    if (current_status == PENDING_WITHDRAW_STATUS || current_status == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = NORMAL_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS) {
        self.status = PENDING_DEPOSIT_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = PENDING_DEPOSIT_STATUS;
    };
    self.pending_withdraw_shares = self.pending_withdraw_shares - cancelled_withdraw_shares;
}

// Execute withdraw: shares ↓, pending_withdraw_shares ↓
public(package) fun update_after_execute_withdraw(
    self: &mut VaultReceiptInfo,
    executed_withdraw_shares: u256,
    claimable_principal: u64,
) {
    let current_status = self.status;
    if (current_status == PENDING_WITHDRAW_STATUS || current_status == PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = NORMAL_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS) {
        self.status = PENDING_DEPOSIT_STATUS;
    } else if (current_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS) {
        self.status = PENDING_DEPOSIT_STATUS;
    };
    self.shares = self.shares - executed_withdraw_shares;
    self.pending_withdraw_shares = self.pending_withdraw_shares - executed_withdraw_shares;
    self.claimable_principal = self.claimable_principal + claimable_principal;
}

// Claim principal: claimable_principal ↓
public(package) fun update_after_claim_principal(self: &mut VaultReceiptInfo, amount: u64) {
    self.claimable_principal = self.claimable_principal - amount;
}

// ------- //

// Get the unclaimed rewards for multiple reward types for a receipt (no update)
public fun get_receipt_rewards(
    self: &VaultReceiptInfo,
    reward_types: vector<TypeName>,
): (vector<u256>) {
    let mut rewards = vector::empty<u256>();

    reward_types.do_ref!(|reward_type| {
        rewards.push_back(self.get_receipt_reward(*reward_type));
    });

    rewards.reverse();
    rewards
}

// Get the unclaimed reward for a receipt (no update)
public fun get_receipt_reward(self: &VaultReceiptInfo, reward_type: TypeName): u256 {
    if (self.unclaimed_rewards.contains(reward_type)) {
        *self.unclaimed_rewards.borrow(reward_type)
    } else {
        0
    }
}

public(package) fun reset_unclaimed_rewards<RewardCoinType>(self: &mut VaultReceiptInfo): u256 {
    let reward_type = type_name::get<RewardCoinType>();
    // always call after update_reward to ensure key existed
    let reward = self.unclaimed_rewards.borrow_mut(reward_type);
    let reward_amount = *reward;
    *reward = 0;
    reward_amount
}

/// Update reward index
/// Return new added reward
public(package) fun update_reward(
    self: &mut VaultReceiptInfo,
    reward_type: TypeName,
    new_reward_idx: u256,
): u256 {
    let reward_indices = &mut self.reward_indices;

    // get or default
    if (!reward_indices.contains(reward_type)) {
        reward_indices.add(reward_type, 0);
    };
    if (!self.unclaimed_rewards.contains(reward_type)) {
        self.unclaimed_rewards.add(reward_type, 0);
    };

    let (pre_idx, unclaimed_reward) = (
        &mut reward_indices[reward_type],
        &mut self.unclaimed_rewards[reward_type],
    );

    if (new_reward_idx > *pre_idx) {
        // get new reward
        let acc_reward = vault_utils::mul_with_oracle_price(new_reward_idx - *pre_idx, self.shares);

        // set reward and index
        *pre_idx = new_reward_idx;
        *unclaimed_reward = *unclaimed_reward + acc_reward;

        emit(VaultReceiptInfoUpdated {
            new_reward: acc_reward,
            unclaimed_reward: *unclaimed_reward,
        });

        acc_reward
    } else {
        return 0
    }
}

// ---------------------  Getters  ---------------------//

public fun status(self: &VaultReceiptInfo): u8 {
    self.status
}

public fun shares(self: &VaultReceiptInfo): u256 {
    self.shares
}

public fun last_deposit_time(self: &VaultReceiptInfo): u64 {
    self.last_deposit_time
}

public fun pending_deposit_balance(self: &VaultReceiptInfo): u64 {
    self.pending_deposit_balance
}

public fun pending_withdraw_shares(self: &VaultReceiptInfo): u256 {
    self.pending_withdraw_shares
}

public(package) fun reward_indices(self: &VaultReceiptInfo): &Table<TypeName, u256> {
    &self.reward_indices
}

public(package) fun unclaimed_rewards(self: &VaultReceiptInfo): &Table<TypeName, u256> {
    &self.unclaimed_rewards
}

public(package) fun reward_indices_mut(self: &mut VaultReceiptInfo): &mut Table<TypeName, u256> {
    &mut self.reward_indices
}

public(package) fun unclaimed_rewards_mut(self: &mut VaultReceiptInfo): &mut Table<TypeName, u256> {
    &mut self.unclaimed_rewards
}

public fun claimable_principal(self: &VaultReceiptInfo): u64 {
    self.claimable_principal
}

#[test_only]
public fun set_shares(self: &mut VaultReceiptInfo, shares: u256) {
    self.shares = shares;
}

#[test_only]
public fun set_status(self: &mut VaultReceiptInfo, status: u8) {
    self.status = status;
}

#[test_only]
public fun set_pending_withdraw_shares(self: &mut VaultReceiptInfo, shares: u256) {
    self.pending_withdraw_shares = shares;
}

#[test_only]
public fun set_claimable_principal(self: &mut VaultReceiptInfo, claimable_principal: u64) {
    self.claimable_principal = claimable_principal;
}

#[test_only]
public fun set_pending_deposit_balance(self: &mut VaultReceiptInfo, pending_deposit_balance: u64) {
    self.pending_deposit_balance = pending_deposit_balance;
}

#[test_only]
public(package) fun add_share(self: &mut VaultReceiptInfo, v: u256) {
    self.shares = self.shares + v;
}

#[test_only]
public(package) fun decrease_share(self: &mut VaultReceiptInfo, v: u256) {
    self.shares = self.shares - v;
}

#[test_only]
public(package) fun set_last_deposit_time(self: &mut VaultReceiptInfo, v: u64) {
    self.last_deposit_time = v;
}
