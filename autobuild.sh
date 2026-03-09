#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

export FORCE_UNSAFE_CONFIGURE=1
export CLEAN_TARGET_BUILD_STATE="${CLEAN_TARGET_BUILD_STATE:-1}"
export WSL_STRIP_WINDOWS_PATH="${WSL_STRIP_WINDOWS_PATH:-1}"

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

run_make_download() {
    if command -v proxychains4 >/dev/null 2>&1; then
        proxychains4 make -j"$(nproc)" download
        return
    fi

    if command -v proxychains >/dev/null 2>&1; then
        proxychains make -j"$(nproc)" download
        return
    fi

    make -j"$(nproc)" download
}

prepare_env
clean_common_state

if [[ "$CLEAN_TARGET_BUILD_STATE" == "1" ]]; then
    clean_target_build_state
fi

git pull
sed -i 's/#src-git helloworld/src-git helloworld/g' ./feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
git checkout -- .config
make defconfig
run_make_download
make -j"$(nproc)" || make -j1 V=s