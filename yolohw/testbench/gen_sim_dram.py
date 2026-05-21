#!/usr/bin/env python3
"""
gen_sim_dram.py — yolo_engine_golden_tb 용 DRAM .mem 파일 생성기

출력 파일 (yolohw/sim/inout_data_sw/ 에 생성):
  gen_wgt_dram.mem   : 11 layer weight 전체 (2,577,152 × 32-bit word)
  gen_bias_dram.mem  : 11 layer bias 전체  (2,294 × 32-bit word, sign-extended)
  gen_ifm_dram.mem   : L0 IFM             (65,536 × 32-bit word)

사용법:
  cd /data/2026 CAU/AIX2026/git/Yolo_Accelerator
  python yolohw/sim/gen_sim_dram.py
"""

import os
import struct

# ── 레이어 테이블 (host.py 와 동일) ──────────────────────────────────────────
# hex_id, Co, Ci, kbytes(9=3×3, 1=1×1), acc_len, blk_off, bias_off
CONV_LAYERS = [
    ('00', 16,   3,  9,   1,       0,    0),
    ('02', 32,  16,  9,   4,      16,   16),
    ('04', 64,  32,  9,   8,     144,   48),
    ('06',128,  64,  9,  16,     656,  112),
    ('08',256, 128,  9,  32,    2704,  240),
    ('10',512, 256,  9,  64,   10896,  496),
    ('12',256, 512,  1, 128,   43664, 1008),
    ('13',512, 256,  9,  64,   76432, 1264),
    ('14',195, 512,  1, 128,  109200, 1776),
    ('17',128, 256,  1,  64,  134160, 1971),
    ('20',195, 384,  1,  96,  142352, 2099),
]
TOTAL_WGT_BLOCKS = 161072   # last blk_off + last Co×acc_len
TOTAL_BIAS_WORDS = 2294     # sum of all Co

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PARAM_DIR    = os.path.join(SCRIPT_DIR, 'inout_data_sw', 'log_param')
FEAMAP_DIR   = os.path.join(SCRIPT_DIR, 'inout_data_sw', 'log_feamap')
OUT_DIR      = os.path.join(SCRIPT_DIR, 'inout_data_sw')


def load_hex_bytes(path):
    """1 byte/line hex 파일 → bytearray"""
    with open(path) as f:
        return bytearray(int(l.strip(), 16) for l in f if l.strip())


def load_hex_u16(path):
    """1 u16/line hex 파일 → list[int]"""
    with open(path) as f:
        return [int(l.strip(), 16) for l in f if l.strip()]


def sign_extend_16(v):
    if v & 0x8000:
        return v - 0x10000
    return v


# ── 1. Weight DRAM buffer ────────────────────────────────────────────────────
def build_wgt_dram():
    total_bytes = TOTAL_WGT_BLOCKS * 64
    buf = bytearray(total_bytes)

    for hex_id, Co, Ci, kbytes, acc_len, blk_off, _ in CONV_LAYERS:
        wgt_path = os.path.join(PARAM_DIR, f'CONV{hex_id}_param_weight.hex')
        raw = load_hex_bytes(wgt_path)
        assert len(raw) == Co * Ci * kbytes, \
            f"L{hex_id} weight: got {len(raw)}, expected {Co*Ci*kbytes}"

        for fi in range(Co):
            fi_off = fi * Ci * kbytes
            for g in range(acc_len):
                block_byte = (blk_off + fi * acc_len + g) * 64
                for s in range(4):
                    ch = g * 4 + s
                    slot_byte = block_byte + s * 16
                    if ch < Ci:
                        k0 = fi_off + ch * kbytes
                        buf[slot_byte: slot_byte + kbytes] = raw[k0: k0 + kbytes]

        print(f"  L{hex_id}: Co={Co} Ci={Ci} kbytes={kbytes} acc={acc_len} "
              f"blk_off={blk_off} → {Co*acc_len} blocks")

    return buf


# ── 2. Bias DRAM buffer ──────────────────────────────────────────────────────
def build_bias_dram():
    words = []
    for hex_id, Co, *_ in CONV_LAYERS:
        bias_path = os.path.join(PARAM_DIR, f'CONV{hex_id}_param_biases.hex')
        raw16 = load_hex_u16(bias_path)
        assert len(raw16) == Co, f"L{hex_id} bias: got {len(raw16)}, expected {Co}"
        for v in raw16:
            s = sign_extend_16(v) & 0xFFFFFFFF
            words.append(s)
    assert len(words) == TOTAL_BIAS_WORDS, \
        f"bias words: {len(words)} != {TOTAL_BIAS_WORDS}"
    return words


# ── 3. IFM DRAM buffer (L0: 256×256×3, 4px×4ch interleaved) ─────────────────
def build_ifm_dram():
    ifm_path = os.path.join(FEAMAP_DIR, 'CONV00_input.hex')
    raw = load_hex_bytes(ifm_path)
    H, W, CI = 256, 256, 3
    assert len(raw) == H * W * CI

    def get_px(c, h, w):
        if c < 0 or c >= CI or h < 0 or h >= H or w < 0 or w >= W:
            return 0
        return raw[c * H * W + h * W + w]

    words = []
    for row in range(H):
        for col_b in range(W // 4):
            # 128-bit entry: 4 cols × 4 channels, byte-interleaved
            entry = []
            for col_l in range(4):
                for ch_l in range(4):
                    entry.append(get_px(ch_l, row, col_b * 4 + col_l))
            # 16 bytes → 4 × 32-bit words (little-endian)
            for wi in range(4):
                b0, b1, b2, b3 = entry[wi*4], entry[wi*4+1], entry[wi*4+2], entry[wi*4+3]
                words.append(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
    return words


# ── 출력 ─────────────────────────────────────────────────────────────────────
def write_mem(path, words_iter, n_words, label):
    with open(path, 'w') as f:
        for w in words_iter:
            f.write(f'{w & 0xFFFFFFFF:08x}\n')
    print(f"  Written {n_words} words → {os.path.basename(path)}")


if __name__ == '__main__':
    print('[gen_sim_dram] Building weight DRAM...')
    wgt_buf = build_wgt_dram()
    total_wgt_words = len(wgt_buf) // 4
    wgt_words = (int.from_bytes(wgt_buf[i*4:i*4+4], 'little')
                 for i in range(total_wgt_words))
    write_mem(os.path.join(OUT_DIR, 'gen_wgt_dram.mem'),
              wgt_words, total_wgt_words, 'weight')

    print('[gen_sim_dram] Building bias DRAM...')
    bias_words = build_bias_dram()
    write_mem(os.path.join(OUT_DIR, 'gen_bias_dram.mem'),
              iter(bias_words), TOTAL_BIAS_WORDS, 'bias')

    print('[gen_sim_dram] Building IFM DRAM...')
    ifm_words = build_ifm_dram()
    write_mem(os.path.join(OUT_DIR, 'gen_ifm_dram.mem'),
              iter(ifm_words), len(ifm_words), 'IFM')

    print('[gen_sim_dram] Done.')
    print(f'  WGT : {total_wgt_words} words = {total_wgt_words*4/1024/1024:.2f} MB')
    print(f'  BIAS: {TOTAL_BIAS_WORDS} words = {TOTAL_BIAS_WORDS*4} bytes')
    print(f'  IFM : {len(ifm_words)} words = {len(ifm_words)*4} bytes')
