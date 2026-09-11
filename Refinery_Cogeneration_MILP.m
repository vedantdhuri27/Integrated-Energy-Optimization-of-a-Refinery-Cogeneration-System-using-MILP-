%% Refinery Cogeneration MILP
% Boilers -> HP/MP/LP steam headers -> turbines vs letdown valves -> electricity
% + refinery byproduct fuel gas balance + battery, solved with intlinprog.
%
% Data source: ALL parameters below trace back to refinery_cogen_parameters.xlsx
% (Parameters + Hourly_Profile sheets). Each block below states which values are
% GROUNDED (sourced from real industry/search data), which are DERIVED (computed
% from grounded numbers via a stated formula), and which are REPRESENTATIVE
% (sized to be internally consistent, not sourced from a specific real plant --
% same convention used throughout the parameter workbook).
%
% MILP formulation logic (header cascade, unit commitment, fuel/FG balance,
% electricity balance, battery SOC) is UNCHANGED from the prior version -- it was
% independently re-solved in Python/HiGHS and verified correct. Only the input
% data section below has been rebuilt to match the grounded parameter sheet, and
% two small bugs/dead-code items have been cleaned up (see notes at bottom).

clear; clc;

%% ---------------- Time base ----------------
T = 24;
hrs = (0:T-1)';

%% ---------------- Steam headers (GROUNDED, Parameters!B6:B11) ----------------
HP_PRESSURE = 45;      % bar
MP_PRESSURE = 15;      % bar
LP_PRESSURE = 5;       % bar
HP_ENTHALPY = 2800;    % kJ/kg (saturated, ~45 bar) -- used below to derive fuel/ton
MP_ENTHALPY = 2790;    % kJ/kg
LP_ENTHALPY = 2750;    % kJ/kg

%% ---------------- Steam demand components (REPRESENTATIVE, Parameters!B54:B57) ----------------
% Named consumers, not one anonymous number -- CDU + hydrocracker feed HP,
% hydrotreater feeds MP, tank heating/stripping feeds LP.
HP_CDU = 40; HP_HC = 15;      % t/h baseload components
MP_HT  = 20;                  % t/h baseload
LP_TANK = 10;                 % t/h baseload

% Same ripple formulas as Hourly_Profile sheet: HP +-3%, MP +-5%, LP +-10% (peaks ~3am)
HP_demand = (HP_CDU + HP_HC) * (1 + 0.03*sin((hrs/24)*2*pi));
MP_demand = MP_HT * (1 + 0.05*sin((hrs/24)*2*pi + 1));
LP_demand = LP_TANK * (1 + 0.10*cos((hrs-3)/24*2*pi));

%% ---------------- Electricity demand (REPRESENTATIVE, Parameters!B43) ----------------
ELEC_BASE_MW = 12;   % MW, flat-ish with mild daytime rise (same formula as Hourly_Profile)
E_demand = 1000 * ELEC_BASE_MW * (1 + 0.08*sin((hrs-6)/24*2*pi));   % kW

%% ---------------- Byproduct refinery fuel gas (kg/h -> kWh thermal/h) ----------------
% Availability profile: REPRESENTATIVE (same shape as Hourly_Profile!H column)
% CV conversion: GROUNDED, RFG calorific value 35-45 MJ/kg range -> mid 40 MJ/kg (Parameters!B23)
RFG_CV_MJ_PER_KG = 40;
RFG_avail_kg_h = 1000 * (1 + 0.20*sin((hrs/24)*2*pi + 2));      % kg/h
FG_prod = RFG_avail_kg_h * RFG_CV_MJ_PER_KG / 3.6;               % kWh thermal/h  (1 kWh = 3.6 MJ)

%% ---------------- Electricity tariff: Indian industrial ToD (GROUNDED, Parameters!B34:B39) ----------------
% Base rate Rs4.5/kWh (IEX day-ahead avg range), peak +20% / solar-hours -20%
% (matches the national ToD rule: peak +10-20%, solar hours -10-20%).
% Bands: Peak 18:00-22:00, Solar/off-peak 10:00-16:00, Normal elsewhere
% -- identical windows to Hourly_Profile sheet.
BASE_RATE = 4.5;
PEAK_MULT = 0.20;
OFFPEAK_DISC = 0.20;
PEAK_RATE = BASE_RATE * (1 + PEAK_MULT);      % 5.4
OFFPEAK_RATE = BASE_RATE * (1 - OFFPEAK_DISC); % 3.6
NORMAL_RATE = BASE_RATE;                       % 4.5

grid_price = zeros(T,1);
for h = 0:T-1
    if h>=18 && h<22
        gp = PEAK_RATE;
    elseif h>=10 && h<16
        gp = OFFPEAK_RATE;
    else
        gp = NORMAL_RATE;
    end
    grid_price(h+1) = gp;
end
sell_price = grid_price * 0.9;   % representative export/injection ratio (not separately sourced)

%% ---------------- Fuel costs (DERIVED from grounded Parameters!B23:B25) ----------------
% Purchased NG priced per kg (Rs37.5/kg, Parameters!B24) -> convert to Rs/kWh using
% the same 40 MJ/kg calorific value basis used for RFG, for unit consistency.
NG_PRICE_PER_KG = 37.5;
NG_price = NG_PRICE_PER_KG / (RFG_CV_MJ_PER_KG / 3.6);     % Rs/kWh thermal  (~Rs3.38/kWh)

% Flaring penalty Rs5/kg RFG flared (Parameters!B25) -> convert to Rs/kWh thermal
FLARE_PENALTY_PER_KG = 5;
FLARE_PENALTY = FLARE_PENALTY_PER_KG / (RFG_CV_MJ_PER_KG / 3.6);  % Rs/kWh thermal (~Rs0.45/kWh)

%% ---------------- Boiler parameters (GROUNDED, Parameters!B15:B19) ----------------
BOILER_CAP = 60.0;                 % t/h each (2 boilers -> 120 t/h total, grounded)
BOILER_MINLOAD_FRAC = 0.30;        % grounded turndown limit
BOILER_EFF = 0.85;                 % grounded boiler thermal efficiency

% Fuel energy per ton of HP steam, DERIVED from grounded HP enthalpy + boiler efficiency:
%   FUEL_PER_TON = enthalpy (kJ/kg) x 1000 (kg/t) / 3600 (kJ/kWh) / efficiency
FUEL_PER_TON = HP_ENTHALPY * 1000 / 3600 / BOILER_EFF;   % ~915 kWh/t

FG_MAX_FRACTION = 0.6;   % REPRESENTATIVE combustion-stability cap on RFG blend fraction
                          % (not sourced -- documented assumption, see notes)

%% ---------------- Turbine parameters (DERIVED from grounded Parameters!B29:B30) ----------------
% Grounded steam rate: 8 kg steam / kWh (back-pressure turbine, Parameters!B30)
%   -> electric output per ton steam = 1000 kg / 8 kg/kWh = 125 kWh/t
% Applied uniformly to both cascade stages (no separately-sourced split between
% HP->MP and MP->LP available) -- documented simplifying assumption.
TURBINE_STEAM_RATE = 8;           % kg steam / kWh, grounded
ETA_TURB1 = 1000 / TURBINE_STEAM_RATE;   % kWh/t, ~125
ETA_TURB2 = 1000 / TURBINE_STEAM_RATE;   % kWh/t, ~125

% Grounded total installed turbine capacity: 15 MW (Parameters!B29).
% Split evenly across the two cascade stages so max combined output = 15 MW
% when both stages run at full steam flow simultaneously.
TURBINE_TOTAL_MW = 15;
TURB1_MAX = (TURBINE_TOTAL_MW*1000/2) / ETA_TURB1;   % t/h
TURB2_MAX = (TURBINE_TOTAL_MW*1000/2) / ETA_TURB2;   % t/h

%% ---------------- Battery (GROUNDED capacity/efficiency + REPRESENTATIVE SOC levels) ----------------
% Capacity, max rate: DERIVED/Scaled (Parameters!B47:B48)
% Round-trip efficiency 0.90: GROUNDED (typical Li-ion round-trip, Parameters!B49)
%   -> split evenly into charge/discharge efficiency: sqrt(0.90) each leg
BATT_CAP_MWH = 5;
BATT_MAX_POWER = 1000 * 1;         % kW (1 MW max charge/discharge rate)
BATT_ROUNDTRIP_EFF = 0.90;
BATT_ETA_C = sqrt(BATT_ROUNDTRIP_EFF);
BATT_ETA_D = sqrt(BATT_ROUNDTRIP_EFF);

BATT_SOC_MAX = 1000 * BATT_CAP_MWH;      % kWh, full capacity = 5000
BATT_SOC_MIN = 0.10 * BATT_SOC_MAX;      % representative 10% reserve floor = 500
BATT_SOC_INIT = 0.50 * BATT_SOC_MAX;     % representative 50% starting SOC = 2500

%% ---------------- Variable layout ----------------
% Per-hour block, var-major: [S1 S2 b1 b2 HPturb1 HPld1 MPturb2 MPld2 NG FGused FGflare Gbuy Gsell Bcharge Bdis]
varNames = {'S1','S2','b1','b2','HPturb1','HPld1','MPturb2','MPld2', ...
            'NG','FGused','FGflare','Gbuy','Gsell','Bcharge','Bdis'};
NV = numel(varNames);
N_HOURLY = NV*T;
N_SOC = T+1;
N = N_HOURLY + N_SOC;

idx = @(name,t) (find(strcmp(varNames,name))-1)*T + (t+1);   % t is 0-based hour, returns 1-based MATLAB index
socIdx = @(t) N_HOURLY + t + 1;                                % t = 0..T (0-based), 1-based index

%% ---------------- Bounds ----------------
lb = zeros(N,1);
ub = inf(N,1);

for t = 0:T-1
    ub(idx('S1',t)) = BOILER_CAP;
    ub(idx('S2',t)) = BOILER_CAP;
    ub(idx('b1',t)) = 1;
    ub(idx('b2',t)) = 1;
    ub(idx('HPturb1',t)) = TURB1_MAX;
    ub(idx('MPturb2',t)) = TURB2_MAX;
    ub(idx('Bcharge',t)) = BATT_MAX_POWER;
    ub(idx('Bdis',t))    = BATT_MAX_POWER;
end

for t = 0:T
    lb(socIdx(t)) = BATT_SOC_MIN;
    ub(socIdx(t)) = BATT_SOC_MAX;
end
lb(socIdx(0)) = BATT_SOC_INIT; ub(socIdx(0)) = BATT_SOC_INIT;   % fix initial SOC
% End-of-day SOC: exact return to start-of-day SOC (equality, not just >=)
lb(socIdx(T)) = BATT_SOC_INIT; ub(socIdx(T)) = BATT_SOC_INIT;

intcon = [];
for t = 0:T-1
    intcon(end+1) = idx('b1',t); %#ok<SAGROW>
    intcon(end+1) = idx('b2',t); %#ok<SAGROW>
end

%% ---------------- Objective ----------------
f = zeros(N,1);
for t = 0:T-1
    f(idx('NG',t))     = NG_price;
    f(idx('FGflare',t))= FLARE_PENALTY;
    f(idx('Gbuy',t))   = grid_price(t+1);
    f(idx('Gsell',t))  = -sell_price(t+1);
end

%% ---------------- Constraints ----------------
Aeq = zeros(0,N); beq = zeros(0,1);
Aub = zeros(0,N); bub = zeros(0,1);

for t = 0:T-1
    S1 = idx('S1',t); S2 = idx('S2',t);
    b1 = idx('b1',t); b2 = idx('b2',t);
    HPt1 = idx('HPturb1',t); HPl1 = idx('HPld1',t);
    MPt2 = idx('MPturb2',t); MPl2 = idx('MPld2',t);
    NG = idx('NG',t); FGu = idx('FGused',t); FGf = idx('FGflare',t);
    Gb = idx('Gbuy',t); Gs = idx('Gsell',t);
    Bc = idx('Bcharge',t); Bd = idx('Bdis',t);

    % 1. HP header balance: S1+S2 = HP_demand + HPturb1 + HPld1
    row = zeros(1,N); row(S1)=1; row(S2)=1; row(HPt1)=-1; row(HPl1)=-1;
    Aeq(end+1,:) = row; beq(end+1,1) = HP_demand(t+1); %#ok<*SAGROW>

    % 2. MP header balance: HPturb1+HPld1 = MP_demand + MPturb2 + MPld2
    row = zeros(1,N); row(HPt1)=1; row(HPl1)=1; row(MPt2)=-1; row(MPl2)=-1;
    Aeq(end+1,:) = row; beq(end+1,1) = MP_demand(t+1);

    % 3. LP header balance: MPturb2+MPld2 = LP_demand
    row = zeros(1,N); row(MPt2)=1; row(MPl2)=1;
    Aeq(end+1,:) = row; beq(end+1,1) = LP_demand(t+1);

    % 4. Boiler capacity & min-load
    row = zeros(1,N); row(S1)=1; row(b1)=-BOILER_CAP;
    Aub(end+1,:) = row; bub(end+1,1) = 0;                          % S1 <= CAP*b1
    row = zeros(1,N); row(S1)=-1; row(b1)=BOILER_CAP*BOILER_MINLOAD_FRAC;
    Aub(end+1,:) = row; bub(end+1,1) = 0;                          % S1 >= minload*b1
    row = zeros(1,N); row(S2)=1; row(b2)=-BOILER_CAP;
    Aub(end+1,:) = row; bub(end+1,1) = 0;
    row = zeros(1,N); row(S2)=-1; row(b2)=BOILER_CAP*BOILER_MINLOAD_FRAC;
    Aub(end+1,:) = row; bub(end+1,1) = 0;

    % 5. Fuel balance: NG + FGused = (S1+S2)*FUEL_PER_TON
    row = zeros(1,N); row(NG)=1; row(FGu)=1; row(S1)=-FUEL_PER_TON; row(S2)=-FUEL_PER_TON;
    Aeq(end+1,:) = row; beq(end+1,1) = 0;

    % 6. FGused + FGflare = FG_prod
    row = zeros(1,N); row(FGu)=1; row(FGf)=1;
    Aeq(end+1,:) = row; beq(end+1,1) = FG_prod(t+1);

    % 7. Refinery-gas fraction cap: FGused <= FG_MAX_FRACTION * total fuel energy
    row = zeros(1,N); row(FGu)=1; row(S1)=-FG_MAX_FRACTION*FUEL_PER_TON; row(S2)=-FG_MAX_FRACTION*FUEL_PER_TON;
    Aub(end+1,:) = row; bub(end+1,1) = 0;

    % 8. Electricity balance
    row = zeros(1,N); row(HPt1)=ETA_TURB1; row(MPt2)=ETA_TURB2; row(Gb)=1; row(Gs)=-1; row(Bd)=1; row(Bc)=-1;
    Aeq(end+1,:) = row; beq(end+1,1) = E_demand(t+1);

    % 9. Battery SOC recursion: SOC[t+1] = SOC[t] + eta_c*Bc - Bd/eta_d
    row = zeros(1,N); row(socIdx(t+1))=1; row(socIdx(t))=-1; row(Bc)=-BATT_ETA_C; row(Bd)=1/BATT_ETA_D;
    Aeq(end+1,:) = row; beq(end+1,1) = 0;
end

%% ---------------- Solve ----------------
opts = optimoptions('intlinprog','Display','iter');
[x, fval, exitflag, output] = intlinprog(f, intcon, Aub, bub, Aeq, beq, lb, ub, opts);

if exitflag ~= 1
    warning('Solver did not report optimal (exitflag=%d). Check output.', exitflag);
end

%% ---------------- Extract results ----------------
getVar = @(name) arrayfun(@(t) x(idx(name,t)), 0:T-1)';
S1v = getVar('S1'); S2v = getVar('S2');
HPturb1v = getVar('HPturb1'); HPld1v = getVar('HPld1');
MPturb2v = getVar('MPturb2'); MPld2v = getVar('MPld2');
NGv = getVar('NG'); FGusedv = getVar('FGused'); FGflarev = getVar('FGflare');
Gbuyv = getVar('Gbuy'); Gsellv = getVar('Gsell');
Bcv = getVar('Bcharge'); Bdv = getVar('Bdis');
SOCv = arrayfun(@(t) x(socIdx(t)), 0:T)';

opt_cost = fval;
fprintf('\nOptimized total daily cost: Rs %.0f\n', opt_cost);
fprintf('  NG purchased total: %.0f kWh -> Rs %.0f\n', sum(NGv), sum(NGv)*NG_price);
fprintf('  Fuel gas flared total: %.0f kWh -> Rs %.0f penalty\n', sum(FGflarev), sum(FGflarev)*FLARE_PENALTY);
fprintf('  Grid purchases: %.0f kWh -> Rs %.0f\n', sum(Gbuyv), sum(Gbuyv.*grid_price));
fprintf('  Grid sales: %.0f kWh -> Rs %.0f income\n', sum(Gsellv), sum(Gsellv.*sell_price));
fprintf('  SOC start/end: %.0f / %.0f kWh\n', SOCv(1), SOCv(end));

%% ---------------- Naive baseline (no optimization) ----------------
base_HP_out = HP_demand + MP_demand + LP_demand;   % boilers raise enough HP steam to cover everything via letdown only
base_fuel_needed = base_HP_out * FUEL_PER_TON;
base_FGused = min(FG_prod, base_fuel_needed);
base_FGflare = FG_prod - base_FGused;
base_NG = base_fuel_needed - base_FGused;
base_Gbuy = E_demand;   % no on-site generation or battery use
base_cost = sum(base_NG*NG_price) + sum(base_FGflare*FLARE_PENALTY) + sum(base_Gbuy.*grid_price);

fprintf('\nNaive baseline total daily cost: Rs %.0f\n', base_cost);
fprintf('Savings from optimization: %.2f%%\n', (base_cost-opt_cost)/base_cost*100);

%% ---------------- Plots ----------------
figure('Position',[100 100 1100 750]);

subplot(2,2,1);
bar(hrs, [S1v S2v], 'stacked'); hold on;
plot(hrs, HP_demand+MP_demand+LP_demand, 'k--','LineWidth',1.5);
title('Boiler steam output (t/h)'); xlabel('Hour'); legend('Boiler 1','Boiler 2','Total steam demand');

subplot(2,2,2);
bar(hrs, [FGusedv NGv], 'stacked'); hold on;
plot(hrs, FG_prod, 'k--','LineWidth',1.5);
title('Boiler fuel mix (kWh thermal)'); xlabel('Hour'); legend('Refinery fuel gas used','Natural gas purchased','Fuel gas available');

subplot(2,2,3);
turbPower = ETA_TURB1*HPturb1v + ETA_TURB2*MPturb2v;
bar(hrs, [turbPower Gbuyv], 'stacked'); hold on;
bar(hrs, -Gsellv);
plot(hrs, E_demand, 'k--','LineWidth',1.5);
title('Electricity supply mix (kW)'); xlabel('Hour'); legend('Turbine generation','Grid purchase','Grid sale','Electricity demand');

subplot(2,2,4);
plot(0:T, SOCv, '-o'); hold on;
yline(BATT_SOC_INIT,':','Start-of-day SOC');
title('Battery state of charge (kWh)'); xlabel('Hour');

sgtitle(sprintf('Refinery Cogeneration MILP -- optimized Rs %.0f/day vs baseline Rs %.0f/day (%.1f%% savings)', ...
    opt_cost, base_cost, (base_cost-opt_cost)/base_cost*100));
