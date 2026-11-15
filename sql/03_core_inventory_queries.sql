/* =====================================================================
   03_core_inventory_queries.sql
   ---------------------------------------------------------------------
   The five required query families from the brief:
     A. Stock level calculations
     B. Reorder point estimation      (view: v_reorder_point)
     C. Low inventory detection       (view: v_low_inventory_latest)
     D. Inventory turnover analysis   (view: v_turnover)
     E. KPI summary report            (view: v_kpi_summary)

   Definitions used throughout
   - Stockout day      : units_sold >= inventory_level (all stock consumed;
                         demand probably went unmet).
   - At-risk day       : demand_forecast > inventory_level (the system's own
                         forecast said stock would not cover the day).
   - Days of supply    : avg inventory / avg daily units sold.
                         Used as the "inventory age" proxy, because the
                         data has no receipt dates to age stock directly.
   - Turnover          : units sold / average inventory, over the period.
   ===================================================================== */

SET search_path = retail;

/* ---------------------------------------------------------------------
   A. STOCK LEVEL CALCULATIONS
   --------------------------------------------------------------------- */

-- A1. Latest stock position for every store-product (most recent date).
--     DISTINCT ON keeps the newest row per key without a self-join.
SELECT DISTINCT ON (store_id, product_id)
       store_id, product_id, date AS as_of_date, inventory_level
FROM inventory_daily
ORDER BY store_id, product_id, date DESC;

-- A2. Average, minimum and maximum stock held by each store.
SELECT store_id,
       ROUND(AVG(inventory_level), 1) AS avg_stock_per_sku_day,
       MIN(inventory_level)           AS min_stock,
       MAX(inventory_level)           AS max_stock,
       SUM(inventory_level) / COUNT(DISTINCT date) AS avg_total_units_on_hand
FROM inventory_daily
GROUP BY store_id
ORDER BY store_id;

-- A3. Store x category stock matrix (average units on hand per day).
SELECT i.store_id,
       c.category_name,
       ROUND(SUM(i.inventory_level)::numeric / COUNT(DISTINCT i.date), 0) AS avg_units_on_hand
FROM inventory_daily i
JOIN products   p ON p.product_id  = i.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY i.store_id, c.category_name
ORDER BY i.store_id, c.category_name;

-- A4. Stock value on hand by category (units x price), latest month.
SELECT category,
       ROUND(AVG(inventory_level * price), 0)                  AS avg_stock_value_per_sku_day,
       ROUND(SUM(inventory_level * price) / COUNT(DISTINCT date), 0) AS avg_total_stock_value
FROM v_daily
WHERE date >= DATE '2023-12-01'
GROUP BY category
ORDER BY avg_total_stock_value DESC;

-- A5. 7-day rolling average stock per store-product (window function).
--     Smooths daily noise; this is what a replenishment planner watches.
SELECT date, store_id, product_id, inventory_level,
       ROUND(AVG(inventory_level) OVER (
             PARTITION BY store_id, product_id
             ORDER BY date
             ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1) AS stock_7d_avg
FROM inventory_daily
WHERE store_id = 'S001' AND product_id = 'P0016'
ORDER BY date DESC
LIMIT 14;


/* ---------------------------------------------------------------------
   B. REORDER POINT ESTIMATION
   ROP = (avg daily demand x lead time) + safety stock
   Safety stock = z x sigma(daily demand) x sqrt(lead time)
   Lead time and z come from analysis_params, so planners can change
   them without touching this code.
   Demand basis: the last 90 days, so the ROP reflects current demand,
   not demand from two years ago.
   --------------------------------------------------------------------- */

DROP VIEW IF EXISTS v_reorder_point CASCADE;
CREATE VIEW v_reorder_point AS
WITH params AS (
    SELECT MAX(param_value) FILTER (WHERE param_name = 'lead_time_days')  AS lead_time,
           MAX(param_value) FILTER (WHERE param_name = 'service_level_z') AS z
    FROM analysis_params
),
recent_demand AS (
    SELECT store_id, product_id,
           AVG(units_sold)         AS avg_daily_demand,
           STDDEV_SAMP(units_sold) AS sd_daily_demand
    FROM inventory_daily
    WHERE date > (SELECT MAX(date) FROM inventory_daily) - INTERVAL '90 days'
    GROUP BY store_id, product_id
)
SELECT d.store_id, d.product_id,
       ROUND(d.avg_daily_demand, 1)                                   AS avg_daily_demand,
       ROUND(d.sd_daily_demand, 1)                                    AS sd_daily_demand,
       p.lead_time                                                    AS lead_time_days,
       ROUND(p.z * d.sd_daily_demand * SQRT(p.lead_time), 0)          AS safety_stock,
       ROUND(d.avg_daily_demand * p.lead_time
             + p.z * d.sd_daily_demand * SQRT(p.lead_time), 0)        AS reorder_point
FROM recent_demand d
CROSS JOIN params p;

-- B1. Reorder points, highest first.
SELECT * FROM v_reorder_point ORDER BY reorder_point DESC LIMIT 15;


/* ---------------------------------------------------------------------
   C. LOW INVENTORY DETECTION
   --------------------------------------------------------------------- */

-- C1. Today's alert list. Three tiers:
--     CRITICAL    : stock < one day of average demand -> likely stockout today
--     REORDER NOW : stock < reorder point            -> place a replenishment order
--     OK          : stock >= reorder point
--     (With daily replenishment many SKUs cross their ROP every day; that is
--      the normal ordering trigger. CRITICAL is the true alarm.)
DROP VIEW IF EXISTS v_low_inventory_latest CASCADE;
CREATE VIEW v_low_inventory_latest AS
WITH latest AS (
    SELECT DISTINCT ON (store_id, product_id)
           store_id, product_id, date, inventory_level
    FROM inventory_daily
    ORDER BY store_id, product_id, date DESC
)
SELECT l.store_id, l.product_id, c.category_name AS category,
       l.date AS as_of_date, l.inventory_level,
       r.avg_daily_demand, r.reorder_point,
       GREATEST(r.reorder_point - l.inventory_level, 0) AS suggested_order_qty,
       CASE WHEN l.inventory_level < r.avg_daily_demand THEN 'CRITICAL'
            WHEN l.inventory_level < r.reorder_point    THEN 'REORDER NOW'
            ELSE 'OK' END AS status
FROM latest l
JOIN v_reorder_point r USING (store_id, product_id)
JOIN products   p ON p.product_id  = l.product_id
JOIN categories c ON c.category_id = p.category_id;

-- C1a. Count by tier.
SELECT status, COUNT(*) AS store_products
FROM v_low_inventory_latest
GROUP BY status
ORDER BY status;

-- C1b. The CRITICAL list, biggest gap first.
SELECT * FROM v_low_inventory_latest
WHERE status = 'CRITICAL'
ORDER BY suggested_order_qty DESC;

-- C2. Historic exposure in 2023: share of days each store-product held less
--     than one day of its average demand. A high share = chronic under-stocking.
SELECT i.store_id, i.product_id,
       COUNT(*) FILTER (WHERE i.inventory_level < r.avg_daily_demand) AS critical_days,
       ROUND(100.0 * COUNT(*) FILTER (WHERE i.inventory_level < r.avg_daily_demand) / COUNT(*), 1) AS pct_critical_days,
       COUNT(*) FILTER (WHERE i.units_sold >= i.inventory_level)      AS stockout_days
FROM inventory_daily i
JOIN v_reorder_point r USING (store_id, product_id)
WHERE i.date >= DATE '2023-01-01'
GROUP BY i.store_id, i.product_id
ORDER BY pct_critical_days DESC
LIMIT 10;


/* ---------------------------------------------------------------------
   D. INVENTORY TURNOVER ANALYSIS
   --------------------------------------------------------------------- */

DROP VIEW IF EXISTS v_turnover CASCADE;
CREATE VIEW v_turnover AS
SELECT i.product_id,
       c.category_name                                           AS category,
       SUM(i.units_sold)                                         AS units_sold,
       ROUND(AVG(i.inventory_level), 1)                          AS avg_inventory,
       -- annual turnover per store-SKU = (avg daily sales x 365) / avg stock
       ROUND(AVG(i.units_sold) * 365 / AVG(i.inventory_level), 1) AS turnover_annual,
       ROUND(AVG(i.inventory_level) / NULLIF(AVG(i.units_sold),0), 2) AS days_of_supply
FROM inventory_daily i
JOIN products   p ON p.product_id  = i.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY i.product_id, c.category_name;

-- D1. Products ranked by turnover.
SELECT *, RANK() OVER (ORDER BY turnover_annual DESC) AS turnover_rank
FROM v_turnover
ORDER BY turnover_rank;

-- D2. Turnover by category.
SELECT c.category_name                                          AS category,
       COUNT(DISTINCT i.product_id)                             AS products,
       SUM(i.units_sold)                                        AS units_sold,
       ROUND(AVG(i.units_sold) * 365 / AVG(i.inventory_level), 1) AS turnover_annual,
       ROUND(AVG(i.inventory_level) / AVG(i.units_sold), 2)     AS days_of_supply
FROM inventory_daily i
JOIN products   p ON p.product_id  = i.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY c.category_name
ORDER BY turnover_annual DESC;

-- D3. Monthly turnover trend (is stock getting more or less productive?).
SELECT DATE_TRUNC('month', date)::date                      AS month,
       ROUND(SUM(units_sold)::numeric / AVG(inventory_level) / COUNT(DISTINCT (store_id, product_id)), 2)
                                                            AS turnover_per_sku_month
FROM inventory_daily
GROUP BY 1
ORDER BY 1;


/* ---------------------------------------------------------------------
   E. KPI SUMMARY REPORT
   --------------------------------------------------------------------- */

DROP VIEW IF EXISTS v_kpi_summary CASCADE;
CREATE VIEW v_kpi_summary AS
SELECT
    COUNT(*)                                                              AS sku_days,
    SUM(units_sold)                                                       AS total_units_sold,
    ROUND(SUM(net_revenue), 0)                                            AS total_net_revenue,
    ROUND(AVG(inventory_level), 1)                                        AS avg_stock_per_sku,
    ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2)           AS stockout_rate_pct,
    ROUND(100.0 * AVG((demand_forecast > inventory_level)::int), 2)       AS at_risk_rate_pct,
    ROUND(AVG(inventory_level) / AVG(units_sold), 2)                      AS days_of_supply,
    ROUND(AVG(units_sold) * 365 / AVG(inventory_level), 1)               AS annual_turnover
FROM v_daily;

SELECT * FROM v_kpi_summary;

-- E2. Same KPIs split by store and year (scorecard).
SELECT store_id, year,
       ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2)     AS stockout_rate_pct,
       ROUND(100.0 * AVG((demand_forecast > inventory_level)::int), 2) AS at_risk_rate_pct,
       ROUND(AVG(inventory_level), 1)                                  AS avg_stock,
       ROUND(AVG(inventory_level) / AVG(units_sold), 2)                AS days_of_supply,
       ROUND(SUM(net_revenue), 0)                                      AS net_revenue
FROM v_daily
GROUP BY store_id, year
ORDER BY store_id, year;

-- E3. KPIs by category.
SELECT category,
       ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2)     AS stockout_rate_pct,
       ROUND(100.0 * AVG((demand_forecast > inventory_level)::int), 2) AS at_risk_rate_pct,
       ROUND(AVG(inventory_level), 1)                                  AS avg_stock,
       ROUND(AVG(inventory_level) / AVG(units_sold), 2)                AS days_of_supply,
       ROUND(SUM(net_revenue), 0)                                      AS net_revenue
FROM v_daily
GROUP BY category
ORDER BY net_revenue DESC;
