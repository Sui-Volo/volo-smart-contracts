import * as fs from 'fs';
import * as path from 'path';

import dotenv from 'dotenv';
dotenv.config();

import {
    SuiClient,
    GetCoinsParams,
    GetOwnedObjectsParams,
} from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { fromHex } from '@mysten/sui/utils';

// --- Re-usable constants ---

export const CLOCK_ID = "0x6";

// --- Network & Signer ---

export function getRpcUrl(network: string): string {
    switch (network) {
        case "localnet":
            return "http://127.0.0.1:9000";
        case "testnet":
            return "https://fullnode.testnet.sui.io:443";
        case "devnet":
            return "https://fullnode.devnet.sui.io:443";
        case "mainnet":
            return "https://fullnode.mainnet.sui.io:443";
        default:
            throw new Error(`Unknown network: ${network}`);
    }
}

export function getClient(network: string): SuiClient {
    return new SuiClient({ url: getRpcUrl(network) });
}

export function getKeypair(): Ed25519Keypair {
    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        throw new Error("PRIVATE_KEY environment variable not set. Please create a .env file with your private key.");
    }
    // Assuming key is hex encoded, remove '0x' if present
    const cleanPrivateKey = privateKey.startsWith('0x') ? privateKey.substring(2) : privateKey;
    return Ed25519Keypair.fromSecretKey(fromHex(cleanPrivateKey));
}

export function getSigner(): Ed25519Keypair {
    const keypair = getKeypair();
    console.log(`Using address: ${keypair.toSuiAddress()}`);
    return keypair;
}


// --- Deployments File Management ---

function getDeploymentsPath(env: string): string {
    return path.join(__dirname, `../deployments-${env}.json`);
}

export function getDeployments(env: string): any {
    const deploymentsPath = getDeploymentsPath(env);
    try {
        if (fs.existsSync(deploymentsPath)) {
            return JSON.parse(fs.readFileSync(deploymentsPath, 'utf-8'));
        }
        console.log(`Deployment file not found at ${deploymentsPath}, returning empty object.`);
        return {};
    } catch (error) {
        console.warn(`Could not read or parse ${deploymentsPath}, returning empty object. Error: ${error}`);
        return {};
    }
}

export function updateDeployments(env: string, data: any): void {
    const deploymentsPath = getDeploymentsPath(env);
    try {
        fs.writeFileSync(deploymentsPath, JSON.stringify(data, null, 4));
        console.log(`Successfully updated ${deploymentsPath}`);
    } catch (error) {
        console.error(`Failed to write to ${deploymentsPath}:`, error);
    }
}


// --- On-chain Interaction Helpers ---

export async function sleep(seconds: number) {
    return new Promise<void>((resolve) => {
        setTimeout(resolve, seconds * 1000)
    })
}

export async function logBalance(client: SuiClient, owner: string) {
    let resp = await client.getAllBalances({ owner: owner })
    console.log("Account Balances:");
    for (let item of resp) {
        let balance = parseInt(item.totalBalance)
        if (balance == 0) {
            continue
        }
        console.log(`  - ${(balance / 1e9).toFixed(4)} ${item.coinType.split("::")[2]}`);
    }
}

export async function getAllCoins(client: SuiClient, owner: string, coinType: string): Promise<any[]> {
    let allCoins: any[] = [];
    let nextCursor: string | null = null;
    while (true) {
        const params: GetCoinsParams = { owner, coinType };
        if (nextCursor) {
            params.cursor = nextCursor;
        }
        const resp = await client.getCoins(params);
        allCoins = [...allCoins, ...resp.data];

        if (!resp.hasNextPage || !resp.nextCursor) {
            break;
        }
        nextCursor = resp.nextCursor;
    }
    return allCoins;
}

export async function getOwnedObjects(
    client: SuiClient,
    owner: string,
    packageId: string,
    module: string,
): Promise<any[]> {
    let objectIds: any[] = [];
    let nextCursor: string | null = null;
    const options: GetOwnedObjectsParams = {
        owner,
        limit: 50,
        options: { showType: true },
        filter: {
            MoveModule: {
                module,
                package: packageId,
            }
        },
    };

    while (true) {
        if (nextCursor) {
            options.cursor = nextCursor;
        }
        const resp = await client.getOwnedObjects(options);
        for (let item of resp.data) {
            if (item.data) {
                objectIds.push(item.data.objectId);
            }
        }
        if (!resp.hasNextPage || !resp.nextCursor) {
            break;
        }
        nextCursor = resp.nextCursor;
    }
    return objectIds;
}

export async function getObject(client: SuiClient, objectId: string): Promise<any> {
    return client.getObject({
        id: objectId,
        options: { showType: true, showContent: true },
    });
}

// merge and split a specific amount of coin
export async function splitCoin(
    client: SuiClient,
    owner: string,
    coinType: string,
    txb: Transaction,
    amount: number,
): Promise<any> {
    if (coinType.toLowerCase().includes("sui")) {
        const [coin] = txb.splitCoins(txb.gas, [txb.pure.u64(amount.toString())]);
        return coin;
    }

    const coins = await getAllCoins(client, owner, coinType);
    if (coins.length === 0) {
        throw new Error(`No coins of type ${coinType} found for owner ${owner}`);
    }

    const [primaryCoin, ...mergeCoins] = coins.map(c => txb.object(c.coinObjectId));

    if (mergeCoins.length > 0) {
        txb.mergeCoins(primaryCoin, mergeCoins);
    }

    const [splitCoin] = txb.splitCoins(primaryCoin, [txb.pure.u64(amount.toString())]);
    return splitCoin;
}

export async function getTransaction(client: SuiClient, digest: string): Promise<any> {
    const resp = await client.getTransactionBlock({
        digest: digest,
        options: {
            showEvents: true,
            showInput: true,
            showEffects: true,
        },
    });
    return resp;
}