#!/usr/bin/env python3
"""Disposable app-server metadata fixture. Never contacts a model or real Codex."""
import json
import os
from pathlib import Path
import sys
import time

if sys.argv[1:] != ["app-server", "--stdio"] or os.getenv("CCS_TEST_CODEX_FAILURE"):
    sys.exit(1)

home = Path(os.environ["HOME"])


def thread(identifier, title, cwd, source="cli"):
    return {"id": identifier, "cwd": str(cwd), "updatedAt": int(time.time()),
            "name": title, "preview": "Review authentication and fix the tests",
            "status": {"type": "notLoaded"}, "source": source}


main = [thread("example", "Codex authentication review", "/tmp/it's a project"),
        thread("second", "Codex migration", home / "work", "vscode")]
agent = thread("child", "Hidden subagent", home / "2026-11-08-4", "subAgent")
archived = thread("archived", "Hidden archived chat", home / "2026-11-08-3")

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method, params = request["method"], request.get("params", {})
    if method == "initialize":
        result = {}
    elif method == "thread/list":
        source = [archived] if params.get("archived") else main + ([agent] if "subAgent" in params.get("sourceKinds", []) else [])
        offset = int(params.get("cursor", "0"))
        result = {"data": source[offset:offset + 1], "nextCursor": str(offset + 1) if offset + 1 < len(source) else None}
    elif method == "thread/read" and params.get("threadId") in {t["id"] for t in main}:
        result = {"thread": next(t for t in main if t["id"] == params["threadId"])}
    else:
        print(json.dumps({"id": request["id"], "error": {"code": -32601, "message": "Unknown fixture request"}}), flush=True)
        continue
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
