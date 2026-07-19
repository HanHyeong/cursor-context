#!/usr/bin/env bash
# PreToolUse 훅 (matcher: Bash): 이 툴킷 자신의 게이트·지문·다이제스트
# 스크립트를 인자 외 다른 셸 특수문자 없이 단독 호출하는 경우에만 승인
# 프롬프트를 건너뛰게 한다("permissionDecision": "allow").
#
# 왜 필요한가: 훅 자신은(이 파일 포함) 권한 검사 없이 실행되지만, 스킬이
# Bash 도구로 context-benchmark.sh 등을 직접 실행하는 것은 일반 Bash 명령과
# 똑같이 권한 게이트에 걸린다. install.sh 배치는 .claude/settings.json에
# permissions.allow: Bash(.claude/hooks/*) 규칙을 심어 이를 우회하지만,
# 그 규칙은 Bash 도구에 넘어가는 명령 텍스트를 문자 그대로 접두어 매칭할
# 뿐이라 셸 변수로 감싸면 매칭이 깨지는 취약점이 있었다(과거 회귀,
# tests/skills.bats로 고정). 게다가 **플러그인 매니페스트는 permissions
# 규칙을 아예 선언할 수 없다** — 플러그인 단독 설치에서는 permissions.allow
# 접근 자체가 불가능하다.
#
# 이 훅은 두 문제를 한 번에 해결한다: PreToolUse 훅은 배치(install.sh/
# 플러그인)와 무관하게 권한 검사보다 먼저 실행되고, 결정론적 코드로 판단해
# "allow"를 반환하면 그 판단이 신뢰된다 — 정적 문자열 접두어 매칭보다
# 강건하다(셸 변수 감싸기에 흔들리지 않음). permissions.allow 규칙은 그대로
# 두되(다른 훅 파일 호출 등 이 훅이 다루지 않는 패턴을 위한 방어선으로 유지),
# 이 훅이 항상 먼저 판단하므로 install.sh 배치에서는 사실상 중복 방어다.
#
# 승인 대상은 반드시 다음을 모두 만족해야 한다:
#   1) tool_name == "Bash"
#   2) 명령 전체에 체이닝·치환·리다이렉션 등 셸 특수문자(; & | ` $ < > 개행)가
#      전혀 없음 — "우리 스크립트 + 단순 인자"만 허용, 임의 명령 삽입 방지
#   3) 명령의 첫 토큰이 이 훅 자신의 HOOK_DIR(install.sh 배치면
#      .../.claude/hooks, 플러그인 배치면 그 플러그인의 실제 hooks 디렉터리)
#      아래의 context-benchmark.sh / context-fingerprint.sh /
#      metrics-collector.sh 중 하나와 정확히 일치(install.sh 배치에서는
#      프로젝트 루트 상대경로 .claude/hooks/<script>도 동일하게 인정 —
#      Bash 도구의 cwd가 프로젝트 루트이기 때문)
#
# 위 조건에 안 맞으면 아무 것도 출력하지 않고 exit 0 — 일반 권한 흐름으로
# 그대로 넘어간다(fail-safe: 애매하면 승인하지 않는다).

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# 3<&0: 훅의 원래 stdin(도구 JSON)을 fd3에 보존 — heredoc이 fd0을 파이썬
# 프로그램으로 대체하므로, 이 복제가 없으면 입력 JSON을 읽을 수 없다
# (metrics-collector.sh와 동일한 패턴).
HOOK_DIR="$HOOK_DIR" python3 - 3<&0 <<'PY' 2>/dev/null
import json, os, re, sys

try:
    d = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)

if d.get("tool_name") != "Bash":
    sys.exit(0)

cmd = str((d.get("tool_input") or {}).get("command", "")).strip()
if not cmd:
    sys.exit(0)

# 셸 특수문자가 하나라도 있으면 절대 승인하지 않는다(체이닝·치환·리다이렉션
# 등으로 임의 명령을 함께 실어 보낼 수 있기 때문).
if re.search(r'[;&|`$<>\n]', cmd):
    sys.exit(0)

head = cmd.split(None, 1)[0]
hook_dir = os.environ.get("HOOK_DIR", "")
scripts = ("context-benchmark.sh", "context-fingerprint.sh", "metrics-collector.sh")

allowed_heads = set()
for s in scripts:
    if hook_dir:
        allowed_heads.add(f"{hook_dir}/{s}")
    # install.sh 배치(HOOK_DIR이 .../.claude/hooks로 끝남)에서는 프로젝트
    # 루트 상대경로 형태도 동일하게 인정한다 — Bash 도구는 프로젝트 루트를
    # cwd로 실행되므로 두 표기가 같은 파일을 가리킨다.
    if hook_dir.endswith("/.claude/hooks"):
        allowed_heads.add(f".claude/hooks/{s}")

if head in allowed_heads:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "cursor-context toolkit's own gate/fingerprint/digest script, no shell metacharacters",
        }
    }))
PY

exit 0
