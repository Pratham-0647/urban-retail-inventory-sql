/* =====================================================================
   05_performance_optimization.sql
   ---------------------------------------------------------------------
   PURPOSE : Show measurable query-performance improvements.
     1. Baseline timings with only the primary-key index
     2. Targeted indexes (and why each exists)
     3. Same queries re-timed
     4. Materialized view for dashboard KPIs (pre-aggregated)
   Results of the timings are recorded in outputs/05_performance_optimization.txt
   ===================================================================== */

SET search_path = retail;
\timing on

-- Start from a clean slate so the before/after comparison is fair.
DROP INDEX IF EXISTS idx_inv_store_product_date;
DROP INDEX IF EXISTS idx_inv_product_date;
DROP INDEX IF EXISTS idx_inv_low_stock;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_kpis;
ANALYZE inventory_daily;

/* ---------------------------------------------------------------------
   1. BASELINE
   The PK index is (date, store_id, product_id). Its leading column is
   date, so it cannot help queries that filter on store/product first.
   --------------------------------------------------------------------- */

-- Q1: time series for one store-product (the replenishment planner's view)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT date, inventory_level, units_sold
FROM inventory_daily
WHERE store_id = 'S003' AND product_id = 'P0057'
ORDER BY date;

-- Q2: one product across all stores over a quarter
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT store_id, SUM(units_sold)
FROM inventory_daily
WHERE product_id = 'P0057' AND date BETWEEN '2023-10-01' AND '2023-12-31'
GROUP BY store_id;

-- Q3: latest stock per store-product (DISTINCT ON)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT DISTINCT ON (store_id, product_id) store_id, product_id, inventory_level
FROM inventory_daily
ORDER BY store_id, product_id, date DESC;


/* ---------------------------------------------------------------------
   2. INDEXES
   --------------------------------------------------------------------- */

-- Serves Q1 and Q3: per-SKU lookups and "latest row per SKU".
-- INCLUDE makes it a covering index (no heap visit for these columns).
CREATE INDEX idx_inv_store_product_date
    ON inventory_daily (store_id, product_id, date DESC)
    INCLUDE (inventory_level, units_sold);

-- Serves Q2: product-level analysis over a date range.
CREATE INDEX idx_inv_product_date
    ON inventory_daily (product_id, date)
    INCLUDE (store_id, units_sold);

-- Partial index: only the "stock ran out" rows (~5.6% of the table).
-- Tiny, and makes stockout drill-downs instant.
CREATE INDEX idx_inv_low_stock
    ON inventory_daily (date, store_id, product_id)
    WHERE units_sold >= inventory_level;

ANALYZE inventory_daily;


/* ---------------------------------------------------------------------
   3. AFTER — same queries
   --------------------------------------------------------------------- */

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT date, inventory_level, units_sold
FROM inventory_daily
WHERE store_id = 'S003' AND product_id = 'P0057'
ORDER BY date;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT store_id, SUM(units_sold)
FROM inventory_daily
WHERE product_id = 'P0057' AND date BETWEEN '2023-10-01' AND '2023-12-31'
GROUP BY store_id;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT DISTINCT ON (store_id, product_id) store_id, product_id, inventory_level
FROM inventory_daily
ORDER BY store_id, product_id, date DESC;

-- Partial index in action.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT date, store_id, product_id
FROM inventory_daily
WHERE units_sold >= inventory_level AND date >= '2023-12-01';

-- Index sizes: the partial index is a fraction of a full one.
SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'inventory_daily'
ORDER BY pg_relation_size(indexrelid) DESC;


/* ---------------------------------------------------------------------
   4. MATERIALIZED VIEW for the dashboard
   The dashboard asks the same monthly questions all day. Pre-aggregating
   109,500 rows into 600 (24 months x 5 stores x 5 categories) makes every tile
   instant. Refresh nightly after the data load:
       REFRESH MATERIALIZED VIEW CONCURRENTLY retail.mv_monthly_kpis;
   --------------------------------------------------------------------- */
CREATE MATERIALIZED VIEW mv_monthly_kpis AS
SELECT DATE_TRUNC('month', date)::date                              AS month,
       store_id, category,
       COUNT(*)                                                     AS sku_days,
       SUM(units_sold)                                              AS units_sold,
       ROUND(SUM(net_revenue), 2)                                   AS net_revenue,
       ROUND(AVG(inventory_level), 2)                               AS avg_stock,
       SUM((units_sold >= inventory_level)::int)                    AS stockout_days,
       SUM((demand_forecast > inventory_level)::int)                AS at_risk_days,
       SUM(demand_forecast)                                         AS forecast_units
FROM v_daily
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX ux_mv_monthly_kpis ON mv_monthly_kpis (month, store_id, category);

-- Same monthly KPI question: raw view vs materialized view.
EXPLAIN (ANALYZE, COSTS OFF)
SELECT DATE_TRUNC('month', date) AS month,
       ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2) AS stockout_rate
FROM v_daily
GROUP BY 1;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT month, ROUND(100.0 * SUM(stockout_days) / SUM(sku_days), 2) AS stockout_rate
FROM mv_monthly_kpis
GROUP BY month;

\timing off
