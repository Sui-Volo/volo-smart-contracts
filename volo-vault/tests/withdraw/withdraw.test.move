#[test_only]
module volo_vault::withdraw_test;

use sui::clock;
use sui::coin::{Self, Coin};
use sui::test_scenario;
use volo_vault::init_vault;
use volo_vault::operation;
use volo_vault::receipt::Receipt;
use volo_vault::reward_manager::RewardManager;
use volo_vault::sui_test_coin::SUI_TEST_COIN;
use volo_vault::test_helpers;
use volo_vault::user_entry;
use volo_vault::vault::{Self, Vault, OperatorCap, Operation, AdminCap};
use volo_vault::vault_manage;
use volo_vault::vault_oracle::OracleConfig;

const OWNER: address = @0xa;
const ALICE: address = @0xb;
// const BOB: address = @0xc;

const ORACLE_DECIMALS: u256 = 1_000_000_000_000_000_000; // 18 decimals
#[allow(unused_const)]
const NORMAL_STATUS: u8 = 0;
const PENDING_DEPOSIT_STATUS: u8 = 1;
const PENDING_WITHDRAW_STATUS: u8 = 2;
const PENDING_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 3;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS: u8 = 4;
const PARALLEL_PENDING_DEPOSIT_WITHDRAW_WITH_AUTO_TRANSFER_STATUS: u8 = 5;

#[test]
// [TEST-CASE: Should request withdraw.] @test-case WITHDRAW-001
public fun test_request_withdraw() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Check withdraw request info
    s.next_tx(OWNER);
    {
        let request_id = 0;
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.shares() == 2_000_000_000);
        assert!(vault_receipt_info.last_deposit_time() == 1000);
        assert!(vault_receipt_info.status() == 2);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 1_000_000_000);

        let withdraw_request = vault.withdraw_request(request_id);
        assert!(withdraw_request.vault_id() == vault.vault_id());
        assert!(withdraw_request.request_id() == request_id);
        assert!(withdraw_request.shares() == 1_000_000_000);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = user_entry::ERR_WITHDRAW_LOCKED, location = user_entry)]
// [TEST-CASE: Should request withdraw fail if still locked.] @test-case WITHDRAW-002
public fun test_request_withdraw_fail_still_locked() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000 - 100);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = user_entry::ERR_WITHDRAW_LOCKED, location = user_entry)]
// [TEST-CASE: Should request withdraw with auto transfer fail if still locked.] @test-case WITHDRAW-003
public fun test_request_withdraw_with_auto_transfer_fail_still_locked() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000 - 100);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw_with_auto_transfer(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_EXCEED_RECEIPT_SHARES, location = vault)]
// [TEST-CASE: Should request withdraw fail if shares not enough.] @test-case WITHDRAW-004
public fun test_request_withdraw_fail_shares_not_enough() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            3_000_000_000,
            6_000_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_NOT_FOUND, location = vault)]
// [TEST-CASE: Should cancel withdraw.] @test-case WITHDRAW-005
public fun test_cancel_withdraw() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            0,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Check withdraw request info
    s.next_tx(OWNER);
    {
        let request_id = 0;
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 2_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        let _withdraw_request = vault.withdraw_request(request_id);
        // assert!(withdraw_request.shares() == 1_000_000_000);
        // assert!(withdraw_request.is_cancelled() == true);
        // assert!(withdraw_request.is_executed() == false);
        // assert!(vault.request_buffer.withdraw_requests.contains(request_id) == false);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_CANCEL_TIME_NOT_REACHED, location = vault)]
// [TEST-CASE: Should cancel withdraw fail if not reach locking time.] @test-case WITHDRAW-006
public fun test_cancel_withdraw_fail_not_reach_locking_time() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let admin_cap = s.take_from_sender<AdminCap>();

        vault_manage::set_locking_time_for_cancel_request(&admin_cap, &mut vault, 5000);

        test_scenario::return_shared(vault);
        s.return_to_sender(admin_cap);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            0,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_RECEIPT_ID_MISMATCH, location = vault)]
// [TEST-CASE: Should cancel withdraw fail if wrong request id.] @test-case WITHDRAW-007
public fun test_cancel_withdraw_fail_wrong_request_id() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request deposit
    s.next_tx(ALICE);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, ALICE);
        transfer::public_transfer(receipt, ALICE);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            1,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Request withdraw
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw with wrong receipt id
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            1,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_NOT_FOUND, location = vault)]
// [TEST-CASE: Should cancel withdraw fail if already cancelled.] @test-case WITHDRAW-008
public fun test_cancel_withdraw_fail_already_cancelled() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            0,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw again
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            0,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should execute withdraw.] @test-case WITHDRAW-009
public fun test_execute_withdraw() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Check total usd value before execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 2_000_000_000);

        test_scenario::return_shared(vault);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), _recipient);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Check total usd value after execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 1_000_000_000);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_NOT_FOUND, location = vault)]
// [TEST-CASE: Should execute withdraw fail if already cancelled.] @test-case WITHDRAW-010
public fun test_execute_withdraw_fail_already_cancelled() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::cancel_withdraw(
            &mut vault,
            &mut receipt,
            0,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), _recipient);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_NOT_FOUND, location = vault)]
// [TEST-CASE: Should execute withdraw fail if already executed.] @test-case WITHDRAW-011
public fun test_execute_withdraw_fail_already_executed() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), _recipient);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), _recipient);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_UNEXPECTED_SLIPPAGE, location = vault)]
// [TEST-CASE: Should execute withdraw fail with negative slippage.] @test-case WITHDRAW-012
public fun test_execute_withdraw_fail_negative_slippage() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            1_000_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        // Expected amount to withdraw is 500_000_000
        // Max amount received is 400_000_000
        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_UNEXPECTED_SLIPPAGE, location = vault)]
// [TEST-CASE: Should execute withdraw fail with positive slippage.] @test-case WITHDRAW-013
public fun test_execute_withdraw_fail_positive_slippage() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        // Expected amount to withdraw is 500_000_000
        // Max amount received is 400_000_000
        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            400_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should execute withdraw with auto transfer.] @test-case WITHDRAW-014
public fun test_execute_withdraw_with_auto_transfer() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    s.next_tx(OWNER);
    {
        let operation = s.take_shared<Operation>();
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let operator_cap = s.take_from_sender<OperatorCap>();

        let operators = vault::get_single_vault_operator_by_dynamic_field(
            &operation,
            vault.vault_id(),
        );
        std::debug::print(operators);

        vault::assert_single_vault_operator_paired(&operation, vault.vault_id(), &operator_cap);

        test_scenario::return_shared(operation);
        test_scenario::return_shared(vault);
        s.return_to_sender(operator_cap);
    };

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let _request_id = user_entry::deposit_with_auto_transfer(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw_with_auto_transfer(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Check total usd value before execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 2_000_000_000);

        test_scenario::return_shared(vault);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        operation::execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            0,
            500_000_000,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    // Check total usd value after execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 1_000_000_000);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should execute withdraw without auto transfer.] @test-case WITHDRAW-015
public fun test_execute_withdraw_with_no_auto_transfer() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let _request_id = user_entry::deposit_with_auto_transfer(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Check total usd value before execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 2_000_000_000);

        test_scenario::return_shared(vault);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        operation::execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            0,
            500_000_000,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    // Check total usd value after execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 1_000_000_000);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);
        assert!(vault_receipt_info.claimable_principal() == 500_000_000);

        assert!(vault.claimable_principal()== 500_000_000);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        let withdraw_balance = user_entry::claim_claimable_principal(
            &mut vault,
            &mut receipt,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), OWNER);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    s.next_tx(OWNER);
    {
        let withdrawn_coin = s.take_from_sender<Coin<SUI_TEST_COIN>>();
        assert!(withdrawn_coin.value() == 500_000_000);

        s.return_to_sender(withdrawn_coin);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_REQUEST_NOT_FOUND, location = vault)]
// [TEST-CASE: Should cancel withdraw by operator.] @test-case WITHDRAW-016
public fun test_cancel_user_withdraw_by_operator() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();

        let operation = s.take_shared<Operation>();
        let operator_cap = s.take_from_sender<OperatorCap>();

        operation::cancel_user_withdraw(
            &operation,
            &operator_cap,
            &mut vault,
            0,
            receipt.receipt_id(),
            OWNER,
            &clock,
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
        test_scenario::return_shared(operation);
        s.return_to_sender(operator_cap);
    };

    // Check withdraw request info
    s.next_tx(OWNER);
    {
        let request_id = 0;
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 2_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        let _withdraw_request = vault.withdraw_request(request_id);
        // assert!(withdraw_request.shares() == 1_000_000_000);
        // assert!(withdraw_request.is_cancelled() == true);
        // assert!(withdraw_request.is_executed() == false);
        // assert!(vault.request_buffer.withdraw_requests.contains(request_id) == false);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_NO_FREE_PRINCIPAL, location = vault)]
// [TEST-CASE: Should execute withdraw fail if no free principal.] @test-case WITHDRAW-017
public fun test_execute_withdraw_fail_no_free_principal() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let withdrawn_principal = vault.borrow_free_principal(1_000_000_000);
        transfer::public_transfer(withdrawn_principal.into_coin(s.ctx()), OWNER);

        let (withdraw_balance, _recipient) = vault.execute_withdraw(
            &clock,
            &config,
            0,
            500_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), _recipient);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should batch execute withdraw.] @test-case WITHDRAW-018
public fun test_batch_execute_withdraw() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request deposit
    s.next_tx(ALICE);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(2_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            2_000_000_000,
            4_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, ALICE);
        transfer::public_transfer(receipt, ALICE);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            1,
            4_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Request withdraw
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::withdraw(
            &mut vault,
            2_000_000_000,
            1_000_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Check total usd value before execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 6_000_000_000);

        test_scenario::return_shared(vault);
    };

    // Batch execute withdraw
    s.next_tx(OWNER);
    {
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let request_ids = vector<u64>[0, 1];
        let max_amount_received = vector<u64>[500_000_000, 1_000_000_000];

        operation::batch_execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            request_ids,
            max_amount_received,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    // Check total usd value after execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 3_000_000_000);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    s.next_tx(ALICE);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 2_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = user_entry::ERR_INVALID_AMOUNT, location = user_entry)]
// [TEST-CASE: Should request withdraw fail if zero shares.] @test-case WITHDRAW-019
public fun test_request_withdrawa_fail_zero_shares() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            0,
            0,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = user_entry::ERR_INVALID_AMOUNT, location = user_entry)]
// [TEST-CASE: Should request withdraw with auto transfer fail if zero shares.] @test-case WITHDRAW-020
public fun test_request_withdrawa_with_auto_transfer_fail_zero_shares() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw_with_auto_transfer(
            &mut vault,
            0,
            0,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[
    test,
    expected_failure(
        abort_code = vault::ERR_INSUFFICIENT_CLAIMABLE_PRINCIPAL,
        location = vault,
    ),
]
// [TEST-CASE: Should execute withdraw without auto transfer.] @test-case WITHDRAW-021
public fun test_claim_claimable_principal_amount_exceed_receipt_claimable_amount() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let _request_id = user_entry::deposit_with_auto_transfer(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        operation::execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            0,
            500_000_000,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        let withdraw_balance = user_entry::claim_claimable_principal(
            &mut vault,
            &mut receipt,
            600_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), OWNER);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[
    test,
    expected_failure(
        abort_code = vault::ERR_INSUFFICIENT_CLAIMABLE_PRINCIPAL,
        location = vault,
    ),
]
// [TEST-CASE: Should execute withdraw without auto transfer.] @test-case WITHDRAW-022
public fun test_claim_claimable_principal_amount_exceed_vault_claimable_amount() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let _request_id = user_entry::deposit_with_auto_transfer(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Execute withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        operation::execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            0,
            500_000_000,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        let balance = vault.remove_claimable_principal(200_000_000);
        balance.destroy_for_testing();

        let withdraw_balance = user_entry::claim_claimable_principal(
            &mut vault,
            &mut receipt,
            400_000_000,
        );
        transfer::public_transfer(withdraw_balance.into_coin(s.ctx()), OWNER);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should request withdraw with pending deposit status.] @test-case WITHDRAW-023
public fun test_request_withdraw_with_pending_deposit_status() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

     // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();

        let (_request_id, ret_receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::some(receipt),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(ret_receipt, OWNER);

        // s.return_to_sender(ret_receipt);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let admin_cap = s.take_from_sender<AdminCap>();

        vault_manage::set_locking_time_for_cancel_request(&admin_cap, &mut vault, 5000);

        test_scenario::return_shared(vault);
        s.return_to_sender(admin_cap);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();

        let receipt_status = vault.vault_receipt_info(receipt.receipt_id()).status();
        assert!(receipt_status == PARALLEL_PENDING_DEPOSIT_WITHDRAW_STATUS);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_RECIPIENT_MISMATCH, location = vault)]
// [TEST-CASE: Should cancel withdraw fail if wrong recipient address.] @test-case WITHDRAW-024
public fun test_cancel_withdraw_fail_wrong_recipient_address() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw_with_auto_transfer(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Cancel withdraw with wrong receipt id
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();

        vault.cancel_withdraw(
            &clock,
            0,
            receipt.receipt_id(),
            ALICE,
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should batch execute withdraw with mixed mode.] @test-case WITHDRAW-025
public fun test_batch_execute_withdraw_with_mixed_mode() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);
    init_vault::init_single_operator_config_for_owner<SUI_TEST_COIN>(&mut s, true);

    // Set mock aggregator and price
    s.next_tx(OWNER);
    {
        let mut oracle_config = s.take_shared<OracleConfig>();

        test_helpers::set_aggregators(&mut s, &mut clock, &mut oracle_config);

        clock::set_for_testing(&mut clock, 1000);
        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut oracle_config, prices);

        test_scenario::return_shared(oracle_config);
    };

    // Request deposit
    s.next_tx(OWNER);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            1_000_000_000,
            2_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, OWNER);
        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            0,
            2_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request deposit
    s.next_tx(ALICE);
    {
        let coin = coin::mint_for_testing<SUI_TEST_COIN>(2_000_000_000, s.ctx());
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();

        let (_request_id, receipt, coin) = user_entry::deposit(
            &mut vault,
            &mut reward_manager,
            coin,
            2_000_000_000,
            4_000_000_000,
            option::none(),
            &clock,
            s.ctx(),
        );

        transfer::public_transfer(coin, ALICE);
        transfer::public_transfer(receipt, ALICE);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(reward_manager);
    };

    // Execute deposit
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        vault::update_free_principal_value(&mut vault, &config, &clock);

        vault.execute_deposit(
            &clock,
            &config,
            1,
            4_000_000_000,
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
    };

    // Request withdraw
    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut config = s.take_shared<OracleConfig>();
        let mut receipt = s.take_from_sender<Receipt>();

        clock::set_for_testing(&mut clock, 1000 + 12 * 3600_000);

        let prices = vector[2 * ORACLE_DECIMALS, 1 * ORACLE_DECIMALS, 100_000 * ORACLE_DECIMALS];
        test_helpers::set_prices(&mut s, &mut clock, &mut config, prices);

        vault.update_free_principal_value(&config, &clock);

        user_entry::withdraw(
            &mut vault,
            1_000_000_000,
            500_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        s.return_to_sender(receipt);
    };

    // Request withdraw
    s.next_tx(ALICE);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let mut receipt = s.take_from_sender<Receipt>();

        user_entry::withdraw_with_auto_transfer(
            &mut vault,
            2_000_000_000,
            1_000_000_000,
            &mut receipt,
            &clock,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    // Check total usd value before execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 6_000_000_000);

        test_scenario::return_shared(vault);
    };

    // Batch execute withdraw
    s.next_tx(OWNER);
    {
        let operation = s.take_shared<Operation>();
        let cap = s.take_from_sender<OperatorCap>();
        let mut reward_manager = s.take_shared<RewardManager<SUI_TEST_COIN>>();
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let request_ids = vector<u64>[0, 1];
        let max_amount_received = vector<u64>[500_000_000, 1_000_000_000];

        operation::batch_execute_withdraw(
            &operation,
            &cap,
            &mut vault,
            &mut reward_manager,
            &clock,
            &config,
            request_ids,
            max_amount_received,
            s.ctx(),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(config);
        test_scenario::return_shared(operation);
        s.return_to_sender(cap);
        test_scenario::return_shared(reward_manager);
    };

    // Check total usd value after execute withdraw
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let total_usd_value = vault.get_total_usd_value(&clock);
        assert!(total_usd_value == 3_000_000_000);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    s.next_tx(ALICE);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info(receipt.receipt_id());

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 2_000_000_000);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        test_scenario::return_shared(vault);
        s.return_to_sender(receipt);
    };

    clock.destroy_for_testing();
    s.end();
}
