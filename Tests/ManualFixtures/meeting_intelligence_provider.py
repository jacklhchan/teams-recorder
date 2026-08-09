#!/usr/bin/env python3
"""Development-only loopback provider for meeting-intelligence acceptance.

It deliberately records only sanitized, count-oriented JSON Lines telemetry.
Never use this fixture as an application runtime dependency.
"""

from __future__ import annotations

import json
import tempfile
import threading
import time
from collections import Counter
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Mapping, Sequence


class SyntheticMeetingIntelligenceProvider:
    """A small OpenAI-compatible test server with privacy-safe telemetry."""

    def __init__(
        self,
        *,
        advertised_models: Sequence[str] = ("asr-model", "llm-model"),
        forced_status: Mapping[str, int] | None = None,
        response_delay_seconds: float = 0,
        chat_response: str = "Synthetic meeting summary",
    ) -> None:
        self._advertised_models = tuple(advertised_models)
        self._forced_status = dict(forced_status or {})
        self._response_delay_seconds = response_delay_seconds
        self._chat_response = chat_response
        self.request_counts: Counter[str] = Counter()
        self._temporary_directory: tempfile.TemporaryDirectory[str] | None = None
        self.telemetry_path: Path | None = None
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        if self._server is None:
            raise RuntimeError("Synthetic provider is not running.")
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}/v1"

    def __enter__(self) -> "SyntheticMeetingIntelligenceProvider":
        self.start()
        return self

    def __exit__(self, *_unused: object) -> None:
        self.close()

    def start(self) -> None:
        if self._server is not None:
            return
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="lmr-meeting-intelligence-provider-"
        )
        self.telemetry_path = Path(self._temporary_directory.name) / "events.jsonl"
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                parent._handle(self, "GET")

            def do_POST(self) -> None:  # noqa: N802
                parent._handle(self, "POST")

            def log_message(self, _format: str, *_args: object) -> None:
                return

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="meeting-intelligence-provider",
            daemon=True,
        )
        self._thread.start()

    def close(self) -> None:
        server = self._server
        thread = self._thread
        self._server = None
        self._thread = None
        if server is not None:
            server.shutdown()
            server.server_close()
        if thread is not None:
            thread.join(timeout=2)
        if self._temporary_directory is not None:
            self._temporary_directory.cleanup()
            self._temporary_directory = None

    def read_events(self) -> list[dict[str, object]]:
        if self.telemetry_path is None or not self.telemetry_path.exists():
            return []
        return [
            json.loads(line)
            for line in self.telemetry_path.read_text(encoding="utf-8").splitlines()
            if line
        ]

    def _handle(self, handler: BaseHTTPRequestHandler, method: str) -> None:
        endpoint, role = self._endpoint_for(method, handler.path)
        if endpoint is None:
            self._send(handler, HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        # Consume input only to keep the connection reusable; never parse, retain,
        # reflect, or log its content, headers, URL, or request path.
        length = int(handler.headers.get("Content-Length", "0"))
        if length > 0:
            handler.rfile.read(length)

        self.request_counts[endpoint] += 1
        if self._response_delay_seconds:
            time.sleep(self._response_delay_seconds)
        status = self._forced_status.get(endpoint, HTTPStatus.OK)
        outcome = "completed" if status == HTTPStatus.OK else "forced-status"
        self._record(endpoint, self.request_counts[endpoint], role, outcome)
        if status != HTTPStatus.OK:
            self._send(handler, status, {"error": "forced status"})
            return

        if endpoint == "models":
            self._send(
                handler,
                HTTPStatus.OK,
                {"object": "list", "data": [{"id": model} for model in self._advertised_models]},
            )
        elif endpoint == "audio-transcriptions":
            self._send(handler, HTTPStatus.OK, {"text": "Synthetic transcript"})
        else:
            self._send(
                handler,
                HTTPStatus.OK,
                {
                    "choices": [
                        {"message": {"content": self._chat_response}}
                    ]
                },
            )

    @staticmethod
    def _endpoint_for(method: str, path: str) -> tuple[str | None, str | None]:
        if method == "GET" and path == "/v1/models":
            return "models", None
        if method == "POST" and path == "/v1/audio/transcriptions":
            return "audio-transcriptions", "asr"
        if method == "POST" and path == "/v1/chat/completions":
            return "chat-completions", "llm"
        return None, None

    def _record(
        self,
        endpoint: str,
        request_count: int,
        model_role: str | None,
        outcome: str,
    ) -> None:
        if self.telemetry_path is None:
            raise RuntimeError("Synthetic provider telemetry is unavailable.")
        event: dict[str, object] = {
            "timestamp": int(time.time() * 1000),
            "endpoint": endpoint,
            "requestCount": request_count,
            "outcome": outcome,
        }
        if model_role is not None:
            event["modelRole"] = model_role
        with self.telemetry_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, separators=(",", ":")) + "\n")

    @staticmethod
    def _send(
        handler: BaseHTTPRequestHandler,
        status: int | HTTPStatus,
        payload: Mapping[str, object],
    ) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        handler.send_response(int(status))
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(encoded)))
        handler.end_headers()
        handler.wfile.write(encoded)
