# CLAUDE.md — YOLOv2 FPGA Accelerator (베타트론)

본 파일은 중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회(팀 베타트론)를 위한 Claude Code의 최우선 작업 가이드입니다. 코드 작성 및 수정 전 반드시 아래 규칙을 숙지하십시오.

## 1. 프로젝트 기본 정보
- 타겟 보드: Nexys A7-100T (Xilinx Artix-7)
- 최종 목표: 22-layer YOLOv2 모델 전체를 FPGA에서 추론 가능한 가속기 SoC 구현 (최소 5 fps 이상)
- 상세 아키텍처 및 네트워크 구조: 필요시 ARCHITECTURE.md 파일을 참조할 것.

## 2. 🚨 치명적 에러 방지 규칙 (가장 중요)
이전 작업에서 자주 발생한 에러들입니다. 절대 반복하지 마십시오.

1. FPGA 매크로 확인: yolohw/src/define.v의 FPGA 매크로는 시뮬레이션 시 주석 처리, 합성 시 활성화해야 합니다. DSP48/BRAM IP는 합성 시 반드시 명시적으로 인스턴스화해야 합니다 (a*b+c 추론 사용 금지).
2. TB 경로 하드코딩 주의: define.v 및 user_param_h.v에 절대경로(C:/yolohw/...)가 하드코딩되어 있습니다. 파일 읽기 실패 시 mklink /J C:\yolohw "C:\AIX Project\yolohw"로 정션을 생성하거나 경로를 수정하십시오.
3. Layer 11 특수 처리: Layer 11은 MaxPool stride=1입니다. 다른 maxpool과 동일하게 처리하면 크기가 깨집니다. 반드시 stride를 레이어 파라미터로 처리하십시오.
4. 연산 모듈 추가 금지 (Route/Upsample/1x1 Conv):
   - Route/Upsample: RTL 연산 모듈을 새로 만들지 말고, 컨트롤러(FSM)의 메모리 주소 제어(DMA)로만 해결하십시오.
   - 1x1 Conv: 기존 3x3 conv_unit을 재사용하되, num_cycles와 0 패딩만 다르게 FSM에서 분기하십시오.
5. SystemVerilog 구문 사용 금지: fork, join_any 등은 Vivado plain Verilog 합성에서 실패합니다. while 폴링 루프로 대체하십시오.
6. 디스크 용량 초과 방지: Vivado 시뮬레이션 시 log_all_signals 옵션은 반드시 OFF로 설정하여 .xilwvdat 파일 폭증을 막으십시오.
7. Bias 부호 확장: 16-bit hex를 32-bit SPRAM에 적재할 때 단순 zero-extend가 아닌 반드시 sign-extend 하십시오.

## 3. 핵심 설계 규칙
- 데이터 표현: NCHW (CHW byte order), C 레퍼런스와 100% 동일하게 유지.
- MAC 파이프라인 레이턴시: 마지막 vld_i부터 output_valid까지 정확히 11 cycle.
- 128-bit 정렬: 3x3 conv의 곱셈은 소프트웨어 hex 생성 시점에 0 패딩하여 16의 배수로 정렬됨을 전제로 설계하십시오.
- Descaling 결과: Float 복원이 아닌 0~255 uint8 클리핑으로 처리.
- 레이어 파라미터: user_param_h.v의 배열에 정의하고 FSM이 인덱스로 참조하도록 구성.

## 4. 시뮬레이션 및 빌드 명령어
- C 골든 레퍼런스 생성: cd skeleton\bin -> script-wins-aix2024-test-one-quantized.cmd
- Vivado 프로젝트 재생성: yolohw/fpga/에서 source yolohw.tcl 및 source gen_bram_ips.tcl 실행
- 합성 및 비트스트림: launch_runs synth_1 -jobs 4, launch_runs impl_1 -to_step write_bitstream -jobs 4

## 5. Claude 행동 원칙
1. 코드 수정 원칙: 수정 전 항상 해당 모듈의 .v 파일 전체를 읽으십시오. 사용자가 코드 수정을 요구하면 일부 스니펫만 주지 말고 수정된 코드 전체를 제공하십시오.
2. 한국어 및 존댓말 사용: 설명은 항상 한국어(존댓말)로 명확하고 상세하게 작성하되, 코드 내 주석은 영어를 사용해도 무방합니다.
3. 점진적 제안: 한 번에 한 가지만 구체적으로 변경하고, 변경 이유와 기존과의 차이점을 명확히 설명하십시오.
4. 동기화: 신호나 포트를 추가할 경우 yolo_engine.v, user_define_h.v, 관련 TB를 모두 일관성 있게 업데이트하십시오.