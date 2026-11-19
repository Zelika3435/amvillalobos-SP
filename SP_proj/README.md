# SP_proj — GAMA Benguet corridor

GAMA Eclipse project for the current **multi-crop proof of concept**. It runs cabbage, carrot, potato, and chayote together. It is not a cabbage-only model, and it is not required to implement every later item in `docs/PLANNING.md`.

## Requirements

- [GAMA Platform](https://gama-platform.org/) 1.9+ (installed under `C:\Program Files\Gama` on this machine)
- Road network is `data/osm/network_cleaned_utm.shp` (named arteries plus the links that join the seven farms and BAPTC)
- Display-only DEM: `includes/corridor_dem_utm.asc` (rebuild with `python scripts/build_corridor_dem.py`)

## Open the project

1. Start GAMA.
2. **File → Open…** (or Import existing project) and select this `SP_proj` folder.
3. Expand `models/`.

## Experiments

| Experiment | Model | Purpose |
|------------|-------|---------|
| `map_view` | `Corridor_World.gaml` | GIS sanity check: DEM backdrop, roads, farm clusters, markets |
| `bau_core_crops` | `Corridor_BAU.gaml` | **Proof of concept to run:** four crops, trucks drive the road graph |
| `bau_cabbage` | `Corridor_BAU.gaml` | Legacy alias of the same four-crop model |
| `present_flow` | `Corridor_Present.gaml` | Older import of the same drive. Use `bau_core_crops` |

### Map check

1. Open `models/Corridor_World.gaml`.
2. Run experiment **map_view**.
3. Confirm terrain under the roads, Halsema / Kennon / Marcos / Naguilian colors, and BAPTC (yellow) vs LTVTP/Hangar labels.
4. Elevation is **display only** — it does not change routing or BAU rates.

### Presentation demo (visible movement)

1. Open `models/Corridor_BAU.gaml`.
2. Run experiment **bau_core_crops**.
3. Trucks drive the cleaned road graph: empty from BAPTC to a farm, then loaded back. A blue truck is outbound. A crop-colored truck is loaded, and the line is its route.
4. Tune **Truck speed (m per hour)** if trips feel too fast or slow.

### Multi-crop proof of concept

1. Open `models/Corridor_BAU.gaml`.
2. Run experiment **bau_core_crops** (not a separate cabbage model).
3. Monitors show per-crop asks; charts show delivered / retail / spoiled; seasonal harvest prior (potato Mar–Jun, cabbage Jul–Oct, carrot Nov–Feb; chayote year-round).
4. Parameter `trust_enabled` toggles the trust-on vs trust-off ablation.
5. Daily rows append to `../results/bau_crops_daily.csv`.

### Compare to frozen dumps

```text
python scripts/compare_bau_crops.py
```

The script compares the four crops. It does not mean this proof of concept is already calibrated.

## Headless smoke test (optional)

From `C:\Program Files\Gama\headless`:

```text
gama-headless.bat -m 2048m "<repo>\SP_proj\headless\bau_crops_smoke.xml" "<repo>\SP_proj\headless\out_crops"
```

Writes `results/bau_crops_daily.csv`.

## Rebuild maps (optional)

From the repo root (close GAMA first if `includes/` is locked):

```text
python scripts/rebuild_maps.py
python scripts/build_corridor_dem.py
python scripts/sync_includes_from_data.py
python scripts/validate_maps.py
```

## Parameters

Runtime rates live in `models/Corridor_BAU.gaml`. `models/params.gaml` mirrors those stubs and is not imported. Plan IDs are in `docs/PLAN-LIBRARIES.md`.

## Out of scope for this proof of concept

LLM plan selection, the MLP surrogate, disaster shocks (Ompong), and the LTVTP floor. Multi-crop is in scope: cabbage, carrot, potato, and chayote run together. Gaps against the full plan in `docs/PLANNING.md` are expected at this stage.
