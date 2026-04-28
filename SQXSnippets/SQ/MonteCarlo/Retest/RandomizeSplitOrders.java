package SQ.MonteCarlo.Retest;

import java.util.ArrayList;

import com.strategyquant.lib.IRandomGenerator;
import com.strategyquant.lib.SettingsMap;
import com.strategyquant.tradinglib.ClassConfig;
import com.strategyquant.tradinglib.Help;
import com.strategyquant.tradinglib.MonteCarloRetest;
import com.strategyquant.tradinglib.MonteCarloTestTypes;
import com.strategyquant.tradinglib.Parameter;
import com.strategyquant.tradinglib.SettingsKeys;
import com.strategyquant.tradinglib.StrategyBase;
import com.strategyquant.tradinglib.TradingOption;

import SQ.TradingOptions.SplitMarketOrderWithDelay;

/**
 * RandomizeSplitOrders — Monte Carlo retest manipulation that, on each
 * Monte Carlo iteration, picks a random Split count K and a random Delay.
 */
@ClassConfig(name = "RandomizeSplitOrders", display = "Randomize Split Orders")
@Help("Monte Carlo manipulation that randomizes the SplitMarketOrderWithDelay "
    + "K and delay parameters within configurable ranges, once per iteration. "
    + "Use to estimate strategy robustness under variable split execution.")
public class RandomizeSplitOrders extends MonteCarloRetest {

    @Parameter(name = "Min K", defaultValue = "2", minValue = 2, maxValue = 100, step = 1, category = "Split MC")
    @Help("Lower bound for the random Split count K (inclusive).")
    public int minK;

    @Parameter(name = "Max K", defaultValue = "5", minValue = 2, maxValue = 100, step = 1, category = "Split MC")
    @Help("Upper bound for the random Split count K (inclusive).")
    public int maxK;

    @Parameter(name = "Min delay seconds", defaultValue = "5", minValue = 1, maxValue = 300, step = 1, category = "Split MC")
    @Help("Lower bound for the random delay (inclusive).")
    public int minDelay;

    @Parameter(name = "Max delay seconds", defaultValue = "30", minValue = 1, maxValue = 300, step = 1, category = "Split MC")
    @Help("Upper bound for the random delay (inclusive).")
    public int maxDelay;

    public RandomizeSplitOrders() {
        super(MonteCarloTestTypes.ModifySettings);
    }

    @Override
    public void modifySettings(IRandomGenerator rng, SettingsMap settings) throws Exception {
        if (settings == null) return;

        ArrayList<TradingOption> opts = (ArrayList<TradingOption>) settings.get(SettingsKeys.TradingOptions);

        int kLow = Math.min(minK, maxK);
        int kHigh = Math.max(minK, maxK);
        int delayLow = Math.min(minDelay, maxDelay);
        int delayHigh = Math.max(minDelay, maxDelay);

        int k = sampleInclusive(rng, kLow, kHigh);
        int delay = sampleInclusive(rng, delayLow, delayHigh);

        for (TradingOption option : opts) {
            if (option instanceof SplitMarketOrderWithDelay) {
                SplitMarketOrderWithDelay split = (SplitMarketOrderWithDelay) option;
                split.enabled = true;
                split.splitCount = k;
                split.delaySeconds = delay;
                break;
            }
        }

        settings.set(SettingsKeys.TradingOptions, opts);
    }

    private static int sampleInclusive(IRandomGenerator rng, int min, int max) {
        if (max <= min) return min;
        return min + rng.nextInt(max - min + 1);
    }

    @Override
    public RandomizeSplitOrders getClone() throws Exception {
        RandomizeSplitOrders cloned = new RandomizeSplitOrders();
        cloned.minK = this.minK;
        cloned.maxK = this.maxK;
        cloned.minDelay = this.minDelay;
        cloned.maxDelay = this.maxDelay;
        cloned.setParams(this.getParams());
        return cloned;
    }
}
