#!/usr/bin/env bash
# Mechrevo / Tongfang NVIDIA dGPU switch helper for Linux.
#
# Firmware model from DSDT:
#   DGPS()    returns 0x55 when RP09.PXP is off, 0xAA when it is on.
#   IGPS(0)  sets EC IGPU=0 and notifies RP09/PXSX, but only when PXP is off.
#   IGPS(1)  finalizes iGPU-only mode, but only when PXP is already off.
#   PXP._ON  performs the real slot power-on, but refuses while EC IGPU is 1/2.
#   PXP._OFF performs the real slot power-off.
#
# Linux model:
#   Use PCI/sysfs first so the kernel has a chance to run ACPI power resources.
#   Use direct PXP._ON/_OFF only as a guarded fallback when the PCI device has
#   been removed or before rescan, where it is least likely to fight the kernel.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NVIDIA_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
EC_PREFIXES=('\_SB.PC00.LPCB.EC0' '\_SB.PCI0.LPCB.EC0')
PXP_PREFIX='\_SB.PC00.RP09.PXP'

DRY_RUN=false
FORCE=false
PCI_ADDR=""
ALLOW_DIRECT_ACPI=true

info() { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

usage() {
    cat <<EOF
Mechrevo GPU Mode Switcher for Linux

Usage: $(basename "$0") <command> [options]

Commands:
  status        Show ACPI, PCI, module, and runtime-PM state
  igpu          Switch to iGPU-only: unload NVIDIA, remove PCI, power off slot
  hybrid        Switch to hybrid: set EC hybrid state, power on slot, rescan
  dgpu          Alias for hybrid; dGPU-primary still needs distro MUX/PRIME setup

Options:
  --pci ADDR            Use a known NVIDIA PCI address, e.g. 0000:01:00.0
  --dry-run             Print actions without changing ACPI/sysfs/modules
  --force               Skip confirmation if the NVIDIA device appears in use
  --no-direct-acpi      Do not call PXP._ON/_OFF directly as fallback
  -h, --help            Show this help

Recommended first run on target Linux:
  sudo modprobe acpi_call
  sudo $(basename "$0") status
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "Missing required command: $1"
        exit 1
    }
}

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "This command needs root. Try: sudo $0 $*"
        exit 1
    fi
}

have_acpi_call() {
    [[ -e /proc/acpi/call ]]
}

acpi_raw() {
    local expr=$1
    local out

    if ! have_acpi_call; then
        return 2
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        printf "${CYAN}[INFO]${NC}  [DRY-RUN] ACPI %s\n" "$expr" >&2
        printf '0x0\n'
        return 0
    fi

    if ! printf '%s\n' "$expr" > /proc/acpi/call 2>/dev/null; then
        return 1
    fi

    sleep 0.1
    out=$(tr -d '\000' < /proc/acpi/call 2>/dev/null || true)
    if [[ "$out" == *Error* ]]; then
        warn "ACPI '$expr' failed: $out"
        return 1
    fi
    printf '%s\n' "$out"
}

parse_acpi_int() {
    local raw=$1
    raw=${raw//$'\0'/}
    raw=${raw//$'\n'/ }

    if [[ "$raw" =~ 0[xX]([0-9a-fA-F]+) ]]; then
        printf '%d\n' "0x${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$raw" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        printf '%d\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

acpi_int() {
    local expr=$1
    local raw
    raw=$(acpi_raw "$expr") || return $?
    parse_acpi_int "$raw"
}

call_no_return_acpi() {
    local expr=$1
    local raw
    raw=$(acpi_raw "$expr") || return $?
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        return 0
    fi
    parse_acpi_int "$raw" >/dev/null 2>&1 || true
}

dgps_state() {
    local prefix value rc

    have_acpi_call || return 2
    for prefix in "${EC_PREFIXES[@]}"; do
        value=$(acpi_int "$prefix.DGPS") && rc=0 || rc=$?
        [[ $rc -eq 0 ]] || continue
        case "$value" in
            85) printf 'off'; return 0 ;;
            170) printf 'on'; return 0 ;;
            *) printf 'unknown:%s' "$value"; return 0 ;;
        esac
    done
    return 1
}

pxp_state() {
    local value
    have_acpi_call || return 2
    value=$(acpi_int "$PXP_PREFIX._STA") || return $?
    case "$value" in
        0) printf 'off' ;;
        1) printf 'on' ;;
        *) printf 'unknown:%s' "$value" ;;
    esac
}

igps() {
    local mode=$1
    local prefix value rc

    have_acpi_call || {
        warn "acpi_call not available; skip IGPS($mode)"
        return 2
    }

    for prefix in "${EC_PREFIXES[@]}"; do
        value=$(acpi_int "$prefix.IGPS $mode") && rc=0 || rc=$?
        [[ $rc -eq 0 ]] || continue
        case "$value" in
            0)
                if [[ "$mode" == "0" ]]; then
                    ok "IGPS(0) accepted: EC set for hybrid/bus-check"
                    return 0
                fi
                warn "IGPS(1) returned 0, unexpected for iGPU-only"
                return 1
                ;;
            1)
                if [[ "$mode" == "1" ]]; then
                    ok "IGPS(1) accepted: EC set for iGPU-only"
                    return 0
                fi
                warn "IGPS(0) returned 1, unexpected for hybrid"
                return 1
                ;;
            2)
                warn "IGPS($mode) timed out waiting for device D3"
                return 1
                ;;
            170)
                warn "IGPS($mode) returned 0xAA: PXP state not suitable, only debug _PS3 ran"
                return 1
                ;;
            *)
                warn "IGPS($mode) returned unknown value $value"
                return 1
                ;;
        esac
    done

    warn "IGPS($mode) failed on all EC paths"
    return 1
}

direct_pxp() {
    local action=$1

    [[ "$ALLOW_DIRECT_ACPI" == "true" ]] || return 2
    have_acpi_call || return 2

    case "$action" in
        on)
            warn "Direct ACPI fallback: calling $PXP_PREFIX._ON"
            call_no_return_acpi "$PXP_PREFIX._ON"
            ;;
        off)
            warn "Direct ACPI fallback: calling $PXP_PREFIX._OFF"
            call_no_return_acpi "$PXP_PREFIX._OFF"
            ;;
        *)
            return 1
            ;;
    esac
}

sysfs_write() {
    local path=$1
    local value=$2

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] write '$value' -> $path"
        return 0
    fi

    [[ -e "$path" ]] || return 1
    if printf '%s\n' "$value" > "$path" 2>/dev/null; then
        return 0
    fi
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

driver_of() {
    local dev=$1
    local link="/sys/bus/pci/devices/$dev/driver"
    if [[ -L "$link" ]]; then
        basename "$(readlink -f "$link")"
    else
        printf 'none'
    fi
}

runtime_status_of() {
    local dev=$1
    local p="/sys/bus/pci/devices/$dev/power/runtime_status"
    if [[ -r "$p" ]]; then
        cat "$p"
    elif [[ -e "/sys/bus/pci/devices/$dev" ]]; then
        printf 'present'
    else
        printf 'removed'
    fi
}

find_root_port() {
    local dev=$1
    local real current name class vendor

    real=$(readlink -f "/sys/bus/pci/devices/$dev" 2>/dev/null || true)
    [[ -n "$real" ]] || return 1

    current=$(dirname "$real")
    while [[ "$current" == /sys/devices/* ]]; do
        name=$(basename "$current")
        if [[ "$name" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
            class=$(cat "$current/class" 2>/dev/null || true)
            vendor=$(cat "$current/vendor" 2>/dev/null || true)
            if [[ "$class" == 0x0604* && "$vendor" =~ ^0x(8086|1022)$ ]]; then
                printf '%s\n' "$name"
                return 0
            fi
        fi
        current=$(dirname "$current")
    done
    return 1
}

set_runtime_auto() {
    local dev=$1
    sysfs_write "/sys/bus/pci/devices/$dev/power/control" auto || true
}

remove_device() {
    local dev=$1
    sysfs_write "/sys/bus/pci/devices/$dev/remove" 1
}

pci_rescan() {
    sysfs_write /sys/bus/pci/rescan 1
}

gpu_in_use() {
    local dev=$1
    [[ "$(driver_of "$dev")" == nvidia* ]] || return 1

    if command -v fuser >/dev/null 2>&1 && fuser /dev/nvidia* >/dev/null 2>&1; then
        return 0
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q '[0-9]' && return 0
    fi
    return 1
}

unload_nvidia() {
    local mod
    for mod in "${NVIDIA_MODULES[@]}"; do
        [[ -d "/sys/module/$mod" ]] || continue
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] modprobe -r $mod"
        elif modprobe -r "$mod" 2>/tmp/gpu-switch-modprobe.err; then
            ok "Unloaded $mod"
        else
            err "Failed to unload $mod"
            sed 's/^/  /' /tmp/gpu-switch-modprobe.err >&2 || true
            return 1
        fi
    done
}

load_nvidia() {
    local mod
    for mod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] modprobe $mod"
        else
            modprobe "$mod" 2>/dev/null || true
        fi
    done

    [[ "$DRY_RUN" == "true" || -d /sys/module/nvidia ]]
}

wait_no_nvidia() {
    local i
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] assume no NVIDIA PCI devices remain"
        return 0
    fi

    for i in {1..20}; do
        [[ -z "$(find_nvidia_devices)" ]] && return 0
        sleep 0.5
    done
    return 1
}

wait_nvidia() {
    local i dev
    if [[ "$DRY_RUN" == "true" ]]; then
        printf "${CYAN}[INFO]${NC}  [DRY-RUN] assume NVIDIA PCI device appears\n" >&2
        printf '%s\n' "${PCI_ADDR:-0000:01:00.0}"
        return 0
    fi

    for i in {1..30}; do
        dev=$(find_primary_nvidia || true)
        [[ -n "$dev" ]] && printf '%s\n' "$dev" && return 0
        sleep 0.5
    done
    return 1
}

show_status() {
    local dev rp modules=false dgps pxp devices

    printf "${CYAN}=== GPU Mode Status ===${NC}\n\n"

    if have_acpi_call; then
        dgps=$(dgps_state 2>/dev/null || true)
        pxp=$(pxp_state 2>/dev/null || true)
        printf "ACPI acpi_call: available\n"
        printf "ACPI DGPS:      %s\n" "${dgps:-unknown}"
        printf "ACPI PXP._STA:  %s\n" "${pxp:-unknown}"
    else
        printf "ACPI acpi_call: unavailable\n"
    fi

    devices=$(find_nvidia_devices || true)

    printf "\nNVIDIA PCI devices:\n"
    if [[ -z "$devices" ]]; then
        printf "  none\n"
    else
        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            rp=$(find_root_port "$dev" 2>/dev/null || true)
            printf "  %s  driver=%s  runtime=%s" "$dev" "$(driver_of "$dev")" "$(runtime_status_of "$dev")"
            [[ -n "$rp" ]] && printf "  root_port=%s runtime=%s" "$rp" "$(runtime_status_of "$rp")"
            printf "\n"
        done <<< "$devices"
    fi

    printf "\nNVIDIA modules:\n"
    for mod in "${NVIDIA_MODULES[@]}"; do
        if [[ -d "/sys/module/$mod" ]]; then
            modules=true
            printf "  %-14s loaded\n" "$mod"
        else
            printf "  %-14s not loaded\n" "$mod"
        fi
    done

    printf "\nMode guess: "
    if [[ -n "$devices" && ( "${dgps:-}" == "off" || "${pxp:-}" == "off" ) ]]; then
        printf "${YELLOW}inconsistent: ACPI says dGPU power is off, but PCI device is present${NC}\n"
    elif [[ -z "$devices" ]]; then
        printf "${GREEN}iGPU-only / dGPU absent from PCI${NC}\n"
    elif [[ "$modules" == "true" ]]; then
        printf "${GREEN}hybrid / dGPU present with NVIDIA stack${NC}\n"
    else
        printf "${YELLOW}dGPU present, driver not loaded${NC}\n"
    fi
}

switch_igpu() {
    local devices dev rp root_ports=() state pxp remaining finalized=false

    info "Switching to iGPU-only..."
    devices=$(find_nvidia_devices || true)
    if [[ -z "$devices" ]]; then
        state=$(dgps_state 2>/dev/null || true)
        if [[ "$state" == "off" || -z "$state" ]]; then
            ok "Already iGPU-only: no NVIDIA PCI device is present"
            return 0
        fi
        warn "No NVIDIA PCI device is present, but ACPI still reports dGPU $state"
    fi

    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        gpu_in_use "$dev" && {
            warn "NVIDIA device $dev appears to be in use"
            if [[ "$FORCE" != "true" ]]; then
                read -r -p "Continue anyway? [y/N] " answer
                [[ "$answer" == "y" || "$answer" == "Y" ]] || return 1
            fi
        }
        rp=$(find_root_port "$dev" 2>/dev/null || true)
        [[ -n "$rp" ]] && root_ports+=("$rp")
    done <<< "$devices"

    info "Step 1/5: unload NVIDIA modules"
    unload_nvidia

    info "Step 2/5: allow Linux runtime PM on dGPU/root port"
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        set_runtime_auto "$dev"
    done <<< "$devices"
    for rp in "${root_ports[@]:-}"; do
        [[ -n "$rp" ]] && set_runtime_auto "$rp"
    done
    sleep 1

    state=$(dgps_state 2>/dev/null || true)
    pxp=$(pxp_state 2>/dev/null || true)
    if [[ "$state" == "off" || "$pxp" == "off" ]]; then
        info "Firmware already reports PXP off; try IGPS(1) before PCI removal"
        if igps 1; then
            finalized=true
        fi
    fi

    info "Step 3/5: remove NVIDIA PCI functions"
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        if [[ "$DRY_RUN" == "true" || -e "/sys/bus/pci/devices/$dev/remove" ]]; then
            remove_device "$dev" && ok "Removed NVIDIA function $dev" || warn "Could not remove $dev"
        fi
    done <<< "$devices"

    for rp in "${root_ports[@]:-}"; do
        [[ -n "$rp" ]] || continue
        if [[ "$DRY_RUN" == "true" || -e "/sys/bus/pci/devices/$rp/remove" ]]; then
            remove_device "$rp" && ok "Removed root port $rp" || warn "Could not remove root port $rp"
        fi
    done

    info "Step 4/5: verify/force ACPI PXP off"
    sleep 1
    state=$(dgps_state 2>/dev/null || true)
    pxp=$(pxp_state 2>/dev/null || true)
    if [[ "$state" != "off" && "$pxp" != "off" && "$ALLOW_DIRECT_ACPI" == "true" ]]; then
        direct_pxp off || true
        sleep 1
    fi

    info "Step 5/5: finalize EC iGPU-only state with IGPS(1)"
    if [[ "$finalized" == "true" ]]; then
        ok "IGPS(1) already accepted before PCI removal"
    else
        state=$(dgps_state 2>/dev/null || true)
        pxp=$(pxp_state 2>/dev/null || true)
        if [[ "$state" == "off" || "$pxp" == "off" ]]; then
            warn "Skipping late IGPS(1): PXP is already off and PCI devices were removed"
        else
            igps 1 || true
        fi
    fi

    if ! wait_no_nvidia; then
        remaining=$(find_nvidia_devices || true)
        err "NVIDIA PCI devices still present:"
        printf '%s\n' "$remaining" | sed 's/^/  /' >&2
        return 1
    fi

    state=$(dgps_state 2>/dev/null || true)
    if [[ "$state" == "off" ]]; then
        ok "ACPI reports dGPU power resource off"
    elif [[ -n "$state" ]]; then
        warn "ACPI DGPS reports '$state' even though PCI device is gone"
    fi

    ok "iGPU-only sequence complete"
}

switch_hybrid() {
    local dev state devices

    info "Switching to hybrid..."
    devices=$(find_nvidia_devices || true)

    info "Step 1/4: set EC hybrid intent with IGPS(0)"
    igps 0 || true

    state=$(dgps_state 2>/dev/null || true)
    if [[ -n "$devices" ]]; then
        info "Step 2/4: dGPU is already present on PCI; skip direct PXP._ON"
    elif [[ "$state" != "on" && "$ALLOW_DIRECT_ACPI" == "true" ]]; then
        info "Step 2/4: power on RP09.PXP if kernel rescan needs help"
        direct_pxp on || true
        sleep 1
    else
        info "Step 2/4: ACPI already reports dGPU power resource on or unavailable"
    fi

    info "Step 3/4: rescan PCI bus"
    pci_rescan || warn "Global PCI rescan write failed"
    sleep 1

    dev=$(wait_nvidia || true)
    if [[ -z "$dev" ]]; then
        err "NVIDIA PCI device did not appear"
        state=$(dgps_state 2>/dev/null || true)
        [[ -n "$state" ]] && err "ACPI DGPS reports: $state"
        return 1
    fi
    ok "NVIDIA device present: $dev"

    info "Step 4/4: load NVIDIA modules"
    if load_nvidia; then
        ok "NVIDIA driver stack loaded or dry-run accepted"
    else
        warn "NVIDIA device is present, but driver stack did not load"
    fi

    ok "Hybrid sequence complete: $dev driver=$(driver_of "$dev")"
}

switch_dgpu() {
    switch_hybrid
    printf "\n"
    warn "dGPU-only display routing is not just power control."
    warn "Use your distro's MUX/PRIME tooling, then restart the display session if needed."
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
            --no-direct-acpi)
                ALLOW_DIRECT_ACPI=false
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

    [[ -n "$command" ]] || {
        usage
        exit 1
    }

    need_cmd awk
    if [[ "$command" != "status" && "$DRY_RUN" != "true" ]]; then
        need_root "$command"
        need_cmd modprobe
    fi

    case "$command" in
        status) show_status ;;
        igpu) switch_igpu ;;
        hybrid) switch_hybrid ;;
        dgpu) switch_dgpu ;;
    esac
}

main "$@"
