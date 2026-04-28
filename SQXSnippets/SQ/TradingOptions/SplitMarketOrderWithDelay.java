package SQ.TradingOptions;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.strategyquant.tradinglib.ClassConfig;
import com.strategyquant.tradinglib.Help;
import com.strategyquant.tradinglib.ILiveOrder;
import com.strategyquant.tradinglib.OrderCloseTypes;
import com.strategyquant.tradinglib.Parameter;
import com.strategyquant.tradinglib.SLPTValues;
import com.strategyquant.tradinglib.StrategyBase;
import com.strategyquant.tradinglib.Trader;
import com.strategyquant.tradinglib.TradingOption;
import com.strategyquant.datalib.TickEvent;

/**
 * SplitMarketOrderWithDelay — non-invasive Trading Option that simulates
 * the SplitOrder library's behavior inside the SQX backtest engine.
 *
 * For each market order the strategy opens of size N, this option:
 *   1. Reduces the original order's size to N/K (first child, fills NOW).
 *   2. Schedules K-1 additional children of size N/K each, to be opened
 *      delaySeconds apart at the prevailing market price, each with its
 *      own SL/TP relative to its own fill price.
 *
 * Children close together with the parent (when the strategy's exit rules
 * close the parent), mirroring the SplitOrder MQL5 library's OnTimer
 * cleanup on MT5.
 */
@ClassConfig(name = "SplitMarketOrderWithDelay", display = "Split Market Orders With Delay")
@Help("Splits each strategy market entry into K children of size N/K, "
    + "spaced by delaySeconds, each with its own SL/TP relative to its own "
    + "fill price. Affects entries only; exits are handled by the strategy. "
    + "Non-invasive: the strategy itself does not need to change.")
public class SplitMarketOrderWithDelay extends TradingOption {

    @Parameter(name = "Split market orders with delay", defaultValue = "false", category = "Split options")
    @Help("Splits each strategy market entry into K children of size N/K, spaced by Delay seconds, each with its own SL/TP. Children close together with the parent, mirroring the SplitOrder MQL5 library on MT5.")
    public boolean enabled;

    @Parameter(name = "Split count K", defaultValue = "3", minValue = 2, maxValue = 100, step = 1, category = "Split options")
    @Help("Total number of child positions per signal, including the first.")
    public int splitCount;

    @Parameter(name = "Delay seconds", defaultValue = "10", minValue = 1, maxValue = 300, step = 1, category = "Split options")
    @Help("Seconds between consecutive child orders.")
    public int delaySeconds;

    private final Set<Integer> handledOrderIds = new HashSet<>();
    private final LinkedList<PendingChild> pendingChildren = new LinkedList<>();
    private final Map<Integer, ParentInfo> parentToInfo = new HashMap<>();

    @Override
    public boolean isUsedInTrading() {
        return enabled;
    }

    @Override
    public TradingOption getClone() {
        SplitMarketOrderWithDelay option = new SplitMarketOrderWithDelay();
        option.enabled = this.enabled;
        option.splitCount = this.splitCount;
        option.delaySeconds = this.delaySeconds;
        return option;
    }

    @Override
    public boolean OnBarUpdate(StrategyBase strategy) throws Exception {
        return true;
    }

    @Override
    public void OnTick(StrategyBase strategy, TickEvent tickEvent, boolean includingPendingOrders) throws Exception {
        if (!enabled) return;
        if (strategy == null) return;

        try {
            Trader trader = strategy.Trader;
            if (trader == null) return;

            interceptNewMarketOrders(strategy, trader, tickEvent, includingPendingOrders);
            drainPendingChildren(strategy, trader, tickEvent);
            closeOrphanedChildren(trader);
        } catch (Throwable ignored) {
        }
    }

    /**
     * Look for newly-filled market orders that we haven't handled yet,
     * shrink their size to size/K, and queue K-1 children.
     */
    private void interceptNewMarketOrders(StrategyBase strategy, Trader trader,
                                          TickEvent tickEvent, boolean includingPending) {
        int openCount;
        try {
            openCount = trader.getOpenOrdersCount(includingPending);
        } catch (Throwable t) {
            return;
        }
        if (openCount <= 0) return;

        for (int i = 0; i < openCount; i++) {
            ILiveOrder order;
            try {
                order = trader.getOpenOrder(i, includingPending);
            } catch (Throwable t) {
                continue;
            }
            if (order == null) continue;
            if (!order.isFilled()) continue;
            if (order.isClosedOrder()) continue;
            if (!order.isMarketOrder()) continue;

            int orderId = order.getOrderId();
            if (handledOrderIds.contains(orderId)) continue;

            splitOrder(strategy, order, tickEvent);
            handledOrderIds.add(orderId);
        }
    }

    /**
     * Shrink the original order to size/K and queue K-1 children with
     * SL/TP expressed in pips so each child gets its own absolute level
     * computed from its own fill price.
     */
    private void splitOrder(StrategyBase strategy, ILiveOrder parent, TickEvent tickEvent) {
        double originalSize = parent.getSize();
        if (originalSize <= 0) return;

        int splits = splitCount;
        double childSize = originalSize / (double) splits;
        String symbol = parent.getSymbol();
        byte direction = parent.getOrderType();
        int magic = parent.getMagicNumber();
        String comment = parent.getComment();
        double parentOpenPrice = parent.getOpenPrice();
        double parentSL = parent.getSL();
        double parentPT = parent.getPT();

        double slPips = computePipsOffset(strategy, symbol, parentOpenPrice, parentSL, parent.isLong(), true);
        double ptPips = computePipsOffset(strategy, symbol, parentOpenPrice, parentPT, parent.isLong(), false);

        try {
            parent.setSize(childSize);
        } catch (Throwable t) {
            return;
        }

        int parentId = parent.getOrderId();
        parentToInfo.put(parentId, new ParentInfo(parent));

        long baseTime = tickEvent.getTime();
        int delay = delaySeconds;
        for (int i = 1; i < splits; i++) {
            PendingChild child = new PendingChild();
            child.parentOrderId = parentId;
            child.symbol = symbol;
            child.direction = direction;
            child.size = childSize;
            // Each child needs a unique MagicNumber so the strategy's
            // exit rules evaluate every child independently. SQX's exit
            // logic groups positions by magic, and a single magic shared
            // across K positions causes only one of them to be closed by
            // a given exit rule (the others linger or close on later
            // signals). The pattern `parentMagic + i` matches what the
            // SplitOrder MQL5 library does on MT5, so the simulation
            // here and the live execution stay consistent.
            child.magicNumber = magic + i;
            child.comment = comment;
            child.slPips = slPips;
            child.ptPips = ptPips;
            child.releaseTime = baseTime + ((long) i) * delay * 1000L;
            child.indexInBatch = i;
            pendingChildren.add(child);
        }
    }

    /**
     * Convert an absolute SL/PT price into pips relative to the parent's open
     * price. Returns 0 (meaning "no SL/PT") if the value is missing, sentinel,
     * or nonsensical.
     */
    private double computePipsOffset(StrategyBase strategy, String symbol,
                                     double openPrice, double level,
                                     boolean isLong, boolean isStopLoss) {
        if (level <= 0) return 0;
        if (Math.abs(level) > 1e6) return 0;
        if (Math.abs(openPrice - level) > openPrice) return 0;

        double diff;
        if (isStopLoss) {
            diff = isLong ? (openPrice - level) : (level - openPrice);
        } else {
            diff = isLong ? (level - openPrice) : (openPrice - level);
        }
        if (diff <= 0) return 0;

        try {
            return strategy.convertRealPriceToPips(symbol, diff);
        } catch (Throwable t) {
            return 0;
        }
    }

    /**
     * Open any queued child whose releaseTime has been reached by the
     * current tick. Children are independent: a child whose siblings
     * already hit SL still opens normally.
     */
    private void drainPendingChildren(StrategyBase strategy, Trader trader, TickEvent tickEvent) {
        if (pendingChildren.isEmpty()) return;

        long now = tickEvent.getTime();
        Iterator<PendingChild> it = pendingChildren.iterator();
        while (it.hasNext()) {
            PendingChild child = it.next();
            if (child.releaseTime > now) continue;

            it.remove();
            spawnChild(strategy, trader, child);
        }
    }

    private void spawnChild(StrategyBase strategy, Trader trader, PendingChild child) {
        try {
            ILiveOrder order = trader.Open(child.direction, child.symbol);
            order.setSize(child.size);
            order.setMagicNumber(child.magicNumber);
            if (child.comment != null) {
                order.setComment(child.comment);
            }
            if (child.slPips > 0) {
                order.setSL((byte) SLPTValues.ValueInPips, child.slPips);
            }
            if (child.ptPips > 0) {
                order.setPT((byte) SLPTValues.ValueInPips, child.ptPips);
            }
            order.Send();

            int childId = order.getOrderId();
            handledOrderIds.add(childId);

            ParentInfo info = parentToInfo.get(child.parentOrderId);
            if (info != null) {
                info.childIds.add(childId);
            }
        } catch (Throwable ignored) {
        }
    }

    /**
     * Match the SplitOrder MQL5 library's exit semantics: when the parent
     * order closes (for any reason — SL, TP, "Exit Signal", "Exit After X
     * Bars", etc.), close every child of that parent that's still open
     * and discard any of its pending children that haven't been spawned yet.
     *
     * SQX's strategy code only evaluates exit rules against the original
     * magic, so children with different magics never receive those rules and
     * would otherwise stay open forever. Closing them on the parent's close
     * mirrors what the MQL5 library does on MT5 via OnTimer.
     */
    private void closeOrphanedChildren(Trader trader) {
        if (parentToInfo.isEmpty()) return;

        Set<Integer> openIds = new HashSet<>();
        Map<Integer, ILiveOrder> openOrders = new HashMap<>();

        int openCount;
        try {
            openCount = trader.getOpenOrdersCount(false);
        } catch (Throwable t) {
            return;
        }
        for (int i = 0; i < openCount; i++) {
            ILiveOrder o;
            try {
                o = trader.getOpenOrder(i, false);
            } catch (Throwable t) {
                continue;
            }
            if (o == null) continue;
            int id = o.getOrderId();
            openIds.add(id);
            openOrders.put(id, o);
        }

        Iterator<Map.Entry<Integer, ParentInfo>> it = parentToInfo.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<Integer, ParentInfo> entry = it.next();
            int parentId = entry.getKey();
            if (openIds.contains(parentId)) continue;

            ParentInfo info = entry.getValue();
            byte parentCloseType = readParentCloseType(info.parent);

            for (int childId : info.childIds) {
                ILiveOrder child = openOrders.get(childId);
                if (child == null) continue;
                if (child.isClosedOrder()) continue;
                closeChildOrder(child, parentCloseType);
            }

            Iterator<PendingChild> pit = pendingChildren.iterator();
            while (pit.hasNext()) {
                PendingChild p = pit.next();
                if (p.parentOrderId == parentId) {
                    pit.remove();
                }
            }
            it.remove();
        }
    }

    /**
     * Read the parent's close type from the wrapper. Falls back to Manual
     * if the wrapper is in an unexpected state, so children still close
     * cleanly rather than lingering.
     */
    private byte readParentCloseType(ILiveOrder parent) {
        try {
            byte closeType = parent.getCloseType();
            if (closeType != 0) {
                return closeType;
            }
        } catch (Throwable ignored) {
        }
        return OrderCloseTypes.Manual;
    }

    /**
     * Close a child using whichever primitive the SQX engine accepts.
     * The parent's closeType is forwarded so the child's row in the
     * trade list shows the same exit reason as its parent (no spurious
     * "Manual" rows mixed with "Exit Signal" or "Exit After X Bars").
     * Falls back to refuse() and finally CloseAsync() if the direct
     * Close fails.
     */
    private boolean closeChildOrder(ILiveOrder child, byte closeType) {
        try {
            child.Close(closeType);
            return true;
        } catch (Throwable ignored) {
        }
        try {
            child.refuse("Split: parent closed");
            return true;
        } catch (Throwable ignored) {
        }
        try {
            child.CloseAsync();
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static class PendingChild {
        int parentOrderId;
        String symbol;
        byte direction;
        double size;
        int magicNumber;
        String comment;
        double slPips;
        double ptPips;
        long releaseTime;
        int indexInBatch;
    }

    private static class ParentInfo {
        final ILiveOrder parent;
        final List<Integer> childIds = new ArrayList<>();

        ParentInfo(ILiveOrder parent) {
            this.parent = parent;
        }
    }
}
