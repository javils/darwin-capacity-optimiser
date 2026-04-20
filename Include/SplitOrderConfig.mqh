//+------------------------------------------------------------------+
//| SplitOrderConfig.mqh                                             |
//| Author: Martí Castany                                            |
//| Configuration for SplitOrder library                             |
//| https://github.com/marticastany/darwin-capacity-optimiser        |
//+------------------------------------------------------------------+
#property copyright "Darwinex / Tradeslide Ltd"
#property version   "1.0"
#property strict

#ifndef SPLIT_ORDER_CONFIG_MQH
#define SPLIT_ORDER_CONFIG_MQH

//+------------------------------------------------------------------+
//| Configuration struct — one per EA, shared by all SplitState      |
//+------------------------------------------------------------------+
struct SplitConfig
  {
   int               splitCount;        // Total positions including pos0 (2-10)
   int               delaySeconds;      // Seconds between each child order
   double            slippage;          // Max slippage in points
   int               maxRetries;        // Retries per failed child order
   int               retryDelaySeconds; // Seconds between retries
   int               magic;             // EA magic number for child orders
   bool              verbose;           // Print detailed logs
  };

//+------------------------------------------------------------------+
//| Initialize config with sensible defaults                         |
//+------------------------------------------------------------------+
void SplitConfigInit(SplitConfig &cfg)
  {
   cfg.splitCount        = 3;
   cfg.delaySeconds      = 10;
   cfg.slippage          = 5.0;
   cfg.maxRetries        = 3;
   cfg.retryDelaySeconds = 2;
   cfg.magic             = 0;
   cfg.verbose           = true;
  }

#endif // SPLIT_ORDER_CONFIG_MQH
//+------------------------------------------------------------------+
