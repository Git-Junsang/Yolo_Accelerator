# testbench/unused — 비활성 테스트벤치 보관함

활성 시뮬레이션 흐름(Vivado `vivado_yolohw.xpr` 의 sim_1 fileset)에는 포함되지 않지만,
삭제하기엔 회귀 검증 가치가 남아 보존하는 TB 를 모읍니다.

> 구분 기준
> - **활성 TB**: `vivado_yolohw.xpr` 가 로드하는 12개 verify TB
>   (`l0/l1/l2/l5/l10/l11/l12/l13/l14/l17/l18/l20_verify_tb.v`).
> - **unused/**: 위 활성 집합에는 없지만 의도적으로 보존하는 TB.
> - **.recycle_bin/**: 복원 가능성이 낮아 소프트 삭제한 파일 (영구 삭제 후보).

---

## 2026-05-24 — non-streaming verify TB 3종 이관

이동 파일:
- `l0_nonstreaming_verify_tb.v`
- `l1_nonstreaming_verify_tb.v`
- `l2_nonstreaming_verify_tb.v`

이관 이유:
- 라인버퍼 오버플로우(4096엔트리 필요 vs 2048용량) 수정 이후 conv 경로가
  **streaming FSM** 으로 전환됨. 현재 active 검증은 streaming 버전
  (`l0/l1/l2_verify_tb.v`) 이며 `.xpr` 도 이 쪽만 로드함.
- non-streaming 버전은 streaming 전환 **이전 동작과의 비교/디버깅용** 으로만 가치가 있어
  활성 트리에서 분리하되 폐기하지 않고 보존.

복원 절차:
1. 이 폴더에서 `yolohw/testbench/` 로 다시 이동.
2. Vivado: Add Sources → Add or Create Simulation Sources 로 `.xpr` sim set 에 재추가.

참고: `documents/technical_reference/14_testbench_per_layer.md`,
`documents/study_guide/20_testbench_per_layer.md` 에 non-streaming TB 언급이 남아 있을 수 있음
(경로가 `unused/` 로 변경됨).
