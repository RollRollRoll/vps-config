#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./vps_tools.sh
UBUNTU_TEST_CHECK_TARGET_IMPL="$(declare -f _ubuntu_lts_check_target)"
UBUNTU_TEST_CHECK_SPACE_IMPL="$(declare -f _ubuntu_lts_check_space)"
UBUNTU_TEST_CHECK_PACKAGES_IMPL="$(declare -f _ubuntu_lts_check_packages)"
UBUNTU_TEST_CHECK_PLATFORM_IMPL="$(declare -f _ubuntu_lts_check_platform)"

UBUNTU_TEST_TEE_BIN="$(command -v tee)"
UBUNTU_TEST_MKDIR_BIN="$(command -v mkdir)"
UBUNTU_TEST_CHMOD_BIN="$(command -v chmod)"
UBUNTU_TEST_RM_BIN="$(command -v rm)"
UBUNTU_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$UBUNTU_TEST_DIR"' EXIT

_ubuntu_test_fail() {
  printf '断言失败：%s\n' "$*" >&2
  return 1
}

_ubuntu_test_equal() {
  [[ "$1" == "$2" ]] || _ubuntu_test_fail "$3；预期 [$1]，实际 [$2]"
}

_ubuntu_test_record() {
  printf '%s' "$1" >> "$UBUNTU_TEST_COMMANDS"
  shift
  if [[ "$#" -gt 0 ]]; then printf ' <%s>' "$@" >> "$UBUNTU_TEST_COMMANDS"; fi
  printf '\n' >> "$UBUNTU_TEST_COMMANDS"
}

_ubuntu_test_forbidden() {
  _ubuntu_test_record '禁止执行的外部命令' "$@"
  return 96
}

_ubuntu_test_fs_command() {
  local executable="$1" argument
  shift
  for argument in "$@"; do
    case "$argument" in
      -*|[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) continue ;;
    esac
    if [[ "$argument" != "$UBUNTU_TEST_CASE_DIR" && "$argument" != "$UBUNTU_TEST_CASE_DIR"/* ]]; then
      _ubuntu_test_forbidden "$executable" "$@"
      return 96
    fi
  done
  "$executable" "$@"
}

_ubuntu_test_package_command() {
  _ubuntu_test_record apt-get "$@"
  local argument action='' simulated=0
  for argument in "$@"; do
    case "$argument" in
      -s|--simulate) simulated=1 ;;
      update|full-upgrade|install|autoremove|autoclean|clean) action="$argument" ;;
    esac
  done
  if [[ "$action" == autoremove && "$simulated" == 1 ]]; then action=preview; fi
  printf '%s\n' "$action" >> "$UBUNTU_TEST_ACTIONS"
  if [[ "$UBUNTU_TEST_SCENARIO" == "${action}_failure" ]]; then
    printf '软件包命令失败（测试桩）：%s\n' "$action" >&2
    return 100
  fi
  printf '软件包命令成功（测试桩）：%s\n' "$action"
}

_ubuntu_test_setup() {
  UBUNTU_TEST_CASE="$1"
  UBUNTU_TEST_SCENARIO="${2:-success}"
  UBUNTU_TEST_CASE_DIR="${UBUNTU_TEST_DIR}/${UBUNTU_TEST_CASE}"
  mkdir -p "$UBUNTU_TEST_CASE_DIR"
  UBUNTU_LTS_STATE_DIR="${UBUNTU_TEST_CASE_DIR}/state"
  UBUNTU_LTS_BACKUP_DIR="${UBUNTU_TEST_CASE_DIR}/backups"
  UBUNTU_LTS_LOG_FILE="${UBUNTU_TEST_CASE_DIR}/upgrade.log"
  UBUNTU_TEST_COMMANDS="${UBUNTU_TEST_CASE_DIR}/commands.log"
  UBUNTU_TEST_ACTIONS="${UBUNTU_TEST_CASE_DIR}/actions.log"
  UBUNTU_TEST_OUTPUT="${UBUNTU_TEST_CASE_DIR}/output.log"
  UBUNTU_TEST_VERSION_FILE="${UBUNTU_TEST_CASE_DIR}/version"
  : > "$UBUNTU_TEST_COMMANDS"
  : > "$UBUNTU_TEST_ACTIONS"
  printf '24.04\n' > "$UBUNTU_TEST_VERSION_FILE"
  UBUNTU_TEST_BOOT_ID=boot-before-upgrade
  UBUNTU_TEST_REBOOT_REQUIRED=0

  require_root() { return 0; }
  check_root() { return 0; }
  _ubuntu_lts_os_version() { cat "$UBUNTU_TEST_VERSION_FILE"; }
  _ubuntu_lts_check_platform() {
    local version
    version="$(_ubuntu_lts_os_version)" || return 1
    [[ "$version" == "$1" ]]
  }
  _ubuntu_lts_boot_id() { printf '%s\n' "$UBUNTU_TEST_BOOT_ID"; }
  _ubuntu_lts_reboot_required() { [[ "$UBUNTU_TEST_REBOOT_REQUIRED" == 1 ]]; }
  _ubuntu_lts_check_space() { [[ "$UBUNTU_TEST_SCENARIO" != space_failure ]]; }
  _ubuntu_lts_check_packages() { [[ "$UBUNTU_TEST_SCENARIO" != packages_failure ]]; }
  _ubuntu_lts_check_target() { [[ "$UBUNTU_TEST_SCENARIO" != target_failure ]]; }
  _ubuntu_lts_backup() {
    if [[ "$UBUNTU_TEST_SCENARIO" == backup_failure ]]; then return 1; fi
    mkdir -p "${UBUNTU_LTS_BACKUP_DIR}/snapshot" || return 1
    printf '%s\n' "${UBUNTU_LTS_BACKUP_DIR}/snapshot"
  }
  apt-get() { _ubuntu_test_package_command "$@"; }
  mkdir() { _ubuntu_test_fs_command "$UBUNTU_TEST_MKDIR_BIN" "$@"; }
  chmod() { _ubuntu_test_fs_command "$UBUNTU_TEST_CHMOD_BIN" "$@"; }
  rm() { _ubuntu_test_fs_command "$UBUNTU_TEST_RM_BIN" "$@"; }
  do-release-upgrade() {
    _ubuntu_test_record do-release-upgrade "$@"
    if [[ "$UBUNTU_TEST_SCENARIO" == release_failure ]]; then return 100; fi
    if [[ "$UBUNTU_TEST_SCENARIO" != release_cancelled ]]; then
      printf '26.04\n' > "$UBUNTU_TEST_VERSION_FILE"
    fi
    if [[ "$UBUNTU_TEST_SCENARIO" == release_partial_failure ]]; then return 100; fi
    printf '发行版升级成功（测试桩）\n'
  }
  tee() {
    local argument
    for argument in "$@"; do
      [[ "$argument" == -* ]] && continue
      if [[ "$argument" != "$UBUNTU_TEST_CASE_DIR"/* ]]; then
        _ubuntu_test_forbidden tee "$@"
        return 96
      fi
    done
    "$UBUNTU_TEST_TEE_BIN" "$@" || return 98
    [[ "$UBUNTU_TEST_SCENARIO" != tee_failure ]]
  }
  reboot() { _ubuntu_test_forbidden reboot "$@"; }
  shutdown() { _ubuntu_test_forbidden shutdown "$@"; }
  flock() { [[ "$UBUNTU_TEST_SCENARIO" != locked ]]; }
  systemctl() {
    if [[ "$*" == '--failed --no-legend --plain' ]]; then
      _ubuntu_test_record systemctl "$@"
      if [[ "$UBUNTU_TEST_SCENARIO" == failed_service ]]; then
        printf 'docker.service loaded failed failed\n'
      fi
      return 0
    fi
    _ubuntu_test_forbidden systemctl "$@"
  }
  service() { _ubuntu_test_forbidden service "$@"; }
  sudo() { _ubuntu_test_forbidden sudo "$@"; }
  curl() { _ubuntu_test_forbidden curl "$@"; }
  wget() { _ubuntu_test_forbidden wget "$@"; }
  apt() { _ubuntu_test_forbidden apt "$@"; }
  dpkg() { _ubuntu_test_forbidden dpkg "$@"; }
  tar() { _ubuntu_test_forbidden tar "$@"; }
  cp() { _ubuntu_test_forbidden cp "$@"; }
  mv() { _ubuntu_test_forbidden mv "$@"; }
  command() {
    if [[ "${1:-}" == -v ]]; then
      case "${2:-}" in
        apt-get|do-release-upgrade) printf '%s\n' "$2"; return 0 ;;
      esac
    fi
    case "${1:-}" in
      apt-get|do-release-upgrade|tee|mkdir|chmod|rm|flock|reboot|shutdown|systemctl|service|sudo|curl|wget|apt|dpkg|tar|cp|mv)
        local mocked_command="$1"
        shift
        "$mocked_command" "$@"
        return
        ;;
    esac
    builtin command "$@"
  }
}

_ubuntu_test_run() {
  local expected="$1" phase="$2" answer="${3:-}" result=0
  if [[ "$#" -lt 3 ]]; then
    case "$phase" in prepare) answer=PREPARE ;; cleanup) answer=$'HEALTHY\nREMOVE' ;; esac
  fi
  # 条件上下文会禁用函数内的隐式 errexit，覆盖主菜单的真实调用方式。
  if do_ubuntu_lts_upgrade "$phase" <<< "$answer" > "$UBUNTU_TEST_OUTPUT" 2>&1; then
    result=0
  else
    result="$?"
  fi
  if [[ "$expected" == success ]]; then
    if ! _ubuntu_test_equal 0 "$result" "$phase 成功场景返回值"; then
      cat "$UBUNTU_TEST_OUTPUT" >&2
      return 1
    fi
  elif [[ "$result" == 0 ]]; then
    _ubuntu_test_fail "$phase 失败必须显式返回非零状态"
    cat "$UBUNTU_TEST_OUTPUT" >&2
    return 1
  fi
  if grep -q '禁止执行的外部命令' "$UBUNTU_TEST_COMMANDS"; then
    _ubuntu_test_fail '测试触发了未授权的网络或系统变更命令'
    return 1
  fi
}

_ubuntu_test_prepared() {
  mkdir -p "$UBUNTU_LTS_STATE_DIR" "${UBUNTU_LTS_BACKUP_DIR}/snapshot"
  printf '%s\n' "${UBUNTU_LTS_BACKUP_DIR}/snapshot" > "${UBUNTU_LTS_STATE_DIR}/prepared"
}

_ubuntu_test_upgraded() {
  _ubuntu_test_prepared
  printf '26.04\n' > "$UBUNTU_TEST_VERSION_FILE"
  printf 'boot-before-upgrade\n' > "${UBUNTU_LTS_STATE_DIR}/upgrade-started-boot"
  : > "${UBUNTU_LTS_STATE_DIR}/upgraded"
  UBUNTU_TEST_BOOT_ID=boot-after-upgrade
}

_ubuntu_test_no_package_commands() {
  _ubuntu_test_equal '' "$(< "$UBUNTU_TEST_ACTIONS")" '安全条件不满足时不能执行软件包操作'
}

_ubuntu_test_no_release_command() {
  if grep -q '^do-release-upgrade' "$UBUNTU_TEST_COMMANDS"; then
    _ubuntu_test_fail '未通过升级检查时不能启动发行版升级'
    return 1
  fi
}

_ubuntu_test_no_marker() {
  [[ ! -s "${UBUNTU_LTS_STATE_DIR}/$1" ]] || _ubuntu_test_fail "失败后不能生成 $1 完成状态"
}

test_prepare_wrong_version() (
  _ubuntu_test_setup prepare_wrong_version
  printf '22.04\n' > "$UBUNTU_TEST_VERSION_FILE"
  _ubuntu_test_run failure prepare || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker prepared
)

test_prepare_prerequisite_failure() (
  local scenario="$1"
  _ubuntu_test_setup "prepare_${scenario}" "$scenario"
  _ubuntu_test_run failure prepare || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker prepared
)

test_prepare_command_failure() (
  local scenario="$1" expected_actions
  _ubuntu_test_setup "prepare_${scenario}" "$scenario"
  _ubuntu_test_run failure prepare || return 1
  case "$scenario" in
    update_failure|tee_failure) expected_actions=update ;;
    full-upgrade_failure) expected_actions=$'update\nfull-upgrade' ;;
    install_failure) expected_actions=$'update\nfull-upgrade\ninstall' ;;
  esac
  _ubuntu_test_equal "$expected_actions" "$(< "$UBUNTU_TEST_ACTIONS")" \
    '准备阶段任一命令失败都不能继续执行后续命令' || return 1
  _ubuntu_test_no_marker prepared
)

test_prepare_success() (
  _ubuntu_test_setup prepare_success
  _ubuntu_test_run success prepare || return 1
  [[ -s "${UBUNTU_LTS_STATE_DIR}/prepared" ]] ||
    { _ubuntu_test_fail '准备成功必须记录可用的备份目录'; return 1; }
  _ubuntu_test_equal "${UBUNTU_LTS_BACKUP_DIR}/snapshot" "$(< "${UBUNTU_LTS_STATE_DIR}/prepared")" \
    '准备标记必须保存本次备份目录'
)

test_prepare_cancelled() (
  _ubuntu_test_setup prepare_cancelled
  _ubuntu_test_run success prepare '' || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker prepared || return 1
  [[ ! -d "${UBUNTU_LTS_BACKUP_DIR}/snapshot" ]] || _ubuntu_test_fail '取消 PREPARE 时不能开始备份'
)

test_prepare_invalidates_ready_marker() (
  _ubuntu_test_setup prepare_invalidates_ready_marker update_failure
  _ubuntu_test_prepared
  _ubuntu_test_run failure prepare || return 1
  _ubuntu_test_no_marker prepared
)

test_upgrade_unprepared() (
  _ubuntu_test_setup upgrade_unprepared
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_release_command || return 1
  _ubuntu_test_no_marker upgraded
)

test_upgrade_reboot_required() (
  _ubuntu_test_setup upgrade_reboot_required
  _ubuntu_test_prepared
  UBUNTU_TEST_REBOOT_REQUIRED=1
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  _ubuntu_test_no_release_command || return 1
  _ubuntu_test_no_marker upgraded
)

test_upgrade_target_failure() (
  _ubuntu_test_setup upgrade_target_failure target_failure
  _ubuntu_test_prepared
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  _ubuntu_test_no_release_command || return 1
  _ubuntu_test_no_marker upgraded
)

test_upgrade_cancelled() (
  local answer
  for answer in '' y yes upgrade REMOVE; do
    _ubuntu_test_setup "upgrade_cancelled_${answer:-empty}"
    _ubuntu_test_prepared
    _ubuntu_test_run success upgrade "$answer" || return 1
    _ubuntu_test_no_release_command || return 1
    _ubuntu_test_no_marker upgraded || return 1
  done
)

test_upgrade_release_failure() (
  _ubuntu_test_setup upgrade_release_failure release_failure
  _ubuntu_test_prepared
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  [[ "$(< "$UBUNTU_TEST_COMMANDS")" == *do-release-upgrade* ]] ||
    { _ubuntu_test_fail '应实际调用已设桩的官方发行版升级工具'; return 1; }
  _ubuntu_test_no_marker upgraded
)

test_upgrade_release_cancelled() (
  _ubuntu_test_setup upgrade_release_cancelled release_cancelled
  _ubuntu_test_prepared
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  _ubuntu_test_no_marker upgraded || return 1
  [[ -s "${UBUNTU_LTS_STATE_DIR}/upgrade-failed" ]] || _ubuntu_test_fail '升级未完成必须持久记录失败'
)

test_cleanup_after_partial_upgrade_failure() (
  _ubuntu_test_setup cleanup_after_partial_upgrade_failure release_partial_failure
  _ubuntu_test_prepared
  _ubuntu_test_run failure upgrade UPGRADE || return 1
  _ubuntu_test_equal 26.04 "$(< "$UBUNTU_TEST_VERSION_FILE")" '模拟部分升级已改为目标版本' || return 1
  [[ -s "${UBUNTU_LTS_STATE_DIR}/upgrade-failed" ]] ||
    { _ubuntu_test_fail '部分升级失败必须持久记录'; return 1; }
  _ubuntu_test_no_marker upgraded || return 1
  UBUNTU_TEST_BOOT_ID=boot-after-partial-upgrade
  : > "$UBUNTU_TEST_ACTIONS"
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_upgrade_success() (
  _ubuntu_test_setup upgrade_success
  _ubuntu_test_prepared
  _ubuntu_test_run success upgrade UPGRADE || return 1
  [[ -s "${UBUNTU_LTS_STATE_DIR}/upgraded" ]] ||
    { _ubuntu_test_fail '升级成功应记录完成状态'; return 1; }
  _ubuntu_test_equal boot-before-upgrade "$(< "${UBUNTU_LTS_STATE_DIR}/upgrade-started-boot")" \
    '升级启动前必须记录当前启动标识'
)

test_cleanup_unprepared() (
  _ubuntu_test_setup cleanup_unprepared
  printf '26.04\n' > "$UBUNTU_TEST_VERSION_FILE"
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_before_reboot() (
  _ubuntu_test_setup cleanup_before_reboot
  _ubuntu_test_upgraded
  UBUNTU_TEST_BOOT_ID=boot-before-upgrade
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_wrong_version() (
  _ubuntu_test_setup cleanup_wrong_version
  _ubuntu_test_upgraded
  printf '24.04\n' > "$UBUNTU_TEST_VERSION_FILE"
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_cancelled() (
  local answer
  for answer in '' y yes remove UPGRADE; do
    _ubuntu_test_setup "cleanup_cancelled_${answer:-empty}"
    _ubuntu_test_upgraded
    _ubuntu_test_run success cleanup "$(printf 'HEALTHY\n%s' "$answer")" || return 1
    if grep -Eq '^(autoremove|autoclean|clean)$' "$UBUNTU_TEST_ACTIONS"; then
      _ubuntu_test_fail '没有输入 REMOVE 时不能清理真实软件包或缓存'
      return 1
    fi
    _ubuntu_test_no_marker cleaned || return 1
  done
)

test_cleanup_health_unconfirmed() (
  _ubuntu_test_setup cleanup_health_unconfirmed
  _ubuntu_test_upgraded
  _ubuntu_test_run success cleanup REMOVE || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_failed_service() (
  _ubuntu_test_setup cleanup_failed_service failed_service
  _ubuntu_test_upgraded
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_requires_reboot() (
  _ubuntu_test_setup cleanup_requires_reboot
  _ubuntu_test_upgraded
  UBUNTU_TEST_REBOOT_REQUIRED=1
  _ubuntu_test_run failure cleanup || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker cleaned
)

test_cleanup_preview_failure() (
  _ubuntu_test_setup cleanup_preview_failure preview_failure
  _ubuntu_test_upgraded
  _ubuntu_test_run failure cleanup || return 1
  if grep -Eq '^(autoremove|autoclean|clean)$' "$UBUNTU_TEST_ACTIONS"; then
    _ubuntu_test_fail '模拟清理失败后不能执行真实清理'
    return 1
  fi
  _ubuntu_test_no_marker cleaned
)

test_cleanup_autoremove_failure() (
  _ubuntu_test_setup cleanup_autoremove_failure autoremove_failure
  _ubuntu_test_upgraded
  _ubuntu_test_run failure cleanup || return 1
  if grep -Eq '^(autoclean|clean)$' "$UBUNTU_TEST_ACTIONS"; then
    _ubuntu_test_fail '旧软件包清理失败后不能继续清理缓存'
    return 1
  fi
  _ubuntu_test_no_marker cleaned
)

test_cleanup_success() (
  _ubuntu_test_setup cleanup_success
  _ubuntu_test_upgraded
  _ubuntu_test_run success cleanup || return 1
  _ubuntu_test_equal $'update\nfull-upgrade\npreview\nautoremove\nautoclean\nclean' \
    "$(< "$UBUNTU_TEST_ACTIONS")" '清理应先更新、升级、模拟，确认后再删除与清缓存' || return 1
  [[ -e "${UBUNTU_LTS_STATE_DIR}/cleaned" ]] || _ubuntu_test_fail '清理成功应记录完成状态'
)

test_status_without_root() (
  _ubuntu_test_setup status_without_root
  require_root() { return 1; }
  check_root() { return 1; }
  _ubuntu_test_run success status || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_release_command || return 1
  [[ ! -d "$UBUNTU_LTS_STATE_DIR" ]] || _ubuntu_test_fail '只读状态不能初始化状态目录'
)

test_mutations_require_root() (
  local phase
  for phase in prepare upgrade cleanup; do
    _ubuntu_test_setup "${phase}_without_root"
    require_root() { return 1; }
    check_root() { return 1; }
    _ubuntu_test_run failure "$phase" UPGRADE || return 1
    _ubuntu_test_no_package_commands || return 1
    _ubuntu_test_no_release_command || return 1
    [[ ! -d "$UBUNTU_LTS_STATE_DIR" ]] || _ubuntu_test_fail '权限不足时不能初始化状态目录'
  done
)

test_concurrent_stage_rejected() (
  _ubuntu_test_setup concurrent_stage_rejected locked
  _ubuntu_test_run failure prepare || return 1
  _ubuntu_test_no_package_commands || return 1
  _ubuntu_test_no_marker prepared
)

test_symlink_path_rejected() (
  local entry="$1" destination
  _ubuntu_test_setup "symlink_${entry}"
  destination="${UBUNTU_TEST_CASE_DIR}/symlink-target"
  if [[ "$entry" != log ]]; then
    mkdir -p "$UBUNTU_LTS_STATE_DIR"
    ln -s "$destination" "${UBUNTU_LTS_STATE_DIR}/${entry}"
  else
    ln -s "$destination" "$UBUNTU_LTS_LOG_FILE"
  fi
  _ubuntu_test_run failure prepare || return 1
  _ubuntu_test_no_package_commands || return 1
  [[ ! -e "$destination" ]] || _ubuntu_test_fail '拒绝符号链接后不能创建它指向的文件'
)

test_target_helper() (
  local output="$1" command_status="$2" expected="$3"
  _ubuntu_test_setup target_helper
  eval "$UBUNTU_TEST_CHECK_TARGET_IMPL"
  do-release-upgrade() {
    _ubuntu_test_equal '-c' "$*" '目标检查仅能查询官方通道，不能使用开发版参数' || return 1
    printf '%s\n' "$output"
    return "$command_status"
  }
  local result=0
  if _ubuntu_lts_check_target > "$UBUNTU_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$expected" == success ]]; then
    _ubuntu_test_equal 0 "$result" '官方 LTS 目标检查返回值'
  else
    [[ "$result" != 0 ]] || _ubuntu_test_fail '错误版本或检查失败不能视为官方目标可用'
  fi
)

test_platform_helper() (
  local scenario="$1" expected="$2" result=0
  _ubuntu_test_setup "platform_helper_${scenario}"
  eval "$UBUNTU_TEST_CHECK_PLATFORM_IMPL"
  _ubuntu_lts_os_version() {
    case "$scenario" in
      non_ubuntu) return 1 ;;
      wrong_version) printf '22.04\n' ;;
      *) printf '24.04\n' ;;
    esac
  }
  systemd-detect-virt() {
    _ubuntu_test_equal '--container --quiet' "$*" '容器检测仅查询容器状态' || return 1
    [[ "$scenario" == container ]]
  }
  stat() {
    _ubuntu_test_equal '-fc %T /sys/fs/cgroup' "$*" 'cgroup 检查应查询统一挂载点文件系统' || return 1
    case "$scenario" in
      cgroup_v1) printf 'tmpfs\n' ;;
      cgroup_hybrid) printf 'tmpfs\n' ;;
      stat_failure) return 1 ;;
      *) printf 'cgroup2fs\n' ;;
    esac
  }
  if _ubuntu_lts_check_platform 24.04 > "$UBUNTU_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$expected" == success ]]; then
    _ubuntu_test_equal 0 "$result" '受支持的 Ubuntu 与 cgroup v2 应通过平台检查'
  else
    [[ "$result" != 0 ]] || _ubuntu_test_fail '不支持的系统、容器或 cgroup 模式必须停止'
  fi
)

test_space_helper() (
  local scenario="$1" expected="$2" result=0
  _ubuntu_test_setup "space_helper_${scenario}"
  eval "$UBUNTU_TEST_CHECK_SPACE_IMPL"
  df() {
    local available=6000000
    if [[ "$scenario" == command_failure ]]; then return 1; fi
    if [[ "$scenario" == insufficient && "$*" == *'/boot' ]]; then available=100000; fi
    if [[ "$scenario" == invalid ]]; then available=unknown; fi
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
    printf '/dev/test 10000000 1000000 %s 10%% /\n' "$available"
  }
  if _ubuntu_lts_check_space > "$UBUNTU_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$expected" == success ]]; then
    _ubuntu_test_equal 0 "$result" '足够磁盘空间应通过预检'
  else
    [[ "$result" != 0 ]] || _ubuntu_test_fail '磁盘空间不足或无法查询时必须停止'
  fi
)

test_packages_helper() (
  local scenario="$1" expected="$2" result=0
  _ubuntu_test_setup "packages_helper_${scenario}"
  eval "$UBUNTU_TEST_CHECK_PACKAGES_IMPL"
  dpkg() {
    _ubuntu_test_equal --audit "$*" 'dpkg 健康检查参数' || return 1
    case "$scenario" in audit_failure) return 1 ;; audit_dirty) printf 'half configured package\n' ;; esac
  }
  apt-mark() {
    _ubuntu_test_equal showhold "$*" '保留软件包检查参数' || return 1
    case "$scenario" in hold_failure) return 1 ;; holds) printf 'held-package\n' ;; esac
  }
  if _ubuntu_lts_check_packages > "$UBUNTU_TEST_OUTPUT" 2>&1; then result=0; else result="$?"; fi
  if [[ "$expected" == success ]]; then
    _ubuntu_test_equal 0 "$result" '健康的软件包状态应通过预检'
  else
    [[ "$result" != 0 ]] || _ubuntu_test_fail '异常或无法查询的软件包状态必须停止'
  fi
)

test_system_update_menu_dispatch() (
  _ubuntu_test_setup system_update_menu
  do_system_update() { _ubuntu_test_record package-update; }
  do_ubuntu_lts_upgrade_menu() { _ubuntu_test_record lts-menu; }
  do_system_update_menu <<< $'1\n2\n0' > "$UBUNTU_TEST_OUTPUT" 2>&1 || return 1
  _ubuntu_test_equal $'package-update\nlts-menu' "$(< "$UBUNTU_TEST_COMMANDS")" \
    '系统更新子菜单应保留包更新，并提供 Ubuntu LTS 升级入口'
)

test_lts_menu_dispatch() (
  _ubuntu_test_setup lts_menu
  do_ubuntu_lts_upgrade() { _ubuntu_test_record phase "$@"; }
  do_ubuntu_lts_upgrade_menu <<< $'1\n2\n3\n4\n0' > "$UBUNTU_TEST_OUTPUT" 2>&1 || return 1
  _ubuntu_test_equal $'phase <prepare>\nphase <upgrade>\nphase <cleanup>\nphase <status>' \
    "$(< "$UBUNTU_TEST_COMMANDS")" 'Ubuntu LTS 子菜单应正确分发四个阶段'
)

UBUNTU_TEST_TOTAL=0
UBUNTU_TEST_FAILURES=0
run_ubuntu_case() {
  local label="$1" function_name="$2"
  shift 2
  UBUNTU_TEST_TOTAL="$((UBUNTU_TEST_TOTAL + 1))"
  if "$function_name" "$@"; then
    printf 'PASS: %s\n' "$label"
  else
    UBUNTU_TEST_FAILURES="$((UBUNTU_TEST_FAILURES + 1))"
    printf 'FAIL: %s\n' "$label" >&2
  fi
}

run_ubuntu_case '准备阶段拒绝错误系统版本' test_prepare_wrong_version
for scenario in space_failure packages_failure backup_failure; do
  run_ubuntu_case "准备阶段前置检查失败：${scenario}" test_prepare_prerequisite_failure "$scenario"
done
for scenario in update_failure full-upgrade_failure install_failure tee_failure; do
  run_ubuntu_case "准备阶段命令失败：${scenario}" test_prepare_command_failure "$scenario"
done
run_ubuntu_case '准备成功记录备份' test_prepare_success
run_ubuntu_case '取消 PREPARE 不开始备份与更新' test_prepare_cancelled
run_ubuntu_case '重新准备失败会撤销先前就绪状态' test_prepare_invalidates_ready_marker
run_ubuntu_case '未准备不能升级' test_upgrade_unprepared
run_ubuntu_case '待重启不能升级' test_upgrade_reboot_required
run_ubuntu_case '官方目标检查失败不能升级' test_upgrade_target_failure
run_ubuntu_case '必须精确输入 UPGRADE' test_upgrade_cancelled
run_ubuntu_case '发行版升级失败不写成功状态' test_upgrade_release_failure
run_ubuntu_case '升级器退出成功但版本未变不能写成功状态' test_upgrade_release_cancelled
run_ubuntu_case '部分升级失败后即使版本变更并重启也禁止清理' test_cleanup_after_partial_upgrade_failure
run_ubuntu_case '升级成功记录启动标识' test_upgrade_success
run_ubuntu_case '未升级不能清理' test_cleanup_unprepared
run_ubuntu_case '升级后未重启不能清理' test_cleanup_before_reboot
run_ubuntu_case '清理阶段拒绝错误系统版本' test_cleanup_wrong_version
run_ubuntu_case '必须精确输入 REMOVE' test_cleanup_cancelled
run_ubuntu_case '确认业务正常之前不开始清理' test_cleanup_health_unconfirmed
run_ubuntu_case '存在失败服务时不开始清理' test_cleanup_failed_service
run_ubuntu_case '仍有重启要求时不开始清理' test_cleanup_requires_reboot
run_ubuntu_case '清理预览失败不执行删除' test_cleanup_preview_failure
run_ubuntu_case '软件包清理失败不继续清理缓存' test_cleanup_autoremove_failure
run_ubuntu_case '清理成功遵守更新、预览与删除顺序' test_cleanup_success
run_ubuntu_case '状态查询无需 root 且不写目录' test_status_without_root
run_ubuntu_case '所有变更阶段都要求 root' test_mutations_require_root
run_ubuntu_case '并发执行阶段被锁阻止' test_concurrent_stage_rejected
run_ubuntu_case '拒绝日志符号链接' test_symlink_path_rejected log
run_ubuntu_case '拒绝状态文件符号链接' test_symlink_path_rejected prepared
run_ubuntu_case '拒绝升级失败状态符号链接' test_symlink_path_rejected upgrade-failed
run_ubuntu_case '官方目标接受 26.04 LTS' test_target_helper "New release '26.04 LTS' available." 0 success
run_ubuntu_case '官方目标接受 26.04.1 LTS' test_target_helper "New release '26.04.1 LTS' available." 0 success
run_ubuntu_case '官方目标拒绝其他发行版' test_target_helper "New release '26.10' available." 0 failure
run_ubuntu_case '官方目标拒绝含版本号的非目标文本' test_target_helper 'No new release found. Current version is 26.04.' 0 failure
run_ubuntu_case '官方目标拒绝非 LTS 与开发版文本' test_target_helper "New release '26.04 development version' available." 0 failure
run_ubuntu_case '官方检查失败即使显示目标也拒绝' test_target_helper "New release '26.04.1 LTS' available." 1 failure
run_ubuntu_case 'Ubuntu 与 cgroup v2 可通过平台检查' test_platform_helper success success
for scenario in non_ubuntu wrong_version container cgroup_v1 cgroup_hybrid stat_failure; do
  run_ubuntu_case "平台预检拒绝异常：${scenario}" test_platform_helper "$scenario" failure
done
run_ubuntu_case '足够磁盘空间可通过' test_space_helper success success
for scenario in insufficient invalid command_failure; do
  run_ubuntu_case "磁盘预检拒绝异常：${scenario}" test_space_helper "$scenario" failure
done
run_ubuntu_case '健康的软件包状态可通过' test_packages_helper success success
for scenario in audit_failure audit_dirty hold_failure holds; do
  run_ubuntu_case "软件包预检拒绝异常：${scenario}" test_packages_helper "$scenario" failure
done
run_ubuntu_case '系统更新子菜单分发' test_system_update_menu_dispatch
run_ubuntu_case 'Ubuntu LTS 子菜单分发' test_lts_menu_dispatch

printf 'Ubuntu LTS 升级测试：共 %s 项，失败 %s 项\n' "$UBUNTU_TEST_TOTAL" "$UBUNTU_TEST_FAILURES"
[[ "$UBUNTU_TEST_FAILURES" == 0 ]]
