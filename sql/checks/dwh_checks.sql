-- DWH checks – run in the Neon SQL editor (or any client) after a load. Read-only.
-- Not run by Load_dwh.ipynb (it only runs sql/*.sql, not this folder).

-- 1. Row counts and ranges
SELECT 'dim_date' AS "table", count(*) AS rows, min(date)::text AS "from", max(date)::text AS "to" FROM dwh.dim_date
UNION ALL SELECT 'dim_weather_type', count(*), NULL, NULL FROM dwh.dim_weather_type
UNION ALL SELECT 'dim_city', count(*), NULL, NULL FROM dwh.dim_city
UNION ALL SELECT 'fact_weather_daily', count(*), min(deltadate)::text, max(deltadate)::text FROM dwh.fact_weather_daily;

-- 2. Rows per deltadate (initial load + one per day)
SELECT deltadate, count(*) AS rows, count(DISTINCT city_key) AS cities, min(loaded_at) AS first_loaded, max(loaded_at) AS last_loaded
FROM dwh.fact_weather_daily
GROUP BY deltadate
ORDER BY deltadate;

-- 3. Every city has every day (expect 0 rows)
SELECT c.city, count(f.date_key) AS days, (SELECT count(*) FROM dwh.dim_date) AS expected
FROM dwh.dim_city c
LEFT JOIN dwh.fact_weather_daily f USING (city_key)
GROUP BY c.city
HAVING count(f.date_key) <> (SELECT count(*) FROM dwh.dim_date);

-- 4. Gaps in dim_date (expect 0 rows)
SELECT date, next_date
FROM (SELECT date, lead(date) OVER (ORDER BY date) AS next_date FROM dwh.dim_date) d
WHERE next_date <> date + 1;

-- 5. Orphans and unknown weather codes (expect all 0)
SELECT count(*) FILTER (WHERE c.city_key IS NULL)                AS missing_city,
       count(*) FILTER (WHERE d.date_key IS NULL)                AS missing_date,
       count(*) FILTER (WHERE t.weather_type_key IS NULL)        AS missing_weather_type,
       count(*) FILTER (WHERE f.weather_type_key = -1)           AS unknown_weather_code,
       count(*) FILTER (WHERE f.deltadate <> greatest(d.date, date '2026-10-06')) AS wrong_deltadate
FROM dwh.fact_weather_daily f
LEFT JOIN dwh.dim_city c USING (city_key)
LEFT JOIN dwh.dim_date d USING (date_key)
LEFT JOIN dwh.dim_weather_type t USING (weather_type_key);

-- 6. Cities
SELECT city_key, city, country, population, timezone, hemisphere, grid_latitude, grid_longitude, updated_at
FROM dwh.dim_city
ORDER BY city_key;
