#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

export FORCE_UNSAFE_CONFIGURE=1
export CLEAN_TARGET_BUILD_STATE="${CLEAN_TARGET_BUILD_STATE:-1}"
export WSL_STRIP_WINDOWS_PATH="${WSL_STRIP_WINDOWS_PATH:-1}"
export ENABLE_NETWORK_PROXY="${ENABLE_NETWORK_PROXY:-1}"
export PROXY_PORT="${PROXY_PORT:-10808}"
export PROXY_HOST="${PROXY_HOST:-}"
export NO_PROXY_LIST="${NO_PROXY_LIST:-127.0.0.1,localhost}"

is_wsl() {
    [[ -n "${WSL_INTEROP:-}" ]] || [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

prepare_env() {
    if is_wsl; then
        echo "[env] detected WSL"
        if [[ "$WSL_STRIP_WINDOWS_PATH" == "1" ]]; then
            export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "[env] normalized PATH for WSL"
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
        return
    fi

    proxy_host="$(resolve_proxy_host)"

    if [[ -z "$proxy_host" ]]; then
        echo "[proxy] failed to determine proxy host" >&2
        exit 1
    fi

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

    echo "[proxy] host=${proxy_host} port=${PROXY_PORT}"
    echo "[proxy] http_proxy=${http_proxy}"
    echo "[proxy] https_proxy=${https_proxy}"
    echo "[proxy] all_proxy=${all_proxy}"
}

read_config_string() {
    local key="$1"
    sed -n "s/^${key}=\"\(.*\)\"$/\1/p" .config | tail -n1
}

remove_paths() {
    local path
    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        echo "[clean] $path"
        rm -rf -- "$path"
    done
}

resolve_target_context() {
    local board subtarget arch libc target_id

    board="$(read_config_string CONFIG_TARGET_BOARD)"
    subtarget="$(read_config_string CONFIG_TARGET_SUBTARGET)"
    arch="$(read_config_string CONFIG_TARGET_ARCH_PACKAGES)"
    libc="$(read_config_string CONFIG_TARGET_SUFFIX)"

    if [[ -z "$libc" ]]; then
        libc="$(read_config_string CONFIG_LIBC)"
    fi

    if [[ -z "$arch" || -z "$libc" ]]; then
        echo "[error] failed to resolve target arch/libc from .config" >&2
        exit 1
    fi

    target_id="${arch}_${libc}"

    printf '%s\n' "$board" "$subtarget" "$arch" "$libc" "$target_id"
}

clean_common_state() {
    remove_paths ./tmp
}

clean_target_build_state() {
    local board subtarget arch libc target_id
    local -a target_context

    mapfile -t target_context < <(resolve_target_context)

    board="${target_context[0]}"
    subtarget="${target_context[1]}"
    arch="${target_context[2]}"
    libc="${target_context[3]}"
    target_id="${target_context[4]}"

    echo "[clean] board=${board:-unknown} subtarget=${subtarget:-unknown} target=${target_id}"

    remove_paths \
        "staging_dir/target-${target_id}" \
        "build_dir/target-${target_id}" \
        staging_dir/toolchain-"${arch}"_*_"${libc}" \
        build_dir/toolchain-"${arch}"_*_"${libc}"
}

is_ssh_remote_url() {
    local url="${1:-}"
    [[ "$url" == git@* || "$url" == ssh://* ]]
}

run_git_pull() {
    local origin_url=""

    origin_url="$(git remote get-url origin 2>/dev/null || true)"

    if is_ssh_remote_url "$origin_url"; then
        echo "[git] origin uses ssh, run git pull directly"
        echo "[git] origin=${origin_url}"
        git pull
        return
    fi

    echo "[git] origin uses non-ssh remote, run git pull with current environment"
    git pull
}

main() {
    prepare_env
    prepare_proxy_env
    clean_common_state

    if [[ "$CLEAN_TARGET_BUILD_STATE" == "1" ]]; then
        clean_target_build_state
    fi

    run_git_pull
    sed -i 's/#src-git helloworld/src-git helloworld/g' ./feeds.conf.default
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    git checkout -- .config
    make defconfig
    make -j"$(nproc)" download
    make -j"$(nproc)" || make -j1 V=s
}

main "$@"