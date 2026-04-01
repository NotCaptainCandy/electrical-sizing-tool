const std = @import("std");
const load = @import("load.zig");
const transformer = @import("transformer.zig");

const MOTOR_PF_ASSUMPTION: f64 = 0.88; // Fallback value in case no pf is provided in json
const DOL_STARTING_MULTIPLIER: f64 = 6.0; // Direct on line motor extra current draw
// based on IEEE 141 section 3

const VD_SCREEN_THRESHOLD_PCT: f64 = 10.0; // Voltage dip threshold for static screen
const RATIO_THRESHOLD: f64 = 0.30; // largest motor kVA / transformer kVA

// Starting method structure

pub const StartingMethod = enum {
    dol_acceptable,
    review_soft_start,
    review_vfd,
    review_star_delta,
};

// Output structure

pub const MotorScreenResult = struct {
    largest_motor_name: []const u8,
    largest_motor_kw: f64,
    largest_motor_kva: f64,
    transformer_kva: f64,
    motor_ratio: f64,
    estimated_vd_pct: f64,
    ratio_flag: bool,
    vd_flag: bool,
    needs_attention: bool,
    recommended_starting: StartingMethod,
    no_motors_found: bool,
};

// Voltage Dip estimate (VD% = (motor start kva / transformer kva) x Z_t%(transformer per unit impedance)

const TRANSFORMER_Z_PCT: f64 = 5.75; // Typical value according to IEEE C57.12

fn estimateStartingVoltageDip(largest_motor_kva: f64, transformer_kva: f64) f64 {
    const starting_kva = largest_motor_kva * DOL_STARTING_MULTIPLIER;
    return (starting_kva / transformer_kva) * TRANSFORMER_Z_PCT;
}
