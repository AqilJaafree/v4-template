# Cross-Pool Operations in Uniswap v4

This project implements cross-pool operations using Uniswap v4 hooks, enabling sophisticated trading strategies that trigger actions across multiple pools in a single transaction.

## Overview

The `CrossPoolHook` allows swaps in one pool to automatically trigger related swaps in another pool based on configurable thresholds and custom strategies. This enables advanced trading patterns, arbitrage opportunities, and liquidity balancing across multiple token pairs.

## Key Features

- **Pool Linking**: Create explicit connections between any two Uniswap v4 pools
- **Threshold-Based Triggers**: Configure minimum swap amounts that activate cross-pool actions
- **Cooldown Periods**: Prevent excessive operations with time-based rate limiting
- **Customizable Strategies**: Flexible logic for determining swap direction and amounts
- **Error Handling**: Graceful handling of failed cross-pool operations

## How It Works

1. A swap occurs in a source pool that exceeds the configured threshold
2. The hook detects this swap and determines if the cooldown period has passed
3. If conditions are met, the hook executes a related swap in the target pool
4. All operations happen within a single transaction, ensuring atomicity

## Implementation Details

The hook consists of several key components:

- `crossPoolLinks`: Maps source pools to their target pools
- `thresholds`: Stores minimum swap amounts for triggering cross-pool actions
- `lastActionTimestamp`: Tracks when each pool last triggered an action
- `_determineTargetSwapDirection()`: Logic that decides swap direction based on token relationships
- `_calculateTargetSwapAmount()`: Strategy for determining swap amount in target pool

## Example Use Cases

- **Arbitrage**: Automatically balance prices between related pools
- **Liquidity Management**: Distribute trading volume across pools with shared tokens
- **Risk Hedging**: Create protective positions in correlated assets
- **Complex Trading Paths**: Execute multi-token strategies in a single transaction

## Getting Started

### Prerequisites

- Forge/Foundry
- Uniswap v4 dependencies

### Installation

```bash
git clone https://github.com/yourusername/uniswap-v4-cross-pool
cd uniswap-v4-cross-pool
forge install
```

### Running Tests

```bash
forge test -vvv
```

### Deployment

Deploy to Anvil (local testnet):

```bash
forge script script/Anvil.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

## Advanced Configuration

### Creating Pool Links

```solidity
// Link Pool A to Pool B with a threshold of 0.1 tokens
hook.createCrossPoolLink(poolKeyA, poolKeyB, 1e17);
```

### Customizing Strategies

The hook allows for customization of two key strategy components:

1. **Swap Direction**: Modify `_determineTargetSwapDirection()` to change how the hook decides whether to swap zeroForOne or oneForZero in the target pool.

2. **Swap Amount**: Customize `_calculateTargetSwapAmount()` to implement more sophisticated strategies for determining how much to swap in the target pool.

## License

MIT

## Acknowledgments

- Uniswap Foundation for the v4-template
- Contributors to the Uniswap v4 core and periphery repositories