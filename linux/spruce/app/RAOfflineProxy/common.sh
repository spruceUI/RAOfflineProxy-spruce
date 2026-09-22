#!/bin/sh

APP_DIR=/mnt/SDCARD/App/RAOfflineProxy
APP_VERSION=v1.13.0-alpha1
APP_MAX_CACHED_GAMES=100
APP_DATA_DIR="$APP_DIR/data"
APP_PACKAGE_DIR="$APP_DIR/app"
# One bundle covers every spruce device: MiyooMini and A30 are armv7, the other
# eighteen are aarch64. uname picks the payload; resolve_python_bin falls back to
# the other arch if that guess cannot actually exec.
case "$(uname -m)" in
    aarch64 | arm64) APP_ARCH=aarch64; APP_ARCH_ALT=armv7 ;;
    *) APP_ARCH=armv7; APP_ARCH_ALT=aarch64 ;;
esac
APP_RUNTIME_DIR="$APP_DIR/runtime/$APP_ARCH"
APP_LIB_DIR="$APP_DIR/lib/$APP_ARCH"
APP_RETROARCH_CFG=
APP_CERT_FILE="$APP_RUNTIME_DIR/lib/python3.9/site-packages/pip/_vendor/certifi/cacert.pem"
APP_SPRUCE_PLATFORM=
APP_SPRUCE_ZONEINFO_DIR=/mnt/SDCARD/spruce/zoneinfo
# The zone lives in the card-global shared-system.json that PyUI and
# timeFunctions.sh both read. The Saves/*-system.json glob is the older per-device
# file, kept because Pixel2 still writes one. Only used without appEnv.sh, which
# exports TZ itself.
APP_SPRUCE_SYSTEM_JSON_GLOB='/mnt/SDCARD/Saves/spruce/shared-system.json /mnt/SDCARD/Saves/*-system.json'
APP_ACTIVE_RUNTIME_ROOT=
RESOLVED_PYTHON_BIN=
RUNTIME_FAILURE_REASON=
RUNTIME_DETECT_LOG="$APP_DATA_DIR/runtime-detect.log"

SPRUCE_APP_ENV=/mnt/SDCARD/spruce/scripts/appEnv.sh

# spruce publishes its device name, live RetroArch config, SDL2 and timezone
# through appEnv.sh. Use it when it is there: copying spruce's internals is what
# left this app writing achievements into a file nothing reads after 4.4.2 moved
# the RetroArch configs.
#
# The fallback below is for spruce older than that contract. It is deliberately
# coarse - it cannot tell RGB30, Miniloong and Flip apart (all Cortex-A55), nor
# which of the seven Anbernic platforms this is, so it names the one config that
# is certain to exist and lets the caller carry on.
detect_spruce_platform() {
    if [ -r "$SPRUCE_APP_ENV" ]; then
        . "$SPRUCE_APP_ENV"
        APP_SPRUCE_PLATFORM="$SPRUCE_PLATFORM"
        return 0
    fi

    info="$(cat /proc/cpuinfo 2>/dev/null)"

    # Checked before cpuinfo: the MagicX A133P shares the H700's Cortex-A53 part
    # id, so matching 0xd03 first would call every Zero28/Zero40/XU20 an Anbernic.
    if [ -e /usr/magicx ]; then
        case "$(tr -d '\r\n' < /usr/magicx/device 2>/dev/null)" in
            zero40) APP_SPRUCE_PLATFORM=Zero40 ;;
            xu20) APP_SPRUCE_PLATFORM=XU20 ;;
            *) APP_SPRUCE_PLATFORM=Zero28 ;;
        esac
        return 0
    fi

    case "$info" in
        *sun8i*) APP_SPRUCE_PLATFORM=A30 ;;
        *TG5040*) APP_SPRUCE_PLATFORM=SmartPro ;;
        *TG3040*) APP_SPRUCE_PLATFORM=Brick ;;
        *TG5050*) APP_SPRUCE_PLATFORM=SmartProS ;;
        *TG4040*) APP_SPRUCE_PLATFORM=BrickPro ;;
        *0xd05*)
            if grep -q '^OS_NAME="DARKMOSS"' /etc/os-release 2>/dev/null; then
                APP_SPRUCE_PLATFORM=RGB30
            elif [ -x /loong/loong_daemon ]; then
                APP_SPRUCE_PLATFORM=Miniloong
            else
                APP_SPRUCE_PLATFORM=Flip
            fi
            ;;
        *0xd04*) APP_SPRUCE_PLATFORM=Pixel2 ;;
        *0xd03*) APP_SPRUCE_PLATFORM=AnbernicXX640480 ;;
        *) APP_SPRUCE_PLATFORM=MiyooMini ;;
    esac
}

resolve_spruce_timezone() {
    # spruce's PyUI applies the chosen zone by exporting TZ into its own environment, so
    # anything it launches inherits it. The boot hook runs from .tmp_update/updater long
    # before PyUI exists, so an autostarted proxy would otherwise stamp every award
    # timestamp in UTC.
    if [ -n "${TZ:-}" ]; then
        return 0
    fi

    if [ ! -d "$APP_SPRUCE_ZONEINFO_DIR" ]; then
        return 0
    fi

    for spruce_system_json in $APP_SPRUCE_SYSTEM_JSON_GLOB; do
        [ -r "$spruce_system_json" ] || continue

        spruce_tz="$(sed -n 's/.*"timezone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$spruce_system_json" 2>/dev/null | head -n 1)"
        [ -n "$spruce_tz" ] || continue

        spruce_zone_file="$APP_SPRUCE_ZONEINFO_DIR/$spruce_tz"
        if [ -r "$spruce_zone_file" ]; then
            # glibc reads a tz file from an absolute path when TZ starts with a colon,
            # which is exactly how spruce itself applies the setting.
            export TZ=":$spruce_zone_file"
            return 0
        fi
    done

    return 0
}

normalize_display_paths() {
    sed 's#/mnt/SDCARD/#/#g'
}

prepare_env() {
    mkdir -p "$APP_DATA_DIR"
    : > "$RUNTIME_DETECT_LOG"

    detect_spruce_platform
    resolve_spruce_timezone

    # The live config, which spruce passes to RetroArch as --config. Since 4.4.2 it
    # lives in Saves/ra-configs and RetroArch/platform holds only .cfg.bak seeds, so
    # writing to the old path is silently discarded. appEnv.sh also seeds the file
    # when it is missing; the fallback has to do that itself or an edit here would
    # leave a config with nothing in it but our own key.
    if [ -n "${SPRUCE_RA_CONFIG:-}" ]; then
        APP_RETROARCH_CFG="$SPRUCE_RA_CONFIG"
    else
        APP_RETROARCH_CFG="/mnt/SDCARD/Saves/ra-configs/retroarch-${APP_SPRUCE_PLATFORM}.cfg"
        if [ ! -f "$APP_RETROARCH_CFG" ]; then
            ra_seed="/mnt/SDCARD/RetroArch/platform/retroarch-${APP_SPRUCE_PLATFORM}.cfg.bak"
            if [ -f "$ra_seed" ]; then
                mkdir -p /mnt/SDCARD/Saves/ra-configs
                cp "$ra_seed" "$APP_RETROARCH_CFG"
            fi
        fi
    fi

    export RAOFFLINEPROXY_CONFIG_DIR="$APP_DATA_DIR"
    export RAOFFLINEPROXY_RETROARCH_CFG="$APP_RETROARCH_CFG"
    export RAOFFLINEPROXY_APP_VERSION="${APP_VERSION#v}"
    export RAOFFLINEPROXY_CACHE_IMAGES=0
    export PYTHONPATH="$APP_PACKAGE_DIR${PYTHONPATH:+:$PYTHONPATH}"
    # glibc hands every allocating thread its own heap and grows each in 1MB chunks it
    # never returns. The proxy runs a thread per connection plus background workers, which
    # on a 103MB device cost ~15MB of arenas — about as much as the interpreter itself.
    export MALLOC_ARENA_MAX=2
    export LD_LIBRARY_PATH="$APP_LIB_DIR:/config/lib:/customer/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # armv7 keeps the Onion stack: its "Mini" SDL2 is the only build that reaches the
    # Mini's panel, and it presents solely through the SDL_Renderer path menu_sdl
    # already uses.
    #
    # aarch64 ships no SDL2 at all. A generic build cannot drive these panels - the
    # Brick, RGB30 and Miniloong each need a different backend - so the build strips
    # the wheel's bundled copy and we load spruce's per-device one from the front of
    # LD_LIBRARY_PATH instead. Without appEnv.sh there is nothing usable to point at,
    # so the menu is left to fail loudly rather than draw to nowhere.
    if [ "$APP_ARCH" = "armv7" ]; then
        export SDL_VIDEODRIVER=Mini
    else
        unset SDL_VIDEODRIVER
        if [ -n "${SPRUCE_SDL2_DLL_PATH:-}" ]; then
            export LD_LIBRARY_PATH="$SPRUCE_SDL2_DLL_PATH:$LD_LIBRARY_PATH"
        fi
        [ -n "${SPRUCE_SDL_VIDEODRIVER:-}" ] && export SDL_VIDEODRIVER="$SPRUCE_SDL_VIDEODRIVER"
        # BaseOS runs no udev; SDL's joystick layer hangs in SDL_Init looking for it.
        case "$APP_SPRUCE_PLATFORM" in
            Anbernic*) export SDL_JOYSTICK_DISABLE_UDEV=1 ;;
        esac
    fi

    if [ -f "$APP_CERT_FILE" ]; then
        export SSL_CERT_FILE="$APP_CERT_FILE"
        export RAOFFLINEPROXY_CA_FILE="$APP_CERT_FILE"
    fi
}

activate_runtime_env() {
    runtime_root="$1"
    APP_ACTIVE_RUNTIME_ROOT="$runtime_root"

    export PYTHONHOME="$runtime_root"
    export LD_LIBRARY_PATH="$APP_LIB_DIR:$runtime_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PATH="$runtime_root/bin${PATH:+:$PATH}"
    if [ -f "$runtime_root/lib/python3.9/site-packages/pip/_vendor/certifi/cacert.pem" ]; then
        export SSL_CERT_FILE="$runtime_root/lib/python3.9/site-packages/pip/_vendor/certifi/cacert.pem"
        export RAOFFLINEPROXY_CA_FILE="$runtime_root/lib/python3.9/site-packages/pip/_vendor/certifi/cacert.pem"
    fi
}

python_supports_backend() {
    candidate="$1"
    runtime_root="${2:-}"

    if [ -n "$runtime_root" ]; then
        PYTHONHOME="$runtime_root" LD_LIBRARY_PATH="$runtime_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>"$RUNTIME_DETECT_LOG"
        return $?
    fi

    "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>"$RUNTIME_DETECT_LOG"
    return $?
}

capture_runtime_failure_reason() {
    if [ ! -s "$RUNTIME_DETECT_LOG" ]; then
        RUNTIME_FAILURE_REASON=
        return 0
    fi

    if IFS= read -r first_line < "$RUNTIME_DETECT_LOG"; then
        RUNTIME_FAILURE_REASON="$first_line"
        return 0
    fi

    RUNTIME_FAILURE_REASON=
}

resolve_python_bin() {
    # Preferred arch first, then the other one. The Flip reports an aarch64 kernel
    # while running a largely 32-bit userland, so a runtime that exec'd fine on
    # paper is not proof of anything - try the alternative before giving up and
    # falling through to a system python3 that has no pygame.
    for runtime_root in \
        "$APP_DIR/runtime/$APP_ARCH" \
        "$APP_DIR/runtime/$APP_ARCH/python" \
        "$APP_DIR/runtime/$APP_ARCH_ALT" \
        "$APP_DIR/runtime/$APP_ARCH_ALT/python"
    do
        [ -x "$runtime_root/bin/python3" ] || continue
        if python_supports_backend "$runtime_root/bin/python3" "$runtime_root"; then
            case "$runtime_root" in
                */runtime/"$APP_ARCH_ALT"*)
                    APP_ARCH="$APP_ARCH_ALT"
                    APP_LIB_DIR="$APP_DIR/lib/$APP_ARCH"
                    ;;
            esac
            activate_runtime_env "$runtime_root"
            RESOLVED_PYTHON_BIN="$runtime_root/bin/python3"
            RUNTIME_FAILURE_REASON=
            return 0
        fi
        capture_runtime_failure_reason
    done

    if command -v python3 >/dev/null 2>&1; then
        candidate="$(command -v python3)"
        if python_supports_backend "$candidate"; then
            RESOLVED_PYTHON_BIN="$candidate"
            RUNTIME_FAILURE_REASON=
            return 0
        fi
        capture_runtime_failure_reason
    fi

    RESOLVED_PYTHON_BIN=
    return 1
}

run_backend() {
    python_bin="$1"
    shift
    run_backend_raw "$python_bin" "$@" | normalize_display_paths
}

run_backend_raw() {
    python_bin="$1"
    shift
    case "${1:-}" in
        boot-reconcile | start-proxy)
            # raofflineproxy.boot opens the proxy port before loading the rest
            # of the package, so an emulator started alongside this hook is not
            # refused.
            "$python_bin" -m raofflineproxy.boot "$@"
            ;;
        *)
            "$python_bin" -m raofflineproxy.main "$@"
            ;;
    esac
}

log_path() {
    printf '%s\n' "$APP_DATA_DIR/service.log"
}
