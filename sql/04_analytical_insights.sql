/* =====================================================================
   04_analytical_insights.sql
   ---------------------------------------------------------------------
   Turns the core metrics into business answers:
     1. ABC classification (which products carry the revenue)
     2. Fast vs slow movers + demand variability (ABC-XYZ matrix)
     3. Overstock & holding-cost opportunity
     4. Stockout & lost-sales exposure
     5. Seasonality and year-on-year trend
     6. Promotion & discount effectiveness
     7. Weather & competitor-price effects
     8. Forecast accuracy (MAPE, bias)
     9. Replenishment reliability (supplier performance proxy)
    10. Demand forecast for Q1 2024 (seasonal index x trend)
   ===================================================================== */

SET search_path = retail;


/* ---------------------------------------------------------------------
   1. ABC CLASSIFICATION (Pareto on net revenue)
   A = top 70% of revenue, B = next 20%, C = last 10%.
   Running total via SUM() OVER (ORDER BY ...) — a window function.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_abc CASCADE;
CREATE VIEW v_abc AS
WITH rev AS (
    SELECT product_id, category, SUM(net_revenue) AS revenue
    FROM v_daily
    GROUP BY product_id, category
),
cum AS (
    SELECT *,
           SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () AS cum_share
    FROM rev
)
SELECT product_id, category, ROUND(revenue, 0) AS revenue,
       ROUND(100 * cum_share, 1) AS cum_revenue_pct,
       CASE WHEN cum_share <= 0.70 THEN 'A'
            WHEN cum_share <= 0.90 THEN 'B'
            ELSE 'C' END AS abc_class
FROM cum;

SELECT * FROM v_abc ORDER BY revenue DESC;

SELECT abc_class, COUNT(*) AS products, ROUND(SUM(revenue), 0) AS revenue
FROM v_abc GROUP BY abc_class ORDER BY abc_class;


/* ---------------------------------------------------------------------
   2. FAST vs SLOW MOVERS  +  XYZ (demand variability)
   Velocity tier : NTILE(3) on average daily units sold per store-product.
   XYZ           : coefficient of variation (CV = sd / mean) of daily sales.
                   X < 0.35 stable, Y 0.35–0.50, Z > 0.50 erratic.
   Stable + fast = automate replenishment. Erratic = needs more safety stock.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_velocity CASCADE;
CREATE VIEW v_velocity AS
WITH s AS (
    SELECT store_id, product_id,
           AVG(units_sold)                              AS avg_daily_units,
           STDDEV_SAMP(units_sold) / AVG(units_sold)    AS demand_cv,
           AVG(inventory_level) / AVG(units_sold)       AS days_of_supply
    FROM inventory_daily
    GROUP BY store_id, product_id
)
SELECT store_id, product_id,
       ROUND(avg_daily_units, 1) AS avg_daily_units,
       ROUND(demand_cv, 3)       AS demand_cv,
       ROUND(days_of_supply, 2)  AS days_of_supply,
       CASE NTILE(3) OVER (ORDER BY avg_daily_units DESC)
            WHEN 1 THEN 'Fast' WHEN 2 THEN 'Medium' ELSE 'Slow' END AS velocity,
       CASE WHEN demand_cv < 0.35 THEN 'X' WHEN demand_cv <= 0.50 THEN 'Y' ELSE 'Z' END AS xyz_class
FROM s;

-- 2a. Fastest 10 and slowest 10 store-products.
(SELECT 'Fastest' AS grp, * FROM v_velocity ORDER BY avg_daily_units DESC LIMIT 10)
UNION ALL
(SELECT 'Slowest', * FROM v_velocity ORDER BY avg_daily_units ASC  LIMIT 10);

-- 2b. Velocity mix by category.
SELECT c.category_name AS category, v.velocity, COUNT(*) AS store_products
FROM v_velocity v
JOIN products p   ON p.product_id = v.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2c. ABC-XYZ matrix (product level).
SELECT a.abc_class, v.xyz_class, COUNT(DISTINCT a.product_id) AS products
FROM v_abc a
JOIN (SELECT product_id, MAX(xyz_class) AS xyz_class FROM v_velocity GROUP BY product_id) v
  USING (product_id)
GROUP BY 1, 2
ORDER BY 1, 2;


/* ---------------------------------------------------------------------
   3. OVERSTOCK & HOLDING COST
   Overstocked day : stock above the target of N days of supply
                     (N = overstock_dos_days in analysis_params, default 2).
   Excess units    : stock above that target.
   Holding cost    : excess value x annual holding rate.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_overstock CASCADE;
CREATE VIEW v_overstock AS
WITH params AS (
    SELECT MAX(param_value) FILTER (WHERE param_name = 'overstock_dos_days') AS dos_target,
           MAX(param_value) FILTER (WHERE param_name = 'holding_cost_rate')  AS hold_rate
    FROM analysis_params
),
base AS (
    SELECT d.store_id, d.product_id, d.category, d.inventory_level, d.price,
           AVG(d.units_sold) OVER (PARTITION BY d.store_id, d.product_id) AS avg_demand
    FROM v_daily d
    WHERE d.year = 2023
)
SELECT b.store_id, b.product_id, b.category,
       ROUND(100.0 * AVG((b.inventory_level > p.dos_target * b.avg_demand)::int), 1) AS pct_days_overstocked,
       ROUND(AVG(GREATEST(b.inventory_level - p.dos_target * b.avg_demand, 0)), 1)    AS avg_excess_units,
       ROUND(AVG(GREATEST(b.inventory_level - p.dos_target * b.avg_demand, 0) * b.price) * MAX(p.hold_rate), 0)
                                                                                     AS annual_holding_cost_of_excess
FROM base b CROSS JOIN params p
GROUP BY b.store_id, b.product_id, b.category;

-- 3a. Worst overstock offenders.
SELECT * FROM v_overstock ORDER BY annual_holding_cost_of_excess DESC LIMIT 10;

-- 3b. Overstock opportunity by category (2023).
SELECT category,
       ROUND(AVG(pct_days_overstocked), 1)       AS pct_days_overstocked,
       ROUND(SUM(avg_excess_units), 0)           AS excess_units_on_hand,
       ROUND(SUM(annual_holding_cost_of_excess)) AS annual_holding_cost_of_excess
FROM v_overstock
GROUP BY category
ORDER BY annual_holding_cost_of_excess DESC;

-- 3c. Total opportunity.
SELECT ROUND(SUM(avg_excess_units))               AS total_excess_units,
       ROUND(SUM(annual_holding_cost_of_excess))  AS total_annual_holding_cost_of_excess
FROM v_overstock;


/* ---------------------------------------------------------------------
   4. STOCKOUT & LOST-SALES EXPOSURE
   Demand on a day is unknown when stock ran out, so we estimate it with the
   demand forecast corrected for its known over-forecast bias (section 8):
       est_demand = demand_forecast x (total sold / total forecast)
   Lost units = est_demand above stock on hand.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_lost_sales CASCADE;
CREATE VIEW v_lost_sales AS
WITH bias AS (
    SELECT SUM(units_sold)::numeric / SUM(demand_forecast) AS factor
    FROM inventory_daily
)
SELECT d.date, d.year, d.season, d.store_id, d.product_id, d.category, d.holiday_promotion,
       GREATEST(d.demand_forecast * b.factor - d.inventory_level, 0)                          AS lost_units,
       GREATEST(d.demand_forecast * b.factor - d.inventory_level, 0)
           * d.price * (1 - d.discount_pct / 100.0)                                           AS lost_revenue
FROM v_daily d CROSS JOIN bias b;

-- 4a. Lost revenue by year and category.
SELECT year, category,
       ROUND(SUM(lost_units))   AS est_lost_units,
       ROUND(SUM(lost_revenue)) AS est_lost_revenue
FROM v_lost_sales
GROUP BY year, category
ORDER BY year, est_lost_revenue DESC;

-- 4b. Lost revenue as a share of actual revenue, 2023.
SELECT ROUND(SUM(l.lost_revenue))                                         AS est_lost_revenue_2023,
       ROUND(100 * SUM(l.lost_revenue) / (SELECT SUM(net_revenue) FROM v_daily WHERE year = 2023), 2)
                                                                          AS pct_of_actual_revenue
FROM v_lost_sales l
WHERE l.year = 2023;

-- 4c. When do stockouts happen? Season x promotion.
SELECT season, holiday_promotion,
       ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2) AS stockout_rate_pct,
       ROUND(AVG(units_sold), 1)                                   AS avg_units_sold,
       ROUND(AVG(inventory_level), 1)                              AS avg_stock
FROM v_daily
GROUP BY season, holiday_promotion
ORDER BY stockout_rate_pct DESC;


/* ---------------------------------------------------------------------
   5. SEASONALITY & TREND
   --------------------------------------------------------------------- */

-- 5a. Seasonal demand index by category (1.00 = category's average day).
SELECT category, season,
       ROUND(AVG(units_sold), 1) AS avg_daily_units,
       ROUND(AVG(units_sold) / AVG(AVG(units_sold)) OVER (PARTITION BY category), 2) AS seasonal_index
FROM v_daily
GROUP BY category, season
ORDER BY category, seasonal_index DESC;

-- 5b. Monthly demand, 2022 vs 2023, with YoY growth (LAG window function).
WITH m AS (
    SELECT year, month, month_name, SUM(units_sold) AS units
    FROM v_daily
    GROUP BY year, month, month_name
)
SELECT month, month_name, year, units,
       ROUND(100.0 * (units - LAG(units) OVER (PARTITION BY month ORDER BY year))
             / LAG(units) OVER (PARTITION BY month ORDER BY year), 1) AS yoy_growth_pct
FROM m
ORDER BY month, year;

-- 5c. Year-on-year totals.
SELECT year, SUM(units_sold) AS units, ROUND(SUM(net_revenue)) AS net_revenue
FROM v_daily GROUP BY year ORDER BY year;

-- 5d. Weekday vs weekend.
SELECT is_weekend, ROUND(AVG(units_sold), 1) AS avg_daily_units
FROM v_daily GROUP BY is_weekend;


/* ---------------------------------------------------------------------
   6. PROMOTION & DISCOUNT EFFECTIVENESS
   --------------------------------------------------------------------- */

-- 6a. Holiday/promotion lift by category: does stock rise to meet it?
SELECT category,
       ROUND(AVG(units_sold)      FILTER (WHERE holiday_promotion), 1)     AS units_promo,
       ROUND(AVG(units_sold)      FILTER (WHERE NOT holiday_promotion), 1) AS units_normal,
       ROUND(100 * (AVG(units_sold) FILTER (WHERE holiday_promotion)
                  / AVG(units_sold) FILTER (WHERE NOT holiday_promotion) - 1), 1) AS demand_lift_pct,
       ROUND(100 * (AVG(inventory_level) FILTER (WHERE holiday_promotion)
                  / AVG(inventory_level) FILTER (WHERE NOT holiday_promotion) - 1), 1) AS stock_lift_pct
FROM v_daily
GROUP BY category
ORDER BY demand_lift_pct DESC;

-- 6b. Discount depth vs volume: do bigger discounts sell more?
SELECT discount_pct,
       COUNT(*)                         AS sku_days,
       ROUND(AVG(units_sold), 1)        AS avg_units_sold,
       ROUND(SUM(units_sold * price * discount_pct / 100.0)) AS revenue_given_away
FROM v_daily
GROUP BY discount_pct
ORDER BY discount_pct;

-- 6c. Total discount cost over two years.
SELECT ROUND(SUM(units_sold * price * discount_pct / 100.0)) AS total_discount_cost,
       ROUND(100 * SUM(units_sold * price * discount_pct / 100.0) / SUM(units_sold * price), 2) AS pct_of_gross_revenue
FROM v_daily;


/* ---------------------------------------------------------------------
   7. WEATHER & COMPETITOR PRICE
   --------------------------------------------------------------------- */

-- 7a. Weather effect on demand.
SELECT weather, ROUND(AVG(units_sold), 1) AS avg_units_sold,
       ROUND(100 * (AVG(units_sold) / (SELECT AVG(units_sold) FROM inventory_daily) - 1), 1) AS vs_overall_pct
FROM v_daily
GROUP BY weather
ORDER BY avg_units_sold DESC;

-- 7b. Price position vs competitor.
SELECT CASE WHEN price < competitor_price * 0.95 THEN '1. >5% cheaper'
            WHEN price > competitor_price * 1.05 THEN '3. >5% dearer'
            ELSE '2. within ±5%' END AS price_position,
       COUNT(*)                  AS sku_days,
       ROUND(AVG(units_sold), 1) AS avg_units_sold
FROM v_daily
GROUP BY 1
ORDER BY 1;


/* ---------------------------------------------------------------------
   8. FORECAST ACCURACY
   MAPE  = average |forecast - actual| / actual   (days with sales > 0)
   Bias  = (total forecast - total actual) / total actual  (+ = over-forecast)
   --------------------------------------------------------------------- */
SELECT category,
       ROUND(100 * AVG(ABS(demand_forecast - units_sold) / NULLIF(units_sold, 0)), 1) AS mape_pct,
       ROUND(100 * (SUM(demand_forecast) - SUM(units_sold)) / SUM(units_sold), 1)     AS bias_pct
FROM v_daily
GROUP BY ROLLUP (category)
ORDER BY category NULLS LAST;

-- 8b. Bias by season and promotion — is the forecast missing the peaks?
SELECT season, holiday_promotion,
       ROUND(100 * (SUM(demand_forecast) - SUM(units_sold)) / SUM(units_sold), 1) AS bias_pct
FROM v_daily
GROUP BY season, holiday_promotion
ORDER BY season, holiday_promotion;


/* ---------------------------------------------------------------------
   9. REPLENISHMENT RELIABILITY  (supplier performance proxy)
   The dataset has no supplier column, so we judge the replenishment
   stream per product by how well orders track what was actually sold:
     - order_gap_cv   : variability of (ordered - sold); high = erratic supply
     - under_order_pct: days the order did not cover that day's sales
     - stockout_pct   : days stock ran out
   Reliability score : 100 minus a weighted penalty of the three.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_replenishment CASCADE;
CREATE VIEW v_replenishment AS
WITH s AS (
    SELECT i.product_id, c.category_name AS category,
           STDDEV_SAMP(i.units_ordered - i.units_sold) / AVG(i.units_sold)  AS order_gap_cv,
           AVG((i.units_ordered < i.units_sold)::int)                       AS under_order_rate,
           AVG((i.units_sold >= i.inventory_level)::int)                    AS stockout_rate,
           SUM(i.units_ordered)::numeric / SUM(i.units_sold)                AS order_to_sales_ratio
    FROM inventory_daily i
    JOIN products   p ON p.product_id  = i.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY i.product_id, c.category_name
)
SELECT product_id, category,
       ROUND(order_to_sales_ratio, 3)   AS order_to_sales_ratio,
       ROUND(order_gap_cv, 3)           AS order_gap_cv,
       ROUND(100 * under_order_rate, 1) AS under_order_pct,
       ROUND(100 * stockout_rate, 2)    AS stockout_pct,
       ROUND(100 - (100 * order_gap_cv * 0.4 + 100 * under_order_rate * 0.3 + 100 * stockout_rate * 3 * 0.3), 1)
                                        AS reliability_score
FROM s;

SELECT *, RANK() OVER (ORDER BY reliability_score ASC) AS worst_rank
FROM v_replenishment
ORDER BY reliability_score ASC;


/* ---------------------------------------------------------------------
   10. DEMAND FORECAST — Q1 2024 (seasonal index x trend)
   Forecast(category, month) = 2023 avg daily units for that month
                               x (1 + category YoY growth 2022->2023)
   Transparent, explainable, and built entirely in SQL.
   --------------------------------------------------------------------- */
DROP VIEW IF EXISTS v_forecast_q1_2024 CASCADE;
CREATE VIEW v_forecast_q1_2024 AS
WITH growth AS (
    SELECT category,
           SUM(units_sold) FILTER (WHERE year = 2023)::numeric
         / SUM(units_sold) FILTER (WHERE year = 2022) - 1 AS yoy
    FROM v_daily
    GROUP BY category
),
base AS (
    SELECT category, month, month_name,
           SUM(units_sold)::numeric / COUNT(DISTINCT date) AS daily_units_2023
    FROM v_daily
    WHERE year = 2023 AND month IN (1, 2, 3)
    GROUP BY category, month, month_name
)
SELECT b.category, b.month, b.month_name || ' 2024' AS forecast_month,
       ROUND(b.daily_units_2023)                      AS daily_units_2023,
       ROUND(100 * g.yoy, 1)                          AS yoy_growth_pct,
       ROUND(b.daily_units_2023 * (1 + g.yoy))        AS forecast_daily_units,
       ROUND(b.daily_units_2023 * (1 + g.yoy)
             * EXTRACT(DAY FROM (MAKE_DATE(2024, b.month, 1) + INTERVAL '1 month - 1 day')))
                                                     AS forecast_month_units
FROM base b
JOIN growth g USING (category);

SELECT * FROM v_forecast_q1_2024 ORDER BY category, month;
