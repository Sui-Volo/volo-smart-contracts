module zo_staking::pool {
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};
    use sui::dynamic_object_field;

    use zo_staking::admin::{AdminCap,AclControl, has_role};
    use zo_staking::event;

    /// Errors
    const ERR_NOT_AUTHORIZED: u64 = 3001;

    // === objects ===

    public struct Pool<phantom S, phantom R> has key {
        id: UID,
        enabled: bool,
        last_updated_time: u64,
        staked_amount: u64,
        reward_vault: Balance<R>,
        reward_rate: u128,
        start_time: u64,
        end_time: u64,
        acc_reward_per_share: u128,
        lock_duration: u64,
    }

    public struct Credential<phantom S, phantom R> has key {
        id: UID,
        lock_until: u64,
        acc_reward_per_share: u128,
        stake: Balance<S>,
    }

    public struct CredentialV2<phantom S, phantom R> has key, store {
        id: UID,
        lock_until: u64,
        acc_reward_per_share: u128,
        stake: Balance<S>,
    }

    public struct PoolVersion has key, store {
        id: UID,
        version: u64,
    }

    const POOL_VERSION_DYNAMIC_KEY: vector<u8> = b"POOL_VERSION";
    const CURRENT_PACKAGE_VERSION: u64 = 5;
    const ERR_POOL_VERSION_EXCEEDS_CURRENT: u64 = 13;
    const ERR_POOL_VERSION_NOT_INITIALIZED: u64 = 14;

    /// Constants
    const SCALE_FACTOR: u128 = 1_000_000_000_000_000_000;
    const MAX_U128: u128 = 340282366920938463463374607431768211455; // 2^128 - 1

    /// Errors
    const ERR_POOL_INACTIVE: u64 = 0;
    const ERR_INVALID_START_TIME: u64 = 1;
    const ERR_INVALID_END_TIME: u64 = 2;
    const ERR_INVALID_DEPOSIT_AMOUNT: u64 = 3;
    const ERR_INVALID_REWARD_AMOUNT: u64 = 4;
    const ERR_INVALID_WITHDRAW_AMOUNT: u64 = 5;
    const ERR_NOT_UNLOCKED: u64 = 6;
    const ERR_ALREADY_STARTED: u64 = 7;
    const ERR_ALREADY_ENDED: u64 = 8;
    const ERR_CAN_NOT_CLEAR_CREDENTIAL: u64 = 9;
    const ERR_NOT_STARTED: u64 = 10;
    const ERR_MATH_OVERFLOW: u64 = 11;
    const ERR_POOL_FORCE_NEED_INACTIVE: u64 = 12;

    fun min_reward<R>(reward: &Balance<R>, reward_amount: u64): u64 {
        if (reward_amount > balance::value(reward)) {
            return balance::value(reward)
        };
        reward_amount
    }

    fun pay_from_balance<T>(
        balance: Balance<T>,
        receiver: address,
        ctx: &mut TxContext,
    ) {
        if (balance::value(&balance) > 0) {
            transfer::public_transfer(coin::from_balance(balance, ctx), receiver);
        } else {
            balance::destroy_zero(balance);
        }
    }

    fun refresh_pool<S, R>(
        pool: &mut Pool<S, R>,
        current_timestamp: u64,
    ) {
        if (current_timestamp <= pool.last_updated_time || current_timestamp < pool.start_time) {
            return
        };

        let applicable_end_time = if (pool.end_time < pool.last_updated_time) {
            pool.last_updated_time
        } else {
            pool.end_time
        };

        let calculation_end_time = if (current_timestamp > applicable_end_time) {
            applicable_end_time
        } else {
            current_timestamp
        };

        if (calculation_end_time > pool.last_updated_time && pool.staked_amount > 0 && pool.reward_rate > 0) {
            let time_diff = calculation_end_time - pool.last_updated_time;

            assert!(MAX_U128 / pool.reward_rate >= (time_diff as u128), ERR_MATH_OVERFLOW);
            let reward_amount = (time_diff as u128) * pool.reward_rate;
            
            let reward_per_share = (((reward_amount as u256) * (SCALE_FACTOR as u256)) / (pool.staked_amount as u256)) as u128;
            assert!(reward_per_share <= MAX_U128, ERR_MATH_OVERFLOW);

            assert!(MAX_U128 - reward_per_share >= pool.acc_reward_per_share, ERR_MATH_OVERFLOW);
            pool.acc_reward_per_share = pool.acc_reward_per_share + reward_per_share;
        };

        pool.last_updated_time = calculation_end_time;
    }

    fun destory_credential<S, R>(credential: Credential<S, R>) {
        assert!(balance::value(&credential.stake) == 0, ERR_CAN_NOT_CLEAR_CREDENTIAL);

        let Credential {
            id,
            lock_until: _,
            acc_reward_per_share: _,
            stake,
        } = credential;

        object::delete(id);
        balance::destroy_zero(stake);
    }

    fun destory_credential_v2<S, R>(credential: CredentialV2<S, R>) {
        assert!(balance::value(&credential.stake) == 0, ERR_CAN_NOT_CLEAR_CREDENTIAL);

        let CredentialV2 {
            id,
            lock_until: _,
            acc_reward_per_share: _,
            stake,
        } = credential;

        object::delete(id);
        balance::destroy_zero(stake);
    }

    // === credential getters ===
    public fun credential_lock_until<S, R>(c: &Credential<S, R>): u64 {
        c.lock_until
    }

    public fun credential_acc_reward_per_share<S, R>(c: &Credential<S, R>): u128 {
        c.acc_reward_per_share
    }

    public fun credential_staked_amount<S, R>(c: &Credential<S, R>): u64 {
        balance::value(&c.stake)
    }

    public fun credential_stake_ref<S, R>(c: &Credential<S, R>): &Balance<S> {
        &c.stake
    }

    // === credential v2 getters ===
    public fun credential_v2_lock_until<S, R>(c: &CredentialV2<S, R>): u64 {
        c.lock_until
    }

    public fun credential_v2_acc_reward_per_share<S, R>(c: &CredentialV2<S, R>): u128 {
        c.acc_reward_per_share
    }

    public fun credential_v2_staked_amount<S, R>(c: &CredentialV2<S, R>): u64 {
        balance::value(&c.stake)
    }

    public fun credential_v2_stake_ref<S, R>(c: &CredentialV2<S, R>): &Balance<S> {
        &c.stake
    }

    public fun create_pool<S, R>(
        _a: &AdminCap,
        clock: &Clock,
        start_time: u64,
        end_time: u64,
        lock_duration: u64,
        ctx: &mut TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(start_time >= timestamp, ERR_INVALID_START_TIME);
        assert!(end_time > start_time, ERR_INVALID_END_TIME);

        let uid = object::new(ctx);
        let id = object::uid_to_inner(&uid);
        transfer::share_object(
            Pool<S, R> {
                id: uid,
                enabled: true,
                last_updated_time: start_time,
                staked_amount: 0,
                reward_vault: balance::zero(),
                reward_rate: 0,
                start_time,
                end_time,
                acc_reward_per_share: 0,
                lock_duration,
            }
        );

        event::create_pool<S, R>(id, start_time, end_time, lock_duration)
    }

    public fun set_enabled<S, R>(
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        pool: &mut Pool<S, R>,
        enabled: bool,
        ctx: &mut TxContext,
    ) {
        assert!(has_role(_acl, _role_name, tx_context::sender(ctx)), ERR_NOT_AUTHORIZED);
        check_version(pool);

        pool.enabled = enabled;

        event::set_enabled<S, R>(enabled)
    }

    public fun set_start_time<S, R>(
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        start_time: u64,
        ctx: &mut TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(has_role(_acl, _role_name, tx_context::sender(ctx)), ERR_NOT_AUTHORIZED);
        check_version(pool);

        assert!(timestamp < pool.start_time, ERR_ALREADY_STARTED);
        assert!(start_time >= timestamp && start_time < pool.end_time, ERR_INVALID_START_TIME);

        refresh_pool(pool, timestamp);
        pool.start_time = start_time;

        event::set_start_time<S, R>(start_time)
    }

    public fun set_end_time<S, R>(
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        end_time: u64,
        ctx: &mut TxContext,
    ) {
        assert!(has_role(_acl, _role_name, tx_context::sender(ctx)), ERR_NOT_AUTHORIZED);
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);
        assert!(end_time > timestamp && end_time > pool.start_time, ERR_INVALID_END_TIME);

        refresh_pool(pool, timestamp);
        pool.end_time = end_time;

        event::set_end_time<S, R>(end_time)
    }

    public fun set_reward_rate<S, R>(
        _acl: &mut AclControl,
        _role_name: vector<u8>,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        reward_rate: u128,
        new_end_time: u64,
        ctx: &mut TxContext,
    ) {
        assert!(has_role(_acl, _role_name, tx_context::sender(ctx)), ERR_NOT_AUTHORIZED);
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        refresh_pool(pool, timestamp);

        assert!(new_end_time > timestamp, ERR_INVALID_END_TIME);
        
        pool.reward_rate = reward_rate;
        pool.end_time = new_end_time;
        pool.last_updated_time = timestamp;
        
        event::set_reward_rate<S, R>(reward_rate, new_end_time);
    }

    public fun set_lock_duration<S, R>(
        _acl: &AclControl,
        _role_name: vector<u8>,
        pool: &mut Pool<S, R>,
        lock_duration: u64,
        ctx: &mut TxContext,
    ) {
        assert!(has_role(_acl, _role_name, tx_context::sender(ctx)), ERR_NOT_AUTHORIZED);
        check_version(pool);

        pool.lock_duration = lock_duration;
        event::set_lock_duration<S, R>(lock_duration)
    }

    public fun add_reward<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        reward: Coin<R>,
        _ctx: &mut TxContext,
    ) {
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);

        let reward_amount = coin::value(&reward);
        assert!(reward_amount > 0, ERR_INVALID_REWARD_AMOUNT);
        let current_reward = balance::value(&pool.reward_vault);
        assert!((current_reward as u128) + (reward_amount as u128) <= MAX_U128, ERR_MATH_OVERFLOW);

        refresh_pool(pool, timestamp);
        coin::put(&mut pool.reward_vault, reward);

        event::add_reward<S, R>(reward_amount);
    }

    public fun deposit<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        stake: Coin<S>,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(timestamp >= pool.start_time, ERR_NOT_STARTED);
        let deposit_amount = coin::value(&stake);
        assert!(deposit_amount > 0, ERR_INVALID_DEPOSIT_AMOUNT);

        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);
        
        refresh_pool(pool, timestamp);

        let lock_until = timestamp + pool.lock_duration;
        let credential = Credential<S, R> {
            id: object::new(ctx),
            lock_until,
            acc_reward_per_share: pool.acc_reward_per_share,
            stake: coin::into_balance(stake),
        };
        pool.staked_amount = pool.staked_amount + deposit_amount;
        
        let user = tx_context::sender(ctx);
        transfer::transfer(credential, user);

        event::deposit<S, R>(user, deposit_amount, lock_until);
    }

    #[allow(lint(self_transfer))]
    public fun deposit_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        stake: Coin<S>,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(timestamp >= pool.start_time, ERR_NOT_STARTED);
        let deposit_amount = coin::value(&stake);
        assert!(deposit_amount > 0, ERR_INVALID_DEPOSIT_AMOUNT);

        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);

        refresh_pool(pool, timestamp);

        let lock_until = timestamp + pool.lock_duration;
        let credential = CredentialV2<S, R> {
            id: object::new(ctx),
            lock_until,
            acc_reward_per_share: pool.acc_reward_per_share,
            stake: coin::into_balance(stake),
        };
        pool.staked_amount = pool.staked_amount + deposit_amount;

        let user = tx_context::sender(ctx);
        transfer::transfer(credential, user);

        event::deposit<S, R>(user, deposit_amount, lock_until);
    }

    // returns the credential
    #[allow(lint(self_transfer))]
    public fun deposit_ptb_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        stake: Coin<S>,
        ctx: &mut TxContext,
    ): CredentialV2<S, R> {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let timestamp = clock::timestamp_ms(clock) / 1000;

        assert!(timestamp >= pool.start_time, ERR_NOT_STARTED);
        let deposit_amount = coin::value(&stake);
        assert!(deposit_amount > 0, ERR_INVALID_DEPOSIT_AMOUNT);

        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);

        refresh_pool(pool, timestamp);

        let lock_until = timestamp + pool.lock_duration;
        let credential = CredentialV2<S, R> {
            id: object::new(ctx),
            lock_until,
            acc_reward_per_share: pool.acc_reward_per_share,
            stake: coin::into_balance(stake),
        };
        pool.staked_amount = pool.staked_amount + deposit_amount;

        let user = tx_context::sender(ctx);

        event::deposit<S, R>(user, deposit_amount, lock_until);

        credential
    }

    public fun withdraw<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        mut credential: Credential<S, R>,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ) {
        check_version(pool);

        let reward_coin = claim_rewards_ptb(pool, clock, &mut credential, ctx);
        let reward = coin::into_balance(reward_coin);
        let unstake = coin::into_balance(withdraw_ptb(pool, clock, &mut credential, withdraw_amount, ctx));
        let user = tx_context::sender(ctx);
        pay_from_balance(reward, user, ctx);
        pay_from_balance(unstake, user, ctx);

        // clear empty credential
        if (balance::value(&credential.stake) == 0) {
            destory_credential(credential);
        } else {
            transfer::transfer(credential, user);
        };
    }

    // withdraw only
    public fun withdraw_ptb<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut Credential<S, R>,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<S> {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let staked_amount = balance::value(&credential.stake);
        assert!(staked_amount >= withdraw_amount, ERR_INVALID_WITHDRAW_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= std::u64::min(credential.lock_until, pool.end_time), ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let unstake = balance::split(&mut credential.stake, withdraw_amount);
        pool.staked_amount = pool.staked_amount - withdraw_amount;

        let user = tx_context::sender(ctx);

        event::withdraw<S, R>(user, withdraw_amount, 0);

        coin::from_balance(unstake, ctx)
    }

    // claim rewards only
    public fun claim_rewards<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut Credential<S, R>,
        ctx: &mut TxContext,
    ) {
        check_version(pool);

        let reward_coin = claim_rewards_ptb(pool, clock, credential, ctx);
        let reward = coin::into_balance(reward_coin);
        let user = tx_context::sender(ctx);
        pay_from_balance(reward, user, ctx);
    }

    public fun claim_rewards_ptb<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut Credential<S, R>,
        ctx: &mut TxContext,
    ): Coin<R> {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let staked_amount = balance::value(&credential.stake);
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= std::u64::min(credential.lock_until, pool.end_time), ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let pending_reward_per_share = pool.acc_reward_per_share - credential.acc_reward_per_share;
        let reward_amount = (((pending_reward_per_share as u256) * (staked_amount as u256)) / (SCALE_FACTOR as u256)) as u128;
        assert!(reward_amount <= MAX_U128, ERR_MATH_OVERFLOW);
        
        credential.acc_reward_per_share = pool.acc_reward_per_share;

        let min_reward_amount = min_reward(&pool.reward_vault, (reward_amount as u64));
        let reward = balance::split(&mut pool.reward_vault, min_reward_amount);
        let user = tx_context::sender(ctx);

        event::claim_reward<S, R>(user, (reward_amount as u64));

        coin::from_balance(reward, ctx)
    }

    // withdraw only (v2)
    public fun withdraw_ptb_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut CredentialV2<S, R>,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<S> {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let staked_amount = balance::value(&credential.stake);
        assert!(staked_amount >= withdraw_amount, ERR_INVALID_WITHDRAW_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= std::u64::min(credential.lock_until, pool.end_time), ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let unstake = balance::split(&mut credential.stake, withdraw_amount);
        pool.staked_amount = pool.staked_amount - withdraw_amount;

        let user = tx_context::sender(ctx);

        event::withdraw<S, R>(user, withdraw_amount, 0);

        coin::from_balance(unstake, ctx)
    }

    #[allow(lint(self_transfer, custom_state_change))]
    public fun withdraw_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        mut credential: CredentialV2<S, R>,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ) {
        check_version(pool);

        let reward_coin = claim_rewards_ptb_v2(pool, clock, &mut credential, ctx);
        let reward = coin::into_balance(reward_coin);
        let unstake = coin::into_balance(withdraw_ptb_v2(pool, clock, &mut credential, withdraw_amount, ctx));
        let user = tx_context::sender(ctx);
        pay_from_balance(reward, user, ctx);
        pay_from_balance(unstake, user, ctx);

        // clear empty credential
        if (balance::value(&credential.stake) == 0) {
            destory_credential_v2(credential);
        } else {
            transfer::transfer(credential, user);
        };
    }

    // claim rewards only (v2)
    public fun claim_rewards_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut CredentialV2<S, R>,
        ctx: &mut TxContext,
    ) {
        check_version(pool);

        let reward_coin = claim_rewards_ptb_v2(pool, clock, credential, ctx);
        let reward = coin::into_balance(reward_coin);
        let user = tx_context::sender(ctx);
        pay_from_balance(reward, user, ctx);
    }

    public fun claim_rewards_ptb_v2<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut CredentialV2<S, R>,
        ctx: &mut TxContext,
    ): Coin<R> {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        check_version(pool);

        let staked_amount = balance::value(&credential.stake);
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= std::u64::min(credential.lock_until, pool.end_time), ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let pending_reward_per_share = pool.acc_reward_per_share - credential.acc_reward_per_share;
        let reward_amount = (((pending_reward_per_share as u256) * (staked_amount as u256)) / (SCALE_FACTOR as u256)) as u128;
        assert!(reward_amount <= MAX_U128, ERR_MATH_OVERFLOW);

        credential.acc_reward_per_share = pool.acc_reward_per_share;

        let min_reward_amount = min_reward(&pool.reward_vault, (reward_amount as u64));
        let reward = balance::split(&mut pool.reward_vault, min_reward_amount);
        let user = tx_context::sender(ctx);

        event::claim_reward<S, R>(user, (reward_amount as u64));

        coin::from_balance(reward, ctx)
    }

    // === pool getters ===
    public fun pool_enabled<S, R>(p: &Pool<S, R>): bool {
        p.enabled
    }

    public fun pool_last_updated_time<S, R>(p: &Pool<S, R>): u64 {
        p.last_updated_time
    }

    public fun pool_staked_amount<S, R>(p: &Pool<S, R>): u64 {
        p.staked_amount
    }

    public fun pool_reward_rate<S, R>(p: &Pool<S, R>): u128 {
        p.reward_rate
    }

    public fun pool_start_time<S, R>(p: &Pool<S, R>): u64 {
        p.start_time
    }

    public fun pool_end_time<S, R>(p: &Pool<S, R>): u64 {
        p.end_time
    }

    public fun pool_acc_reward_per_share<S, R>(p: &Pool<S, R>): u128 {
        p.acc_reward_per_share
    }

    public fun pool_lock_duration<S, R>(p: &Pool<S, R>): u64 {
        p.lock_duration
    }

    public fun pool_reward_vault_value<S, R>(p: &Pool<S, R>): u64 {
        balance::value(&p.reward_vault)
    }

    public fun pool_reward_vault_ref<S, R>(p: &Pool<S, R>): &Balance<R> {
        &p.reward_vault
    }

    public fun force_withdraw<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(!pool.enabled, ERR_POOL_FORCE_NEED_INACTIVE);
        let reward_amount = balance::value(&pool.reward_vault);
        let reward = balance::split(&mut pool.reward_vault, reward_amount);
        pay_from_balance(reward, recipient, ctx);

        event::force_withdraw<S, R>(reward_amount, recipient);
    }

    public fun clear_empty_credential<S, R>(
        credential: Credential<S, R>,
        _ctx: &mut TxContext,
    ) {
        if (balance::value(&credential.stake) == 0) {
            destory_credential(credential);
        } else {
            transfer::transfer(credential, tx_context::sender(_ctx));
        }
    }

    #[allow(lint(self_transfer, custom_state_change))]
    public fun clear_empty_credential_v2<S, R>(
        credential: CredentialV2<S, R>,
        _ctx: &mut TxContext,
    ) {
        if (balance::value(&credential.stake) == 0) {
            destory_credential_v2(credential);
        } else {
            transfer::transfer(credential, tx_context::sender(_ctx));
        }
    }

    // === versioning control ===
    public fun bump_pool_version<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        ctx: &mut TxContext,
    ) {
        if (dynamic_object_field::exists_(&pool.id, POOL_VERSION_DYNAMIC_KEY)) {
            let pv: &mut PoolVersion = dynamic_object_field::borrow_mut(
                &mut pool.id,
                POOL_VERSION_DYNAMIC_KEY,
            );
            let old = pv.version;
            let new = old + 1;

            assert!(new <= CURRENT_PACKAGE_VERSION, ERR_POOL_VERSION_EXCEEDS_CURRENT);

            pv.version = new;

            event::pool_version_updated<S, R>(old, new);
        } else {
            // initialize to CURRENT_PACKAGE_VERSION
            let pv = PoolVersion {
                id: object::new(ctx),
                version: CURRENT_PACKAGE_VERSION,
            };
            dynamic_object_field::add(
                &mut pool.id,
                POOL_VERSION_DYNAMIC_KEY,
                pv,
            );

            event::pool_version_updated<S, R>(0, CURRENT_PACKAGE_VERSION);
        }
    }

    fun check_version<S, R>(pool: &Pool<S, R>) {
        if (dynamic_object_field::exists_(&pool.id, POOL_VERSION_DYNAMIC_KEY)) {
            let pv: &PoolVersion = dynamic_object_field::borrow(&pool.id, POOL_VERSION_DYNAMIC_KEY);
            assert!(pv.version <= CURRENT_PACKAGE_VERSION, ERR_POOL_VERSION_EXCEEDS_CURRENT);
        } else {
            assert!(false, ERR_POOL_VERSION_NOT_INITIALIZED);
        }
    }
}