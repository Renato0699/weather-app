"""Settings for notebooks/Ingest_data.ipynb and notebooks/Load_dwh.ipynb. Cities are in config/cities.csv."""

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# Open-Meteo historical weather API, https://open-meteo.com/en/docs/historical-weather-api
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"   # country, region, population of the cities
START_DATE = "2023-01-01"          # first day of the history
INITIAL_DELTADATE = "2026-10-06"   # everything up to this day is the initial load with this deltadate;
                                   # every later day gets its own date as deltadate

# where raw files go: "local" = RAW_DIR in the project, "s3" = bucket on Neon Object Storage – set in .env
STORAGE = os.getenv("STORAGE", "local")
RAW_DIR = "raw_data"
S3_ENDPOINT_URL = os.getenv("STORAGE_ENDPOINT_URL")
S3_REGION = os.getenv("STORAGE_REGION", "eu-central-1")
S3_ACCESS_KEY_ID = os.getenv("STORAGE_ACCESS_KEY_ID")
S3_SECRET_ACCESS_KEY = os.getenv("STORAGE_SECRET_ACCESS_KEY")
S3_BUCKET = os.getenv("STORAGE_BUCKET", "weather-raw")

# PostgreSQL for the DWH (local now, Neon later) – set in .env, see .env.example
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/weather")

# geocoding columns saved to raw_data/cities (+ deltadate)
CITY_COLUMNS = [
    "city", "id", "name", "latitude", "longitude", "elevation", "feature_code",
    "country_code", "timezone", "population", "country_id", "country",
]

DAILY_VARIABLES = [
    "weather_code",
    "temperature_2m_max", "temperature_2m_min", "temperature_2m_mean",
    "apparent_temperature_max", "apparent_temperature_min", "apparent_temperature_mean",
    "daylight_duration", "sunshine_duration",
    "precipitation_sum", "rain_sum", "snowfall_sum", "precipitation_hours",
    "wind_speed_10m_max", "wind_gusts_10m_max", "wind_direction_10m_dominant",
    "shortwave_radiation_sum", "et0_fao_evapotranspiration",
]
