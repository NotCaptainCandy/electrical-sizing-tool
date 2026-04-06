const std = @import("std");
const load = @import("load.zig");
const transformer = @import("transformer.zig");
const feeder = @import("feeder.zig");
const motor = @import("motor.zig");
const report = @import("report.zig");

// JSON Input mirrors the load.zig structs to make parsing easier

const PlantInput = struct {
    facility_name: []const u8,
    loads: []const load.Load,
};

// Bundle of the CLI Arguments

const CliArgs = struct {
    input_path: []const u8 = "",
    out_path: []const u8 = "report.txt",
    voltage_ll: f64 = 600.0,
    target_pf: f64 = 0.90,
    growth: f64 = 0.20,
    length_m: f64 = 0.0,
    length_set: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Parsing the CLI Arguments

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // skip executable name

    var cli = CliArgs{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--voltage")) {
            const val = args.next() orelse return cliError("--voltage requires a value");
            cli.voltage_ll = std.fmt.parseFloat(f64, val) catch
                return cliError("--voltage must be a number");
        } else if (std.mem.eql(u8, arg, "--pf")) {
            const val = args.next() orelse return cliError("--pf requires a value");
            cli.target_pf = std.fmt.parseFloat(f64, val) catch
                return cliError("--pf must be a number");
        } else if (std.mem.eql(u8, arg, "--growth")) {
            const val = args.next() orelse return cliError("--growth requires a value");
            cli.growth = std.fmt.parseFloat(f64, val) catch
                return cliError("--growth must be a number");
        } else if (std.mem.eql(u8, arg, "--length")) {
            const val = args.next() orelse return cliError("--length requires a value");
            cli.length_m = std.fmt.parseFloat(f64, val) catch
                return cliError("--length must be a number");
            cli.length_set = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            cli.out_path = args.next() orelse return cliError("--out requires a path");
        } else if (arg.len > 0 and arg[0] != '-') {
            cli.input_path = arg;
        } else {
            printUsage();
            return error.UnknownFlag;
        }
    }

    if (cli.input_path.len == 0) {
        printUsage();
        return cliError("input JSON file is required");
    }
    if (!cli.length_set) {
        printUsage();
        return cliError("--length is required");
    }
    if (cli.target_pf <= 0.0 or cli.target_pf > 1.0) return cliError("--pf must be between 0 and 1");
    if (cli.growth < 0.0) return cliError("--growth must be >= 0");
    if (cli.voltage_ll <= 0.0) return cliError("--voltage must be > 0");
    if (cli.length_m <= 0.0) return cliError("--length must be > 0");

    // Reading and parsing the JSON

    const json_bytes = std.Io.Dir.cwd().readFileAlloc(io, cli.input_path, gpa, .limited(1024 * 1024)) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ cli.input_path, err });
        return err;
    };
    defer gpa.free(json_bytes);

    const parsed = std.json.parseFromSlice(PlantInput, gpa, json_bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("JSON parse error in '{s}': {}\n", .{ cli.input_path, err });
        return err;
    };
    defer parsed.deinit();

    const plant = parsed.value;

    if (plant.loads.len == 0) return cliError("Load list is empty - add at least one load to the JSON");

    // Computing the demand
    const detailed = try load.computeDemandDetailed(plant.loads, gpa);
    defer gpa.free(detailed.breakdown);
    const demand = detailed.result;

    // Sizing the transformer
    const selection = transformer.sizeTransfomer(demand, cli.growth) catch |err| switch (err) {
        error.DemandExceedsMaxRating => {
            std.debug.print("Error: demand of {d:.1} kVA (with {d:.0}% growth) exceeds the " ++
                "largest standard transformer rating (2500 kVA).\n" ++
                "Consider parallel transformers or a custom unit.\n", .{ demand.demand_kva * (1.0 + cli.growth), cli.growth * 100.0 });
            return err;
        },
    };

    // Sizing the feeder
    const feed = feeder.sizeFeeder(
        selection,
        cli.voltage_ll,
        cli.length_m,
        cli.target_pf,
    ) catch |err| switch (err) {
        error.NoSuitableCableFound => {
            std.debug.print(
                "Error: no cable in the table satisfies both ampacity and " ++
                    "voltage drop constraints for a {d:.0} m feeder at {d:.0} kVA.\n" ++
                    "Consider parallel feeders or relocating the transformer.\n",
                .{ cli.length_m, selection.selected_kva },
            );
            return err;
        },
    };

    const candidates = try feeder.allCableCandidates(
        feed.full_load_current_a,
        cli.length_m,
        cli.target_pf,
        cli.voltage_ll,
        gpa,
    );
    defer gpa.free(candidates);

    // Motor starting screening
    const motor_screen = motor.screenMotorStarting(plant.loads, selection);

    // Write the report
    const report_input = report.ReportInput{
        .facility_name = plant.facility_name,
        .voltage_ll = cli.voltage_ll,
        .target_pf = cli.target_pf,
        .growth_margin = cli.growth,
        .feeder_length_m = cli.length_m,
        .demand = demand,
        .breakdown = detailed.breakdown,
        .selection = selection,
        .feed = feed,
        .candidates = candidates,
        .motor_screen = motor_screen,
    };

    try report.writeReport(io, gpa, cli.out_path, report_input);

    std.debug.print("Report written to: {s}\n", .{cli.out_path});
}

// Helper Functions

fn cliError(msg: []const u8) error{CliError} {
    std.debug.print("Error: {s}\n", .{msg});
    return error.CliError;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: plant_sizer <loads.json> --length <m> [options]
        \\
        \\Required:
        \\  <loads.json>       Path to facility load list JSON file
        \\  --length <m>       Main feeder length in metres
        \\
        \\Options:
        \\  --voltage <V>      LV bus voltage, line-to-line (default: 600)
        \\  --pf <0-1>         Target power factor (default: 0.90)
        \\  --growth <0-1>     Future growth margin fraction (default: 0.20)
        \\  --out <file>       Output report file path (default: report.txt)
        \\
        \\Example:
        \\  plant_sizer loads.json --length 80 --voltage 600 --pf 0.92 --growth 0.25 --out sizing.txt
        \\
    , .{});
}
