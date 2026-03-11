#!/usr/bin/env python3
"""
Stub jadx LSP server.

Speaks LSP over stdio so the Neovim plugin can be exercised end-to-end
before the real Java server exists.  All responses are hardcoded.

Logs go to /tmp/jadx-stub.log so stdout stays clean for the protocol.

Run manually to sanity-check JSON-RPC framing:
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
        python3 stub/server.py
"""

import json
import sys
import os

# ─── Logging ────────────────────────────────────────────────────────────────

_log = open("/tmp/jadx-stub.log", "w", buffering=1)

def log(msg):
    _log.write(msg + "\n")


# ─── JSON-RPC framing ────────────────────────────────────────────────────────

def read_message():
    """Read one LSP message from stdin.  Returns parsed dict, or None on EOF."""
    headers = {}
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.rstrip("\r\n")
        if line == "":
            break
        key, _, value = line.partition(": ")
        headers[key] = value

    length = int(headers.get("Content-Length", 0))
    body   = sys.stdin.read(length)
    log(f"<-- {body}")
    return json.loads(body)


def send_message(obj):
    body = json.dumps(obj, separators=(",", ":"))
    log(f"--> {body}")
    header = f"Content-Length: {len(body)}\r\n\r\n"
    sys.stdout.write(header + body)
    sys.stdout.flush()


def send_response(req_id, result):
    send_message({"jsonrpc": "2.0", "id": req_id, "result": result})


def send_error(req_id, code, message):
    send_message({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": code, "message": message}})


# ─── Stub data ───────────────────────────────────────────────────────────────

STUB_CLASSES = {
    "com.example.MainActivity": """\
package com.example;

import android.app.Activity;
import android.os.Bundle;

/* jadx-stub: com.example.MainActivity */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(0x7f040019);
        String msg = getGreeting();
    }

    private String getGreeting() {
        return "Hello, World!";
    }
}
""",
    "com.example.Helper": """\
package com.example;

/* jadx-stub: com.example.Helper */
public class Helper {

    public static int add(int a, int b) {
        return a + b;
    }
}
""",
}

FALLBACK_SOURCE = """\
package com.example;

/* jadx-stub: class not found in stub registry */
public class Unknown {
}
"""

# Position of `getGreeting` in MainActivity (0-indexed line 12, char 19).
DEFINITION_TARGET = {
    "uri":   "jadx://com.example.MainActivity",
    "range": {
        "start": {"line": 12, "character": 19},
        "end":   {"line": 12, "character": 30},
    },
}


# ─── Request handlers ────────────────────────────────────────────────────────

def handle_initialize(req_id, params):
    file_hint = (params.get("initializationOptions") or {}).get("jadxFile")
    log(f"initialize: jadxFile={file_hint!r}")
    send_response(req_id, {
        "capabilities": {
            "textDocumentSync": 1,      # Full sync
            "hoverProvider":    True,
            "definitionProvider": True,
            "executeCommandProvider": {"commands": ["jadx.loadFile"]},
        },
        "serverInfo": {"name": "jadx-lsp-stub", "version": "0.0.1"},
    })


def handle_class_source(req_id, params):
    fqn    = (params or {}).get("fqn", "")
    source = STUB_CLASSES.get(fqn)
    if source is None:
        source = f"/* jadx-stub: no entry for '{fqn}' */\n" + FALLBACK_SOURCE
    send_response(req_id, {"source": source})


def handle_hover(req_id, params):
    doc  = (params or {}).get("textDocument", {})
    pos  = (params or {}).get("position", {})
    uri  = doc.get("uri", "")
    line = pos.get("line", 0)
    char = pos.get("character", 0)
    log(f"hover: uri={uri} line={line} char={char}")
    send_response(req_id, {
        "contents": {
            "kind":  "markdown",
            "value": (
                "**stub hover**\n\n"
                "`private String getGreeting()`\n\n"
                "Returns a greeting string.  *(jadx-lsp stub)*"
            ),
        }
    })


def handle_definition(req_id, params):
    doc  = (params or {}).get("textDocument", {})
    pos  = (params or {}).get("position", {})
    uri  = doc.get("uri", "")
    line = pos.get("line", 0)
    char = pos.get("character", 0)
    log(f"definition: uri={uri} line={line} char={char}")
    send_response(req_id, DEFINITION_TARGET)


def handle_execute_command(req_id, params):
    command = (params or {}).get("command", "")
    args    = (params or {}).get("arguments", [])
    if command == "jadx.loadFile":
        path = args[0] if args else "<none>"
        log(f"executeCommand jadx.loadFile: path={path!r} (stub: ignoring)")
    else:
        log(f"executeCommand: unknown command {command!r}")
    send_response(req_id, None)


def handle_shutdown(req_id, _params):
    send_response(req_id, None)


# ─── Dispatch ────────────────────────────────────────────────────────────────

HANDLERS = {
    "initialize":              handle_initialize,
    "jadx/classSource":        handle_class_source,
    "textDocument/hover":      handle_hover,
    "textDocument/definition": handle_definition,
    "workspace/executeCommand": handle_execute_command,
    "shutdown":                handle_shutdown,
}

SILENT_NOTIFICATIONS = {
    "initialized",
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
    "textDocument/didSave",
    "$/cancelRequest",
}


def dispatch(msg):
    method = msg.get("method")
    req_id = msg.get("id")     # None for notifications
    params = msg.get("params")

    if method == "exit":
        log("exit received, shutting down")
        sys.exit(0)

    if method in SILENT_NOTIFICATIONS:
        return  # notifications — no response expected

    handler = HANDLERS.get(method)
    if handler:
        handler(req_id, params)
    elif req_id is not None:
        # Unknown request: reply with method-not-found so the client doesn't hang.
        send_error(req_id, -32601, f"Method not found: {method}")
    else:
        log(f"ignoring unknown notification: {method}")


# ─── Main loop ───────────────────────────────────────────────────────────────

def main():
    log("jadx-lsp stub server started")
    while True:
        try:
            msg = read_message()
            if msg is None:
                log("EOF on stdin, exiting")
                break
            dispatch(msg)
        except Exception:
            import traceback
            log(traceback.format_exc())


if __name__ == "__main__":
    main()
