#!/usr/bin/env bash
# Stop 훅: 진화 강제 게이트.
# 사용 신호가 임계값을 넘었는데 진화가 실행되지 않은 채 턴이 끝나려 하면
# 종료를 차단(exit 2)하고 context-evolve 실행을 지시한다.
#
# "작업 후 스킬을 실행하라"는 주입 지시는 확률적 보장뿐이라는 것이 실측으로
# 확인되어(헤드리스 세션에서 스킵됨), 이 게이트로 결정론적 보장으로 격상했다.
#
# 루프 안전성 (이중 방어):
#   1) stop_hook_active=true(이미 이 게이트로 재개된 턴의 종료)면 무조건 통과
#   2) 진화가 실행되면 스킬 절차상 신호 파일이 소진되므로 임계 조건 자체가
#      해제된다 — 즉 차단은 임계값 교차당 최대 1회다.
# python3가 없으면 차단하지 않는다 (루프 가드 불가 시 강제도 하지 않는 fail-safe).

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -f .cursor-context/project-context.md ] || exit 0

IN=$(cat 2>/dev/null || true)
active=$(printf '%s' "$IN" | python3 -c 'import json,sys
try:
    print(1 if json.load(sys.stdin).get("stop_hook_active") else 0)
except Exception:
    print(1)' 2>/dev/null || echo 1)
[ "$active" = "1" ] && exit 0

[ -f .claude/skills/context-evolve/SKILL.md ] || exit 0

fb=$(grep -c . .cursor-context/context-feedback.jsonl 2>/dev/null || echo 0)
mt=$(grep -c . .cursor-context/metrics.jsonl 2>/dev/null || echo 0)
if [ "${fb:-0}" -ge 5 ] || [ "${mt:-0}" -ge 300 ]; then
  echo "축적된 사용 신호(피드백 ${fb}건, 메트릭 ${mt}건)가 임계값을 넘었습니다. 지금 context-evolve 스킬 절차에 따라 .cursor-context/project-context.md 를 개선하세요: 백업 → 신호 분석 → 재작성 → context-benchmark.sh 게이트 → 신호 파일 소진(백업으로 이동) → evolve-log 기록. CLAUDE.md·훅·스킬·설정은 절대 수정하지 마세요. 단, 이 세션에서 파일 쓰기가 불가능하거나 부적절하면(plan 모드, 읽기 전용) 아무것도 하지 말고 그대로 종료하세요." >&2
  exit 2
fi
exit 0
