#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_<lang>_<key> 변수들은 msg()의 ${!varname} 간접 참조로만 쓰인다
# UserPromptSubmit 훅: 사용자가 프롬프트를 보낼 때마다 지문을 재검사한다.
# 커서가 파일 저장 시마다 재인덱싱하듯, 세션 "도중"의 커밋·롤백·브랜치 전환·
# 미커밋 수정을 프롬프트 단위로 실시간 감지한다.
#
# 핵심 규칙: 지문이 일치하면 아무것도 출력하지 않는다 (토큰 비용 0).
# 달라진 경우에만 짧은 경고를 주입한다. 실패해도 프롬프트를 막지 않는다.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
# 이 스크립트 자신이 어디 있는지로 형제 스크립트(예: context-fingerprint.sh,
# lib-config.sh)를 찾는다 — install.sh 배치($CLAUDE_PROJECT_DIR/.claude/hooks/)와
# 플러그인 배치($CLAUDE_PLUGIN_ROOT/hooks/) 둘 다에서 항상 옳다. 계산 실패 시에만
# 예전 방식(프로젝트 루트 기준 고정 경로)으로 폴백한다.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks"


CTX_FILE=".cursor-context/project-context.md"
HELPER="$HOOK_DIR/context-fingerprint.sh"
[ -f "$CTX_FILE" ] && [ -x "$HELPER" ] || exit 0

changed=$("$HELPER" --changed "$CTX_FILE" 2>/dev/null) || exit 0
[ -n "$changed" ] || exit 0

CTX_LANG=en
# shellcheck disable=SC1091
. "$HOOK_DIR/lib-config.sh" 2>/dev/null || true

MSG_en_header="The project's structural state has diverged from the context doc (%s) since it was generated (live working-tree comparison). Changed items:"
MSG_ko_header="프로젝트의 구조적 상태가 컨텍스트 문서(%s) 생성 시점과 달라졌습니다 (작업 트리 실시간 비교). 달라진 항목:"
MSG_en_footer="Do not trust the doc content related to the items above (commands/stack/structure) for the rest of this request either. After finishing the request, in the same turn and without asking the user, quietly refresh the doc via the context-refresh skill. If writing is impossible or inappropriate in this session (plan mode, read-only review), skip the refresh -- just double-check the real files. Do not touch CLAUDE.md."
MSG_ko_footer="위 항목과 관련된 문서 내용(명령어·스택·구조)은 이번 요청 처리 중에도 신뢰하지 말고 실제 파일을 확인하세요. 요청을 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬로 문서를 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요 — 실제 파일 확인만 하면 됩니다. CLAUDE.md는 건드리지 마세요."

# ${!varname} 간접 참조로 언어별 메시지를 고른다 (bash 3.2도 지원 — macOS 기본 bash 호환).
msg() {
  key="$1"
  varname="MSG_${CTX_LANG}_${key}"
  printf '%s\n' "${!varname}"
}

echo "<context-freshness-alert>"
# msg(header)는 내부에서만 정의하는 통제된 포맷 문자열이라 SC2059 대상이 아니다.
# shellcheck disable=SC2059
printf -- "$(msg header)\n" "$CTX_FILE"
# 여러 줄 각각에 접두어를 붙이는 작업이라
# ${var//search/replace}로는 안 되고(줄별 ^ 앵커 불가) sed가 맞다.
# shellcheck disable=SC2001
echo "$changed" | sed 's/^/- /'
msg footer
echo "</context-freshness-alert>"
exit 0
