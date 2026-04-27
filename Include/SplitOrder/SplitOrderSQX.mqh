//+------------------------------------------------------------------+
//| SplitOrderSQX.mqh                                                |
//| Author: Martí Castany                                            |
//| SQX adapter for SplitOrder library                               |
//|                                                                  |
//| Provides openPositionSplit() — a drop-in replacement for SQX's   |
//| openPosition() with the same signature. Splits market entries    |
//| transparently; passes through pending, exit-level, and too-small |
//| orders unchanged.                                                |
//|                                                                  |
//| Integration in an SQX-generated strategy:                        |
//|   1. #include <SplitOrder/SplitOrderSQX.mqh>                     |
//|   2. OnInit:   SQXSplitInit(3, 10);                              |
//|                EventSetTimer(1);                                 |
//|   3. OnTimer:  SQXSplitOnTimer();                                |
//|   4. Find-and-replace: openPosition() → openPositionSplit()      |
//|                                                                  |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex"
#property version   "1.0"
#property strict

#ifndef SPLIT_ORDER_SQX_MQH
#define SPLIT_ORDER_SQX_MQH

#include "SplitOrder.mqh"

//+------------------------------------------------------------------+
//| FORWARD DECLARATION                                              |
//|                                                                  |
//| The real openPosition() is defined in the SQX-generated strategy |
//| file itself. This adapter is #include'd into that file, so the   |
//| compiler resolves openPosition() at link time within the same    |
//| translation unit.                                                |
//|                                                                  |
//| Signature must match SQX's exactly (as of SQX build 138+).       |
//+------------------------------------------------------------------+
ulong openPosition(ENUM_ORDER_TYPE type, string symbol, double volume,
                   const double price = 0, const double slPrice = 0,
                   const double ptPrice = 0, const int deviation = 100,
                   const string comment = "", const int magicNo = -1,
                   const int expiration = 0, const bool replaceExisting = true,
                   const bool allowDuplicateTrades = true,
                   const bool isExitLevel = false);

//+------------------------------------------------------------------+
//| INTERNAL STATE — not exposed to the user                         |
//+------------------------------------------------------------------+
SplitConfig _sqxSplitCfg;
SplitState  _sqxSplitLong;
SplitState  _sqxSplitShort;
bool        _sqxSplitInitialized = false;

// PUBLIC API

//+------------------------------------------------------------------+
//| SQXSplitInit — one-line setup, call from OnInit()                |
//|                                                                  |
//|   splitCount    — total positions including pos0 (2-10)          |
//|   delaySeconds  — seconds between each child order               |
//|   verbose       — print detailed logs (default: true)            |
//+------------------------------------------------------------------+
void SQXSplitInit(int splitCount, int delaySeconds, bool verbose = true)
  {
   SplitConfigInit(_sqxSplitCfg);
   _sqxSplitCfg.splitCount   = splitCount;
   _sqxSplitCfg.delaySeconds = delaySeconds;
   _sqxSplitCfg.verbose      = verbose;

   SplitReset(_sqxSplitLong);
   SplitReset(_sqxSplitShort);

   _sqxSplitInitialized = true;

   if(verbose)
      Print("[SplitOrderSQX] Initialized — splitCount=", splitCount,
            ", delaySeconds=", delaySeconds);
  }

//+------------------------------------------------------------------+
//| SQXSplitOnTimer — call from OnTimer() every 1 second             |
//+------------------------------------------------------------------+
void SQXSplitOnTimer()
  {
   if(!_sqxSplitInitialized)
      return;

   SplitManage(_sqxSplitLong,  _sqxSplitCfg);
   SplitManage(_sqxSplitShort, _sqxSplitCfg);
  }

//+------------------------------------------------------------------+
//| openPositionSplit — drop-in replacement for SQX's openPosition   |
//|                                                                  |
//| Decision tree:                                                   |
//|   - Pending order            → pass through (no split)           |
//|   - isExitLevel = true       → pass through (no split)           |
//|   - Not initialized          → pass through (no split)           |
//|   - splitCount <= 1          → pass through (no split)           |
//|   - Active split in same dir → pass through (no split)           |
//|   - Volume too small         → pass through (handled by library) |
//|   - Otherwise                → send pos0 via openPosition,       |
//|                                register for split chain          |
//+------------------------------------------------------------------+
ulong openPositionSplit(ENUM_ORDER_TYPE type, string symbol, double volume,
                        const double price = 0, const double slPrice = 0,
                        const double ptPrice = 0, const int deviation = 100,
                        const string comment = "", const int magicNo = -1,
                        const int expiration = 0, const bool replaceExisting = true,
                        const bool allowDuplicateTrades = true,
                        const bool isExitLevel = false)
  {
   bool isMarketOrder = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_SELL);

   //--- Pass-through cases ----------------------------------------
   bool passThrough = !isMarketOrder
                   || isExitLevel
                   || !_sqxSplitInitialized
                   || _sqxSplitCfg.splitCount <= 1;

   if(!passThrough)
     {
      // Active split already running in this direction? Pass through.
      if(type == ORDER_TYPE_BUY && SplitIsActive(_sqxSplitLong))
        {
         if(_sqxSplitCfg.verbose)
            Print("[SplitOrderSQX] Long split already active — passing through unchanged");
         passThrough = true;
        }
      else if(type == ORDER_TYPE_SELL && SplitIsActive(_sqxSplitShort))
        {
         if(_sqxSplitCfg.verbose)
            Print("[SplitOrderSQX] Short split already active — passing through unchanged");
         passThrough = true;
        }
     }

   if(passThrough)
     {
      return openPosition(type, symbol, volume, price, slPrice, ptPrice,
                          deviation, comment, magicNo, expiration,
                          replaceExisting, allowDuplicateTrades, isExitLevel);
     }

   //--- Split path -------------------------------------------------

   // Sync per-call settings into our config so child orders match pos0
   if(magicNo > 0)
      _sqxSplitCfg.magic = magicNo;
   _sqxSplitCfg.slippage = (double)deviation;

   // Compute pos0 volume (carries rounding remainder; returns full volume
   // unchanged if splitting isn't possible for this symbol/volume)
   double pos0Volume = SplitAdjustLots(symbol, volume, _sqxSplitCfg);

   // Send pos0 through SQX's own openPosition — preserves all of SQX's
   // logic (margin check, duplicate check, sqHandleTradingOptions gate,
   // orderSendWithRetries, etc.)
   ulong ticket = openPosition(type, symbol, pos0Volume, price, slPrice, ptPrice,
                               deviation, comment, magicNo, expiration,
                               replaceExisting, allowDuplicateTrades, isExitLevel);

   if(ticket == 0)
      return(0); // Pos0 open failed; nothing to register

   // Register for sequential child-order firing.
   // (If splitting turned out infeasible, SplitRegister internally no-ops
   //  and pos0Volume already equals volume, so this is harmless.)
   if(type == ORDER_TYPE_BUY)
      SplitRegister(_sqxSplitLong,  ticket, _sqxSplitCfg, volume, false);
   else
      SplitRegister(_sqxSplitShort, ticket, _sqxSplitCfg, volume, false);

   return(ticket);
  }

#endif // SPLIT_ORDER_SQX_MQH
//+------------------------------------------------------------------+
