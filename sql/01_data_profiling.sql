/* =====================================================================
   01_data_profiling.sql
   ---------------------------------------------------------------------
   PURPOSE : Understand the data before designing the schema.
             Each check answers one question and drives a design or
             analysis decision (noted under "Finding").
   ===================================================================== */

-- 1. Grain check: is (date, store, product) unique?
--    Finding: yes, max 1 row per key -> natural primary key for the fact table.
SELECT MAX(cnt) AS max_rows_per_key
FROM (SELECT date, store_id, product_id, COUNT(*) AS cnt
      FROM staging.raw_inventory
      GROUP BY 1, 2, 3) t;

-- 2. Nulls / impossible values.
--    Finding: no nulls, no negatives -> no cleaning of missing values needed.
SELECT SUM(CASE WHEN inventory_level < 0 OR units_sold < 0 OR units_ordered < 0 THEN 1 ELSE 0 END) AS negative_rows,
       SUM(CASE WHEN price <= 0 THEN 1 ELSE 0 END)                                               AS non_positive_price
FROM staging.raw_inventory;

-- 3. Does a product always belong to one category?
--    Finding: yes -> category is an attribute of PRODUCT (goes in products table).
SELECT MAX(n_cat) AS max_categories_per_product
FROM (SELECT product_id, COUNT(DISTINCT category) AS n_cat
      FROM staging.raw_inventory GROUP BY product_id) t;

-- 4. Does a store always sit in one region?
--    Finding: NO — each store appears in all 4 regions on different days
--    (roughly 25% each). Region therefore cannot be a store attribute; it is
--    kept on the daily fact row and flagged as a data-quality issue.
SELECT store_id, region, COUNT(*) AS days
FROM staging.raw_inventory
GROUP BY store_id, region
ORDER BY store_id, region;

-- 5. Is season a function of the date?
--    Finding: yes — fixed by calendar month (Nov–Feb Winter, Mar–Apr Spring,
--    May–Jul Summer, Aug–Oct Autumn) -> season lives in the
--    calendar dimension, not on every fact row.
SELECT EXTRACT(MONTH FROM date)::int AS month, seasonality, COUNT(*) AS rows
FROM staging.raw_inventory
GROUP BY 1, 2
ORDER BY 1;

-- 6. Does inventory "flow"? (today = yesterday - sold + ordered)
--    Finding: matches on <1% of rows -> each row is an independent daily
--    snapshot, not a running ledger. Metrics are computed per snapshot.
WITH flow AS (
    SELECT inventory_level,
           LAG(inventory_level) OVER w - units_sold + units_ordered AS expected_level
    FROM staging.raw_inventory
    WINDOW w AS (PARTITION BY store_id, product_id ORDER BY date)
)
SELECT ROUND(100.0 * AVG(CASE WHEN inventory_level = expected_level THEN 1 ELSE 0 END), 2) AS pct_rows_matching_flow
FROM flow
WHERE expected_level IS NOT NULL;

-- 7. Units sold greater than stock on hand (physically impossible).
--    Finding: ~5% of rows. Treated as "demand exceeded stock" = stockout signal.
SELECT ROUND(100.0 * AVG(CASE WHEN units_sold >  inventory_level THEN 1 ELSE 0 END), 2) AS pct_sold_gt_stock,
       ROUND(100.0 * AVG(CASE WHEN units_sold >= inventory_level THEN 1 ELSE 0 END), 2) AS pct_sold_ge_stock,
       ROUND(100.0 * AVG(CASE WHEN demand_forecast > inventory_level THEN 1 ELSE 0 END), 2) AS pct_forecast_gt_stock
FROM staging.raw_inventory;

-- 8. Value ranges for the numeric columns.
SELECT MIN(inventory_level) AS min_inv,  MAX(inventory_level) AS max_inv,  ROUND(AVG(inventory_level),1) AS avg_inv,
       MIN(units_sold)      AS min_sold, MAX(units_sold)      AS max_sold, ROUND(AVG(units_sold),1)      AS avg_sold,
       MIN(price)           AS min_price,MAX(price)           AS max_price,
       MIN(discount)        AS min_disc, MAX(discount)        AS max_disc
FROM staging.raw_inventory;

-- 9. No supplier / warehouse / lead-time columns exist.
--    Finding: supplier performance must be approximated (see 04_analysis.sql,
--    "replenishment consistency"), and lead time is an explicit assumption
--    stored in the analysis_params table.
