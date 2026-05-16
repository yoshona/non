#!/usr/bin/env bash
# Mechrevo / Tongfang GPU switch helper for Linux.
#
# This script mirrors the useful part of the Windows OEM flow:
#   ACPI EC0.IGPS(1) -> iGPU-only intent / dGPU eject notification
#   ACPI EC0.IGPS(0) -> hybrid intent / dGPU bus-check notification
#
# Linux still needs native PCI hotplug for the real device removal/rescan.
# The script therefore uses IGPS when acpi_call is available, then verifies
# actual PCI state through sysfs/lspci.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NVIDIA_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
ACPI_PREFIXES=('\_SB.PC00.LPCB.EC0' '\_SB.PCI0.LPCB.EC0')

DRY_RUN=false
FORCE=false
PCI_ADDR=""

info() { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

usage() {
    cat <<EOF
Mechrevo GPU Mode Switcher for Linux

Usage: $(basename "$0") <command> [options]

Commands:
  status       Show dGPU, ACPI, and module state
  igpu         Switch to iGPU-only by unloading NVIDIA and removing dGPU PCI
  hybrid       Switch to hybrid by ACPI IGPS(0), PCI rescan, and driver load
  dgpu         Alias for hybrid, then prints display-manager guidance

Options:
  --pci ADDR   Use a specific NVIDIA PCI address, e.g. 0000:01:00.0
  --dry-run    Print actions without writing to ACPI/sysfs
  --force      Skip interactive safety prompts
  -h, --help   Show this help

Notes:
  - For OEM ACPI control, load acpi_call first:
      sudo modprobe acpi_call
  - The script does not write persistent Xorg, udev, or modprobe config.
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "Missing required command: $1"
        exit 1
    }
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This command must be run as root. Try: sudo $0 $*"
        exit 1
    fi
}

sysfs_write() {
    local path=$1
    local value=$2

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] write '$value' -> $path"
        return 0
    fi

    if [[ ! -e "$path" ]]; then
        warn "Missing sysfs path: $path"
        return 1
    fi

    if printf '%s\n' "$value" > "$path" 2>/dev/null; then
        return 0
    fi

    err "Failed to write '$value' to $path"
    return 1
}

find_nvidia_devices() {
    if [[ -n "$PCI_ADDR" ]]; then
        if [[ "$DRY_RUN" == "true" || -e "/sys/bus/pci/devices/$PCI_ADDR" ]]; then
            printf '%s\n' "$PCI_ADDR"
        fi
        return 0
    fi

    if command -v lspci >/dev/null 2>&1; then
        lspci -D -d 10de: 2>/dev/null | awk '{print $1}'
        return 0
    fi

    for dev in /sys/bus/pci/devices/*; do
        [[ -r "$dev/vendor" ]] || continue
        [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x10de" ]] || continue
        basename "$dev"
    done
}

find_primary_nvidia() {
    find_nvidia_devices | head -n 1
}

device_driver() {
    local dev=$1
    local link="/sys/bus/pci/devices/$dev/driver"
    if [[ -L "$link" ]]; then
        basename "$(readlink -f "$link")"
    else
        printf 'none'
    fi
}

runtime_status() {
    local dev=$1
    local path="/sys/bus/pci/devices/$dev/power/runtime_status"
    if [[ -r "$path" ]]; then
        cat "$path"
    elif [[ -e "/sys/bus/pci/devices/$dev" ]]; then
        printf 'present'
    else
        printf 'removed'
    fi
}

find_root_port() {
    local dev=$1
    local real

    real=$(readlink -f "/sys/bus/pci/devices/$dev" 2>/dev/null || true)
    [[ -n "$real" ]] || return 1

    local current
    current=$(dirname "$real")
    while [[ "$current" == /sys/devices/* ]]; do
        local name class vendor
        name=$(basename "$current")
        [[ "$name" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
            current=$(dirname "$current")
            continue
        }

        class=$(cat "$current/class" 2>/dev/null || true)
        vendor=$(cat "$current/vendor" 2>/dev/null || true)
        if [[ "$class" == 0x0604* && "$vendor" =~ ^0x(8086|1022)$ ]]; then
            printf '%s\n' "$name"
            return 0
        fi
        current=$(dirname "$current")
    done

    return 1
}

acpi_available() {
    [[ -e /proc/acpi/call ]]
}

parse_acpi_hex() {
    local value=$1
    value=${value//$'\0'/}
    value=${value//$'\n'/ }

    if [[ "$value" =~ Error ]]; then
        return 1
    fi
    if [[ "$value" =~ 0[xX]([0-9a-fA-F]+) ]]; then
        printf '%d\n' "0x${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$value" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        printf '%d\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

acpi_eval() {
    local expr=$1
    local result

    if ! acpi_available; then
        return 2
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        printf "${CYAN}[INFO]${NC}  [DRY-RUN] ACPI: %s\n" "$expr" >&2
        printf '0\n'
        return 0
    fi

    if ! printf '%s\n' "$expr" > /proc/acpi/call 2>/dev/null; then
        return 1
    fi

    sleep 0.1
    result=$(cat /proc/acpi/call 2>/dev/null || true)
    if parse_acpi_hex "$result"; then
        return 0
    fi

    warn "ACPI call failed for '$expr': ${result:-empty result}"
    return 1
}

call_igps() {
    local mode=$1
    local prefix result rc

    if ! acpi_available; then
        warn "acpi_call is not available; skipping IGPS($mode)"
        return 2
    fi

    for prefix in "${ACPI_PREFIXES[@]}"; do
        result=$(acpi_eval "$prefix.IGPS $mode") && rc=0 || rc=$?
        [[ $rc -eq 0 ]] || continue

        case "$result" in
            0)
                if [[ "$mode" == "0" ]]; then
                    ok "IGPS(0) via $prefix returned 0: dGPU power-on/bus-check requested"
                    return 0
                fi
                warn "IGPS(1) via $prefix returned 0: unexpected state"
                return 1
                ;;
            1)
                if [[ "$mode" == "1" ]]; then
                    ok "IGPS(1) via $prefix returned 1: iGPU-only state accepted"
                    return 0
                fi
                warn "IGPS(0) via $prefix returned 1: unexpected state"
                return 1
                ;;
            2)
                warn "IGPS($mode) via $prefix returned 2: firmware timed out waiting for D3"
                return 1
                ;;
            170)
                warn "IGPS($mode) via $prefix returned 0xAA: firmware only hit debug _PS3 path"
                return 1
                ;;
            *)
                warn "IGPS($mode) via $prefix returned unknown value: $result"
                return 1
                ;;
        esac
    done

    warn "IGPS($mode) failed on all known ACPI paths"
    return 1
}

query_dgps() {
    local prefix result rc

    acpi_available || return 2
    for prefix in "${ACPI_PREFIXES[@]}"; do
        result=$(acpi_eval "$prefix.DGPS") && rc=0 || rc=$?
        [[ $rc -eq 0 ]] || continue
        case "$result" in
            85) printf 'off'; return 0 ;;
            170) printf 'on'; return 0 ;;
            *) printf 'unknown(%s)' "$result"; return 0 ;;
        esac
    done
    return 1
}

gpu_in_use() {
    local dev=$1
    local driver
    driver=$(device_driver "$dev")

    if [[ "$driver" != nvidia* ]]; then
        return 1
    fi

    if command -v fuser >/dev/null 2>&1; then
        if fuser /dev/nvidia* >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q '[0-9]'; then
            return 0
        fi
    fi

    return 1
}

unload_nvidia_modules() {
    local mod

    for mod in "${NVIDIA_MODULES[@]}"; do
        if [[ ! -d "/sys/module/$mod" ]]; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] modprobe -r $mod"
            continue
        fi

        if modprobe -r "$mod" 2>/tmp/gpu-switch-modprobe.err; then
            ok "Unloaded $mod"
        else
            err "Cannot unload $mod"
            sed 's/^/  /' /tmp/gpu-switch-modprobe.err >&2 || true
            return 1
        fi
    done
}

load_nvidia_modules() {
    local mod

    for mod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] modprobe $mod"
            continue
        fi
        modprobe "$mod" 2>/dev/null || true
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    if [[ -d /sys/module/nvidia ]]; then
        ok "NVIDIA module loaded"
        return 0
    fi

    warn "NVIDIA hardware is present, but the nvidia module is not loaded"
    return 1
}

remove_pci_device() {
    local dev=$1
    local path="/sys/bus/pci/devices/$dev/remove"
    sysfs_write "$path" 1
}

pci_rescan() {
    sysfs_write /sys/bus/pci/rescan 1
}

wait_for_no_nvidia() {
    local i
    if [[ "$DRY_RUN" == "true" ]]; then
        printf "${CYAN}[INFO]${NC}  [DRY-RUN] assume NVIDIA PCI devices disappear\n" >&2
        return 0
    fi

    for i in {1..20}; do
        if [[ -z "$(find_nvidia_devices)" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

wait_for_nvidia() {
    local i found
    if [[ "$DRY_RUN" == "true" ]]; then
        printf "${CYAN}[INFO]${NC}  [DRY-RUN] assume NVIDIA PCI device appears\n" >&2
        printf '%s\n' "${PCI_ADDR:-0000:01:00.0}"
        return 0
    fi

    for i in {1..30}; do
        found=$(find_primary_nvidia || true)
        if [[ -n "$found" ]]; then
            printf '%s\n' "$found"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

cmd_status() {
    local dev dgps modules

    printf "${CYAN}=== GPU Mode Status ===${NC}\n\n"

    if acpi_available; then
        dgps=$(query_dgps 2>/dev/null || true)
        printf "ACPI acpi_call: available\n"
        printf "ACPI DGPS:      %s\n" "${dgps:-unknown}"
    else
        printf "ACPI acpi_call: unavailable\n"
    fi

    printf "\nNVIDIA PCI devices:\n"
    if [[ -z "$(find_nvidia_devices)" ]]; then
        printf "  none\n"
    else
        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            printf "  %s  driver=%s  runtime=%s" "$dev" "$(device_driver "$dev")" "$(runtime_status "$dev")"
            local rp
            rp=$(find_root_port "$dev" 2>/dev/null || true)
            [[ -n "$rp" ]] && printf "  root_port=%s" "$rp"
            printf "\n"
        done < <(find_nvidia_devices)
    fi

    printf "\nNVIDIA modules:\n"
    modules=false
    for mod in "${NVIDIA_MODULES[@]}"; do
        if [[ -d "/sys/module/$mod" ]]; then
            modules=true
            printf "  %-14s loaded\n" "$mod"
        else
            printf "  %-14s not loaded\n" "$mod"
        fi
    done

    printf "\nMode guess: "
    if [[ -z "$(find_nvidia_devices)" ]]; then
        printf "${GREEN}iGPU-only${NC} (NVIDIA absent from PCI bus)\n"
    elif [[ "$modules" == "true" ]]; then
        printf "${GREEN}hybrid/dGPU-present${NC}\n"
    else
        printf "${YELLOW}dGPU present without NVIDIA driver${NC}\n"
    fi
}

cmd_igpu() {
    local devices dev root_ports=() rp remaining dgps

    info "Switching to iGPU-only mode..."
    devices=$(find_nvidia_devices)
    if [[ -z "$devices" ]]; then
        ok "Already iGPU-only: no NVIDIA PCI device is present"
        return 0
    fi

    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        rp=$(find_root_port "$dev" 2>/dev/null || true)
        [[ -n "$rp" ]] && root_ports+=("$rp")
        if gpu_in_use "$dev"; then
            warn "NVIDIA device $dev appears to be in use"
            if [[ "$FORCE" != "true" ]]; then
                read -r -p "Continue and remove it anyway? [y/N] " answer
                [[ "$answer" == "y" || "$answer" == "Y" ]] || {
                    info "Aborted"
                    return 1
                }
            fi
        fi
    done <<< "$devices"

    info "Step 1/4: unload NVIDIA modules"
    unload_nvidia_modules

    info "Step 2/4: request OEM iGPU-only state"
    call_igps 1 || true

    info "Step 3/4: remove NVIDIA PCI functions"
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        if [[ "$DRY_RUN" == "true" || -e "/sys/bus/pci/devices/$dev" ]]; then
            remove_pci_device "$dev" && ok "Removed NVIDIA PCI function $dev" || true
        fi
    done <<< "$devices"

    if ((${#root_ports[@]} > 0)); then
        for rp in "${root_ports[@]}"; do
            if [[ "$DRY_RUN" == "true" || -e "/sys/bus/pci/devices/$rp/remove" ]]; then
                remove_pci_device "$rp" && ok "Removed parent root port $rp" || true
            fi
        done
    fi

    info "Step 4/4: request OEM iGPU-only state again and verify"
    call_igps 1 || true

    if wait_for_no_nvidia; then
        ok "No NVIDIA PCI devices remain"
    else
        remaining=$(find_nvidia_devices)
        err "NVIDIA PCI devices are still present:"
        printf '%s\n' "$remaining" | sed 's/^/  /' >&2
        return 1
    fi

    dgps=$(query_dgps 2>/dev/null || true)
    if [[ "$dgps" == "off" ]]; then
        ok "ACPI DGPS reports dGPU off"
    elif [[ -n "$dgps" ]]; then
        warn "ACPI DGPS reports '$dgps' after PCI removal"
    fi

    ok "iGPU-only switch complete"
}

cmd_hybrid() {
    local dev dgps

    info "Switching to hybrid mode..."

    info "Step 1/4: request OEM hybrid state"
    call_igps 0 || true

    info "Step 2/4: rescan PCI bus"
    pci_rescan || true

    info "Step 3/4: wait for NVIDIA PCI device"
    if ! dev=$(wait_for_nvidia); then
        call_igps 0 || true
        pci_rescan || true
        dev=$(wait_for_nvidia || true)
    fi

    if [[ -z "$dev" ]]; then
        dgps=$(query_dgps 2>/dev/null || true)
        err "dGPU did not appear after ACPI IGPS(0) and PCI rescan"
        [[ -n "$dgps" ]] && err "ACPI DGPS currently reports: $dgps"
        err "A cold reboot may be required if the platform removed the root port deeply"
        return 1
    fi

    ok "Detected NVIDIA PCI device: $dev"

    info "Step 4/4: load NVIDIA driver modules"
    load_nvidia_modules || true

    ok "Hybrid switch complete: $dev driver=$(device_driver "$dev")"
}

cmd_dgpu() {
    cmd_hybrid
    printf "\n"
    warn "dGPU-only display routing is a MUX/display-manager policy, not just PCI power."
    warn "This script only restores the dGPU to the PCI bus and loads the driver."
    info "Use your distro's PRIME/MUX tooling, then log out or reboot if needed."
}

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|igpu|hybrid|dgpu)
                command=$1
                shift
                ;;
            --pci)
                [[ $# -ge 2 ]] || {
                    err "--pci requires an address"
                    exit 1
                }
                PCI_ADDR=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force|-f)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        usage
        exit 1
    fi

    need_cmd awk
    if [[ "$command" != "status" && "$DRY_RUN" != "true" ]]; then
        check_root "$command"
        need_cmd modprobe
    fi

    case "$command" in
        status) cmd_status ;;
        igpu) cmd_igpu ;;
        hybrid) cmd_hybrid ;;
        dgpu) cmd_dgpu ;;
    esac
}

main "$@"
