#!/usr/bin/env python3
"""Run the submodule's sensing WebSocket server with SimulatedCollector forced.

Why this wrapper exists: on macOS, ws_server._create_collector() picks
MacosWifiCollector, whose .start() shells out to `swiftc` and is called
unguarded -- so it crashes rather than falling back to simulation. There is no
env var or CLI flag to force the simulated source.

_create_collector() calls platform.system() at runtime and falls through to
SimulatedCollector(seed=42, sample_rate_hz=10.0) for any value that isn't
Windows/Linux/Darwin, so stubbing that one call is enough.

This lives in the PARENT repo so external/wifi-csi-pose stays byte-identical
to its pinned upstream commit.
"""
import os
import platform
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUB = os.path.join(REPO_ROOT, "external", "wifi-csi-pose")

# ws_server.py and the modules it pulls in use absolute `v1.src.…` imports,
# so the submodule root is the correct sys.path anchor.
sys.path.insert(0, SUB)

platform.system = lambda: "SimulatedForce"

from v1.src.sensing.ws_server import main  # noqa: E402

if __name__ == "__main__":
    print("forcing SimulatedCollector (platform.system stubbed)", flush=True)
    main()
