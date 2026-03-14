#!/usr/bin/env node

import prompts from 'prompts';
import {
    getDeployments,
    getClient,
    getSigner,
} from './utils';
import { Transaction } from '@mysten/sui/transactions';

async function main() {
    const { env, gasBudget, roleName } = await prompts([
        { type: 'text', name: 'env', message: 'Enter env name', initial: 'testnet' },
        { type: 'number', name: 'gasBudget', message: 'Enter gas budget', initial: 1000000000 },
        { type: 'text', name: 'roleName', message: 'Enter the role name to add (e.g., operator)' },
    ]);

    if (!roleName) {
        console.error('Role name is required.');
        process.exit(1);
    }

    const deployments = getDeployments(env);
    const client = getClient(env);
    const signer = getSigner();

    const zoStaking = deployments.zo_staking;

    if (!zoStaking.admin_cap || !zoStaking.acl_control) {
        console.error('admin_cap or acl_control not found in deployments file. Please deploy the contract first.');
        process.exit(1);
    }

    const txb = new Transaction();

    txb.moveCall({
        target: `${zoStaking.package}::admin::add_role`,
        arguments: [
            txb.object(zoStaking.admin_cap),
            txb.object(zoStaking.acl_control),
            txb.pure.string(roleName),
        ],
    });

    txb.setGasBudget(gasBudget);

    try {
        console.log(`\n🚀 Adding role "${roleName}" to ACL ${zoStaking.acl_control}...`);

        const result = await client.signAndExecuteTransaction({
            transaction: txb,
            signer: signer,
            options: { showEffects: true },
        });

        if (result.effects?.status.status === 'success') {
            console.log('✅ Successfully added role.');
        } else {
            console.error('Transaction failed:', result.effects?.status.error);
        }

    } catch (error) {
        console.error('An error occurred:', error);
    }
}

main();
