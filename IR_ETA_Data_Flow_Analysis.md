# Full Data Flow Analysis — Indian Railways ETA Prediction System

This traces every piece of data from its origin to its final use — what's collected, from where, what happens to it, where it's stored, and what it becomes input to, at each stage. Structured as a pipeline with numbered stages so every arrow (source → transformation → output → next input) is explicit.

**Key clarification incorporated:** We are NOT building GPS tracking ourselves. Real-time train location is already solved at the infrastructure level by **CRIS/ISRO's RTIS system** — that's the eventual real data source once access is granted (Part 12, action item #1 in the master plan). Until then, the prototype substitutes **scraped public train-tracking data (NTES/third-party apps) + OSM track geometry for interpolated positioning** as a stand-in for that exact same slot in the pipeline. This is designed as a single swappable input at Stage 1 — nothing downstream changes when real CRIS access arrives.

---

## STAGE 1 — DATA SOURCES (origin of every piece of data)

| # | Source | What it provides | Collection method | Status |
|---|---|---|---|---|
| 1a | `combined_schedule.csv` | Timetable: station sequence, arrival/departure times, distance | One-time file (already have it) | Available now |
| 1b | `combined_delay.csv` | Historical per-station delay records | One-time file (already have it) | Available now |
| 1c | `train_details.csv` | Train priority class (Rajdhani/Express/etc.) | One-time file (already have it) | Available now |
| 1d | `station_full_names.csv` | Station code → name → zone mapping | One-time file (already have it) | Available now |
| 1e | `etrain_delays.csv` | Pre-aggregated 1-year delay summary per train-station | One-time file (already have it) | Available now |
| 1f | NTES + third-party apps (RailYatri/Trainman/Where Is My Train) | Live train position (last known station + time), reported delay, platform number | **Continuous scraper**, polling every 10-15 min for active trains on target corridors | To be built (Part 9 of master plan) |
| 1g | OpenStreetMap (Overpass API / Geofabrik extract) | Real track geometry, station node coordinates, line attributes (single/double, electrified) | **One-time bulk extract**, refreshed rarely (infra doesn't change often) | To be built |
| 1h | IMD weather API | Visibility, rainfall, temperature, cyclone alerts | Would be periodic API pull | Named but not yet built (static seasonal flag used for now instead) |
| 1i | TSR/PSR notices (railway division PDFs/Excel) | Active speed restrictions | Would need NLP/regex parser | Named but not yet built |
| 1j | **CRIS/ISRO RTIS (real GPS)** | True continuous train location, real block-section occupancy | **Not built by us — accessed via data-sharing agreement once granted** | Future / production only |
| 1k | Synthetic Kaggle dataset (`ir_train.csv` etc.) | NOT used in main pipeline — sandbox only | One-time file | Available, isolated use only |

---

## STAGE 2 — INGESTION (how each source physically enters the system)

- **1a–1e (static files):** loaded once into a raw staging area (a `/raw/` folder or raw Postgres tables) — no transformation yet, just captured as-is.
- **1f (scraper):** runs on an always-on VPS (per Part 9). Each poll's raw JSON/HTML response is written immediately to dated raw storage **before** any parsing — this is the "never parse-then-discard" rule from the master plan, so a parser bug never destroys collected data.
- **1g (OSM):** downloaded once as a bulk regional extract, filtered locally with `osmium` for railway tags only, stored as a static reference file (doesn't need continuous re-ingestion).
- **1h/1i (weather/TSR):** would be pulled on a schedule (e.g. every few hours) and land in raw staging the same way as 1f.
- **1j (future CRIS):** would plug into this exact same ingestion layer as a new source — same downstream pipeline, this is the swap point mentioned above.

**Output of Stage 2:** raw, untransformed data sitting in dated/partitioned storage, one bucket per source.

---

## STAGE 3 — CLEANING & TRANSFORMATION (per-source processing)

| Source | Cleaning steps applied |
|---|---|
| `combined_delay.csv` | Cap outlier delays (max was 7,018 min — cap at ~99.5th percentile); handle 6.5% missing `delay` rows; parse `date` field |
| `combined_schedule.csv` | Resolve mislabeled `station_name` column (actually a code); handle nulls at origin/terminal stations (expected, not errors) |
| `train_details.csv` | Flag "SPL" (special) trains separately from regular scheduled services |
| Scraped tracking data (1f) | Multi-source reconciliation: merge NTES + app readings per (train, timestamp) into one value with a `source_agreement_score`; discard/flag snapshots with high disagreement |
| OSM data (1g) | Fuzzy-match OSM station names to real station codes; build a graph (`networkx`) of track ways; find the "expected route" between named station pairs by matching candidate path length against the known scheduled distance (rather than pure shortest path, since the geometrically shortest path isn't always the actual line a train runs on at junctions); extract `tracks=`, `electrified=` tags where present |
| TSR/PSR notices (1i) | NLP/regex parsing of semi-structured PDF/Excel into structured (section, severity, active-dates) records |

**Output of Stage 3:** cleaned, structured tables — one per source, all still separate at this point.

---

## STAGE 4 — JOINING (where separate sources become one dataset)

**The core join** (real data only — synthetic Kaggle set is explicitly excluded here, per the earlier "why we don't merge synthetic data" decision):

```
combined_schedule (train_no + station_no)
        ⋈ combined_delay (train_no + station_no + date)
        ⋈ train_details (train_no → priority class)
        ⋈ station_full_names (station code → zone)
        ⋈ reconciled scraped tracking data (train_no + approx timestamp)
        ⋈ OSM-derived section attributes (station-pair → line type, electrified, congestion proxy)
        ⋈ TSR/weather records (section + date → active restrictions/conditions)
```

**Output of Stage 4:** one wide, per-(train, station, date) table — this is the master training table.

---

## STAGE 5 — FEATURE ENGINEERING (master table → model-ready features)

This is where the full feature list (Part 5 of the master plan) gets computed from the joined table:
- Direct columns (delay, distance, priority class, zone) pulled straight from the join
- Derived/rolling features computed here: `section_avg_delay_30d/90d/365d`, `delay_trend_last_3_points`, `elapsed_journey_pct`, cyclical time encodings, `data_confidence_score` (from the source-agreement score)
- **Precedence-inference features** (see Stage 6 below) are joined in at this point too, once that separate pipeline produces them

**Output of Stage 5:** the final feature table — this is what actually feeds the model. Two versions of this table are maintained:
- **Model A feature table** — everything except precedence-inference columns
- **Model B feature table** — Model A's table + precedence-inference columns

---

## STAGE 6 — PRECEDENCE-INFERENCE PIPELINE (a parallel, separate flow that feeds back into Stage 5)

This runs independently, on its own weekly cadence (per Part 3/Part 9):

```
Reconciled scraped tracking data (from Stage 3)
        + train_details (priority class)
        + OSM section/track data (from Stage 3)
        ↓
Precedence-inference algorithm:
  1. Compute delay_picked_up per train per section
  2. Baseline against that train's own historical pattern
  3. Systemic-cause filter (check if ALL trains in section were affected)
  4. Cross-reference priority of nearby trains
  5. Require repetition (6+/10 crossings) before trusting the label
  6. Platform-number deviation as a corroborating signal
        ↓
Output: confidence-scored precedence events
  (train_pair, section, date, confidence_score)
```

**Output of Stage 6:** a table of inferred precedence events with confidence scores → **this becomes an INPUT back into Stage 5**, aggregated into features like `precedence_risk_score_next_section` and `historical_precedence_rate_vs_known_priority_trains`.

**Validation branch (not part of the automated pipeline, human-in-the-loop):** a sample of top-confidence events from this output is manually spot-checked against enthusiast forums/news/RTI records (Part 3) — this doesn't feed back into the pipeline automatically, it's a periodic manual QA step on the methodology itself.

---

## STAGE 7 — MODEL TRAINING (feature table → trained model artifact)

**Input:** the Stage 5 feature tables (Model A and Model B versions), split by time (train on older data, validate/test on more recent data — never randomly shuffled, since this is time-series-like data and random splitting would leak future information).

**Process** (owned by the ML team member, per your last instruction — noted here only for pipeline completeness). *(Note: the numbered layers below refer to the model's own internal architecture from Part 6 of the master plan — "Model-Stage" — not this document's Stage 1–11 pipeline numbering.)*
1. Baseline layer (Model-Stage 1) — pure arithmetic, no training needed
2. Tree-ensemble layer (Model-Stage 2) — Random Forest / XGBoost / Extra Trees trained on the residual (actual − baseline)
3. Uncertainty layer (Model-Stage 4) — quantile objective or inter-tree variance

**Output of Stage 7:** a trained model artifact (e.g. a serialized `.pkl`/`.json` model file) for Model A and, separately, for Model B — these are the things that get deployed.

---

## STAGE 8 — MODEL SERVING (trained model + live request → a prediction)

**Input at request time:**
- The trained model artifact (from Stage 7, loaded once at service startup)
- The **current state** of the specific train being queried — pulled fresh at request time: latest scraped position/delay (Stage 3 output, or in production, live CRIS data), current time, which section it's approaching

**Process:**
1. Compute the same features (this document's Stage 5 logic) for this one train's *current* situation
2. Run through the baseline layer (Model-Stage 1) → the tree-ensemble model (Model-Stage 2) → the uncertainty layer (Model-Stage 4)
3. Combine into: `{eta, confidence_interval_lower, confidence_interval_upper, delay_reason (from SHAP/feature importance)}`

**Output of Stage 8:** a JSON prediction object — this is what the API returns.

---

## STAGE 9 — API LAYER (prediction → structured response)

**Input:** Stage 8's prediction object.
**Process:** FastAPI endpoints wrap this into defined contracts:
- `/predict?train_no=X` → returns current ETA + CI
- `/explain?train_no=X` → returns the "why" (top contributing features)
- `/replay?train_no=X&date=Y` → returns a full historical journey replayed as a time series of positions/ETAs (for the live-replay demo mode)

**Output of Stage 9:** HTTP JSON responses — this becomes the **input to the frontend**.

---

## STAGE 10 — FRONTEND / DASHBOARD (API response → what the user sees)

**Inputs consumed here:**
- `/predict` and `/explain` responses → ETA display, confidence band, "why" text panel
- `/replay` response (a sequence of positions over simulated time) + **OSM track geometry (Stage 3 output)** → drives the **time-based polyline-snapping visualization** (Part 4): the replay gives the time-progress ratio, OSM gives the coordinate path to snap that ratio onto
- Manual "what-if" mode: user input (train + scenario) → sent as a request to `/predict` → same response cycle as above

**Output of Stage 10:** the rendered dashboard — map view + table/timeline view, both part of the final prototype — this is the **final human-facing output** of the whole pipeline, but it's not the end of the data flow (see Stage 11).

---

## STAGE 11 — FEEDBACK LOOP (actual outcomes become future training input)

This is what makes the system "continuously adapt" per the SIH problem statement, not a one-time trained model:

```
Once a train actually arrives at a station:
  real arrival time (from scraped tracking data / future CRIS feed)
        ↓
  compared against what was predicted earlier
        ↓
  written back into combined_delay-equivalent storage as a NEW labeled record
        ↓
  becomes part of the training data for the NEXT retraining cycle (Stage 7, rerun nightly/weekly)
```

**This closes the loop:** Stage 11's output is literally new rows feeding back into Stage 1/Stage 4 territory (it's new historical delay data), which flows through Stages 3→4→5→7 again on the next scheduled retrain.

---

## THE ONE SWAP POINT FOR REAL CRIS/ISRO DATA (production transition)

Everything above is architected so that **only Stage 1 and part of Stage 3 change** when real CRIS/ISRO access is granted:

| Stage | Prototype (now) | Production (with CRIS access) |
|---|---|---|
| 1f (source) | Scraped NTES/app tracking, polled every 10-15 min | Direct CRIS/ISRO RTIS feed, continuous |
| 3 (reconciliation) | Multi-source scrape reconciliation | Simpler — CRIS is authoritative, less reconciliation needed |
| Stage 10 map visualization | Time-interpolated polyline snapping (approximation) | True continuous GPS position (no interpolation needed) |
| Everything else (Stages 4-9, 11) | **Unchanged** | **Unchanged** |

This is the practical payoff of designing the pipeline with a clean source-abstraction boundary at Stage 1 — the scraping/interpolation work isn't throwaway, it's a placeholder that plugs into the exact same downstream architecture you'd need anyway.

---

## One-Page Summary Diagram

```
SOURCES                 CLEAN/TRANSFORM         JOIN & FEATURES        MODEL              SERVE/CONSUME
────────                ───────────────         ───────────────        ─────              ─────────────
schedule.csv ──┐
delay.csv ─────┤        per-source              master joined      Stage1 baseline    /predict ──► Frontend
train_details ─┼──►     cleaning/         ──►   table  ──►         Stage2 RF/XGB/ET ──►/explain ──► dashboard
station_names ─┤        parsing                 (Stage 4)          Stage4 CI          /replay ──►  (map+table)
scraped track ─┤                                     ▲                  │                              │
OSM geometry ──┘                                     │                  ▼                              │
                                              precedence-inference   trained model                      │
                                              pipeline (Stage 6,     artifact (Stage 7)                 │
                                              parallel, weekly)                                         │
                                                                                                         ▼
                                                                                          actual arrival outcome
                                                                                          ──► feeds back into
                                                                                              delay.csv-equivalent
                                                                                              storage (Stage 11)
                                                                                              ──► next retrain cycle
```
