#!/usr/bin/env bash
# UserPromptSubmit 훅: 사용자가 프롬프트를 보낼 때마다 지문을 재검사한다.
# 커서가 파일 저장 시마다 재인덱싱하듯, 세션 "도중"의 커밋·롤백·브랜치 전환·
# 미커밋 수정을 프롬프트 단위로 실시간 감지한다.
#
# 핵심 규칙: 지문이 일치하면 아무것도 출력하지 않는다 (토큰 비용 0).
# 달라진 경우에만 짧은 경고를 주입한다. 실패해도 프롬프트를 막지 않는다.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

CTX_FILE=".claude/project-context.md"
HELPER=".claude/hooks/context-fingerprint.sh"
[ -f "$CTX_FILE" ] && [ -x "$HELPER" ] || exit 0

changed=$("$HELPER" --changed "$CTX_FILE" 2>/dev/null) || exit 0
[ -n "$changed" ] || exit 0

echo "<context-freshness-alert>"
echo "프로젝트의 구조적 상태가 컨텍스트 문서($CTX_FILE) 생성 시점과 달라졌습니다 (작업 트리 실시간 비교). 달라진 항목:"
echo "$changed" | sed 's/^/- /'
echo "위 항목과 관련된 문서 내용(명령어·스택·구조)은 이번 요청 처리 중에도 신뢰하지 말고 실제 파일을 확인하세요. 요청을 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬로 문서를 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요 — 실제 파일 확인만 하면 됩니다. CLAUDE.md는 건드리지 마세요."
echo "</context-freshness-alert>"
exit 0
