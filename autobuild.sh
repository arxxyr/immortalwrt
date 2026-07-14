#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FEED_PATCH_ROOT="${REPO_ROOT}/patches/feeds"
readonly LOG_WRITE_FAILURE_EXIT_CODE=125

export FORCE_UNSAFE_CONFIGURE=1
export CLEAN_TARGET_BUILD_STATE="${CLEAN_TARGET_BUILD_STATE:-1}"
export CLEAN_TARGET_OUTPUT_STATE="${CLEAN_TARGET_OUTPUT_STATE:-${CLEAN_TARGET_BUILD_STATE}}"
export RESET_BUILD_CONFIG="${RESET_BUILD_CONFIG:-1}"
export WSL_STRIP_WINDOWS_PATH="${WSL_STRIP_WINDOWS_PATH:-1}"
export ENABLE_NETWORK_PROXY="${ENABLE_NETWORK_PROXY:-1}"
export ALLOW_EXTERNAL_OUTPUT_DIR="${ALLOW_EXTERNAL_OUTPUT_DIR:-0}"
export PROXY_PORT="${PROXY_PORT:-10808}"
export PROXY_HOST="${PROXY_HOST:-}"
export NO_PROXY_LIST="${NO_PROXY_LIST:-127.0.0.1,localhost}"
export BUILD_JOBS="${BUILD_JOBS:-}"
export BUILD_LOG_ROOT="${BUILD_LOG_ROOT:-${REPO_ROOT}/logs/autobuild}"

BOARD=""
SUBTARGET=""
ARCH_PACKAGES=""
OUTPUT_ROOT=""
TARGET_BUILD_DIR=""
TARGET_STAGING_DIR=""
TOOLCHAIN_BUILD_DIR=""
TOOLCHAIN_STAGING_DIR=""
TARGET_BIN_DIR=""
ARCH_PACKAGES_BIN_DIR=""
PACKAGE_STAGING_DIR=""
CURRENT_LOG_DIR=""
BUILD_LOCK_FD=""

die() {
    echo "[错误] $*" >&2
    exit 1
}

require_commands() {
    local command_name

    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "缺少必需命令：${command_name}"
    done
}

validate_boolean() {
    local name="$1"
    local value="$2"

    [[ "$value" == "0" || "$value" == "1" ]] || die "${name} 必须为 0 或 1，当前值：${value}"
}

validate_positive_integer() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${name} 必须为正整数，当前值：${value}"
}

assert_repo_root() {
    [[ -f "${REPO_ROOT}/rules.mk" ]] || die "脚本目录不是 ImmortalWrt 源码根目录：${REPO_ROOT}"
    [[ -x "${REPO_ROOT}/scripts/feeds" ]] || die "缺少可执行文件 scripts/feeds"
    git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "源码目录不是 Git 工作区"
}

is_wsl() {
    local kernel_version=""

    if [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0
    fi

    [[ -r /proc/version ]] || return 1
    IFS= read -r kernel_version </proc/version || return 1
    kernel_version="${kernel_version,,}"
    [[ "$kernel_version" == *microsoft* || "$kernel_version" == *wsl* ]]
}

prepare_env() {
    if is_wsl; then
        echo "[环境] 检测到 WSL"
        if [[ "$WSL_STRIP_WINDOWS_PATH" == "1" ]]; then
            export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "[环境] 已移除 PATH 中的 Windows 路径"
        fi
    fi
}

get_wsl_windows_host_ip() {
    ip route show default 2>/dev/null | awk '/default/ { print $3; exit }'
}

resolve_proxy_host() {
    if [[ -n "$PROXY_HOST" ]]; then
        printf '%s\n' "$PROXY_HOST"
        return
    fi

    if is_wsl; then
        get_wsl_windows_host_ip
        return
    fi

    printf '%s\n' '127.0.0.1'
}

prepare_proxy_env() {
    local proxy_host http_proxy_url https_proxy_url all_proxy_url

    if [[ "$ENABLE_NETWORK_PROXY" != "1" ]]; then
        echo "[代理] 已禁用"
        return
    fi

    if is_wsl && [[ -z "$PROXY_HOST" ]]; then
        require_commands ip
    fi

    proxy_host="$(resolve_proxy_host)"
    [[ -n "$proxy_host" ]] || die "无法确定代理主机地址"

    http_proxy_url="${HTTP_PROXY_URL:-http://${proxy_host}:${PROXY_PORT}}"
    https_proxy_url="${HTTPS_PROXY_URL:-http://${proxy_host}:${PROXY_PORT}}"
    all_proxy_url="${ALL_PROXY_URL:-socks5://${proxy_host}:${PROXY_PORT}}"

    export http_proxy="$http_proxy_url"
    export https_proxy="$https_proxy_url"
    export all_proxy="$all_proxy_url"
    export no_proxy="$NO_PROXY_LIST"

    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"
    export ALL_PROXY="$all_proxy"
    export NO_PROXY="$no_proxy"

    echo "[代理] host=${proxy_host} port=${PROXY_PORT}"
}

acquire_repo_lock() {
    local lock_dir="${REPO_ROOT}/logs"
    local lock_file="${lock_dir}/autobuild.lock"

    [[ ! -L "$lock_dir" ]] || die "构建锁目录不能是符号链接：${lock_dir}"
    mkdir -p -- "$lock_dir" || die "无法创建构建锁目录：${lock_dir}"
    [[ -d "$lock_dir" ]] || die "构建锁目录无效：${lock_dir}"
    [[ ! -L "$lock_file" ]] || die "构建锁文件不能是符号链接：${lock_file}"

    exec {BUILD_LOCK_FD}>>"$lock_file" || die "无法打开构建锁：${lock_file}"
    flock -n "$BUILD_LOCK_FD" || die "已有 autobuild.sh 正在使用此源码树"
    echo "[锁] 已获取源码树独占锁"
}

remove_paths() {
    local path

    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        echo "[清理] ${path}"
        rm -rf -- "$path"
    done
}

validate_build_config() {
    [[ -f "${REPO_ROOT}/.config" && ! -L "${REPO_ROOT}/.config" ]] || die ".config 不存在或不是普通文件"

    if [[ "$RESET_BUILD_CONFIG" == "1" ]] && git -C "$REPO_ROOT" ls-files --error-unmatch .config >/dev/null 2>&1; then
        git -C "$REPO_ROOT" diff --cached --quiet -- .config || die ".config 含有暂存修改，拒绝自动重置"
    fi
}

sync_repository() {
    local upstream_ref config_backup=""
    local config_is_tracked=0
    local config_needs_premerge_reset=0

    upstream_ref="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    [[ -n "$upstream_ref" ]] || die "当前分支没有配置 upstream"

    echo "[Git] upstream=${upstream_ref}"
    git -C "$REPO_ROOT" fetch

    if git -C "$REPO_ROOT" ls-files --error-unmatch .config >/dev/null 2>&1; then
        config_is_tracked=1
    fi

    if [[ "$RESET_BUILD_CONFIG" == "1" && "$config_is_tracked" == "1" ]] &&
        ! git -C "$REPO_ROOT" diff --quiet -- .config &&
        ! git -C "$REPO_ROOT" diff --quiet HEAD.."$upstream_ref" -- .config; then
        config_needs_premerge_reset=1
        config_backup="$(mktemp "${TMPDIR:-/tmp}/autobuild-config.XXXXXX")" || die "无法创建 .config 临时备份"
        cp -- "${REPO_ROOT}/.config" "$config_backup" || die "无法备份 .config"
    fi

    revert_managed_feed_patches

    if [[ "$config_needs_premerge_reset" == "1" ]] && ! git -C "$REPO_ROOT" checkout -- .config; then
        apply_managed_feed_patches
        rm -f -- "$config_backup"
        die "无法在 Git 更新前重置 .config"
    fi

    if ! git -C "$REPO_ROOT" merge --ff-only "$upstream_ref"; then
        if [[ "$config_needs_premerge_reset" == "1" ]]; then
            if ! cp -- "$config_backup" "${REPO_ROOT}/.config"; then
                apply_managed_feed_patches
                die "Git 更新失败，且无法恢复 .config 备份：${config_backup}"
            fi
        fi
        [[ -z "$config_backup" ]] || rm -f -- "$config_backup"
        apply_managed_feed_patches
        die "无法将当前分支快进到 ${upstream_ref}"
    fi

    if [[ "$RESET_BUILD_CONFIG" == "1" && "$config_is_tracked" == "1" ]]; then
        git -C "$REPO_ROOT" checkout -- .config
        echo "[配置] 已恢复更新后仓库中的 .config"
    else
        echo "[配置] 保留当前 .config"
    fi

    [[ -z "$config_backup" ]] || rm -f -- "$config_backup"
}

feed_name_from_patch() {
    basename -- "$(dirname -- "$1")"
}

revert_managed_feed_patches() {
    local patch_file feed_name feed_dir patch_index
    local -a patch_files=("${FEED_PATCH_ROOT}"/*/*.patch)

    for ((patch_index = ${#patch_files[@]} - 1; patch_index >= 0; --patch_index)); do
        patch_file="${patch_files[patch_index]}"
        feed_name="$(feed_name_from_patch "$patch_file")"
        feed_dir="${REPO_ROOT}/feeds/${feed_name}"

        git -C "$feed_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
        git -C "$feed_dir" diff --cached --quiet || die "Feed 暂存区存在修改，拒绝自动还原：${feed_name}"

        if git -C "$feed_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            if git -C "$feed_dir" apply --cached --check "$patch_file" >/dev/null 2>&1; then
                echo "[Feed补丁] 更新前还原 ${feed_name}/$(basename -- "$patch_file")"
                git -C "$feed_dir" apply --reverse "$patch_file"
            elif git -C "$feed_dir" apply --cached --reverse --check "$patch_file" >/dev/null 2>&1; then
                echo "[Feed补丁] 上游已包含 ${feed_name}/$(basename -- "$patch_file")，无需还原"
            else
                die "Feed 索引状态不明确，拒绝还原补丁：${patch_file}"
            fi
        elif git -C "$feed_dir" apply --check "$patch_file" >/dev/null 2>&1; then
            if git -C "$feed_dir" apply --cached --check "$patch_file" >/dev/null 2>&1; then
                continue
            fi

            die "Feed 工作树缺少上游已有补丁，拒绝继续：${patch_file}"
        else
            die "无法安全还原 Feed 补丁：${patch_file}"
        fi
    done
}

apply_managed_feed_patches() {
    local patch_file feed_name feed_dir

    for patch_file in "${FEED_PATCH_ROOT}"/*/*.patch; do
        feed_name="$(feed_name_from_patch "$patch_file")"
        feed_dir="${REPO_ROOT}/feeds/${feed_name}"

        git -C "$feed_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Feed 不存在或不是 Git 仓库：${feed_name}"
        git -C "$feed_dir" diff --cached --quiet || die "Feed 暂存区存在修改，拒绝自动应用：${feed_name}"

        if git -C "$feed_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
            if git -C "$feed_dir" apply --cached --check "$patch_file" >/dev/null 2>&1; then
                echo "[Feed补丁] 已应用 ${feed_name}/$(basename -- "$patch_file")"
            elif git -C "$feed_dir" apply --cached --reverse --check "$patch_file" >/dev/null 2>&1; then
                echo "[Feed补丁] 上游已包含 ${feed_name}/$(basename -- "$patch_file")"
            else
                die "Feed 索引状态不明确，拒绝接受补丁：${patch_file}"
            fi
        elif git -C "$feed_dir" apply --check "$patch_file" >/dev/null 2>&1; then
            if git -C "$feed_dir" apply --cached --check "$patch_file" >/dev/null 2>&1; then
                echo "[Feed补丁] 正在应用 ${feed_name}/$(basename -- "$patch_file")"
                git -C "$feed_dir" apply "$patch_file"
            else
                die "Feed 工作树缺少上游已有补丁，拒绝覆盖：${patch_file}"
            fi
        else
            die "Feed 已变化，补丁无法安全应用：${patch_file}"
        fi
    done
}

prepare_feeds() {
    ./scripts/feeds update -a
    apply_managed_feed_patches
    ./scripts/feeds update -i -a
    ./scripts/feeds install -a
}

read_make_value() {
    local name="$1"
    local value

    value="$(make -s --no-print-directory "val.${name}")"
    [[ -n "$value" ]] || die "OpenWrt 构建系统没有返回 ${name}"
    [[ "$value" != *$'\n'* ]] || die "OpenWrt 构建变量 ${name} 包含多行内容"
    [[ "$value" != *undefined* ]] || die "OpenWrt 构建变量 ${name} 未定义"

    printf '%s\n' "$value"
}

validate_path_component() {
    local name="$1"
    local value="$2"

    [[ -n "$value" ]] || die "${name} 为空"
    [[ "$value" != "." && "$value" != ".." && "$value" != */* ]] || die "${name} 不是安全的路径分量：${value}"
}

assert_not_system_path() {
    local name="$1"
    local raw_path="$2"
    local normalized_path protected_root

    normalized_path="$(realpath -m -- "$raw_path")"
    [[ "$normalized_path" != "/" ]] || die "${name} 不能是文件系统根目录"

    for protected_root in /bin /boot /dev /etc /lib /lib64 /proc /root /run /sbin /sys /usr /var; do
        if [[ "$normalized_path" == "$protected_root" || "$normalized_path" == "${protected_root}/"* ]]; then
            die "${name} 不能位于系统目录：${normalized_path}"
        fi
    done
}

safe_child_path() {
    local name="$1"
    local raw_path="$2"
    local expected_root="$3"
    local normalized_path normalized_root lexical_path lexical_root

    normalized_path="$(realpath -m -- "$raw_path")"
    normalized_root="$(realpath -m -- "$expected_root")"
    lexical_path="$(realpath -ms -- "$raw_path")"
    lexical_root="$(realpath -ms -- "$expected_root")"

    [[ "$normalized_path" == "$lexical_path" ]] || die "拒绝清理包含符号链接的路径：${name}=${raw_path}"
    [[ "$normalized_root" == "$lexical_root" ]] || die "拒绝使用包含符号链接的清理根目录：${expected_root}"

    if [[ "$normalized_path" == "$normalized_root" || "$normalized_path" != "${normalized_root}/"* ]]; then
        die "拒绝清理不安全路径：${name}=${normalized_path}，预期父目录=${normalized_root}"
    fi

    printf '%s\n' "$normalized_path"
}

safe_direct_child_path() {
    local name="$1"
    local raw_path="$2"
    local expected_root="$3"
    local normalized_path normalized_root

    normalized_path="$(safe_child_path "$name" "$raw_path" "$expected_root")"
    normalized_root="$(realpath -m -- "$expected_root")"
    [[ "$(dirname -- "$normalized_path")" == "$normalized_root" ]] || die "拒绝清理非直接子目录：${name}=${normalized_path}"

    printf '%s\n' "$normalized_path"
}

validate_path_prefix() {
    local name="$1"
    local path="$2"
    local prefix="$3"
    local path_basename

    path_basename="$(basename -- "$path")"
    [[ "$path_basename" == "${prefix}"* ]] || die "${name} 的目录名不符合预期：${path_basename}"
}

resolve_output_root() {
    local raw_path="$1"
    local normalized_path normalized_repo_root normalized_home

    normalized_path="$(realpath -m -- "$raw_path")"
    normalized_repo_root="$(realpath -m -- "$REPO_ROOT")"
    normalized_home="$(realpath -m -- "${HOME:-/}")"

    assert_not_system_path OUTPUT_DIR "$normalized_path"
    [[ "$normalized_path" != "$normalized_repo_root" ]] || die "OUTPUT_DIR 不能是源码根目录"
    [[ "$normalized_path" != "$normalized_home" ]] || die "OUTPUT_DIR 不能是用户主目录"

    if [[ "$normalized_path" != "${normalized_repo_root}/"* && "$ALLOW_EXTERNAL_OUTPUT_DIR" != "1" ]]; then
        die "OUTPUT_DIR 位于源码树外：${normalized_path}；确认安全后设置 ALLOW_EXTERNAL_OUTPUT_DIR=1"
    fi

    printf '%s\n' "$normalized_path"
}

resolve_final_context() {
    local target_build_name target_staging_name toolchain_build_name toolchain_staging_name target_bin_name

    BOARD="$(read_make_value BOARD)"
    SUBTARGET="$(read_make_value SUBTARGET)"
    ARCH_PACKAGES="$(read_make_value ARCH_PACKAGES)"
    OUTPUT_ROOT="$(resolve_output_root "$(read_make_value OUTPUT_DIR)")"

    validate_path_component BOARD "$BOARD"
    validate_path_component SUBTARGET "$SUBTARGET"
    validate_path_component ARCH_PACKAGES "$ARCH_PACKAGES"

    TARGET_BUILD_DIR="$(
        safe_direct_child_path BUILD_DIR "$(read_make_value BUILD_DIR)" "${REPO_ROOT}/build_dir"
    )"
    TARGET_STAGING_DIR="$(
        safe_direct_child_path STAGING_DIR "$(read_make_value STAGING_DIR)" "${REPO_ROOT}/staging_dir"
    )"
    TOOLCHAIN_BUILD_DIR="$(
        safe_direct_child_path BUILD_DIR_TOOLCHAIN "$(read_make_value BUILD_DIR_TOOLCHAIN)" "${REPO_ROOT}/build_dir"
    )"
    TOOLCHAIN_STAGING_DIR="$(
        safe_direct_child_path TOOLCHAIN_DIR "$(read_make_value TOOLCHAIN_DIR)" "${REPO_ROOT}/staging_dir"
    )"
    TARGET_BIN_DIR="$(
        safe_direct_child_path BIN_DIR "$(read_make_value BIN_DIR)" "${OUTPUT_ROOT}/targets/${BOARD}"
    )"
    ARCH_PACKAGES_BIN_DIR="$(
        safe_direct_child_path \
            ARCH_PACKAGES_BIN_DIR \
            "${OUTPUT_ROOT}/packages/${ARCH_PACKAGES}" \
            "${OUTPUT_ROOT}/packages"
    )"
    PACKAGE_STAGING_DIR="$(
        safe_direct_child_path \
            PACKAGE_DIR_ALL \
            "$(read_make_value PACKAGE_DIR_ALL)" \
            "${REPO_ROOT}/staging_dir/packages"
    )"

    validate_path_prefix BUILD_DIR "$TARGET_BUILD_DIR" "target-"
    validate_path_prefix STAGING_DIR "$TARGET_STAGING_DIR" "target-"
    validate_path_prefix BUILD_DIR_TOOLCHAIN "$TOOLCHAIN_BUILD_DIR" "toolchain-"
    validate_path_prefix TOOLCHAIN_DIR "$TOOLCHAIN_STAGING_DIR" "toolchain-"
    target_build_name="$(basename -- "$TARGET_BUILD_DIR")"
    target_staging_name="$(basename -- "$TARGET_STAGING_DIR")"
    toolchain_build_name="$(basename -- "$TOOLCHAIN_BUILD_DIR")"
    toolchain_staging_name="$(basename -- "$TOOLCHAIN_STAGING_DIR")"
    target_bin_name="$(basename -- "$TARGET_BIN_DIR")"

    [[ "$target_build_name" == "$target_staging_name" ]] || die "目标 build/staging 目录名不一致"
    [[ "$toolchain_build_name" == "$toolchain_staging_name" ]] || die "工具链 build/staging 目录名不一致"
    [[ "$(basename -- "$PACKAGE_STAGING_DIR")" == "$BOARD" ]] || die "PACKAGE_DIR_ALL 与当前 BOARD 不匹配"
    [[ "$target_bin_name" == "$SUBTARGET" || "$target_bin_name" == "${SUBTARGET}-"* ]] ||
        die "BIN_DIR 与当前 SUBTARGET 不匹配"

    echo "[目标] board=${BOARD} subtarget=${SUBTARGET} arch_packages=${ARCH_PACKAGES}"
    echo "[目标] build_dir=${TARGET_BUILD_DIR}"
    echo "[目标] staging_dir=${TARGET_STAGING_DIR}"
    echo "[目标] output_dir=${OUTPUT_ROOT}"
    echo "[目标] bin_dir=${TARGET_BIN_DIR}"
}

clean_common_state() {
    remove_paths "${REPO_ROOT}/tmp"
}

clean_final_context() {
    if [[ "$CLEAN_TARGET_BUILD_STATE" == "1" ]]; then
        remove_paths \
            "$TARGET_STAGING_DIR" \
            "$TARGET_BUILD_DIR" \
            "$TOOLCHAIN_STAGING_DIR" \
            "$TOOLCHAIN_BUILD_DIR"
    fi

    if [[ "$CLEAN_TARGET_OUTPUT_STATE" == "1" ]]; then
        remove_paths \
            "$TARGET_BIN_DIR" \
            "$ARCH_PACKAGES_BIN_DIR" \
            "$PACKAGE_STAGING_DIR"
    fi
}

create_log_dir() {
    local timestamp normalized_log_root lexical_log_root unsafe_root
    local -a unsafe_roots=(
        "${REPO_ROOT}/bin"
        "${REPO_ROOT}/build_dir"
        "${REPO_ROOT}/staging_dir"
        "${REPO_ROOT}/tmp"
    )

    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    normalized_log_root="$(realpath -m -- "$BUILD_LOG_ROOT")"
    lexical_log_root="$(realpath -ms -- "$BUILD_LOG_ROOT")"
    assert_not_system_path BUILD_LOG_ROOT "$normalized_log_root"
    [[ "$normalized_log_root" != "$(realpath -m -- "${HOME:-/}")" ]] || die "日志根目录不能是用户主目录"
    [[ "$normalized_log_root" != "$(realpath -m -- "$REPO_ROOT")" ]] || die "日志根目录不能是源码根目录"
    [[ "$normalized_log_root" == "$lexical_log_root" ]] || die "日志根目录不能包含符号链接：${BUILD_LOG_ROOT}"

    if [[ -n "$OUTPUT_ROOT" ]]; then
        unsafe_roots+=("$OUTPUT_ROOT")
    fi

    for unsafe_root in "${unsafe_roots[@]}"; do
        unsafe_root="$(realpath -m -- "$unsafe_root")"
        if [[ "$normalized_log_root" == "$unsafe_root" || "$normalized_log_root" == "${unsafe_root}/"* ]]; then
            die "日志目录不能位于可清理目录内：${normalized_log_root}"
        fi
    done

    mkdir -p -- "$normalized_log_root" || die "无法创建日志根目录：${normalized_log_root}"
    CURRENT_LOG_DIR="$(mktemp -d -- "${normalized_log_root%/}/${timestamp}-$$-XXXXXX")" || die "无法创建本次构建日志目录"
    echo "[日志] ${CURRENT_LOG_DIR}"
}

run_logged() (
    local log_file="$1"
    local -a pipeline_status
    shift

    if ! mkdir -p -- "$(dirname -- "$log_file")"; then
        echo "[错误] 无法创建日志目录：$(dirname -- "$log_file")" >&2
        exit "$LOG_WRITE_FAILURE_EXIT_CODE"
    fi
    set +e
    "$@" 2>&1 | tee "$log_file"
    pipeline_status=("${PIPESTATUS[@]}")

    if ((pipeline_status[1] != 0)); then
        echo "[错误] 写入日志失败：${log_file}，command_exit=${pipeline_status[0]} tee_exit=${pipeline_status[1]}" >&2
        exit "$LOG_WRITE_FAILURE_EXIT_CODE"
    fi

    exit "${pipeline_status[0]}"
)

download_sources() {
    local return_code
    local log_file="${CURRENT_LOG_DIR}/download.log"

    echo "[下载] jobs=${BUILD_JOBS} log=${log_file}"
    if run_logged "$log_file" \
        make -j"${BUILD_JOBS}" BUILD_LOG=1 BUILD_LOG_DIR="${CURRENT_LOG_DIR}/openwrt-download" download; then
        return
    else
        return_code=$?
    fi

    if ((return_code == LOG_WRITE_FAILURE_EXIT_CODE)); then
        echo "[错误] 源码下载日志写入失败：${log_file}" >&2
        return "$return_code"
    fi
    if ((return_code >= 128)); then
        echo "[错误] 源码下载被信号中断，exit_code=${return_code}，日志：${log_file}" >&2
        return "$return_code"
    fi

    echo "[错误] 源码下载失败，exit_code=${return_code}，日志：${log_file}" >&2
    return "$return_code"
}

build_with_fallback() {
    local parallel_return_code serial_return_code
    local parallel_log="${CURRENT_LOG_DIR}/build-parallel.log"
    local serial_log="${CURRENT_LOG_DIR}/build-serial.log"

    echo "[构建] 并行编译 jobs=${BUILD_JOBS} log=${parallel_log}"
    if run_logged "$parallel_log" \
        make -j"${BUILD_JOBS}" BUILD_LOG=1 BUILD_LOG_DIR="${CURRENT_LOG_DIR}/openwrt-parallel"; then
        echo "[构建] 并行编译成功"
        return
    else
        parallel_return_code=$?
    fi

    if ((parallel_return_code == LOG_WRITE_FAILURE_EXIT_CODE)); then
        echo "[错误] 并行编译日志写入失败：${parallel_log}" >&2
        return "$parallel_return_code"
    fi
    if ((parallel_return_code >= 128)); then
        echo "[错误] 并行编译被信号中断，exit_code=${parallel_return_code}，日志：${parallel_log}" >&2
        return "$parallel_return_code"
    fi
    if ((parallel_return_code != 2)); then
        echo "[错误] 并行编译异常退出，exit_code=${parallel_return_code}，日志：${parallel_log}" >&2
        return "$parallel_return_code"
    fi

    echo "[构建] 并行编译失败，exit_code=${parallel_return_code}；开始串行重试，log=${serial_log}" >&2
    if run_logged "$serial_log" make -j1 V=s BUILD_LOG=1 BUILD_LOG_DIR="${CURRENT_LOG_DIR}/openwrt-serial"; then
        echo "[构建] 串行重试成功"
        return
    else
        serial_return_code=$?
    fi

    if ((serial_return_code == LOG_WRITE_FAILURE_EXIT_CODE)); then
        echo "[错误] 串行编译日志写入失败：${serial_log}" >&2
        return "$serial_return_code"
    fi
    if ((serial_return_code >= 128)); then
        echo "[错误] 串行编译被信号中断，exit_code=${serial_return_code}，日志：${serial_log}" >&2
        return "$serial_return_code"
    fi

    echo "[错误] 编译失败，parallel_exit=${parallel_return_code} serial_exit=${serial_return_code}" >&2
    echo "[错误] 日志目录：${CURRENT_LOG_DIR}" >&2
    return "$serial_return_code"
}

main() {
    cd "$REPO_ROOT"

    prepare_env
    require_commands awk basename cp date dirname flock git make mkdir mktemp nproc realpath rm tee
    assert_repo_root
    if [[ -z "$BUILD_JOBS" ]]; then
        BUILD_JOBS="$(nproc)"
        export BUILD_JOBS
    fi

    validate_boolean CLEAN_TARGET_BUILD_STATE "$CLEAN_TARGET_BUILD_STATE"
    validate_boolean CLEAN_TARGET_OUTPUT_STATE "$CLEAN_TARGET_OUTPUT_STATE"
    validate_boolean RESET_BUILD_CONFIG "$RESET_BUILD_CONFIG"
    validate_boolean WSL_STRIP_WINDOWS_PATH "$WSL_STRIP_WINDOWS_PATH"
    validate_boolean ENABLE_NETWORK_PROXY "$ENABLE_NETWORK_PROXY"
    validate_boolean ALLOW_EXTERNAL_OUTPUT_DIR "$ALLOW_EXTERNAL_OUTPUT_DIR"
    validate_positive_integer BUILD_JOBS "$BUILD_JOBS"
    if [[ "$CLEAN_TARGET_OUTPUT_STATE" != "$CLEAN_TARGET_BUILD_STATE" ]]; then
        die "CLEAN_TARGET_BUILD_STATE 与 CLEAN_TARGET_OUTPUT_STATE 必须同时启用或同时禁用"
    fi

    acquire_repo_lock
    prepare_proxy_env
    validate_build_config
    sync_repository
    prepare_feeds
    clean_common_state
    make defconfig
    if [[ "$CLEAN_TARGET_BUILD_STATE" == "1" ]]; then
        resolve_final_context
        create_log_dir
        clean_final_context
    else
        OUTPUT_ROOT="$(resolve_output_root "$(read_make_value OUTPUT_DIR)")"
        create_log_dir
        echo "[清理] 已保留当前目标构建状态与输出目录"
    fi
    download_sources
    build_with_fallback
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
