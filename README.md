## Volo Smart Contracts (Sui Move)

Core Move packages for the Volo protocol on Sui. This repository includes on-chain modules and the common commands used to build, publish, and upgrade the contracts.

## ⚙️ Requirements

- Sui CLI installed and configured (`sui client`)
- A funded publisher account (for gas)

## 🧱 Build

```bash
sui move build
```

## 🚀 Publish / Upgrade

**Publish**

```bash
sui client publish --gas-budget 100000000
```

**Publish (skip dependency verification)**

```bash
sui client publish --gas-budget 100000000 --skip-dependency-verification
```

**Upgrade**

```bash
sui client upgrade --gas-budget 100000000 --upgrade-capability ${upgradeCap}
```

Notes:

- Replace `${upgradeCap}` with your upgrade capability object ID.
- Adjust `--gas-budget` based on network conditions and package size.

## 🔒 Security

Bug Bounty Program: `https://hackenproof.com/companies/navi-protocol`

