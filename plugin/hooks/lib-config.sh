#!/usr/bin/env bash
# 공유 설정 로더. .cursor-context/config(KEY=VALUE, 파일이 없으면 기본값)에서
# 임계값과 언어를 읽어와 이 파일을 source한 훅의 셸 변수로 노출한다.
#
# 다루는 값(텍스트 문자열 자체는 각 훅 상단에 두므로 여기서 다루지 않는다):
#   FEEDBACK_THRESHOLD  (기본 5)   — evolve-gate: 피드백 라인 수 임계값
#   METRICS_THRESHOLD   (기본 300) — evolve-gate: 메트릭 라인 수 임계값
#   COMMIT_BACKSTOP     (기본 20)  — session-context: 커밋 수 백스톱
#   DOC_LINE_BUDGET      (기본 200) — context-benchmark: 문서 줄 수 목표
#   CTX_LANG            (기본 en)  — 훅 출력 언어. 설정 파일의 키 이름은
#                                    "LANG"이지만, 시스템 로케일 변수 $LANG과
#                                    충돌하지 않도록 내부 변수명은 CTX_LANG을 쓴다.
#
# 사용법(각 훅에서): 자체 기본값을 먼저 설정한 뒤 다음 줄로 불러온다 —
#   . "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/lib-config.sh" 2>/dev/null || true
# 이 파일이 없거나 로드에 실패해도 각 훅이 미리 설정해 둔 기본값이 그대로
# 쓰이므로 동작에는 지장이 없다(설정 가능성만 잃는다) — fail-safe.

: "${FEEDBACK_THRESHOLD:=5}"
: "${METRICS_THRESHOLD:=300}"
: "${COMMIT_BACKSTOP:=20}"
: "${DOC_LINE_BUDGET:=200}"
: "${CTX_LANG:=en}"

_cc_config_file=".cursor-context/config"
if [ -f "$_cc_config_file" ]; then
  while IFS='=' read -r _cc_key _cc_val || [ -n "$_cc_key" ]; do
    case "$_cc_key" in
      ''|'#'*) continue ;;
    esac
    # 값의 앞뒤 공백 제거
    _cc_val="${_cc_val#"${_cc_val%%[![:space:]]*}"}"
    _cc_val="${_cc_val%"${_cc_val##*[![:space:]]}"}"
    case "$_cc_key" in
      FEEDBACK_THRESHOLD)
        case "$_cc_val" in ''|*[!0-9]*) ;; *) FEEDBACK_THRESHOLD="$_cc_val" ;; esac ;;
      METRICS_THRESHOLD)
        case "$_cc_val" in ''|*[!0-9]*) ;; *) METRICS_THRESHOLD="$_cc_val" ;; esac ;;
      COMMIT_BACKSTOP)
        case "$_cc_val" in ''|*[!0-9]*) ;; *) COMMIT_BACKSTOP="$_cc_val" ;; esac ;;
      DOC_LINE_BUDGET)
        case "$_cc_val" in ''|*[!0-9]*) ;; *) DOC_LINE_BUDGET="$_cc_val" ;; esac ;;
      LANG)
        case "$_cc_val" in ko|en) CTX_LANG="$_cc_val" ;; esac ;;
      *) : ;;  # 알 수 없는 키는 무시 (임의 변수 주입 방지)
    esac
  done < "$_cc_config_file"
fi
unset _cc_config_file _cc_key _cc_val
