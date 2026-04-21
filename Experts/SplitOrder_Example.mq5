//+------------------------------------------------------------------+
//| SplitOrder_Example.mq5                                           |
//| Author: Martí Castany                                            |
//| Minimal EA showing how to integrate the SplitOrder library       |
//|                                                                  |
//| This EA does NOT contain real trading logic. It demonstrates the |
//| before/after pattern for adding order splitting to any EA.       |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex"
#property version   "1.0"
#property strict

#include <SplitOrder/SplitOrder.mqh>

//+------------------------------------------------------------------+
//| EA INPUTS                                                        |
//+------------------------------------------------------------------+
input string s0                = "----------- Trading -----------";
input double BaseLotSize       = 0.10;
input double StopLossPoints    = 200;
input int    EAMagic           = 12345;

input string s1                = "----------- Split Order -----------";
input bool   UseSplitting      = true;
input int    InpSplitCount     = 3;
input int    InpSplitDelay     = 10;
input double InpSplitSlippage  = 5.0;
input int    InpSplitRetries   = 3;
input bool   InpSplitVerbose   = true;

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
SplitConfig splitCfg;
SplitState  splitLong;
SplitState  splitShort;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Initialize split config from inputs
   SplitConfigInit(splitCfg);
   splitCfg.splitCount        = InpSplitCount;
   splitCfg.delaySeconds      = InpSplitDelay;
   splitCfg.slippage          = InpSplitSlippage;
   splitCfg.maxRetries        = InpSplitRetries;
   splitCfg.magic             = EAMagic;
   splitCfg.verbose           = InpSplitVerbose;

   // Initialize split state
   SplitReset(splitLong);
   SplitReset(splitShort);

   // 1-second timer for split order management
   if(UseSplitting)
      EventSetTimer(1);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| TIMER — drives the split state machine                           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!UseSplitting) return;

   SplitManage(splitLong,  splitCfg);
   SplitManage(splitShort, splitCfg);
  }

//+------------------------------------------------------------------+
//| TICK — your normal EA logic goes here                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ================================================================
   // Your normal signal logic here. Below is a placeholder that
   // opens a buy when no position exists. Replace with your strategy.
   // ================================================================

   // Example: check if we already have a position or active split
   if(PositionSelect(Symbol()) || SplitIsActive(splitLong))
      return;

   bool buySignal = false;  // <-- replace with your signal

   if(buySignal)
      OpenBuyExample();
  }

//+------------------------------------------------------------------+
//| EXAMPLE: Opening a buy with split support                        |
//|                                                                  |
//| Lines marked ★ are the only changes vs. a non-split EA.         |
//+------------------------------------------------------------------+
void OpenBuyExample()
  {
   double lots = BaseLotSize;

   // ★ Step 1: Adjust lot size for splitting
   if(UseSplitting)
      lots = SplitAdjustLots(Symbol(), lots, splitCfg);

   // --- Normal order send (unchanged) ---
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - StopLossPoints * _Point, _Digits);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = Symbol();
   req.volume       = lots;
   req.type         = ORDER_TYPE_BUY;
   req.price        = ask;
   req.sl           = sl;
   req.tp           = 0;
   req.deviation    = (ulong)InpSplitSlippage;
   req.magic        = EAMagic;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      return;
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return;

   ulong ticket = res.order;
   Print("Pos0 opened: ticket #", ticket, " lots=", lots);

   // ★ Step 2: Register the split
   if(UseSplitting)
      SplitRegister(splitLong, ticket, splitCfg, BaseLotSize);
                    // Note: pass BaseLotSize (the ORIGINAL total), not the adjusted lots
  }

//+------------------------------------------------------------------+
//| EXAMPLE: Opening a sell (same pattern)                           |
//+------------------------------------------------------------------+
void OpenSellExample()
  {
   double lots = BaseLotSize;

   // ★ Adjust lots
   if(UseSplitting)
      lots = SplitAdjustLots(Symbol(), lots, splitCfg);

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double sl  = NormalizeDouble(bid + StopLossPoints * _Point, _Digits);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = Symbol();
   req.volume       = lots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = bid;
   req.sl           = sl;
   req.tp           = 0;
   req.deviation    = (ulong)InpSplitSlippage;
   req.magic        = EAMagic;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      return;
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return;

   ulong ticket = res.order;
   Print("Pos0 opened: ticket #", ticket, " lots=", lots);

   // ★ Register the split
   if(UseSplitting)
      SplitRegister(splitShort, ticket, splitCfg, BaseLotSize);
  }

//+------------------------------------------------------------------+
//| EXAMPLE: Cancel and close all splits (e.g. for EOD)              |
//+------------------------------------------------------------------+
void CloseEverythingExample()
  {
   // ★ If splits are active, use the cancel function for staggered close
   if(UseSplitting)
     {
      if(SplitIsActive(splitLong))
         SplitCancelAndClose(splitLong, splitCfg);
      if(SplitIsActive(splitShort))
         SplitCancelAndClose(splitShort, splitCfg);
      return;
     }

   // Non-split path: normal close logic
   // ...
  }
//+------------------------------------------------------------------+
