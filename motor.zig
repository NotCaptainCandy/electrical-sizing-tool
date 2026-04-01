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

// Starting Method Advisor

fn recommendStartingMethod(motor_ratio: f64) StartingMethod {
    if (motor_ratio < RATIO_THRESHOLD) {
        return .dol_acceptable;
    } else if (motor_ratio < 0.50) {
        return .review_soft_start;
    } else if (motor_ratio < 0.70) {
        return .review_star_delta;
    } else {
        return .review_vfd;
    }
}

// Static Screening Function

pub fn screenMotorStarting(loads: []const load.Load, sel: transformer.TransformerSelection) MotorScreenResult {
    var largest_kw: f64 = 0.0;
    var largest_name: []const u8 = "N/A";
    var largest_pf: f64 = MOTOR_PF_ASSUMPTION;
    var motor_found: bool = false;

    for (loads) |l| {
        if (l.load_type == .motor and l.kw > largest_kw) {
            largest_kw = l.kw;
            largest_name = l.name;
            largest_pf = l.pf;
            motor_found = true;
        }
    }

    //No motor case

    if (!motor_found) {
        return MotorScreenResult{
            .largest_motor_name = "N/A",
            .largest_motor_kw = 0.0,
            .largest_motor_kva = 0.0,
            .transformer_kva = sel.selected_kva,
            .motor_ratio = 0.0,
            .estimated_vd_pct = 0.0,
            .ratio_flag = false,
            .vd_flag = false,
            .needs_attention = false,
            .recommended_starting = .dol_acceptable,
            .no_motors_found = true,
        };
    }

    const largest_kva = largest_kw / sel.selected_kva;

    const motor_ratio = largest_kva / sel.selected_kva;
    const est_vd_pct = estimateStartingVoltageDip(largest_kva, sel.selected_kva);
    const ratio_flag = motor_ratio > RATIO_THRESHOLD;
    const vd_flag = est_vd_pct > VD_SCREEN_THRESHOLD_PCT;
    const needs_attention = ratio_flag or vd_flag;

    const starting_method = recommendStartingMethod(motor_ratio);

    return MotorScreenResult{
        .largest_motor_name = largest_name,
        .largest_motor_kw = largest_kw,
        .largest_motor_kva = largest_kva,
        .transformer_kva = sel.selected_kva,
        .motor_ratio = motor_ratio,
        .estimated_vd_pct = est_vd_pct,
        .ratio_flag = ratio_flag,
        .vd_flag = vd_flag,
        .needs_attention = needs_attention,
        .recommended_starting = starting_method,
        .no_motors_found = false,
    };
}
