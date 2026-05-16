//================================================================
// define.v — [LEGACY] 구 전역 정의 파일
//
// ⚠️  이 파일은 레거시(legacy) 파일입니다.
//     현재 프로젝트에서는 사용하지 않으며 Vivado 소스 목록에 포함하지 마십시오.
//     대체 파일:
//       - `include "user_define_h.v"  : 매크로 정의 (NUM_BRAMS, FPGA 토글 등)
//       - `include "user_param_h.v"   : TB 전용 파라미터 정의
//
// 원래 역할:
//   이전 버전에서 user_define_h.v 와 user_param_h.v 의 내용을 하나의 파일에
//   합쳐 관리하던 include 파일.
//   합성 / 시뮬레이션 모드 전환 매크로와 TB 파라미터를 모두 포함하고 있었음.
//
// 현재 상태:
//   yolo_engine.v, mac_kern.v 등 활성 RTL 파일은 이 파일을 include하지 않음.
//   mul.v 만 `include "define.v" 를 사용하지만, 그 용도는 FPGA 매크로 참조이며
//   현재 user_define_h.v 로 대체됨.
//================================================================

//`define PRELOAD    // (미사용) TB 사전 적재 모드
//`define DEBUG      // (미사용) 디버그 출력 활성화

// BRAM 관련 상수 (user_define_h.v 에서 동일하게 정의됨)
`define NUM_BRAMS   16   // BRAM 인스턴스 수
`define BRAM_WIDTH  128  // BRAM 인스턴스당 데이터 폭 (bit)
`define BRAM_DELAY  3    // BRAM 읽기 latency (cycle)

// -------------------------------------------------------------
// FPGA 합성 모드 전환 매크로
//   ▶ 합성 시: 아래 주석 해제 → `define FPGA 1
//   ▶ 시뮬레이션 시: 주석 유지
//
//   NOTE: 현재 프로젝트는 user_define_h.v 에서 이 매크로를 관리.
//         이 파일의 FPGA 매크로와 충돌하지 않도록 동시에 include 금지.
// -------------------------------------------------------------
// `define FPGA 1

// -------------------------------------------------------------
// TB 전용 파라미터 (user_param_h.v 에서 동일하게 정의됨)
//   - 경로는 Vivado 시뮬레이션 working directory 기준 상대경로
//   - Windows Vivado 에서는 '/' 슬래시도 동작
//   IMPORTANT NOTE**:
//       1. Correct the directories with your path
//       2. Use directories without blank space
// -------------------------------------------------------------
//{{{

// =====================================================================
// 입력 IFM(Input Feature Map) 관련 파라미터
//   - Layer 0: 256×256 RGB 이미지 입력
// =====================================================================
parameter IFM_WIDTH         = 256;   // 이미지 가로 픽셀 수
parameter IFM_HEIGHT        = 256;   // 이미지 세로 픽셀 수
parameter IFM_CHANNEL       = 3;     // RGB 3채널

parameter IFM_DATA_SIZE     = IFM_HEIGHT*IFM_WIDTH*2;   // = 131072 halfword (16-bit 표현)
parameter IFM_WORD_SIZE     = 32/2;                      // = 16 bit (halfword)
parameter IFM_DATA_SIZE_32  = IFM_HEIGHT*IFM_WIDTH;     // = 65536 word (32-bit 표현)
parameter IFM_WORD_SIZE_32  = 32;                        // = 32 bit (word)

// =====================================================================
// Layer 0 가중치(Weight) 파라미터
//   CONV00: 3×3 커널, 입력 채널=3, 출력 채널=16
// =====================================================================
parameter Fx = 3, Fy = 3;   // 커널 크기 3×3
parameter Ni = 3, No = 16;  // 입력 채널=3, 출력 채널=16
// 총 가중치 = 3×3×3×16 = 432
parameter WGT_DATA_SIZE = Fx*Fy*Ni*No;  // = 432
parameter WGT_WORD_SIZE = 32;            // 32 bit/word

// =====================================================================
// 입력 hex 파일 경로 (TB에서 $readmemh로 로드)
// =====================================================================
parameter IFM_FILE_32 = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_32b.hex";
parameter IFM_FILE    = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_16b.hex";
parameter WGT_FILE    = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_weight.hex";

// =====================================================================
// 출력 BMP 파일 경로 (TB에서 채널별 이미지 출력)
// =====================================================================
// CONV00 입력 채널별 이미지
parameter CONV_INPUT_IMG00 = "../../../../../../sim/inout_data_hw/CONV00_input_ch00.bmp";
parameter CONV_INPUT_IMG01 = "../../../../../../sim/inout_data_hw/CONV00_input_ch01.bmp";
parameter CONV_INPUT_IMG02 = "../../../../../../sim/inout_data_hw/CONV00_input_ch02.bmp";
parameter CONV_INPUT_IMG03 = "../../../../../../sim/inout_data_hw/CONV00_input_ch03.bmp";

// CONV00 출력 채널별 이미지 (GOLDEN 비교용)
parameter CONV_OUTPUT_IMG00 = "../../../../../../sim/inout_data_hw/CONV00_output_ch00.bmp";
parameter CONV_OUTPUT_IMG01 = "../../../../../../sim/inout_data_hw/CONV00_output_ch01.bmp";
parameter CONV_OUTPUT_IMG02 = "../../../../../../sim/inout_data_hw/CONV00_output_ch02.bmp";
parameter CONV_OUTPUT_IMG03 = "../../../../../../sim/inout_data_hw/CONV00_output_ch03.bmp";

// DMA write 시각화 디버그 매크로 (활성화 시 시뮬레이션 속도 저하 주의)
// Uncomment to visualize the data from DMA write
//`define CHECK_DMA_WRITE 1

//}}}
