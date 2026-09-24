#[test_only]
module volo_vault::receipt_test;

use std::type_name::{Self, TypeName};
use sui::clock;
use sui::coin;
use sui::table;
use sui::test_scenario;
use volo_vault::init_vault;
use volo_vault::receipt::{Self, Receipt};
use volo_vault::receipt_adaptor;
use volo_vault::sui_test_coin::SUI_TEST_COIN;
use volo_vault::test_helpers;
use volo_vault::usdc_test_coin::USDC_TEST_COIN;
use volo_vault::vault::{Self, Vault};
use volo_vault::vault_oracle::OracleConfig;
use volo_vault::vault_receipt_info;
use volo_vault::receipt_cancellation;

const OWNER: address = @0xa;

const ORACLE_DECIMALS: u256 = 1_000_000_000_000_000_000;

#[test]
// [TEST-CASE: Should create receipt.] @test-case RECEIPT-001
public fun test_create_receipt() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let receipt = receipt::create_receipt(
            vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);
        vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);
        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        let receipt = s.take_from_sender<Receipt>();
        let vault_receipt_info = vault.vault_receipt_info_mut(receipt.receipt_id());

        let reward_indices_mut = vault_receipt_info.reward_indices_mut();
        assert!(reward_indices_mut.length() == 0);

        let reward_for_sui = vault_receipt_info.get_receipt_reward(type_name::with_defining_ids<SUI_TEST_COIN>());
        assert!(reward_for_sui == 0);

        let reward_for_usdc = vault_receipt_info.get_receipt_reward(
            type_name::with_defining_ids<USDC_TEST_COIN>(),
        );
        assert!(reward_for_usdc == 0);

        let unclaimed_rewards = vault_receipt_info.unclaimed_rewards();
        assert!(unclaimed_rewards.length() == 0);

        let unclaimed_rewards_mut = vault_receipt_info.unclaimed_rewards_mut();
        assert!(unclaimed_rewards_mut.length() == 0);

        let type_names = vector[type_name::with_defining_ids<SUI_TEST_COIN>()];
        let rewards = vault_receipt_info.get_receipt_rewards(type_names);
        assert!(rewards.length() == 1);

        assert!(vault_receipt_info.status() == 0);
        assert!(vault_receipt_info.shares() == 1_000_000_000);
        assert!(vault_receipt_info.last_deposit_time() == 0);
        assert!(vault_receipt_info.pending_deposit_balance() == 0);
        assert!(vault_receipt_info.pending_withdraw_shares() == 0);

        s.return_to_sender(receipt);
        test_scenario::return_shared(vault);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should add receipt as defi asset.] @test-case RECEIPT-002
public fun test_receipt_as_defi_asset() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);

        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let receipt = s.take_from_sender<Receipt>();
        let sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let receipt_value = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value == 2_000_000_000);

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should add receipt as defi asset with pending status.] @test-case RECEIPT-003
public fun test_receipt_as_defi_asset_with_pending_status() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);
        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let receipt = s.take_from_sender<Receipt>();
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let vault_receipt_info = sui_vault.vault_receipt_info_mut(receipt.receipt_id());
        let config = s.take_shared<OracleConfig>();

        vault_receipt_info.set_status(1);

        let receipt_value = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value == 2_000_000_000);

        let vault_receipt_info_mut = sui_vault.vault_receipt_info_mut(receipt.receipt_id());
        vault_receipt_info_mut.set_status(2);

        let receipt_value_2 = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value_2 == 2_000_000_000);

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should add receipt as defi asset with pending withdraw with auto transfer status.] @test-case RECEIPT-004
public fun test_receipt_as_defi_asset_with_pending_withdraw_with_auto_transfer_status() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);
        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let receipt = s.take_from_sender<Receipt>();
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let vault_receipt_info = sui_vault.vault_receipt_info_mut(receipt.receipt_id());
        let config = s.take_shared<OracleConfig>();

        vault_receipt_info.set_status(1);

        let receipt_value = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value == 2_000_000_000);

        let vault_receipt_info_mut = sui_vault.vault_receipt_info_mut(receipt.receipt_id());
        vault_receipt_info_mut.set_status(3);
        vault_receipt_info_mut.set_pending_withdraw_shares(500_000_000);

        let receipt_value_2 = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value_2 == 1_000_000_000);

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should add receipt as defi asset with all fields values.] @test-case RECEIPT-005
public fun test_receipt_as_defi_asset_with_all_fields_values() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);

        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let receipt = s.take_from_sender<Receipt>();
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let vault_receipt_info = sui_vault.vault_receipt_info_mut(receipt.receipt_id());
        vault_receipt_info.set_claimable_principal(1_000_000_000);
        vault_receipt_info.set_pending_deposit_balance(1_000_000_000);

        // 1 share + 1SUI pending deposit + 1SUI claimable principal = 6U
        let receipt_value = receipt_adaptor::get_receipt_value(
            &sui_vault,
            &config,
            &receipt,
            &clock,
        );
        assert!(receipt_value == 6_000_000_000);

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = vault::ERR_VAULT_RECEIPT_NOT_MATCH, location = vault)]
// [TEST-CASE: Should add receipt as defi asset fail if vault mismatch.] @test-case RECEIPT-006
public fun test_receipt_as_defi_asset_fail_vault_mismatch() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);

        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let receipt = s.take_from_sender<Receipt>();
        let sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let _receipt_value = receipt_adaptor::get_receipt_value(
            &usdc_vault,
            &config,
            &receipt,
            &clock,
        );

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
public fun test_receipt_can_be_cancelled_status() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_vault<USDC_TEST_COIN>(&mut s);
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

    s.next_tx(OWNER);
    {
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let coin = coin::mint_for_testing<SUI_TEST_COIN>(1_000_000_000, s.ctx());
        sui_vault.return_free_principal(coin.into_balance());
        sui_vault.update_free_principal_value(&config, &clock);
        sui_vault.set_total_shares(1_000_000_000);

        let receipt = receipt::create_receipt(
            sui_vault.vault_id(),
            s.ctx(),
        );

        let mut vault_receipt_info = vault_receipt_info::new_vault_receipt_info(
            table::new<TypeName, u256>(s.ctx()),
            table::new<TypeName, u256>(s.ctx()),
        );
        vault_receipt_info.set_shares(1_000_000_000);

        sui_vault.set_vault_receipt_info(receipt.receipt_id(), vault_receipt_info);

        transfer::public_transfer(receipt, OWNER);

        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(config);
    };

    s.next_tx(OWNER);
    {
        let mut receipt = s.take_from_sender<Receipt>();
        let mut sui_vault = s.take_shared<Vault<SUI_TEST_COIN>>();
        let usdc_vault = s.take_shared<Vault<USDC_TEST_COIN>>();
        let config = s.take_shared<OracleConfig>();

        let can_be_cancelled_initial = receipt_cancellation::receipt_can_be_cancelled(&receipt);
        assert!(can_be_cancelled_initial);

        receipt_cancellation::add_dynamic_field_to_receipt(&mut receipt);
        receipt_cancellation::add_dynamic_field_to_vault(&mut sui_vault, s.ctx());

        receipt_cancellation::set_receipt_can_not_be_cancelled(&mut receipt, &mut sui_vault);
        let can_be_cancelled_after = receipt_cancellation::receipt_can_be_cancelled(&receipt);
        assert!(!can_be_cancelled_after);

        receipt_cancellation::set_receipt_can_be_cancelled(&mut receipt, &mut sui_vault);
        let can_be_cancelled_after = receipt_cancellation::receipt_can_be_cancelled(&receipt);
        assert!(can_be_cancelled_after);

        s.return_to_sender(receipt);
        test_scenario::return_shared(sui_vault);
        test_scenario::return_shared(usdc_vault);
        test_scenario::return_shared(config);
    };

    clock.destroy_for_testing();
    s.end();
}