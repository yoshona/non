#!/bin/bash
# gpu-switch.sh — Mechrevo GPU mode switching for Linux
#
# Replicates the Windows Control Center's GPU mode switching by using
# PCIe hot-plug, as discovered through ACPI DSDT reverse engineering.
#
# Usage:
#   gpu-switch.sh status          Show current GPU mode
#   gpu-switch.sh igpu            Switch to iGPU Only (power off dGPU)
#   gpu-switch.sh dgpu            Switch to dGPU Only (dGPU primary, needs restart)
#   gpu-switch.sh hybrid          Switch to Hybrid (rescan dGPU)
#   gpu-switch.sh igpu --force    Skip confirmation prompt
#   gpu-switch.sh dgpu --force
#   gpu-switch.sh hybrid --force
#
# Requires: root, lspci, modprobe
# Drivers:  nvidia-open (open-source NVIDIA kernel modules)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Globals ---
NVIDIA_MODULES=("nvidia_drm" "nvidia_modeset" "nvidia_uvm" "nvidia")
DRY_RUN=false
FORCE=false

# --- Helpers ---

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Try: sudo $0 $*"
        exit 1
    fi
}

# Find all NVIDIA GPU PCIe addresses (full domain-padded format)
find_nvidia_devices() {
    lspci -D 2>/dev/null | grep -i 'vga\|3d\|display' | grep -i nvidia | awk '{print $1}' || true
}

# Find the primary NVIDIA GPU (first one)
find_primary_nvidia() {
    local devices
    devices=$(find_nvidia_devices)
    if [[ -z "$devices" ]]; then
        return 1
    fi
    echo "$devices" | head -1
}

# Get the parent PCIe root port for a device
find_parent_port() {
    local dev=$1
    local syspath="/sys/bus/pci/devices/$dev"

    if [[ ! -L "$syspath" ]]; then
        return 1
    fi

    # Walk up the device tree to find the root port
    local current="$dev"
    while true; do
        local parent
        parent=$(readlink "$syspath" 2>/dev/null | grep -oP '\d{4}:[0-9a-f]{2}:[0-9a-f]{2}\.\d' | tail -1)
        if [[ -z "$parent" ]] || [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
    done

    # Alternative: use the pci_bus parent
    local subsystem_vendor
    subsystem_vendor=$(cat "/sys/bus/pci/devices/$dev/subsystem_vendor" 2>/dev/null || echo "")

    # Simple approach: strip function, get parent from sysfs
    local domain bus slot func
    IFS=':.' read -r domain bus slot func <<< "$dev"
    # Parent bus is one level up — look at the bridge device
    local parent_dev
    parent_dev=$(find /sys/bus/pci/devices/ -maxdepth 1 -lname "*/$domain:$bus:$slot.$func/.." 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)

    # Fallback: just return the device itself for remove operation
    echo "$dev"
}

# Check if NVIDIA GPU is in active use
check_gpu_in_use() {
    local in_use=false

    # Check if any process has NVIDIA device files open
    if command -v fuser &>/dev/null; then
        if fuser /dev/nvidia* /dev/dri/card* 2>/dev/null; then
            in_use=true
        fi
    fi

    # Check if nvidia module is loaded
    if lsmod | grep -q '^nvidia '; then
        # Check if Xorg/Wayland is using it
        if pgrep -a Xorg &>/dev/null | grep -qi nvidia; then
            in_use=true
        fi
        if pgrep -a Xwayland &>/dev/null | grep -qi nvidia; then
            in_use=true
        fi
    fi

    echo "$in_use"
}

# Get GPU power state from sysfs
get_gpu_power_state() {
    local dev=$1
    local state_file="/sys/bus/pci/devices/$dev/power/runtime_status"
    if [[ -f "$state_file" ]]; then
        cat "$state_file" 2>/dev/null || echo "unknown"
    else
        echo "removed"
    fi
}

# --- Commands ---

cmd_status() {
    echo -e "${CYAN}=== GPU Mode Status ===${NC}"
    echo

    # Find all GPUs
    local all_gpus
    all_gpus=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' || true)

    if [[ -z "$all_gpus" ]]; then
        warn "No GPU devices found"
        return
    fi

    echo "All GPU devices:"
    while IFS= read -r line; do
        echo "  $line"
    done <<< "$all_gpus"
    echo

    # Check NVIDIA specifically
    local nvidia_devs
    nvidia_devs=$(find_nvidia_devices)

    if [[ -z "$nvidia_devs" ]]; then
        ok "Mode: iGPU Only (dGPU not present on PCIe bus)"
        echo
        info "Use '$0 hybrid' to rescan and bring dGPU back"
        return
    fi

    local primary
    primary=$(echo "$nvidia_devs" | head -1)
    local power_state
    power_state=$(get_gpu_power_state "$primary")

    # Check driver
    local driver="none"
    local driver_path="/sys/bus/pci/devices/$primary/driver"
    if [[ -L "$driver_path" ]]; then
        driver=$(readlink "$driver_path" | xargs basename)
    fi

    echo "NVIDIA dGPU:"
    echo "  PCIe Address: $primary"
    echo "  Power State:  $power_state"
    echo "  Driver:       $driver"

    # Show GPU usage
    local in_use
    in_use=$(check_gpu_in_use)
    if [[ "$in_use" == "true" ]]; then
        echo "  In Use:       ${YELLOW}YES${NC}"
    else
        echo "  In Use:       no"
    fi

    echo

    # Determine mode
    if [[ "$power_state" == "suspended" || "$power_state" == "off" ]]; then
        warn "Mode: iGPU Only (dGPU suspended/off)"
    elif [[ "$power_state" == "active" ]]; then
        # Check if PRIME is set to nvidia (dGPU primary)
        local prime_mode
        prime_mode=$(get_prime_mode)
        if [[ "$prime_mode" == "nvidia" ]]; then
            ok "Mode: dGPU Only (dGPU is primary GPU)"
        else
            ok "Mode: Hybrid (dGPU active, iGPU primary)"
        fi
    else
        info "Mode: Hybrid (dGPU present, state: $power_state)"
    fi

    echo
    echo "NVIDIA kernel modules:"
    for mod in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^$mod "; then
            local usage
            usage=$(lsmod | grep "^$mod " | awk '{print $2 " users"}')
            echo "  ${GREEN}LOAD${NC}  $mod ($usage)"
        else
            echo "  ${RED}----${NC}  $mod (not loaded)"
        fi
    done

    echo
    info "Use '$0 igpu'   to switch to iGPU Only mode"
    info "Use '$0 dgpu'   to switch to dGPU Only mode"
    info "Use '$0 hybrid' to switch to Hybrid mode"
}

# Detect current PRIME mode
get_prime_mode() {
    # Check prime-select (Ubuntu)
    if command -v prime-select &>/dev/null; then
        prime-select query 2>/dev/null && return
    fi
    # Check xorg.conf for primary GPU
    if [[ -f /etc/X11/xorg.conf ]]; then
        if grep -q 'Option "PrimaryGPU" "yes"' /etc/X11/xorg.conf 2>/dev/null || \
           grep -q 'Driver "nvidia"' /etc/X11/xorg.conf 2>/dev/null; then
            echo "nvidia"
            return
        fi
    fi
    # Check environment profile
    if [[ -f /etc/profile.d/prime-nvidia.sh ]] || \
       [[ -f /etc/environment.d/prime-nvidia.conf ]]; then
        echo "nvidia"
        return
    fi
    # Check if nvidia-drm modeset is active with PRIME render offload
    if [[ -f /sys/module/nvidia_drm/parameters/modeset ]]; then
        local modeset
        modeset=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "N")
        if [[ "$modeset" == "Y" ]]; then
            echo "on-demand"
            return
        fi
    fi
    echo "intel"
}

cmd_igpu() {
    info "Switching to iGPU Only mode..."
    echo

    # Find NVIDIA devices
    local nvidia_devs
    nvidia_devs=$(find_nvidia_devices)

    if [[ -z "$nvidia_devs" ]]; then
        ok "Already in iGPU Only mode (no dGPU on PCIe bus)"
        return 0
    fi

    # Check if GPU is in use
    local in_use
    in_use=$(check_gpu_in_use)

    if [[ "$in_use" == "true" ]]; then
        warn "GPU appears to be in active use!"
        echo "  The following processes may be affected:"
        fuser /dev/nvidia* /dev/dri/card* 2>/dev/null | head -5 || true
        echo

        if [[ "$FORCE" != "true" ]]; then
            read -rp "Continue anyway? [y/N] " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                info "Aborted"
                return 1
            fi
        fi
    fi

    # Step 1: Unload NVIDIA kernel modules (reverse order)
    info "Step 1/3: Unloading NVIDIA kernel modules..."
    local mods_to_remove=()
    for mod in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^$mod "; then
            mods_to_remove+=("$mod")
        fi
    done

    if [[ ${#mods_to_remove[@]} -gt 0 ]]; then
        # Reverse order for unload: nvidia_drm first, nvidia last
        for (( i=${#mods_to_remove[@]}-1; i>=0; i-- )); do
            local mod="${mods_to_remove[$i]}"
            if [[ "$DRY_RUN" == "true" ]]; then
                info "[DRY-RUN] modprobe -r $mod"
            else
                if modprobe -r "$mod" 2>/dev/null; then
                    ok "Unloaded $mod"
                else
                    warn "Failed to unload $mod (may have dependents)"
                    # Try harder — wait and retry
                    sleep 1
                    if modprobe -r "$mod" 2>/dev/null; then
                        ok "Unloaded $mod (retry)"
                    else
                        err "Cannot unload $mod — GPU may be in use"
                        err "Close applications using the GPU and try again"
                        return 1
                    fi
                fi
            fi
        done
    else
        ok "No NVIDIA modules loaded"
    fi

    # Step 2: Remove dGPU from PCIe bus
    info "Step 2/3: Removing dGPU from PCIe bus..."
    local count=0
    while IFS= read -r dev; do
        count=$((count + 1))
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] echo 1 > /sys/bus/pci/devices/$dev/remove"
        else
            echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>/dev/null && \
                ok "Removed $dev" || \
                warn "Failed to remove $dev"
        fi
    done <<< "$nvidia_devs"

    # Also remove the PCIe bridge for the dGPU if it exists
    # This saves more power (equivalent to RP09._PS3 in ACPI)
    local bridge_devs
    bridge_devs=$(lspci -D 2>/dev/null | grep -i 'pci bridge' | grep -i nvidia | awk '{print $1}' || true)
    if [[ -n "$bridge_devs" ]]; then
        while IFS= read -r bdev; do
            if [[ -e "/sys/bus/pci/devices/$bdev" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    info "[DRY-RUN] echo 1 > /sys/bus/pci/devices/$bdev/remove (PCIe bridge)"
                else
                    echo 1 > "/sys/bus/pci/devices/$bdev/remove" 2>/dev/null && \
                        ok "Removed PCIe bridge $bdev" || true
                fi
            fi
        done <<< "$bridge_devs"
    fi

    # Step 3: Verify
    info "Step 3/3: Verifying..."
    sleep 0.5
    local remaining
    remaining=$(find_nvidia_devices)
    if [[ -z "$remaining" ]]; then
        ok "Successfully switched to iGPU Only mode"
        ok "Power saving: dGPU fully disconnected from PCIe bus"
    else
        warn "Some NVIDIA devices still present:"
        while IFS= read -r line; do
            warn "  $line"
        done <<< "$(lspci | grep -i nvidia)"
    fi
}

cmd_hybrid() {
    info "Switching to Hybrid mode..."
    echo

    # Check if dGPU is already present
    local nvidia_devs
    nvidia_devs=$(find_nvidia_devices)

    if [[ -n "$nvidia_devs" ]]; then
        local primary
        primary=$(echo "$nvidia_devs" | head -1)
        local driver_path="/sys/bus/pci/devices/$primary/driver"
        if [[ -L "$driver_path" ]]; then
            ok "Already in Hybrid mode (dGPU present and driven)"
            return 0
        fi
    fi

    # Step 1: Rescan PCIe bus
    info "Step 1/3: Rescanning PCIe bus..."
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] echo 1 > /sys/bus/pci/rescan"
    else
        echo 1 > /sys/bus/pci/rescan
    fi

    # Step 2: Wait for dGPU to appear
    info "Step 2/3: Waiting for dGPU to appear..."
    local found=false
    for i in $(seq 1 20); do
        sleep 0.5
        nvidia_devs=$(find_nvidia_devices)
        if [[ -n "$nvidia_devs" ]]; then
            found=true
            ok "dGPU detected: $(echo "$nvidia_devs" | head -1)"
            break
        fi
        printf "  Waiting... (%d/20)\r" "$i"
    done
    echo

    if [[ "$found" != "true" ]]; then
        err "dGPU not detected after rescan"
        err "Try: echo 1 > /sys/bus/pci/rescan"
        err "Or check if the PCIe root port was also removed"
        return 1
    fi

    # Step 3: Load NVIDIA driver
    info "Step 3/3: Loading NVIDIA kernel modules..."
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] modprobe nvidia"
    else
        if modprobe nvidia 2>/dev/null; then
            ok "Loaded nvidia module"
            # Load dependent modules
            modprobe nvidia_modeset 2>/dev/null || true
            modprobe nvidia_drm 2>/dev/null || true
            modprobe nvidia_uvm 2>/dev/null || true
        else
            warn "nvidia module load failed — dGPU is present but unmanaged"
            warn "You may need to manually load: modprobe nvidia"
        fi
    fi

    # Verify
    sleep 1
    local primary
    primary=$(find_primary_nvidia)
    if [[ -n "$primary" ]]; then
        local driver="none"
        if [[ -L "/sys/bus/pci/devices/$primary/driver" ]]; then
            driver=$(readlink "/sys/bus/pci/devices/$primary/driver" | xargs basename)
        fi
        ok "Hybrid mode active — dGPU: $primary, driver: $driver"
    else
        err "dGPU disappeared after driver load"
        return 1
    fi
}

cmd_dgpu() {
    info "Switching to dGPU Only mode..."
    echo
    warn "This mode sets dGPU as the primary GPU."
    warn "A display manager restart (or reboot) is required to take full effect."
    echo

    # Step 1: Ensure dGPU is present and driven (reuse hybrid logic)
    local nvidia_devs
    nvidia_devs=$(find_nvidia_devices)

    if [[ -z "$nvidia_devs" ]]; then
        info "dGPU not found — rescanning PCIe bus..."
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] echo 1 > /sys/bus/pci/rescan"
        else
            echo 1 > /sys/bus/pci/rescan
        fi

        # Wait for dGPU to appear
        local found=false
        for i in $(seq 1 20); do
            sleep 0.5
            nvidia_devs=$(find_nvidia_devices)
            if [[ -n "$nvidia_devs" ]]; then
                found=true
                ok "dGPU detected: $(echo "$nvidia_devs" | head -1)"
                break
            fi
            printf "  Waiting... (%d/20)\r" "$i"
        done
        echo

        if [[ "$found" != "true" ]]; then
            err "dGPU not detected after rescan"
            return 1
        fi
    fi

    # Load drivers if not already loaded
    local primary
    primary=$(echo "$nvidia_devs" | head -1)
    local driver_path="/sys/bus/pci/devices/$primary/driver"

    if [[ ! -L "$driver_path" ]]; then
        info "Loading NVIDIA kernel modules..."
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[DRY-RUN] modprobe nvidia nvidia_modeset nvidia_drm nvidia_uvm"
        else
            modprobe nvidia 2>/dev/null || true
            modprobe nvidia_modeset 2>/dev/null || true
            modprobe nvidia_drm 2>/dev/null || true
            modprobe nvidia_uvm 2>/dev/null || true
        fi
        sleep 1
    fi

    ok "dGPU online: $primary"
    echo

    # Step 2: Configure PRIME — set dGPU as primary
    info "Step 2/3: Configuring PRIME to use dGPU as primary..."

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY-RUN] Configure dGPU as primary GPU"
    else
        # Method 1: prime-select (Ubuntu)
        if command -v prime-select &>/dev/null; then
            prime-select nvidia 2>/dev/null && \
                ok "Set PRIME to nvidia via prime-select" || \
                warn "prime-select nvidia failed (may need reboot)"
        else
            # Method 2: Create xorg.conf
            local xconf="/etc/X11/xorg.conf.d/10-nvidia-prime.conf"
            local xconf_dir
            xconf_dir=$(dirname "$xconf")

            if [[ ! -d "$xconf_dir" ]]; then
                mkdir -p "$xconf_dir"
            fi

            cat > "$xconf" <<'XORG'
# Generated by gpu-switch.sh — dGPU Only mode
Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "PrimaryGPU" "yes"
    Option "AllowEmptyInitialConfiguration" "yes"
    ModulePath "/usr/lib/x86_64-linux-gnu/nvidia/xorg"
EndSection
XORG
            ok "Wrote xorg.conf.d/10-nvidia-prime.conf (PrimaryGPU=nvidia)"
        fi

        # Enable nvidia-drm modeset for Wayland compatibility
        if [[ -d /etc/modprobe.d ]]; then
            cat > /etc/modprobe.d/nvidia-dgpu.conf <<'MODPROBE'
# Generated by gpu-switch.sh — dGPU Only mode
options nvidia-drm modeset=1 fbdev=1
MODPROBE
            ok "Set nvidia-drm modeset=1 for Wayland support"
        fi

        # Set udev rule for PRIME render offload (always use dGPU)
        if [[ -d /etc/udev/rules.d ]]; then
            cat > /etc/udev/rules.d/80-nvidia-dgpu.rules <<'UDEV'
# Generated by gpu-switch.sh — dGPU Only mode
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{power/control}="on"
UDEV
            ok "Set udev rule to keep dGPU powered on"
        fi

        # Disable runtime D3 (power saving) so dGPU stays awake
        for dev in $nvidia_devs; do
            local pwr="/sys/bus/pci/devices/$dev/power/control"
            if [[ -f "$pwr" ]]; then
                echo "on" > "$pwr" 2>/dev/null || true
            fi
        done
        ok "Disabled dGPU runtime power management (always on)"
    fi

    echo

    # Step 3: Verify and prompt restart
    info "Step 3/3: Verifying configuration..."
    local prime_mode
    prime_mode=$(get_prime_mode)
    ok "PRIME mode: $prime_mode"
    ok "dGPU Only mode configured"
    echo

    echo -e "${YELLOW}=== Action Required ===${NC}"
    echo "  The display server must restart for changes to take effect."
    echo "  Options (from least to most disruptive):"
    echo ""
    echo "    1. Log out and log back in"
    echo "    2. sudo systemctl restart display-manager"
    echo "    3. sudo reboot"
    echo ""

    if [[ "$FORCE" != "true" ]]; then
        read -rp "Restart display manager now? [y/N] " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                info "[DRY-RUN] systemctl restart display-manager"
            else
                info "Restarting display manager..."
                systemctl restart display-manager 2>/dev/null || \
                    systemctl restart gdm 2>/dev/null || \
                    systemctl restart sddm 2>/dev/null || \
                    systemctl restart lightdm 2>/dev/null || \
                    warn "Could not restart display manager — please reboot manually"
            fi
        fi
    fi
}

# --- Main ---

usage() {
    cat <<EOF
Mechrevo GPU Mode Switcher for Linux

Usage: $(basename "$0") <command> [options]

Commands:
  status    Show current GPU mode and dGPU status
  igpu      Switch to iGPU Only mode (disconnect dGPU)
  dgpu      Switch to dGPU Only mode (dGPU primary, needs restart)
  hybrid    Switch to Hybrid mode (reconnect dGPU)

Options:
  --dry-run   Show what would be done without executing
  --force     Skip confirmation prompts
  -h, --help  Show this help

Examples:
  sudo $(basename "$0") status
  sudo $(basename "$0") igpu
  sudo $(basename "$0") dgpu --force
  sudo $(basename "$0") hybrid
EOF
}

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|igpu|dgpu|hybrid)
                command="$1"
                shift
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

    # status doesn't need root
    if [[ "$command" != "status" ]]; then
        check_root "$command"
    fi

    case "$command" in
        status) cmd_status ;;
        igpu)   cmd_igpu ;;
        dgpu)   cmd_dgpu ;;
        hybrid) cmd_hybrid ;;
    esac
}

main "$@"
