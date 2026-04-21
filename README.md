# Darwin Capacity Optimiser

**Drop-in order splitting for MetaTrader 5 — reduce slippage at scale.**

> [!WARNING]
> **Alpha software — use at your own risk.**
>
> This is **alpha-stage code** and has not been battle-tested across brokers, symbols, or live market conditions. It is **your responsibility** to thoroughly review the source, test the library on a demo account, and verify its behaviour end-to-end before deploying it with real funds.
>
> The authors and contributors accept **no liability** for trading losses, execution errors, partial fills, missed closes, slippage, broker rejections, or any other financial or operational consequence arising from the use of this software. The library is provided **"AS IS"**, without warranties of any kind — see the [LICENSE](./LICENSE) (Apache License 2.0, Sections 7 and 8) for the full disclaimer.

When trade volume grows, executing a single large market order generates slippage. In copy-trading setups, copied orders for investors can carry significantly higher volume than the original strategy, amplifying slippage and causing returns divergence.

This library splits a trade into N smaller orders fired sequentially with configurable delays, giving the order book time to recover between fills. Integration requires **three lines of code** in your EA.

## The problem

A strategy trading 0.10 lots has negligible market impact. But when that strategy is copied across hundreds of investor accounts, the aggregated volume can be substantial. A single 5-lot market order on a thin book will walk the price far beyond the quoted spread. Splitting it into 5 × 1.0 lot orders spaced 10 seconds apart lets liquidity replenish between fills.

## Quick start

1. Copy the `Include/SplitOrder/` folder into your MQL5 `Include/` directory.
2. Add three lines to your EA:

```mql5
#include <SplitOrder/SplitOrder.mqh>

// In OnInit():
SplitConfig splitCfg;
SplitConfigInit(splitCfg);
splitCfg.splitCount   = 3;    // Split into 3 orders
splitCfg.delaySeconds = 10;   // 10 seconds apart
splitCfg.magic        = 12345;
EventSetTimer(1);              // 1-second timer for the engine

SplitState splitLong, splitShort;
SplitReset(splitLong);
SplitReset(splitShort);

// In OnTimer():
SplitManage(splitLong,  splitCfg);
SplitManage(splitShort, splitCfg);

// When opening a buy:
double totalLots = 0.30;                                       // Your original lot size
double pos0Lots  = SplitAdjustLots(Symbol(), totalLots, splitCfg); // ★ Returns 0.12 (0.10 + 0.02 remainder)
// ... your normal OrderSend with pos0Lots ...
SplitRegister(splitLong, ticket, splitCfg, totalLots);            // ★ Library handles the rest
```

That's it. The library fires the remaining 2 child orders automatically, 10 seconds apart, with the same SL and direction.

## Using with StrategyQuant X (SQX)

Every SQX-generated strategy uses a standard `openPosition()` function as the single entry point for all order placement. The library ships with a dedicated SQX adapter that provides `openPositionSplit()` — a drop-in replacement with the **identical signature**. Integration is four mechanical steps that anyone (or an LLM) can apply to any SQX-generated strategy file:

```mql5
// 1. Add the include at the top of your .mq5 file:
#include <SplitOrder/SplitOrderSQX.mqh>

// 2. In OnInit(), add:
SQXSplitInit(3, 10);   // 3 splits, 10 seconds apart
EventSetTimer(1);

// 3. In OnTimer() (create one if your strategy doesn't have it), add:
SQXSplitOnTimer();

// 4. Find-and-replace across the file:
//    openPosition(  →  openPositionSplit(
```

That's everything. The adapter hides all the state machine complexity: no `SplitState` variables to declare, no `SplitRegister` to call, no `SplitConfig` to build. It automatically decides whether to split each order based on its type:

- **Market entries** (`BUY` / `SELL` with `isExitLevel = false`) → split into N child orders.
- **Pending orders** (`BUY_STOP`, `SELL_LIMIT`, etc.) → pass through unchanged.
- **Exit-level orders** (`isExitLevel = true`) → pass through unchanged. These are typically EOD closes, stop-reverses, or signal-driven exits where splitting would leave partial exposure during the close window.
- **Volume too small to split** → pass through unchanged.

Pos0 is still sent through SQX's own `openPosition()`, so all of SQX's existing protections remain in force: margin checks, duplicate detection, `sqHandleTradingOptions()` gate (weekend filter, EOD, time range, max trades per day), `orderSendWithRetries`, pending order replacement, etc.

**Note on SQX trading-options gate**: child orders bypass `sqHandleTradingOptions()` because they're fired directly by the library engine, not through `openPosition()`. In practice this only matters if a child is scheduled to fire across an SQX gate boundary — for example, pos0 fills at 17:59:55 with a 10-second delay and an EOD cutoff at 18:00:00. For typical split delays (5–30 seconds) this edge case is rare. If it matters for your setup, keep delays modest or avoid placing entries in the last minute before an SQX cutoff.

## Using with CTrade

The library is agnostic about how you place your first order. If your EA uses the standard `CTrade` class from `<Trade/Trade.mqh>`, integration works exactly the same way — just grab the ticket from `trade.ResultOrder()`:

```mql5
#include <Trade/Trade.mqh>
#include <SplitOrder/SplitOrder.mqh>

CTrade      trade;
SplitConfig splitCfg;
SplitState  splitLong;

void OpenBuy()
{
    double totalLots = 0.30;

    // ★ Step 1: Adjust lot size
    double pos0Lots = SplitAdjustLots(Symbol(), totalLots, splitCfg);

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double sl  = NormalizeDouble(ask - 200 * _Point, _Digits);

    // --- Normal CTrade call, unchanged ---
    if(!trade.Buy(pos0Lots, Symbol(), ask, sl, 0))
        return;

    // ★ Step 2: Register the ticket
    SplitRegister(splitLong, trade.ResultOrder(), splitCfg, totalLots);
}
```

The library internally uses `MqlTradeRequest` for child orders to avoid interfering with your `CTrade` instance's state (particularly `ResultXxx()` values your EA may check).

## How it works

### Entry splitting

1. Your EA calculates its normal lot size (e.g., 0.30 lots).
2. `SplitAdjustLots()` divides it into N equal parts, respecting the symbol's `VOLUME_STEP` and `VOLUME_MIN`. The first order (pos0) carries any rounding remainder so total volume is preserved.
3. Your EA sends pos0 as a normal `OrderSend()`.
4. `SplitRegister()` seeds a state machine with the pos0 ticket.
5. `SplitManage()` (called every second from `OnTimer()`) fires the remaining N-1 child orders at the configured delay interval. Each child gets the same SL as pos0.

### Exit handling

The library monitors pos0 for closure:

- **SL hit**: Each child position has its own broker-side SL, so they'll be stopped out independently. The library resets and does nothing — SL exits are urgent, and the broker handles them.
- **TP or manual close**: The library detects that pos0 closed without SL, then sequentially closes remaining split positions with the same delay interval. This prevents slippage on the exit side too.

### Cancellation

Call `SplitCancelAndClose()` to abort a split sequence (for EOD close, signal reversal, etc.). It stops firing new entries and sequentially closes all open split positions with delays.

### Error handling

If a child order fails (requote, insufficient margin, etc.), the library retries up to `maxRetries` times with a short delay. If all retries fail, it logs a warning with the missing volume and continues with the next child. The EA can check `SplitGetExecutedVolume()` to verify how much was actually filled.

### Broker compatibility

The library auto-detects the appropriate order filling mode for each symbol by reading `SYMBOL_FILLING_MODE`, preferring IOC where available and falling back to FOK or RETURN. This matches the logic used by `CTrade::SetTypeFillingBySymbol()` and works across brokers with different execution models.

## API reference

### Configuration

```mql5
struct SplitConfig {
    int    splitCount;         // Total positions including pos0 (2-10)
    int    delaySeconds;       // Seconds between each child order
    double slippage;           // Max slippage in points
    int    maxRetries;         // Retries per failed child order (default: 3)
    int    retryDelaySeconds;  // Seconds between retries (default: 2)
    int    magic;              // EA magic number for child orders
    bool   verbose;            // Print detailed logs (default: true)
};

void SplitConfigInit(SplitConfig &cfg);  // Initialize with defaults
```

### Functions

| Function | Description |
|----------|-------------|
| `SplitAdjustLots(symbol, totalLots, cfg)` | Returns the lot size for pos0 (includes rounding remainder). Call **before** your `OrderSend`. |
| `SplitRegister(state, ticket, cfg, totalLots)` | Register a filled order for splitting. Pass the **original total lots**, not the adjusted amount. Optional `isPending` flag for pending orders. |
| `SplitManage(state, cfg)` | The engine — call from `OnTimer()` every 1 second. Handles entry firing, monitoring, and close chains. |
| `SplitCancelAndClose(state, cfg)` | Abort: stops new entries and sequentially closes all open splits. |
| `SplitReset(state)` | Clear all state to idle. |
| `SplitIsActive(state)` | Returns `true` if a split operation is in progress. |
| `SplitGetExecutedVolume(state)` | Returns total volume successfully filled across all child orders. |

### Lot distribution example

0.30 lots split into 4 with `VOLUME_STEP = 0.01`:
- Base per split: `floor(0.30 / 4 / 0.01) * 0.01 = 0.07`
- Total at base: `0.07 × 4 = 0.28`
- Remainder: `0.30 − 0.28 = 0.02`
- **Pos0**: 0.09 lots (0.07 + 0.02 remainder)
- **Pos1–3**: 0.07 lots each
- **Total**: 0.09 + 0.07 × 3 = 0.30 ✓

## Repo structure

```
darwin-capacity-optimiser/
├── Include/
│   └── SplitOrder/
│       ├── SplitOrder.mqh            ← The library (core)
│       ├── SplitOrderConfig.mqh      ← Config struct
│       └── SplitOrderSQX.mqh         ← SQX adapter (thin layer on core)
├── Experts/
│   └── Examples/
│       ├── SplitOrder_Example.mq5     ← DIY integration example
│       ├── SplitOrder_SQXExample.mq5  ← SQX integration example
│       └── SplitOrder_TestEA.mq5      ← Random-signal test EA
├── README.md
└── LICENSE
```

## Testing on a demo account

The repo ships with `SplitOrder_TestEA.mq5`, a simple EA that opens a random BUY or SELL every minute — provided no position is already open — with symmetric SL/TP distances so you get a mix of both exit paths to watch. Attach it to an EURUSD chart on a demo account, open the Experts tab, and you'll see:

- Pos0 opening at the adjusted lot size (including rounding remainder).
- Child orders firing sequentially at the configured delay.
- On TP: the library's sequential close chain on remaining children.
- On SL: each child being stopped out independently on its own broker SL.

Default settings are 0.05 lots split into 3 (pos0 = 0.03, children = 0.01 each) with 10-second delays, 20 pip SL/TP, and random signal every 1 minute. All parameters are exposed as inputs.

## Limitations (v1)

- **One split per direction**: Supports one active long split and one active short split simultaneously. Multiple concurrent splits in the same direction (pyramiding) are not supported.
- **Market orders only**: Child orders are market orders. Splitting pending orders (placing N pending orders) is not supported.
- **No persistence across restarts**: If the terminal restarts mid-split, pending child orders are lost. The EA will have a partial position, which it can handle through its normal logic.
- **No TP on children**: Child orders are placed without TP. Exit is managed either by their individual SL or by the close chain when pos0 exits.

## License

Licensed under the **Apache License, Version 2.0**. See the [LICENSE](./LICENSE) file for the full text.

## Contributing

Issues and PRs welcome. Please test on a demo account before submitting changes.
