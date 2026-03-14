#!/usr/bin/env node

import { exec } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import prompts from 'prompts';
import { promisify } from 'util';

const execAsync = promisify(exec);

interface DeploymentResult {
    package?: string;
    upgrade_cap?: string;
    pools?: string[];
    [key: string]: any;
}

interface Deployments {
    [packageName: string]: DeploymentResult;
}

interface SuiObjectChange {
    type: 'published' | 'created' | 'mutated' | 'transferred' | 'deleted';
    packageId?: string;
    objectType?: string;
    objectId?: string;
}

interface SuiTransactionEffects {
    status: {
        status: 'success' | 'failure';
    };
}

interface SuiDeploymentLog {
    effects: SuiTransactionEffects;
    objectChanges: SuiObjectChange[];
    events: any[];
}

function parseInitializeEvent(events: any[], packageId: string): Record<string, string> {
    const result: Record<string, string> = {};
    const eventType = `${packageId}::event::InitializeEvent`;
    const initializeEvent = events.find(event => event.type === eventType);

    if (initializeEvent && initializeEvent.parsedJson) {
        if (initializeEvent.parsedJson.admin_cap_id) {
            result['admin_cap'] = initializeEvent.parsedJson.admin_cap_id;
        }
        if (initializeEvent.parsedJson.acl_control_id) {
            result['acl_control'] = initializeEvent.parsedJson.acl_control_id;
        }
    }
    return result;
}

function parseDeployment(deployLog: SuiDeploymentLog, deploymentsPath: string, packageName: string): void {
    if (deployLog.effects.status.status !== 'success') {
        console.error("Deployment failed:", deployLog.effects);
        return;
    }

    let deployments: Deployments = {};
    try {
        if (fs.existsSync(deploymentsPath)) {
            const fileContent = fs.readFileSync(deploymentsPath, 'utf-8');
            deployments = JSON.parse(fileContent) as Deployments;
        }
    } catch (error) {
        console.warn(`Could not read or parse ${deploymentsPath}, starting fresh.`);
        deployments = {};
    }

    const deploymentResult: DeploymentResult = {};

    for (const change of deployLog.objectChanges) {
        if (change.type === 'published') {
            deploymentResult['package'] = change.packageId;
            const eventData = parseInitializeEvent(deployLog.events, change.packageId!);
            Object.assign(deploymentResult, eventData);
        } else if (change.objectType === '0x2::package::UpgradeCap') {
            deploymentResult['upgrade_cap'] = change.objectId;
        } 
    }

    if (!deployments[packageName]) {
        deployments[packageName] = {};
    }

    if (!deployments[packageName].pools) {
        deployments[packageName].pools = [];
    }

    deployments[packageName] = { ...deployments[packageName], ...deploymentResult };

    try {
        fs.writeFileSync(deploymentsPath, JSON.stringify(deployments, null, 4));
        console.log(`\n✅ Update ${deploymentsPath} for package "${packageName}" finished!`);
        console.log(JSON.stringify(deployments[packageName], null, 2));
    } catch (error) {
        console.error(`Failed to write to ${deploymentsPath}:`, error);
    }
}


async function main() {
    try {
        const response = await prompts([
            {
                type: 'text',
                name: 'envName',
                message: 'Enter the environment name',
                initial: 'testnet'
            },
            {
                type: 'text',
                name: 'gasBudget',
                message: 'Enter the gas budget',
                initial: '5000000000' // 5 SUI
            },
            {
                type: 'text',
                name: 'packageName',
                message: 'Enter the package name for deployments file',
                initial: 'zo_staking'
            }
        ]);

        const { envName, gasBudget, packageName } = response;

        if (!packageName) {
            console.error('Package name cannot be empty.');
            process.exit(1);
        }

        const projectRoot = path.join(__dirname, '..');
        const deploymentsPath = path.join(projectRoot, `deployments-${envName}.json`);

        const cmd = [
            "sui",
            "client",
            "publish",
            "--gas-budget",
            gasBudget,
            "--json",
        ].join(' ');

        console.log(`\n📦 Publishing contract...`);
        console.log(`> ${cmd}`);

        const { stdout, stderr } = await execAsync(cmd, { cwd: projectRoot });

        if (stderr) {
            console.error("Stderr from sui client:", stderr);
        }

        let deployLog: SuiDeploymentLog;
        try {
            deployLog = JSON.parse(stdout);
            console.log(JSON.stringify(deployLog, null, 2));
        } catch (error) {
            console.error("Error: Invalid JSON output from sui client.");
            console.error("Raw stdout:", stdout);
            process.exit(1);
        }

        parseDeployment(deployLog, deploymentsPath, packageName);

    } catch (error) {
        if (error && typeof error === 'object' && 'stderr' in error) {
            const execError = error as { stderr: string };
            console.error("❌ Deployment command failed. Error from sui client:");
            console.error(execError.stderr);
        } else {
            console.error(`An unexpected error occurred:`, error);
        }
        process.exit(1);
    }
}

main();