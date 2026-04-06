const std = @import("std");
const load = @import("load.zig");

// Standard transformer ratings (kVA) (based on suppliers such as Hammond Power, Eaton, etc.)

const standard_ratings_kva = [_]f64{
    45.0,
    75.0,
    122.5,
    150.0,
    225.0,
    300.0,
    500.0,
    750.0,
    1000.0,
    1500.0,
    2000.0,
    2500.0,
};

// Output structure

pub const TransformerSelection = struct {
    demand_kva: f64, // Taken from load.DemandResult
    growth_margin: f64, // User given fraction (e.g. 0.30)
    required_kva: f64, // demand_kva * (1 + growth_margin)
    selected_kva: f64, // next standard rating >= required_kva
    utilization_pct: f64, // demand_kva / selected_kva * 100
    oversize_warning: bool, // true if utilization < 40%
};

// Sizing Function

pub fn sizeTransfomer(demand: load.DemandResult, growth_margin: f64) !TransformerSelection {
    const required_kva = demand.demand_kva * (1.0 + growth_margin);

    var selected_kva: ?f64 = null;
    for (standard_ratings_kva) |rating| {
        if (rating >= required_kva) {
            selected_kva = rating;
            break;
        }
    }

    const kva = selected_kva orelse return error.DemandExceedsMaxRating;

    const utilization_pct = (demand.demand_kva / kva) * 100.0;

    return TransformerSelection{
        .demand_kva = demand.demand_kva,
        .growth_margin = growth_margin,
        .required_kva = required_kva,
        .selected_kva = kva,
        .utilization_pct = utilization_pct,
        .oversize_warning = utilization_pct < 40.0,
    };
}

// Helper function for feeder.zig and motor.zig
//
// Full Load Current for the Selected Transformer
// Formula: I_fl = (kVA x 1000) / (root 3 x V_ll)

pub fn fullLoadCurrent(selected_kva: f64, voltage_ll: f64) f64 {
    return (selected_kva * 1000.0) / (std.math.sqrt(3.0) * voltage_ll);
}
