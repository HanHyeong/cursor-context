#!/usr/bin/env bash
# PostToolUse 훅: 도구 사용 신호를 .cursor-context/metrics.jsonl 에 적재한다.
# 자기 평가 루프의 "측정" 계층 — 순수 코드로만 기록하며 LLM이 개입하지
# 않으므로 측정 자체가 오염되지 않는다.
#
# 기록 대상: Bash 명령(무엇을 실행했나), Read/Grep/Glob(무엇을 탐색했나),
# 세션 id(세션 간 반복 판별용). context-evolve 스킬이 `--digest` 요약에서
# "문서가 커버했어야 할 반복 탐색"을 찾는다.
#
# 원칙:
#   - 어떤 경로에서도 exit 0 (도구 실행을 절대 방해하지 않음)
#   - python3 없으면 조용히 비활성 (측정 불가를 거짓 데이터로 채우지 않음)
#   - 자격증명 형태 값(token=, password=, Bearer … 등)은 기록 전에 마스킹
#     (베스트 에포트 — 시크릿을 CLI 인자로 넘기지 않는 것이 근본 대책)
#   - .cursor-context/ 를 대상으로 한 호출은 기록하지 않음 (자기 관측 방지)
#   - 벤치마크 실행 중에는 기록하지 않음 (게이트 측정 오염 방지)
#   - 로그 회전으로 무한 성장 방지 (2000줄 초과 시 최근 1000줄 유지). 회전 여부
#     판단에 파일 전체를 읽어야 하므로, 매 호출이 아니라 호출의 1%만
#     확률적으로 검사한다(기대 호출 100회당 1회) — 평균 비용을 O(1)에
#     가깝게 유지하고, 회전이 늦어져도 무한 성장은 아니다.

set -u
[ -n "${CURSOR_CONTEXT_BENCH:-}" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# --digest: 적재된 metrics.jsonl의 결정론적 요약을 출력한다. context-evolve
# 스킬이 원시 로그(최대 2,000줄)를 통째로 읽고 직접 세는 대신 이 요약을
# 읽는다 — 집계는 순수 코드가 하므로 수치가 정확하고 토큰 비용이 없다.
# "세션 간 반복(sessions ≥ 2)"이 문서 갭의 핵심 증거이므로 항목별 고유
# 세션 수를 함께 낸다. 출력은 모델이 읽는 용도라 번역하지 않는다.
if [ "${1:-}" = "--digest" ]; then
  [ -f .cursor-context/metrics.jsonl ] || { echo "metrics-digest: no metrics file"; exit 0; }
  python3 - <<'PY' 2>/dev/null || echo "metrics-digest: unavailable (python3 error)"
import datetime, json, os
from collections import defaultdict

cmds = defaultdict(lambda: [0, set()])
dirs = defaultdict(lambda: [0, set()])
greps = defaultdict(lambda: [0, set()])
total = 0
sids = set()
ts_min = ts_max = None

with open(".cursor-context/metrics.jsonl") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        total += 1
        sid = str(r.get("sid") or "")
        if sid:
            sids.add(sid)
        ts = r.get("ts")
        if isinstance(ts, int):
            ts_min = ts if ts_min is None else min(ts_min, ts)
            ts_max = ts if ts_max is None else max(ts_max, ts)
        tool = r.get("tool")
        if tool == "Bash":
            words = str(r.get("cmd") or "").split()
            if words:
                e = cmds[" ".join(words[:2])]; e[0] += 1; e[1].add(sid)
        elif tool in ("Read", "Glob"):
            p = str(r.get("path") or "")
            if p:
                e = dirs[os.path.dirname(p) or p]; e[0] += 1; e[1].add(sid)
        elif tool == "Grep":
            p = str(r.get("path") or "") or "(repo root)"
            e = greps[p]; e[0] += 1; e[1].add(sid)

def day(ts):
    if ts is None:
        return "?"
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")

print(f"metrics-digest: {total} entries, {len(sids)} sessions with id, {day(ts_min)}..{day(ts_max)}")
for title, table in (("bash commands (first two words)", cmds),
                     ("explored dirs (Read/Glob)", dirs),
                     ("grep scopes", greps)):
    if not table:
        continue
    print(f"[{title}]  hits  sessions  key")
    for k, (c, s) in sorted(table.items(), key=lambda kv: (-kv[1][0], kv[0]))[:15]:
        print(f"  {c:>4}  {len({x for x in s if x}):>4}  {k}")
PY
  exit 0
fi
# 프로젝트 쪽 디렉터리 존재(.claude 등)는 요구하지 않는다 — 이 훅이 실행된다는
# 것 자체가 활성화 신호다(install.sh 배치는 프로젝트 settings.json 등록,
# 플러그인 배치는 플러그인 활성화). 예전의 `[ -d .claude ]` 가드는 플러그인
# 단독 설치(프로젝트에 .claude/가 없음)에서 측정을 통째로 꺼버렸다.
mkdir -p .cursor-context 2>/dev/null || exit 0

# 3<&0: 훅의 원래 stdin(도구 JSON)을 fd3에 보존 — heredoc이 fd0을 파이썬
# 프로그램으로 대체하므로, 이 복제가 없으면 입력 JSON을 읽을 수 없다.
python3 - 3<&0 <<'PY' 2>/dev/null
import json, re, sys, os, time, random
try:
    d = json.load(os.fdopen(3))
except Exception:
    sys.exit(0)
tool = d.get("tool_name", "")
ti = d.get("tool_input") or {}
rec = {"ts": int(time.time()), "tool": tool}
# 세션 id를 함께 기록한다 — "한 세션의 반복"(그 작업의 특성)과 "세션 간
# 반복"(문서가 커버했어야 할 갭의 진짜 증거)을 --digest가 구분하는 데 쓴다.
sid = str(d.get("session_id") or "")[:32]
if sid:
    rec["sid"] = sid
if tool == "Bash":
    cmd = str(ti.get("command", ""))
    # 자격증명 형태의 값은 기록 전에 마스킹한다 (베스트 에포트 — 이 로그는
    # 로컬 전용·gitignore 대상이지만, CLI 인자로 넘긴 시크릿이 평문으로
    # 쌓이는 것 자체를 줄인다). 명령의 형태는 진화 신호로 충분히 남는다.
    cmd = re.sub(
        r'(?i)([\w-]*(?:token|secret|passwd|password|api[_-]?key|apikey|'
        r'access[_-]?key|private[_-]?key|credential)[\w-]*\s*[=:]\s*)\S+',
        r'\1[redacted]', cmd)
    cmd = re.sub(r'(?i)\b(bearer\s+)\S+', r'\1[redacted]', cmd)
    rec["cmd"] = cmd[:200]
elif tool in ("Read", "Glob"):
    rec["path"] = str(ti.get("file_path") or ti.get("pattern") or "")[:200]
elif tool == "Grep":
    rec["pattern"] = str(ti.get("pattern", ""))[:120]
    rec["path"] = str(ti.get("path", "") or "")[:120]
else:
    sys.exit(0)

# 자기 관측 방지: .cursor-context/(툴킷 자신의 데이터 계층)를 대상으로 한
# 호출은 프로젝트 지식 갭의 신호가 아니라 툴킷 운영이다 — 특히 진화 실행
# 자체가 신호 파일을 읽으며 다음 사이클의 신호를 오염시킨다. 지문 생성기가
# .cursor-context/를 구조 해시에서 제외하는 것과 같은 원칙. .claude/ 등
# 다른 경로는 거르지 않는다 — 그것이 실제 작업 대상인 프로젝트가 있다.
probe = rec.get("cmd", "") + rec.get("path", "") + rec.get("pattern", "")
if ".cursor-context" in probe:
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
