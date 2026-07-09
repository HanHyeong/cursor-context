#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_<lang>_<key> 변수들은 msg()의 ${!varname} 간접 참조로만 쓰인다
# Stop 훅: 진화 강제 게이트.
# 사용 신호가 임계값을 넘었는데 진화가 실행되지 않은 채 턴이 끝나려 하면
# 종료를 차단(exit 2)하고 context-evolve 실행을 지시한다.
#
# "작업 후 스킬을 실행하라"는 주입 지시는 확률적 보장뿐이라는 것이 실측으로
# 확인되어(헤드리스 세션에서 스킵됨), 이 게이트로 결정론적 보장으로 격상했다.
#
# 루프 안전성 (삼중 방어):
#   1) stop_hook_active=true(이미 이 게이트로 재개된 턴의 종료)면 무조건 통과
#   2) 진화가 실행되면 스킬 절차상 신호 파일이 소진되므로 임계 조건 자체가
#      해제된다 — 즉 차단은 임계값 교차당 최대 1회다.
#   3) 세션 단위 sentinel(.cursor-context/.gate-fired-<session_id>): 진화를
#      건너뛴 세션(plan 모드, 읽기 전용 등)에서는 (2)의 신호 소진이 일어나지
#      않아 다음 턴의 첫 Stop마다 다시 차단될 수 있었다. sentinel이 있으면
#      같은 세션 안에서는 무조건 통과시켜 "세션당 최대 1회"를 보장한다.
#      새 세션에서는 SessionStart 훅(session-context.sh)이 오래된 sentinel을
#      정리하므로 다시 1회 차단된다.
# python3가 없으면 차단하지 않는다 (루프 가드 불가 시 강제도 하지 않는 fail-safe).

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
# 이 스크립트 자신이 어디 있는지로 형제 스크립트(예: context-fingerprint.sh,
# lib-config.sh)를 찾는다 — install.sh 배치($CLAUDE_PROJECT_DIR/.claude/hooks/)와
# 플러그인 배치($CLAUDE_PLUGIN_ROOT/hooks/) 둘 다에서 항상 옳다. 계산 실패 시에만
# 예전 방식(프로젝트 루트 기준 고정 경로)으로 폴백한다.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks"

command -v python3 >/dev/null 2>&1 || exit 0
[ -f .cursor-context/project-context.md ] || exit 0

# 기본값을 먼저 설정한 뒤 .cursor-context/config가 있으면 그 값으로 덮어쓴다
# (lib-config.sh가 없거나 로드 실패해도 아래 기본값으로 정상 동작한다).
FEEDBACK_THRESHOLD=5
METRICS_THRESHOLD=300
CTX_LANG=en
# shellcheck disable=SC1091
. "$HOOK_DIR/lib-config.sh" 2>/dev/null || true

MSG_en_block="Accumulated usage signal (feedback: %s entries, metrics: %s lines) crossed the threshold. Follow the context-evolve skill procedure now to improve .cursor-context/project-context.md: backup -> analyze signals -> rewrite -> context-benchmark.sh gate -> consume signal files (move to backup) -> record in evolve-log. Never modify CLAUDE.md, hooks, skills, or settings. If writing is impossible or inappropriate in this session (plan mode, read-only), do nothing and just let the turn end."
MSG_ko_block="축적된 사용 신호(피드백 %s건, 메트릭 %s건)가 임계값을 넘었습니다. 지금 context-evolve 스킬 절차에 따라 .cursor-context/project-context.md 를 개선하세요: 백업 → 신호 분석 → 재작성 → context-benchmark.sh 게이트 → 신호 파일 소진(백업으로 이동) → evolve-log 기록. CLAUDE.md·훅·스킬·설정은 절대 수정하지 마세요. 단, 이 세션에서 파일 쓰기가 불가능하거나 부적절하면(plan 모드, 읽기 전용) 아무것도 하지 말고 그대로 종료하세요."

# ${!varname} 간접 참조로 언어별 메시지를 고른다 (bash 3.2도 지원 — macOS 기본 bash 호환).
msg() {
  key="$1"
  varname="MSG_${CTX_LANG}_${key}"
  printf '%s\n' "${!varname}"
}

IN=$(cat 2>/dev/null || true)
info=$(printf '%s' "$IN" | python3 -c 'import json,sys
active = 1
session_id = ""
try:
    d = json.load(sys.stdin)
    active = 1 if d.get("stop_hook_active") else 0
    session_id = str(d.get("session_id") or "")
except Exception:
    pass
print(active)
print(session_id)' 2>/dev/null || printf '1\n')
active=$(printf '%s\n' "$info" | sed -n 1p)
session_id=$(printf '%s\n' "$info" | sed -n 2p)
[ "$active" = "1" ] && exit 0

# 진화 스킬이 실제로 존재할 때만 강제한다. install.sh 배치는 프로젝트의
# .claude/skills/에, 플러그인 배치는 훅 디렉터리의 형제 디렉터리
# ($HOOK_DIR/../skills/)에 스킬이 있다 — 프로젝트 경로만 검사하면 플러그인
# 단독 설치에서 게이트가 영원히 조용히 통과해 버린다.
[ -f .claude/skills/context-evolve/SKILL.md ] \
  || [ -f "$HOOK_DIR/../skills/context-evolve/SKILL.md" ] || exit 0

# 세션 단위 sentinel. 파일명 안전을 위해 영숫자/-_ 외 문자는 치환.
sentinel=""
if [ -n "$session_id" ]; then
  safe_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '_')
  [ -n "$safe_id" ] && sentinel=".cursor-context/.gate-fired-${safe_id}"
fi
[ -n "$sentinel" ] && [ -f "$sentinel" ] && exit 0

# grep -c는 빈 파일에서 "0" 출력 + rc=1이라 `|| echo 0`과 조합하면 두 줄이 된다. awk 사용.
fb=$(awk 'NF{n++} END{print n+0}' .cursor-context/context-feedback.jsonl 2>/dev/null || echo 0)
mt=$(awk 'NF{n++} END{print n+0}' .cursor-context/metrics.jsonl 2>/dev/null || echo 0)
if [ "${fb:-0}" -ge "$FEEDBACK_THRESHOLD" ] || [ "${mt:-0}" -ge "$METRICS_THRESHOLD" ]; then
  [ -n "$sentinel" ] && : > "$sentinel" 2>/dev/null
  # msg(block)은 내부에서만 정의하는 통제된 포맷 문자열이라 SC2059 대상이 아니다.
  # shellcheck disable=SC2059
  printf -- "$(msg block)\n" "$fb" "$mt" >&2
  exit 2
fi
exit 0
