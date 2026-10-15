#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./vps_tools.sh

SYSTEM_UPDATE_MKTEMP_BIN="$(command -v mktemp)"
SYSTEM_UPDATE_TEE_BIN="$(command -v tee)"
SYSTEM_UPDATE_RM_BIN="$(command -v rm)"
SYSTEM_UPDATE_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SYSTEM_UPDATE_TEST_DIR"' EXIT

# 命令计数保存在临时文件里，兼容实现通过管道或子 shell 捕获输出。
_update_test_increment() {
  local count_file="$1" count
  count="$(< "$count_file")"
  printf '%s\n' "$((count + 1))" > "$count_file"
}

_update_test_404() {
  printf '%s\n' \
    'E: Failed to fetch http://deb.debian.org/debian-security/pool/updates/main/o/openssl/libssl1.1_1.1.1w-0%2bdeb11u8_amd64.deb  404  Not Found' >&2
}

_update_test_package_command() {
  local manager="$1" action='' upgrade_count update_count argument
  shift
  printf '%s %s\n' "$manager" "$*" >> "$UPDATE_TEST_COMMANDS"
  for argument in "$@"; do
    case "$argument" in update|upgrade) action="$argument"; break ;; esac
  done
  printf '%s\n' "$action" >> "$UPDATE_TEST_ACTIONS"
  if [[ "${LC_ALL:-}" != C ]]; then
    printf 'APT 输出语言必须固定为 C，当前为 [%s]\n' "${LC_ALL:-}" >&2
    return 94
  fi
  case "$action" in
    update)
      _update_test_increment "$UPDATE_TEST_UPDATE_COUNT"
      update_count="$(< "$UPDATE_TEST_UPDATE_COUNT")"
      if [[ " $* " != *' APT::Update::Error-Mode=any '* ]]; then
        printf '索引刷新缺少严格错误选项 APT::Update::Error-Mode=any\n' >&2
        return 94
      fi
      if [[ "$update_count" -gt 1 &&
            ( " $* " != *' Acquire::http::No-Cache=true '* || " $* " != *' Acquire::https::No-Cache=true '* ) ]]; then
        printf '404 恢复阶段刷新必须禁用 HTTP 和 HTTPS 缓存\n' >&2
        return 94
      fi
      if [[ "$UPDATE_TEST_SCENARIO" == update_failure ||
            ( "$UPDATE_TEST_SCENARIO" == recovery_index_failure && "$update_count" -gt 1 ) ]]; then
        printf '%s\n' 'E: Failed to fetch http://deb.debian.org/debian/dists/bullseye/InRelease  Temporary failure resolving deb.debian.org' >&2
        return 100
      fi
      printf '%s\n' '软件包索引刷新成功（测试桩）'
      ;;
    upgrade)
      _update_test_increment "$UPDATE_TEST_UPGRADE_COUNT"
      upgrade_count="$(< "$UPDATE_TEST_UPGRADE_COUNT")"
      if [[ "$manager" == apt-get && " $* " != *' --with-new-pkgs '* ]]; then
        printf 'apt-get upgrade 必须保留允许新增依赖的语义\n' >&2
        return 94
      fi
      case "$UPDATE_TEST_SCENARIO" in
        first_404|recovery_index_failure)
          if [[ "$upgrade_count" -eq 1 ]]; then
            _update_test_404
            return 100
          fi
          ;;
        always_404)
          _update_test_404
          return 100
          ;;
        non_404)
          printf '%s\n' 'E: Sub-process /usr/bin/dpkg returned an error code (1)' >&2
          return 100
          ;;
        release_404)
          printf '%s\n' 'E: Failed to fetch http://deb.debian.org/debian/dists/bullseye/Release  404  Not Found' >&2
          return 100
          ;;
        success_with_404) _update_test_404 ;;
      esac
      printf '%s\n' '软件包升级成功（测试桩）'
      ;;
    *)
      printf '未预期的软件包操作：%s %s\n' "$manager" "$*" >&2
      return 95
      ;;
  esac
}

_update_test_other_manager() {
  local manager="$1" action="${2:-}"
  shift
  printf '%s %s\n' "$manager" "$*" >> "$UPDATE_TEST_COMMANDS"
  if [[ "$UPDATE_TEST_SCENARIO" == other_upgrade_failure && "$action" == update ]]; then
    return 0
  fi
  printf '%s 更新失败（测试桩）\n' "$manager" >&2
  return 100
}

_update_test_unexpected_command() {
  printf '禁止执行的外部命令：%s\n' "$*" >> "$UPDATE_TEST_COMMANDS"
  return 96
}

_update_test_setup() {
  UPDATE_TEST_MANAGER="$1"
  UPDATE_TEST_SCENARIO="$2"
  UPDATE_TEST_CASE_DIR="${SYSTEM_UPDATE_TEST_DIR}/${UPDATE_TEST_MANAGER}_${UPDATE_TEST_SCENARIO}"
  mkdir -p "$UPDATE_TEST_CASE_DIR"
  UPDATE_TEST_COMMANDS="${UPDATE_TEST_CASE_DIR}/commands.log"
  UPDATE_TEST_OUTPUT="${UPDATE_TEST_CASE_DIR}/output.log"
  UPDATE_TEST_ACTIONS="${UPDATE_TEST_CASE_DIR}/actions.log"
  UPDATE_TEST_TEMPFILES="${UPDATE_TEST_CASE_DIR}/tempfiles.log"
  UPDATE_TEST_UPDATE_COUNT="${UPDATE_TEST_CASE_DIR}/update.count"
  UPDATE_TEST_UPGRADE_COUNT="${UPDATE_TEST_CASE_DIR}/upgrade.count"
  : > "$UPDATE_TEST_COMMANDS"
  : > "$UPDATE_TEST_ACTIONS"
  : > "$UPDATE_TEST_TEMPFILES"
  printf '0\n' > "$UPDATE_TEST_UPDATE_COUNT"
  printf '0\n' > "$UPDATE_TEST_UPGRADE_COUNT"
  export TMPDIR="$UPDATE_TEST_CASE_DIR"

  require_root() { return 0; }
  check_root() { return 0; }
  apt() { _update_test_package_command apt "$@"; }
  apt-get() { _update_test_package_command apt-get "$@"; }
  dnf() { _update_test_other_manager dnf "$@"; }
  yum() { _update_test_other_manager yum "$@"; }
  apk() { _update_test_other_manager apk "$@"; }
  pacman() { _update_test_unexpected_command pacman "$@"; }
  zypper() { _update_test_unexpected_command zypper "$@"; }

  # 网络与系统变更入口全部拦截，测试只允许使用临时目录中的记录文件。
  curl() { _update_test_unexpected_command curl "$@"; }
  wget() { _update_test_unexpected_command wget "$@"; }
  mktemp() {
    if [[ "$UPDATE_TEST_SCENARIO" == mktemp_failure ]]; then return 97; fi
    local argument created
    for argument in "$@"; do
      if [[ "$argument" == */* && "$argument" != "$UPDATE_TEST_CASE_DIR"/* ]]; then
        _update_test_unexpected_command mktemp "$@"
        return 96
      fi
    done
    created="$("$SYSTEM_UPDATE_MKTEMP_BIN" "$@")" || return 97
    if [[ "$created" != "$UPDATE_TEST_CASE_DIR"/* ]]; then
      _update_test_unexpected_command mktemp "$@"
      return 96
    fi
    printf '%s\n' "$created" >> "$UPDATE_TEST_TEMPFILES"
    printf '%s\n' "$created"
  }
  tee() {
    local argument
    for argument in "$@"; do
      [[ "$argument" == -* ]] && continue
      if ! grep -Fxq -- "$argument" "$UPDATE_TEST_TEMPFILES"; then
        _update_test_unexpected_command tee "$@"
        return 96
      fi
    done
    "$SYSTEM_UPDATE_TEE_BIN" "$@" || return 98
    [[ "$UPDATE_TEST_SCENARIO" != tee_failure ]]
  }
  rm() {
    local argument
    for argument in "$@"; do
      [[ "$argument" == -* ]] && continue
      if [[ "$argument" != "$UPDATE_TEST_CASE_DIR"/* ]] ||
          ! grep -Fxq -- "$argument" "$UPDATE_TEST_TEMPFILES"; then
        _update_test_unexpected_command rm "$@"
        return 96
      fi
    done
    "$SYSTEM_UPDATE_RM_BIN" "$@"
  }
  mv() { _update_test_unexpected_command mv "$@"; }
  cp() { _update_test_unexpected_command cp "$@"; }
  sudo() { _update_test_unexpected_command sudo "$@"; }
  systemctl() { _update_test_unexpected_command systemctl "$@"; }
  service() { _update_test_unexpected_command service "$@"; }

  command() {
    if [[ "${1:-}" == -v ]]; then
      case "${2:-}" in
        apt|apt-get|dnf|yum|apk|pacman|zypper)
          if [[ "$2" == "$UPDATE_TEST_MANAGER" ||
                ( "$UPDATE_TEST_MANAGER" == both && ( "$2" == apt || "$2" == apt-get ) ) ]]; then
            printf '%s\n' "$2"
            return 0
          fi
          return 1 ;;
      esac
    fi
    case "${1:-}" in
      apt|apt-get|dnf|yum|apk|pacman|zypper|curl|wget|mktemp|tee|rm|mv|cp|sudo|systemctl|service)
        local mocked_command="$1"
        shift
        "$mocked_command" "$@"
        return
        ;;
    esac
    builtin command "$@"
  }
}

_update_test_assert_equal() {
  if [[ "$1" != "$2" ]]; then
    printf '断言失败：%s；预期 [%s]，实际 [%s]\n' "$3" "$1" "$2" >&2
    return 1
  fi
}

_update_test_run_and_assert() {
  local expected_result="$1" expected_updates="$2" expected_upgrades="$3" result=0 expected_actions
  # 放在条件判断中运行，主动关闭隐式 errexit，复现主菜单的真实调用环境。
  if do_system_update > "$UPDATE_TEST_OUTPUT" 2>&1; then
    result=0
  else
    result="$?"
  fi
  _update_test_assert_equal "$expected_updates" "$(< "$UPDATE_TEST_UPDATE_COUNT")" '索引刷新次数' || return 1
  _update_test_assert_equal "$expected_upgrades" "$(< "$UPDATE_TEST_UPGRADE_COUNT")" '软件包升级次数' || return 1
  case "${expected_updates}:${expected_upgrades}" in
    0:0) expected_actions='' ;;
    1:0) expected_actions='update' ;;
    1:1) expected_actions=$'update\nupgrade' ;;
    2:1) expected_actions=$'update\nupgrade\nupdate' ;;
    2:2) expected_actions=$'update\nupgrade\nupdate\nupgrade' ;;
  esac
  _update_test_assert_equal "$expected_actions" "$(< "$UPDATE_TEST_ACTIONS")" \
    '必须先刷新索引再升级，404 恢复阶段也使用同样顺序' || return 1
  if [[ "$expected_result" == success ]]; then
    _update_test_assert_equal 0 "$result" '成功场景退出码' || return 1
    if ! grep -q '系统更新完成' "$UPDATE_TEST_OUTPUT"; then
      printf '断言失败：成功场景应显示系统更新完成\n' >&2
      return 1
    fi
  else
    if [[ "$result" == 0 ]]; then
      printf '断言失败：更新失败必须返回非零状态\n' >&2
      return 1
    fi
    if grep -q '系统更新完成' "$UPDATE_TEST_OUTPUT"; then
      printf '断言失败：更新失败不能显示系统更新完成\n' >&2
      return 1
    fi
  fi
  if grep -q '禁止执行的外部命令' "$UPDATE_TEST_COMMANDS"; then
    printf '断言失败：不应执行其他包管理器、网络或系统变更命令\n' >&2
    return 1
  fi
  local tempfile
  while IFS= read -r tempfile; do
    if [[ -e "$tempfile" ]]; then
      printf '断言失败：遗留临时日志 %s\n' "$tempfile" >&2
      return 1
    fi
  done < "$UPDATE_TEST_TEMPFILES"
}

test_404_recovery() (
  _update_test_setup "$1" first_404
  _update_test_run_and_assert success 2 2
)

test_404_retry_limit() (
  _update_test_setup "$1" always_404
  _update_test_run_and_assert failure 2 2
)

test_index_failure() (
  _update_test_setup "$1" update_failure
  _update_test_run_and_assert failure 1 0
)

test_non_404_failure() (
  _update_test_setup "$1" non_404
  _update_test_run_and_assert failure 1 1
)

test_recovery_index_failure() (
  _update_test_setup "$1" recovery_index_failure
  _update_test_run_and_assert failure 2 1
)

test_normal_success() (
  _update_test_setup "$1" success
  _update_test_run_and_assert success 1 1
)

test_release_404_not_retried() (
  _update_test_setup "$1" release_404
  _update_test_run_and_assert failure 1 1
)

test_success_with_404_not_retried() (
  _update_test_setup "$1" success_with_404
  _update_test_run_and_assert success 1 1
)

test_tee_failure() (
  _update_test_setup "$1" tee_failure
  _update_test_run_and_assert failure 1 1
)

test_mktemp_failure() (
  _update_test_setup "$1" mktemp_failure
  _update_test_run_and_assert failure 0 0
)

test_apt_get_preferred() (
  _update_test_setup both success
  _update_test_run_and_assert success 1 1 || return 1
  if grep -q '^apt ' "$UPDATE_TEST_COMMANDS"; then
    printf '断言失败：同时存在 apt-get 和 apt 时应优先使用 apt-get\n' >&2
    return 1
  fi
  if ! grep -q '^apt-get ' "$UPDATE_TEST_COMMANDS"; then
    printf '断言失败：未调用 apt-get\n' >&2
    return 1
  fi
)

test_other_manager_failure() (
  local manager="$1" result=0 expected_commands
  _update_test_setup "$manager" other_failure
  if do_system_update > "$UPDATE_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$result" == 0 ]] || grep -q '系统更新完成' "$UPDATE_TEST_OUTPUT"; then
    printf '断言失败：%s 更新失败不能返回成功或显示系统更新完成\n' "$manager" >&2
    return 1
  fi
  case "$manager" in
    dnf) expected_commands='dnf upgrade -y' ;;
    yum) expected_commands='yum update -y' ;;
    apk) expected_commands='apk update' ;;
  esac
  _update_test_assert_equal "$expected_commands" "$(< "$UPDATE_TEST_COMMANDS")" \
    '失败后不能执行后续操作'
)

test_apk_upgrade_failure() (
  local result=0
  _update_test_setup apk other_upgrade_failure
  if do_system_update > "$UPDATE_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$result" == 0 ]] || grep -q '系统更新完成' "$UPDATE_TEST_OUTPUT"; then
    printf '断言失败：apk upgrade 失败不能返回成功或显示系统更新完成\n' >&2
    return 1
  fi
  _update_test_assert_equal $'apk update\napk upgrade' "$(< "$UPDATE_TEST_COMMANDS")" \
    'apk 升级失败后不能执行后续操作'
)

UPDATE_TEST_FAILURES=0
UPDATE_TEST_TOTAL=0
run_update_case() {
  local manager="$1" scenario="$2" label="$3" test_function="$4"
  UPDATE_TEST_TOTAL="$((UPDATE_TEST_TOTAL + 1))"
  if "$test_function" "$manager"; then
    printf 'PASS: %s：%s\n' "$manager" "$label"
  else
    UPDATE_TEST_FAILURES="$((UPDATE_TEST_FAILURES + 1))"
    printf 'FAIL: %s：%s\n' "$manager" "$label" >&2
    printf '%s\n' '命令记录：' >&2
    cat "${SYSTEM_UPDATE_TEST_DIR}/${manager}_${scenario}/commands.log" >&2
    printf '%s\n' '函数输出：' >&2
    cat "${SYSTEM_UPDATE_TEST_DIR}/${manager}_${scenario}/output.log" >&2
  fi
}

for manager in apt apt-get; do
  run_update_case "$manager" first_404 '旧版本软件包 404 后刷新索引并重试成功' test_404_recovery
  run_update_case "$manager" always_404 '404 持续失败时最多重试一次' test_404_retry_limit
  run_update_case "$manager" update_failure '索引刷新失败不升级且不显示完成' test_index_failure
  run_update_case "$manager" non_404 '非 404 升级失败不重试且不显示完成' test_non_404_failure
  run_update_case "$manager" recovery_index_failure '恢复阶段刷新索引失败不再升级' test_recovery_index_failure
  run_update_case "$manager" success '正常升级只执行一次' test_normal_success
  run_update_case "$manager" release_404 'Release 404 不当作软件包下载 404 重试' test_release_404_not_retried
  run_update_case "$manager" success_with_404 '包含 404 文本但升级成功时不重试' test_success_with_404_not_retried
  run_update_case "$manager" tee_failure '日志写入失败不误报成功或触发重试' test_tee_failure
  run_update_case "$manager" mktemp_failure '临时日志创建失败不开始更新' test_mktemp_failure
done
run_update_case both success 'apt-get 与 apt 共存时优先 apt-get' test_apt_get_preferred
for manager in dnf yum apk; do
  run_update_case "$manager" other_failure '更新失败必须显式传播且不执行后续' test_other_manager_failure
done
run_update_case apk other_upgrade_failure '索引成功但升级失败时不显示完成' test_apk_upgrade_failure

printf '系统更新测试：共 %s 项，失败 %s 项\n' "$UPDATE_TEST_TOTAL" "$UPDATE_TEST_FAILURES"
[[ "$UPDATE_TEST_FAILURES" == 0 ]]
