#!/usr/bin/env bash
# 구조적 파일들의 "현재 작업 트리 내용" 해시 목록을 출력한다.
# 커서의 머클 트리 비교처럼, 커밋 히스토리가 아니라 실제 파일 내용을 기준으로
# 문서 신선도를 판단하기 위한 지문(fingerprint) 생성기.
#
# 훅(비교)과 스킬(마커 기록)이 동일한 이 스크립트를 사용해야
# 지문이 항상 같은 방식으로 계산된다.
#
# 출력 형식: sha256sum과 동일 ("<해시>  <이름>"), 정렬됨.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

{
  # 매니페스트·빌드·설정 파일 (작업 트리의 실제 내용 — 미커밋 변경 포함)
  for f in package.json pnpm-lock.yaml yarn.lock package-lock.json bun.lockb bun.lock \
           pyproject.toml setup.py setup.cfg requirements.txt requirements-dev.txt \
           go.mod go.sum Cargo.toml Cargo.lock pom.xml build.gradle build.gradle.kts \
           settings.gradle settings.gradle.kts Gemfile Gemfile.lock composer.json \
           Dockerfile docker-compose.yml docker-compose.yaml compose.yaml Makefile \
           tsconfig.json tsconfig.base.json; do
    [ -f "$f" ] && sha256sum "$f" 2>/dev/null
  done

  # CI 워크플로우
  if [ -d .github/workflows ]; then
    find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null \
      | sort | xargs -r sha256sum 2>/dev/null
  fi

  # 디렉터리 구조 (깊이 2, 추적 + 미추적 비무시 파일 기준) — 구조 재편 감지용
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirhash=$(git ls-files --cached --others --exclude-standard 2>/dev/null \
      | awk -F/ 'NF==1{print $1} NF>=2{print $1"/"$2}' \
      | sort -u | sha256sum | cut -d' ' -f1)
    echo "$dirhash  directory-structure"
  fi
} | sort -k2

exit 0
