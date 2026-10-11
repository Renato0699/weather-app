-- Weather DWH – tables (PostgreSQL). Design: docs/DWH_DESIGN.md
--
-- stg  raw files 1:1 (column names as in the CSV headers), filled by Python before each load
-- dwh  star schema: fact_weather_daily + dim_date, dim_city, dim_weather_type

CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dwh;

-- ---------------------------------------------------------------- staging

-- config/weather_types.csv (WMO weather codes)
CREATE TABLE IF NOT EXISTS stg.weather_types (
    weather_code        smallint,
    description         text,
    category            text,
    intensity           text,
    severity            smallint,
    is_precipitation    boolean,
    is_freezing         boolean
);

-- raw_data/cities/deltadate=<YYYY-MM-DD>/cities.csv (geocoding API) – always all files
CREATE TABLE IF NOT EXISTS stg.cities (
    city            text,           -- name used in the raw weather files
    id              bigint,         -- GeoNames id
    name            text,
    latitude        double precision,
    longitude       double precision,
    elevation       double precision,
    feature_code    text,
    country_code    text,
    timezone        text,
    population      double precision,
    country_id      bigint,         -- GeoNames id of the country
    country         text,
    deltadate       date
);

-- raw_data/weather/deltadate=<YYYY-MM-DD>/<City>.csv
CREATE TABLE IF NOT EXISTS stg.weather_daily (
    city                        text,
    latitude                    double precision,
    longitude                   double precision,
    elevation                   double precision,
    timezone                    text,
    deltadate                   date,
    date                        date,
    weather_code                double precision,
    temperature_2m_max          double precision,
    temperature_2m_min          double precision,
    temperature_2m_mean         double precision,
    apparent_temperature_max    double precision,
    apparent_temperature_min    double precision,
    apparent_temperature_mean   double precision,
    daylight_duration           double precision,
    sunshine_duration           double precision,
    precipitation_sum           double precision,
    rain_sum                    double precision,
    snowfall_sum                double precision,
    precipitation_hours         double precision,
    wind_speed_10m_max          double precision,
    wind_gusts_10m_max          double precision,
    wind_direction_10m_dominant double precision,
    shortwave_radiation_sum     double precision,
    et0_fao_evapotranspiration  double precision
);

-- ---------------------------------------------------------------- dimensions

-- SCD0 – generated calendar
CREATE TABLE IF NOT EXISTS dwh.dim_date (
    date_key        integer PRIMARY KEY,            -- YYYYMMDD
    date            date NOT NULL UNIQUE,
    year            smallint NOT NULL,
    quarter         smallint NOT NULL,
    month           smallint NOT NULL,
    month_name      text NOT NULL,
    iso_week        smallint NOT NULL,
    day_of_month    smallint NOT NULL,
    day_of_year     smallint NOT NULL,
    day_of_week     smallint NOT NULL,              -- Monday = 1
    day_name        text NOT NULL,
    is_weekend      boolean NOT NULL
);

-- SCD0 – WMO weather codes, -1 = unknown
CREATE TABLE IF NOT EXISTS dwh.dim_weather_type (
    weather_type_key    smallint PRIMARY KEY,       -- WMO code
    description         text NOT NULL,
    category            text NOT NULL,
    intensity           text NOT NULL,
    severity            smallint NOT NULL,
    is_precipitation    boolean NOT NULL,
    is_freezing         boolean NOT NULL
);

-- SCD1 – surrogate key, natural key = city
CREATE TABLE IF NOT EXISTS dwh.dim_city (
    city_key        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city            text NOT NULL UNIQUE,
    geonames_id     bigint,
    country         text,
    country_code    text,
    country_id      bigint,
    population      bigint,
    place_type      text,
    latitude        double precision NOT NULL,
    longitude       double precision NOT NULL,
    grid_latitude   double precision,
    grid_longitude  double precision,
    elevation       double precision,
    timezone        text,
    hemisphere      text NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- fact

-- one row per city per day
CREATE TABLE IF NOT EXISTS dwh.fact_weather_daily (
    date_key                    integer  NOT NULL REFERENCES dwh.dim_date,
    city_key                    integer  NOT NULL REFERENCES dwh.dim_city,
    weather_type_key            smallint NOT NULL REFERENCES dwh.dim_weather_type,
    temperature_2m_max          real,    -- °C
    temperature_2m_min          real,    -- °C
    temperature_2m_mean         real,    -- °C
    temperature_range           real,    -- °C, max - min
    apparent_temperature_max    real,    -- °C
    apparent_temperature_min    real,    -- °C
    apparent_temperature_mean   real,    -- °C
    daylight_duration           real,    -- s
    sunshine_duration           real,    -- s
    precipitation_sum           real,    -- mm
    rain_sum                    real,    -- mm
    snowfall_sum                real,    -- cm
    precipitation_hours         real,    -- h
    wind_speed_10m_max          real,    -- km/h
    wind_gusts_10m_max          real,    -- km/h
    wind_direction_10m_dominant real,    -- °
    shortwave_radiation_sum     real,    -- MJ/m²
    et0_fao_evapotranspiration  real,    -- mm
    deltadate                   date NOT NULL,
    loaded_at                   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (date_key, city_key)
);

CREATE INDEX IF NOT EXISTS ix_fact_weather_daily_city ON dwh.fact_weather_daily (city_key, date_key);
CREATE INDEX IF NOT EXISTS ix_fact_weather_daily_deltadate ON dwh.fact_weather_daily (deltadate);
