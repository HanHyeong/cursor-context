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
import datetime, json, os, re
from collections import defaultdict

cmds = defaultdict(lambda: [0, set()])
paths = defaultdict(lambda: [0, set()])
greps = defaultdict(lambda: [0, set()])
total = 0
bad = 0          # 파싱 불가 라인 수 — evolve-gate의 임계값은 "비어 있지 않은
                 # 줄 수"(awk NF) 기준이라 이 수를 숨기면 게이트가 말한 수와
                 # 다이제스트 합계가 어긋나 보인다. 정직하게 함께 보고한다.
sids = set()
ts_min = ts_max = None
sid = ""

def bump(table, key):
    e = table[key]
    e[0] += 1
    if sid:                       # 빈 sid(구버전 라인)는 세션 집합에 넣지 않는다
        e[1].add(sid)

with open(".cursor-context/metrics.jsonl") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            bad += 1
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
            # 체인 명령(&&, ;, |)은 세그먼트별로 계수한다 — 통째로 첫 두
            # 단어만 보면 `cd /a && npm test`가 전부 'cd /a'로 묶여 정작
            # npm test가 영영 안 보인다. 선행 환경변수 대입(VAR=x ...)도
            # 걷어내고 실제 명령 머리 두 단어를 키로 삼는다.
            for seg in re.split(r'(?:&&|\|\||[;|])', str(r.get("cmd") or ""))[:8]:
                ws = seg.split()
                while ws and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', ws[0]):
                    ws.pop(0)
                if ws:
                    bump(cmds, " ".join(ws[:2]))
        elif tool in ("Read", "Glob"):
            p = str(r.get("path") or "")
            if p:
                # 글롭 패턴(*·?·[ 포함)은 dirname이 '**' 같은 무의미 키가
                # 되므로 패턴 그대로, 일반 경로는 디렉터리로 묶는다.
                key = p if any(ch in p for ch in "*?[") else (os.path.dirname(p) or p)
                bump(paths, key)
        elif tool == "Grep":
            bump(greps, str(r.get("path") or "") or "(repo root)")

def day(ts):
    if ts is None:
        return "?"
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")

hdr = f"metrics-digest: {total} entries, {len(sids)} sessions with id, {day(ts_min)}..{day(ts_max)}"
if bad:
    hdr += f" ({bad} unparsable lines skipped)"
print(hdr)
for title, table in (("bash commands (first two words per segment)", cmds),
                     ("explored paths (Read/Glob)", paths),
                     ("grep scopes", greps)):
    if not table:
        continue
    print(f"[{title}]  hits  sessions  key")
    # 정렬은 고유 세션 수 우선 — 세션 간 반복이 문서 갭의 핵심 증거인데,
    # 횟수만으로 자르면 "한 세션에서 여러 번"이 "여러 세션에서 반복"을
    # 상위 15개 밖으로 밀어낼 수 있다.
    for k, (c, s) in sorted(table.items(), key=lambda kv: (-len(kv[1][1]), -kv[1][0], kv[0]))[:15]:
        print(f"  {c:>4}  {len(s):>4}  {k}")
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
# [:64]는 비정상 입력의 라인 폭주 방지 상한일 뿐이다 — 통상적인 세션 id
# (36자 UUID)는 절대 잘리지 않는다. 잘라서 구분 정보를 잃으면 다이제스트의
# 고유 세션 계수가 과소 집계된다.
sid = str(d.get("session_id") or "")[:64]
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

# 자기 관측 방지: 툴킷 자신의 운영은 프로젝트 지식 갭의 신호가 아니다 —
# 특히 진화 실행 자체가 신호 파일을 읽고 벤치마크·다이제스트를 돌리며
# 다음 사이클의 신호를 오염시킨다. 지문 생성기가 .cursor-context/를 구조
# 해시에서 제외하는 것과 같은 원칙. 규칙은 두 갈래다:
#   - Bash 명령: .cursor-context를 언급하거나 툴킷 스크립트를 호출하면 제외
#     (진화가 실행하는 `.claude/hooks/context-benchmark.sh` 등은 경로에
#     .cursor-context가 없어서 이름 목록으로 잡아야 한다)
#   - Read/Glob/Grep: 대상 "경로"가 .cursor-context 안일 때만 제외.
#     Grep의 "패턴"이 그 문자열을 언급하는 것만으로는 제외하지 않는다 —
#     실제 소스를 검색하는 정당한 탐색 신호까지 지워버리기 때문.
# .claude/ 등 다른 경로는 거르지 않는다 — 그것이 실제 작업 대상인 프로젝트가 있다.
TOOLKIT_SCRIPTS = ("context-fingerprint.sh", "context-benchmark.sh",
                   "metrics-collector.sh", "session-context.sh",
                   "prompt-freshness.sh", "evolve-gate.sh", "lib-config.sh")
cmd_s = rec.get("cmd", "")
if ".cursor-context" in cmd_s or any(s in cmd_s for s in TOOLKIT_SCRIPTS):
    sys.exit(0)
path_s = rec.get("path", "")
if (path_s == ".cursor-context" or path_s.startswith(".cursor-context/")
        or "/.cursor-context/" in path_s or path_s.endswith("/.cursor-context")):
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
