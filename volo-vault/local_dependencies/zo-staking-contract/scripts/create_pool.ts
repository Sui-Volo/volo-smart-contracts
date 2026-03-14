#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    updateDeployments,
    getClient,
    getSigner,
} from './utils';
import { Transaction } from '@mysten/sui/transactions';

function parseCreatePoolEvent(events: any[], packageId: string): string | undefined {
    const eventType = `${packageId}::event::CreatePoolEvent`;
    const createPoolEvent = events.find(event => event.type === eventType);
    if (createPoolEvent) {
        return createPoolEvent.parsedJson.id;
    }
    return undefined;
}


async function main() {
    // Calculate default times
    const now = Math.floor(Date.now() / 1000); // Current time in seconds
    const defaultStartTime = now + (60 * 60); // Now + 1 hour
    const defaultEndTime = defaultStartTime + (6 * 30 * 24 * 60 * 60); // 6 months from start time (approximately)

    const { env, gasBudget, stakeCoin, rewardCoin, startTime, endTime, lockDuration } = await prompts([
        { type: 'text', name: 'env', message: 'Enter env name', initial: 'testnet' },
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'stakeCoin', message: 'Enter staking coin name (e.g., sui)', initial: 'sui' },
        { type: 'text', name: 'rewardCoin', message: 'Enter reward coin name (e.g., sui)', initial: 'sui' },
        {
            type: 'number',
            name: 'startTime',
            message: 'Enter start timestamp (seconds)',
            initial: defaultStartTime
        },
        {
            type: 'number',
            name: 'endTime',
            message: 'Enter end timestamp (seconds)',
            initial: defaultEndTime
        },
        { type: 'number', name: 'lockDuration', message: 'Enter lock duration (seconds)', initial: 0 },
    ]);

    if (!startTime || !endTime) {
        console.error('Start time and end time are required.');
        process.exit(1);
    }

    const deployments = getDeployments(env);
    const client = getClient(env);
    const signer = getSigner();

    const zoStaking = deployments.zo_staking;
    const coinModules = deployments.coin_modules;

    const stakeCoinModule = coinModules[stakeCoin.toLowerCase()].module;
    const rewardCoinModule = coinModules[rewardCoin.toLowerCase()].module;

    if (!stakeCoinModule || !rewardCoinModule) {
        console.error(`Coin module for ${stakeCoin} or ${rewardCoin} not found in deployments.`);
        process.exit(1);
    }

    const txb = new Transaction();

    txb.moveCall({
        target: `${zoStaking.package}::pool::create_pool`,
        typeArguments: [stakeCoinModule, rewardCoinModule],
        arguments: [
            txb.object(zoStaking.admin_cap),
            txb.object('0x6'), // Clock
            txb.pure.u64(Number(startTime)),
            txb.pure.u64(Number(endTime)),
            txb.pure.u64(Number(lockDuration)),
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log('🚀 Creating new pool...');
        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true, showEvents: true },
        });

        if (result.effects?.status.status !== 'success') {
            console.error('Transaction failed:', result.effects?.status.error);
            return;
        }

        const poolId = parseCreatePoolEvent(result.events || [], zoStaking.package);

        if (poolId) {
            console.log(`✅ New pool created with ID: ${poolId}`);

            if (!zoStaking.pools) {
                zoStaking.pools = [];
            }
            zoStaking.pools.push(poolId);

            updateDeployments(env, deployments);
            console.log(`📝 deployments-${env}.json has been updated.`);

        } else {
            console.error('Could not find created pool object in transaction result.');
        }

    } catch (error) {
        console.error('An error occurred during pool creation:', error);
    }
}

main();
