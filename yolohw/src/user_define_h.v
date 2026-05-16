//================================================================
// user_define_h.v — 전역 매크로 정의 파일
//
// 프로젝트 전체에서 `include "user_define_h.v" 로 포함된다.
// 합성 vs 시뮬레이션 모드를 이 파일 하나로 전환한다.
//================================================================

//----------------------------------------------------------------
// BRAM 관련 상수
//   - NUM_BRAMS  : 프로젝트에서 사용하는 BRAM 인스턴스 수 (16개)
//   - BRAM_WIDTH : 한 BRAM 인스턴스의 데이터 폭 (128 bit)
//                  → 총 유효 대역폭 = 128 × 16 = 2048 bit/cycle 가능
//   - BRAM_DELAY : BRAM read latency (읽기 요청 후 데이터 유효까지 cycle 수)
//                  Vivado Block Memory Generator 기본값 = 1 (output register 미사용)
//                  → 본 프로젝트는 별도 pipeline reg 로 보상 (ifm_line_buf 등 참조)
//----------------------------------------------------------------
//`define PRELOAD     // (미사용) TB 사전 적재 모드
//`define DEBUG       // (미사용) 디버그 출력 활성화
`define NUM_BRAMS   16
`define BRAM_WIDTH  128
`define BRAM_DELAY  3


// -------------------------------------------------------------
// FPGA 합성 모드 전환 매크로
//
//   ▶ 합성(Vivado synthesis) 시:
//       1. 아래 줄의 주석을 해제 → `define FPGA 1
//       2. Vivado IP Catalog 에서 다음 IP 를 생성해야 합니다:
//          ┌──────────────────────────────────────────────────────┐
//          │ IP 이름              폭(bit)  깊이(entry)  타입      │
//          │ xbip_dsp48_macro_0   (mul.v)              Multiplier│
//          │ spram_512x72         72       512         Single Port│
//          │ spram_4096x32        32       4096        Single Port│
//          │ spram_65536x32       32       65536       Single Port│
//          │ spram_2048x128       128      2048        Single Port│
//          │ spram_128x32         32       128         Single Port│
//          │ dpram_512x72         72       512         Simple DP  │
//          │ dpram_4096x32        32       4096        Simple DP  │
//          │ dpram_65536x32       32       65536       Simple DP  │
//          │ dpram_2048x128       128      2048        Simple DP  │
//          │ dpram_8192x32        32       8192        Simple DP  │
//          └──────────────────────────────────────────────────────┘
//          (상세 설정은 gen_bram_ips.tcl 참조)
//
//   ▶ 시뮬레이션(Vivado Simulator / Verilator) 시:
//       이 줄을 주석 처리 상태로 유지 → behavioral 모델 동작
//       (spram_wrapper / dpram_wrapper 의 reg 배열 모델 사용,
//        mul.v 는 $signed 곱셈 4-stage pipeline 모델 사용)
//
//   ⚠️  주의: FPGA 매크로를 활성화한 채 시뮬레이션하면
//             존재하지 않는 IP 참조로 elaboration 실패.
// -------------------------------------------------------------

//`define FPGA	1

// -------------------------------------------------------------
// 디버그용 DMA write 시각화 (선택)
//   활성화 시 DMA write 데이터를 $display 로 출력.
//   TB 파형 분석과 병행할 때 유용하나 시뮬레이션 속도 저하 주의.
// -------------------------------------------------------------

// Uncomment to visualize the data from DMA write
//`define CHECK_DMA_WRITE 1

//}}}
