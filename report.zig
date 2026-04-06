const std = @import("std");
const load = @import("load.zig");
const transformer = @import("transformer.zig");
const feeder = @import("feeder.zig");
const motor = @import("motor.zig");

pub const ReportInput = struct {
    facility_name: []const u8,
    voltage_ll: f64,
    target_pf: f64,
    growth_margin: f64,
    feeder_length_m: f64,

    demand: load.DemandResult,
    breakdown: []const load.LoadDemand,
    selection: transformer.TransformerSelection,
    feed: feeder.FeederResult,
    candidates: []const feeder.CableCandidate,
    motor_screen: motor.MotorScreenResult,
};

// Builds the report into a Writer.Allocating buffer then flushes to a file using std.fs.File.Writer

pub fn writeReport(io: std.Io, allocator: std.mem.Allocator, out_path: []const u8, r: ReportInput) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try buildHeader(w, r);
    try buildLoadSummary(w, r);
    try buildTransformerSizing(w, r);
    try buildFeederSizing(w, r);
    try buildMotorScreen(w, r);
    try sep(w);
    try w.writeAll("Report complete.\n", .{});

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});

    var out_buf: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(file, io, &out_buf);
    try file_writer.interface.writeAll(aw.writer.buffered());
    try file_writer.interface.flush();
}

// Helper Functions

const W = *std.Io.Writer;

fn sep(w: W) !void {
    try w.writeAll("=" ** 60 ++ "\n");
}

fn secHeader(w: W, title: []const u8) !void {
    try w.writeByte('\n');
    try w.writeAll(title);
    try w.writeByte('\n');
    try w.writeAll("-" ** 60 ++ "\n");
}

// Header

fn buildHeader(w: W, r: ReportInput) !void {
    try sep(w);
    try w.writeAll("  INDUSTRIAL PLANT ELECTRICAL SIZING REPORT\n");
    try sep(w);
    try w.print("  Facility      : {s}\n", .{r.facility_name});
    try w.print("  Supply voltage: {d:.0} V (L-L)\n", .{r.voltage_ll});
    try w.print("  Target PF     : {d:.2}\n", .{r.target_pf});
    try w.print("  Growth margin : {d:.0}%\n", .{r.growth_margin * 100.0});
    try w.print("  Feeder length : {d:.0} m\n\n", .{r.feeder_length_m});
}

// Load Summary

fn buildLoadSummary(w: W, r: ReportInput) !void {
    try secHeader(w, "1. LOAD SUMMARY");
    try w.print("  {s:<28} {s:>8} {s:>6} {s:>8} {s:>10} {s:>10}\n", .{ "Load Name", "kW", "PF", "Dem.Fct", "Dem. kW", "Dem. kVA" });
    try w.writeAll("  " ++ "-" ** 74 ++ "\n");

    for (r.breakdown) |b| {
        try w.print(
            "  {s:<28} {d:>8.1} {d:>6.2} {d:>8.2} {d:>10.1} {d:>10.1}\n",
            .{ b.load.name, b.load.kw, b.load.pf, b.demand_factor, b.demand_kw, b.demand_kva },
        );
    }

    try w.writeAll("  " ++ "-" ** 74 ++ "\n");
    try w.print("  {s:<28} {d:>8.1} {s:>6} {s:>8} {d:>10.1} {d:>10.1}\n", .{ "TOTAL", r.demand.total_connected_kw, "", "", r.demand.total_demand_kw, r.demand.demand_kva });
    try w.print("\n  Connected load : {d:.1} kW\n", .{r.demand.total_connected_kw});
    try w.print("  Demand load    : {d:.1} kW\n", .{r.demand.total_demand_kw});
    try w.print("  Demand kVA     : {d:.1} kVA\n", .{r.demand.demand_kva});
    try w.print("  Effective PF   : {d:.3}\n", .{r.demand.effective_pf});
}

// Transformer Sizing

fn buildTransformerSizing(w: W, r: ReportInput) !void {
    try secHeader(w, "2. TRANSFORMER SIZING");
    try w.print("  Demand kVA               : {d:.1} kVA\n", .{r.selection.demand_kva});
    try w.print("  Growth margin ({d:.0}%)  : +{d:.1} kVA\n", .{ r.selection.growth_margin * 100.0, r.selection.required_kva - r.selection.demand_kva });
    try w.print("  Required kVA             : {d:.1} kVA\n", .{r.selection.required_kva});
    try w.print("  Selected standard rating : {d:.0} kVA\n", .{r.selection.selected_kva});
    try w.print("  Utilization at demand    : {d:.1}%\n", .{r.selection.utilization_pct});

    if (r.selection.oversize_warning) {
        try w.writeAll("\n  [!] WARNING: Transformer utilization is below 40%.\n" ++
            "      Consider reducing growth margin or validating load list.\n");
    }
}

// Feeder Sizing

fn buildFeederSizing(w: W, r: ReportInput) !void {
    try secHeader(w, "3. MAIN FEEDER SIZING");
    try w.print("  Full load current : {d:.1} A\n", .{r.feed.full_load_current_a});
    try w.print("  Feeder length     : {d:.0} m\n", .{r.feed.length_m});
    try w.print("  Selected cable    : {s}\n", .{r.feed.cable.name});
    try w.print("  Ampacity          : {d:.0} A  [{s}]\n", .{ r.feed.cable.ampacity_a, if (r.feed.ampacity_ok) "PASS" else "FAIL" });
    try w.print("  Voltage drop      : {d:.2}%  [{s}]  (limit: 3.0%)\n", .{ r.feed.vd_pct, if (r.feed.vd_ok) "PASS" else "FAIL" });

    try w.writeAll("\n  Cable comparison:\n");
    try w.print("  {s:<24} {s:>10} {s:>10} {s:>8} {s:>8}\n", .{ "Cable", "Ampacity A", "VD %", "Amp.", "VD" });
    try w.writeAll("  " ++ "-" ** 64 ++ "\n");

    for (r.candidates) |c| {
        const marker: []const u8 = if (std.mem.eql(u8, c.cable.name, r.feed.cable.name)) " <--" else "";
        try w.print("  {s:<24} {d:>10.0} {d:>10.2} {s:>8} {s:>8}{s}\n", .{ c.cable.name, c.cable.ampacity_a, c.vd_pct, if (c.ampacity_ok) "PASS" else "FAIL", if (c.vd_ok) "PASS" else "FAIL", marker });
    }
}

// Motor Starting Screening

fn buildMotorScreen(w: W, r: ReportInput) !void {
    try secHeader(w, "4. MOTOR STARTING SCREEN");

    if (r.motor_screen.no_motors_found) {
        try w.writeAll("  No motors in load list. Screen not applicable.\n");
        return;
    }

    try w.print("  Largest motor     : {s}\n", .{r.motor_screen.largest_motor_name});
    try w.print("  Motor kW / kVA    : {d:.1} kW  /  {d:.1} kVA\n", .{
        r.motor_screen.largest_motor_kw,
        r.motor_screen.largest_motor_kva,
    });
    try w.print("  Transformer kVA   : {d:.0} kVA\n", .{r.motor_screen.transformer_kva});
    try w.print("  Motor/Xfmr ratio  : {d:.3}  (threshold: 0.30)\n", .{r.motor_screen.motor_ratio});
    try w.print("  Est. starting dip : {d:.1}%  (threshold: 10.0%)\n", .{r.motor_screen.estimated_vd_pct});
    try w.print("  Ratio check       : [{s}]\n", .{if (r.motor_screen.ratio_flag) "FLAG" else "OK"});
    try w.print("  VD estimate check : [{s}]\n", .{if (r.motor_screen.vd_flag) "FLAG" else "OK"});

    if (r.motor_screen.needs_attention) {
        const advice: []const u8 = switch (r.motor_screen.recommended_starting) {
            .dol_acceptable => "Direct-on-line acceptable.",
            .review_soft_start => "Review soft starter option with engineer.",
            .review_star_delta => "Review star-delta or soft starter with engineer.",
            .review_vfd => "VFD strongly recommended. Review with engineer.",
        };
        try w.print(
            "\n  [!] Motor starting warrants further review.\n" ++
                "      Recommendation: {s}\n" ++
                "      A dynamic motor starting study (ETAP/SKM) is advised\n" ++
                "      before finalising the distribution design.\n",
            .{advice},
        );
    } else {
        try w.writeAll("\n  Direct-on-line starting acceptable for this system.\n");
    }
}
