# Fixed-Point Radix-2 FFT Accelerator with AXI4-Stream

A parameterized 256-point fixed-point FFT accelerator in SystemVerilog. It takes complex samples in on an AXI4-Stream slave port, computes an in-place radix-2 decimation-in-time FFT with one pipelined butterfly unit, and streams the spectrum out on an AXI4-Stream master port. A bit-exact Python model generates the twiddle ROM and the test vectors, and the testbenches compare the hardware against it bit for bit. Synthesized in Vivado for a Zynq-7000 (`XC7Z007S-CLG400-1`) at 100 MHz.

---

## Architecture

```text
                           axi4_stream_fft
   ┌──────────────────────────────────────────────────────────────────┐
   │  wrapper FSM: IDLE_WAIT -> PULSE -> INGEST -> COMPUTE -> EMIT    │
   │                                                                  │
 s_axis ──► ingest ──► ┌─────────────────── fft_core ────────────────┐│
 (tdata,               │  dual-port BRAM 256 x 32 (in-place)         ││
  tvalid,              │    write: bit-reversed address while loading││
  tready)              │                                             ││
                       │  FSM: LOAD, BF_READ, BF_LATCH, BF_WAIT,     ││
                       │       BF_WRITE (x 1,024), UNLOAD, DONE      ││
                       │                                             ││
                       │   twiddle_rom (128 x 32) ──┐                ││
                       │   BRAM ports a,b ──────────┼──► butterfly   ││
                       │         ▲                  │   (3-stage)    ││
                       │         └───── u, l ◄──────┘                ││
                       └─────────────────────────────────────────────┘│
   │                                              output register ──► m_axis
   └──────────────────────────────────────────────────────────────────┘ (tdata,
                                                                         tvalid,
                                                                         tready,
                                                                         tlast)
```

| File | Role |
|------|------|
| `axi4_stream_fft.sv` | AXI4-Stream wrapper: ingests one frame, waits for the core, then emits the spectrum |
| `fft_core.sv` | In-place radix-2 DIT core: BRAM, address generation, FSM, bit-reversed loading |
| `butterfly.sv` | 3-stage butterfly: complex multiply by the twiddle, then add and subtract with scaling |
| `twiddle_rom.sv` | 128-entry twiddle ROM initialized from `twiddles_256.mem` |

Parameters: `N_POINTS` (256), `DATA_WIDTH` (16), `TWIDDLE_WIDTH` (16) and `TWIDDLE_FILE`.

### Datapath

1. **Load.** 256 complex samples arrive as `tdata[31:16]` = real and `tdata[15:0]` = imaginary, in signed Q1.15. Each sample is written to a bit-reversed address, so the output comes out in natural order.
2. **Butterflies.** 8 stages of 128 butterflies each (1,024 in total), computed in place in the BRAM. Each one reads two words, multiplies the lower one by the twiddle, then writes back `(a + b*w) / 2` and `(a - b*w) / 2`.
3. **Unload.** The 256 bins stream out through an output register, with `tlast` on the last beat.

### Butterfly

| Stage | Operation |
|-------|-----------|
| 1 | Registers the operands and the twiddle |
| 2 | Four 16 x 16 signed multiplications on `DSP48E1` blocks, shifted right by 15 (Q1.15), then combined as `Re = rr - ii` and `Im = ri + ir` with saturation |
| 3 | 17-bit add and subtract against the other operand, then an arithmetic shift right by 1 |

### Numerics

- Q1.15 samples and twiddles. Twiddles are `round(cos or sin * 32767)`.
- Every stage divides by 2, so the output is `X[k] / N` and cannot overflow.
- Products and the per-stage divide truncate toward minus infinity (they do not round), which adds a small negative bias.

### Throughput

The core runs one butterfly at a time. Each takes 5 cycles (read, latch, two waits for the 3-stage butterfly, write), so the butterflies alone take 1,024 x 5 = 5,120 cycles, about 51 µs at 100 MHz. Loading and unloading add 256 cycles each. In simulation, three frames finished in 169 µs, about 56 µs per frame. The butterfly is pipelined internally, but consecutive butterflies do not overlap.

---

## Python reference model

`model/fft_model.py` is a bit-exact model of the hardware (same bit-reversed loading, per-stage scaling, truncation and saturation). It writes the twiddle ROM `twiddles_256.mem` and stimulus and golden files in `model/vectors/` for five cases, and prints the SQNR of the fixed-point result against NumPy's floating-point FFT:

| Vector | Description | SQNR |
|--------|-------------|-----:|
| `impulse` | Full-scale impulse at t = 0 | 42.18 dB |
| `dc` | Constant 16384 on all samples | 66.23 dB |
| `single_tone` | Complex tone at bin 8, amplitude 28000 | 71.63 dB |
| `dual_tone` | Tones at bins 12 and 45, amplitude 14000 each | 65.19 dB |
| `random` | Gaussian noise, sigma 8000, seed 42 | 54.03 dB |

The impulse is lowest because every output bin is only about 127 LSB, so a one-LSB truncation error already limits it. The hardware matches this model bit for bit on the vectors it is tested with, so these are also the hardware SQNR figures.

```bash
pip install numpy
python3 fft_model.py
```

---

## Verification

| Testbench | What it does |
|-----------|--------------|
| `tb_butterfly.sv` | Three directed cases against hand-computed values: identity twiddle, a -90 degree rotation, and equal vectors that cancel. It also checks the 3-cycle latency |
| `tb_fft_core.sv` | Drives the core directly through its load and unload interface with the impulse, DC and single-tone vectors and compares every output bin with the golden file |
| `tb_axi4_stream_fft.sv` | Streams the same three vectors through the AXI4-Stream wrapper and compares the output bit for bit. It has a watchdog that ends a hung simulation |

Console output of the AXI4-Stream testbench:

```text
----------------------------------------------------------------
Running Full AXI4-Stream FFT Accelerator Verification...
----------------------------------------------------------------
[AXI-STREAM PASS] Impulse Vector streamed bit-exact with valid/ready handshake.
[AXI-STREAM PASS] DC Vector streamed bit-exact with valid/ready handshake.
[AXI-STREAM PASS] Single Tone Vector streamed bit-exact with valid/ready handshake.
----------------------------------------------------------------
$finish called at time : 169445 ns
```

### Not covered yet

- **Output backpressure.** The testbench holds `m_axis_tready` high while draining. By inspection, the output stage can lose a word if `m_axis_tready` drops mid-frame, because the core's read pipeline keeps advancing.
- **Input stalls.** `s_axis_tvalid` stays high for the whole frame, so gaps in the input are not tested. The input `tlast` is not used, so a wrong frame length is not detected.
- **Random and dual-tone vectors** are generated by the model but no testbench uses them yet.
- **Only N = 256** has been run. The RTL is parameterized, but the model constants and the twiddle file are for 256 points.
- **One frame at a time.** Loading, computing and unloading do not overlap.
- **Post-synthesis only.** Place and route has not been run, and the design has not been run on hardware.

---

## Results

Vivado 2026.1, `XC7Z007S-CLG400-1` (speed grade -1), post-synthesis. The 100 MHz clock (10.000 ns) and I/O delays are set in `constraints/constraints.xdc`: input delay 1.2 to 2.0 ns, output delay 0.5 to 2.0 ns.

| Resource | Used | Available | Utilization |
|----------|-----:|----------:|------------:|
| DSP48E1 | 4 | 66 | 6.06% |
| RAMB36E1 | 1 | 50 | 2.00% |
| Slice LUTs | 271 | 14,400 | 1.88% |
| Slice registers | 271 | 28,800 | 0.94% |
| BUFG | 1 | 32 | 3.13% |

| Metric | Value |
|--------|-------|
| Worst negative slack (setup) | +0.050 ns (0 failing of 834 endpoints) |
| Worst hold slack | +0.137 ns (0 failing of 834 endpoints) |
| Worst pulse width slack | +4.500 ns (0 failing of 309 endpoints) |

Setup slack is only 0.050 ns, so the design is at its limit at 100 MHz (roughly 100.5 MHz from this slack). The critical path is the multiply, shift, subtract and saturate in the butterfly.

---

## Repository layout

```text
axi4-stream-fft-accelerator/
├── rtl/
│   ├── axi4_stream_fft.sv
│   ├── fft_core.sv
│   ├── butterfly.sv
│   └── twiddle_rom.sv
├── tb/
│   ├── tb_butterfly.sv
│   ├── tb_fft_core.sv
│   └── tb_axi4_stream_fft.sv
├── model/
│   ├── fft_model.py
│   ├── twiddles_256.mem
│   └── vectors/          (stim_*.mem and gold_*.mem)
├── constraints/
│   └── constraints.xdc
└── README.md
```

## Running it

1. **Model:** `python3 model/fft_model.py` regenerates the twiddle ROM and the vectors.
2. **Vivado:** create an RTL project for `xc7z007sclg400-1`. Add everything in `rtl/` as design sources with `axi4_stream_fft` as top, and add `constraints/constraints.xdc` as constraints.
3. **Simulation:** add the testbenches from `tb/` as simulation sources. Add `twiddles_256.mem` and the `stim_*.mem` and `gold_*.mem` files as simulation data files so `$readmemh` can find them, set the testbench you want as the simulation top, and run. Each testbench ends with `$finish`.
