#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    getClient,
    getSigner,
    CLOCK_ID,
} from './utils';
import { Transaction } from '@mysten/sui/transactions';
import Decimal from 'decimal.js';

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
            message: 'Select a pool to set the reward period for:',
            choices: zoStaking.pools.map((id: string) => ({ title: id, value: id })),
        });
        poolId = choice.poolId;
    }

    if (!poolId) {
        console.error('No pool selected. Exiting.');
        process.exit(1);
    }

    const { gasBudget, stakeCoin, rewardCoin, totalRewardAmount, rewardCoinDecimals, durationDays, roleName } = await prompts([
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'stakeCoin', message: 'Enter staking coin name (e.g., usdz)', initial: 'usdz' },
        { type: 'text', name: 'rewardCoin', message: 'Enter reward coin name (e.g., sui)', initial: 'sui' },
        { type: 'number', name: 'totalRewardAmount', message: 'Enter total reward amount for this period (e.g., 1000000000 = 1 sui)' },
        { type: 'number', name: 'rewardCoinDecimals', message: 'Enter reward coin decimals', initial: 9 },
        { type: 'number', name: 'durationDays', message: 'Enter duration of this period in days (e.g., 30)' },
        { type: 'text', name: 'roleName', message: 'Enter the role name for authorization', initial: 'operator' },
    ]);

    if (!totalRewardAmount || !durationDays || !roleName) {
        console.error('Total reward amount, duration and role name are required.');
        process.exit(1);
    }

    const durationSeconds = new Decimal(durationDays).mul(24 * 60 * 60);
    const totalRewardAtomic = new Decimal(totalRewardAmount).mul(new Decimal(10).pow(rewardCoinDecimals));

    if (durationSeconds.isZero()) {
        console.error("Error: Duration cannot be zero.");
        return;
    }

    const rewardRate = totalRewardAtomic.dividedToIntegerBy(durationSeconds);

    console.log("\n--- Calculated Values ---");
    console.log(`Duration: ${durationDays} days (${durationSeconds.toString()} seconds)`);
    console.log(`Total Reward (atomic units): ${totalRewardAtomic.toString()}`);
    console.log(`Calculated Reward Rate (atomic units per second): ${rewardRate.toString()}`);

    const confirm = await prompts({
        type: 'confirm',
        name: 'value',
        message: `Confirm to proceed with rate ${rewardRate.toString()}?`,
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
    const newEndTime = Math.floor(Date.now() / 1000) + durationSeconds.toNumber();

    txb.moveCall({
        target: `${zoStaking.package}::pool::set_reward_rate`,
        typeArguments: [stakeCoinModule, rewardCoinModule],
        arguments: [
            txb.object(zoStaking.acl_control),
            txb.pure.string(roleName),
            txb.object(poolId),
            txb.object(CLOCK_ID),
            txb.pure.u128(rewardRate.toString()),
            txb.pure.u64(newEndTime.toString()),
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log(`\n🚀 Setting new reward period for pool ${poolId}...`);
        console.log(`  - New End Time: ${new Date(newEndTime * 1000).toLocaleString()}`);
        console.log(`  - New Rate: ${rewardRate.toString()}`);

        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true },
        });

        if (result.effects?.status.status === 'success') {
            console.log('✅ Successfully set new reward period.');
        } else {
            console.error('Transaction failed:', result.effects?.status.error);
        }

    } catch (error) {
        console.error('An error occurred:', error);
    }
}

main();
