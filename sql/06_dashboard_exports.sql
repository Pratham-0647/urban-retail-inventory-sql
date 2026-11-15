/* =====================================================================
   06_dashboard_exports.sql
   ---------------------------------------------------------------------
   PURPOSE : Export the dashboard's data as CSV files, so the KPI dashboard
             (or Power BI / Tableau) reads exactly what the SQL produced.
   RUN     : from the repo root, after scripts 00–05.
   OUTPUT  : CSV files in outputs/dashboard_data
   ===================================================================== */

SET search_path = retail;

-- Headline KPIs (one row)
\copy (SELECT * FROM v_kpi_summary) TO 'outputs/dashboard_data/kpi_summary.csv' WITH (FORMAT csv, HEADER)

-- Monthly trend (from the materialized view)
\copy (SELECT month, SUM(units_sold) AS units_sold, ROUND(SUM(net_revenue)) AS net_revenue, ROUND(SUM(forecast_units)) AS forecast_units, ROUND(100.0 * SUM(stockout_days) / SUM(sku_days), 2) AS stockout_rate_pct, ROUND(100.0 * SUM(at_risk_days) / SUM(sku_days), 2) AS at_risk_rate_pct, ROUND(SUM(avg_stock * sku_days) / SUM(sku_days), 1) AS avg_stock FROM mv_monthly_kpis GROUP BY month ORDER BY month) TO 'outputs/dashboard_data/monthly_trend.csv' WITH (FORMAT csv, HEADER)

-- Category scorecard
\copy (SELECT category, SUM(units_sold) AS units_sold, ROUND(SUM(net_revenue)) AS net_revenue, ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2) AS stockout_rate_pct, ROUND(AVG(inventory_level), 1) AS avg_stock, ROUND(AVG(inventory_level) / AVG(units_sold), 2) AS days_of_supply, ROUND(AVG(units_sold) * 365 / AVG(inventory_level), 1) AS annual_turnover FROM v_daily GROUP BY category ORDER BY net_revenue DESC) TO 'outputs/dashboard_data/category_scorecard.csv' WITH (FORMAT csv, HEADER)

-- Store scorecard
\copy (SELECT store_id, ROUND(SUM(net_revenue)) AS net_revenue, ROUND(100.0 * AVG((units_sold >= inventory_level)::int), 2) AS stockout_rate_pct, ROUND(100.0 * AVG((demand_forecast > inventory_level)::int), 2) AS at_risk_rate_pct, ROUND(AVG(inventory_level), 1) AS avg_stock, ROUND(AVG(inventory_level) / AVG(units_sold), 2) AS days_of_supply FROM v_daily GROUP BY store_id ORDER BY store_id) TO 'outputs/dashboard_data/store_scorecard.csv' WITH (FORMAT csv, HEADER)

-- Seasonal index by category
\copy (SELECT category, season, ROUND(AVG(units_sold), 1) AS avg_daily_units, ROUND(AVG(units_sold) / AVG(AVG(units_sold)) OVER (PARTITION BY category), 2) AS seasonal_index FROM v_daily GROUP BY category, season ORDER BY category, season) TO 'outputs/dashboard_data/seasonal_index.csv' WITH (FORMAT csv, HEADER)

-- Promotion gap by category
\copy (SELECT category, ROUND(100 * (AVG(units_sold) FILTER (WHERE holiday_promotion) / AVG(units_sold) FILTER (WHERE NOT holiday_promotion) - 1), 1) AS demand_lift_pct, ROUND(100 * (AVG(inventory_level) FILTER (WHERE holiday_promotion) / AVG(inventory_level) FILTER (WHERE NOT holiday_promotion) - 1), 1) AS stock_lift_pct, ROUND(100.0 * AVG((units_sold >= inventory_level)::int) FILTER (WHERE holiday_promotion), 2) AS stockout_promo_pct, ROUND(100.0 * AVG((units_sold >= inventory_level)::int) FILTER (WHERE NOT holiday_promotion), 2) AS stockout_normal_pct FROM v_daily GROUP BY category ORDER BY category) TO 'outputs/dashboard_data/promo_gap.csv' WITH (FORMAT csv, HEADER)

-- Discount depth vs volume
\copy (SELECT discount_pct, COUNT(*) AS sku_days, ROUND(AVG(units_sold), 1) AS avg_units_sold, ROUND(SUM(units_sold * price * discount_pct / 100.0)) AS revenue_given_away FROM v_daily GROUP BY discount_pct ORDER BY discount_pct) TO 'outputs/dashboard_data/discount_effect.csv' WITH (FORMAT csv, HEADER)

-- Low-inventory alert list (latest day)
\copy (SELECT * FROM v_low_inventory_latest WHERE status <> 'OK' ORDER BY status, suggested_order_qty DESC) TO 'outputs/dashboard_data/low_inventory_alerts.csv' WITH (FORMAT csv, HEADER)

-- Reorder points for every store-product
\copy (SELECT * FROM v_reorder_point ORDER BY store_id, product_id) TO 'outputs/dashboard_data/reorder_points.csv' WITH (FORMAT csv, HEADER)

-- Product turnover + ABC + velocity
\copy (SELECT t.product_id, t.category, a.abc_class, a.revenue, t.units_sold, t.avg_inventory, t.turnover_annual, t.days_of_supply FROM v_turnover t JOIN v_abc a USING (product_id) ORDER BY a.revenue DESC) TO 'outputs/dashboard_data/product_turnover_abc.csv' WITH (FORMAT csv, HEADER)

-- Q1 2024 forecast
\copy (SELECT * FROM v_forecast_q1_2024 ORDER BY category, month) TO 'outputs/dashboard_data/forecast_q1_2024.csv' WITH (FORMAT csv, HEADER)
