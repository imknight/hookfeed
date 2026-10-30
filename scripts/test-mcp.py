#!/usr/bin/env python3
"""Real stdio JSON-RPC client round trip against HookFeed's official Swift SDK server.

No model, credentials, SDK installation, or user configuration required.
Build: swift build --scratch-path .build-cli --product hookfeed
Run:   python3 scripts/test-mcp.py [--binary /absolute/path/to/hookfeed]
"""
import argparse
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BINARY = next((ROOT / p for p in (".build-cli/debug/hookfeed", ".build-cli/out/Products/Debug/hookfeed", ".build/debug/hookfeed", ".build/out/Products/Debug/hookfeed") if (ROOT / p).is_file()), ROOT / ".build-cli/debug/hookfeed")


class StdioClient:
    def __init__(self, binary, environment, *server_arguments):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen([binary, "mcp", *server_arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, env=environment)
        self.lines = queue.Queue()
        self.counter = 0
        self.notifications = []
        def read():
            for line in self.process.stdout:
                self.lines.put(line)
            self.lines.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def write(self, message):
        self.process.stdin.write(json.dumps(message, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, parameters=None):
        self.counter += 1
        identifier = self.counter
        self.write({"jsonrpc": "2.0", "id": identifier, "method": method, "params": parameters or {}})
        while True:
            line = self.lines.get(timeout=8)
            assert line is not None, "Server exited before a response"
            response = json.loads(line)  # Any stdout diagnostic corrupts the test.
            assert response["jsonrpc"] == "2.0", response
            if "id" not in response:
                self.notifications.append(response)
                continue
            assert response["id"] == identifier, response
            return response

    def initialize(self):
        response = self.request("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "hookfeed-jsonrpc-test", "version": "1.0.0"}, "capabilities": {}})
        assert "error" not in response, response
        assert response["result"]["serverInfo"]["name"] == "hookfeed"
        assert "tools" in response["result"]["capabilities"]
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return response

    def call(self, arguments, name="send_message"):
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        assert "error" not in response, response
        return response["result"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        assert self.process.returncode == 0, self.process.returncode
        while True:
            try:
                line = self.lines.get_nowait()
            except queue.Empty:
                break
            if line is not None:
                response = json.loads(line)
                assert response["jsonrpc"] == "2.0" and "id" not in response, response
        self.errors.seek(0)
        diagnostics = self.errors.read()
        self.errors.close()
        return diagnostics

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        if kind:
            self.process.kill()
            self.process.wait(timeout=3)
            self.errors.seek(0)
            print(self.errors.read().decode(errors="replace"))
            self.errors.close()
        else:
            self.close()


def receipt(result):
    assert result.get("isError") is False, result
    value = json.loads(result["content"][0]["text"])
    assert value == result["structuredContent"], result
    assert value["status"] == "stored" and isinstance(value["duplicate"], bool)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=os.environ.get("HOOKFEED_CLI", str(DEFAULT_BINARY)))
    binary = str(Path(parser.parse_args().binary).resolve())
    assert Path(binary).is_file(), f"Build hookfeed first: {binary}"
    with tempfile.TemporaryDirectory(prefix="hookfeed-mcp-") as temporary:
        directory = Path(temporary)
        environment = {key: value for key, value in os.environ.items() if key not in {"HOOKFEED_URL", "HOOKFEED_TOKEN", "HOOKFEED_BOT"}} | {"HOME": temporary, "CFFIXED_USER_HOME": temporary, "HOOKFEED_STORE_PATH": str(directory / "inbox.sqlite")}
        arguments = {"title": "MCP review 🦉", "body": 'Multiline\n"quoted"; $(literal)', "project": "MailScope", "bot": "Charname", "kind": "needs_attention", "url": "https://example.com/review", "workdir": "/tmp/synthetic-project", "session_id": "synthetic-mcp-session", "thread_key": "mcp:synthetic-session", "idempotency_key": "synthetic-message-1"}
        with StdioClient(binary, environment | {"HOOKFEED_BOT": "EnvBot"}) as client:
            initialized = client.initialize()
            assert "--read-all" not in initialized["result"].get("instructions", "")
            discovery = client.request("tools/list")["result"]
            assert [tool["name"] for tool in discovery["tools"]] == ["send_message"]
            schema = discovery["tools"][0]["inputSchema"]
            assert schema["required"] == ["title"] and schema["properties"]["source"]["default"] == "mcp"
            assert schema["properties"]["bot"]["maxLength"] == 80
            assert set(schema["properties"]["kind"]["enum"]) == {"info", "completed", "failed", "needs_attention"}
            denied = client.call({}, name="list_messages")
            assert denied.get("isError") is True
            assert "start hookfeed mcp with --read-all to allow reading" in denied["content"][0]["text"]
            original = receipt(client.call(arguments))
            duplicate = receipt(client.call(arguments))
            assert original["duplicate"] is False and duplicate["duplicate"] is True and original["id"] == duplicate["id"]
            assert receipt(client.call({"title": "Minimal message"}))["duplicate"] is False
            invalids = [{"title": "x", "bot": 3}, {"title": "x", "bot": "x" * 81}, arguments | {"bot": "Other"}, {}, {"title": " "}, {"title": "x" * 201}, {"title": 3}, {"title": "x", "body": "🦉" * 9000}, {"title": "x", "kind": "unknown"}, {"title": "x", "source": None}, {"title": "x", "body": ["not text"]}, {"title": "x", "url": "file:///tmp/x"}, {"title": "x", "workdir": "relative"}, {"title": "x", "unknown": "argument"}, arguments | {"title": "Conflicting reuse"}]
            for invalid in invalids:
                result = client.call(invalid)
                assert result.get("isError") is True and "structuredContent" not in result, result
                assert result["content"][0]["text"].startswith("Message was not stored:")
            unknown = client.request("tools/call", {"name": "not_a_tool", "arguments": {}})
            assert "error" in unknown
            assert "result" in client.request("ping")
        # Reconnect with a new server process and retry against the same durable DB.
        with StdioClient(binary, environment) as client:
            client.initialize()
            assert client.request("tools/list")["result"]["tools"][0]["name"] == "send_message"
            reconnected = receipt(client.call(arguments))
            assert reconnected["id"] == original["id"] and reconnected["duplicate"] is True
        persisted = subprocess.run([binary, "list", "--json"], env=environment, check=True, capture_output=True)
        messages = json.loads(persisted.stdout)
        assert len(messages) == 2
        full = next(message for message in messages if message["id"] == original["id"])
        assert all(full[key] == value for key, value in arguments.items())
        assert next(message for message in messages if message["title"] == "Minimal message")["bot"] == "EnvBot"
        assert full["source"] == "mcp" and full.get("read_at") is None
        with StdioClient(binary, environment, "--read-all") as client:
            initialized = client.initialize()
            assert "--read-all" in initialized["result"]["instructions"]
            assert "every project" in initialized["result"]["instructions"]
            tools = client.request("tools/list")["result"]["tools"]
            assert [tool["name"] for tool in tools] == ["send_message", "list_messages"]
            reader = tools[1]
            assert reader["annotations"]["readOnlyHint"] is True
            properties = reader["inputSchema"]["properties"]
            assert set(properties) == {"project", "source", "bot", "unread_only", "search", "limit"}
            assert properties["limit"]["minimum"] == 1 and properties["limit"]["maximum"] == 100
            assert properties["limit"]["default"] == 20
            other = receipt(client.call({"title": "Other project", "project": "Other", "bot": "Charname"}))
            receipt(client.call({"title": "Other bot", "project": "MailScope", "bot": "Other"}))
            cafe = receipt(client.call({"title": "Café", "project": "Query", "bot": "QueryBot"}))
            receipt(client.call({"title": "Latest unrelated"}))

            def read(filters):
                result = client.call(filters, name="list_messages")
                assert result.get("isError") is False, result
                payload = json.loads(result["content"][0]["text"])
                assert payload == result["structuredContent"] and set(payload) == {"messages"}
                return payload["messages"]

            for filters, expected in [({"project": "MailScope", "bot": "Charname"}, original["id"]),
                                      ({"project": "Other"}, other["id"]),
                                      ({"source": "mcp", "search": "REVIEW"}, original["id"]),
                                      ({"search": "cafe", "limit": 1}, cafe["id"])]:
                found = read(filters)
                assert [message["id"] for message in found] == [expected]
                assert found[0].get("read_at") is None and found[0]["received_at"].endswith("Z")
            assert read({"project": "' OR 1=1 --"}) == []
            with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as database:
                database.execute("UPDATE messages SET read_at = 123 WHERE id = ?", (original["id"],))
                before = database.execute("SELECT * FROM messages ORDER BY seq").fetchall()
            assert read({"project": "MailScope", "bot": "Charname", "unread_only": True}) == []
            assert read({"project": "MailScope", "bot": "Charname", "unread_only": False})[0]["read_at"].endswith("Z")
            assert all(message.get("read_at") is None for message in read({"unread_only": True}))
            for invalid in [{"limit": 0}, {"limit": 101}, {"limit": 1.5}, {"limit": True}, {"limit": "2"},
                            {"unread_only": 1}, {"project": None}, {"source": 3}, {"bot": []}, {"search": None},
                            {"mark_read": True}, {"workdir_prefix": "/tmp"}]:
                assert client.call(invalid, name="list_messages").get("isError") is True, invalid
            with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as database:
                assert database.execute("SELECT * FROM messages ORDER BY seq").fetchall() == before
            assert "result" in client.request("ping")
        blocked = directory / "blocked"
        blocked.write_text("not a directory")
        with StdioClient(binary, environment | {"HOOKFEED_STORE_PATH": str(blocked / "inbox.sqlite")}) as client:
            client.initialize()
            failed = client.call({"title": "Storage unavailable"})
            assert failed.get("isError") is True and "structuredContent" not in failed
            assert client.request("tools/list")["result"]["tools"]
        with StdioClient(binary, environment | {"HOOKFEED_STORE_PATH": str(blocked / "inbox.sqlite")}, "--read-all") as client:
            client.initialize()
            assert client.call({}, name="list_messages").get("isError") is True
            assert "result" in client.request("ping")
    print("MCP stdio JSON-RPC round trip passed: initialize, discovery, send, invalid input, duplicate/conflict, reconnect, persistence, storage failure, opt-in read-only queries, clean stdout.")


if __name__ == "__main__":
    main()
