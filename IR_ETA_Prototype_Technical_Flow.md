# Prototype Technical Flow — Exact Technology + Data Transformation at Every Step

This is the prototype-specific version of the data flow: not the full production architecture, but exactly what we've decided to actually build, with the specific tool/technology at each step and how the data's shape/format changes as it passes through.

---

## STEP 1 — Data Collection (Scraper)

**Technology:** Python script (`requests` + `BeautifulSoup`, or direct calls to reverse-engineered NTES JSON endpoints if found — preferred, per Part 9's recommendation to check Network tab before building an HTML scraper), running as a **cron job on a small always-on VPS**.

**Input:** Nothing — this is the origin point. The script is given a list of active train numbers for the day (precomputed each morning from `combined_schedule.csv`: which trains on the target corridor(s) are currently en route based on scheduled departure/arrival windows).

**Process:** Every 10–15 minutes, for each active train, the script sends an HTTP request to NTES/third-party endpoints and receives back either raw HTML or a JSON payload containing: last reported station, timestamp, reported delay, platform number (where available).

**Output — data shape change:** Unstructured HTTP response (HTML or nested JSON) → **written immediately, unparsed, to raw storage** as a timestamped file (e.g. `raw/2026-09-15/train_12345_143000.json`). No cleaning happens yet — this is the "raw-first" rule from the master plan.

**Goes to:** Step 2 (parsing).

---

## STEP 2 — Parsing Raw Snapshots

**Technology:** Python (`pandas`, `json`), run as a separate batch script (can run right after each scrape, or as a nightly job over the day's accumulated raw files).

**Input:** The raw JSON/HTML files from Step 1.

**Process:** Extract the fixed fields from each raw file into a flat row: `train_no, source_name, poll_timestamp, last_station_code, platform_number, reported_delay_min`. Multiple sources (NTES + 2 apps) produce separate rows for the same train/time — these are NOT merged yet at this step, just standardized into the same row format.

**Output — data shape change:** Messy nested JSON/HTML → **one flat CSV/Parquet row per (train, source, timestamp)**. This is now a structured table, appended to a growing `parsed_snapshots.parquet` file.

**Goes to:** Step 3 (reconciliation).

---

## STEP 3 — Multi-Source Reconciliation

**Technology:** Python (`pandas`).

**Input:** `parsed_snapshots.parquet` — multiple rows per (train, approximate timestamp), one per source.

**Process:** Group by (train_no, rounded timestamp), compare `reported_delay_min` across sources. If sources agree within a small tolerance → average/take the higher-frequency source's value, compute `source_agreement_score` (high). If they disagree significantly → flag `source_agreement_score` low, keep the value but mark it as lower-confidence.

**Output — data shape change:** N rows per (train, time) → **1 reconciled row per (train, time)**, with a new `source_agreement_score` column added. Written to `reconciled_positions.parquet`.

**Goes to:** Step 5 (joining) AND Step 7 (precedence-inference pipeline) — this output is used in two places.

---

## STEP 4 — Static Reference Data Preparation (runs once, in parallel with Steps 1–3)

**Technology:** Python (`pandas` for CSVs, `osmium` + `networkx` for OSM).

**Input:** `combined_schedule.csv`, `combined_delay.csv`, `train_details.csv`, `station_full_names.csv` (all already-owned files) + a bulk **Geofabrik India OSM extract**.

**Process:**
- `pandas`: clean each file per the rules in the master plan (cap `combined_delay`'s outlier max, resolve the mislabeled `station_name`-is-actually-a-code issue, flag "SPL" trains).
- `osmium`: filter the huge national OSM extract down to just `railway=rail` ways and `railway=station` nodes — this alone shrinks a multi-GB file to a manageable railway-only dataset.
- `networkx`: build a graph from the filtered OSM ways (nodes = track points, edges = track segments), fuzzy-match OSM station names to real station codes. Instead of taking the pure shortest path between two stations, enumerate the candidate paths between them and pick the one whose **total track length matches the known scheduled distance** for that leg (from `combined_schedule.csv`'s `distance_from_origin` — e.g. if the schedule says the next station is 50 km away, find the candidate path summing to ~50 km, since OSM's scale lets every edge's real-world length be computed directly). This "expected route" is a better proxy for the actual physical line used than pure shortest-path, since at junctions the geometrically shortest path isn't always the one trains are actually scheduled on.

**Output — data shape change:** Several separate raw CSVs + a raw OSM extract → **cleaned individual tables** + **one `section_geometry.parquet`** (station-pair → ordered list of lat/lon coordinates + line attributes like `tracks=`/`electrified=`).

**Goes to:** Step 5 (the master join) and Step 10 (frontend map rendering, for the raw coordinate geometry).

---

## STEP 5 — The Master Join

**Technology:** Python (`pandas`).

**Input:** All cleaned tables from Step 4 + `reconciled_positions.parquet` from Step 3.

**Process:** A single script performs the sequential joins described in the Data Flow Analysis (schedule ⋈ delay ⋈ train_details ⋈ station_full_names ⋈ reconciled tracking ⋈ OSM section attributes), keyed on `train_no` + `station_no`/code + approximate date/time.

**Output — data shape change:** Multiple normalized tables (each a few columns) → **one wide table**, one row per (train, station, date), with every relevant column attached. Written as `master_joined_table.parquet`.

**Goes to:** Step 6 (feature engineering).

---

## STEP 6 — Feature Engineering

**Technology:** Python (`pandas`, `numpy`).

**Input:** `master_joined_table.parquet`.

**Process:** Compute every derived column from Part 5 of the master plan: rolling averages (`section_avg_delay_30d` etc. via `groupby().rolling()`), cyclical time encodings (`np.sin`/`np.cos` on hour/day), `elapsed_journey_pct`, the schedule-based congestion proxy (count of other trains scheduled through the same station-pair within ±30 min — computed via a self-join on `combined_schedule` filtered by time window), and `data_confidence_score` (directly carried over from `source_agreement_score`).

**Output — data shape change:** The wide joined table (raw columns) → the **same table with ~30+ additional numeric feature columns appended**, all numeric/encoded and ready for a model. Written as `model_A_features.parquet`.

**Goes to:** Step 8 (Model A training) directly, AND Step 7b if precedence features are ready.

---

## STEP 7 — Precedence-Inference Pipeline (runs weekly, separate from the main flow)

**Technology:** Python (`pandas`) — a standalone script, scheduled weekly (cron on the same VPS, or run manually while volume is low).

**Input:** `reconciled_positions.parquet` (Step 3) + `train_details.csv` (priority class) + `section_geometry.parquet` (Step 4, for line-type context).

**Process:** Implements the 6-step algorithm from the master plan: compute `delay_picked_up` per section crossing → baseline against the train's own history → filter out systemic (section-wide) delay days → cross-reference nearby higher-priority trains → require repeated occurrence (6+/10) before trusting a candidate → treat platform-number deviation as a confidence booster rather than noise.

**Output — data shape change:** A large table of individual section crossings → a **much smaller table of confidence-scored precedence events**: `(delayed_train, priority_train, section, confidence_score)`. Written as `precedence_events.parquet`.

**Goes to:** Step 7b (feeds into Model B's feature table).

---

## STEP 7b — Adding Precedence Features (produces Model B's table)

**Technology:** Python (`pandas`).

**Input:** `model_A_features.parquet` (Step 6) + the output of Step 7 (precedence-inference pipeline, above).

**Process:** Left-join the precedence-inference output (train_pair, section, date, confidence_score) onto `model_A_features.parquet`, aggregated into `precedence_risk_score_next_section` and `historical_precedence_rate_vs_known_priority_trains`. Rows without a matching precedence record get a default/null value (handled by the model as "no known conflict").

**Output — data shape change:** `model_A_features.parquet` → **`model_B_features.parquet`** (same rows, 2 additional columns).

**Goes to:** Step 8 (Model B training).

---

## STEP 8 — Model Training

**Technology:** `scikit-learn` (Random Forest, Extra Trees) + `XGBoost`. *(Owned by the ML teammate — included here only so the pipeline is complete; not something I'm building.)*

**Input:** `model_A_features.parquet` and `model_B_features.parquet`, split by date (train on older data, test on recent — never randomly shuffled).

**Process:** Train the Stage-2 residual model (predicting actual-minus-baseline delay) separately for Model A and Model B feature sets; derive confidence intervals either via XGBoost's quantile objective or via Random Forest/Extra Trees' natural inter-tree prediction variance; compute SHAP or built-in feature importances for the explainability output.

**Output — data shape change:** A large numeric feature table → **two trained model artifact files** (e.g. `model_a.pkl`, `model_b.pkl`) plus a small metrics report (MAE, CI coverage).

**Goes to:** Step 9 (backend serving).

---

## STEP 9 — Backend API (FastAPI)

**Technology:** FastAPI (Python), deployed on **Render/Railway**.

**Input:** The trained model artifact (loaded once at service startup) +, at each request, the *current* live state of the requested train (pulled from the latest rows of `reconciled_positions.parquet`, refreshed by the same scraper pipeline running continuously).

**Process:** On a request like `GET /predict?train_no=12345`:
1. Pull that train's latest known position/delay from the reconciled data
2. Recompute the same feature logic from Step 6 for this single train's current situation (a lightweight, single-row version of the batch feature engineering)
3. Run Stage 1 baseline arithmetic → Stage 2 model `.predict()` call → Stage 4 uncertainty computation
4. Package the result

**Output — data shape change:** A single train's current raw state (a few fields) → **a structured JSON response**: `{"eta": "...", "confidence_lower": "...", "confidence_upper": "...", "top_delay_factors": [...]}`.

**Goes to:** Step 10 (frontend) over HTTPS.

Other endpoints on the same service:
- `/explain?train_no=X` → returns the feature-importance breakdown for that prediction
- `/replay?train_no=X&date=Y` → reads historical rows for that train/date from `master_joined_table.parquet` and returns them as an ordered time series (for the live-replay demo mode)

---

## STEP 10 — Frontend (React + Vite, on Hostinger)

**Technology:** React (Vite build), deployed as a static site to Hostinger; **Leaflet** for the map, included as a core part of the final prototype, using `section_geometry.parquet`'s coordinates (exported to a small static JSON bundled with the frontend, since it rarely changes).

**Input:** JSON responses from Step 9's API, plus the bundled OSM geometry JSON.

**Process, by mode:**
- **Simple dashboard:** fetches `/predict` and `/explain`, renders as a table/timeline component alongside the map — the core numeric ETA/confidence-band view.
- **Live-replay mode:** fetches `/replay`, then steps through the returned time series on a simulated clock (e.g. 1 real second = several simulated minutes); at each tick, the **time-based polyline-snapping function** (arc-length interpolation over the OSM coordinate array from Step 4) computes the train's approximate position and plots it as a moving marker on the Leaflet map.
- **What-if mode:** a form lets the user pick a train + a hypothetical scenario (e.g. "assume +20 min delay at station X"); this is sent as query parameters to `/predict`, which recomputes the prediction with that hypothetical input substituted into the feature vector.

**Output — data shape change:** JSON numbers/strings → **rendered UI**: table rows, a confidence-band chart, and a moving marker on a Leaflet map. This is the final human-facing output.

**Fallback path:** if the `fetch()` call to the Render backend fails or times out, the frontend catches the error and reads from a **bundled `demo-fallback.json`** (precomputed predictions for a fixed demo train set, built into the React app at build time) — so the on-screen demo never visibly breaks, per the mandatory backup-plan requirement.

---

## STEP 11 — Deployment Mechanics

| Component | Technology | How it's deployed |
|---|---|---|
| Backend | FastAPI | Pushed to Render/Railway (free tier), which builds and runs it from a `requirements.txt` + entrypoint, exposing a public HTTPS URL |
| Frontend | React (Vite) | `npm run build` produces a static `dist/` folder, uploaded to Hostinger (via its file manager or FTP/Git integration, since Hostinger's Business/Cloud plan supports Node-built static output) |
| Connection | HTTPS + CORS | Frontend's `fetch()` calls point at the Render backend's public URL; FastAPI has CORS middleware enabled for the Hostinger domain |

---

## Full Concrete Walkthrough (One Train, One Request)

1. **04:00 AM:** Cron job on the VPS computes today's active-train list from `combined_schedule.csv`.
2. **10:15 AM:** Scraper polls NTES + 2 apps for train 12345 → 3 raw JSON files saved.
3. **10:16 AM:** Parser turns those into 3 flat rows in `parsed_snapshots.parquet`.
4. **10:16 AM:** Reconciliation script merges them into 1 row in `reconciled_positions.parquet` with `source_agreement_score = 0.95` (sources agreed closely).
5. **(Weekly, separately):** Precedence pipeline has already produced a `precedence_risk_score` for train 12345's upcoming section, sitting in `precedence_events.parquet`.
6. **10:17 AM, a passenger opens the dashboard:** React calls `GET /predict?train_no=12345`.
7. **FastAPI:** pulls the 10:16 AM reconciled row + the precomputed precedence score, builds a feature vector, runs it through the trained Model B artifact, returns `{"eta": "14:32", "confidence_lower": "14:24", "confidence_upper": "14:41", "top_delay_factors": ["historical section delay", "precedence risk: SF Express priority crossing"]}`.
8. **React:** renders this as an ETA card with a confidence band and the listed reasons — the actual final output the user sees.
9. **14:32 (or whenever the train actually arrives):** the real arrival time gets captured by the next scrape, written back into the historical data store, and becomes one more training row for the next retraining cycle.

---

## Summary Table — Every Technology, In Order of Use

| Order | Stage | Technology |
|---|---|---|
| 1 | Scraping | Python `requests`/`BeautifulSoup` or NTES JSON endpoints, cron on VPS |
| 2 | Parsing | Python `pandas`, `json` |
| 3 | Reconciliation | Python `pandas` |
| 4 | Static reference prep | Python `pandas`, `osmium`, `networkx` |
| 5 | Master join | Python `pandas` |
| 6 | Feature engineering | Python `pandas`, `numpy` |
| 7 | Precedence-inference | Python `pandas` |
| 8 | Model training | `scikit-learn` (RF, Extra Trees), `XGBoost` |
| 9 | Backend serving | FastAPI, deployed on Render/Railway |
| 10 | Frontend | React (Vite), Leaflet (map), deployed on Hostinger |
| 11 | Storage throughout | Parquet/CSV files (prototype scale — no Kafka/Spark/K8s needed at this volume) |
