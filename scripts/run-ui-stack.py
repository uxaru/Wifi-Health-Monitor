#!/usr/bin/env python3
"""Serve the whole wifi-csi-pose UI stack from ONE origin (http://localhost:8000).

Why this exists
---------------
ui/config/api.config.js derives BASE_URL from window.location.origin, and
ui/services/sensing.service.js derives its socket as `${origin}/ws/sensing`.
So the UI only works when the static files, the REST API, and the sensing
socket are all on the SAME host:port. Serving ui/ from `python -m http.server`
guarantees failure: every /api/v1/... request and every WebSocket upgrade goes
to a static file server that cannot answer them.

This wrapper composes one app on :8000:

  * the submodule's real FastAPI app  -> /api/v1/*, /health/*, /docs
  * /ws/sensing                       -> relayed from the sensing server on :8765
  * everything else                   -> the static ui/ directory

The static mount is added LAST so the API routes registered above it win;
Starlette matches routes in registration order and a Mount at "/" matches
everything.

Lives in the PARENT repo so external/wifi-csi-pose stays byte-identical to its
pinned upstream commit.
"""
import asyncio
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUB = os.path.join(REPO_ROOT, "external", "wifi-csi-pose")
V1 = os.path.join(SUB, "v1")
UI = os.path.join(SUB, "ui")

# The API modules import as `src.…`, so v1/ is the sys.path anchor.
sys.path.insert(0, V1)

# Must be set before src.config.settings is imported: SECRET_KEY has no default
# and mock mode is the only mode that yields data without CSI hardware.
os.environ.setdefault("MOCK_HARDWARE", "true")
os.environ.setdefault("MOCK_POSE_DATA", "true")
os.environ.setdefault("SECRET_KEY", "dev-local-testing-key")
os.environ.setdefault("ENABLE_AUTHENTICATION", "false")
os.environ.setdefault("ENABLE_RATE_LIMITING", "false")
os.environ.setdefault("ENVIRONMENT", "development")

import uvicorn  # noqa: E402
import websockets  # noqa: E402
from fastapi import WebSocket, WebSocketDisconnect  # noqa: E402
from starlette.staticfiles import StaticFiles  # noqa: E402

from src.api.main import app  # noqa: E402

SENSING_UPSTREAM = os.environ.get("SENSING_UPSTREAM", "ws://127.0.0.1:8765")


@app.websocket("/ws/sensing")
async def sensing_relay(client: WebSocket):
    """Relay frames from the sensing server so the UI sees them same-origin.

    Proxying rather than re-implementing keeps the real pipeline
    (SimulatedCollector -> RssiFeatureExtractor -> PresenceClassifier) as the
    single source of the data.
    """
    await client.accept()
    try:
        async with websockets.connect(SENSING_UPSTREAM) as upstream:
            while True:
                await client.send_text(await upstream.recv())
    except WebSocketDisconnect:
        pass
    except Exception as exc:  # upstream down / refused
        try:
            await client.close(code=1011, reason=f"sensing upstream: {exc}"[:120])
        except Exception:
            pass


# Registered last: a Mount at "/" matches everything, so it must not shadow the
# API routes above.
app.mount("/", StaticFiles(directory=UI, html=True), name="ui")


if __name__ == "__main__":
    print(f"ui      : {UI}")
    print(f"sensing : relaying {SENSING_UPSTREAM} at /ws/sensing")
    print("open    : http://localhost:8000/", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
