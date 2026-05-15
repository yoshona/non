#!/usr/bin/env python3
"""
GPU Mode Switching Tool for Linux (Mechrevo / Tongfang Laptops)
Ported from Windows gpu-switch.ps1

Uses ACPI IGPS method on Embedded Controller (EC0) for dGPU power control,
matching the Control Center backend. Falls back to PCI remove/rescan if
ACPI is unavailable.

ACPI call chain (from DSDT analysis):
  IGPS(0) → Notify(RP09, BusCheck) + Notify(RP09.PXSX, BusCheck) → dGPU power on
  IGPS(1) → Notify(RP09.PXSX, Eject) → dGPU power off

Called through /proc/acpi/call (acpi_call module) on Linux.

Usage:
  sudo gpu_switch.py igpu      Switch to iGPU Only (power off dGPU)
  sudo gpu_switch.py hybrid    Switch to Hybrid (power on dGPU)
  sudo gpu_switch.py status    Show current GPU mode
  sudo gpu_switch.py auto      Auto based on AC power
"""

import os
import sys
import time
import logging
import subprocess
from pathlib import Path
from typing import Optional, List

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler()],
)
log = logging.getLogger("gpu_switch")

NVIDIA_VENDOR = "0x10de"
INTEL_VENDOR = "0x8086"
AMD_VENDOR = "0x1022"

NVIDIA_MODULES = ["nvidia_drm", "nvidia_modeset", "nvidia_uvm", "nvidia"]

# ACPI IGPS paths — try PC00 first (per DSDT), fall back to PCI0
ACPI_IGPS_PATHS = [
    "\\_SB.PC00.LPCB.EC0.IGPS",
    "\\_SB.PCI0.LPCB.EC0.IGPS",
]


# ============================================================
# GPU Controller — ACPI IGPS + PCI Hotplug
# ============================================================
class GpuController:
    """Controls NVIDIA dGPU on Linux using ACPI IGPS + PCI hotplug.

    Sequence for igpu mode (matching Windows gpu-switch.ps1):
      1. Unload NVIDIA kernel modules
      2. Remove dGPU from PCI bus (kernel triggers PXP._OFF)
      3. Call ACPI IGPS(1) to complete power-off
      4. Verify dGPU is off

    Sequence for hybrid mode:
      1. Call ACPI IGPS(0) to signal dGPU power-on
      2. PCI rescan to bring dGPU back
      3. Wait for dGPU to appear
      4. Load NVIDIA driver modules
    """

    def __init__(self, pci_addr: str = "auto"):
        self._pci_addr = pci_addr
        self._root_port_addr: Optional[str] = None
        self._igps_path: Optional[str] = None
        self._has_acpi_call = Path("/proc/acpi/call").exists()
        self._detect_pci()
        self._detect_root_port()

    # ---- Detection ----

    def _detect_pci(self):
        if self._pci_addr != "auto":
            return
        self._pci_addr = self._find_nvidia_pci_addr()

    @staticmethod
    def _find_nvidia_pci_addr() -> str:
        try:
            r = subprocess.run(
                ["lspci", "-D", "-d", "10de:"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0 and r.stdout.strip():
                addr = r.stdout.strip().split("\n")[0].split()[0]
                log.info(f"Detected dGPU PCI: {addr}")
                return addr
        except FileNotFoundError:
            log.debug("lspci not found")
        except Exception as e:
            log.debug(f"PCI detection: {e}")
        return "auto"

    def _detect_root_port(self):
        """Find the PCIe root port the dGPU sits behind (via sysfs path).

        sysfs path: /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0
                                              ^root port    ^dGPU
        """
        if not self._pci_addr or self._pci_addr == "auto":
            return
        try:
            real = Path(f"/sys/bus/pci/devices/{self._pci_addr}").resolve()
            if not real.exists():
                return
            current = real.parent
            for _ in range(5):
                name = current.name
                if not name.startswith("0000:"):
                    break
                vendor_file = current / "vendor"
                if vendor_file.exists():
                    vendor = vendor_file.read_text().strip()
                    if vendor in (INTEL_VENDOR, AMD_VENDOR):
                        self._root_port_addr = name
                        log.info(f"Detected root port: {name}")
                        return
                current = current.parent
        except Exception as e:
            log.debug(f"Root port detection: {e}")

    # ---- ACPI IGPS ----

    def _acpi_eval(self, method: str, arg: int = None) -> Optional[int]:
        """Evaluate an ACPI method via /proc/acpi/call.

        Returns the integer result, or None on error.
        """
        if not self._has_acpi_call:
            return None
        call_str = method
        if arg is not None:
            call_str += f" {arg}"
        try:
            subprocess.run(
                ["sudo", "tee", "/proc/acpi/call"],
                input=call_str, capture_output=True, text=True, timeout=5,
            )
            time.sleep(0.1)
            result = Path("/proc/acpi/call").read_text().strip()
            if "Error" in result:
                log.debug(f"ACPI call error: {result}")
                return None
            if "0x" in result.lower():
                hex_part = result.lower().split("0x")[-1].split()[0]
                return int(hex_part, 16)
            if result.isdigit():
                return int(result)
        except Exception as e:
            log.debug(f"ACPI eval: {e}")
        return None

    def _call_igps(self, mode: int) -> bool:
        """Call ACPI IGPS(0) for dGPU on, IGPS(1) for dGPU off.

        Tries each ACPI path and caches the working one.
        """
        if not self._has_acpi_call:
            log.warning("/proc/acpi/call not available (load acpi_call module)")
            return False

        paths = [self._igps_path] if self._igps_path else list(ACPI_IGPS_PATHS)
        mode_name = "Bus Check (dGPU on)" if mode == 0 else "Eject (dGPU off)"
        log.info(f"Calling IGPS({mode}) — {mode_name}...")

        for path in paths:
            result = self._acpi_eval(path, mode)
            if result is None:
                continue
            self._igps_path = path
            log.info(f"IGPS returned: 0x{result:X} "
                     f"(0=on, 1=off, 0xAA=_PS3 debug)")
            if mode == 0 and result == 0:
                log.info("IGPS(0) succeeded — dGPU power-on signal sent")
            elif mode == 1 and result == 1:
                log.info("IGPS(1) succeeded — dGPU powered off")
            elif result == 0xAA:
                log.info(f"IGPS({mode}) returned 0xAA — PXP was on, _PS3 called")
            return True

        log.warning("IGPS call failed on all paths")
        return False

    # ---- NVIDIA Module Management ----

    def _get_loaded_nvidia_modules(self) -> List[str]:
        return [m for m in NVIDIA_MODULES if Path(f"/sys/module/{m}").exists()]

    def _unload_nvidia_modules(self) -> bool:
        loaded = self._get_loaded_nvidia_modules()
        if not loaded:
            return True
        log.info(f"Unloading NVIDIA modules: {', '.join(loaded)}")
        for mod in NVIDIA_MODULES:
            if mod not in loaded:
                continue
            r = subprocess.run(
                ["sudo", "modprobe", "-r", mod],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode != 0:
                if "in use" in r.stderr:
                    log.error(f"Module {mod} in use — close GPU applications first")
                    return False
                log.warning(f"modprobe -r {mod}: {r.stderr.strip()}")
        return True

    def _load_nvidia_modules(self) -> bool:
        r = subprocess.run(
            ["sudo", "modprobe", "nvidia"],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode == 0:
            log.info("NVIDIA driver loaded")
            return True
        log.warning(f"modprobe nvidia: {r.stderr.strip()}")
        return False

    # ---- PCI Operations ----

    def _pci_write(self, path: Path, value: str) -> bool:
        if not path.exists():
            return False
        try:
            if os.access(path, os.W_OK):
                path.write_text(value)
            else:
                subprocess.run(
                    ["sudo", "bash", "-c", f"echo {value} > {path}"],
                    capture_output=True, timeout=10,
                )
            return True
        except Exception as e:
            log.debug(f"PCI write {path}: {e}")
            return False

    def _pci_remove_device(self, addr: str) -> bool:
        return self._pci_write(
            Path(f"/sys/bus/pci/devices/{addr}/remove"), "1"
        )

    def _pci_rescan(self) -> bool:
        return self._pci_write(Path("/sys/bus/pci/rescan"), "1")

    def _pci_set_power(self, addr: str, state: str) -> bool:
        ctrl = Path(f"/sys/bus/pci/devices/{addr}/power/control")
        return self._pci_write(ctrl, state)

    # ---- Status ----

    @property
    def is_dgpu_off(self) -> bool:
        if not self._pci_addr or self._pci_addr == "auto":
            return False
        return not Path(f"/sys/bus/pci/devices/{self._pci_addr}").exists()

    def status(self) -> dict:
        return {
            "mode": "IGPU Only" if self.is_dgpu_off else "Hybrid/dGPU",
            "pci_addr": self._pci_addr or "N/A",
            "root_port": self._root_port_addr or "N/A",
            "dgpu_removed": self.is_dgpu_off,
            "igps_path": self._igps_path or ("available" if self._has_acpi_call else "N/A"),
            "nvidia_modules": self._get_loaded_nvidia_modules(),
        }

    # ---- GPU Switching ----

    def switch_to_igpu_only(self) -> bool:
        """Power off dGPU — switch to iGPU only.

        1. Unload NVIDIA driver modules
        2. Disable root port (triggers ACPI PXP._OFF) then call IGPS(1)
        3. Remove dGPU from PCI bus
        4. Verify dGPU is off
        """
        log.info("Switching to iGPU Only...")

        if self.is_dgpu_off:
            log.info("Already in iGPU Only mode")
            return True

        # Step 1: Unload NVIDIA modules
        log.info("Step 1/3: Unloading NVIDIA driver...")
        if not self._unload_nvidia_modules():
            log.error("Cannot unload NVIDIA modules — GPU may be in use")
            return False
        time.sleep(1)

        # Step 2: Disable root port → IGPS(1)
        # On Linux, removing the root port triggers the kernel to call
        # ACPI power resource _OFF (PXP._OFF), ensuring PXP._STA==0
        # so IGPS(1) takes the correct eject branch.
        log.info("Step 2/3: Powering off dGPU via ACPI...")
        if self._root_port_addr:
            rp_path = Path(f"/sys/bus/pci/devices/{self._root_port_addr}")
            if rp_path.exists():
                log.info(f"Disabling root port {self._root_port_addr}...")
                self._pci_set_power(self._root_port_addr, "off")
                self._pci_remove_device(self._root_port_addr)
                time.sleep(2)

        self._call_igps(1)
        time.sleep(2)

        # Step 3: Remove dGPU from PCI bus
        log.info("Step 3/3: Removing dGPU from PCI bus...")
        if self._pci_addr and self._pci_addr != "auto":
            dgpu_path = Path(f"/sys/bus/pci/devices/{self._pci_addr}")
            if dgpu_path.exists():
                self._pci_remove_device(self._pci_addr)
        time.sleep(2)

        # Verify
        if self.is_dgpu_off:
            log.info("iGPU Only mode active — dGPU fully powered off")
            return True

        # Fallback methods
        log.warning("dGPU still on bus, trying fallback methods...")
        if self._bbswitch_off():
            log.info("iGPU Only mode active (via bbswitch)")
            return True
        if self._runtime_pm_auto():
            log.info("dGPU set to runtime PM auto (may power off when idle)")
            return True
        if self._nvidia_pm_off():
            log.info("NVIDIA persistence mode disabled")
            return True

        log.error("Failed to power off dGPU")
        return False

    def switch_to_hybrid(self) -> bool:
        """Power on dGPU — switch to Hybrid mode.

        1. Call ACPI IGPS(0) to signal dGPU power-on (Notify RP09 BusCheck)
        2. Power cycle root port (triggers ACPI PXP._ON)
        3. PCI rescan to enumerate dGPU
        4. Load NVIDIA driver
        """
        log.info("Switching to Hybrid mode...")

        if not self.is_dgpu_off:
            if self._get_loaded_nvidia_modules():
                log.info("Already in Hybrid mode (dGPU active with driver)")
                return True
            log.info("dGPU on bus but driver not loaded, loading...")

        # Step 1: Call IGPS(0)
        if self._has_acpi_call:
            log.info("Step 1/4: Calling IGPS(0)...")
            self._call_igps(0)
            time.sleep(2)
        else:
            log.info("Step 1/4: ACPI unavailable, skipping IGPS(0)")

        # Step 2: Root port power cycle (triggers PXP._OFF then PXP._ON)
        log.info("Step 2/4: Power cycling root port...")
        if self._root_port_addr:
            rp_path = Path(f"/sys/bus/pci/devices/{self._root_port_addr}")
            if rp_path.exists():
                # Power off
                log.info(f"Disabling root port {self._root_port_addr}...")
                self._pci_set_power(self._root_port_addr, "off")
                time.sleep(2)
            # Power on — rescan brings the root port and its children back
            log.info("Enabling root port (PCI rescan)...")
            self._pci_rescan()
            time.sleep(3)

            # If root port came back, rescan behind it
            rp_path = Path(f"/sys/bus/pci/devices/{self._root_port_addr}")
            if rp_path.exists():
                self._pci_write(rp_path / "rescan", "1")
                time.sleep(3)
        else:
            # No root port info — just rescan
            self._pci_rescan()
            time.sleep(3)

        # Step 3: Wait for dGPU to appear
        log.info("Step 3/4: Waiting for dGPU...")
        self._pci_addr = "auto"
        self._detect_pci()
        found = not self.is_dgpu_off

        if not found:
            for i in range(10):
                time.sleep(2)
                self._detect_pci()
                if not self.is_dgpu_off:
                    found = True
                    log.info(f"dGPU detected: {self._pci_addr}")
                    break
                log.info(f"  Waiting... ({i + 1}/10)")

        if not found:
            # Try bbswitch fallback
            if self._bbswitch_on():
                time.sleep(3)
                self._detect_pci()
                found = not self.is_dgpu_off

        if not found:
            log.error("dGPU not detected after rescan — try reboot")
            return False

        # Step 4: Load NVIDIA driver
        log.info("Step 4/4: Loading NVIDIA driver...")
        if not self._get_loaded_nvidia_modules():
            self._load_nvidia_modules()
            time.sleep(3)

        if self._get_loaded_nvidia_modules():
            log.info("Hybrid mode active — dGPU powered on with driver")
        else:
            log.warning("dGPU hardware present but driver not loaded")
            log.info("Try: sudo modprobe nvidia")

        return True

    # ---- Fallback Methods ----

    def _bbswitch_off(self) -> bool:
        bb = Path("/proc/acpi/bbswitch")
        if not bb.exists():
            return False
        r = subprocess.run(
            ["sudo", "tee", "/proc/acpi/bbswitch"],
            input="OFF", capture_output=True, text=True, timeout=5,
        )
        return "OFF" in (r.stdout or "")

    def _bbswitch_on(self) -> bool:
        bb = Path("/proc/acpi/bbswitch")
        if not bb.exists():
            return False
        r = subprocess.run(
            ["sudo", "tee", "/proc/acpi/bbswitch"],
            input="ON", capture_output=True, text=True, timeout=5,
        )
        return "ON" in (r.stdout or "")

    def _runtime_pm_auto(self) -> bool:
        if not self._pci_addr or self._pci_addr == "auto":
            return False
        return self._pci_set_power(self._pci_addr, "auto")

    def _nvidia_pm_off(self) -> bool:
        try:
            return subprocess.run(
                ["nvidia-smi", "-pm", "0"],
                capture_output=True, timeout=5,
            ).returncode == 0
        except FileNotFoundError:
            return False


# ============================================================
# EC Controller — Embedded Controller (ACPI/EC) Access
# ============================================================
class EcController:
    EC_CMD = 0x66
    EC_DATA = 0x62

    def __init__(self):
        self._methods = []
        try:
            if Path("/sys/kernel/debug/ec/ec0/io").exists():
                self._methods.append("ec_sys")
        except PermissionError:
            pass
        try:
            if Path("/proc/acpi/call").exists():
                self._methods.append("acpi_call")
        except PermissionError:
            pass
        try:
            if Path("/dev/port").exists():
                self._methods.append("port_io")
        except PermissionError:
            pass
        if self._methods:
            log.info(f"EC access: {', '.join(self._methods)}")
        else:
            log.info("EC access not available")

    @property
    def available(self) -> bool:
        return bool(self._methods)

    def read(self, addr: int) -> Optional[int]:
        if "ec_sys" in self._methods:
            return self._ec_sys_read(addr)
        if "acpi_call" in self._methods:
            return self._acpi_read(addr)
        if "port_io" in self._methods:
            return self._port_read(addr)
        return None

    def write(self, addr: int, value: int):
        if "ec_sys" in self._methods:
            self._ec_sys_write(addr, value)
        elif "acpi_call" in self._methods:
            self._acpi_write(addr, value)
        elif "port_io" in self._methods:
            self._port_write(addr, value)

    def _ec_sys_read(self, addr: int) -> Optional[int]:
        try:
            data = Path("/sys/kernel/debug/ec/ec0/io").read_bytes()
            return data[addr] if addr < len(data) else None
        except Exception as e:
            log.debug(f"ec_sys read: {e}")
            return None

    def _ec_sys_write(self, addr: int, value: int):
        try:
            p = Path("/sys/kernel/debug/ec/ec0/io")
            data = bytearray(p.read_bytes())
            if addr < len(data):
                data[addr] = value & 0xFF
                p.write_bytes(bytes(data))
        except Exception as e:
            log.debug(f"ec_sys write: {e}")

    def _acpi_read(self, addr: int) -> Optional[int]:
        # Try PC00 first (DSDT), fall back to PCI0
        for prefix in ["\\_SB.PC00.LPCB.EC0", "\\_SB.PCI0.LPCB.EC0"]:
            try:
                subprocess.run(
                    ["sudo", "tee", "/proc/acpi/call"],
                    input=f"{prefix}.RDEC {addr:04X}",
                    capture_output=True, text=True, timeout=5,
                )
                time.sleep(0.1)
                result = Path("/proc/acpi/call").read_text().strip()
                if "Error" not in result and "0x" in result.lower():
                    return int(result.lower().split("0x")[-1].split()[0], 16)
            except Exception:
                pass
        return None

    def _acpi_write(self, addr: int, value: int):
        for prefix in ["\\_SB.PC00.LPCB.EC0", "\\_SB.PCI0.LPCB.EC0"]:
            try:
                subprocess.run(
                    ["sudo", "tee", "/proc/acpi/call"],
                    input=f"{prefix}.WREC {addr:04X} {value:02X}",
                    capture_output=True, text=True, timeout=5,
                )
                return
            except Exception:
                pass

    def _port_read(self, addr: int) -> Optional[int]:
        try:
            with open("/dev/port", "rb") as f:
                f.seek(addr)
                return f.read(1)[0]
        except Exception:
            return None

    def _port_write(self, addr: int, value: int):
        try:
            with open("/dev/port", "wb") as f:
                f.seek(addr)
                f.write(bytes([value & 0xFF]))
        except Exception:
            pass


# ============================================================
# Power Source Detection
# ============================================================
def is_on_ac_power() -> bool:
    paths = [
        "/sys/class/power_supply/AC0/online",
        "/sys/class/power_supply/AC/online",
        "/sys/class/power_supply/ACAD/online",
    ]
    for p in paths:
        try:
            return Path(p).read_text().strip() == "1"
        except Exception:
            continue
    return True  # assume AC


# ============================================================
# CLI
# ============================================================
def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="GPU Mode Switching Tool for Linux Laptops "
                    "(Mechrevo / Tongfang)"
    )
    parser.add_argument(
        "command", nargs="?", default=None,
        choices=["igpu", "hybrid", "auto", "status",
                 "ec-read", "ec-write",
                 "on", "off"],
        help="Command: igpu=power off dGPU, hybrid=power on dGPU, "
             "auto=AC-based, status=show mode",
    )
    parser.add_argument("--pci", default="auto",
                        help="dGPU PCI address, e.g. 0000:01:00.0")
    parser.add_argument("--simulate", action="store_true",
                        help="Simulate without hardware access")
    parser.add_argument("--ec-addr", type=lambda x: int(x, 0),
                        help="EC register address (hex)")
    parser.add_argument("--ec-value", type=lambda x: int(x, 0),
                        help="EC register value to write (hex)")
    parser.add_argument("--interactive", "-i", action="store_true",
                        help="Run in interactive mode")
    args = parser.parse_args()

    gpu = GpuController(args.pci) if not args.simulate else "sim"
    ec = EcController() if not args.simulate else "sim"

    def _exec(cmd):
        # Map old commands to new
        if cmd == "on":
            log.warning("'on' is deprecated, use 'igpu'")
            cmd = "igpu"
        elif cmd == "off":
            log.warning("'off' is deprecated, use 'hybrid'")
            cmd = "hybrid"

        if cmd == "status":
            if args.simulate:
                print("mode:     IGPU Only (simulated)")
                print("dgpu_pci: auto (simulated)")
                print("ec:       False (simulated)")
            else:
                s = gpu.status()
                print(f"mode:           {s['mode']}")
                print(f"dgpu_pci:       {s['pci_addr']}")
                print(f"root_port:      {s['root_port']}")
                print(f"dgpu_off:       {s['dgpu_removed']}")
                print(f"igps_path:      {s['igps_path']}")
                print(f"nvidia_modules: {s['nvidia_modules']}")
                print(f"ec:             {ec.available}")
                print(f"ac_power:       {is_on_ac_power()}")
        elif cmd == "igpu":
            if args.simulate:
                log.info("[SIM] dGPU powered off (iGPU Only)")
            else:
                gpu.switch_to_igpu_only()
        elif cmd == "hybrid":
            if args.simulate:
                log.info("[SIM] dGPU powered on (Hybrid)")
            else:
                gpu.switch_to_hybrid()
        elif cmd == "auto":
            on_ac = is_on_ac_power() if not args.simulate else False
            if on_ac:
                _exec("hybrid")
            else:
                _exec("igpu")
        elif cmd == "ec-read":
            if args.simulate:
                print("EC read: 0x00 (simulated)")
            elif ec.available and args.ec_addr is not None:
                v = ec.read(args.ec_addr)
                print(f"EC[0x{args.ec_addr:04X}] = 0x{v:02X}"
                      if v is not None else "EC read failed")
            else:
                print("EC not available or no address specified")
        elif cmd == "ec-write":
            if args.simulate:
                log.info(f"[SIM] EC write 0x{args.ec_addr:04X} = "
                         f"0x{args.ec_value:02X}")
            elif (ec.available and args.ec_addr is not None
                  and args.ec_value is not None):
                ec.write(args.ec_addr, args.ec_value)
                log.info(f"EC write 0x{args.ec_addr:04X} = "
                         f"0x{args.ec_value:02X}")
            else:
                print("EC not available or missing addr/value")

    if args.interactive or not args.command:
        print("GPU Mode Switch Tool")
        print("  igpu   — iGPU Only (power off dGPU)")
        print("  hybrid — Hybrid (power on dGPU)")
        print("  auto   — Auto based on AC power")
        print("  status — Status")
        print("  quit   — Exit\n")
        while True:
            try:
                cmd = input("gpu> ").strip().lower()
                if cmd in ("q", "quit", "exit"):
                    break
                if cmd == "stat":
                    cmd = "status"
                _exec(cmd)
            except (KeyboardInterrupt, EOFError):
                break
    else:
        _exec(args.command)


if __name__ == "__main__":
    main()
