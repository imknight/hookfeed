#!/usr/bin/env python3
"""Build and exercise the actual debug app/helper using only loopback and disposable data.
No real inbox, config, Keychain item, Tailscale listener or clipboard is touched.
"""
import base64
import hashlib
import http.client
import json
import os
import plistlib
from pathlib import Path
import queue
import pwd
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/HookFeed.app'
ACCOUNT = 'connections'


def main():
    checks = 0
    host_preferences = Path(pwd.getpwuid(os.getuid()).pw_dir) / 'Library/Preferences/com.apple.security.plist'
    def preference_digest():
        return hashlib.sha256(host_preferences.read_bytes()).digest() if host_preferences.exists() else None
    initial_preferences = preference_digest()
    with tempfile.TemporaryDirectory(prefix='hookfeed-remote-') as home:
        service = 'app.hookfeed.test.' + str(uuid.uuid4())
        env = {k:v for k,v in os.environ.items() if not k.startswith('HOOKFEED_')}
        env.update(HOME=home, CFFIXED_USER_HOME=home, ZDOTDIR=home, HOOKFEED_STORE_PATH=home+'/server.sqlite',
                   HOOKFEED_LOG_PATH=home+'/hook.log', HOOKFEED_KEYCHAIN_SERVICE=service)
        # Always build both binaries from this checkout. Never select an old .build-cli product.
        subprocess.run(['./scripts/build-app.sh', '--debug'], cwd=ROOT, env=env, check=True)
        test_app = Path(home) / 'HookFeed.app'
        subprocess.run(['/usr/bin/ditto', str(APP), str(test_app)], check=True)
        info_path = test_app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = service + '.app'
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                        '--identifier', info['CFBundleIdentifier'], str(test_app)], check=True)
        binary = str(test_app / 'Contents/Helpers/hookfeed')
        executable = str(test_app / 'Contents/MacOS/HookFeed')
        with socket.socket() as probe:
            try:
                probe.bind(('127.0.0.1', 47321))
            except OSError:
                probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        client = env | {'HOOKFEED_STORE_PATH': home+'/client.sqlite'}
        app = None
        helper = None
        errors = tempfile.TemporaryFile()
        lines = queue.Queue()

        def launch(*args):
            nonlocal app, lines
            lines = queue.Queue()
            app = subprocess.Popen([executable, '-onboardingComplete', 'YES', '-notificationMode', 'Off', '--debug-remote-port', str(port), *args], env=env | {'HOOKFEED_BOT': 'AppEnvMustNotLeak'},
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            def read(process=app, output=lines):
                for line in process.stdout:
                    output.put(line)
                output.put(None)
            threading.Thread(target=read, daemon=True).start()

        def event(kind, timeout=10):
            deadline = time.monotonic()+timeout
            while True:
                try:
                    line = lines.get(timeout=max(0.01, deadline-time.monotonic()))
                except queue.Empty:
                    raise AssertionError(f'Debug app did not emit {kind}; debug harness missing or listener failed')
                assert line is not None, f'Debug app exited before {kind}'
                try: value = json.loads(line)
                except ValueError: continue
                if value.get('event') == 'failed': raise AssertionError('Debug startup/listener failed: '+value.get('error', 'listener unavailable'))
                if value.get('event') == kind: return value

        def control(command, expected):
            app.stdin.write((command+'\n').encode()); app.stdin.flush()
            return event(expected)

        def invoke(*args, expected=0, extra=None, stdin=None, timeout=8):
            nonlocal checks
            result = subprocess.run([binary, *args], env=client | (extra or {}), input=stdin, capture_output=True, timeout=timeout)
            assert result.returncode == expected, (args, result.returncode, result.stderr.decode(errors='replace').replace((extra or {}).get("HOOKFEED_TOKEN", "<none>"), "<redacted>"))
            checks += 1
            return result

        def rows():
            with sqlite3.connect(env['HOOKFEED_STORE_PATH']) as db:
                db.row_factory = sqlite3.Row
                return [dict(row) for row in db.execute('SELECT * FROM messages ORDER BY seq DESC')]

        def request(body=b'{"title":"Hi"}', auth=None, method='POST', path='/v1/messages'):
            nonlocal checks
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            headers = {'Content-Type': 'application/json'}
            if auth is not None: headers['Authorization'] = auth
            connection.request(method, path, body, headers)
            result = connection.getresponse()
            status, data, challenge = result.status, result.read(), result.getheader('WWW-Authenticate')
            connection.close(); checks += 1
            return status, data, challenge

        def raw(data, timeout=3):
            nonlocal checks
            with socket.create_connection(('127.0.0.1', port), timeout=timeout) as sock:
                sock.sendall(data)
                response = b''
                while True:
                    chunk = sock.recv(4096)
                    if not chunk: break
                    response += chunk
                    if b'\r\n\r\n' in response:
                        header, body = response.split(b'\r\n\r\n', 1)
                        length = int(next(line.split(b':', 1)[1] for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:')))
                        if len(body) >= length: break
                checks += 1
                return int(response.split(b' ')[1])

        def mcp(message=None, auth=None, session=None, method='POST', extra=None):
            nonlocal checks
            headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                       'MCP-Protocol-Version': '2025-03-26'}
            if auth is not None: headers['Authorization'] = auth
            if session is not None: headers['Mcp-Session-Id'] = session
            headers.update(extra or {})
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            connection.request(method, '/mcp', json.dumps(message, ensure_ascii=False).encode() if message is not None else b'', headers)
            result = connection.getresponse()
            status, response_headers, data = result.status, dict((k.lower(), v) for k, v in result.getheaders()), result.read()
            connection.close(); checks += 1
            if 'text/event-stream' in response_headers.get('content-type', ''):
                messages = [json.loads(line[5:].strip()) for line in data.decode().splitlines()
                            if line.startswith('data:') and line[5:].strip()]
                assert len(messages) == 1, 'Expected exactly one JSON-RPC SSE response'
                value = messages[0]
            else:
                value = json.loads(data) if data else None
            return status, response_headers, value

        initialize = {'jsonrpc':'2.0', 'id':1, 'method':'initialize', 'params':{
            'protocolVersion':'2025-03-26', 'capabilities':{}, 'clientInfo':{'name':'remote-test', 'version':'1'}}}
        list_tools = {'jsonrpc':'2.0', 'id':2, 'method':'tools/list', 'params':{}}

        def initialize_mcp(token):
            status, headers, result = mcp(initialize, 'Bearer '+token)
            assert status == 200 and result['result']['protocolVersion'] == '2025-03-26'
            session = headers['mcp-session-id']
            assert uuid.UUID(session)
            assert mcp({'jsonrpc':'2.0', 'method':'notifications/initialized'}, 'Bearer '+token, session)[0] == 202
            return session

        try:
            launch('--debug-remote-create', 'Test connection', '--debug-remote-start')
            created = event('created')
            token, identifier = created['token'], created['id']
            event('ready')
            duplicate = subprocess.run([binary, 'serve', '--port', str(port), '--test-keychain'], env=env,
                                       capture_output=True, timeout=8)
            assert duplicate.returncode != 0, 'CLI must not double-bind the app listener'
            checks += 1
            bound = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(app.pid), '-iTCP', '-sTCP:LISTEN'], capture_output=True, text=True, check=True).stdout
            listeners = [line for line in bound.splitlines() if '(LISTEN)' in line]
            assert len(listeners) == 1 and f'127.0.0.1:{port} (LISTEN)' in listeners[0], 'Unexpected listener binding'
            print('Verified app listener: '+listeners[0], flush=True)
            remote = {'HOOKFEED_URL': base, 'HOOKFEED_TOKEN': token}
            assert request(method='GET', path='/v1/health')[0] == 200
            for bot in ['Grokbot', 'Charname']:
                invoke('send', 'Hi', '--bot', bot, '--json', extra=remote)
            assert [row['bot'] for row in rows()] == ['Charname', 'Grokbot']
            assert request(auth='Bearer '+token)[0] == 201
            assert rows()[0]['bot'] is None and rows()[0]['source'] == 'remote'
            invoke('send', 'All fields', '--body', 'Body', '--source', 'test', '--bot', 'Bot', '--project', 'A',
                   '--kind', 'needs_attention', '--url', 'https://example.com', '--workdir', home,
                   '--session-id', 'session', '--thread', 'thread', '--key', 'key', extra=remote)
            row = rows()[0]
            assert (row['session_id'], row['thread_key'], row['idempotency_key'], row['workdir']) == ('session', 'thread', 'key', home)
            invoke('run', '--bot', 'Runner', '--', '/bin/sh', '-c', 'echo failure >&2; exit 7', extra=remote, expected=7)
            row = rows()[0]
            assert row['kind'] == 'failed' and row['origin'] is None and 'Exit code: 7' in row['body']
            payload = json.dumps({'hook_event_name':'Stop', 'session_id':'remote-hook', 'cwd':home, 'last_assistant_message':'Hook finished'}).encode()
            invoke('hook', 'claude-code', '--bot', 'HookBot', stdin=payload, extra=remote)
            assert rows()[0]['bot'] == 'HookBot'
            before = len(rows())
            for auth in [None, 'Bearer wrong']:
                status, _, challenge = request(auth=auth)
                assert status == 401 and challenge == 'Bearer'
            assert request(b'x'*65537, 'Bearer '+token)[0] == 413
            for body in [b'{', b'[]', b'{"title":"x","origin":"run"}', b'{"title":"x","bot":null}', b'{"title":"x","sender":"bad"}']:
                assert request(body, 'Bearer '+token)[0] == 400
            for headers in [b'Content-Length: 2\r\nContent-Length: 2', b'Content-Length: 2\r\nContent-Length: 3',
                            b'Content-Length: -1', b'Content-Length: +2', b'Content-Length: 999999999999999999999999',
                            b'Transfer-Encoding: chunked', b'Transfer-Encoding: identity\r\nContent-Length: 2',
                            b'Authorization: x\r\nAuthorization: y', b'Bad Header: x', b' folded: x']:
                assert raw(b'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\n'+headers+b'\r\n\r\n{}') == 400
            assert raw(b'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65537\r\n\r\n') == 413
            assert raw(b'GET /v1/health HTTP/1.1\r\nHost: localhost\r\nX-Huge: '+b'x'*16384) == 431
            assert raw(b'not HTTP\r\n\r\n') == 400
            assert raw(b'GET /v1/health HTTP/1.0\r\nHost: localhost\r\n\r\n') == 400
            assert request(method='GET', path='/v1/messages')[0] == 405
            assert len(rows()) == before
            # Web MCP uses the same isolated app, token and store as the HTTP API.
            for auth in [None, 'Bearer wrong']:
                for method in ['POST', 'GET', 'DELETE']:
                    status, headers, _ = mcp(initialize, auth, 'unknown', method,
                                              {'Origin':'https://evil.example', 'Accept':'invalid'})
                    assert status == 401 and headers.get('www-authenticate') == 'Bearer', 'MCP must authenticate before session/header validation'
            used_before = json.loads(control('inspect', 'connections')['stored'])[0]['lastUsedAt']
            mcp_session = initialize_mcp(token)
            status, headers, result = mcp(list_tools, 'Bearer '+token, mcp_session)
            assert status == 200 and headers['mcp-session-id'] == mcp_session
            tools = result['result']['tools']
            assert [tool['name'] for tool in tools] == ['send_message']
            schema = tools[0]['inputSchema']
            assert schema['additionalProperties'] is False and schema['properties']['bot']['maxLength'] == 80
            assert schema['properties']['source']['default'] == 'mcp' and 'sender' not in schema['properties']
            for name in ['list_messages', 'get_thread', 'mark', 'mark_read', 'delete', 'delete_message']:
                status, _, result = mcp({'jsonrpc':'2.0', 'id':3, 'method':'tools/call', 'params':{'name':name, 'arguments':{}}}, 'Bearer '+token, mcp_session)
                assert status == 200 and ('error' in result or result['result']['isError'])
                assert '--read-all' not in json.dumps(result) and 'messages' not in result.get('result', {}).get('structuredContent', {})
            for arguments in [{}, {'title':'x','bot':None}, {'title':'x','bot':42}, {'title':'x','bot':'x'*81},
                              {'title':'x','sender':'bad'}, {'title':'x','origin':'run'}, {'title':'x','body':'é'*20000}]:
                status, _, result = mcp({'jsonrpc':'2.0', 'id':4, 'method':'tools/call', 'params':{'name':'send_message','arguments':arguments}}, 'Bearer '+token, mcp_session)
                assert status == 200 and result['result']['isError'] is True
            for extra, expected in [({'Origin':'https://evil.example'},403), ({'Host':'evil.example'},421),
                                    ({'Accept':'application/json'},406), ({'Content-Type':'text/plain'},415),
                                    ({'MCP-Protocol-Version':'1900-01-01'},400)]:
                assert mcp(list_tools, 'Bearer '+token, mcp_session, extra=extra)[0] == expected
            assert mcp(list_tools, 'Bearer '+token, 'unknown')[0] == 404
            assert mcp(list_tools, 'Bearer '+token)[0] == 400
            assert mcp(method='GET', auth='Bearer '+token, session=mcp_session)[0] == 405
            assert json.loads(control('inspect', 'connections')['stored'])[0]['lastUsedAt'] == used_before
            assert len(rows()) == before
            for arguments in [{'title':'MCP Claude','bot':'Claude','idempotency_key':'mcp-key'}, {'title':'MCP unnamed'}]:
                status, _, result = mcp({'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'send_message','arguments':arguments}}, 'Bearer '+token, mcp_session)
                assert status == 200 and result['result']['isError'] is False
                receipt = result['result']['structuredContent']
                assert receipt['status'] == 'stored'
            assert [(row['bot'],row['source']) for row in rows()[:2]] == [(None,'mcp'),('Claude','mcp')]
            assert all(row['read_at'] is None for row in rows())
            assert json.loads(control('inspect', 'connections')['stored'])[0]['lastUsedAt'] != used_before
            # A large SDK SSE response must arrive completely, followed by graceful EOF,
            # even when the client drains it slowly with a small receive buffer.
            large_id = 'slow-' + 'x'*30000
            large_request = json.dumps({'jsonrpc':'2.0','id':large_id,'method':'tools/list'}).encode()
            with socket.create_connection(('127.0.0.1', port), timeout=5) as slow_response:
                slow_response.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                head = (f'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {token}\r\n'
                        f'Mcp-Session-Id: {mcp_session}\r\nMCP-Protocol-Version: 2025-03-26\r\n'
                        'Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n'
                        f'Content-Length: {len(large_request)}\r\n\r\n').encode()
                slow_response.sendall(head+large_request)
                chunks = []
                while True:
                    chunk = slow_response.recv(1024)
                    if not chunk: break
                    chunks.append(chunk)
                    time.sleep(0.005)
                head, data = b''.join(chunks).split(b'\r\n\r\n', 1)
                assert head.startswith(b'HTTP/1.1 200 ') and b'text/event-stream' in head
                messages = [json.loads(line[5:].strip()) for line in data.decode().splitlines()
                            if line.startswith('data:') and line[5:].strip()]
                assert data.endswith(b'\n\n') and len(messages) == 1 and messages[0]['id'] == large_id
                assert [tool['name'] for tool in messages[0]['result']['tools']] == ['send_message']
                checks += 1
            print('Verified complete large SSE response with slow reads and graceful EOF.', flush=True)
            before = len(rows())
            print('Verified MCP initialization, SSE/session headers, send-only tools, strict validation and app environment isolation.', flush=True)
            # Timeout is measured from accept, not renewed after each trickled chunk.
            with socket.create_connection(('127.0.0.1', port), timeout=12) as slow:
                start = time.monotonic()
                slow.sendall(b'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\n{')
                time.sleep(4); slow.sendall(b' ')
                response = slow.recv(4096)
                assert b' 408 ' in response and 9 <= time.monotonic()-start < 12
                checks += 1
            # Switch off cancels a previously accepted partial request too.
            with socket.create_connection(('127.0.0.1', port), timeout=2) as pending:
                pending.sendall(b'POST /v1/messages HTTP/1.1\r\n')
                deadline = time.monotonic()+2
                while int(control('status', 'status')['accepted']) == 0:
                    assert time.monotonic() < deadline, 'Partial connection was not accepted'
                    time.sleep(0.01)
                print('Verified partial request is accepted before disabling Remote.', flush=True)
                control('disable', 'disabled')
                try: assert pending.recv(1024) == b''
                except ConnectionResetError: pass
            try:
                socket.create_connection(('127.0.0.1', port), timeout=1).close()
                raise AssertionError('Disabled listener still accepts connections')
            except ConnectionRefusedError: pass
            control('enable', 'ready')
            assert mcp(list_tools, 'Bearer '+token, mcp_session)[0] == 404
            persisted = json.loads(control('inspect', 'connections')['stored'])
            assert token not in json.dumps(persisted), 'Raw token persisted in test Keychain'
            assert base64.b64decode(persisted[0]['tokenHash']) == hashlib.sha256(token.encode()).digest(), 'Stored hash mismatch'
            assert persisted[0]['lastUsedAt'] is not None
            control('quit', 'stopped'); app.wait(timeout=5); app = None
            launch(); event('disabled')
            try:
                socket.create_connection(('127.0.0.1', port), timeout=1).close()
                raise AssertionError('Isolated debug restart enabled itself')
            except ConnectionRefusedError: pass
            control('enable', 'ready')
            assert request(auth='Bearer '+token)[0] == 201
            before += 1
            mcp_session = initialize_mcp(token)
            control('revoke '+identifier, 'revoked')
            event('ready')
            assert request(auth='Bearer '+token)[0] == 401
            status, headers, _ = mcp(list_tools, 'Bearer '+token, mcp_session)
            assert status == 401 and headers.get('www-authenticate') == 'Bearer'
            assert len(rows()) == before
            failed = invoke('send', 'Must not fall back', extra=remote, expected=1)
            assert b'401' in failed.stderr and not Path(client['HOOKFEED_STORE_PATH']).exists()
            assert b'HOOKFEED_TOKEN' in invoke('send', 'Missing token', extra={'HOOKFEED_URL':base}, expected=2).stderr
            for bad_url in [base+'?token=x', base+'#token=x', base.replace('://', '://user:pass@'), 'file:///tmp/no']:
                invoke('send', 'Bad URL', extra=remote | {'HOOKFEED_URL':bad_url}, expected=2)
            control('quit', 'stopped'); app.wait(timeout=5); app = None
            # Persisted revocation survives restart and isolated enable state starts off.
            launch('--debug-remote-start'); event('ready')
            assert request(auth='Bearer '+token)[0] == 401
            control('quit', 'stopped'); app.wait(timeout=5); app = None
            # A standalone helper receives HTTP and MCP after the UI process exits.
            launch('--debug-remote-create', 'Background connection')
            background = event('created')
            event('disabled')
            control('quit', 'stopped'); app.wait(timeout=5); app = None
            subprocess.run(['/usr/bin/defaults', 'write', service+'.settings', 'enabled', '-bool', 'YES'], env=env, check=True)
            helper = subprocess.Popen([binary, 'serve', '--managed', '--port', str(port), '--test-keychain'], env=env,
                                      stdout=subprocess.DEVNULL, stderr=errors)
            deadline = time.monotonic() + 8
            while True:
                assert helper.poll() is None, 'Headless receiver exited'
                try:
                    if request(method='GET', path='/v1/health')[0] == 200: break
                except (OSError, http.client.HTTPException): pass
                assert time.monotonic() < deadline, 'Headless receiver did not start'
                time.sleep(0.05)
            assert app is None
            assert request(auth='Bearer '+background['token'])[0] == 201
            session = initialize_mcp(background['token'])
            send = {'jsonrpc':'2.0', 'id':3, 'method':'tools/call', 'params':{
                'name':'send_message', 'arguments':{'title':'Received without UI', 'source':'grokbot'}}}
            status, _, result = mcp(send, 'Bearer '+background['token'], session)
            assert status == 200 and not result['result'].get('isError', False)
            assert rows()[0]['title'] == 'Received without UI'
            assert request(auth='Bearer '+token)[0] == 401
            # The running helper must observe a token revoked by a separate UI process immediately.
            launch(); event('disabled')
            control('revoke '+background['id'], 'revoked')
            assert request(auth='Bearer '+background['token'])[0] == 401
            assert mcp(list_tools, 'Bearer '+background['token'], session)[0] == 401
            control('quit', 'stopped'); app.wait(timeout=5); app = None
            subprocess.run(['/usr/bin/defaults', 'write', service+'.settings', 'enabled', '-bool', 'NO'], env=env, check=True)
            deadline = time.monotonic() + 8
            while True:
                try: request(method='GET', path='/v1/health')
                except (ConnectionRefusedError, ConnectionResetError): break
                assert time.monotonic() < deadline, 'Managed helper ignored disabled setting'
                time.sleep(0.05)
            assert helper.poll() is None, 'Disabled managed helper should stay available'
            helper.terminate(); helper.wait(timeout=5); helper = None
            print('Verified headless HTTP/MCP delivery, listener exclusion, and cross-process revocation.', flush=True)
            with socket.socket() as dead:
                dead.bind(('127.0.0.1', 0)); dead_url = f'http://127.0.0.1:{dead.getsockname()[1]}'
                start = time.monotonic()
                result = invoke('hook', 'claude-code', stdin=payload, extra=remote | {'HOOKFEED_URL':dead_url}, timeout=6)
                assert time.monotonic()-start < 6 and result.stderr
                invoke('run', '--', '/bin/sh', '-c', 'exit 7', expected=7, extra=remote | {'HOOKFEED_URL':dead_url})
            # A stalled HTTP server exercises the full remote timeout and watchdog.
            with socket.socket() as stalled:
                stalled.bind(('127.0.0.1', 0)); stalled.listen()
                stall_url = f'http://127.0.0.1:{stalled.getsockname()[1]}'
                start = time.monotonic()
                result = invoke('hook', 'claude-code', stdin=payload, extra=remote | {'HOOKFEED_URL':stall_url}, timeout=6)
                elapsed = time.monotonic()-start
                assert 4.5 < elapsed < 6 and result.stderr, (elapsed, result.stderr)
            # Redirects must never receive the bearer token (including same-host redirects).
            class Redirect(BaseHTTPRequestHandler):
                followed = False
                def do_POST(self):
                    if self.path == '/v1/messages':
                        self.send_response(307); self.send_header('Location', f'http://localhost:{self.server.server_port}/stolen'); self.end_headers()
                    else:
                        Redirect.followed = True; self.send_response(201); self.end_headers()
                def log_message(self, *args): pass
            with ThreadingHTTPServer(('127.0.0.1', 0), Redirect) as server:
                threading.Thread(target=server.serve_forever, daemon=True).start()
                result = invoke('send', 'Redirect', extra=remote | {'HOOKFEED_URL':f'http://127.0.0.1:{server.server_port}'}, expected=1)
                assert b'307' in result.stderr and not Redirect.followed
                server.shutdown()
            class RetryStub(BaseHTTPRequestHandler):
                def do_POST(self):
                    fields = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    self.server.keys.append(fields.get('idempotency_key'))
                    attempt = len(self.server.keys)
                    if self.server.mode == 'drop':
                        with sqlite3.connect(self.server.store) as db:
                            db.execute('INSERT OR IGNORE INTO delivered(key) VALUES (?)', (fields.get('idempotency_key'),))
                        if attempt == 1:
                            self.connection.shutdown(socket.SHUT_RDWR)
                            self.connection.close()
                            return
                    status = 503 if self.server.mode == 'always' or (self.server.mode == 'twice' and attempt <= 2) else 201
                    body = json.dumps({'error': 'busy test server'} if status == 503 else {'status': 'stored', 'id': 'test-id', 'duplicate': attempt > 1}).encode()
                    self.send_response(status)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(body)))
                    self.send_header('Retry-After', '0')
                    self.end_headers()
                    self.wfile.write(body)
                def log_message(self, *args): pass
            stub_store = home + '/retry-stub.sqlite'
            with sqlite3.connect(stub_store) as db:
                db.execute('CREATE TABLE delivered(key TEXT PRIMARY KEY)')
            for mode in ('twice', 'drop', 'always'):
                with ThreadingHTTPServer(('127.0.0.1', 0), RetryStub) as server:
                    server.mode, server.keys, server.store = mode, [], stub_store
                    threading.Thread(target=server.serve_forever, daemon=True).start()
                    result = invoke('send', 'Retry test', extra=remote | {'HOOKFEED_URL': f'http://127.0.0.1:{server.server_port}'}, expected=1 if mode == 'always' else 0)
                    server.shutdown()
                    assert len(server.keys) == {'twice': 3, 'drop': 2, 'always': 4}[mode], server.keys
                    assert len(set(server.keys)) == 1 and server.keys[0].startswith('retry:')
                    if mode == 'always': assert b'busy test server' in result.stderr
                    if mode == 'drop':
                        with sqlite3.connect(stub_store) as db:
                            assert db.execute('SELECT count(*) FROM delivered').fetchone()[0] == 1
            assert not Path(client['HOOKFEED_STORE_PATH']).exists()
            print(f'PASS: {checks} remote checks; real debug app/helper, loopback port {port}; no token logged')
        finally:
            if helper is not None:
                helper.terminate()
                try: helper.wait(timeout=5)
                except subprocess.TimeoutExpired: helper.kill(); helper.wait()
            if app is not None:
                app.terminate()
                try: app.wait(timeout=5)
                except subprocess.TimeoutExpired: app.kill(); app.wait()
            errors.close()
            # Delete only this test's exact service/account, never a wildcard or real item.
            keychain = home+'/remote-tests.keychain-db'
            if Path(keychain).exists():
                subprocess.run(['/usr/bin/security', 'delete-generic-password', '-s', service, '-a', ACCOUNT, keychain], env=env, capture_output=True)
                deleted = subprocess.run(['/usr/bin/security', 'delete-keychain', keychain], env=env, capture_output=True)
                assert deleted.returncode == 0 and not Path(keychain).exists(), 'Temporary Keychain cleanup failed'
            assert preference_digest() == initial_preferences, 'Host Keychain preference file changed'
            print('Cleanup complete: owned app exited; exact temporary Keychain removed; host Keychain preferences unchanged.', flush=True)


if __name__ == '__main__':
    main()
