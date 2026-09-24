#[test_only]
module volo_vault::getter_test;

use lending_core::account::AccountCap as NaviAccountCap;
use sui::clock;
use sui::test_scenario;
use volo_vault::init_vault;
use volo_vault::sui_test_coin::SUI_TEST_COIN;
use volo_vault::vault::Vault;
use volo_vault::vault_utils;

const OWNER: address = @0xa;

#[test]
// [TEST-CASE: Should get epoch.] @test-case GETTER-001
public fun test_getter_epoch() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        assert!(vault.cur_epoch() == 0);

        test_scenario::return_shared(vault);
    };

    s.next_epoch(OWNER);
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        assert!(vault.cur_epoch() == 0);

        test_scenario::return_shared(vault);
    };

    s.next_tx(OWNER);
    {
        let mut vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        vault.try_reset_tolerance(false, s.ctx());
        assert!(vault.cur_epoch() == 1);

        test_scenario::return_shared(vault);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
// [TEST-CASE: Should get epoch loss.] @test-case GETTER-002
public fun test_getter_epoch_loss() {
    let mut s = test_scenario::begin(OWNER);

    let mut clock = clock::create_for_testing(s.ctx());

    init_vault::init_vault(&mut s, &mut clock);
    init_vault::init_create_vault<SUI_TEST_COIN>(&mut s);
    init_vault::init_create_reward_manager<SUI_TEST_COIN>(&mut s);

    // Request deposit
    s.next_tx(OWNER);
    {
        let vault = s.take_shared<Vault<SUI_TEST_COIN>>();

        assert!(vault.cur_epoch_loss() == 0);

        test_scenario::return_shared(vault);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test,allow(unused_variable)]
// [TEST-CASE: Should parse key.] @test-case GETTER-003
public fun test_parse_key() {
    let s = test_scenario::begin(OWNER);

    let idx: u8 = 10;
    let key = vault_utils::parse_key<NaviAccountCap>(idx);

    s.end();
}
