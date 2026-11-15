/* =====================================================================
   00_load_raw.sql
   Urban Retail Co. — Inventory Analytics
   ---------------------------------------------------------------------
   PURPOSE : Land the raw CSV exactly as delivered, before any modelling.
             Keeping an untouched staging copy means every later number
             can be traced back to the source file.
   RUN     : psql -d urban_retail -f sql/00_load_raw.sql
             (run from the repo root so the relative CSV path resolves)
   ===================================================================== */

DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

-- Column names are snake_cased; types match the CSV profile.
CREATE TABLE staging.raw_inventory (
    date               DATE          NOT NULL,
    store_id           VARCHAR(10)   NOT NULL,
    product_id         VARCHAR(10)   NOT NULL,
    category           VARCHAR(30)   NOT NULL,
    region             VARCHAR(10)   NOT NULL,
    inventory_level    INTEGER       NOT NULL,
    units_sold         INTEGER       NOT NULL,
    units_ordered      INTEGER       NOT NULL,
    demand_forecast    NUMERIC(10,2) NOT NULL,
    price              NUMERIC(10,2) NOT NULL,
    discount           INTEGER       NOT NULL,   -- percent, 0–20
    weather_condition  VARCHAR(15)   NOT NULL,
    holiday_promotion  SMALLINT      NOT NULL,   -- 0/1 flag
    competitor_pricing NUMERIC(10,2) NOT NULL,
    seasonality        VARCHAR(10)   NOT NULL
);

\copy staging.raw_inventory FROM 'data/inventory_forecasting.csv' WITH (FORMAT csv, HEADER true)

-- Sanity check: expect 109,500 rows = 5 stores x 30 products x 730 days
SELECT COUNT(*)                         AS total_rows,
       COUNT(DISTINCT store_id)         AS stores,
       COUNT(DISTINCT product_id)       AS products,
       MIN(date)                        AS first_day,
       MAX(date)                        AS last_day
FROM staging.raw_inventory;
