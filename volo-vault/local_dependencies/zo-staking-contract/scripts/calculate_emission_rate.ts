#!/usr/bin/env node

import prompts from 'prompts';
import Decimal from 'decimal.js';

// Set high precision for calculations
Decimal.set({ precision: 50 });

interface EmissionCalculation {
    rewardCoin: string;
    rewardCoinPrice: Decimal;
    targetTvl: Decimal;
    targetApy: Decimal;
    rewardCoinDecimals: number;
    annualRewardValue: Decimal;
    annualRewardTokens: Decimal;
    emissionRatePerSecond: Decimal;
    emissionRateAtomic: Decimal;
}

function calculateEmissionRate(
    targetTvl: Decimal,
    targetApy: Decimal,
    rewardCoinPrice: Decimal,
    rewardCoinDecimals: number
): EmissionCalculation {
    const SECONDS_PER_YEAR = new Decimal(365.25 * 24 * 60 * 60); // Account for leap years
    
    // Calculate annual reward value in USD
    const annualRewardValue = targetTvl.mul(targetApy.div(100));
    
    // Calculate annual reward tokens needed
    const annualRewardTokens = annualRewardValue.div(rewardCoinPrice);
    
    // Calculate emission rate per second (in token units)
    const emissionRatePerSecond = annualRewardTokens.div(SECONDS_PER_YEAR);
    
    // Convert to atomic units (multiply by 10^decimals)
    const emissionRateAtomic = emissionRatePerSecond.mul(new Decimal(10).pow(rewardCoinDecimals));
    
    return {
        rewardCoin: '',
        rewardCoinPrice,
        targetTvl,
        targetApy,
        rewardCoinDecimals,
        annualRewardValue,
        annualRewardTokens,
        emissionRatePerSecond,
        emissionRateAtomic
    };
}

function displayCalculationSummary(calc: EmissionCalculation) {
    console.log('\n=== EMISSION RATE CALCULATION SUMMARY ===');
    console.log(`Reward Coin: ${calc.rewardCoin}`);
    console.log(`Reward Coin Price: $${calc.rewardCoinPrice.toFixed(6)}`);
    console.log(`Target TVL: $${calc.targetTvl.toLocaleString()}`);
    console.log(`Target APY: ${calc.targetApy.toFixed(2)}%`);
    console.log(`Reward Coin Decimals: ${calc.rewardCoinDecimals}`);
    console.log('\n--- Calculated Values ---');
    console.log(`Annual Reward Value: $${calc.annualRewardValue.toLocaleString()}`);
    console.log(`Annual Reward Tokens: ${calc.annualRewardTokens.toFixed(6)} ${calc.rewardCoin}`);
    console.log(`Emission Rate: ${calc.emissionRatePerSecond.toFixed(10)} ${calc.rewardCoin}/second`);
    console.log(`Emission Rate (Atomic): ${calc.emissionRateAtomic.toFixed(0)} atomic units/second`);
    console.log('\n--- Verification ---');
    const dailyEmission = calc.emissionRatePerSecond.mul(86400);
    const monthlyEmission = dailyEmission.mul(30);
    const yearlyEmission = calc.emissionRatePerSecond.mul(365.25 * 24 * 60 * 60);
    console.log(`Daily Emission: ${dailyEmission.toFixed(6)} ${calc.rewardCoin}`);
    console.log(`Monthly Emission: ${monthlyEmission.toFixed(6)} ${calc.rewardCoin}`);
    console.log(`Yearly Emission: ${yearlyEmission.toFixed(6)} ${calc.rewardCoin}`);
    console.log(`Yearly Value: $${yearlyEmission.mul(calc.rewardCoinPrice).toLocaleString()}`);
}

async function main() {
    console.log('🎯 Token Emission Rate Calculator for Target APY\n');
    
    const inputs = await prompts([
        {
            type: 'text',
            name: 'rewardCoin',
            message: 'Enter reward coin name (e.g., sui, usdc):',
            initial: 'sui'
        },
        {
            type: 'text',
            name: 'rewardCoinPrice',
            message: 'Enter reward coin price in USD:',
            initial: '1.0',
            validate: (value: string) => {
                const num = parseFloat(value);
                return (!isNaN(num) && num > 0) || 'Price must be a valid number greater than 0';
            }
        },
        {
            type: 'number',
            name: 'rewardCoinDecimals',
            message: 'Enter reward coin decimals:',
            initial: 9,
            validate: (value: number) => value >= 0 && value <= 18 || 'Decimals must be between 0 and 18'
        },
        {
            type: 'number',
            name: 'targetTvl',
            message: 'Enter target TVL in USD:',
            validate: (value: number) => value > 0 || 'TVL must be greater than 0'
        },
        {
            type: 'number',
            name: 'targetApy',
            message: 'Enter target APY (as percentage, e.g., 15 for 15%):',
            validate: (value: number) => value > 0 && value <= 1000 || 'APY must be between 0 and 1000%'
        }
    ]);

    if (!inputs.rewardCoin || !inputs.rewardCoinPrice || !inputs.targetTvl || !inputs.targetApy) {
        console.error('❌ All inputs are required.');
        process.exit(1);
    }

    try {
        const calculation = calculateEmissionRate(
            new Decimal(inputs.targetTvl),
            new Decimal(inputs.targetApy),
            new Decimal(inputs.rewardCoinPrice),
            inputs.rewardCoinDecimals
        );
        
        calculation.rewardCoin = inputs.rewardCoin;
        
        displayCalculationSummary(calculation);
        
        const { shouldContinue } = await prompts({
            type: 'confirm',
            name: 'shouldContinue',
            message: '\nWould you like to calculate with different parameters?',
            initial: false
        });
        
        if (shouldContinue) {
            console.log('\n' + '='.repeat(50) + '\n');
            await main(); // Recursive call for new calculation
        } else {
            console.log('\n✅ Calculation complete!');
            console.log('\n💡 Usage Tips:');
            console.log('- Use the "Emission Rate (Atomic)" value as the reward_rate parameter');
            console.log('- Monitor actual TVL vs target TVL to adjust rates accordingly');
            console.log('- Consider token inflation impact on price over time');
            console.log('- Factor in potential changes in staking participation rates');
        }
        
    } catch (error) {
        console.error('❌ Calculation error:', error);
        process.exit(1);
    }
}

// Handle graceful exit
process.on('SIGINT', () => {
    console.log('\n\n👋 Goodbye!');
    process.exit(0);
});

main().catch(console.error);