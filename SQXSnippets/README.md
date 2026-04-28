## What's in here

```
SQXSnippets/
└── SQ/
    └── TradingOptions/
        └── SplitMarketOrderWithDelay.java
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

## Installation

1. Close SQX
2. Copy `SQ/TradingOptions/SplitMarketOrderWithDelay.java` to: `<SQX-install-folder>/user/extend/Snippets/SQ/TradingOptions/`.
   The folder name `SQ/TradingOptions/` must match the package declaration in the file exactly — SQX uses the path to discover the snippet.
3. Open SQX. SQX will compile the snippet automatically on startup; if it doesn't, run *Tools → CodeEditor → Compile All* and restart.

## Usage

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

## Limitations
- **Tick-precision recommended.** With bar-precision data the delay
  between children is rounded to the nearest bar.
- **Engines: MT4 and MT5 only.** Tradestation/MultiCharts do not support
  multiple same-direction positions with independent exits and are not
  supported by this snippet.

