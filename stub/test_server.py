#!/usr/bin/env python3
"""
Protocol tests for the jadx-lsp stub server.

Drives stub/server.py via subprocess with piped JSON-RPC messages and asserts
response shapes. Tests run without Neovim or a real JAR — they validate the
LSP framing, dispatch, and all response structures the Lua plugin depends on.
"""

import json
import subprocess
import sys
import os
import unittest

STUB = os.path.join(os.path.dirname(__file__), "server.py")


# ─── LSP transport helpers ────────────────────────────────────────────────────

def encode(obj: dict) -> bytes:
    body = json.dumps(obj, separators=(",", ":")).encode()
    header = f"Content-Length: {len(body)}\r\n\r\n".encode()
    return header + body


def decode_one(data: bytes) -> tuple[dict, bytes]:
    """Parse the first LSP message from data; return (message, remaining_bytes)."""
    header_end = data.index(b"\r\n\r\n")
    header = data[:header_end].decode()
    length = int(next(
        v for line in header.split("\r\n")
        for k, _, v in [line.partition(": ")]
        if k == "Content-Length"
    ))
    body_start = header_end + 4
    body = data[body_start : body_start + length]
    return json.loads(body), data[body_start + length :]


class StubTestCase(unittest.TestCase):
    """Each test method starts a fresh stub subprocess."""

    def _run(self, *messages: dict) -> list[dict]:
        """
        Send a sequence of requests to a fresh stub process and collect
        exactly one response per request that has an id (notifications
        produce no response).
        """
        request_ids = [m["id"] for m in messages if "id" in m]
        payload = b"".join(encode(m) for m in messages)

        proc = subprocess.run(
            [sys.executable, STUB],
            input=payload,
            capture_output=True,
            timeout=10,
        )
        # Parse all responses from stdout
        buf = proc.stdout
        responses = []
        while buf:
            msg, buf = decode_one(buf)
            responses.append(msg)
            if len(responses) == len(request_ids):
                break
        return responses

    # ─── initialize ──────────────────────────────────────────────────────────

    def test_initialize_returns_capabilities(self):
        [resp] = self._run(req(1, "initialize", {}))
        caps = resp["result"]["capabilities"]
        self.assertTrue(caps["hoverProvider"])
        self.assertTrue(caps["definitionProvider"])
        self.assertEqual(caps["textDocumentSync"], 1)

    def test_initialize_advertises_execute_command(self):
        [resp] = self._run(req(1, "initialize", {}))
        exec_cap = resp["result"]["capabilities"]["executeCommandProvider"]
        self.assertIn("jadx.loadFile", exec_cap["commands"])

    def test_initialize_server_info(self):
        [resp] = self._run(req(1, "initialize", {}))
        info = resp["result"]["serverInfo"]
        self.assertEqual(info["name"], "jadx-lsp-stub")

    def test_initialize_forwards_jadx_file(self):
        # The stub accepts jadxFile in initializationOptions without error.
        [resp] = self._run(req(1, "initialize", {
            "initializationOptions": {"jadxFile": "/some/path.apk"}
        }))
        self.assertIn("capabilities", resp["result"])

    # ─── jadx/classSource ────────────────────────────────────────────────────

    def test_class_source_known_class(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "jadx/classSource", {"fqn": "com.example.MainActivity"}),
        )
        source = resp["result"]["source"]
        self.assertIn("com.example.MainActivity", source)
        self.assertIn("class", source)

    def test_class_source_unknown_class_returns_fallback(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "jadx/classSource", {"fqn": "com.example.DoesNotExist"}),
        )
        # Must return a non-null source (fallback stub, not null)
        source = resp["result"]["source"]
        self.assertIsNotNone(source)
        self.assertIsInstance(source, str)
        self.assertGreater(len(source), 0)

    def test_class_source_second_known_class(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "jadx/classSource", {"fqn": "com.example.Helper"}),
        )
        source = resp["result"]["source"]
        self.assertIn("Helper", source)

    # ─── textDocument/hover ──────────────────────────────────────────────────

    def test_hover_returns_markdown(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "textDocument/hover", {
                "textDocument": {"uri": "jadx://com.example.MainActivity"},
                "position": {"line": 12, "character": 19},
            }),
        )
        contents = resp["result"]["contents"]
        self.assertEqual(contents["kind"], "markdown")
        self.assertIsInstance(contents["value"], str)
        self.assertGreater(len(contents["value"]), 0)

    # ─── textDocument/definition ─────────────────────────────────────────────

    def test_definition_returns_location(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "textDocument/definition", {
                "textDocument": {"uri": "jadx://com.example.MainActivity"},
                "position": {"line": 12, "character": 19},
            }),
        )
        result = resp["result"]
        self.assertIn("uri", result)
        self.assertTrue(result["uri"].startswith("jadx://"))
        self.assertIn("range", result)
        start = result["range"]["start"]
        self.assertIn("line", start)
        self.assertIn("character", start)

    # ─── workspace/executeCommand ────────────────────────────────────────────

    def test_execute_command_load_file_returns_null(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "workspace/executeCommand", {
                "command": "jadx.loadFile",
                "arguments": ["/path/to/app.apk"],
            }),
        )
        self.assertIsNone(resp["result"])
        self.assertNotIn("error", resp)

    def test_execute_command_unknown_returns_null_not_error(self):
        # The stub logs unknown commands but still responds with null result.
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "workspace/executeCommand", {
                "command": "jadx.unknownCommand",
                "arguments": [],
            }),
        )
        self.assertIsNone(resp["result"])
        self.assertNotIn("error", resp)

    # ─── shutdown ────────────────────────────────────────────────────────────

    def test_shutdown_returns_null(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "shutdown", None),
        )
        self.assertIsNone(resp["result"])
        self.assertNotIn("error", resp)

    # ─── Error handling ──────────────────────────────────────────────────────

    def test_unknown_method_returns_method_not_found(self):
        [_, resp] = self._run(
            req(1, "initialize", {}),
            req(2, "nonexistent/method", {}),
        )
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32601)

    def test_notifications_produce_no_response(self):
        # initialized is a notification (no id) — only 1 response expected
        [resp] = self._run(
            req(1, "initialize", {}),
            notif("initialized", {}),
        )
        self.assertIn("capabilities", resp["result"])

    def test_did_open_notification_produces_no_response(self):
        [resp] = self._run(
            req(1, "initialize", {}),
            notif("textDocument/didOpen", {
                "textDocument": {
                    "uri": "jadx://com.example.MainActivity",
                    "languageId": "java",
                    "version": 1,
                    "text": "",
                }
            }),
        )
        self.assertIn("capabilities", resp["result"])

    # ─── JSON-RPC framing ────────────────────────────────────────────────────

    def test_response_has_jsonrpc_version(self):
        [resp] = self._run(req(1, "initialize", {}))
        self.assertEqual(resp["jsonrpc"], "2.0")

    def test_response_id_matches_request(self):
        [resp] = self._run(req(42, "initialize", {}))
        self.assertEqual(resp["id"], 42)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def req(id: int, method: str, params) -> dict:
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}

def notif(method: str, params) -> dict:
    return {"jsonrpc": "2.0", "method": method, "params": params}


if __name__ == "__main__":
    unittest.main(verbosity=2)
