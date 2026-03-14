module zo_staking::event {
    use sui::event;

    public struct InitializeEvent has copy, drop {
        admin_cap_id: ID,
        acl_control_id: ID,
    }

    public(package) fun initialize(admin_cap_id: ID, acl_control_id: ID) {
        event::emit(
            InitializeEvent {admin_cap_id, acl_control_id}
        );
    }

    public struct CreatePoolEvent<phantom S, phantom R> has copy, drop {
        id: ID,
        start_time: u64,
        end_time: u64,
        lock_duration: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun create_pool<S, R>(
        id: ID,
        start_time: u64,
        end_time: u64,
        lock_duration: u64,
    ) {
        event::emit(
            CreatePoolEvent<S, R> {
                id,
                start_time,
                end_time,
                lock_duration
            }
        );
    }

    public struct SetEnabledEvent<phantom S, phantom R> has copy, drop {
        enabled: bool,
    }

    #[allow(unused_type_parameter)]
    public(package) fun set_enabled<S, R>(enabled: bool) {
        event::emit(SetEnabledEvent<S, R> { enabled });
    }

    public struct SetStartTimeEvent<phantom S, phantom R> has copy, drop {
        start_time: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun set_start_time<S, R>(start_time: u64) {
        event::emit(SetStartTimeEvent<S, R> { start_time });
    }

    public struct SetEndTimeEvent<phantom S, phantom R> has copy, drop {
        end_time: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun set_end_time<S, R>(end_time: u64) {
        event::emit(SetEndTimeEvent<S, R> { end_time });
    }

    public struct SetLockDurationEvent<phantom S, phantom R> has copy, drop {
        lock_duration: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun set_lock_duration<S, R>(lock_duration: u64) {
        event::emit(
            SetLockDurationEvent<S, R> { lock_duration }
        );
    }

    public struct SetRewardRateEvent<phantom S, phantom R> has copy, drop {
        reward_rate: u128,
        end_time: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun set_reward_rate<S, R>(reward_rate: u128, end_time: u64) {
        event::emit(
            SetRewardRateEvent<S, R> {reward_rate, end_time}
        );
    }

    public struct AddRewardEvent<phantom S, phantom R> has copy, drop {
        reward_amount: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun add_reward<S, R>(reward_amount: u64) {
        event::emit(AddRewardEvent<S, R> { reward_amount });
    }

    public struct DepositEvent<phantom S, phantom R> has copy, drop {
        user: address,
        deposit_amount: u64,
        lock_until: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun deposit<S, R>(
        user: address,
        deposit_amount: u64,
        lock_until: u64
    ) {
        event::emit(
            DepositEvent<S, R> {user, deposit_amount, lock_until}
        );
    }

    public struct WithdrawEvent<phantom S, phantom R> has copy, drop {
        user: address,
        withdraw_amount: u64,
        reward_amount: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun withdraw<S, R>(
        user: address,
        withdraw_amount: u64,
        reward_amount: u64,
    ) {
        event::emit(
            WithdrawEvent<S, R> {
                user,
                withdraw_amount,
                reward_amount
            }
        );
    }

    public struct ClaimRewardEvent<phantom S, phantom R> has copy, drop {
        user: address,
        reward_amount: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun claim_reward<S, R>(user: address, reward_amount: u64,) {
        event::emit(
            ClaimRewardEvent<S, R> {user, reward_amount}
        );
    }

    public struct ClearCredentialEvent<phantom S, phantom R> has copy, drop {
        user: address,
    }

    #[allow(unused_type_parameter)]
    public(package) fun clear_credential<S, R>(user: address) {
        event::emit(ClearCredentialEvent<S, R> { user });
    }

    public struct ForceWithdrawEvent<phantom S, phantom R> has copy, drop {
        amount: u64,
        recipient: address,
    }

    #[allow(unused_type_parameter)]
    public(package) fun force_withdraw<S, R>(amount: u64, recipient: address) {
        event::emit(
            ForceWithdrawEvent<S, R> {amount, recipient}
        );
    }

    public struct PoolVersionUpdated<phantom S, phantom R> has copy, drop {
        old_version: u64,
        new_version: u64,
    }

    #[allow(unused_type_parameter)]
    public(package) fun pool_version_updated<S, R>(old_version: u64, new_version: u64) {
        event::emit(
            PoolVersionUpdated<S, R> {old_version, new_version}
        );
    }
}
