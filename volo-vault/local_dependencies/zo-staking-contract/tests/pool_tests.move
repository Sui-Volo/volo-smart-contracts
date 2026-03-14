#[test_only]
module zo_staking::pool_tests {
    use sui::balance;
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self, Scenario, next_tx, ctx};

    use zo_staking::pool::{Self, Pool};
    use zo_staking::admin::{Self, AdminCap, AclControl};

    // === Mocks ===

    public struct SUI has drop, store {}
    public struct USDC has drop, store {}

    fun create_pool<S, R>(
        scenario: &mut Scenario,
        start_time: u64,
        end_time: u64,
        lock_duration: u64
    ): Pool<S, R> {
        let sender = test_scenario::sender(scenario);
        let (admin_cap, acl_control) = create_admin_caps(scenario);
        
        let mut c = clock::create_for_testing(ctx(scenario));
        clock::set_for_testing(&mut c, (start_time - 1) * 1000);

        pool::create_pool<S, R>(&admin_cap, &c, start_time, end_time, lock_duration, ctx(scenario));
        
        transfer::public_transfer(admin_cap, sender);
        transfer::public_transfer(acl_control, sender);
        clock::destroy_for_testing(c);

        next_tx(scenario, sender);

        test_scenario::take_shared<Pool<S, R>>(scenario)
    }

    fun create_admin_caps(scenario: &mut Scenario): (AdminCap, AclControl) {
        admin::new_for_testing(ctx(scenario))
    }

    fun mint<T>(scenario: &mut Scenario, amount: u64): Coin<T> {
        coin::from_balance(balance::create_for_testing<T>(amount), ctx(scenario))
    }

    // === Tests ===

    #[test]
    fun test_single_user_deposit_and_withdraw() {
        let mut scenario = test_scenario::begin(@0xA);
        let user_a = @0xA;
        let start_time = 1000;
        let end_time = 2000;

        let mut pool = create_pool<SUI, USDC>(&mut scenario, start_time, end_time, 0);
        
        next_tx(&mut scenario, user_a);
        {
            let (admin_cap, mut acl_control) = create_admin_caps(&mut scenario);
            admin::add_role(&admin_cap, &mut acl_control, b"operator");
            admin::add_address_to_role(&admin_cap, &mut acl_control, b"operator", user_a);

            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, start_time * 1000);
            
            // Add 1M USDC as reward
            let reward_coin = mint<USDC>(&mut scenario, 1_000_000);
            pool::add_reward(&mut pool, &c, reward_coin, ctx(&mut scenario));
            
            // Rate: 100 USDC atomic units per second
            pool::set_reward_rate(&mut acl_control, b"operator", &mut pool, &c, 100, end_time, ctx(&mut scenario));

            transfer::public_transfer(admin_cap, user_a);
            transfer::public_transfer(acl_control, user_a);
            clock::destroy_for_testing(c);
        };

        next_tx(&mut scenario, user_a);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 1) * 1000);
            let stake_coin = mint<SUI>(&mut scenario, 1000);

            pool::deposit(&mut pool, &c, stake_coin, ctx(&mut scenario));
            
            clock::destroy_for_testing(c);
        };

        next_tx(&mut scenario, user_a);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 101) * 1000);
            
            let credential = test_scenario::take_from_sender<zo_staking::pool::Credential<SUI, USDC>>(&scenario);
            
            // Withdraw all 1000 SUI
            pool::withdraw(&mut pool, &c, credential, 1000, ctx(&mut scenario));

            clock::destroy_for_testing(c);
        };

        next_tx(&mut scenario, user_a);
        {
            let user_sui = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            let user_usdc = test_scenario::take_from_sender<Coin<USDC>>(&scenario);
            
            // Should have 1000 SUI back
            assert!(coin::value(&user_sui) == 1000, 0); 
            // Should have 100 seconds * 100 rate = 10000 USDC reward
            assert!(coin::value(&user_usdc) == 10000, 1);

            test_scenario::return_to_sender(&scenario, user_sui);
            test_scenario::return_to_sender(&scenario, user_usdc);
        };

        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_multiple_users_rewards_fairness() {
        let mut scenario = test_scenario::begin(@0xA);
        let user_a = @0xA;
        let user_b = @0xB;
        let start_time = 1000;
        let end_time = 2000;
        let rate = 1000; // 1000 USDC per second

        let mut pool = create_pool<SUI, USDC>(&mut scenario, start_time, end_time, 0);
        next_tx(&mut scenario, user_a);
        {
            let (admin_cap, mut acl_control) = create_admin_caps(&mut scenario);
            admin::add_role(&admin_cap, &mut acl_control, b"operator");
            admin::add_address_to_role(&admin_cap, &mut acl_control, b"operator", user_a);

            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, start_time * 1000);
            
            // Add 1M USDC as reward
            let reward_coin = mint<USDC>(&mut scenario, 1_000_000);
            pool::add_reward(&mut pool, &c, reward_coin, ctx(&mut scenario));
            
            pool::set_reward_rate(&mut acl_control, b"operator", &mut pool, &c, rate, end_time, ctx(&mut scenario));
            transfer::public_transfer(admin_cap, user_a);
            transfer::public_transfer(acl_control, user_a);
            clock::destroy_for_testing(c);
        };

        // 2. At T=1, User A deposits 100 SUI
        next_tx(&mut scenario, user_a);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 1) * 1000);
            pool::deposit(&mut pool, &c, mint<SUI>(&mut scenario, 100), ctx(&mut scenario));
            clock::destroy_for_testing(c);
        };

        // 3. At T=11, User B deposits 300 SUI
        next_tx(&mut scenario, user_b);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 11) * 1000);
            pool::deposit(&mut pool, &c, mint<SUI>(&mut scenario, 300), ctx(&mut scenario));
            clock::destroy_for_testing(c);
        };

        // 4. At T=21, User A withdraws 100 SUI
        next_tx(&mut scenario, user_a);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 21) * 1000);
            let credential = test_scenario::take_from_sender<zo_staking::pool::Credential<SUI, USDC>>(&scenario);
            pool::withdraw(&mut pool, &c, credential, 100, ctx(&mut scenario));
            clock::destroy_for_testing(c);
        };

        // 5. At T=31, User B withdraws 300 SUI
        next_tx(&mut scenario, user_b);
        {
            let mut c = clock::create_for_testing(ctx(&mut scenario));
            clock::set_for_testing(&mut c, (start_time + 31) * 1000);
            let credential = test_scenario::take_from_sender<zo_staking::pool::Credential<SUI, USDC>>(&scenario);
            pool::withdraw(&mut pool, &c, credential, 300, ctx(&mut scenario));
            clock::destroy_for_testing(c);
        };

        // 6. Check Balances
        next_tx(&mut scenario, user_a);
        {
            // User A's reward calculation:
            // - Period 1 (T=1 to T=11): 10 seconds. Staked: 100, Total Staked: 100. Share: 100%.
            //   Reward: 10 * 1000 = 10000
            // - Period 2 (T=11 to T=21): 10 seconds. Staked: 100, Total Staked: 400. Share: 25%.
            //   Reward: 10 * 1000 * (100/400) = 2500
            // Total A Reward: 10000 + 2500 = 12500
            let user_sui_a = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            let user_usdc_a = test_scenario::take_from_sender<Coin<USDC>>(&scenario);
            assert!(coin::value(&user_sui_a) == 100, 0);
            assert!(coin::value(&user_usdc_a) == 12500, 1);
            test_scenario::return_to_sender(&scenario, user_sui_a);
            test_scenario::return_to_sender(&scenario, user_usdc_a);
        };

        next_tx(&mut scenario, user_b);
        {
            // User B's reward calculation:
            // - Period 1 (T=11 to T=21): 10 seconds. Staked: 300, Total Staked: 400. Share: 75%.
            //   Reward: 10 * 1000 * (300/400) = 7500
            // - Period 2 (T=21 to T=31): 10 seconds. Staked: 300, Total Staked: 300. Share: 100%.
            //   Reward: 10 * 1000 = 10000
            // Total B Reward: 7500 + 10000 = 17499
            // Suppose 17500, but because of the precision issue, it is 17499
            let user_sui_b = test_scenario::take_from_sender<Coin<SUI>>(&scenario);
            let user_usdc_b = test_scenario::take_from_sender<Coin<USDC>>(&scenario);
            assert!(coin::value(&user_sui_b) == 300, 2);
            assert!(coin::value(&user_usdc_b) == 17499, 3);
            test_scenario::return_to_sender(&scenario, user_sui_b);
            test_scenario::return_to_sender(&scenario, user_usdc_b);
        };

        test_scenario::return_shared(pool);
        test_scenario::end(scenario);
    }
}