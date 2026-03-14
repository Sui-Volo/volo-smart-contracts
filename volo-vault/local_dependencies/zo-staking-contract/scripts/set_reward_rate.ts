#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    getClient,
    getSigner,
    CLOCK_ID,
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
            message: 'Select a pool to set the reward rate for:',
            choices: zoStaking.pools.map((id: string) => ({ title: id, value: id })),
        });
        poolId = choice.poolId;
    }

    if (!poolId) {
        console.error('No pool selected. Exiting.');
        process.exit(1);
    }

    const { gasBudget, stakeCoin, rewardCoin, rewardRate, newEndTime, roleName } = await prompts([
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'stakeCoin', message: 'Enter staking coin name (e.g., usdz)', initial: 'usdz' },
        { type: 'text', name: 'rewardCoin', message: 'Enter reward coin name (e.g., sui)', initial: 'sui' },
        { type: 'text', name: 'rewardRate', message: 'Enter reward rate (tokens per second, include decimals, as string for u128)', initial: '1000000000' },
        { type: 'number', name: 'newEndTime', message: 'Enter new end timestamp (seconds since epoch)' },
        { type: 'text', name: 'roleName', message: 'Enter the role name for authorization', initial: 'operator' },
    ]);

    if (!rewardRate || !newEndTime || !roleName) {
        console.error('Reward rate, new end time, and role name are required.');
        process.exit(1);
    }

    // Validate that newEndTime is in the future
    const currentTime = Math.floor(Date.now() / 1000);
    if (newEndTime <= currentTime) {
        console.error('New end time must be in the future.');
        process.exit(1);
    }

    console.log("\n--- Configuration ---");
    console.log(`Pool ID: ${poolId}`);
    console.log(`Stake Coin: ${stakeCoin}`);
    console.log(`Reward Coin: ${rewardCoin}`);
    console.log(`Reward Rate: ${rewardRate} tokens per second`);
    console.log(`New End Time: ${new Date(newEndTime * 1000).toLocaleString()}`);
    console.log(`Role Name: ${roleName}`);

    const confirm = await prompts({
        type: 'confirm',
        name: 'value',
        message: 'Confirm to proceed with these settings?',
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

    if (!stakeCoinModule || !rewardCoinModule) {
        console.error(`Coin module for ${stakeCoin} or ${rewardCoin} not found in deployments.`);
        process.exit(1);
    }

    const txb = new Transaction();

    txb.moveCall({
        target: `${zoStaking.package}::pool::set_reward_rate`,
        typeArguments: [stakeCoinModule, rewardCoinModule],
        arguments: [
            txb.object(zoStaking.acl_control),
            txb.pure.string(roleName),
            txb.object(poolId),
            txb.object(CLOCK_ID),
            txb.pure.u128(rewardRate),
            txb.pure.u64(newEndTime),
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log(`\n🚀 Setting reward rate for pool ${poolId}...`);
        console.log(`  - New Reward Rate: ${rewardRate} tokens/second`);
        console.log(`  - New End Time: ${new Date(newEndTime * 1000).toLocaleString()}`);

        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true },
        });

        if (result.effects?.status.status === 'success') {
            console.log('✅ Successfully set new reward rate.');
            console.log(`Transaction digest: ${result.digest}`);
        } else {
            console.error('Transaction failed:', result.effects?.status.error);
        }

    } catch (error) {
        console.error('An error occurred:', error);
    }
}

main();