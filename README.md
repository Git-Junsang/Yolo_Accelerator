# YOLOv2 FPGA Accelerator

**English** | [한국어](README.ko.md)

---

**FPGA SoC that runs a full 22-layer YOLOv2 object detector on a single Artix-7**

---

## 1. Background

Real-time object detection normally leans on a GPU, but the energy budget makes that impractical at the edge. This project ports an entire 22-layer YOLOv2 detector onto a single Artix-7 FPGA, doing every convolution, pooling, upsample, and route on-chip so that only lightweight post-processing stays in software.

- **Model**: 22-layer YOLOv2 (tiny variant), INT8-quantized, two detection heads (8×8 and 16×16 grids)
- **Engine**: a 144-MAC output-stationary datapath (`36 mul × 4 spatial`) drives every convolution from a single reusable kernel
- **Single-pass inference**: one FSM sweeps all 22 layers (Conv 3×3/1×1, MaxPool s2/s1, Upsample, Route) with no host round-trips per layer
- **Scoring** — this is an energy-first contest:

  ```
  Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)
  ```

  Target: **≥ 5 fps** and **mAP > 0.2** on the Nexys A7-100T while minimizing energy.

> Submitted to the **Chung-Ang University AIX2026 Deep Learning Hardware Design Contest** (Team Betatron).

---

## 2. System Overview

The hardware performs all tensor math; software handles only the YOLO detection head math (sigmoid / softmax / NMS).

| Component             | Role                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------- |
| Host PC (`host.py`) | Uploads image + weights over UART, runs YOLO post-processing (sigmoid/softmax/NMS), displays detections |
| MicroBlaze (Vitis)    | Accelerator control, DMA trigger, UART bridge between Host PC and`yolo_engine`                        |
| `yolo_engine` (RTL) | 22-layer auto inference — Conv/Pool/Upsample/Route + 144-MAC array + AXI master DMA                    |
| DDR2 (~4 MB)          | Weights + bias, input image (L0 IFM), and every per-layer OFM (offset table)                            |

**Division of labor**

- **Hardware (RTL)**: Conv (3×3, 1×1), Bias + Descaling, ReLU, MaxPool (stride 2 / stride 1), Upsample 2×, **Route** (L16/L19 concat handled by the `yolo_engine` FSM as a DMA/REPACK step — no software `memcpy`)
- **Software (MicroBlaze + Host PC)**: accelerator control, DMA triggers, YOLO post-processing. Single L0→L20 inference (double-inference dropped)

---

## 3. Model & Hardware Architecture

### 3.1 Software Model — YOLOv2 (quantized)

A Darknet-derived C reference (`skeleton/`) is the bit-exact golden model. It both computes mAP and emits the `$readmemh` hex the RTL consumes, so RTL output can be checked layer-by-layer against the C reference.

- **Input**: 256×256×3 image, **NCHW** (CHW byte order), identical to the C reference
- **Network**: 22 layers, two YOLO heads — L14 (8×8×195) and L20 (16×16×195)
- **Quantization**: INT8 **signed** weight, UINT8 activation; per-layer arithmetic descale shift measured from `CONV*_param_scales.hex`
- **Descaling result**: clipped to `0~255` uint8 (not float-restored); detection heads use trunc-toward-zero + INT8 clamp

| Item                | Value                                                             |
| ------------------- | ----------------------------------------------------------------- |
| Framework (golden)  | Darknet-variant C (`skeleton/`)                                 |
| Input               | 256×256×3, NCHW byte order                                      |
| Weight / activation | INT8 signed / UINT8                                               |
| Detection heads     | L14 → 8×8×195, L20 → 16×16×195                              |
| Descale             | per-layer arithmetic shift (L0=8, L2~L20=6, L20 shift=9 head)     |
| Hex artifacts       | `CONV{NN}_param_weight.hex` / `_biases.hex` / `_scales.hex` |

### 3.2 Hardware Architecture — RTL

**Design spec** (`hardware/src/`)

| Item            | Spec                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------- |
| Target board    | Nexys A7-100T (XC7A100T)                                                                      |
| Top module      | `yolo_engine.v` — 53-state FSM, 22-layer auto inference (`ap_start` → `network_done`) |
| MAC array       | 144 MAC = 36 mul × 4 spatial set → one 2×2 OFM block per pass                              |
| Data format     | NCHW, INT8 signed weight, UINT8 activation, 16-bit sign-extended bias                         |
| Clock           | 81.25 MHz target (timing closure in progress, WNS ≈ −0.18 ns at impl stage)                 |
| On-chip OFM     | `dpram_wrapper` OFM = 65536 × 32-bit = 256 KB, 5-way port mux                              |
| External memory | DDR2 (~4 MB): weight/bias base, IFM base, OFM base (per-layer offset)                         |
| Interfaces      | AXI4-Lite slave (control) + AXI4 master (data, FIXED_BURST=256)                               |

**Module map**

| Group   | Modules                                                                                              |
| ------- | ---------------------------------------------------------------------------------------------------- |
| Top     | `yolo_engine.v` (22-layer FSM), `yolo_engine_axi.v` (AXI4-Lite ctrl_reg0~3)                      |
| DMA     | `axi_dma_rd.v` (IFM/weight/bias read mux), `axi_dma_wr.v` (OFM store)                            |
| Conv    | `conv_top.v` (output-stationary loop), `ifm_line_buf.v` (4-row cyclic window, 3×3/1×1 packing) |
| MAC     | `mac_kern.v` → `mac_stack.v` → `mul.v` ×144 (INT8×INT8→INT16) + `add_tree_36in.v` ×4   |
| Post    | `post_process.v` ×4 (bias → ReLU → arith shift → uint8 clip)                                   |
| Special | `max_pool_unit.v` (s2), `max_pool_s1_unit.v` (L11 s1), `upsample_unit.v` (L18 2×)             |
| Memory  | `gbuff_param.v` (weight 72/288 asym + bias), `dpram_wrapper.v`, `spram_wrapper.v`              |
| Header  | `user_define_h.v` (`` `define FPGA `` — ON for synth, OFF for sim)                                |

**Network (22 layers)** — Route/Upsample handled without a dedicated compute module except L18.

| Layer          | Type                         | Input → Output             | Module                                         |
| -------------- | ---------------------------- | --------------------------- | ---------------------------------------------- |
| L0             | Conv 3×3                    | 256×256×3 → 256×256×16 | `conv_top`                                   |
| L1/3/5/7/9     | MaxPool s2                   | halve spatial               | `max_pool_unit`                              |
| L2/4/6/8/10/13 | Conv 3×3                    | channel up                  | `conv_top` (L8 = Route branch for L19)       |
| L11            | **MaxPool s1**         | 8×8×512 → 8×8×512      | **`max_pool_s1_unit`** (same-padding)  |
| L12            | Conv 1×1                    | 8×8×512 → 8×8×256      | `conv_top` (1×1 mode, Route branch for L16) |
| L14            | Conv 1×1                    | 8×8×512 → 8×8×195      | `conv_top` — YOLO head 1                    |
| L16            | **Route** ← L12       | → 8×8×256                | FSM skip + DRAM alias (no module)              |
| L17            | Conv 1×1                    | 8×8×256 → 8×8×128      | `conv_top`                                   |
| L18            | **Upsample 2×**       | 8×8×128 → 16×16×128    | **`upsample_unit`**                    |
| L19            | **Route** ← L18 ‖ L8 | → 16×16×384              | RTL REPACK FSM (8 states, no module)           |
| L20            | Conv 1×1                    | 16×16×384 → 16×16×195  | `conv_top` — YOLO head 2 (shift=9)          |
| L15/L21        | YOLO output                  | —                          | software post-processing                       |

**DRAM memory map** (`yolo_engine.v`)

- `ctrl_reg1` = `dram_wgt_base` — weights + bias (bias at `+0x00A0_0000`)
- `ctrl_reg2` = `dram_ifm_base` — input image (L0 IFM)
- `ctrl_reg3` = `dram_ofm_base` — every layer OFM (per-layer word offset)

---

## 4. Directory Structure

```
Yolo_Accelerator/
├── skeleton/                  # Darknet-variant C golden reference + quantized hex generator
│   ├── src/                   # C source (additionally.c 등 — quantization + hex export)
│   ├── bin/                   # ./darknet, aix2024.cfg/weights, yolohw.names
│   │   ├── log_param/         #   → CONV{NN}_param_weight/biases/scales.hex
│   │   └── log_feamap/        #   → per-layer feature-map dumps
│   └── Makefile
│
├── hardware/
│   ├── src/                   # Active RTL — 19 .v (yolo_engine + 17 submodules + define stub)
│   ├── testbench/             # Block TBs + per-layer verify (l0~l20) + yolo_engine_tb
│   │   ├── inout_data_sw/     #   C-reference golden hex (per-layer IFM/OFM)
│   │   └── sim_dram_model/    #   AXI-slave DRAM behavioral model
│   ├── sim/                   # Compile outputs (.gitignore)
│   ├── fpga/                  # Vivado project (2025) + BMG IP TCL + IP packaging + Vitis workspace
│   └── firmware/              # host.py (Host PC UART client)
│
├── documents/
│   ├── technical_reference/   # 16-chapter technical reference (Markdown)
│   └── tutorial_guide/        # Contest-provided SDK / Vivado tutorial PDFs
│
├── ARCHITECTURE.md            # Detailed architecture spec (network, module hierarchy, memory map)
├── CLAUDE.md                  # Work guide + critical-error rules
├── README.md                  # This file
└── README.ko.md
```

> Everything under `hardware/src/` is a synthesis target (no legacy files). `define.v` is an include stub for `mul.v`; the real macros live in `user_define_h.v`.

---

## 5. Getting Started

### 5.1 Build the C golden reference (Linux)

```bash
cd skeleton
make                          # → ./bin/darknet
cd bin/dataset
python make_list_cur.py       # refresh test-image paths (first run only)
```

### 5.2 Generate quantized hex (Linux)

```bash
cd skeleton/bin
# single-image inference + hex dump (-save_params)
./darknet detector test yolohw.names aix2024.cfg aix2024.weights \
  -thresh 0.24 test01.jpg -out_filename test01-det-quantized \
  -quantized -save_params

# full test-set mAP (quantized)
sh script-unix-aix2024-test-all-quantized.sh
```

Output hex lands in `skeleton/bin/log_param/`:
`CONV{NN}_param_weight.hex` (INT8), `_biases.hex` (16-bit), `_scales.hex` (descale shift).

### 5.3 RTL simulation

Set `` `define FPGA `` **OFF** (commented) in `hardware/src/user_define_h.v`, then simulate. Chain verification uses **Vivado 2025** — Vivado 2021 handles uninitialized memory (X) differently and produces ±1 LSB non-determinism.

**Testbenches** (`hardware/testbench/`)

| File                                      | Target                                     | External data                            |
| ----------------------------------------- | ------------------------------------------ | ---------------------------------------- |
| `conv_top_tb.v`                         | Conv wrapper (3×3 / 1×1)                 | `inout_data_sw/*.hex`                  |
| `pool_tb.v` / `pool_s1_tb.v`          | MaxPool stride-2 / stride-1                | `inout_data_sw/*.hex`                  |
| `upsample_tb.v`                         | Upsample 2×                               | `inout_data_sw/*.hex`                  |
| `ifm_line_buf_tb.v`                     | 4-row cyclic line buffer                   | `inout_data_sw/*.hex`                  |
| `axi_dma_rd_tb.v` / `axi_dma_wr_tb.v` | AXI master read / write                    | `sim_dram_model/`                      |
| `l{N}_verify_tb.v`                      | Per-layer chain verify (l0~l20)            | `inout_data_sw/*.hex`                  |
| `yolo_engine_tb.v`                      | Full 22-layer inference (`network_done`) | `inout_data_sw/` + `sim_dram_model/` |

```tcl
# Vivado 2025 project + per-layer / full-chain sim
source hardware/fpga/create_project_25.tcl

set_property top conv_top_tb    [get_filesets sim_1]; launch_simulation
set_property top l0_verify_tb   [get_filesets sim_1]; launch_simulation
set_property top yolo_engine_tb [get_filesets sim_1]; launch_simulation
```

> ⚠️ Keep the `log_all_signals` option **OFF** — waveform dumps blow up disk usage (hundreds of MB per TB).

### 5.4 Synthesis / bitstream (Vivado)

Set `` `define FPGA `` **ON** in `user_define_h.v` (DSP48/BRAM IPs are explicitly instantiated), then:

```tcl
cd hardware/fpga
source yolohw.tcl
source gen_bram_ips.tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
```

### 5.5 Run on hardware (Host PC UART client)

```bash
cd hardware/firmware
pip install Pillow numpy pyserial

# upload weights + image, run L0→L20 inference, receive detections
python host.py --port /dev/ttyUSB1 --image test01.jpg

# re-infer another image without re-uploading weights
python host.py --port /dev/ttyUSB1 --image test02.jpg --skip-weights
```

---

## 6. Development Status

**Current state — Phase 3 (SoC integration) in progress.** The 22-layer `yolo_engine` is synthesized and verified layer-by-layer against the C golden reference; MicroBlaze + UART + DDR2 integration and IP packaging are underway with timing being closed at 81.25 MHz.

### Software (golden reference)

- [X] Darknet-variant C reference build (`skeleton/`) — mAP + bit-exact golden model
- [X] Quantized hex export (`CONV*_param_weight/biases/scales.hex`)
- [X] `host.py` UART client — weight/image upload + YOLO post-processing (sigmoid/softmax/NMS)

### RTL (YOLOv2 accelerator)

**Phase 1 — RTL synthesis (yolo_engine standalone)**

- [X] 22-layer auto-inference FSM (53 states)
- [X] 144-MAC array (36 mul × 4 spatial) + 4× post_process
- [X] Same `mac_kern` reused for 3×3 and 1×1 conv
- [X] Dedicated L11 (MaxPool s1) and L18 (Upsample 2×) modules
- [X] AXI master DMA (FIXED_BURST=256) + per-layer DRAM offset table
- [X] Block TBs (conv_top / max_pool / max_pool_s1 / upsample)

**Phase 2 — TB verification + accuracy tuning**

- [X] `mul.v` IFM sign fix (UINT8 → INT8 signed) → conv_top_tb mismatch 31 → **0**
- [X] `yolo_engine.v` per-layer descale shift from measured scale hex (L0=8, L2~L20=6)
- [X] SW golden hex regenerated for single-inference, synced to `inout_data_sw/`
- [X] Layer-by-layer chain verify **L0~L20** (Vivado 2025, 0 mismatch), incl. L19 Route concat + L20 detection head

**Phase 3 — MicroBlaze + UART + DDR2 SoC**

- [X] `yolo_engine` IP packaging (`hardware/fpga/IP_PACKAGING/`)
- [X] Vitis firmware + `host.py` UART client (weight/image upload, YOLO post-processing)
- [X] Timing optimization — WNS @81.25 MHz: −2.6 → ≈ −0.18 ns
- [ ] Block design: MicroBlaze MCS + UART + DDR2 MIG + interconnect (on-board bring-up)
- [ ] Full timing closure at target clock

**Phase 4 — Bitstream + board demo + measurement**

- [ ] Synthesis → bitstream → board programming
- [ ] 100-image test-set mAP / fps / energy measurement → final score

---

## 7. Extras

### Documents

| Path                               | Contents                                                                      |
| ---------------------------------- | ----------------------------------------------------------------------------- |
| `documents/technical_reference/` | 16-chapter technical reference (yolo_engine, conv engine, DMA, timing)        |
| `documents/tutorial_guide/`      | Contest-provided SDK install / quantization / Vivado / MAC-BRAM manuals       |
| `ARCHITECTURE.md`                | Detailed spec — network, module hierarchy, FSM flow, DRAM map                |
| `CLAUDE.md`                      | Work guide + 8 critical-error-prevention rules                                |

### Design notes

- **144 MAC** is fixed budget — 1×1 conv reuses the 3×3 `mac_kern`, Route/Upsample avoid new compute modules (energy-first)
- **Bias** must be **sign-extended** to 32-bit (`{ {16{b[15]}}, b }`), not zero-extended
- **L11 MaxPool is stride-1** — must use `max_pool_s1_unit`, not the stride-2 unit
- **Sim memories** are `initial`-zeroed (matches real BRAM power-on), so chain verify is deterministic under Vivado 2025

---

## 8. References

- [YOLO9000 / YOLOv2](https://arxiv.org/abs/1612.08242) — Better, Faster, Stronger (Redmon & Farhadi)
- [Darknet](https://pjreddie.com/darknet/) — reference framework the `skeleton/` C golden model derives from
- [Nexys A7 (Digilent)](https://digilent.com/reference/programmable-logic/nexys-a7/start) — XC7A100T target board
