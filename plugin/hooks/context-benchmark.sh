#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_<lang>_<key> 변수들은 msg()의 ${!varname} 간접 참조로만 쓰인다
# 문서 품질 게이트 (결정론적): context-evolve 스킬이 새 문서를 채택하기 전에
# 반드시 통과시켜야 하는 검사. 자기 진화 루프의 "선택" 계층이며, 진화 대상이
# 아니다 — 측정·게이트 계층을 스스로 고치는 시스템은 점수를 후하게 바꾸는
# 방향으로 퇴화할 수 있으므로 이 파일은 자동 수정 금지.
#
# 사용법: context-benchmark.sh [문서경로]   (기본 .cursor-context/project-context.md)
# 출력:  PASS/WARN/FAIL 라인 + 요약. 종료 코드 0=채택 가능, 1=불합격.
# 정확한 검사는 FAIL(하드), 휴리스틱 검사는 WARN(소프트)으로만 판정한다.
#
# PASS/WARN/FAIL 접두어와 "결과: PASS=x WARN=y FAIL=z" 요약 포맷은 언어와
# 무관하게 고정이다 — context-evolve/SKILL.md가 이 정확한 토큰("FAIL=0",
# "PASS 수")을 채택 기준으로 삼아 읽으므로 절대 바꾸지 않는다. 번역 대상은
# 각 판정 뒤에 붙는 설명 텍스트뿐이다.

set -u
export CURSOR_CONTEXT_BENCH=1   # 벤치마크 중 메트릭 수집 오염 방지
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 1
# 이 스크립트 자신이 어디 있는지로 형제 스크립트(예: context-fingerprint.sh,
# lib-config.sh)를 찾는다 — install.sh 배치($CLAUDE_PROJECT_DIR/.claude/hooks/)와
# 플러그인 배치($CLAUDE_PLUGIN_ROOT/hooks/) 둘 다에서 항상 옳다. 계산 실패 시에만
# 예전 방식(프로젝트 루트 기준 고정 경로)으로 폴백한다.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks"

DOC="${1:-.cursor-context/project-context.md}"

# 기본값을 먼저 설정한 뒤 .cursor-context/config가 있으면 그 값으로 덮어쓴다
# (lib-config.sh가 없거나 로드 실패해도 아래 기본값으로 정상 동작한다).
DOC_LINE_BUDGET=200
DOC_MIN_LINES=10
CTX_LANG=en
# shellcheck disable=SC1091
. "$HOOK_DIR/lib-config.sh" 2>/dev/null || true
WARN_CEILING=$((DOC_LINE_BUDGET + 50))

MSG_en_doc_missing="doc not found: %s"
MSG_ko_doc_missing="문서 없음: %s"
MSG_en_result_label="Result:"
MSG_ko_result_label="결과:"
MSG_en_body_pass="body: %s lines (target: within %s)"
MSG_ko_body_pass="본문 %s줄 (목표 %s 이내)"
MSG_en_body_warn="body: %s lines (over %s -- trim recommended)"
MSG_ko_body_warn="본문 %s줄 (%s 초과 — 다이어트 권장)"
MSG_en_body_fail="body: %s lines -- over %s, will be truncated on injection"
MSG_ko_body_fail="본문 %s줄 — %s 초과, 주입 시 잘림"
MSG_en_body_floor_ok="body has %s non-empty lines (min %s)"
MSG_ko_body_floor_ok="본문 실질 %s줄 (최소 %s 이상)"
MSG_en_body_floor_fail="body: only %s non-empty lines -- under the minimum of %s; an effectively empty doc must not be adopted"
MSG_ko_body_floor_fail="본문 실질 %s줄 — 최소 %s 미만, 사실상 빈 문서는 채택 불가"
MSG_en_marker_ok="generated-at-commit marker present"
MSG_ko_marker_ok="generated-at-commit 마커 존재"
MSG_en_marker_fail="generated-at-commit marker missing"
MSG_ko_marker_fail="generated-at-commit 마커 없음"
MSG_en_fp_unverifiable="fingerprint verification unavailable (no hash tool)"
MSG_ko_fp_unverifiable="지문 검증 불가 환경 (해시 도구 없음)"
MSG_en_fp_match="fingerprint matches the current working tree"
MSG_ko_fp_match="지문이 현재 작업 트리와 일치"
MSG_en_fp_mismatch="fingerprint mismatch -- marker needs to be re-recorded (changed: %s)"
MSG_ko_fp_mismatch="지문 불일치 — 마커 재기록 필요 (달라진 항목: %s)"
MSG_en_fp_missing_block="no fingerprint block (will be recorded on next refresh)"
MSG_ko_fp_missing_block="지문 블록 없음 (다음 갱신 시 기록 필요)"
MSG_en_npm_ok="all 'npm run' commands in the doc exist"
MSG_ko_npm_ok="문서의 'npm run' 명령 전부 실재"
MSG_en_npm_fail="doc references npm scripts that do not exist: %s"
MSG_ko_npm_fail="문서가 언급한 존재하지 않는 npm 스크립트: %s"
MSG_en_make_ok="all make targets in the doc exist"
MSG_ko_make_ok="문서의 make 타깃 전부 실재"
MSG_en_make_fail="doc references make targets that do not exist:%s"
MSG_ko_make_fail="문서가 언급한 존재하지 않는 make 타깃:%s"
MSG_en_path_warn="doc references paths that do not exist:%s"
MSG_ko_path_warn="문서가 언급했지만 존재하지 않는 경로:%s"
MSG_en_path_ok="all %s referenced paths exist"
MSG_ko_path_ok="문서 언급 경로 %s개 전부 실재"

# ${!varname} 간접 참조로 언어별 메시지를 고른다 (bash 3.2도 지원 — macOS 기본 bash 호환).
msg() {
  key="$1"
  varname="MSG_${CTX_LANG}_${key}"
  # 번역 누락 시 영어로 폴백하고, 그것도 없으면 빈 문자열을 낸다 —
  # set -u 환경에서 미정의 키의 간접 참조가 스크립트를 죽이지 못하게 한다.
  [ -n "${!varname-}" ] || varname="MSG_en_${key}"
  printf '%s' "${!varname-}"
}

hard=0; soft=0; pass=0
# msg()가 반환하는 포맷 문자열은 위에서 우리가 직접 정의한 통제된 문자열이라
# SC2059 대상이 아니다.
# shellcheck disable=SC2059
ok(){ pass=$((pass+1)); printf 'PASS: %s\n' "$(printf -- "$1" "${@:2}")"; }
# shellcheck disable=SC2059
warn(){ soft=$((soft+1)); printf 'WARN: %s\n' "$(printf -- "$1" "${@:2}")"; }
# shellcheck disable=SC2059
fail(){ hard=$((hard+1)); printf 'FAIL: %s\n' "$(printf -- "$1" "${@:2}")"; }

if [ ! -f "$DOC" ]; then
  fail "$(msg doc_missing)" "$DOC"
  echo "$(msg result_label) PASS=0 WARN=0 FAIL=1"
  exit 1
fi

# 1. 본문 길이 (마커 제외 — 주입 시 실제로 보이는 분량)
body_lines=$(grep -vcE '^<!--|^[0-9a-f]{64} |^context-fingerprint-end -->' "$DOC")
if [ "$body_lines" -le "$DOC_LINE_BUDGET" ]; then ok "$(msg body_pass)" "$body_lines" "$DOC_LINE_BUDGET"
elif [ "$body_lines" -le "$WARN_CEILING" ]; then warn "$(msg body_warn)" "$body_lines" "$DOC_LINE_BUDGET"
else fail "$(msg body_fail)" "$body_lines" "$WARN_CEILING"; fi

# 1b. 본문 하한 (정확 검사 → FAIL). 예산 상한만 있으면 "전부 삭제" 변이가
# 모든 검사를 공허하게 통과해 채택될 수 있다(빈 문서는 언급 명령·경로도
# 없으므로 나머지 검사가 전부 PASS다). 실질(비공백) 줄 수가 하한 미만이면
# 내용이 사실상 없는 퇴행 문서로 보고 채택을 막는다.
body_nonempty=$(grep -vE '^<!--|^[0-9a-f]{64} |^context-fingerprint-end -->' "$DOC" | grep -c '[^[:space:]]')
if [ "${body_nonempty:-0}" -ge "$DOC_MIN_LINES" ]; then ok "$(msg body_floor_ok)" "$body_nonempty" "$DOC_MIN_LINES"
else fail "$(msg body_floor_fail)" "$body_nonempty" "$DOC_MIN_LINES"; fi

# 2. 신선도 마커 유효성
if grep -q 'generated-at-commit:' "$DOC"; then ok "$(msg marker_ok)"
else fail "$(msg marker_fail)"; fi

if sed -n '/context-fingerprint-begin/,/context-fingerprint-end/p' "$DOC" | grep -qE '^[0-9a-f]{64}'; then
  changed=$("$HOOK_DIR/context-fingerprint.sh" --changed "$DOC" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 3 ]; then warn "$(msg fp_unverifiable)"
  elif [ -z "$changed" ]; then ok "$(msg fp_match)"
  else fail "$(msg fp_mismatch)" "$(echo "$changed" | tr '\n' ' ')"; fi
else
  warn "$(msg fp_missing_block)"
fi

# 3. 문서가 언급한 패키지 스크립트가 실제로 존재하는가 (정확 검사 → FAIL)
if [ -f package.json ] && command -v python3 >/dev/null 2>&1; then
  missing=$(python3 - "$DOC" <<'PY' 2>/dev/null
import json, re, sys
doc = open(sys.argv[1]).read()
try:
    scripts = set((json.load(open("package.json")).get("scripts") or {}).keys())
except Exception:
    sys.exit(0)
used = set(re.findall(r'(?:npm|pnpm|yarn|bun) run ([A-Za-z0-9:_-]+)', doc))
# yarn은 "yarn run <script>"의 run 생략형("yarn <script>")도 허용하지만, 이 형태는
# yarn 자체 내장 명령과 문법적으로 구분되지 않는다. 내장 명령을 제외 목록으로
# 걸러내지 않으면 "yarn install" 같은 문서 언급이 거짓 FAIL을 유발한다.
YARN_BUILTINS = {
    "install", "add", "remove", "upgrade", "upgrade-interactive", "dlx",
    "create", "init", "run", "exec", "why", "list", "info", "config",
    "cache", "link", "unlink", "workspace", "workspaces", "dedupe",
    "audit", "outdated", "pack", "publish", "version", "versions", "tag",
    "login", "logout", "whoami", "import", "node", "policies", "autoclean",
    "bin", "check", "global", "help", "licenses", "generate", "plugin",
    "set", "constraints", "explain", "rebuild", "unplug", "up",
}
yarn_shorthand = set(re.findall(r'\byarn ([A-Za-z0-9:_-]+)', doc)) - YARN_BUILTINS
used |= yarn_shorthand
print("\n".join(sorted(used - scripts)))
PY
)
  if [ -n "$missing" ]; then fail "$(msg npm_fail)" "$(echo "$missing" | tr '\n' ' ')"
  else ok "$(msg npm_ok)"; fi
fi

# 4. Makefile 타깃 검사 (정확 검사 → FAIL)
if [ -f Makefile ]; then
  mk_missing=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    grep -qE "^$t:" Makefile || mk_missing="$mk_missing $t"
  done < <(grep -oE '\bmake [A-Za-z0-9_-]+' "$DOC" | awk '{print $2}' | sort -u)
  if [ -n "$mk_missing" ]; then fail "$(msg make_fail)" "$mk_missing"
  else ok "$(msg make_ok)"; fi
fi

# 5. 문서가 언급한 경로 실재 여부 (백틱 안 상대경로 — 휴리스틱 → WARN)
# 주의: 정규식에서 \` 는 GNU grep의 "버퍼 시작 앵커"라 리터럴 백틱이 아니다.
# 단따옴표 안의 맨 백틱을 그대로 쓴다.
bad=""; checked=0
# 백틱은 리터럴 문자다(위 주석 참고), 셸 확장 의도가 아니다.
# shellcheck disable=SC2016
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in *"..."*|http*|*/) continue ;; esac
  checked=$((checked+1))
  [ -e "$p" ] || bad="$bad $p"
done < <(grep -oE '`[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*`' "$DOC" | tr -d '`' | sort -u | head -30)
if [ -n "$bad" ]; then warn "$(msg path_warn)" "$bad"
elif [ "$checked" -gt 0 ]; then ok "$(msg path_ok)" "$checked"
fi

echo "$(msg result_label) PASS=$pass WARN=$soft FAIL=$hard"
[ "$hard" -eq 0 ] && exit 0
exit 1
