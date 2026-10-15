#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source ./vps_tools.sh
TAILSCALE_START_SERVICE_IMPL="$(declare -f _tailscale_start_service)"

# 每个场景都在子 shell 中替换函数，避免桩函数影响其他场景。
TAILSCALE_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TAILSCALE_TEST_DIR"' EXIT
TAILSCALE_TEST_LOG="${TAILSCALE_TEST_DIR}/commands.log"

test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || test_fail "$3；预期 [$1]，实际 [$2]"
}

assert_success() {
  "$@" || test_fail "命令应成功：$*"
}

assert_failure() {
  if "$@"; then
    test_fail "命令应失败：$*"
  fi
}

record_command() {
  printf '%s' "$1" >> "$TAILSCALE_TEST_LOG"
  shift
  if [[ "$#" -gt 0 ]]; then
    printf ' <%s>' "$@" >> "$TAILSCALE_TEST_LOG"
  fi
  printf '\n' >> "$TAILSCALE_TEST_LOG"
}

assert_commands() {
  local actual
  actual="$(cat "$TAILSCALE_TEST_LOG")"
  assert_equal "$1" "$actual" "$2"
}

stub_common_commands() {
  : > "$TAILSCALE_TEST_LOG"
  require_root() { return 0; }
  check_root() { return 0; }
  uname() {
    case "${1:-}" in
      -m) printf 'x86_64\n' ;;
      *) printf 'Linux\n' ;;
    esac
  }
  tailscale() { record_command tailscale "$@"; return 0; }
  _tailscale_start_service() { record_command start-service; return 0; }
  systemctl() { record_command systemctl "$@"; return 0; }
  rc-service() { record_command rc-service "$@"; return 0; }
  rc-update() { record_command rc-update "$@"; return 0; }
  curl() { record_command curl "$@"; return 22; }
  wget() { record_command wget "$@"; return 22; }
  sh() { record_command sh "$@"; return 26; }
  bash() { record_command bash "$@"; return 26; }
  apt-get() { record_command apt-get "$@"; return 23; }
  dpkg-query() { printf 'install ok installed\n'; }
  rpm() { return 1; }
  dnf() { record_command dnf "$@"; return 23; }
  yum() { record_command yum "$@"; return 23; }
  apk() { record_command apk "$@"; return 23; }
  pacman() { record_command pacman "$@"; return 23; }
}

hide_tailscale_and_apk() {
  command() {
    if [[ "${1:-}" == "-v" ]]; then
      case "${2:-}" in tailscale|apk) return 1 ;; esac
    fi
    builtin command "$@"
  }
}

run_case() {
  local label="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
  else
    test_fail "$label"
  fi
}

test_confirmation() (
  local answer
  for answer in 是 确认 继续; do
    assert_success _tailscale_confirm 安装 软件包 系统变更 <<< "$answer" >/dev/null
  done
  for answer in '' y Y yes n 否; do
    assert_failure _tailscale_confirm 安装 软件包 系统变更 <<< "$answer" >/dev/null
  done
  assert_failure _tailscale_confirm 安装 软件包 系统变更 </dev/null >/dev/null
)

test_service_names() (
  _detect_init_system() { printf 'systemd\n'; }
  assert_equal tailscaled "$(_tailscale_service_name)" 'systemd 服务名'
  _detect_init_system() { printf 'openrc\n'; }
  assert_equal tailscale "$(_tailscale_service_name)" 'OpenRC 服务名'
  _detect_init_system() { printf 'unknown\n'; }
  assert_failure _tailscale_service_name >/dev/null 2>&1
)

test_install_already_present() (
  stub_common_commands
  _tailscale_install >/dev/null 2>&1 || test_fail '已安装时应直接成功返回'
  assert_commands '' '已安装时不执行安装或服务命令'
)

test_install_cancelled() (
  stub_common_commands
  hide_tailscale_and_apk
  _tailscale_install <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消安装不执行下载、包管理或服务命令'
)

test_install_download_failure() (
  stub_common_commands
  hide_tailscale_and_apk
  assert_failure _tailscale_install <<< '确认' >/dev/null 2>&1
  local commands
  commands="$(cat "$TAILSCALE_TEST_LOG")"
  [[ "$commands" == curl* ]] || test_fail '安装应尝试下载官方脚本'
  [[ "$commands" != *start-service* ]] || test_fail '下载失败后不能启动服务'
  [[ "$commands" != *systemctl* ]] || test_fail '下载失败后不能调用 systemctl'
  [[ "$commands" != *rc-service* ]] || test_fail '下载失败后不能调用 rc-service'
)

test_install_empty_script() (
  stub_common_commands
  hide_tailscale_and_apk
  curl() { record_command curl "$@"; printf ' \n\t'; }
  assert_failure _tailscale_install <<< '确认' >/dev/null 2>&1
  local commands
  commands="$(cat "$TAILSCALE_TEST_LOG")"
  [[ "$commands" == curl* ]] || test_fail '安装应尝试下载官方脚本'
  [[ "$commands" != *$'\nsh '* && "$commands" != *start-service* ]] ||
    test_fail '空安装脚本不能执行或启动服务'
)

test_install_script_failure() (
  stub_common_commands
  hide_tailscale_and_apk
  curl() { record_command curl "$@"; printf '%s\n' '安装脚本桩'; }
  assert_failure _tailscale_install <<< '确认' >/dev/null 2>&1
  local commands
  commands="$(cat "$TAILSCALE_TEST_LOG")"
  [[ "$commands" == *$'\nsh <-c> <安装脚本桩>'* ]] || test_fail '下载成功后应执行安装脚本桩'
  [[ "$commands" != *start-service* ]] || test_fail '脚本安装失败后不能启动服务'
)

test_install_official_script_success() (
  stub_common_commands
  local installed=0
  command() {
    if [[ "${1:-}" == "-v" ]]; then
      case "${2:-}" in
        tailscale) [[ "$installed" == 1 ]]; return ;;
        apk) return 1 ;;
      esac
    fi
    builtin command "$@"
  }
  curl() { record_command curl "$@"; printf '%s\n' '安装脚本桩'; }
  sh() { record_command sh "$@"; installed=1; return 0; }
  assert_success _tailscale_install <<< '确认' >/dev/null 2>&1
  assert_commands $'curl <-fsSL> <--connect-timeout> <15> <--max-time> <180> <https://tailscale.com/install.sh>\nsh <-c> <安装脚本桩>\nstart-service' \
    '官方脚本安装成功后才启动服务'
)

test_install_openrc() (
  stub_common_commands
  local installed=0
  _detect_init_system() { printf 'openrc\n'; }
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "tailscale" && "$installed" == 0 ]]; then
      return 1
    fi
    builtin command "$@"
  }
  apk() { record_command apk "$@"; installed=1; return 0; }
  assert_success _tailscale_install <<< '确认' >/dev/null 2>&1
  assert_commands $'apk <add> <--no-cache> <tailscale> <tailscale-openrc>\nstart-service' \
    'OpenRC 安装同时包含服务包并在成功后启动'
)

test_install_openrc_failure() (
  stub_common_commands
  _detect_init_system() { printf 'openrc\n'; }
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "tailscale" ]]; then return 1; fi
    builtin command "$@"
  }
  assert_failure _tailscale_install <<< '确认' >/dev/null 2>&1
  assert_commands 'apk <add> <--no-cache> <tailscale> <tailscale-openrc>' \
    'OpenRC 软件包安装失败不能继续启动'
)

test_connect_cancelled() (
  stub_common_commands
  _tailscale_connect <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消连接不启动服务或修改 Tailscale'
)

test_connect_root_denied() (
  stub_common_commands
  require_root() { return 1; }
  check_root() { return 1; }
  assert_failure _tailscale_connect <<< '确认' >/dev/null 2>&1
  assert_commands '' '权限检查失败不启动服务或修改 Tailscale'
)

test_connect_preserves_preferences() (
  stub_common_commands
  assert_success _tailscale_connect <<< '确认' >/dev/null 2>&1
  assert_commands $'start-service\ntailscale <up>' '连接只执行无参数 tailscale up'
)

test_connect_service_failure() (
  stub_common_commands
  _tailscale_start_service() { record_command start-service; return 24; }
  assert_failure _tailscale_connect <<< '确认' >/dev/null 2>&1
  assert_commands 'start-service' '服务启动失败后不能执行 tailscale up'
)

test_service_start_wrappers() (
  stub_common_commands
  # 恢复真实封装，底层服务命令仍由桩记录，验证完整服务名与调用链。
  eval "$TAILSCALE_START_SERVICE_IMPL"
  _detect_init_system() { printf 'systemd\n'; }
  assert_success _tailscale_start_service >/dev/null 2>&1
  assert_commands $'systemctl <enable> <tailscaled>\nsystemctl <start> <tailscaled>' \
    'systemd 启用并启动 tailscaled'
  : > "$TAILSCALE_TEST_LOG"
  _detect_init_system() { printf 'openrc\n'; }
  assert_success _tailscale_start_service >/dev/null 2>&1
  assert_commands $'rc-update <add> <tailscale> <default>\nrc-service <tailscale> <start>' \
    'OpenRC 启用并启动 tailscale'
)

test_service_start_wrapper_failure() (
  stub_common_commands
  eval "$TAILSCALE_START_SERVICE_IMPL"
  _detect_init_system() { printf 'systemd\n'; }
  systemctl() { record_command systemctl "$@"; return 25; }
  assert_failure _tailscale_start_service >/dev/null 2>&1
  assert_commands 'systemctl <enable> <tailscaled>' '启用失败阻止继续启动服务'
)

test_connect_cli_failure() (
  stub_common_commands
  tailscale() { record_command tailscale "$@"; return 25; }
  assert_failure _tailscale_connect <<< '确认' >/dev/null 2>&1
  assert_commands $'start-service\ntailscale <up>' '连接失败必须返回失败'
)

test_single_preference() (
  stub_common_commands
  assert_success _tailscale_change_preference accept-routes true <<< '继续' >/dev/null 2>&1
  assert_commands 'tailscale <set> <--accept-routes=true>' '设置偏好只传入指定的一项参数'
)

test_preference_cancelled() (
  stub_common_commands
  _tailscale_change_preference accept-routes true <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消偏好设置不调用 Tailscale'
)

test_preference_cli_failure() (
  stub_common_commands
  tailscale() { record_command tailscale "$@"; return 25; }
  assert_failure _tailscale_change_preference accept-dns false <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <set> <--accept-dns=false>' '偏好设置失败必须返回失败'
)

test_preference_validation() (
  stub_common_commands
  assert_failure _tailscale_change_preference unknown true <<< '确认' >/dev/null 2>&1
  assert_failure _tailscale_change_preference ssh invalid <<< '确认' >/dev/null 2>&1
  assert_commands '' '非法偏好项或值不能传给 Tailscale'
)

test_disconnect() (
  stub_common_commands
  assert_success _tailscale_disconnect down <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <down>' '断开仅执行 tailscale down'
  : > "$TAILSCALE_TEST_LOG"
  assert_success _tailscale_disconnect logout <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <logout>' '注销仅执行 tailscale logout'
  : > "$TAILSCALE_TEST_LOG"
  assert_failure _tailscale_disconnect invalid <<< '确认' >/dev/null 2>&1
  assert_commands '' '非法断开动作不能执行外部命令'
)

test_disconnect_cancelled() (
  stub_common_commands
  _tailscale_disconnect logout <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消注销不调用 Tailscale'
)

test_disconnect_cli_failure() (
  stub_common_commands
  tailscale() { record_command tailscale "$@"; return 25; }
  assert_failure _tailscale_disconnect down <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <down>' '断开失败必须返回失败'
)

test_update_cancelled() (
  stub_common_commands
  _tailscale_update <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消更新不执行包管理命令'
)

test_update_package_failure() (
  stub_common_commands
  apt-get() {
    record_command apt-get "$@"
    [[ "${1:-}" == "update" ]]
  }
  assert_failure _tailscale_update <<< '确认' >/dev/null 2>&1
  assert_commands $'apt-get <update>\napt-get <install> <-y> <--only-upgrade> <tailscale>' \
    '更新只针对 Tailscale 且包升级失败向上传递'
)

test_update_repository_failure() (
  stub_common_commands
  assert_failure _tailscale_update <<< '确认' >/dev/null 2>&1
  assert_commands 'apt-get <update>' '软件源更新失败后不继续升级软件包'
)

test_package_source_detection() (
  stub_common_commands
  assert_equal apt "$(_tailscale_package_manager)" 'Debian 已安装包应识别为 apt'

  dpkg-query() { return 1; }
  rpm() { return 0; }
  assert_equal dnf "$(_tailscale_package_manager)" 'RPM 已安装包优先使用 dnf'

  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "dnf" ]]; then return 1; fi
    builtin command "$@"
  }
  assert_equal yum "$(_tailscale_package_manager)" 'RPM 已安装包兼容 yum'

  rpm() { return 1; }
  apk() { [[ "${1:-}" == info && "${2:-}" == -e && "${3:-}" == tailscale ]]; }
  assert_equal apk "$(_tailscale_package_manager)" 'Alpine 已安装包识别为 apk'
)

test_package_source_residual_config() (
  stub_common_commands
  dpkg-query() { printf 'deinstall ok config-files\n'; }
  apk() { return 1; }
  assert_equal unknown "$(_tailscale_package_manager)" '残留 Debian 配置不能视为已安装软件包'
  dpkg-query() { return 1; }
  assert_equal unknown "$(_tailscale_package_manager)" '仅存在包管理器不能确定安装来源'
  assert_commands '' '安装来源检测仅查询元数据'
)

test_manual_install_update() (
  stub_common_commands
  dpkg-query() { return 1; }
  apk() { return 1; }
  assert_success _tailscale_update <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <update>' '手动安装的 Tailscale 使用自身更新命令'
)

test_manual_install_update_failure() (
  stub_common_commands
  dpkg-query() { return 1; }
  apk() { return 1; }
  tailscale() { record_command tailscale "$@"; return 25; }
  assert_failure _tailscale_update <<< '确认' >/dev/null 2>&1
  assert_commands 'tailscale <update>' '自身更新命令失败必须向上传递'
)

test_uninstall_cancelled() (
  stub_common_commands
  rm() { record_command rm "$@"; return 27; }
  _tailscale_uninstall <<< '否' >/dev/null 2>&1 || true
  assert_commands '' '取消卸载不执行服务或包管理命令'
)

test_uninstall_package_failure() (
  stub_common_commands
  rm() { record_command rm "$@"; return 27; }
  assert_failure _tailscale_uninstall <<< '确认' >/dev/null 2>&1
  local commands
  commands="$(cat "$TAILSCALE_TEST_LOG")"
  [[ "$commands" == *'<tailscale>'* ]] || test_fail '卸载必须指定 tailscale 软件包'
  [[ "$commands" != rm* && "$commands" != *$'\nrm '* ]] || test_fail '卸载不能删除状态目录'
)

test_manual_install_uninstall_rejected() (
  stub_common_commands
  dpkg-query() { return 1; }
  apk() { return 1; }
  rm() { record_command rm "$@"; return 27; }
  assert_failure _tailscale_uninstall <<< '确认' >/dev/null 2>&1
  assert_commands '' '手动安装来源未知时拒绝自动卸载且不删除状态'
)

test_menu_eof() (
  stub_common_commands
  assert_success do_tailscale </dev/null >/dev/null 2>&1
  assert_commands '' '子菜单遇到 EOF 时直接退出'
)

test_nested_menus_eof() (
  stub_common_commands
  assert_success _tailscale_service_menu </dev/null >/dev/null 2>&1
  assert_success _tailscale_preferences_menu </dev/null >/dev/null 2>&1
  assert_commands '' '服务与连接设置子菜单在 EOF 时直接退出'
)

test_menu_recovers_from_failure() (
  stub_common_commands
  _tailscale_status() { record_command status; return 25; }
  assert_success do_tailscale <<< $'3\n0' >/dev/null 2>&1
  assert_commands status '状态查看失败后仍能返回主菜单'
)

test_nested_menus_recover_from_failure() (
  stub_common_commands
  _tailscale_service_action() { record_command service-action "$@"; return 25; }
  _tailscale_change_preference() { record_command preference "$@"; return 25; }
  assert_success _tailscale_service_menu <<< $'1\n0' >/dev/null 2>&1
  assert_success _tailscale_preferences_menu <<< $'3\n0' >/dev/null 2>&1
  assert_commands $'service-action <start>\npreference <accept-routes> <true>' \
    '服务与设置操作失败后仍能退出子菜单'
)

test_nft_takeover_guard() (
  stub_common_commands
  nft() { record_command nft "$@"; return 0; }
  # 即使保护条件被误删，否定输入也会阻止旧流程修改系统。
  assert_failure _nft_do_install <<< '否' >/dev/null 2>&1
  assert_commands '' '安装 Tailscale 后禁止全局清空 nftables'
)

test_nft_new_install_guard() (
  stub_common_commands
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "nft" ]]; then return 1; fi
    builtin command "$@"
  }
  assert_failure _nft_do_install </dev/null >/dev/null 2>&1
  assert_commands '' 'Tailscale 存在时新装 nftables 也不能触发全局接管'
)

run_case '中文明确确认与 EOF' test_confirmation
run_case 'systemd 与 OpenRC 服务映射' test_service_names
run_case '已安装时跳过安装' test_install_already_present
run_case '取消安装无外部操作' test_install_cancelled
run_case '下载失败不继续启动' test_install_download_failure
run_case '空下载内容不能执行安装' test_install_empty_script
run_case '安装脚本失败不继续启动' test_install_script_failure
run_case '官方脚本安装成功后启动' test_install_official_script_success
run_case 'OpenRC 安装包含服务包' test_install_openrc
run_case 'OpenRC 安装失败不启动' test_install_openrc_failure
run_case '取消连接无外部操作' test_connect_cancelled
run_case '无 root 权限阻止连接' test_connect_root_denied
run_case '连接保留已有偏好' test_connect_preserves_preferences
run_case '服务失败阻止连接' test_connect_service_failure
run_case '完整服务启动封装兼容两类系统' test_service_start_wrappers
run_case '服务启动封装正确传播失败' test_service_start_wrapper_failure
run_case '连接失败向上传递' test_connect_cli_failure
run_case '偏好设置仅修改指定项' test_single_preference
run_case '取消偏好设置无外部操作' test_preference_cancelled
run_case '偏好设置失败向上传递' test_preference_cli_failure
run_case '偏好参数白名单验证' test_preference_validation
run_case '断开与注销动作白名单' test_disconnect
run_case '取消注销无外部操作' test_disconnect_cancelled
run_case '断开失败向上传递' test_disconnect_cli_failure
run_case '取消更新无外部操作' test_update_cancelled
run_case '更新软件包失败向上传递' test_update_package_failure
run_case '软件源更新失败不继续升级' test_update_repository_failure
run_case '识别实际软件包安装来源' test_package_source_detection
run_case '残留配置与缺失包均不误判来源' test_package_source_residual_config
run_case '手动安装使用 Tailscale 自身更新' test_manual_install_update
run_case '手动安装更新失败向上传递' test_manual_install_update_failure
run_case '取消卸载无外部操作' test_uninstall_cancelled
run_case '卸载软件包失败且保留状态' test_uninstall_package_failure
run_case '手动安装拒绝自动卸载' test_manual_install_uninstall_rejected
run_case '子菜单 EOF 正常退出' test_menu_eof
run_case '嵌套子菜单 EOF 正常退出' test_nested_menus_eof
run_case '操作失败后仍可退出菜单' test_menu_recovers_from_failure
run_case '嵌套子菜单操作失败后仍可退出' test_nested_menus_recover_from_failure
run_case '保护 Tailscale 动态防火墙规则' test_nft_takeover_guard
run_case '新装 nftables 同样保护 Tailscale' test_nft_new_install_guard

printf 'Tailscale 辅助函数检查通过\n'
