const std = @import("std");

// Object Structures

pub const LoadType = enum {
    motor,
    lighting,
    hvac,
    other,
};

pub const Duty = enum {
    continuous,
    intermittent,
};

// Load Structures

pub const Load = struct {
    name: []const u8,
    kw: f64,
    pf: f64,
    load_type: LoadType,
    duty: Duty,
};

// Per-load breakdown used by report.zig to print the load table
pub const LoadDemand = struct {
    load: Load,
    demand_factor: f64,
    demand_kw: f64,
    demand_kva: f64,
};

// Summary output of the demand aggregation step
pub const DemandResult = struct {
    total_connected_kw: f64,
    total_demand_kw: f64,
    demand_kva: f64,
    effective_pf: f64,
};

// Demand Factors
//
// These parameters encode the demand factors for different loads and
// duty cycles based on industrial transformer sizing and load schedule conventions
// (Subject to refinement)

pub fn demandFactor(load_type: LoadType, duty: Duty) f64 {
    return switch (load_type) {
        .motor => switch (duty) {
            .continuous => 1.00,
            .intermittent => 0.40,
        },
        .lighting => switch (duty) {
            .continuous => 0.90,
            .intermittent => 0.70,
        },
        .hvac => switch (duty) {
            .continuous => 0.80,
            .intermittent => 0.50,
        },
        .other => switch (duty) {
            .continuous => 0.85,
            .intermittent => 0.50,
        },
    };
}

// Demand Aggregation
// computeDemand() -> returns DemandResult used by transformer.zig
// computeDemandDetailed() -> returns DemandResult and []LoadDemand used by report.zig

pub fn computeDemand(loads: []const Load) DemandResult {
    var total_connected_kw: f64 = 0.0;
    var total_demand_kw: f64 = 0.0;
    var total_demand_kva: f64 = 0.0;

    for (loads) |load| {
        const df = demandFactor(load.load_type, load.duty);
        const demand_kw = load.kw * df;
        const demand_kva = demand_kw / load.pf;

        total_connected_kw += load.kw;
        total_demand_kw += demand_kw;
        total_demand_kva += demand_kva;
    }

    // Returns PF of 1 if load list is empty
    const effective_pf = if (total_demand_kva > 0.0) total_demand_kw / total_demand_kva else 1.0;

    return DemandResult{
        .total_connected_kw = total_connected_kw,
        .total_demand_kw = total_demand_kw,
        .demand_kva = total_demand_kva,
        .effective_pf = effective_pf,
    };
}

pub fn computeDemandDetailed(loads: []const Load, allocator: std.mem.Allocator) !struct { result: DemandResult, breakdown: []LoadDemand } {
    var breakdown = try allocator.alloc(LoadDemand, loads.len);

    var total_connected_kw: f64 = 0.0;
    var total_demand_kw: f64 = 0.0;
    var total_demand_kva: f64 = 0.0;

    for (loads, 0..) |load, i| {
        const df = demandFactor(load.load_type, load.duty);
        const demand_kw = load.kw * df;
        const demand_kva = demand_kw / load.pf;

        breakdown[i] = LoadDemand{
            .load = load,
            .demand_factor = df,
            .demand_kw = demand_kw,
            .demand_kva = demand_kva,
        };

        total_connected_kw += load.kw;
        total_demand_kw += demand_kw;
        total_demand_kva += demand_kva;
    }

    // Returns PF of 1 if load list is empty
    const effective_pf = if (total_demand_kva > 0.0) total_demand_kw / total_demand_kva else 1.0;

    const result = DemandResult{
        .total_connected_kw = total_connected_kw,
        .total_demand_kw = total_demand_kw,
        .demand_kva = total_demand_kva,
        .effective_pf = effective_pf,
    };

    return .{ .result = result, .breakdown = breakdown };
}
