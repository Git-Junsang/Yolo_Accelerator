// -------------------------------------------------------------
// user_param_h.v — TB(Testbench) 전용 파라미터 정의
//
// 이 파일은 합성 대상이 아닌 시뮬레이션 전용 파라미터를 담습니다.
// yolo_engine_tb.v 등 TB 파일에서 `include "user_param_h.v" 로 포함.
//
// 사용 전 반드시 확인:
//   1. 파일 경로(IFM_FILE, WGT_FILE 등)를 로컬 환경에 맞게 수정하세요.
//   2. 경로에 공백(빈 칸)이 포함되면 $readmemh 실패 → 공백 없는 경로 사용.
// -------------------------------------------------------------
// IMPORTANT NOTE**:
//      1. Correct the directories with your path
//      2. Use directories without blank space
//{{{

// =====================================================================
// 입력 IFM(Input Feature Map) 관련 파라미터
//   - Layer 0 기준: 256×256 RGB 이미지 입력
// =====================================================================
parameter IFM_WIDTH         = 256;          // 이미지 가로 픽셀 수
parameter IFM_HEIGHT        = 256;          // 이미지 세로 픽셀 수
parameter IFM_CHANNEL       = 3;            // RGB 3 채널

// Layer 0 IFM 의 총 데이터 크기 (16-bit 표현 기준)
parameter IFM_DATA_SIZE     = IFM_HEIGHT*IFM_WIDTH*2;    // = 131072 halfword
parameter IFM_WORD_SIZE     = 32/2;                       // 16 bit (halfword 단위)

// Layer 0 IFM 의 총 데이터 크기 (32-bit word 기준)
parameter IFM_DATA_SIZE_32  = IFM_HEIGHT*IFM_WIDTH;      // = 65536 word
parameter IFM_WORD_SIZE_32  = 32;                         // 32 bit (word 단위)

// =====================================================================
// Layer 0 가중치(Weight) 파라미터
//   CONV00: 3×3 커널, Ci=3, Co=16
// =====================================================================
parameter Fx = 3, Fy = 3;   // 커널 크기 3×3
parameter Ni = 3, No = 16;  // 입력 채널=3, 출력 채널=16
// 총 가중치 개수 = Fx × Fy × Ni × No = 3×3×3×16 = 432
parameter WGT_DATA_SIZE     = Fx*Fy*Ni*No;   // = 432
parameter WGT_WORD_SIZE     = 32;             // 32 bit (word 단위)


// =====================================================================
// 입력 hex 파일 경로 (TB 에서 $readmemh 로 로드)
//   - 경로는 Vivado 시뮬레이션 working directory 기준 상대경로.
//   - Windows Vivado 환경에서는 '/' 슬래시도 동작함.
// =====================================================================
// 32-bit packed IFM (pixel 4개 묶음 → 4 ch × 8bit = 32bit)
parameter IFM_FILE_32        = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_32b.hex";
// 16-bit IFM (halfword 단위, 양자화 전 중간 표현 확인용)
parameter IFM_FILE           = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_16b.hex";
// Layer 0 가중치 hex (8-bit INT8, filter-major 순서)
parameter WGT_FILE           = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_weight.hex";

// =====================================================================
// 출력 BMP 파일 경로 (TB 에서 $writememh 또는 custom task 로 출력)
//   채널별로 분리된 grayscale BMP 형태로 확인 가능.
// =====================================================================
// CONV00 입력 채널 별 이미지
parameter CONV_INPUT_IMG00   = "../../../../../../sim/inout_data_hw/CONV00_input_ch00.bmp";
parameter CONV_INPUT_IMG01   = "../../../../../../sim/inout_data_hw/CONV00_input_ch01.bmp";
parameter CONV_INPUT_IMG02   = "../../../../../../sim/inout_data_hw/CONV00_input_ch02.bmp";
parameter CONV_INPUT_IMG03   = "../../../../../../sim/inout_data_hw/CONV00_input_ch03.bmp";

// CONV00 출력 채널 별 이미지 (GOLDEN과 비교용)
parameter CONV_OUTPUT_IMG00  = "../../../../../../sim/inout_data_hw/CONV00_output_ch00.bmp";
parameter CONV_OUTPUT_IMG01  = "../../../../../../sim/inout_data_hw/CONV00_output_ch01.bmp";
parameter CONV_OUTPUT_IMG02  = "../../../../../../sim/inout_data_hw/CONV00_output_ch02.bmp";
parameter CONV_OUTPUT_IMG03  = "../../../../../../sim/inout_data_hw/CONV00_output_ch03.bmp";

// =====================================================================
// SRAM (spram_wrapper) 파라미터 — TB 에서 독립 사용 시 참조
// =====================================================================
parameter DW            = 32;       // 워드당 데이터 비트 폭
parameter AW            = 16;       // 주소 비트 폭 (최대 2^16 = 65536 엔트리)
parameter DEPTH         = 65536;    // 총 엔트리 수
parameter N_DELAY       = 1;        // BRAM read latency (clk cycle)
                                    // Vivado BMG default = 1 (no output register)

// =====================================================================
// 범용 버퍼 파라미터 (conv_top 등 내부 버퍼 크기)
// =====================================================================
parameter BUFF_WIDTH    = 32;                        // 버퍼 데이터 폭 (bit)
parameter BUFF_DEPTH    = 4096;                      // 버퍼 깊이 (엔트리)
parameter BUFF_ADDR_W   = $clog2(BUFF_DEPTH);        // 주소 비트 폭 = 12 bit
//}}}
