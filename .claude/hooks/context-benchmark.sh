#!/usr/bin/env bash
# 문서 품질 게이트 (결정론적): context-evolve 스킬이 새 문서를 채택하기 전에
# 반드시 통과시켜야 하는 검사. 자기 진화 루프의 "선택" 계층이며, 진화 대상이
# 아니다 — 측정·게이트 계층을 스스로 고치는 시스템은 점수를 후하게 바꾸는
# 방향으로 퇴화할 수 있으므로 이 파일은 자동 수정 금지.
#
# 사용법: context-benchmark.sh [문서경로]   (기본 .cursor-context/project-context.md)
# 출력:  PASS/WARN/FAIL 라인 + 요약. 종료 코드 0=채택 가능, 1=불합격.
# 정확한 검사는 FAIL(하드), 휴리스틱 검사는 WARN(소프트)으로만 판정한다.

set -u
export CURSOR_CONTEXT_BENCH=1   # 벤치마크 중 메트릭 수집 오염 방지
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 1
DOC="${1:-.cursor-context/project-context.md}"

hard=0; soft=0; pass=0
ok(){ pass=$((pass+1)); echo "PASS: $1"; }
warn(){ soft=$((soft+1)); echo "WARN: $1"; }
fail(){ hard=$((hard+1)); echo "FAIL: $1"; }

[ -f "$DOC" ] || { echo "FAIL: 문서 없음: $DOC"; echo "결과: PASS=0 WARN=0 FAIL=1"; exit 1; }

# 1. 본문 길이 (마커 제외 — 주입 시 실제로 보이는 분량)
body_lines=$(grep -vcE '^<!--|^[0-9a-f]{64} |^context-fingerprint-end -->' "$DOC")
if [ "$body_lines" -le 200 ]; then ok "본문 ${body_lines}줄 (목표 200 이내)"
elif [ "$body_lines" -le 250 ]; then warn "본문 ${body_lines}줄 (200 초과 — 다이어트 권장)"
else fail "본문 ${body_lines}줄 — 250 초과, 주입 시 잘림"; fi

# 2. 신선도 마커 유효성
if grep -q 'generated-at-commit:' "$DOC"; then ok "generated-at-commit 마커 존재"
else fail "generated-at-commit 마커 없음"; fi

if sed -n '/context-fingerprint-begin/,/context-fingerprint-end/p' "$DOC" | grep -qE '^[0-9a-f]{64}'; then
  changed=$(.claude/hooks/context-fingerprint.sh --changed "$DOC" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 3 ]; then warn "지문 검증 불가 환경 (해시 도구 없음)"
  elif [ -z "$changed" ]; then ok "지문이 현재 작업 트리와 일치"
  else fail "지문 불일치 — 마커 재기록 필요 (달라진 항목: $(echo "$changed" | tr '\n' ' '))"; fi
else
  warn "지문 블록 없음 (다음 갱신 시 기록 필요)"
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
print("\n".join(sorted(used - scripts)))
PY
)
  if [ -n "$missing" ]; then fail "문서가 언급한 존재하지 않는 npm 스크립트: $(echo "$missing" | tr '\n' ' ')"
  else ok "문서의 'npm run' 명령 전부 실재"; fi
fi

# 4. Makefile 타깃 검사 (정확 검사 → FAIL)
if [ -f Makefile ]; then
  mk_missing=""
  for t in $(grep -oE '\bmake [A-Za-z0-9_-]+' "$DOC" | awk '{print $2}' | sort -u); do
    grep -qE "^$t:" Makefile || mk_missing="$mk_missing $t"
  done
  if [ -n "$mk_missing" ]; then fail "문서가 언급한 존재하지 않는 make 타깃:$mk_missing"
  else ok "문서의 make 타깃 전부 실재"; fi
fi

# 5. 문서가 언급한 경로 실재 여부 (백틱 안 상대경로 — 휴리스틱 → WARN)
# 주의: 정규식에서 \` 는 GNU grep의 "버퍼 시작 앵커"라 리터럴 백틱이 아니다.
# 단따옴표 안의 맨 백틱을 그대로 쓴다.
bad=""; checked=0
for p in $(grep -oE '`[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*`' "$DOC" | tr -d '`' | sort -u | head -30); do
  case "$p" in *"..."*|http*|*/) continue ;; esac
  checked=$((checked+1))
  [ -e "$p" ] || bad="$bad $p"
done
if [ -n "$bad" ]; then warn "문서가 언급했지만 존재하지 않는 경로:$bad"
elif [ "$checked" -gt 0 ]; then ok "문서 언급 경로 ${checked}개 전부 실재"
fi

echo "결과: PASS=$pass WARN=$soft FAIL=$hard"
[ "$hard" -eq 0 ] && exit 0
exit 1
