#!/usr/bin/env bash
# PostToolUse 훅: 도구 사용 신호를 .cursor-context/metrics.jsonl 에 적재한다.
# 자기 평가 루프의 "측정" 계층 — 순수 코드로만 기록하며 LLM이 개입하지
# 않으므로 측정 자체가 오염되지 않는다.
#
# 기록 대상: Bash 명령(무엇을 실행했나), Read/Grep/Glob(무엇을 탐색했나).
# context-evolve 스킬이 이 로그에서 "문서가 커버했어야 할 반복 탐색"을 찾는다.
#
# 원칙:
#   - 어떤 경로에서도 exit 0 (도구 실행을 절대 방해하지 않음)
#   - python3 없으면 조용히 비활성 (측정 불가를 거짓 데이터로 채우지 않음)
#   - 벤치마크 실행 중에는 기록하지 않음 (게이트 측정 오염 방지)
#   - 로그 회전으로 무한 성장 방지 (2000줄 초과 시 최근 1000줄 유지). 회전 여부
#     판단에 파일 전체를 읽어야 하므로, 매 호출이 아니라 호출의 1%만
#     확률적으로 검사한다(기대 호출 100회당 1회) — 평균 비용을 O(1)에
#     가깝게 유지하고, 회전이 늦어져도 무한 성장은 아니다.

set -u
[ -n "${CURSOR_CONTEXT_BENCH:-}" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ -d .claude ] || exit 0   # 툴킷이 설치된 프로젝트에서만 동작
mkdir -p .cursor-context 2>/dev/null || exit 0

# 3<&0: 훅의 원래 stdin(도구 JSON)을 fd3에 보존 — heredoc이 fd0을 파이썬
# 프로그램으로 대체하므로, 이 복제가 없으면 입력 JSON을 읽을 수 없다.
python3 - 3<&0 <<'PY' 2>/dev/null
import json, sys, os, time, random
try:
    d = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)
tool = d.get("tool_name", "")
ti = d.get("tool_input") or {}
rec = {"ts": int(time.time()), "tool": tool}
if tool == "Bash":
    rec["cmd"] = str(ti.get("command", ""))[:200]
elif tool in ("Read", "Glob"):
    rec["path"] = str(ti.get("file_path") or ti.get("pattern") or "")[:200]
elif tool == "Grep":
    rec["pattern"] = str(ti.get("pattern", ""))[:120]
    rec["path"] = str(ti.get("path", "") or "")[:120]
else:
    sys.exit(0)

p = ".cursor-context/metrics.jsonl"
try:
    # open(p, "a")의 write()는 한 줄(수백 바이트)뿐이라, 버퍼가 flush되며 나가는
    # 단일 OS write() 호출로 끝난다 — POSIX에서 O_APPEND 단일 write는 다른
    # 프로세스의 동시 append와 뒤섞이지 않는다("practically atomic"). 다만 이는
    # 로컬 파일시스템 가정이며, 네트워크 파일시스템에서는 보장되지 않는다.
    with open(p, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    # 회전 검사(전체 읽기)는 확률적으로만 수행 — 위 주석 참고.
    if random.random() < 0.01:
        with open(p) as f:
            lines = f.readlines()
        if len(lines) > 2000:
            with open(p, "w") as f:
                f.writelines(lines[-1000:])
except Exception:
    pass
PY
exit 0
