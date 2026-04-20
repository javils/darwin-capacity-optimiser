//+------------------------------------------------------------------+
//| SplitOrder.mqh                                                   |
//| Author: Martí Castany                                            |
//| Drop-in order splitting library for MetaTrader 5                 |
//|                                                                  |
//| Splits a single trade into N child orders fired sequentially     |
//| with configurable delays, to reduce slippage at scale.           |
//|                                                                  |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex"
#property version   "1.0"
#property strict

#ifndef SPLIT_ORDER_MQH
#define SPLIT_ORDER_MQH

#include "SplitOrderConfig.mqh"

//+------------------------------------------------------------------+
//| CONSTANTS                                                        |
//+------------------------------------------------------------------+
#define SPLIT_MAX_POSITIONS 10

//+------------------------------------------------------------------+
//| PHASE ENUM — drives the state machine                            |
//+------------------------------------------------------------------+
enum ENUM_SPLIT_PHASE
  {
   SPLIT_PHASE_IDLE     = 0,  // No active split
   SPLIT_PHASE_PENDING  = 1,  // Pos0 is a pending order, waiting for fill
   SPLIT_PHASE_ACTIVE   = 2,  // Firing entries and/or monitoring pos0
   SPLIT_PHASE_CLOSING  = 3   // Sequential close chain (TP hit or cancel)
  };

//+------------------------------------------------------------------+
//| STATE STRUCT — one instance per direction (long / short)         |
//+------------------------------------------------------------------+
struct SplitState
  {
   // Identity
   string            symbol;
   ENUM_ORDER_TYPE   direction;        // ORDER_TYPE_BUY or ORDER_TYPE_SELL
   int               splitCount;       // Actual count (may be < config if lots too small)

   // Tickets
   ulong             tickets[SPLIT_MAX_POSITIONS];

   // Phase
   ENUM_SPLIT_PHASE  phase;

   // Entry state
   int               nextEntry;        // Next child index to fire (1..splitCount-1)
   datetime          entryFireTime;    // When to fire next entry
   int               entryRetries;     // Current retry counter for active entry

   // Close chain state
   int               nextClose;        // Next index to close
   datetime          closeFireTime;    // When to fire next close

   // Lot sizes
   double            totalLots;        // Original intended total volume
   double            childLots;        // Per-child lot size (splits 1..N-1)

   // Position data from pos0
   double            sl;               // Stop loss price

   // Tracking
   double            executedVolume;   // Sum of all filled child volumes
  };

//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS — Internal helpers (prefixed with _Split)   |
//+------------------------------------------------------------------+
void   _SplitComputePlan(string symbol, double totalLots, int requested,
                         double &pos0Lots, double &childLots, int &actualSplits);
double _SplitRoundLots(string symbol, double lots);
bool   _SplitPositionExists(ulong ticket);
bool   _SplitIsPendingOrder(ulong ticket);
bool   _SplitHitSL(ulong positionTicket);
void   _SplitOpenMarket(const SplitState &state, const SplitConfig &cfg, ulong &outTicket);
void   _SplitCloseTicket(ulong ticket, const SplitConfig &cfg);
void   _SplitLog(const SplitState &state, const SplitConfig &cfg, string msg);
ENUM_ORDER_TYPE_FILLING _SplitDetectFillingMode(string symbol);

//+------------------------------------------------------------------+
//|                                                                  |
//|                        PUBLIC API                                |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| SplitReset — clear all state to idle                             |
//+------------------------------------------------------------------+
void SplitReset(SplitState &state)
  {
   ArrayInitialize(state.tickets, 0);
   state.symbol         = "";
   state.direction      = ORDER_TYPE_BUY;
   state.splitCount     = 0;
   state.phase          = SPLIT_PHASE_IDLE;
   state.nextEntry      = 0;
   state.entryFireTime  = 0;
   state.entryRetries   = 0;
   state.nextClose      = 0;
   state.closeFireTime  = 0;
   state.totalLots      = 0;
   state.childLots      = 0;
   state.sl             = 0;
   state.executedVolume = 0;
  }

//+------------------------------------------------------------------+
//| SplitIsActive — true if any split operation is in progress       |
//+------------------------------------------------------------------+
bool SplitIsActive(const SplitState &state)
  {
   return(state.phase != SPLIT_PHASE_IDLE);
  }

//+------------------------------------------------------------------+
//| SplitGetExecutedVolume — total volume successfully filled        |
//+------------------------------------------------------------------+
double SplitGetExecutedVolume(const SplitState &state)
  {
   return(state.executedVolume);
  }

//+------------------------------------------------------------------+
//| SplitAdjustLots                                                  |
//|                                                                  |
//| Returns the lot size the EA should use for its own order (pos0). |
//| Pos0 carries the rounding remainder so total volume is preserved.|
//|                                                                  |
//| Call BEFORE placing your initial order.                          |
//| If splitting is not possible (lots too small), returns totalLots |
//| unchanged (no splitting will occur).                             |
//+------------------------------------------------------------------+
double SplitAdjustLots(string symbol, double totalLots, const SplitConfig &cfg)
  {
   double pos0Lots, childLots;
   int    actualSplits;
   _SplitComputePlan(symbol, totalLots, cfg.splitCount, pos0Lots, childLots, actualSplits);
   return(pos0Lots);
  }

//+------------------------------------------------------------------+
//| SplitRegister                                                    |
//|                                                                  |
//| Call AFTER your initial order fills (or is placed as pending).   |
//| Seeds the state machine so SplitManage() can take over.          |
//|                                                                  |
//| Parameters:                                                      |
//|   state     — the SplitState instance (splitLong or splitShort)  |
//|   ticket    — pos0 ticket from your OrderSend result             |
//|   cfg       — shared config                                      |
//|   totalLots — original FULL lot size before splitting            |
//|   isPending — true if ticket is a pending order, not yet filled  |
//+------------------------------------------------------------------+
void SplitRegister(SplitState &state, ulong ticket, const SplitConfig &cfg,
                   double totalLots, bool isPending = false)
  {
   SplitReset(state);

   // Compute the split plan
   double pos0Lots, childLots;
   int    actualSplits;

   // Determine symbol: try reading from position, fall back to current
   string sym = Symbol();
   if(!isPending && PositionSelectByTicket(ticket))
      sym = PositionGetString(POSITION_SYMBOL);

   _SplitComputePlan(sym, totalLots, cfg.splitCount, pos0Lots, childLots, actualSplits);

   // No splitting needed
   if(actualSplits <= 1)
     {
      _SplitLog(state, cfg, StringFormat(
         "Split count reduced to 1 (lots=%.5f too small to split). No splitting.", totalLots));
      return;
     }

   // Initialize state
   state.symbol     = sym;
   state.splitCount = actualSplits;
   state.totalLots  = totalLots;
   state.childLots  = childLots;
   state.tickets[0] = ticket;

   if(isPending)
     {
      state.phase = SPLIT_PHASE_PENDING;
      _SplitLog(state, cfg, StringFormat(
         "Registered pending order #%d — %d splits, child lots=%.5f",
         ticket, actualSplits, childLots));
     }
   else
     {
      if(!PositionSelectByTicket(ticket))
        {
         _SplitLog(state, cfg, StringFormat(
            "ERROR: ticket #%d not found as open position. Aborting.", ticket));
         SplitReset(state);
         return;
        }

      state.direction     = (ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE);
      state.sl            = PositionGetDouble(POSITION_SL);
      state.executedVolume= PositionGetDouble(POSITION_VOLUME);
      state.phase         = SPLIT_PHASE_ACTIVE;
      state.nextEntry     = 1;
      state.entryFireTime = TimeCurrent() + cfg.delaySeconds;
      state.entryRetries  = 0;

      _SplitLog(state, cfg, StringFormat(
         "Registered %s #%d — %d splits, child lots=%.5f, SL=%.5f, next fire in %ds",
         (state.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         ticket, actualSplits, childLots, state.sl, cfg.delaySeconds));
     }
  }

//+------------------------------------------------------------------+
//| SplitManage                                                      |
//|                                                                  |
//| The engine. Call this from OnTimer() every ~1 second.            |
//| Handles all phases: pending wait, entry firing, pos0 monitoring, |
//| and TP/cancel close chains.                                      |
//+------------------------------------------------------------------+
void SplitManage(SplitState &state, const SplitConfig &cfg)
  {
   if(state.phase == SPLIT_PHASE_IDLE)
      return;

   datetime now = TimeCurrent();

   //--- PHASE: PENDING — waiting for pending order to fill --------
   if(state.phase == SPLIT_PHASE_PENDING)
     {
      _SplitManagePending(state, cfg, now);
      return;
     }

   //--- PHASE: ACTIVE — firing entries + monitoring pos0 ----------
   if(state.phase == SPLIT_PHASE_ACTIVE)
     {
      _SplitManageActive(state, cfg, now);
      return;
     }

   //--- PHASE: CLOSING — sequential close chain -------------------
   if(state.phase == SPLIT_PHASE_CLOSING)
     {
      _SplitManageClosing(state, cfg, now);
      return;
     }
  }

//+------------------------------------------------------------------+
//| SplitCancelAndClose                                              |
//|                                                                  |
//| Abort the split: stop firing new entries and sequentially close  |
//| all open split positions. Use for EOD close, signal reversal,    |
//| or any reason the EA wants to unwind the whole thing.            |
//|                                                                  |
//| Closes are staggered by delaySeconds, starting immediately.      |
//+------------------------------------------------------------------+
void SplitCancelAndClose(SplitState &state, const SplitConfig &cfg)
  {
   if(state.phase == SPLIT_PHASE_IDLE)
      return;

   _SplitLog(state, cfg, "Cancel requested — closing all split positions");

   state.phase         = SPLIT_PHASE_CLOSING;
   state.nextEntry     = state.splitCount; // Stop any new entries
   state.nextClose     = 0;                // Start from pos0
   state.closeFireTime = TimeCurrent();    // Fire immediately
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|                    PHASE HANDLERS (internal)                     |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Handle PENDING phase                                             |
//+------------------------------------------------------------------+
void _SplitManagePending(SplitState &state, const SplitConfig &cfg, datetime now)
  {
   ulong ticket = state.tickets[0];

   // Still a pending order?
   if(_SplitIsPendingOrder(ticket))
      return; // Keep waiting

   // Filled as a position?
   if(PositionSelectByTicket(ticket))
     {
      state.direction      = (ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE);
      state.sl             = PositionGetDouble(POSITION_SL);
      state.executedVolume = PositionGetDouble(POSITION_VOLUME);
      state.phase          = SPLIT_PHASE_ACTIVE;
      state.nextEntry      = 1;
      state.entryFireTime  = now + cfg.delaySeconds;
      state.entryRetries   = 0;

      _SplitLog(state, cfg, StringFormat(
         "Pending #%d filled as %s — starting entry chain",
         ticket, (state.direction == ORDER_TYPE_BUY ? "BUY" : "SELL")));
      return;
     }

   // Neither pending nor position — cancelled or expired
   _SplitLog(state, cfg, StringFormat("Pending #%d cancelled/expired — aborting split", ticket));
   SplitReset(state);
  }

//+------------------------------------------------------------------+
//| Handle ACTIVE phase — fire entries + monitor pos0                |
//+------------------------------------------------------------------+
void _SplitManageActive(SplitState &state, const SplitConfig &cfg, datetime now)
  {
   //--- 1. Monitor pos0 for close --------------------------------
   if(state.tickets[0] > 0)
     {
      if(!_SplitPositionExists(state.tickets[0]))
        {
         bool slHit = _SplitHitSL(state.tickets[0]);
         _SplitLog(state, cfg, StringFormat(
            "Pos0 #%d closed — SL=%s", state.tickets[0], (slHit ? "YES" : "NO (TP/manual)")));

         if(slHit)
           {
            // SL hit: each split has its own SL, let broker handle them.
            // Stop firing new entries but don't force-close existing splits.
            _SplitLog(state, cfg, "SL hit on pos0 — splits ride their own SL. Done.");
            SplitReset(state);
            return;
           }
         else
           {
            // TP or manual close: begin closing remaining splits sequentially
            state.nextEntry     = state.splitCount; // Stop new entries
            state.tickets[0]    = 0;
            state.phase         = SPLIT_PHASE_CLOSING;
            state.nextClose     = 1;
            state.closeFireTime = now + cfg.delaySeconds;
            _SplitLog(state, cfg, "TP/manual close on pos0 — starting close chain for splits");
            return;
           }
        }
     }

   //--- 2. Fire next entry if due --------------------------------
   if(state.nextEntry > 0 && state.nextEntry < state.splitCount && now >= state.entryFireTime)
     {
      ulong newTicket = 0;
      _SplitOpenMarket(state, cfg, newTicket);

      if(newTicket > 0)
        {
         state.tickets[state.nextEntry] = newTicket;

         // Track executed volume
         if(PositionSelectByTicket(newTicket))
            state.executedVolume += PositionGetDouble(POSITION_VOLUME);

         _SplitLog(state, cfg, StringFormat(
            "Entry %d/%d fired — ticket #%d, lots=%.5f",
            state.nextEntry + 1, state.splitCount, newTicket, state.childLots));

         state.nextEntry++;
         state.entryRetries = 0;

         if(state.nextEntry < state.splitCount)
            state.entryFireTime = now + cfg.delaySeconds;
         else
            _SplitLog(state, cfg, "All entries filled — monitoring pos0");
        }
      else
        {
         // Order failed — retry or skip
         state.entryRetries++;
         if(state.entryRetries >= cfg.maxRetries)
           {
            _SplitLog(state, cfg, StringFormat(
               "WARNING: Entry %d/%d failed after %d retries — skipping (%.5f lots lost)",
               state.nextEntry + 1, state.splitCount, cfg.maxRetries, state.childLots));

            state.nextEntry++;
            state.entryRetries = 0;

            if(state.nextEntry < state.splitCount)
               state.entryFireTime = now + cfg.delaySeconds;
           }
         else
           {
            _SplitLog(state, cfg, StringFormat(
               "Entry %d/%d failed — retry %d/%d in %ds",
               state.nextEntry + 1, state.splitCount,
               state.entryRetries, cfg.maxRetries, cfg.retryDelaySeconds));
            state.entryFireTime = now + cfg.retryDelaySeconds;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Handle CLOSING phase — sequential close chain                    |
//+------------------------------------------------------------------+
void _SplitManageClosing(SplitState &state, const SplitConfig &cfg, datetime now)
  {
   if(state.nextClose >= state.splitCount)
     {
      _SplitLog(state, cfg, "Close chain complete");
      SplitReset(state);
      return;
     }

   if(now < state.closeFireTime)
      return;

   ulong ticket = state.tickets[state.nextClose];

   if(ticket > 0 && _SplitPositionExists(ticket))
     {
      _SplitCloseTicket(ticket, cfg);
      _SplitLog(state, cfg, StringFormat(
         "Close chain: closed split %d — ticket #%d", state.nextClose, ticket));
     }

   state.tickets[state.nextClose] = 0;
   state.nextClose++;

   if(state.nextClose >= state.splitCount)
     {
      _SplitLog(state, cfg, "Close chain complete");
      SplitReset(state);
     }
   else
      state.closeFireTime = now + cfg.delaySeconds;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|                    INTERNAL HELPERS                               |
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Compute the split plan: pos0 lots, child lots, actual count      |
//|                                                                  |
//| Pos0 carries the rounding remainder so total volume is preserved.|
//| If child lots fall below VOLUME_MIN, split count is reduced.     |
//+------------------------------------------------------------------+
void _SplitComputePlan(string symbol, double totalLots, int requested,
                       double &pos0Lots, double &childLots, int &actualSplits)
  {
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   // Clamp requested splits
   int sc = MathMax(1, MathMin(SPLIT_MAX_POSITIONS, requested));

   if(sc <= 1 || totalLots <= 0)
     {
      pos0Lots     = totalLots;
      childLots    = 0;
      actualSplits = 1;
      return;
     }

   // Guard against bad symbol info
   if(step <= 0) step = 0.01;
   if(minLot <= 0) minLot = step;

   // Compute base child lot size, reducing split count if needed
   double baseLots = 0;
   while(sc > 1)
     {
      baseLots = NormalizeDouble(MathFloor(totalLots / sc / step) * step, 8);
      if(baseLots >= minLot)
         break;
      sc--;
     }

   if(sc <= 1)
     {
      pos0Lots     = totalLots;
      childLots    = 0;
      actualSplits = 1;
      return;
     }

   // Remainder goes to pos0
   double remainder = NormalizeDouble(totalLots - baseLots * sc, 8);
   pos0Lots     = NormalizeDouble(baseLots + remainder, 8);
   childLots    = baseLots;
   actualSplits = sc;
  }

//+------------------------------------------------------------------+
//| Round lots to symbol's volume step, respecting min/max           |
//+------------------------------------------------------------------+
double _SplitRoundLots(string symbol, double lots)
  {
   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0) step = 0.01;

   double rounded = NormalizeDouble(MathFloor(lots / step) * step, 8);

   if(rounded < minLot) return(0);
   if(rounded > maxLot) rounded = maxLot;

   return(rounded);
  }

//+------------------------------------------------------------------+
//| Check if a ticket exists as an open position                     |
//+------------------------------------------------------------------+
bool _SplitPositionExists(ulong ticket)
  {
   return(PositionSelectByTicket(ticket));
  }

//+------------------------------------------------------------------+
//| Check if a ticket is still a pending order                       |
//+------------------------------------------------------------------+
bool _SplitIsPendingOrder(ulong ticket)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == ticket)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Check if a position was closed by SL (via deal history)          |
//+------------------------------------------------------------------+
bool _SplitHitSL(ulong positionTicket)
  {
   HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent());

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);

      // Match by position ID
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionTicket)
         continue;

      // Only look at exit deals
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      // Check if the reason was SL
      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
      return(reason == DEAL_REASON_SL);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Open a market order for a child split position                   |
//+------------------------------------------------------------------+
void _SplitOpenMarket(const SplitState &state, const SplitConfig &cfg, ulong &outTicket)
  {
   outTicket = 0;

   double lots = _SplitRoundLots(state.symbol, state.childLots);
   if(lots <= 0)
      return;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = state.symbol;
   req.volume       = lots;
   req.type         = state.direction;
   req.price        = (state.direction == ORDER_TYPE_BUY)
                      ? SymbolInfoDouble(state.symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(state.symbol, SYMBOL_BID);
   req.sl           = NormalizeDouble(state.sl, (int)SymbolInfoInteger(state.symbol, SYMBOL_DIGITS));
   req.tp           = 0;
   req.deviation    = (ulong)cfg.slippage;
   req.magic        = cfg.magic;
   req.type_filling = _SplitDetectFillingMode(state.symbol);
   req.comment      = "SplitOrder child";

   if(OrderSend(req, res))
     {
      if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
         outTicket = res.order;
     }
  }

//+------------------------------------------------------------------+
//| Close a single position by ticket                                |
//+------------------------------------------------------------------+
void _SplitCloseTicket(ulong ticket, const SplitConfig &cfg)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   string sym = PositionGetString(POSITION_SYMBOL);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = sym;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.type         = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = (req.type == ORDER_TYPE_SELL)
                      ? SymbolInfoDouble(sym, SYMBOL_BID)
                      : SymbolInfoDouble(sym, SYMBOL_ASK);
   req.deviation    = (ulong)cfg.slippage;
   req.magic        = cfg.magic;
   req.type_filling = _SplitDetectFillingMode(sym);
   req.comment      = "SplitOrder close";

   OrderSend(req, res);
  }

//+------------------------------------------------------------------+
//| Detect the appropriate filling mode for a symbol                 |
//|                                                                  |
//| Reads SYMBOL_FILLING_MODE bitmask and picks the best option:     |
//|   1. IOC  — preferred (accepts partial fills)                    |
//|   2. FOK  — fallback (all-or-nothing)                            |
//|   3. RETURN — last resort (exchange-style default)               |
//|                                                                  |
//| Matches the logic used by CTrade::SetTypeFillingBySymbol().      |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING _SplitDetectFillingMode(string symbol)
  {
   int mode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   if((mode & SYMBOL_FILLING_IOC) != 0)
      return(ORDER_FILLING_IOC);

   if((mode & SYMBOL_FILLING_FOK) != 0)
      return(ORDER_FILLING_FOK);

   return(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
//| Log helper — prints with [SplitOrder] prefix and direction       |
//+------------------------------------------------------------------+
void _SplitLog(const SplitState &state, const SplitConfig &cfg, string msg)
  {
   if(!cfg.verbose)
      return;

   string dir = "---";
   if(state.phase != SPLIT_PHASE_IDLE)
      dir = (state.direction == ORDER_TYPE_BUY) ? "LONG" : "SHORT";

   Print("[SplitOrder][", dir, "] ", msg);
  }

#endif // SPLIT_ORDER_MQH
//+------------------------------------------------------------------+
