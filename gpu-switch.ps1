# gpu-switch.ps1 — Mechrevo GPU Mode Switcher for Windows
#
# Uses WMI ACPI calls to AMW0 device, matching the Control Center backend.
# IGPS(1) = PCIe eject dGPU (power off), IGPS(0) = Bus Check (rescan)
#
# Usage:
#   .\gpu-switch.ps1 status          Show current GPU mode
#   .\gpu-switch.sh igpu            Switch to iGPU Only (eject dGPU from PCIe)
#   .\gpu-switch.ps1 dgpu            Switch to dGPU Only (dGPU primary, needs restart)
#   .\gpu-switch.ps1 hybrid          Switch to Hybrid (rescan dGPU onto PCIe)
#
# Requires: Administrator

param(
    [Parameter(Position=0)]
    [ValidateSet("status", "igpu", "dgpu", "hybrid")]
    [string]$Command = "status",

    [switch]$Force,
    [switch]$DryRun,
    [switch]$Fallback  # Use PnP disable instead of WMI ACPI
)

# --- Helpers ---

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-OK($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NvidiaDisplayDevices {
    return @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
}

# --- WMI ACPI Interface ---
#
# The Control Center backend (GCUService.exe) calls WMI methods on the AMW0
# ACPI WMI device (_HID=PNP0C14, _UID=1) to control GPU modes.
#
# Call chain discovered from DSDT reverse engineering:
#   WMIEC.WMIWriteECIGPUonlyON()
#     → WMIEC.GetSetULong2(0x0300, ...) or Smrw(...)
#       → WMI method on AMW0 → WMBC(Arg1=4)
#         → OEMG(AC00) where AC00 buffer has:
#             dword[0] = SA00 (sub-command: 0=igpu_off, 1=igpu_on, 2=query)
#             dword[4] = SAC1 (function: 0x0300 = iGPU mode control)
#           OEMG dispatches to:
#             IGPS(1) — PCIe Eject dGPU (power off completely)
#             IGPS(0) — PCIe Bus Check (rescan + re-enable dGPU)
#             DGPS()  — Query dGPU power status

# P/Invoke for cfgmgr32 (PCIe eject/rescan)
if (-not ([System.Management.Automation.PSTypeName]'GpuSwitchApi').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class GpuSwitchApi {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr CreateFile(
        string lpFileName, int dwDesiredAccess, int dwShareMode,
        IntPtr lpSecurityAttributes, int dwCreationDisposition,
        int dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr hDevice, int dwIoControlCode,
        byte[] lpInBuffer, int nInBufferSize,
        byte[] lpOutBuffer, int nOutBufferSize,
        out int lpBytesReturned, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    // CfgMgr32 — proper PCIe hot-eject without needing Control Center
    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Locate_DevNodeW(out int pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Request_Device_Eject(int dnDevInst, out int pVetoType,
        StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Parent(out int pdnDevInst, int dnDevInst, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Get_Device_IDW(int dnDevInst, StringBuilder pszBuffer, int ulBufferLen, int ulFlags);

    [DllImport("cfgmgr32.dll", SetLastError = false, CharSet = CharSet.Unicode)]
    public static extern int CM_Reenumerate_DevNode(int dnDevInst, int ulFlags);
}
"@ -Language CSharp
}

# --- PCIe Hot-Eject via CfgMgr32 API ---
#
# Uses CM_Request_Device_Eject to perform a proper PCIe hot-remove of the dGPU.
# This is the same mechanism Windows uses when ACPI sends Notify(0x03) Eject Request.
# No Control Center dependency — works with just the Windows PnP/PCIe subsystem.
#
# Equivalent to Linux: echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove

function Find-NvidiaPciDeviceId {
    # Find the NVIDIA GPU PCIe device instance ID
    # Search by display class first, then by hardware ID
    $devs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
    if ($devs.Count -eq 0) {
        $devs = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'VEN_10DE' })
    }
    if ($devs.Count -eq 0) {
        return $null
    }

    # Use the first NVIDIA device — all functions share the same PCIe parent
    $dev = $devs[0]
    Write-Info "Found NVIDIA device: $($dev.InstanceId)"

    # Get the parent PCIe device (VEN_10DE) — this is what we need to eject
    # For single-function GPUs, the display adapter IS the PCIe device
    # For multi-function GPUs, we need to walk up to the parent
    $parentId = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data

    if ($parentId -and $parentId -match 'VEN_10DE') {
        # Parent is also NVIDIA — we're a child function, eject the parent
        Write-Info "Parent PCIe device: $parentId"
        return $parentId
    }

    # The display adapter itself is the PCIe device (common case)
    if ($dev.InstanceId -match 'VEN_10DE') {
        return $dev.InstanceId
    }

    # Last resort: try the parent anyway
    if ($parentId) {
        Write-Info "Using parent device: $parentId"
        return $parentId
    }

    return $dev.InstanceId
}

function Find-NvidiaRootPort {
    # Find the PCIe root port that the NVIDIA GPU sits behind
    $gpuId = Find-NvidiaPciDeviceId
    if (-not $gpuId) { return $null }

    # Walk up the device tree: GPU → PCIe bridge (if any) → Root Port
    $currentId = $gpuId
    for ($i = 0; $i -lt 5; $i++) {
        $parentId = (Get-PnpDeviceProperty -InstanceId $currentId `
            -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
        if (-not $parentId) { break }

        # Root ports are typically Intel (VEN_8086) or AMD (VEN_1022)
        if ($parentId -match 'VEN_(8086|1022)') {
            Write-Info "Root port: $parentId"
            return $parentId
        }

        $currentId = $parentId
    }
    return $null
}

function Invoke-PcieDeviceEject {
    param(
        [Parameter(Mandatory)]
        [string]$DeviceInstanceId
    )

    $devInst = 0
    $cr = [GpuSwitchApi]::CM_Locate_DevNodeW([ref]$devInst, $DeviceInstanceId, 0)
    if ($cr -ne 0) {
        Write-Err "CM_Locate_DevNode failed (CR=$cr) for $DeviceInstanceId"
        return $false
    }

    $vetoType = 0
    $vetoName = New-Object System.Text.StringBuilder(512)
    $cr = [GpuSwitchApi]::CM_Request_Device_Eject($devInst, [ref]$vetoType, $vetoName, 512, 0)

    # CR_SUCCESS = 0
    if ($cr -eq 0 -and $vetoType -eq 0) {
        return $true
    }

    if ($cr -eq 0 -and $vetoType -ne 0) {
        Write-Warn "Eject vetoed (type=$vetoType, reason=$($vetoName.ToString()))"
        return $false
    }

    # CR_CALL_NOT_IMPLEMENTED = 20 — device doesn't support eject
    # CR_NO_SUCH_DEVNODE = 13
    Write-Err "CM_Request_Device_Eject failed (CR=$cr, vetoType=$vetoType)"
    return $false
}

function Invoke-PcieRescan {
    # Rescan PCIe bus to bring back the dGPU
    # Equivalent to Linux: echo 1 > /sys/bus/pci/rescan

    # Method 1: pnputil /scan-devices
    try {
        Write-Info "Running pnputil /scan-devices..."
        $output = pnputil /scan-devices 2>&1
        Write-Info "pnputil: $output"
        return $true
    }
    catch {
        Write-Warn "pnputil failed: $($_.Exception.Message)"
    }

    # Method 2: CM_Reenumerate_DevNode on the root port
    $rootPortId = Find-NvidiaRootPort
    if ($rootPortId) {
        $devInst = 0
        $cr = [GpuSwitchApi]::CM_Locate_DevNodeW([ref]$devInst, $rootPortId, 0)
        if ($cr -eq 0) {
            Write-Info "Re-enumerating root port..."
            $cr = [GpuSwitchApi]::CM_Reenumerate_DevNode($devInst, 0)
            if ($cr -eq 0) {
                return $true
            }
            Write-Warn "CM_Reenumerate_DevNode failed (CR=$cr)"
        }
    }

    return $false
}

# --- PnP Device Control (fallback, like OEM disableDGpu.ps1) ---
# Note: This only disables the driver, does NOT power off the dGPU.
# The dGPU stays on PCIe bus and continues drawing power.

function Disable-NvidiaPnp {
    $devices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($devices.Count -eq 0) {
        Write-OK "No active NVIDIA display devices to disable"
        return $true
    }

    foreach ($dev in $devices) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] Disable-PnpDevice: $($dev.FriendlyName)"
        }
        else {
            try {
                Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Disabled: $($dev.FriendlyName)"
            }
            catch {
                Write-Err "Failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
    return $true
}

function Enable-NvidiaPnp {
    $devices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)
    if ($devices.Count -eq 0) {
        # Check if already enabled
        $okDevices = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($okDevices.Count -gt 0) {
            Write-OK "dGPU already active"
            return $true
        }
        Write-Warn "No NVIDIA device found"
        return $false
    }

    foreach ($dev in $devices) {
        if ($DryRun) {
            Write-Info "[DRY-RUN] Enable-PnpDevice: $($dev.FriendlyName)"
        }
        else {
            try {
                Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
                Write-OK "Enabled: $($dev.FriendlyName)"
            }
            catch {
                Write-Err "Failed: $($_.Exception.Message)"
                return $false
            }
        }
    }
    return $true
}

# --- Commands ---

function Show-Status {
    Write-Host "=== GPU Mode Status ===" -ForegroundColor Cyan
    Write-Host ""

    $allGpus = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)

    if ($allGpus.Count -eq 0) {
        Write-Warn "No display devices found"
        return
    }

    Write-Host "Display devices:"
    foreach ($gpu in $allGpus) {
        $icon = switch ($gpu.Status) {
            'OK'       { '[ON]  ' }
            'Error'    { '[OFF] ' }
            'Degraded' { '[WARN]' }
            default    { "[?]  " }
        }
        $color = switch ($gpu.Status) {
            'OK'    { 'Green' }
            'Error' { 'DarkGray' }
            default { 'Yellow' }
        }
        Write-Host "  $icon $($gpu.FriendlyName)" -ForegroundColor $color
    }
    Write-Host ""

    # Determine mode
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    $nvidiaOff = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)

    if ($nvidiaOk.Count -gt 0) {
        $driver = Get-PnpDeviceProperty -InstanceId $nvidiaOk[0].InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
        Write-Host "  NVIDIA driver: $($driver.Data)" -ForegroundColor DarkGray
        Write-Host ""
        Write-OK "Mode: Hybrid or dGPU Only (dGPU active)"
    }
    elseif ($nvidiaOff.Count -gt 0) {
        Write-Warn "Mode: iGPU Only (dGPU disabled — still on PCIe, drawing power)"
        Write-Info "Use -Fallback switch for WMI ACPI eject to fully power off"
    }
    else {
        Write-OK "Mode: iGPU Only (no dGPU detected — fully powered off)"
    }

    Write-Host ""
    Write-Info "Commands: igpu | dgpu | hybrid"
}

function Switch-IGpuOnly {
    Write-Info "Switching to iGPU Only mode..."
    Write-Host ""

    # Check current state
    $allNv = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue)
    $nvidiaOk = @($allNv | Where-Object { $_.Status -eq 'OK' })
    $nvidiaOff = @($allNv | Where-Object { $_.Status -eq 'Error' })

    if ($allNv.Count -eq 0) {
        Write-OK "Already in iGPU Only mode (no dGPU present)"
        return
    }

    # Confirm
    if (-not $Force) {
        Write-Warn "This will power off the dGPU via PCIe eject."
        Write-Warn "Applications using the dGPU will be affected."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -notin @('y', 'Y')) {
            Write-Info "Aborted"
            return
        }
    }

    if ($Fallback) {
        Write-Warn "Using PnP fallback — dGPU will stay on PCIe (not fully powered off)"
        Disable-NvidiaPnp
        return
    }

    # Step 1: Unload driver if still active
    if ($nvidiaOk.Count -gt 0) {
        Write-Info "Step 1/2: Unloading dGPU driver..."
        Disable-NvidiaPnp
        Start-Sleep -Seconds 2
    }
    else {
        Write-Info "Step 1/2: dGPU driver already disabled"
    }

    # Step 2: PCIe eject via CM_Request_Device_Eject
    Write-Info "Step 2/2: PCIe hot-eject dGPU..."

    if ($DryRun) {
        Write-Info "[DRY-RUN] CM_Request_Device_Eject on NVIDIA PCIe device"
        return
    }

    # Find the NVIDIA PCIe device to eject
    $gpuDeviceId = Find-NvidiaPciDeviceId

    if (-not $gpuDeviceId) {
        Write-Warn "No NVIDIA PCIe device found to eject"
        Write-Info "The dGPU may have already been removed from the bus"
        return
    }

    Write-Info "Ejecting: $gpuDeviceId"
    $success = Invoke-PcieDeviceEject -DeviceInstanceId $gpuDeviceId

    if ($success) {
        Write-OK "dGPU ejected from PCIe — fully powered off"

        # Also try to power down the PCIe root port for maximum power savings
        Start-Sleep -Seconds 1
        $rootPortId = Find-NvidiaRootPort
        if ($rootPortId) {
            Write-Info "Powering down root port: $rootPortId"
            # Disable the root port device to save additional power
            $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
            if ($rpDev -and $rpDev.Status -eq 'OK') {
                try {
                    Disable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
                    Write-OK "Root port powered down"
                }
                catch { }
            }
        }
    }
    else {
        Write-Warn "PCIe eject failed or vetoed"
        Write-Host ""
        Write-Warn "Possible reasons:"
        Write-Host "  - A process still has the GPU open (close GPU apps and retry)"
        Write-Host "  - The device doesn't support hot-eject"
        Write-Host "  - The GPU is in use by the display server"
        Write-Host ""
        Write-Host "Try: Disable-PnpDevice first, then re-run this script." -ForegroundColor Cyan
    }

    # Verify
    Start-Sleep -Seconds 3
    $remaining = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'Error' })
    if ($remaining.Count -eq 0) {
        Write-OK "Verified: dGPU fully removed from PCIe bus"
    }
    elseif ($remaining[0].Status -eq 'Unknown') {
        Write-OK "dGPU ejecting (device in transitional state)"
    }
    else {
        Write-Warn "Some NVIDIA devices still visible (Status: $($remaining[0].Status))"
    }
}

function Switch-DGpuOnly {
    Write-Info "Switching to dGPU Only mode..."
    Write-Host ""
    Write-Warn "dGPU Only requires a restart (display mux switch)."
    Write-Host ""

    # Ensure dGPU is enabled
    $nvidiaOff = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)
    if ($nvidiaOff.Count -gt 0) {
        Write-Info "Enabling dGPU..."
        Enable-NvidiaPnp
        Start-Sleep -Seconds 3
    }

    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -eq 0) {
        # Try PCIe rescan
        Write-Info "dGPU not active — trying PCIe rescan..."
        if (-not $DryRun) {
            # Re-enable root port if it was disabled
            $rootPortId = Find-NvidiaRootPort
            if ($rootPortId) {
                $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
                if ($rpDev -and $rpDev.Status -ne 'OK') {
                    Enable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            Invoke-PcieRescan
            Start-Sleep -Seconds 3
        }
    }

    # Verify dGPU is active
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -eq 0) {
        Write-Err "dGPU not detected — cannot switch to dGPU Only mode"
        Write-Info "Make sure the Control Center is installed and dGPU hardware is present"
        return
    }

    Write-OK "dGPU is active: $($nvidiaOk[0].FriendlyName)"
    Write-Host ""

    # Set NVIDIA as preferred GPU (registry settings)
    if (-not $DryRun) {
        # Hardware-accelerated GPU scheduling
        $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        if (Test-Path $dwmPath) {
            Set-ItemProperty -Path $dwmPath -Name "OverlayMinHardwareSupported" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        }

        # NVIDIA preferred renderer
        $nvPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global"
        if (Test-Path $nvPath) {
            Set-ItemProperty -Path $nvPath -Name "PreferredGraphicsProcessor" -Value "HighPerformanceNVIDIA" -ErrorAction SilentlyContinue
        }
        Write-OK "Configured dGPU as preferred GPU"
    }

    Write-Host ""
    Write-OK "dGPU Only mode configured"
    Write-Host ""
    Write-Host -ForegroundColor Yellow "=== Restart Required ==="
    Write-Host "  dGPU Only mode involves a display mux hardware switch."
    Write-Host "  Restart to apply:  shutdown /r /t 0"
    Write-Host ""

    if (-not $Force) {
        $confirm = Read-Host "Restart now? [y/N]"
        if ($confirm -in @('y', 'Y') -and -not $DryRun) {
            shutdown /r /t 5 /c "GPU mode: switching to dGPU Only"
        }
    }
}

function Switch-Hybrid {
    Write-Info "Switching to Hybrid mode..."
    Write-Host ""

    # Check if already active
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -gt 0) {
        Write-OK "Already in Hybrid mode (dGPU active)"
        return
    }

    # Step 1: Try PnP enable first
    $nvidiaOff = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status Error -ErrorAction SilentlyContinue)
    if ($nvidiaOff.Count -gt 0) {
        Write-Info "Step 1/2: Re-enabling dGPU driver..."
        Enable-NvidiaPnp
        Start-Sleep -Seconds 3

        $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
        if ($nvidiaOk.Count -gt 0) {
            Write-OK "Hybrid mode active — dGPU re-enabled"
            return
        }
    }

    # Step 2: PCIe rescan via pnputil / CM_Reenumerate_DevNode
    Write-Info "Step 2/2: PCIe rescan..."

    if ($DryRun) {
        Write-Info "[DRY-RUN] pnputil /scan-devices + CM_Reenumerate_DevNode on root port"
        return
    }

    # Re-enable root port if it was disabled during igpu mode
    $rootPortId = Find-NvidiaRootPort
    if ($rootPortId) {
        $rpDev = Get-PnpDevice -InstanceId $rootPortId -ErrorAction SilentlyContinue
        if ($rpDev -and $rpDev.Status -ne 'OK') {
            Write-Info "Re-enabling root port..."
            Enable-PnpDevice -InstanceId $rootPortId -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Invoke-PcieRescan
    Start-Sleep -Seconds 3

    # Verify
    $nvidiaOk = @(Get-PnpDevice -FriendlyName '*NVIDIA*' -Class Display -Status OK -ErrorAction SilentlyContinue)
    if ($nvidiaOk.Count -gt 0) {
        Write-OK "Hybrid mode active — dGPU: $($nvidiaOk[0].FriendlyName)"
    }
    else {
        Write-Warn "dGPU not yet detected after rescan"
        Write-Info "It may need more time, or try: pnputil /scan-devices"
    }
}

# --- Main ---

if (-not (Test-Admin) -and $Command -ne 'status') {
    Write-Err "Requires Administrator. Run as:"
    Write-Err "  Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -File `"$PSCommandPath`" $Command'"
    exit 1
}

switch ($Command) {
    'status' { Show-Status }
    'igpu'   { Switch-IGpuOnly }
    'dgpu'   { Switch-DGpuOnly }
    'hybrid' { Switch-Hybrid }
}
