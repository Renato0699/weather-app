# Weather pipeline – how it works and how to run it

Daily weather for the cities in `config/cities.csv`, from the Open-Meteo historical API to a star schema in Neon
Postgres. Table and column design: [DWH_DESIGN.md](DWH_DESIGN.md).

```
             Ingest_data.ipynb                         Load_dwh.ipynb
Open-Meteo ───────────────────► Neon bucket weather-raw ───────────────► Neon Postgres  ──► Power BI
 archive API                    weather/ cities/        stg.* → dwh.*    (neondb)
 geocoding API                  (raw CSV, by deltadate) (procedures)
```

| Part | Where |
|---|---|
| Code | GitHub `Renato0699/weather-app` (private) |
| Raw files | Neon project `still-boat-59324290`, branch `br-holy-forest-b9lgdjy2`, Object storage bucket `weather-raw` |
| DWH | same branch, database `neondb`, schemas `stg` and `dwh` |
| Schedule | GitHub Actions, *Daily pipeline*, every day 05:30 UTC |

---

## 1. Raw layer – the bucket

```
weather/deltadate=<YYYY-MM-DD>/<City>.csv     one file per city and deltadate
cities/deltadate=<YYYY-MM-DD>/cities.csv      geocoding of all cities added in that deltadate
```

**deltadate**

| Data | deltadate |
|---|---|
| weather for days up to 2026-10-06 (the initial load, history since 2023-01-01) | `2026-10-06` |
| weather for any later day | the day itself (`2026-10-07`, `2026-10-08`, …) |
| cities | `2026-10-06` – a city's row is written once, in the folder where its weather history starts |

`deltadate` is also a column in every file and in `dwh.fact_weather_daily`, so every row can be traced to its
load. Rule in one line: `deltadate = max(date, 2026-10-06)`.

**Weather file columns:** `city, latitude, longitude, elevation, timezone` (the weather-model grid cell the API
used), `deltadate, date`, then the 18 variables of `DAILY_VARIABLES` in `config/settings.py`.

**City file columns:** `city, id, name, latitude, longitude, elevation, feature_code, country_code, timezone,
population, country_id, country, deltadate` (`CITY_COLUMNS` in `config/settings.py`).

Raw files are never in git. `.gitignore` excludes `raw_data/` (the local copy when `STORAGE=local`).

---

## 2. Ingest – `notebooks/Ingest_data.ipynb`

1. **Setup** – reads `config/settings.py`; secrets come from `.env` locally or from environment variables in
   GitHub. `STORAGE=s3` reads and writes the bucket, `STORAGE=local` the `raw_data/` folder (same keys).
2. **Cities – geocoding** – every city in `config/cities.csv` that is not in any `cities/…/cities.csv` yet is
   looked up in the Open-Meteo geocoding API. Several places share a name, so the result with exactly the same name
   closest to the configured coordinates wins (otherwise Scottsdale becomes "Scottsdale Trailer Corral").
3. **Weather** – for each city: find its newest deltadate in the bucket, fetch every day after it up to
   **yesterday** (one request per city), split the rows by deltadate, write one file per deltadate.
   - No data yet for a city → its whole history from `START_DATE` (2023-01-01).
   - Days the archive does not have yet (all values empty) are dropped and come with a later run.
   - Free API limit: 600 calls/minute. A "limit exceeded" answer waits 60 s and retries (up to 3 times).
     18 variables count as 1.8 calls per city and 2 weeks: a full history for one city ≈ 180 weighted calls,
     the daily delta for all 23 cities ≈ 40 (free tier: 10,000 a day).

Re-running is safe: a city that is up to date is skipped. Missed days are caught up by the next run.

---

## 3. DWH load – `notebooks/Load_dwh.ipynb`

1. Runs `sql/01_create_tables.sql` and `sql/02_load_procedures.sql` (`IF NOT EXISTS` / `CREATE OR REPLACE` –
   safe every time).
2. **Staging** – each `stg` table is truncated and filled from the CSV files (columns by name):

   | Staging table | Source |
   |---|---|
   | `stg.weather_types` | `config/weather_types.csv` |
   | `stg.cities` | all `cities/deltadate=*/cities.csv` |
   | `stg.weather_daily` | only weather files whose (deltadate, city) is not in `dwh.fact_weather_daily` yet |

3. **Procedures**

   | Procedure | When | What |
   |---|---|---|
   | `dwh.load_dim_weather_type()` | only if codes from the CSV are missing | inserts missing codes (SCD0) |
   | `dwh.load_dim_date()` | only if staged dates are missing | inserts missing dates (SCD0) |
   | `dwh.load_dim_city()` | every run | upsert by `city` (SCD1, newest deltadate per city), keeps `city_key` |
   | `dwh.load_fact_weather_daily()` | every run | upsert by (`date_key`, `city_key`) |

4. One transaction: either everything is loaded or nothing (a failed run leaves the DWH unchanged).
5. Shows row counts and a summary per city.

`load_fact_weather_daily` stops with an error if a city in the weather files has no row in `raw_data/cities` –
the ingest always writes the city first, so this only happens if files were copied by hand.

---

## 4. Daily operation

- **Schedule:** `.github/workflows/pipeline.yml`, 05:30 UTC, runs Ingest then Load. Yesterday's weather is in the
  archive by then.
- **Manual run:** GitHub → *Actions → Daily pipeline → Run workflow*, or `gh workflow run pipeline.yml -R Renato0699/weather-app`.
- **What a run did:** each run has an artifact *notebooks-&lt;run id&gt;* with both executed notebooks (30 days).
- **Failures:** GitHub e-mails you when a scheduled run fails. Fix the cause and run it again – it continues where
  it stopped.
- **Checks:** `sql/checks/dwh_checks.sql` in the Neon SQL editor (read-only).

### Secrets

GitHub repository secrets (*Settings → Secrets and variables → Actions*) and, for local runs, `.env`
(template `.env.example`):

| Name | Neon Console |
|---|---|
| `DATABASE_URL` | Connect → direct connection string (host without `-pooler`) |
| `STORAGE_ENDPOINT_URL`, `STORAGE_REGION` | Object storage → weather-raw |
| `STORAGE_ACCESS_KEY_ID`, `STORAGE_SECRET_ACCESS_KEY` | Settings → Credentials, `storage:read` + `storage:write`, same branch |
| `STORAGE_BUCKET` | `weather-raw` |

**Rotating a password/key:** create the new one in Neon, update `.env` and the GitHub secret
(`gh secret set DATABASE_URL -R Renato0699/weather-app`), run the workflow once, then delete the old one in Neon.

---

## 5. Common tasks

| Task | How |
|---|---|
| **Add a city** | add `city,latitude,longitude` to `config/cities.csv`, commit. The next run geocodes it, fetches its history since 2023 and loads it. |
| **Reload one day** | `DELETE FROM dwh.fact_weather_daily WHERE deltadate = '2026-10-08';` – the next Load_dwh run sees those files as new and loads them again. |
| **Re-fetch one day from the API** | delete `weather/deltadate=<day>/` in the bucket **and** the fact rows of that deltadate; the next run fetches and loads it again. Only works for the newest days – Ingest continues after the newest deltadate per city. |
| **Rebuild the whole DWH** | `DROP SCHEMA stg, dwh CASCADE;` then run Load_dwh – everything is rebuilt from the bucket (`city_key`s are regenerated). |
| **Add a weather variable** | add it to `DAILY_VARIABLES`, to `stg.weather_daily` and `dwh.fact_weather_daily` (ALTER TABLE) and to `load_fact_weather_daily`. Existing files do not have it – a full re-fetch is needed for history. |
| **Work locally** | `.env` with `STORAGE=local` and a local `DATABASE_URL`; run the notebooks in Jupyter / VS Code from `notebooks/`. |

---

## 6. Testing the incremental load

### What each test proves

| Test | Proves |
|---|---|
| **A. Incremental ingest + load** | a missing day is fetched from the API, written to the bucket and loaded; dims get the new date |
| **B. Upsert (update path)** | loading rows that already exist updates them instead of duplicating or failing |
| **C. Idempotence** | running the pipeline again changes nothing |

Emptying the tables and leaving out one day only exercises **inserts**. The update branch of the upsert only runs
when the same (date, city) is loaded twice, and Load_dwh never does that on its own (it skips files that are
already in the fact). Test B forces it.

### A. Incremental ingest + load

1. **Empty the DWH** (Neon SQL editor). Truncate the fact and the dimensions together because of the foreign keys;
   `RESTART IDENTITY` starts `city_key` at 1 again:
   ```sql
   TRUNCATE dwh.fact_weather_daily, dwh.dim_city, dwh.dim_date, dwh.dim_weather_type RESTART IDENTITY;
   TRUNCATE stg.weather_daily, stg.cities, stg.weather_types;
   ```
2. **Remove the last day from the bucket** – delete the folder `weather/deltadate=2026-10-10/` (23 files) in
   *Neon Console → Object storage → weather-raw*. Deleting `2026-10-10` only from `dim_date` is not enough: the
   files would be loaded again by the next run.
3. **Load without that day** – run `Load_dwh.ipynb` (locally, or temporarily via the workflow). Expect:
   `92 new weather file(s)`, `dim_date: 1378 new rows`, `fact_weather_daily: 31694`, max deltadate `2026-10-09`.
4. **Run the whole pipeline** – *Actions → Daily pipeline → Run workflow*. Expect in the run's notebooks:
   - Ingest: every city `2026-10-10 .. <yesterday> -> N days` (N = 1 if you test on 2026-10-11), new files in
     `weather/deltadate=2026-10-10/`
   - Load: `23 new weather file(s)` per day, `dim_date: N new rows`, `fact_weather_daily: 23·N rows`
5. **Check** – `sql/checks/dwh_checks.sql`: query 2 shows the new deltadate(s) with a later `loaded_at`,
   queries 3–5 return no problems.

If you test on a later day than 2026-10-11, the run also fetches the days after 2026-10-10 – each gets its own
deltadate, which is part of what is being tested.

### B. Upsert (update path)

After a Load_dwh run that loaded new rows (e.g. step 4 of test A), `stg.weather_daily` still holds those rows –
staging is only emptied by the next run. Load them again:

```sql
SELECT count(*), max(loaded_at) FROM dwh.fact_weather_daily;   -- note both
CALL dwh.load_fact_weather_daily();                             -- NOTICE: N rows inserted or updated
SELECT count(*), max(loaded_at) FROM dwh.fact_weather_daily;   -- same count, newer loaded_at
SELECT count(*) FROM (SELECT date_key, city_key FROM dwh.fact_weather_daily GROUP BY 1, 2 HAVING count(*) > 1) d;  -- 0
```

To see a value really change, edit a row in staging first:

```sql
UPDATE stg.weather_daily SET temperature_2m_max = 99 WHERE city = 'London';
CALL dwh.load_fact_weather_daily();
SELECT d.date, f.temperature_2m_max FROM dwh.fact_weather_daily f
JOIN dwh.dim_city c USING (city_key) JOIN dwh.dim_date d USING (date_key)
WHERE c.city = 'London' ORDER BY d.date DESC LIMIT 3;      -- 99 on the staged days
```

Then repair it with "Reload one day" from section 5 (or run test A again).

`dim_city` works the same way: `CALL dwh.load_dim_city();` twice → the second call reports `0 rows`
(unchanged rows are not touched); change `population` in `stg.cities` → `1 rows`, same `city_key`.

### C. Idempotence

Run the workflow again right after A. Expect `up to date` for every city, `0 new weather file(s)`,
`0 rows inserted or updated`, and unchanged counts in the checks.

---

## 7. Known limitations

- **A raw file rewritten after it was loaded is not reloaded** – Load_dwh decides by (deltadate, city) present in
  the fact. Use "Reload one day".
- **Archive revisions are not picked up** – Open-Meteo can correct recent days later; a day is fetched once.
- **Cities are geocoded once** – population etc. are not refreshed unless the city's row is removed from
  `cities.csv` in the bucket.
- **`dim_date` only has days with data** – it ends with the newest loaded day. Fine for Power BI time
  intelligence because it has no gaps; `SAMEPERIODLASTYEAR` compares a partial year with the same partial period.

---

## 8. Power BI

*Get data → PostgreSQL database*, server `ep-long-cell-b9lxk785.c-7.eu-central-1.aws.neon.tech`, database
`neondb`, Import mode, *Database* credentials. Load only the four `dwh` tables, relate the fact to the
dimensions on `date_key`, `city_key`, `weather_type_key`, and mark `dwh dim_date` as the date table (column `date`) –
needed for time intelligence because the relationship uses an integer key.

If Power BI reports *"Endpoint ID is not specified"*, enter the password as `endpoint=ep-long-cell-b9lxk785;<password>`.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Minutely API request limit exceeded` in the ingest output | normal – it waits 60 s and continues |
| `Daily API request limit exceeded` | 10,000 weighted calls/day used (e.g. several full re-fetches) – run again tomorrow |
| `AccessDenied` / `SignatureDoesNotMatch` from storage | wrong key/secret, a credential without `storage:write`, or one created on another branch |
| `Cities in stg.weather_daily but not in dim_city` | weather file for a city without a row in `cities/…/cities.csv` – run Ingest (it geocodes first) |
| `connection timeout` to Neon | the compute was suspended – run again; check the host in `DATABASE_URL` |
