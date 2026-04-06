const std = @import("std");
const transformer = @import("transformer.zig");

// Cable Structure

const Cable = struct {
    name: []const u8,
    area_mm2: f64,
    r_ohm_per_km: f64,
    x_ohm_per_km: f64,
    ampacity_a: f64,
};

// Cable Table (3 Phase, copper conductor, XLPE insulation, 600V rated)
// !! Add more cables here to have more options to select from
// Resistance and reactance at 90* C conductor temperature / km (from Nexans Canada XLPE cable datasheets)
// Ampacity values for cables in conduit at 30* C ambient, derated per CSA C22.1 Table 2

const cables = [_]Cable{
    .{ .name = "3C 35mm² Cu XLPE", .area_mm2 = 35, .r_ohm_per_km = 0.668, .x_ohm_per_km = 0.100, .ampacity_a = 130.0 },
    .{ .name = "3C 50mm² Cu XLPE", .area_mm2 = 50, .r_ohm_per_km = 0.463, .x_ohm_per_km = 0.095, .ampacity_a = 160.0 },
    .{ .name = "3C 70mm² Cu XLPE", .area_mm2 = 70, .r_ohm_per_km = 0.321, .x_ohm_per_km = 0.090, .ampacity_a = 200.0 },
    .{ .name = "3C 95mm² Cu XLPE", .area_mm2 = 95, .r_ohm_per_km = 0.248, .x_ohm_per_km = 0.087, .ampacity_a = 240.0 },
    .{ .name = "3C 120mm² Cu XLPE", .area_mm2 = 120, .r_ohm_per_km = 0.196, .x_ohm_per_km = 0.085, .ampacity_a = 275.0 },
    .{ .name = "3C 150mm² Cu XLPE", .area_mm2 = 150, .r_ohm_per_km = 0.159, .x_ohm_per_km = 0.083, .ampacity_a = 310.0 },
    .{ .name = "3C 185mm² Cu XLPE", .area_mm2 = 185, .r_ohm_per_km = 0.127, .x_ohm_per_km = 0.082, .ampacity_a = 355.0 },
    .{ .name = "3C 240mm² Cu XLPE", .area_mm2 = 240, .r_ohm_per_km = 0.098, .x_ohm_per_km = 0.080, .ampacity_a = 415.0 },
    .{ .name = "3C 300mm² Cu XLPE", .area_mm2 = 300, .r_ohm_per_km = 0.078, .x_ohm_per_km = 0.079, .ampacity_a = 470.0 },
};

// Output Structure

pub const FeederResult = struct {
    full_load_current_a: f64, // Taken from transformer.fullLoadCurrent
    cable: Cable, // selected cable
    length_m: f64, // feeder run length provided by user
    vd_pct: f64, // calculated voltage drop %
    vd_ok: bool, // true if vd_pct <= VD_LIMIT_PCT
    ampacity_ok: bool, // true if cable ampacity >= full_load_current
};

// Voltage Drop Limit Percentage (Based on CSA C22.1)
const VD_LIMIT_PCT: f64 = 3.0;

// Voltage Drop calculation based on the formula (gives a conservative approx):
// VD% = (√3 × I × L × (R·cosφ + X·sinφ)) / V_LL  × 100

fn voltageDrop(cable: Cable, current_a: f64, length_m: f64, pf: f64, voltage_ll: f64) f64 {
    const length_km = length_m / 1000.0;
    const sin_phi = std.math.sqrt(1.0 - pf * pf);
    const vd = (std.math.sqrt(3.0) * current_a * length_km * (cable.r_ohm_per_km * pf + cable.x_ohm_per_km * sin_phi)) / voltage_ll * 100.0;

    return vd;
}

// Feeder Sizing Function
// Selects on the conditions:
// 1. ampacity >= full_load_current (thermal limit)
// 2. voltage drop % <= 3.0 (power quality limit)

pub fn sizeFeeder(sel: transformer.TransformerSelection, voltage_ll: f64, length_m: f64, pf: f64) !FeederResult {
    const i_fl = transformer.fullLoadCurrent(sel.selected_kva, voltage_ll);

    for (cables) |cable| {
        const ampacity_ok = cable.ampacity_a >= i_fl;
        const vd_pct = voltageDrop(cable, i_fl, length_m, pf, voltage_ll);
        const vd_ok = vd_pct <= VD_LIMIT_PCT;

        if (ampacity_ok and vd_ok) {
            return FeederResult{
                .full_load_current_a = i_fl,
                .ampacity_ok = true,
                .cable = cable,
                .length_m = length_m,
                .vd_ok = true,
                .vd_pct = vd_pct,
            };
        }
    }

    return error.NoSuitableCableFound;
}

// Helper function for report.zig

pub const CableCandidate = struct {
    cable: Cable,
    vd_pct: f64,
    ampacity_ok: bool,
    vd_ok: bool,
};

pub fn allCableCandidates(i_fl: f64, length_m: f64, pf: f64, voltage_ll: f64, allocator: std.mem.Allocator) ![]CableCandidate {
    var candidates = try allocator.alloc(CableCandidate, cables.len);

    for (cables, 0..) |cable, i| {
        const vd_pct = voltageDrop(cable, i_fl, length_m, pf, voltage_ll);
        candidates[i] = CableCandidate{
            .cable = cable,
            .vd_pct = vd_pct,
            .ampacity_ok = cable.ampacity_a >= i_fl,
            .vd_ok = vd_pct <= VD_LIMIT_PCT,
        };
    }

    return candidates;
}
