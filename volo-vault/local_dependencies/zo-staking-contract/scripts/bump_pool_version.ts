#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    getClient,
    getSigner,
} from './utils';
import { Transaction } from '@mysten/sui/transactions';

async function main() {
    const { env } = await prompts([
        { type: 'text', name: 'env', message: 'Enter env name', initial: 'testnet' },
    ]);

    if (!env) {
        console.error('Environment name is required.');
        process.exit(1);
    }

    const deployments = getDeployments(env);
    const zoStaking = deployments.zo_staking;

    if (!zoStaking || !zoStaking.pools || zoStaking.pools.length === 0) {
        console.error(`No pools found in deployments file for environment "${env}". Please create a pool first.`);
        process.exit(1);
    }

    let poolId: string;
    if (zoStaking.pools.length === 1) {
        poolId = zoStaking.pools[0];
        console.log(`Using the only available pool: ${poolId}`);
    } else {
        const choice = await prompts({
            type: 'select',
            name: 'poolId',
            message: 'Select a pool to bump version for:',
            choices: zoStaking.pools.map((id: string) => ({ title: id, value: id })),
        });
        poolId = choice.poolId;
    }

    if (!poolId) {
        console.error('No pool selected. Exiting.');
        process.exit(1);
    }

    const { gasBudget, stakeCoin, rewardCoin } = await prompts([
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'stakeCoin', message: 'Enter staking coin name (e.g., usdz)', initial: 'usdz' },
        { type: 'text', name: 'rewardCoin', message: 'Enter reward coin name (e.g., sui)', initial: 'sui' },
    ]);

    if (!stakeCoin || !rewardCoin) {
        console.error('Stake coin and reward coin are required.');
        process.exit(1);
    }

    console.log("\n--- Configuration ---");
    console.log(`Pool ID: ${poolId}`);
    console.log(`Stake Coin: ${stakeCoin}`);
    console.log(`Reward Coin: ${rewardCoin}`);

    const confirm = await prompts({
        type: 'confirm',
        name: 'value',
        message: 'Confirm to bump pool version?',
        initial: true
    });

    if (!confirm.value) {
        console.log("Operation cancelled.");
        return;
    }

    const client = getClient(env);
    const signer = getSigner();

    const coinModules = deployments.coin_modules;

    const stakeCoinModule = coinModules[stakeCoin.toLowerCase()].module;
    const rewardCoinModule = coinModules[rewardCoin.toLowerCase()].module;

    console.log(`Stake Coin Module: ${stakeCoinModule}`);
    console.log(`Reward Coin Module: ${rewardCoinModule}`);
    if (!stakeCoinModule || !rewardCoinModule) {
        console.error(`Coin module for ${stakeCoin} or ${rewardCoin} not found in deployments.`);
        process.exit(1);
    }

    console.log(`zoStaking upgrade package: ${zoStaking.upgraded_package}`);
    const txb = new Transaction();

    txb.moveCall({
        target: `${zoStaking.upgraded_package}::pool::bump_pool_version`,
        typeArguments: [stakeCoinModule, rewardCoinModule],
        arguments: [
            txb.object(zoStaking.admin_cap),
            txb.object(poolId),
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log(`\n🚀 Bumping version for pool ${poolId}...`);

        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true, showEvents: true },
        });

        if (result.effects?.status.status === 'success') {
            console.log('✅ Successfully bumped pool version.');
            console.log(`Transaction digest: ${result.digest}`);
            
            // Log any events if available
            if (result.events && result.events.length > 0) {
                console.log('\n📋 Events:');
                result.events.forEach((event, index) => {
                    console.log(`  Event ${index + 1}:`, JSON.stringify(event, null, 2));
                });
            }
        } else {
            console.error('Transaction failed:', result.effects?.status.error);
        }

    } catch (error) {
        console.error('An error occurred:', error);
    }
}

main();