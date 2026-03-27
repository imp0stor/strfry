# Strfry 100M Ingestion Ramp Runbook (Aggressive + Safe)

Canonical strfry path: `/home/owner/strangesignal/forks/strfry-compressed`  
Canonical commit baseline: `6934c65`

## Goals
- Reach milestones with guardrails: **10M -> 25M -> 50M -> 100M** events.
- Preserve canonical path and avoid regressions.
- Drive throughput with bounded risk: source scoring, parallel sync waves, duplicate suppression, import tuning, storage/index checks.

## Immediate actions implemented
1. **Source expansion + quality scoring**
   - File: `ops/ramp-sources.txt`
   - Command: `scripts/ramp-100m.sh score-sources`
   - Output: `ops/ramp-state/source-scores.tsv`

2. **Bounded parallel sync waves**
   - Command: `WAVE_PARALLEL=3 scripts/ramp-100m.sh sync-wave`
   - Scale gradually: 3 -> 5 -> 8 only after KPI gates pass.

3. **Duplicate suppression heuristics**
   - Prefer strfry-native dedupe on sync/import.
   - If pre-importing JSONL from dumps, pre-dedupe by event id before `strfry import`:
     - `jq -c . raw.jsonl | awk -F'"id":"' 'NF>1{split($2,a,"\""); if(!seen[a[1]]++) print $0}' > deduped.jsonl`

4. **Import pipeline tuning**
   - High-trust dumps: `strfry import --no-verify` (faster)
   - Unknown dumps: `strfry import` (safe)
   - Use split+parallel ingestion only from trusted data sources.

5. **Storage/index checks**
   - `df -h`
   - `du -sh strfry-db`
   - Alert thresholds:
     - warn >= 75% disk
     - block >= 85% disk

6. **Reliability guardrails**
   - Rollback if either:
     - connect errors > 20/hour
     - dup rate > 85% sustained for 2 hours with low unique/min
   - Freeze wave promotions for 60 minutes after rollback.

## Hourly KPI command
Run every hour:

```bash
scripts/ramp-100m.sh kpi
```

KPI schema:
- total
- delta/hr
- unique/min
- dup rate
- lag
- connect errors

CSV log: `ops/ramp-state/kpi-hourly.csv`

## Milestones + ETA bands

```bash
scripts/ramp-100m.sh milestones
```

ETA bands are computed from recent hourly delta and emitted as low/base/high.

## Promotion commands

```bash
scripts/ramp-100m.sh promote phase-10m
scripts/ramp-100m.sh promote phase-25m
scripts/ramp-100m.sh promote phase-50m
scripts/ramp-100m.sh promote phase-100m
```

## Rollback commands

```bash
scripts/ramp-100m.sh rollback phase-10m
scripts/ramp-100m.sh rollback phase-25m
scripts/ramp-100m.sh rollback phase-50m
scripts/ramp-100m.sh rollback phase-100m
```

## Phased ramp policy
- **Phase 1 (to 10M):** WAVE_PARALLEL=3, top scored relays only.
- **Phase 2 (10M-25M):** WAVE_PARALLEL=5, add next source tier.
- **Phase 3 (25M-50M):** WAVE_PARALLEL=8 if connect errors stable.
- **Phase 4 (50M-100M):** hold parallelism, optimize quality and dedupe, avoid wasteful fan-out.

## Safety notes
- Do not change non-canonical strfry trees during ramp.
- Snapshot `strfry.conf` before every phase promotion.
- Gate every promotion on KPI, not optimism.
