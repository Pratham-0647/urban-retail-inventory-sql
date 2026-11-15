/* =====================================================================
   02_schema_normalized.sql
   ---------------------------------------------------------------------
   PURPOSE : Turn the single flat CSV table into a normalized (3NF)
             relational schema, then populate it from staging.

   DESIGN DECISIONS (each backed by a check in 01_data_profiling.sql)
   - Grain of the fact table = one row per (date, store, product).
   - category depends only on product        -> products.category_id
   - season depends only on calendar month   -> calendar.season_id
   - region varies day-to-day for a store    -> kept on the fact row
     (a data-quality issue; it cannot be a store attribute)
   - repeated text labels (region, category, weather, season) become
     small lookup tables with integer keys -> less storage, no typos.
   - Stock movement and commercial/pricing data are split into two 1:1
     tables. The inventory queries (the hot path) then scan a narrow
     table, and pricing can be maintained by a different process.
   - analysis_params stores business assumptions (lead time, service
     level, holding cost) so they can be changed without editing SQL.
   ===================================================================== */

DROP SCHEMA IF EXISTS retail CASCADE;
CREATE SCHEMA retail;
SET search_path = retail;

/* ---------- Lookup (dimension) tables ---------- */

CREATE TABLE regions (
    region_id   SMALLSERIAL PRIMARY KEY,
    region_name VARCHAR(10) NOT NULL UNIQUE
);

CREATE TABLE categories (
    category_id   SMALLSERIAL PRIMARY KEY,
    category_name VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE weather_conditions (
    weather_id   SMALLSERIAL PRIMARY KEY,
    weather_name VARCHAR(15) NOT NULL UNIQUE
);

CREATE TABLE seasons (
    season_id   SMALLSERIAL PRIMARY KEY,
    season_name VARCHAR(10) NOT NULL UNIQUE
);

CREATE TABLE stores (
    store_id   VARCHAR(10) PRIMARY KEY
);

CREATE TABLE products (
    product_id  VARCHAR(10) PRIMARY KEY,
    category_id SMALLINT    NOT NULL REFERENCES categories(category_id)
);

/* Calendar dimension: every date-derived attribute lives here once,
   instead of being recomputed in every query. */
CREATE TABLE calendar (
    date         DATE        PRIMARY KEY,
    year         SMALLINT    NOT NULL,
    quarter      SMALLINT    NOT NULL,
    month        SMALLINT    NOT NULL,
    month_name   VARCHAR(10) NOT NULL,
    week_of_year SMALLINT    NOT NULL,
    day_of_week  SMALLINT    NOT NULL,          -- ISO: 1 = Monday
    is_weekend   BOOLEAN     NOT NULL,
    season_id    SMALLINT    NOT NULL REFERENCES seasons(season_id)
);

/* ---------- Fact tables ---------- */

CREATE TABLE inventory_daily (
    date            DATE          NOT NULL REFERENCES calendar(date),
    store_id        VARCHAR(10)   NOT NULL REFERENCES stores(store_id),
    product_id      VARCHAR(10)   NOT NULL REFERENCES products(product_id),
    region_id       SMALLINT      NOT NULL REFERENCES regions(region_id),
    weather_id      SMALLINT      NOT NULL REFERENCES weather_conditions(weather_id),
    inventory_level INTEGER       NOT NULL CHECK (inventory_level >= 0),
    units_sold      INTEGER       NOT NULL CHECK (units_sold      >= 0),
    units_ordered   INTEGER       NOT NULL CHECK (units_ordered   >= 0),
    demand_forecast NUMERIC(10,2) NOT NULL CHECK (demand_forecast >= 0),
    PRIMARY KEY (date, store_id, product_id)
);

CREATE TABLE pricing_daily (
    date              DATE          NOT NULL,
    store_id          VARCHAR(10)   NOT NULL,
    product_id        VARCHAR(10)   NOT NULL,
    price             NUMERIC(10,2) NOT NULL CHECK (price > 0),
    discount_pct      SMALLINT      NOT NULL CHECK (discount_pct BETWEEN 0 AND 100),
    competitor_price  NUMERIC(10,2) NOT NULL CHECK (competitor_price > 0),
    holiday_promotion BOOLEAN       NOT NULL,
    PRIMARY KEY (date, store_id, product_id),
    FOREIGN KEY (date, store_id, product_id)
        REFERENCES inventory_daily (date, store_id, product_id) ON DELETE CASCADE
);

/* ---------- Business assumptions ---------- */

CREATE TABLE analysis_params (
    param_name  VARCHAR(40) PRIMARY KEY,
    param_value NUMERIC     NOT NULL,
    description TEXT        NOT NULL
);

INSERT INTO analysis_params VALUES
 ('lead_time_days',     1,    'Replenishment lead time. The data shows units ordered ~ units sold every day, i.e. daily replenishment, so 1 day is the default.'),
 ('service_level_z',    1.65, 'z-score for a 95% cycle service level, used in safety stock.'),
 ('holding_cost_rate',  0.25, 'Annual holding cost as a share of item value (industry rule of thumb: 20–30%).'),
 ('overstock_dos_days', 2.0,  'Days of supply above which a store-product is treated as overstocked.');

/* ---------- Populate from staging ---------- */

INSERT INTO regions (region_name)
SELECT DISTINCT region FROM staging.raw_inventory ORDER BY 1;

INSERT INTO categories (category_name)
SELECT DISTINCT category FROM staging.raw_inventory ORDER BY 1;

INSERT INTO weather_conditions (weather_name)
SELECT DISTINCT weather_condition FROM staging.raw_inventory ORDER BY 1;

INSERT INTO seasons (season_name)
VALUES ('Winter'), ('Spring'), ('Summer'), ('Autumn');

INSERT INTO stores (store_id)
SELECT DISTINCT store_id FROM staging.raw_inventory ORDER BY 1;

INSERT INTO products (product_id, category_id)
SELECT DISTINCT r.product_id, c.category_id
FROM staging.raw_inventory r
JOIN categories c ON c.category_name = r.category
ORDER BY 1;

INSERT INTO calendar
SELECT DISTINCT
       r.date,
       EXTRACT(YEAR    FROM r.date)::SMALLINT,
       EXTRACT(QUARTER FROM r.date)::SMALLINT,
       EXTRACT(MONTH   FROM r.date)::SMALLINT,
       TRIM(TO_CHAR(r.date, 'Month')),
       EXTRACT(WEEK    FROM r.date)::SMALLINT,
       EXTRACT(ISODOW  FROM r.date)::SMALLINT,
       EXTRACT(ISODOW  FROM r.date) IN (6, 7),
       s.season_id
FROM staging.raw_inventory r
JOIN seasons s ON s.season_name = r.seasonality;

INSERT INTO inventory_daily
SELECT r.date, r.store_id, r.product_id,
       rg.region_id, w.weather_id,
       r.inventory_level, r.units_sold, r.units_ordered, r.demand_forecast
FROM staging.raw_inventory r
JOIN regions            rg ON rg.region_name  = r.region
JOIN weather_conditions w  ON w.weather_name  = r.weather_condition;

INSERT INTO pricing_daily
SELECT date, store_id, product_id,
       price, discount, competitor_pricing, holiday_promotion = 1
FROM staging.raw_inventory;

/* ---------- Reconciliation: normalized model must equal the source ---------- */
SELECT 'inventory_daily' AS tbl, COUNT(*) AS rows FROM inventory_daily
UNION ALL SELECT 'pricing_daily', COUNT(*) FROM pricing_daily
UNION ALL SELECT 'calendar',      COUNT(*) FROM calendar
UNION ALL SELECT 'products',      COUNT(*) FROM products
UNION ALL SELECT 'stores',        COUNT(*) FROM stores;

SELECT (SELECT SUM(units_sold) FROM staging.raw_inventory) AS raw_units_sold,
       (SELECT SUM(units_sold) FROM inventory_daily)       AS model_units_sold;

/* Convenience view that re-joins everything into one readable row.
   Analysts query this; the tables underneath stay normalized. */
CREATE VIEW v_daily AS
SELECT i.date, cal.year, cal.quarter, cal.month, cal.month_name,
       cal.week_of_year, cal.is_weekend, se.season_name AS season,
       i.store_id, i.product_id, c.category_name AS category,
       rg.region_name AS region, w.weather_name AS weather,
       i.inventory_level, i.units_sold, i.units_ordered, i.demand_forecast,
       p.price, p.discount_pct, p.competitor_price, p.holiday_promotion,
       ROUND(i.units_sold * p.price * (1 - p.discount_pct / 100.0), 2) AS net_revenue
FROM inventory_daily i
JOIN pricing_daily      p   USING (date, store_id, product_id)
JOIN calendar           cal ON cal.date       = i.date
JOIN seasons            se  ON se.season_id   = cal.season_id
JOIN products           pr  ON pr.product_id  = i.product_id
JOIN categories         c   ON c.category_id  = pr.category_id
JOIN regions            rg  ON rg.region_id   = i.region_id
JOIN weather_conditions w   ON w.weather_id   = i.weather_id;
