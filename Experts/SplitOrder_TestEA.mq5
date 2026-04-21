//+------------------------------------------------------------------+
//| SplitOrder_TestEA.mq5                                            |
//| Author: Martí Castany                                            |
//|                                                                  |
//| Test EA for the SplitOrder library (DIY / non-SQX integration).  |
//|                                                                  |
//| Opens a random BUY or SELL on a configurable symbol every N      |
//| minutes, provided no position or active split already exists.    |
//| Symmetric SL / TP distances mean roughly half the trades exit on |
//| SL and half on TP, which exercises both close paths:             |
//|                                                                  |
//|   - TP hit  → library runs the sequential close chain            |
//|   - SL hit  → each child is stopped out on its own broker SL     |
//|                                                                  |
//| Use this to verify the library works on your broker / instrument |
//| before putting it in a live strategy.                            |
//|                                                                  |
//|    DEMO ACCOUNT ONLY. This EA places random trades.              |
//|                                                                  |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex"
#property version   "1.0"
#property strict

#include <SplitOrder/SplitOrder.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input string s_ea            = "----------- Test EA -----------";
input string TradeSymbol     = "EURUSD";   // Instrument to trade
input double LotSize         = 0.05;       // Full intended volume (before splitting)
input int    SLPoints        = 200;        // Stop loss in points (20 pips on 5-digit FX)
input int    TPPoints        = 200;        // Take profit in points
input int    SignalMinutes   = 1;          // Evaluate signal every N minutes
input int    MagicNumber     = 90210;

input string s_split         = "----------- Split Config -----------";
input int    InpSplitCount   = 3;          // Number of child orders including pos0
input int    InpSplitDelay   = 10;         // Seconds between children
input double InpSlippage     = 5.0;        // Slippage in points
input bool   InpVerbose      = true;       // Print library logs

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
SplitConfig cfg;
SplitState  splitLong;
SplitState  splitShort;
datetime    lastSignalTime = 0;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Seed RNG so each run produces a different direction sequence
   MathSrand((int)GetTickCount());

   // Make sure the symbol is in Market Watch and tradable
   if(!SymbolSelect(TradeSymbol, true))
     {
      Print("[TestEA] ERROR — symbol ", TradeSymbol, " not available. Aborting.");
      return(INIT_FAILED);
     }

   // Configure split
   SplitConfigInit(cfg);
   cfg.splitCount   = InpSplitCount;
   cfg.delaySeconds = InpSplitDelay;
   cfg.slippage     = InpSlippage;
   cfg.magic        = MagicNumber;
   cfg.verbose      = InpVerbose;

   SplitReset(splitLong);
   SplitReset(splitShort);

   EventSetTimer(1);

   Print("[TestEA] Started on ", TradeSymbol,
         " — signal every ", SignalMinutes, " min",
         ", lots=", LotSize,
         ", SL=", SLPoints, "p TP=", TPPoints, "p",
         ", splits=", InpSplitCount, "x", InpSplitDelay, "s");

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
//| TIMER                                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // 1. Drive the split state machines every second
   SplitManage(splitLong,  cfg);
   SplitManage(splitShort, cfg);

   // 2. Evaluate a new random signal every SignalMinutes
   datetime now = TimeCurrent();
   if(now - lastSignalTime < SignalMinutes * 60)
      return;

   lastSignalTime = now;
   EvaluateSignal();
  }

//+------------------------------------------------------------------+
//| TICK — unused; all logic is timer-driven                         |
//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
//| EvaluateSignal — pick a random direction if no activity          |
//+------------------------------------------------------------------+
void EvaluateSignal()
  {
   if(HasActivityOnSymbol())
     {
      if(InpVerbose)
         Print("[TestEA] Signal skipped — position or active split on ", TradeSymbol);
      return;
     }

   // Coin flip
   bool goLong = (MathRand() % 2 == 0);
   OpenRandomTrade(goLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| HasActivityOnSymbol — true if any position with our magic exists |
//| on TradeSymbol, or either split state machine is running.        |
//+------------------------------------------------------------------+
bool HasActivityOnSymbol()
  {
   if(SplitIsActive(splitLong) || SplitIsActive(splitShort))
      return(true);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol)  continue;
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| OpenRandomTrade — send pos0 in the given direction, register it  |
//+------------------------------------------------------------------+
void OpenRandomTrade(ENUM_ORDER_TYPE direction)
  {
   // ★ Step 1: get the pos0 lot size (carries any rounding remainder)
   double pos0Lots = SplitAdjustLots(TradeSymbol, LotSize, cfg);

   int    digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   bool   isBuy  = (direction == ORDER_TYPE_BUY);
   double entry  = isBuy ? SymbolInfoDouble(TradeSymbol, SYMBOL_ASK)
                         : SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double sl     = isBuy ? NormalizeDouble(entry - SLPoints * point, digits)
                         : NormalizeDouble(entry + SLPoints * point, digits);
   double tp     = isBuy ? NormalizeDouble(entry + TPPoints * point, digits)
                         : NormalizeDouble(entry - TPPoints * point, digits);

   Print("[TestEA] ", (isBuy ? "BUY" : "SELL"), " signal — entry=", entry,
         " sl=", sl, " tp=", tp, " pos0=", pos0Lots, " (total=", LotSize, ")");

   //--- Send pos0 (normal OrderSend) ------------------------------
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = TradeSymbol;
   req.volume       = pos0Lots;
   req.type         = direction;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = (ulong)InpSlippage;
   req.magic        = MagicNumber;
   req.comment      = "TestEA pos0";
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
     {
      Print("[TestEA] OrderSend failed — error=", GetLastError());
      return;
     }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
     {
      Print("[TestEA] Order rejected — retcode=", res.retcode);
      return;
     }

   Print("[TestEA] pos0 opened — ticket #", res.order);

   // ★ Step 2: register for splitting (library fires remaining children)
   if(isBuy)
      SplitRegister(splitLong,  res.order, cfg, LotSize);
   else
      SplitRegister(splitShort, res.order, cfg, LotSize);
  }
//+------------------------------------------------------------------+
