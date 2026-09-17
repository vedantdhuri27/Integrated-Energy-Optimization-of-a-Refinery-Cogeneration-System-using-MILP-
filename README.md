# Integrated-Energy-Optimization-of-a-Refinery-Cogeneration-System-using-MILP
# Refinery Cogeneration Dispatch Optimizer (MILP)

A Mixed-Integer Linear Programming (MILP) model that optimizes the hourly dispatch of a refinery steam/power cogeneration system — boiler unit-commitment, turbine-vs-letdown steam routing, byproduct fuel-gas substitution, and battery scheduling — under time-varying electricity and fuel prices.

Solved in MATLAB using `intlinprog`. Achieves an **8% cost reduction** versus a fixed-schedule baseline policy on a representative 24-hour refinery utility profile.

---

## What this models

A refinery utility system typically looks like this:

```
Boilers → HP steam header → [Turbine 1 | Letdown valve] → MP steam header → [Turbine 2 | Letdown valve] → LP steam header
                ↑                                                                                                    
        Refinery fuel gas (byproduct) + purchased natural gas
```

At each of the three pressure levels (HP/MP/LP), process units draw steam. Whenever steam has to drop from one pressure level to the next to meet downstream demand, that pressure drop can either be wasted through a **letdown valve** or used to generate electricity through a **turbine** — the core economic trade-off in cogeneration.

The model also captures:
- **Boiler unit-commitment**: boilers have a minimum stable load once switched on — this requires binary on/off decision variables (the reason this is a MILP, not a plain LP)
- **Refinery fuel gas (RFG)**: a byproduct of upstream cracking/reforming units, available at no direct cost but capacity-limited each hour — unused RFG must be flared (a penalized outcome), and any shortfall is covered by purchased natural gas
- **Grid interaction**: the plant can buy or sell electricity against an hourly Time-of-Day (ToD) tariff
- **Battery storage**: charges/discharges across the day, returning to its starting state-of-charge by the end of the horizon

## Why MILP (not LP or MINLP)

- **Not plain LP** — boiler on/off and minimum-load logic are genuinely discrete decisions
- **Not MINLP** — this model treats each hour as a static balance snapshot (steam-in = steam-out per header) rather than modeling continuous-time pressure/flow dynamics, which is what would introduce nonlinear valve and turbine curves. That's the deliberate scope boundary: this is an **hourly economic dispatch** model, not a dynamic control (EMPC) model.

## Repository contents

| File | Description |
|---|---|
| `refinery_cogen_milp.m` | Main MATLAB script — builds and solves the MILP, prints cost breakdown, plots results |
| `refinery_cogen_parameters.xlsx` | Parameter workbook — every input value with its source (see below) |
| `README.md` | This file |

## Data sourcing

Every parameter in this model is labeled as one of:

- **Grounded** — sourced from real published data (steam table enthalpies, typical refinery header pressure ranges, Indian ToD tariff regulations, IEX day-ahead market prices, standard turbine steam-rate ranges, boiler efficiency ranges)
- **Derived** — computed from grounded values via a stated formula (e.g. fuel energy per ton of steam = steam enthalpy ÷ boiler efficiency; NG price per kWh = price per kg ÷ calorific value)
- **Representative** — sized to be internally consistent with the grounded values, but not sourced from any specific real plant (e.g. exact hourly demand curve shape, battery capacity)

See the `Parameters` and `Notes & Sources` sheets in `refinery_cogen_parameters.xlsx` for the full breakdown, cell by cell.

**This model is not calibrated to, or validated against, any specific named refinery**, and its results should not be compared numerically against savings figures reported in other published studies (different plant scale, currency, and fuel mix make such comparisons invalid) — only the broad ballpark is a reasonable sanity check.

## How to run

1. Open `refinery_cogen_milp.m` in MATLAB (requires the Optimization Toolbox for `intlinprog`)
2. Run the script — it will:
   - Build the 24-hour demand, tariff, and fuel-availability vectors
   - Solve the MILP
   - Print a cost breakdown (fuel, grid purchase/sale, flaring penalty) to the console
   - Plot boiler output, fuel mix, electricity supply mix, and battery SOC over the day
   - Compute and print the naive-baseline comparison and % savings

No external solver is required beyond MATLAB's built-in `intlinprog`.

## Model structure

**Decision variables** (per hour): boiler steam output ×2 (continuous) + boiler on/off ×2 (binary), turbine steam flow ×2, letdown valve flow ×2, purchased natural gas, refinery fuel gas used, refinery fuel gas flared, grid import, grid export, battery charge, battery discharge — plus a battery state-of-charge variable per hour boundary.

**Objective**: minimize total daily cost = purchased fuel cost + flaring penalty + net grid electricity cost (import cost − export revenue).

**Key constraints**:
- Steam mass balance at each of the three headers (HP/MP/LP)
- Boiler capacity and minimum-load logic (unit commitment)
- Fuel balance linking steam output to fuel consumption
- Refinery fuel gas balance (used + flared = available) and a maximum blend-fraction cap
- Electricity balance (turbine generation + grid import + battery discharge = demand + grid export + battery charge)
- Battery state-of-charge recursion, with start-of-day = end-of-day SOC

## Validation approach

- **Baseline vs. optimized**: a simple fixed-schedule policy (constant boiler load, letdown-only routing, no price-aware fuel or grid decisions) is computed as a reference point; the MILP result is compared against it
- Formulation independently re-solved in Python (`scipy.optimize.milp` / HiGHS) to confirm the MATLAB and constraint-matrix logic agree

## Limitations / possible extensions

- Static hourly snapshots only — no intra-hour dynamics, ramp-rate limits, or startup/shutdown costs
- Single representative day, not a multi-day or seasonal analysis
- Turbine steam-rate assumed uniform across both cascade stages (HP→MP and MP→LP) due to lack of separately-sourced stage-specific data
- A natural extension would be a two-layer structure: this MILP as the hourly dispatch layer, with a faster Economic Model Predictive Control (EMPC) layer beneath it handling real dynamic response — out of scope here by design

## Disclaimer

This is an independent academic/portfolio project. It does not represent, and is not affiliated with, any specific refinery or company. All representative parameters are clearly labeled as such and should not be presented as real operational data.
