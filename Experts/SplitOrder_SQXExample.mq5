//+------------------------------------------------------------------+
//| SplitOrder_SQXExample.mq5                                        |
//| Author: Martí Castany                                            |
//|                                                                  |
//| Example showing how to integrate SplitOrder into an SQX-generated|
//| strategy. This file simulates the minimum SQX structure: an      |
//| openPosition() function that the strategy's signal logic calls.  |
//|                                                                  |
//| Real SQX-generated files are much longer (thousands of lines)    |
//| but the openPosition() signature and the integration steps are   |
//| identical to what's shown here.                                  |
//|                                                                  |
//| -------------------------------------------------------------    |
//| FOR SQX USERS: the four integration steps are marked with ★      |
//| -------------------------------------------------------------    |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex"
#property version   "1.0"
#property strict

// ★ STEP 1: Add this include at the top of your SQX-generated .mq5 file
#include <SplitOrder/SplitOrderSQX.mqh>

//+------------------------------------------------------------------+
//| INPUTS (SQX-style)                                               |
//+------------------------------------------------------------------+
input double BaseLotSize    = 0.30;
input int    MagicNumber    = 12345;
input int    Slippage       = 5;

// SplitOrder inputs — add these alongside your existing SQX inputs
input string s_split        = "----------- Order Splitting -----------";
input int    SplitCount     = 3;
input int    SplitDelaySec  = 10;
input bool   SplitVerbose   = true;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   // ★ STEP 2: Initialize SplitOrder and start the timer
   SQXSplitInit(SplitCount, SplitDelaySec, SplitVerbose);
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
//| TIMER                                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // ★ STEP 3: Drive the split engine
   SQXSplitOnTimer();

   // (If your SQX strategy already has OnTimer content, add SQXSplitOnTimer()
   //  as the first or last line. The two don't conflict.)
  }

//+------------------------------------------------------------------+
//| TICK — your strategy signal logic                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   // This is placeholder signal logic. In a real SQX strategy, this
   // section contains your strategy's entry/exit rules, indicator
   // reads, pattern detection, etc.

   if(PositionSelect(Symbol()))
      return; // already in a position

   bool buySignal = false;  // <-- your actual signal
   if(!buySignal)
      return;

   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double sl  = NormalizeDouble(ask - 200 * _Point, _Digits);
   double tp  = NormalizeDouble(ask + 400 * _Point, _Digits);

   // ★ STEP 4: Replace every `openPosition(` with `openPositionSplit(`
   //
   // Before:
   //    openPosition(ORDER_TYPE_BUY, Symbol(), BaseLotSize, 0, sl, tp, ...);
   //
   // After:
   openPositionSplit(ORDER_TYPE_BUY, Symbol(), BaseLotSize, 0, sl, tp,
                     Slippage, "", MagicNumber, 0, true, true, false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//| MOCK SQX openPosition — simplified version of what SQX generates |
//|                                                                  |
//| In a real SQX-generated strategy, this function is ~150 lines    |
//| and handles pending orders, duplicate checks, retries, expiration|
//| etc. This simplified version is enough to make the example       |
//| compile and demonstrate the pattern.                             |
//|                                                                  |
//| DO NOT use this mock in production — your real SQX strategy has  |
//| the full openPosition already.                                   |
//|                                                                  |
//+------------------------------------------------------------------+
ulong openPosition(ENUM_ORDER_TYPE type, string symbol, double volume,
                   const double price = 0, const double slPrice = 0,
                   const double ptPrice = 0, const int deviation = 100,
                   const string comment = "", const int magicNo = -1,
                   const int expiration = 0, const bool replaceExisting = true,
                   const bool allowDuplicateTrades = true,
                   const bool isExitLevel = false)
  {
   if(volume <= 0) return(0);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   bool isPending = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT
                  || type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP);

   req.action       = isPending ? TRADE_ACTION_PENDING : TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.volume       = volume;
   req.type         = type;
   req.price        = (type == ORDER_TYPE_BUY)  ? SymbolInfoDouble(symbol, SYMBOL_ASK)
                    : (type == ORDER_TYPE_SELL) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                    : price;
   req.sl           = slPrice;
   req.tp           = ptPrice;
   req.deviation    = (ulong)deviation;
   req.magic        = (magicNo > 0) ? magicNo : 0;
   req.comment      = comment;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      return(0);
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return(0);

   return(res.order);
  }
//+------------------------------------------------------------------+
