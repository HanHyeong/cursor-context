#!/usr/bin/env bash
# 구조적 파일들의 "현재 작업 트리 내용" 지문(fingerprint)을 다루는 단일 진실 공급원.
# 커서의 머클 트리 비교처럼, 커밋 히스토리가 아니라 실제 파일 내용을 기준으로
# 문서 신선도를 판단한다.
#
# 사용법:
#   context-fingerprint.sh                     # 지문 목록 출력 (마커 기록용)
#   context-fingerprint.sh --changed <문서>    # 문서에 저장된 지문과 현재 지문을
#                                              # 비교해 달라진 항목명만 출력.
#                                              # 출력 없음 = 일치(또는 마커 없음).
#
# 모든 훅과 스킬은 반드시 이 스크립트를 통해 지문을 계산·비교해야 한다.
# 비교 로직이 여러 곳에 복제되면 계산 방식이 어긋날 수 있다.
#
# 출력 형식: sha256 해시 목록 ("<해시>  <이름>"), 이름 기준 정렬.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

# sha256sum은 macOS에 기본 설치되어 있지 않다. shasum -a 256으로 폴백
# (출력 형식 동일: "<해시>  <파일명>").
# 종료 코드 규약: 0 = 정상 동작, 3 = 지문 기능 사용 불가(해시 도구/마커 없음).
# 훅은 3을 받으면 "검증됨"이라고 주장해서는 안 된다 — 거짓 보증 금지.
if command -v sha256sum >/dev/null 2>&1; then
  HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASHER="shasum -a 256"
else
  HASHER=""
fi

emit_fingerprint() {
  {
    # 매니페스트·빌드·설정 파일 (작업 트리의 실제 내용 — 미커밋 변경 포함)
    for f in package.json pnpm-lock.yaml yarn.lock package-lock.json bun.lockb bun.lock \
             pyproject.toml setup.py setup.cfg requirements.txt requirements-dev.txt \
             go.mod go.sum Cargo.toml Cargo.lock pom.xml build.gradle build.gradle.kts \
             settings.gradle settings.gradle.kts Gemfile Gemfile.lock composer.json \
             Dockerfile docker-compose.yml docker-compose.yaml compose.yaml Makefile \
             tsconfig.json tsconfig.base.json; do
      [ -f "$f" ] && $HASHER "$f" 2>/dev/null
    done

    # CI 워크플로우 (xargs -r은 BSD에 없으므로 while 루프 사용)
    if [ -d .github/workflows ]; then
      find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null \
        | sort | while IFS= read -r wf; do $HASHER "$wf" 2>/dev/null; done
    fi

    # 디렉터리 구조 해시 — "디렉터리 목록"만 본다 (깊이 1 디렉터리 전체 +
    # 하위에 깊이 3 이상이 존재하는 깊이 2 디렉터리).
    # 개별 파일 추가(메모, .env, 스크래치 등)로는 절대 바뀌지 않아야
    # 거짓 "구조 변경" 경고가 나지 않는다. 파일 내용 변경은 위의
    # 매니페스트 해시가 담당한다.
    # .cursor-context/(툴킷 자신의 데이터 계층)는 항상 제외한다 — 팀 공유
    # 모드(gitignore 해제)에서는 진화 백업(backup/evolve-<ts>/) 같은 미추적
    # 디렉터리가 --others에 잡혀, 툴킷의 자기 활동이 거짓 "구조 변경" 알람과
    # 불필요한 갱신 루프를 유발했다. 자기 관측은 지문 대상이 아니다.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      dirhash=$(git ls-files --cached --others --exclude-standard 2>/dev/null \
        | awk -F/ '$1==".cursor-context"{next} NF>=2{print $1} NF>=3{print $1"/"$2}' \
        | sort -u | $HASHER | cut -d' ' -f1)
      echo "$dirhash  directory-structure"
    fi
  } | sort -k2
}

if [ "${1:-}" = "--changed" ]; then
  [ -n "$HASHER" ] || exit 3
  doc="${2:-.cursor-context/project-context.md}"
  [ -f "$doc" ] || exit 3
  # tr -d '\r': 마커가 CRLF로 기록된 경우에도 영구 불일치 루프에 빠지지 않게 정규화
  stored=$(sed -n '/context-fingerprint-begin/,/context-fingerprint-end/p' "$doc" | tr -d '\r' | grep -E '^[0-9a-f]{64}')
  [ -n "$stored" ] || exit 3
  current=$(emit_fingerprint)
  [ -n "$current" ] || exit 3
  [ "$stored" = "$current" ] && exit 0
  printf '%s\n%s\n' "$stored" "$current" | sort | uniq -u | awk '{print $2}' | sort -u | head -10
  exit 0
fi

[ -n "$HASHER" ] || exit 3
emit_fingerprint
exit 0
