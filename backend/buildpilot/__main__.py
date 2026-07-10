"""Run the Build Pilot backend:

    python -m buildpilot [--port 8787] [--host 0.0.0.0]

Advertises the server on the local network via Bonjour (`_buildpilot._tcp`)
using macOS's built-in `dns-sd`, so the iPhone app finds the Mac
automatically — nobody types an IP address. No extra dependencies.
"""

from __future__ import annotations

import argparse
import shutil
import socket
import subprocess

import uvicorn


def advertise(port: int) -> subprocess.Popen | None:
    if shutil.which("dns-sd") is None:  # non-macOS dev machine: skip quietly
        return None
    hostname = socket.gethostname().removesuffix(".local")
    return subprocess.Popen(
        ["dns-sd", "-R", f"Build Pilot on {hostname}", "_buildpilot._tcp", "local", str(port)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Pilot local backend")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    bonjour = advertise(args.port)
    print(f"Build Pilot backend on http://{args.host}:{args.port}  (console: http://localhost:{args.port}/)")
    if bonjour:
        print("Advertising on the local network — the iPhone app will find this Mac automatically.")
    try:
        uvicorn.run("buildpilot.server:app", host=args.host, port=args.port, log_level="info")
    finally:
        if bonjour:
            bonjour.terminate()


if __name__ == "__main__":
    main()
