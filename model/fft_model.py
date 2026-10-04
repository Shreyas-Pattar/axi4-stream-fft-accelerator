#!/usr/bin/env python3
"""
Bit-Exact Reference Model, Twiddle ROM Generator, and Vector Engine
Project: axi4-stream-fft-accelerator
Target: Xilinx Zynq-7000 (XC7Z007S)
"""

import os
import numpy as np

# -----------------------------------------------------------------------------
# Hardware Configuration Constants
# -----------------------------------------------------------------------------
N_POINTS = 256          # Default frame size (parameterizable power-of-two)
DATA_WIDTH = 16        # Q1.15 signed fixed-point (1 sign, 15 fractional)
TWIDDLE_WIDTH = 16     # Q1.15 signed fixed-point
STAGES = int(np.log2(N_POINTS))

MAX_VAL = (1 << (DATA_WIDTH - 1)) - 1   # +32767
MIN_VAL = -(1 << (DATA_WIDTH - 1))      # -32768

# -----------------------------------------------------------------------------
# Fixed-Point Helpers (Q1.15 Bit-Exact Arithmetic)
# -----------------------------------------------------------------------------
def clamp16(val: int) -> int:
    """Clamps a 32-bit integer to signed 16-bit boundaries."""
    return max(MIN_VAL, min(MAX_VAL, int(val)))

def to_hex16(val: int) -> str:
    """Formats signed integer into 4-character uppercase hex string (two's complement)."""
    val = clamp16(val)
    return f"{(val & 0xFFFF):04X}"

def bit_reverse(addr: int, bits: int) -> int:
    """Reverses the bit order of an integer address."""
    rev = 0
    for _ in range(bits):
        rev = (rev << 1) | (addr & 1)
        addr >>= 1
    return rev

def q15_mul(a: int, b: int) -> int:
    """
    Simulates DSP48E1 16-bit x 16-bit Q1.15 signed multiplication:
    Result is 32-bit, truncated back to 16-bit via arithmetic right shift by 15.
    """
    prod = a * b
    scaled = prod >> 15
    return clamp16(scaled)

def complex_mul_q15(ar: int, ai: int, wr: int, wi: int):
    """
    Hardware-exact Complex Multiplier:
    (Ar + j*Ai) * (Wr + j*Wi) = (Ar*Wr - Ai*Wi) + j*(Ar*Wi + Ai*Wr)
    """
    rr = q15_mul(ar, wr)
    ii = q15_mul(ai, wi)
    ri = q15_mul(ar, wi)
    ir = q15_mul(ai, wr)

    out_r = clamp16(rr - ii)
    out_i = clamp16(ri + ir)
    return out_r, out_i

# -----------------------------------------------------------------------------
# Bit-Exact RTL Hardware Simulator
# -----------------------------------------------------------------------------
def hardware_fft_model(samples_r: list, samples_i: list):
    """
    Mirrors the in-place Radix-2 DIT dual-port memory execution:
    1. Bit-reversed loading into working buffer.
    2. log2(N) stages of butterflies.
    3. Per-stage divide-by-2 arithmetic shift: (A +/- B*W) >> 1.
    """
    n = len(samples_r)
    stages = int(np.log2(n))

    # 1. Bit-reversed address mapping
    buf_r = [0] * n
    buf_i = [0] * n
    for i in range(n):
        rev = bit_reverse(i, stages)
        buf_r[rev] = clamp16(samples_r[i])
        buf_i[rev] = clamp16(samples_i[i])

    # 2. Stage computations
    for s in range(1, stages + 1):
        m = 1 << s               # Sub-transform size
        half_m = m >> 1          # Butterfly span
        twiddle_step = n // m

        for k in range(0, n, m):
            for j in range(half_m):
                # Retrieve Quantized Twiddle: W_N^(j * twiddle_step)
                theta = -2.0 * np.pi * (j * twiddle_step) / n
                wr = clamp16(round(np.cos(theta) * 32767.0))
                wi = clamp16(round(np.sin(theta) * 32767.0))

                idx_u = k + j
                idx_l = k + j + half_m

                ur = buf_r[idx_u]
                ui = buf_i[idx_u]
                lr = buf_r[idx_l]
                li = buf_i[idx_l]

                # Complex Multiplier on lower wing
                t_r, t_i = complex_mul_q15(lr, li, wr, wi)

                # Butterfly Add/Sub with hardware >> 1 scaling
                buf_r[idx_u] = clamp16((ur + t_r) >> 1)
                buf_i[idx_u] = clamp16((ui + t_i) >> 1)
                buf_r[idx_l] = clamp16((ur - t_r) >> 1)
                buf_i[idx_l] = clamp16((ui - t_i) >> 1)

    return buf_r, buf_i

# -----------------------------------------------------------------------------
# Metric & File Generation
# -----------------------------------------------------------------------------
def calculate_sqnr(float_ref: np.ndarray, fixed_out: np.ndarray) -> float:
    """Calculates Signal-to-Quantization-Noise Ratio (SQNR) in decibels."""
    scaled_ref = float_ref / len(float_ref)
    noise = scaled_ref - fixed_out
    sig_pwr = np.mean(np.abs(scaled_ref) ** 2)
    noise_pwr = np.mean(np.abs(noise) ** 2)
    if noise_pwr == 0:
        return float('inf')
    return 10.0 * np.log10(sig_pwr / noise_pwr)

def export_twiddles(output_path: str, n_points: int):
    """
    Generates twiddle ROM entries: W_N^k for k in [0, N/2 - 1].
    Line format: 32 bits total -> [31:16] Real, [15:0] Imaginary.
    """
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        for k in range(n_points // 2):
            theta = -2.0 * np.pi * k / n_points
            wr = clamp16(round(np.cos(theta) * 32767.0))
            wi = clamp16(round(np.sin(theta) * 32767.0))
            f.write(f"{to_hex16(wr)}{to_hex16(wi)}\n")
    print(f"[Generated] Twiddle ROM ({n_points // 2} entries) -> {output_path}")

def generate_test_case(name: str, input_complex: np.ndarray, base_dir: str):
    """Generates stimulus and expected outputs for SystemVerilog testbench."""
    n = len(input_complex)
    os.makedirs(base_dir, exist_ok=True)

    in_r = [int(x.real) for x in input_complex]
    in_i = [int(x.imag) for x in input_complex]

    # Write Stimulus File (32 bits: [31:16] Real, [15:0] Imag)
    stim_path = os.path.join(base_dir, f"stim_{name}.mem")
    with open(stim_path, "w") as f:
        for r, i in zip(in_r, in_i):
            f.write(f"{to_hex16(r)}{to_hex16(i)}\n")

    # Run Bit-Exact Model
    hw_r, hw_i = hardware_fft_model(in_r, in_i)

    # Write Hardware Gold File
    gold_path = os.path.join(base_dir, f"gold_{name}.mem")
    with open(gold_path, "w") as f:
        for r, i in zip(hw_r, hw_i):
            f.write(f"{to_hex16(r)}{to_hex16(i)}\n")

    # Compute NumPy Baseline & Measure SQNR
    norm_in = (np.array(in_r) + 1j * np.array(in_i)) / 32767.0
    float_fft = np.fft.fft(norm_in)
    hw_complex_norm = (np.array(hw_r) + 1j * np.array(hw_i)) / 32767.0
    sqnr = calculate_sqnr(float_fft, hw_complex_norm)

    print(f"[Vector] {name:<12} | Length: {n} | SQNR: {sqnr:6.2f} dB")

# -----------------------------------------------------------------------------
# Main Execution Entry Point
# -----------------------------------------------------------------------------
if __name__ == "__main__":
    np.random.seed(42)
    output_dir = os.path.join(os.path.dirname(__file__), "vectors")

    # 1. Output Twiddle Factor ROM (W_256^0 to W_256^127)
    twiddle_file = os.path.join(os.path.dirname(__file__), "twiddles_256.mem")
    export_twiddles(twiddle_file, N_POINTS)

    # 2. Vector: Unit Impulse
    impulse = np.zeros(N_POINTS, dtype=complex)
    impulse[0] = 32767 + 0j
    generate_test_case("impulse", impulse, output_dir)

    # 3. Vector: Full-Scale DC
    dc = np.full(N_POINTS, 16384 + 0j, dtype=complex)
    generate_test_case("dc", dc, output_dir)

    # 4. Vector: Single Sine Wave Tone (Bin 8)
    t = np.arange(N_POINTS)
    bin_idx = 8
    tone = np.round(28000.0 * np.exp(1j * 2.0 * np.pi * bin_idx * t / N_POINTS))
    generate_test_case("single_tone", tone, output_dir)

    # 5. Vector: Dual Sine Wave Tone (Bins 12 and 45)
    dual_tone = np.round(14000.0 * np.exp(1j * 2.0 * np.pi * 12 * t / N_POINTS) +
                         14000.0 * np.exp(1j * 2.0 * np.pi * 45 * t / N_POINTS))
    generate_test_case("dual_tone", dual_tone, output_dir)

    # 6. Vector: Constrained-Random Gaussian Frame
    rand_r = np.random.normal(0, 8000, N_POINTS)
    rand_i = np.random.normal(0, 8000, N_POINTS)
    rand_vec = np.clip(rand_r, -32768, 32767) + 1j * np.clip(rand_i, -32768, 32767)
    generate_test_case("random", rand_vec, output_dir)