# Weather DWH

Daily weather for 23 cities from the [Open-Meteo](https://open-meteo.com/) historical API, stored as raw CSV files
in Neon Object Storage and loaded into a star schema in Neon Postgres. Runs every day in GitHub Actions.

```
Open-Meteo API ──► Ingest_data.ipynb ──► bucket weather-raw ──► Load_dwh.ipynb ──► Neon Postgres (stg → dwh) ──► Power BI
```

## Layout

```
config/settings.py          dates, API URLs, variables, storage and database settings (secrets from .env / env vars)
config/cities.csv           cities to load (city, latitude, longitude)
config/weather_types.csv    WMO weather codes -> dim_weather_type
notebooks/Ingest_data.ipynb API -> raw files
notebooks/Load_dwh.ipynb    raw files -> DWH
notebooks/Test_pipeline.ipynb  tests (workflow "Test pipeline", against Neon)
sql/01_create_tables.sql    stg + dwh tables
sql/02_load_procedures.sql  load procedures (dim_date, dim_weather_type, dim_city, fact_weather_daily)
docs/DWH_DESIGN.md          star schema, columns, keys, SCD types
docs/PIPELINE.md            how the pipeline works, operation, testing, troubleshooting
sql/checks/dwh_checks.sql   read-only checks after a load
.github/workflows/          pipeline.yml (daily), test.yml (manual tests)
```

Raw files in the bucket (never in git):

```
weather/deltadate=<YYYY-MM-DD>/<City>.csv     daily weather, one file per city and deltadate
cities/deltadate=<YYYY-MM-DD>/cities.csv      geocoding (country, population ...), once per city
```

Everything up to 2026-10-06 is the initial load (`deltadate=2026-10-06`); every later day has its own deltadate.
Each run only fetches and loads what is new, so missed days are caught up by the next run.

## Run in GitHub Actions

`.github/workflows/pipeline.yml` runs both notebooks daily at 05:30 UTC (and on demand: *Actions → Daily pipeline →
Run workflow*). The executed notebooks are attached to each run as an artifact.

Repository secrets (*Settings → Secrets and variables → Actions*):

| Secret | Where to find it |
|---|---|
| `STORAGE_ENDPOINT_URL` | Neon Console → Object storage → weather-raw |
| `STORAGE_REGION` | same page, e.g. `eu-central-1` |
| `STORAGE_ACCESS_KEY_ID`, `STORAGE_SECRET_ACCESS_KEY` | Neon Console → Settings → Credentials (storage:read + storage:write, same branch) |
| `STORAGE_BUCKET` | `weather-raw` |
| `DATABASE_URL` | Neon Console → Connect → direct connection string |

## Run locally

```bash
pip install -r requirements.txt
cp .env.example .env        # fill in the values
```

Then run `notebooks/Ingest_data.ipynb` and `notebooks/Load_dwh.ipynb`. With `STORAGE=local` the raw files go to
`raw_data/` in the project instead of the bucket.

More: [docs/PIPELINE.md](docs/PIPELINE.md) (operation, testing, troubleshooting) and
[docs/DWH_DESIGN.md](docs/DWH_DESIGN.md) (tables and columns).

## Add a city

Add a line to `config/cities.csv`. The next run geocodes it, fetches its whole history since 2023 and loads it.
