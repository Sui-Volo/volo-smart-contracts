#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    getClient,
    getSigner,
    CLOCK_ID,
    splitCoin,
} from './utils';
import { Transaction } from '@mysten/sui/transactions';

async function main() {
    const { env } = await prompts([
        { type: 'text', name: 'env', message: 'Enter env name', initial: 'testnet' },
    ]);

    if (!env) {
        console.error('Environment is required.');
        process.exit(1);
    }

    const deployments = getDeployments(env);
    const client = getClient(env);
    const signer = getSigner();
    const signerAddress = signer.toSuiAddress();

    const zoStaking = deployments.zo_staking;

    if (!zoStaking.pools || zoStaking.pools.length === 0) {
        console.error('No pools found in deployments file for this environment.');
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
            message: 'Select a pool to add reward to:',
            choices: zoStaking.pools.map((id: string) => ({ title: id, value: id })),
        });
        poolId = choice.poolId;
    }

    if (!poolId) {
        console.error('No pool selected. Exiting.');
        process.exit(1);
    }

    const { gasBudget, stakeCoin, rewardCoin, amount } = await prompts([
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'stakeCoin', message: 'Enter staking coin name (e.g., usdz)', initial: 'usdz' },
        { type: 'text', name: 'rewardCoin', message: 'Enter reward coin name (e.g., sui)', initial: 'sui' },
        { type: 'number', name: 'amount', message: 'Enter the amount of reward to add (e.g., 1 = 1 sui)', initial: 1 },
    ]);

    if (!amount) {
        console.error('Amount is required.');
        process.exit(1);
    }
    const coinModules = deployments.coin_modules;

    const stakeCoinModule = coinModules[stakeCoin.toLowerCase()].module;
    const rewardCoinModule = coinModules[rewardCoin.toLowerCase()].module;
    const rewardCoinDecimals = coinModules[rewardCoin.toLowerCase()].decimals;

    if (!stakeCoinModule || !rewardCoinModule) {
        console.error(`Coin module for ${stakeCoin} or ${rewardCoin} not found in deployments.`);
        process.exit(1);
    }

    const txb = new Transaction();

    // Prepare the reward coin object
    const rewardCoinObject = await splitCoin(client, signerAddress, rewardCoinModule, txb, Number(amount) * 10 ** rewardCoinDecimals);

    txb.moveCall({
        target: `${zoStaking.package}::pool::add_reward`,
        typeArguments: [stakeCoinModule, rewardCoinModule],
        arguments: [
            txb.object(poolId),
            txb.object(CLOCK_ID),
            rewardCoinObject,
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log(`🚀 Adding ${amount} ${rewardCoin} reward to pool ${poolId}...`);
        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true },
        });

        if (result.effects?.status.status === 'success') {
            console.log('✅ Successfully added reward to the pool.');
        } else {
            console.error('Transaction failed:', result.effects?.status.error);
        }

    } catch (error) {
        console.error('An error occurred while adding reward:', error);
    }
}

main();
