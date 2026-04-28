## What's in here

```
SQXSnippets/
└── SQ/
    ├── TradingOptions/
    │   └── SplitMarketOrderWithDelay.java
    └── MonteCarlo/
        └── Retest/
            └── RandomizeSplitOrders.java
```

### `SplitMarketOrderWithDelay`

A Trading Option that splits each strategy market entry into K children of
size N/K, spaced by a configurable delay, each with its own SL/TP relative
to its own fill price. Children close together with the parent — the same
exit semantics the SplitOrder MQL5 library implements on MT5 via OnTimer.

This lets you backtest the impact of split execution inside SQX (Builder,
Retester, Optimizer, Walk-Forward) before exporting the strategy to MT5
and patching the `.mq5` with `SQXSplitInstaller`.

UI parameters (under category **Split options**):

| Parameter | Default | Description |
|-----------|---------|-------------|
| Split market orders with delay | off | Master toggle. Off by default — must be enabled per strategy. |
| Split count K | 3 | Total number of child positions per signal, including the first. Range: 2 to 100. |
| Delay seconds | 10 | Seconds between consecutive child orders. Range: 1 to 300. |

### `RandomizeSplitOrders`

A Monte Carlo retest manipulation that, on each Monte Carlo iteration,
picks a random K and a random delay within configurable ranges and feeds
them to the active `SplitMarketOrderWithDelay` Trading Option. Use it to
estimate strategy robustness when live execution can't guarantee exact K
and delay values — the same logical model as randomizing slippage or
spread, but applied to the split parameters themselves.

Requires `SplitMarketOrderWithDelay` to be enabled on the strategy.

UI parameters (under category **Split MC**):

| Parameter | Default | Description |
|-----------|---------|-------------|
| Min K | 2 | Lower bound (inclusive) for the random Split count K. |
| Max K | 5 | Upper bound (inclusive) for the random Split count K. |
| Min delay seconds | 5 | Lower bound (inclusive) for the random delay. |
| Max delay seconds | 30 | Upper bound (inclusive) for the random delay. |

## Installation

1. Close SQX
2. Copy each `.java` file to its matching path under `<SQX-install-folder>/user/extend/Snippets/`, preserving the folder structure:
   ```
   SQ/TradingOptions/SplitMarketOrderWithDelay.java
   SQ/MonteCarlo/Retest/RandomizeSplitOrders.java
   ```
   The folder names must match the `package` declarations in each file exactly — SQX uses the path to discover snippets.
3. Open SQX. SQX will compile the snippets automatically on startup; if it doesn't, run *Tools → CodeEditor → Compile All* and restart.

## Usage

### Split Trading Option

1. Open or create a strategy (Builder, Retester, AlgoWizard)
2. Go to *Full settings → Trading options*
3. Scroll to the **Split options** section
4. Enable **Split market orders with delay**
5. Configure **Split count K** and **Delay seconds**
6. Run the backtest

Every market entry the strategy opens will be transparently split into K
children spaced by the delay. The trade list will show K rows per signal,
all sharing the same close type as the parent (Exit Signal, Exit After X
Bars, SL, TP, etc.).

### Monte Carlo over split parameters

1. Go to *Monte Carlo settings*
2. Add **Randomize Split Orders** to the list of manipulations
3. Set Min/Max K and Min/Max delay seconds
4. Run Monte Carlo

Each Monte Carlo iteration will draw a random `(K, delay)` pair from the
ranges and apply it for that entire backtest run. The Monte Carlo report
shows the resulting distribution of Net Profit, Profit Factor, Drawdown,
etc. under variable execution.

## Limitations
- **Tick-precision recommended.** With bar-precision data the delay
  between children is rounded to the nearest bar.
- **Engines: MT4 and MT5 only.** Tradestation/MultiCharts do not support
  multiple same-direction positions with independent exits and are not
  supported by this snippet.

