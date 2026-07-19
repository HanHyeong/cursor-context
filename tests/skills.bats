#!/usr/bin/env bats
# SKILL.md 내 훅 스크립트 호출이 리터럴 경로를 유지하는지 검증한다.
#
# 배경: .claude/settings.json은 permissions.allow에 Bash(.claude/hooks/*)
# 규칙을 등록해 스킬이 게이트 스크립트를 승인 프롬프트 없이 Bash 도구로
# 실행할 수 있게 한다. 이 규칙은 Bash 도구에 넘어가는 명령 텍스트를 문자
# 그대로 접두어 매칭하며 셸 변수 확장을 전혀 이해하지 못한다(Claude Code
# 공식 문서로 확인됨). 과거 한 리비전에서 훅 경로를 `HOOKS=.claude/hooks;
# "$HOOKS"/...` 같은 변수로 감싼 적이 있었는데, 그러면 명령 텍스트가
# `.claude/hooks/`로 시작하지 않아 권한 매칭이 깨지고 호출마다 프롬프트가
# 떠서 진화가 조용히 막힌다 — 이 회귀를 다시 도입하지 못하게 고정한다.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_SCRIPTS='context-benchmark|context-fingerprint|metrics-collector|evolve-gate|session-context|prompt-freshness'

# 파일에서 ```bash로 시작하는 펜스 코드 블록(들여쓰기 허용)만 뽑아낸다 —
# 실행되는 코드만 검사 대상이다. 변수 사용을 경고하는 설명 산문(백틱 인용
# 예시 등)은 대상이 아니다.
extract_bash_blocks() {
  awk '/^[[:space:]]*```bash/{inblock=1; next} /^[[:space:]]*```[[:space:]]*$/{inblock=0} inblock{print}' "$1"
}

@test "SKILL.md fenced bash blocks never invoke hook scripts through a shell variable" {
  for f in "$REPO_ROOT"/.claude/skills/*/SKILL.md; do
    code="$(extract_bash_blocks "$f")"
    # 따옴표로 감싼 변수형("$VAR"/...)과 안 감싼 형태($VAR/...) 둘 다 잡는다.
    run bash -c "printf '%s\n' \"\$1\" | grep -E '\"?\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\"?/($HOOK_SCRIPTS)\\.sh'" _ "$code"
    if [ "$status" -eq 0 ]; then
      echo "variable-indirected hook invocation found in $f:"
      echo "$output"
      return 1
    fi
  done
}

@test "SKILL.md fenced bash blocks invoke hook scripts via a literal .claude/hooks/ or ../../hooks/ prefix" {
  for f in "$REPO_ROOT"/.claude/skills/*/SKILL.md; do
    code="$(extract_bash_blocks "$f")"
    [ -z "$code" ] && continue
    # 스크립트명 언급 총 횟수 vs. 바로 앞에 올바른 리터럴 접두어가 붙은
    # 횟수를 비교한다 — 둘이 같아야 모든 언급이 리터럴 경로다. 접두어를
    # 직접 추출하지 않는 이유는 "FP=$(.claude/hooks/x.sh" 같은 줄에서
    # 여는 괄호까지 탐욕적으로 잡혀 오탐이 나기 때문이다.
    total=$(printf '%s\n' "$code" | grep -oE "($HOOK_SCRIPTS)\\.sh" | wc -l | tr -d ' ')
    literal=$(printf '%s\n' "$code" | grep -oE "(\\.claude/hooks/|\\.\\./\\.\\./hooks/)($HOOK_SCRIPTS)\\.sh" | wc -l | tr -d ' ')
    if [ "$total" -ne "$literal" ]; then
      echo "hook script referenced without a literal .claude/hooks/ or ../../hooks/ prefix in $f (total=$total literal=$literal):"
      printf '%s\n' "$code"
      return 1
    fi
  done
}
