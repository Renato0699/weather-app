-- Weather DWH – load procedures (PostgreSQL). Run after 01_create_tables.sql.
-- Every procedure reads only from stg.*, which notebooks/Load_dwh.ipynb fills from the CSV files:
--   stg.weather_types <- config/weather_types.csv
--   stg.cities        <- raw_data/cities/deltadate=*/cities.csv (all files)
--   stg.weather_daily <- raw_data/weather/deltadate=*/*.csv (deltadates not loaded yet)
-- Order: load_dim_date, load_dim_weather_type, load_dim_city, load_fact_weather_daily

-- ---------------------------------------------------------------- dim_date (SCD0)
-- Days of the weather files that are not in dim_date yet.
CREATE OR REPLACE PROCEDURE dwh.load_dim_date()
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO dwh.dim_date
    SELECT to_char(d, 'YYYYMMDD')::integer,
           d,
           extract(year FROM d),
           extract(quarter FROM d),
           extract(month FROM d),
           to_char(d, 'FMMonth'),
           extract(week FROM d),
           extract(day FROM d),
           extract(doy FROM d),
           extract(isodow FROM d),
           to_char(d, 'FMDay'),
           extract(isodow FROM d) IN (6, 7)
    FROM (SELECT DISTINCT date AS d FROM stg.weather_daily) AS days
    ON CONFLICT (date_key) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'dim_date: % new rows', n;
END $$;

-- ---------------------------------------------------------------- dim_weather_type (SCD0)
-- Codes of config/weather_types.csv that are not in dim_weather_type yet.
CREATE OR REPLACE PROCEDURE dwh.load_dim_weather_type()
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO dwh.dim_weather_type
        (weather_type_key, description, category, intensity, severity, is_precipitation, is_freezing)
    SELECT weather_code, description, category, intensity, severity, is_precipitation, is_freezing
    FROM stg.weather_types
    ON CONFLICT (weather_type_key) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'dim_weather_type: % new rows', n;
END $$;

-- ---------------------------------------------------------------- dim_city (SCD1)
-- Newest row per city in raw_data/cities (stg.cities) + grid cell from the newest weather row in staging.
-- Existing cities keep their city_key and get the attributes overwritten.
CREATE OR REPLACE PROCEDURE dwh.load_dim_city()
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO dwh.dim_city AS c
        (city, geonames_id, country, country_code, country_id, population, place_type,
         latitude, longitude, grid_latitude, grid_longitude, elevation, timezone, hemisphere)
    SELECT geo.city,
           geo.id,
           geo.country,
           geo.country_code,
           geo.country_id,
           geo.population::bigint,
           geo.feature_code,
           geo.latitude,
           geo.longitude,
           w.latitude,
           w.longitude,
           coalesce(w.elevation, geo.elevation),
           coalesce(w.timezone, geo.timezone),
           CASE WHEN geo.latitude >= 0 THEN 'North' ELSE 'South' END
    FROM (SELECT DISTINCT ON (city) * FROM stg.cities ORDER BY city, deltadate DESC) geo
    LEFT JOIN LATERAL (SELECT s.latitude, s.longitude, s.elevation, s.timezone
                       FROM stg.weather_daily s
                       WHERE s.city = geo.city
                       ORDER BY s.date DESC
                       LIMIT 1) w ON true
    ON CONFLICT (city) DO UPDATE SET
        geonames_id    = excluded.geonames_id,
        country        = excluded.country,
        country_code   = excluded.country_code,
        country_id     = excluded.country_id,
        population     = excluded.population,
        place_type     = excluded.place_type,
        latitude       = excluded.latitude,
        longitude      = excluded.longitude,
        -- grid cell is only in staging for cities with new weather rows – keep the old value otherwise
        grid_latitude  = coalesce(excluded.grid_latitude,  c.grid_latitude),
        grid_longitude = coalesce(excluded.grid_longitude, c.grid_longitude),
        elevation      = CASE WHEN excluded.grid_latitude IS NULL THEN c.elevation ELSE excluded.elevation END,
        timezone       = excluded.timezone,
        hemisphere     = excluded.hemisphere,
        updated_at     = now()
    WHERE (c.geonames_id, c.country, c.country_code, c.country_id, c.population, c.place_type,
           c.latitude, c.longitude, c.grid_latitude, c.grid_longitude, c.elevation, c.timezone, c.hemisphere)
          IS DISTINCT FROM
          (excluded.geonames_id, excluded.country, excluded.country_code, excluded.country_id,
           excluded.population, excluded.place_type, excluded.latitude, excluded.longitude,
           coalesce(excluded.grid_latitude, c.grid_latitude), coalesce(excluded.grid_longitude, c.grid_longitude),
           CASE WHEN excluded.grid_latitude IS NULL THEN c.elevation ELSE excluded.elevation END,
           excluded.timezone, excluded.hemisphere);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'dim_city: % rows inserted or updated', n;
END $$;

-- ---------------------------------------------------------------- fact_weather_daily
-- Upsert by (date_key, city_key): a reloaded deltadate replaces the rows it contains.
CREATE OR REPLACE PROCEDURE dwh.load_fact_weather_daily()
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
    missing text;
BEGIN
    SELECT string_agg(DISTINCT s.city, ', ') INTO missing
    FROM stg.weather_daily s
    LEFT JOIN dwh.dim_city c ON c.city = s.city
    WHERE c.city_key IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Cities in stg.weather_daily but not in dim_city (not in raw_data/cities): %', missing;
    END IF;

    INSERT INTO dwh.fact_weather_daily AS f
        (date_key, city_key, weather_type_key,
         temperature_2m_max, temperature_2m_min, temperature_2m_mean, temperature_range,
         apparent_temperature_max, apparent_temperature_min, apparent_temperature_mean,
         daylight_duration, sunshine_duration, precipitation_sum, rain_sum, snowfall_sum, precipitation_hours,
         wind_speed_10m_max, wind_gusts_10m_max, wind_direction_10m_dominant,
         shortwave_radiation_sum, et0_fao_evapotranspiration, deltadate, loaded_at)
    SELECT to_char(s.date, 'YYYYMMDD')::integer,
           c.city_key,
           coalesce(wt.weather_type_key, -1),
           s.temperature_2m_max, s.temperature_2m_min, s.temperature_2m_mean,
           s.temperature_2m_max - s.temperature_2m_min,
           s.apparent_temperature_max, s.apparent_temperature_min, s.apparent_temperature_mean,
           s.daylight_duration, s.sunshine_duration, s.precipitation_sum, s.rain_sum, s.snowfall_sum,
           s.precipitation_hours, s.wind_speed_10m_max, s.wind_gusts_10m_max, s.wind_direction_10m_dominant,
           s.shortwave_radiation_sum, s.et0_fao_evapotranspiration,
           s.deltadate,
           now()
    FROM stg.weather_daily s
    JOIN dwh.dim_city c ON c.city = s.city
    LEFT JOIN dwh.dim_weather_type wt ON wt.weather_type_key = s.weather_code::smallint
    ON CONFLICT (date_key, city_key) DO UPDATE SET
        weather_type_key            = excluded.weather_type_key,
        temperature_2m_max          = excluded.temperature_2m_max,
        temperature_2m_min          = excluded.temperature_2m_min,
        temperature_2m_mean         = excluded.temperature_2m_mean,
        temperature_range           = excluded.temperature_range,
        apparent_temperature_max    = excluded.apparent_temperature_max,
        apparent_temperature_min    = excluded.apparent_temperature_min,
        apparent_temperature_mean   = excluded.apparent_temperature_mean,
        daylight_duration           = excluded.daylight_duration,
        sunshine_duration           = excluded.sunshine_duration,
        precipitation_sum           = excluded.precipitation_sum,
        rain_sum                    = excluded.rain_sum,
        snowfall_sum                = excluded.snowfall_sum,
        precipitation_hours         = excluded.precipitation_hours,
        wind_speed_10m_max          = excluded.wind_speed_10m_max,
        wind_gusts_10m_max          = excluded.wind_gusts_10m_max,
        wind_direction_10m_dominant = excluded.wind_direction_10m_dominant,
        shortwave_radiation_sum     = excluded.shortwave_radiation_sum,
        et0_fao_evapotranspiration  = excluded.et0_fao_evapotranspiration,
        deltadate                   = excluded.deltadate,
        loaded_at                   = excluded.loaded_at;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'fact_weather_daily: % rows inserted or updated', n;
END $$;
