#!/usr/bin/env python3
"""
YOLOv2 FPGA Accelerator — Host PC UART 클라이언트 (Phase 3)

사전 준비:
  pip install Pillow numpy pyserial

사용법:
  # 최초 실행 (weight + image 전송 + 추론)
  python host.py --port /dev/ttyUSB1 --image test01.jpg

  # weight 재업로드 없이 다른 이미지로 재추론
  python host.py --port /dev/ttyUSB1 --image test02.jpg --skip-weights

  # UART 통신 테스트만
  python host.py --port /dev/ttyUSB1 --hello

추론 시퀀스 (double-inference, L19 concat 포함):
  1. Weight + Bias DRAM 적재  (MODE_STORE_RAM)
  2. IFM 적재                  (MODE_STORE_RAM)
  3. 1차 추론  L0→L21          (MODE_RUN_ENGINE)
  4. L19 concat  L8→L18 뒤     (MODE_CONCAT_L19)
  5. 2차 추론  L0→L21          (MODE_RUN_ENGINE)
  6. YOLO 후처리 + 결과 수신    (MODE_YOLO_POST)
"""

import serial
import struct
import argparse
import sys
import os
import time
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# ═══════════════════════════════════════════════════════════════════════════════
# 프로토콜 모드 코드
# ═══════════════════════════════════════════════════════════════════════════════
MODE_TEST_HELLO = 0x01
MODE_TEST_ECHO  = 0x02
MODE_STORE_RAM  = 0x03
MODE_LOAD_RAM   = 0x04
MODE_RUN_ENGINE = 0x06
MODE_CONCAT_L19 = 0x07
MODE_YOLO_POST  = 0x08

# ═══════════════════════════════════════════════════════════════════════════════
# DRAM 레이아웃 (DDR2_BASE 기준 byte offset)
# ═══════════════════════════════════════════════════════════════════════════════
DDR2_OFF_WGT  = 0x00000000  # weight 전체 (22 conv layer 연속)
DDR2_OFF_BIAS = 0x00A00000  # bias 전체 (weight ~9.8 MB 이후 안전 위치)
DDR2_OFF_IFM  = 0x01000000  # 입력 이미지 (256×256×3 packed)
DDR2_OFF_OFM  = 0x02000000  # OFM 영역 (per-layer offset)

# ═══════════════════════════════════════════════════════════════════════════════
# YOLO 모델 상수
# ═══════════════════════════════════════════════════════════════════════════════
N_ANCHORS  = 3
N_CLASSES  = 60
YOLO_ENTRY = 4 + 1 + N_CLASSES   # 65
INPUT_W = INPUT_H = 256

OBJ_THRESH = 0.24

# ═══════════════════════════════════════════════════════════════════════════════
# Conv layer 테이블
# (hex_id, Co, Ci, kernel_size, acc_len, wgt_blk_offset, bias_word_offset)
#
# wgt_blk_offset  : 이전 layer 의 Co×acc_len 누적 합 (64-byte block 단위)
# bias_word_offset: 이전 layer 의 Co 누적 합 (32-bit word 단위)
# ═══════════════════════════════════════════════════════════════════════════════
CONV_LAYERS = [
    # hex   Co    Ci   kbytes acc  blkOff   biasOff
    # kbytes: 3×3 kernel = 9 bytes/ch, 1×1 kernel = 1 byte/ch
    ('00',  16,   3,   9,   1,       0,       0),
    ('02',  32,  16,   9,   4,      16,      16),
    ('04',  64,  32,   9,   8,     144,      48),
    ('06', 128,  64,   9,  16,     656,     112),
    ('08', 256, 128,   9,  32,    2704,     240),
    ('10', 512, 256,   9,  64,   10896,     496),
    ('12', 256, 512,   1, 128,   43664,    1008),
    ('13', 512, 256,   9,  64,   76432,    1264),
    ('14', 195, 512,   1, 128,  109200,    1776),
    ('17', 128, 256,   1,  64,  134160,    1971),
    ('20', 195, 384,   1,  96,  142352,    2099),
]

# 마지막 layer 이후 누적값 → 전체 크기 계산
_LAST = CONV_LAYERS[-1]
TOTAL_WGT_BLOCKS = _LAST[5] + _LAST[1] * _LAST[4]   # 161072 blocks × 64 bytes
TOTAL_WGT_WORDS  = TOTAL_WGT_BLOCKS * 16             # 2,577,152 words = ~9.8 MB
TOTAL_BIAS_WORDS = _LAST[6] + _LAST[1]               # 2294 words

# ═══════════════════════════════════════════════════════════════════════════════
# UART 헬퍼
# ═══════════════════════════════════════════════════════════════════════════════
def recv_exact(ser, n):
    """n 바이트 정확히 수신 (타임아웃 예외 포함)"""
    buf = b''
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if not chunk:
            raise TimeoutError(
                f"UART 수신 타임아웃 (요청={n}B, 수신={len(buf)}B). "
                f"포트·보드 연결 및 펌웨어 실행 여부 확인."
            )
        buf += chunk
    return buf

def recv_ack(ser, label=''):
    """16-byte ACK 수신 후 내용 반환 (디버그용 label)"""
    ack = recv_exact(ser, 16)
    return ack

# ═══════════════════════════════════════════════════════════════════════════════
# 모드 핸들러
# ═══════════════════════════════════════════════════════════════════════════════
def cmd_hello(ser):
    """MODE_TEST_HELLO: 16-byte 'Hello, World!' 응답 확인"""
    ser.write(bytes([MODE_TEST_HELLO]))
    return recv_ack(ser, 'hello')

def cmd_store_ram(ser, offset, data: bytes, desc=''):
    """MODE_STORE_RAM: DDR2[offset] 에 data (word 단위) 적재

    프로토콜:
      Host→FW : [0x03]
      FW→Host : [16B "  Waiting_CMD   "]
      Host→FW : [4B offset LE][4B word_count LE]
      FW→Host : [16B "  CMD_Receive   "]
      Host→FW : word_count × [4B data LE]
      FW→Host : [16B " Store complete "]
    """
    assert len(data) % 4 == 0, f"데이터 크기가 4-byte 정렬되지 않음: {len(data)}"
    word_count = len(data) // 4

    ser.write(bytes([MODE_STORE_RAM]))
    recv_ack(ser, 'waiting')

    ser.write(struct.pack('<II', offset, word_count))
    recv_ack(ser, 'cmd_recv')

    # 데이터 스트리밍 + 진행률 표시
    total = len(data)
    CHUNK = 4096   # 4 KB 단위 전송
    t0 = time.time()
    sent = 0
    for i in range(0, total, CHUNK):
        chunk = data[i:i + CHUNK]
        ser.write(chunk)
        sent += len(chunk)
        elapsed = time.time() - t0 + 1e-6
        pct = sent * 100 // total
        kbps = sent / 1024 / elapsed
        eta  = (total - sent) / (sent / elapsed) if sent else 0
        print(f'\r  {desc}: {pct:3d}%  {sent//1024}/{total//1024} KB  '
              f'{kbps:.0f} KB/s  ETA {eta:.0f}s   ', end='', flush=True)
    print()

    recv_ack(ser, 'complete')

def cmd_run_engine(ser, timeout_s=300):
    """MODE_RUN_ENGINE: 22-layer 추론 실행, network_done 까지 대기"""
    ser.write(bytes([MODE_RUN_ENGINE]))
    recv_ack(ser, 'engine_run')   # "Engine Run      " (즉시)

    print('  추론 실행 중...', end='', flush=True)
    old_to = ser.timeout
    ser.timeout = timeout_s
    t0 = time.time()
    recv_ack(ser, 'engine_done')  # "Engine complete " (완료 후)
    ser.timeout = old_to
    print(f' 완료 ({time.time()-t0:.1f}초)')

def cmd_concat_l19(ser):
    """MODE_CONCAT_L19: L8 OFM → L18 OFM 직후 DRAM memcpy"""
    ser.write(bytes([MODE_CONCAT_L19]))
    recv_ack(ser, 'concat')   # "Concat Done     "

def cmd_yolo_post(ser):
    """MODE_YOLO_POST: DRAM OFM → Sigmoid/NMS → Detection 목록 수신

    수신 형식:
      [4B n_dets LE]
      n_dets × [4B cls_id(int32) | 4B score(float) | 4B x | 4B y | 4B w | 4B h]
      [16B "Post Done       "]
    """
    ser.write(bytes([MODE_YOLO_POST]))

    n_dets = struct.unpack('<I', recv_exact(ser, 4))[0]
    print(f'  탐지 수: {n_dets}')

    dets = []
    for _ in range(n_dets):
        buf = recv_exact(ser, 24)
        cls_id          = struct.unpack('<i', buf[0:4])[0]
        score, bx, by, bw, bh = struct.unpack('<fffff', buf[4:24])
        dets.append({'cls_id': cls_id, 'score': score,
                     'x': bx, 'y': by, 'w': bw, 'h': bh})

    recv_ack(ser, 'post_done')  # "Post Done       "
    return dets

# ═══════════════════════════════════════════════════════════════════════════════
# 데이터 패킹
# ═══════════════════════════════════════════════════════════════════════════════
def build_weight_buf(param_dir):
    """모든 conv layer weight를 DRAM 포맷으로 패킹 (~9.8 MB 연속 버퍼)

    DRAM 구조 (yolo_engine.v DMA 요구):
      각 64-byte block = filter f, group g (4ch 단위)
        slot 0..3 = channel g*4+0..g*4+3
        각 slot = [kernel bytes (9 or 1)] + [zero pad to 16 bytes]
      block 배치: filter-major → group-major → slot-minor

    DRAM byte offset = (wgt_blk_offset + f*acc_len + g)*64 + s*16
    """
    buf = bytearray(TOTAL_WGT_BLOCKS * 64)   # = TOTAL_WGT_WORDS × 4 bytes

    for hex_id, Co, Ci, kbytes, acc_len, blk_off, _ in CONV_LAYERS:
        path = os.path.join(param_dir, f'CONV{hex_id}_param_weight.hex')
        with open(path) as f:
            raw = bytearray(int(ln.strip(), 16) for ln in f if ln.strip())
        expected = Co * Ci * kbytes
        if len(raw) != expected:
            raise ValueError(
                f'CONV{hex_id}_param_weight.hex 크기 불일치: {len(raw)} != {expected}')

        for fi in range(Co):
            fi_off = fi * Ci * kbytes       # hex raw 내 filter fi 시작 index
            for g in range(acc_len):
                block_byte = (blk_off + fi * acc_len + g) * 64
                for s in range(4):          # 4 slots per group (4 channels)
                    ch = g * 4 + s
                    slot_byte = block_byte + s * 16
                    if ch < Ci:
                        k0 = fi_off + ch * kbytes
                        buf[slot_byte: slot_byte + kbytes] = raw[k0: k0 + kbytes]
                    # 나머지 바이트는 0 (bytearray 기본값)

    size_kb = len(buf) // 1024
    print(f'  Weight 버퍼: {size_kb} KB ({TOTAL_WGT_BLOCKS:,} blocks)')
    return bytes(buf)

def build_bias_buf(param_dir):
    """모든 conv layer bias를 연속 DRAM 포맷으로 패킹

    각 bias: 16-bit hex (signed) → sign-extend to 32-bit → LE 4-byte word
    저장 순서: L0, L2, L4, ..., L20 연속 (bias_word_offset 기준)
    """
    buf = bytearray(TOTAL_BIAS_WORDS * 4)
    word_off = 0

    for hex_id, Co, *_ in CONV_LAYERS:
        path = os.path.join(param_dir, f'CONV{hex_id}_param_biases.hex')
        with open(path) as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                v = int(ln, 16)
                signed = v if v < 0x8000 else v - 0x10000   # 16-bit sign extend
                struct.pack_into('<i', buf, word_off * 4, signed)
                word_off += 1

    if word_off != TOTAL_BIAS_WORDS:
        raise ValueError(f'bias word 수 불일치: {word_off} != {TOTAL_BIAS_WORDS}')
    print(f'  Bias 버퍼:   {len(buf)} bytes ({word_off} entries)')
    return bytes(buf)

def pack_ifm(img_path):
    """이미지 → L0 IFM DRAM 포맷 변환

    DRAM 128-bit entry (16 bytes): 4 pixels × 4 channels (ch3 = 0 padding)
      byte b = col_l*4 + ch_l = pixel(row, col_b*4+col_l), channel ch_l

    Word 배치 (row-major):
      dram_word[row*W_BLOCKS*4 + col_b*4 + col_l] =
        {0x00, pixel_B, pixel_G, pixel_R}  (LE, ch3=0)
    """
    if not HAS_PIL:
        raise RuntimeError(
            'Pillow/numpy 없음 — pip install Pillow numpy')

    img = Image.open(img_path).resize((INPUT_W, INPUT_H), Image.BILINEAR)
    if img.mode != 'RGB':
        img = img.convert('RGB')
    pixels = np.array(img, dtype=np.uint8)   # shape (H, W, 3): RGB

    W_BLOCKS = INPUT_W // 4
    buf = bytearray(INPUT_H * W_BLOCKS * 4 * 4)   # 256 × 64 entries × 16 bytes/entry
    word_off = 0

    for row in range(INPUT_H):
        for col_b in range(W_BLOCKS):
            for col_l in range(4):
                col = col_b * 4 + col_l
                r = int(pixels[row, col, 0])   # ch0 (Red)
                g = int(pixels[row, col, 1])   # ch1 (Green)
                b = int(pixels[row, col, 2])   # ch2 (Blue)
                word = r | (g << 8) | (b << 16)   # ch3 = 0
                struct.pack_into('<I', buf, word_off * 4, word)
                word_off += 1

    print(f'  IFM 버퍼:    {len(buf)//1024} KB (256×256 RGB → 4px/entry 인터리브)')
    return bytes(buf)

# ═══════════════════════════════════════════════════════════════════════════════
# 결과 시각화
# ═══════════════════════════════════════════════════════════════════════════════
def load_names(names_path):
    """클래스 이름 파일 로드 (N_CLASSES 개까지 패딩)"""
    with open(names_path) as f:
        names = [ln.strip() for ln in f if ln.strip()]
    while len(names) < N_CLASSES:
        names.append(f'class_{len(names)}')
    return names

def visualize(img_path, dets, names, out_path):
    """탐지 결과를 원본 이미지에 오버레이하여 저장"""
    if not HAS_PIL:
        print('[경고] Pillow 없음 — 시각화 스킵')
        return

    img = Image.open(img_path).convert('RGB')
    draw = ImageDraw.Draw(img)
    iw, ih = img.size

    try:
        font = ImageFont.truetype(
            '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)
    except Exception:
        font = ImageFont.load_default()

    for det in dets:
        if det['score'] <= 0:
            continue
        bx, by, bw, bh = det['x'], det['y'], det['w'], det['h']
        x1 = max(0, int((bx - bw * 0.5) * iw))
        y1 = max(0, int((by - bh * 0.5) * ih))
        x2 = min(iw - 1, int((bx + bw * 0.5) * iw))
        y2 = min(ih - 1, int((by + bh * 0.5) * ih))

        cls_id = det['cls_id']
        label  = names[cls_id] if 0 <= cls_id < len(names) else f'cls{cls_id}'
        # 클래스별 색상 (간이 hash)
        hue    = (cls_id * 37) % 256
        color  = (hue, (hue + 90) % 256, (hue + 170) % 256)

        draw.rectangle([x1, y1, x2, y2], outline=color, width=2)
        draw.rectangle([x1, y1 - 16, x1 + len(label) * 8 + 4, y1], fill=color)
        draw.text((x1 + 2, y1 - 15),
                  f'{label} {det["score"]:.2f}', fill=(255, 255, 255), font=font)

    img.save(out_path)
    print(f'  결과 이미지: {out_path}')

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════
def main():
    # 기본 경로: host.py 는 yolohw/firmware/ 에 위치
    script_dir    = Path(__file__).resolve().parent
    repo_root     = script_dir.parent.parent
    default_param = str(repo_root / 'skeleton' / 'bin' / 'log_param')
    default_names = str(repo_root / 'skeleton' / 'bin' / 'yolohw.names')

    parser = argparse.ArgumentParser(
        description='YOLOv2 FPGA 보드 Host 클라이언트 (Phase 3)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--port',         default='/dev/ttyUSB1',
                        help='UART 포트 (기본: /dev/ttyUSB1)')
    parser.add_argument('--baud',         type=int, default=921600,
                        help='통신 속도 (기본: 921600)')
    parser.add_argument('--timeout',      type=int, default=15,
                        help='UART 수신 타임아웃 초 (기본: 15)')
    parser.add_argument('--image',        default=None,
                        help='입력 이미지 경로 (--hello 제외 시 필수)')
    parser.add_argument('--weights',      default=default_param,
                        help=f'weight hex 파일 디렉토리 (기본: {default_param})')
    parser.add_argument('--names',        default=default_names,
                        help=f'클래스 이름 파일 (기본: {default_names})')
    parser.add_argument('--output',       default=None,
                        help='결과 이미지 저장 경로 (미지정 시 자동)')
    parser.add_argument('--hello',        action='store_true',
                        help='UART 통신 테스트만 수행')
    parser.add_argument('--skip-weights', action='store_true',
                        help='weight/bias DRAM 적재 스킵 (이미 적재된 경우)')
    args = parser.parse_args()

    # ── UART 연결 ──────────────────────────────────────────────────────────────
    print(f'[연결] {args.port} @ {args.baud} baud')
    try:
        ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    except serial.SerialException as e:
        print(f'[오류] UART 연결 실패: {e}', file=sys.stderr)
        sys.exit(1)
    time.sleep(0.3)   # 연결 안정화

    # ── Hello 테스트 ───────────────────────────────────────────────────────────
    print('[1] 통신 확인 (Hello)...')
    try:
        ack = cmd_hello(ser)
        print(f'    응답: {ack!r}')
    except TimeoutError as e:
        print(f'[오류] {e}', file=sys.stderr)
        ser.close()
        sys.exit(1)

    if args.hello:
        ser.close()
        print('[완료] Hello 테스트 성공')
        return

    # ── 이미지 인수 확인 ───────────────────────────────────────────────────────
    if not args.image:
        parser.error('--image 경로를 지정하세요 (--hello 옵션 사용 시 불필요)')
    if not os.path.isfile(args.image):
        print(f'[오류] 이미지 파일 없음: {args.image}', file=sys.stderr)
        ser.close()
        sys.exit(1)

    # ── Weight + Bias 적재 (최초 1회) ─────────────────────────────────────────
    if not args.skip_weights:
        print('[2] Weight 버퍼 패킹 (전체 11 conv layer)...')
        wgt_buf = build_weight_buf(args.weights)
        print('[3] Weight DRAM 적재 (~9.8 MB, 수 분 소요)...')
        cmd_store_ram(ser, DDR2_OFF_WGT, wgt_buf, 'Weight')

        print('[4] Bias 버퍼 패킹 + DRAM 적재...')
        bias_buf = build_bias_buf(args.weights)
        cmd_store_ram(ser, DDR2_OFF_BIAS, bias_buf, 'Bias')
    else:
        print('[2] Weight 적재 스킵 (--skip-weights)')
        print('[4] Bias 적재 스킵')

    # ── IFM 적재 ───────────────────────────────────────────────────────────────
    print(f'[5] IFM 적재: {args.image}')
    ifm_buf = pack_ifm(args.image)
    cmd_store_ram(ser, DDR2_OFF_IFM, ifm_buf, 'IFM')

    # ── 1차 추론: L0 → L21 전 layer 완주 ─────────────────────────────────────
    print('[6] 1차 추론 (22-layer)...')
    cmd_run_engine(ser)

    # ── L19 concat: L8 OFM(16384 words)을 L18 OFM 직후에 복사 ─────────────────
    print('    L19 concat (L8 OFM → L18 OFM 직후)...')
    cmd_concat_l19(ser)

    # ── 2차 추론: concat 반영 후 L20 재계산 ───────────────────────────────────
    print('    2차 추론 (L20 재계산)...')
    cmd_run_engine(ser)

    # ── YOLO 후처리 ────────────────────────────────────────────────────────────
    print('[7] YOLO 후처리 (Sigmoid/Softmax/NMS)...')
    dets = cmd_yolo_post(ser)
    ser.close()

    # ── 결과 출력 ──────────────────────────────────────────────────────────────
    names = load_names(args.names)
    print('\n=== 탐지 결과 ===')
    valid_dets = [d for d in dets if d['score'] > 0]
    if not valid_dets:
        print('  (탐지 결과 없음)')
    for i, det in enumerate(valid_dets):
        cls_id  = det['cls_id']
        cls_name = names[cls_id] if 0 <= cls_id < len(names) else f'cls{cls_id}'
        print(f'  [{i}] {cls_name:<35s}  score={det["score"]:.3f}  '
              f'xywh=({det["x"]:.3f},{det["y"]:.3f},{det["w"]:.3f},{det["h"]:.3f})')

    # ── 시각화 ─────────────────────────────────────────────────────────────────
    if HAS_PIL:
        if args.output:
            out_path = args.output
        else:
            base, ext = os.path.splitext(args.image)
            out_path = base + '-det' + (ext or '.png')
        visualize(args.image, valid_dets, names, out_path)
    else:
        print('[경고] Pillow 없음 — 시각화 스킵. pip install Pillow numpy')

    print('\n[완료]')

if __name__ == '__main__':
    main()
