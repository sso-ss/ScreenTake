#!/usr/bin/env python3
"""Protocol checks; optional real native socket integration driven by test_editor_mcp.swift."""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parent
MAX_REQUEST = 1024 * 1024
PROJECT_URI = 'screentake://editor/project'
BRIDGE = ROOT / '.build/DerivedData/Build/Products/Debug/ScreenTake.app/Contents/Helpers/screentake-mcp'


def bridge_command(path):
    assert BRIDGE.is_file(), f'Build ScreenTake first or pass --bridge: {BRIDGE}'
    return [str(BRIDGE), '--socket', path]


def run_frames(messages, path='/tmp/nonexistent-screentake-test.sock'):
    # Even with no Python or shell available on PATH, the installed helper runs.
    environment = dict(os.environ, PATH='/nonexistent')
    result = subprocess.run(bridge_command(path), input=b''.join(messages), capture_output=True,
                            timeout=20, check=True, env=environment)
    assert result.stderr == b'', result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()]


def protocol_checks():
    def rpc(method, params=None, request_id=1):
        return dict(jsonrpc='2.0', id=request_id, method=method, params=params or {})
    messages = [b'{bad\n', json.dumps([]).encode() + b'\n',
                json.dumps(rpc('tools/list')).encode() + b'\n',
                json.dumps(rpc('initialize', dict(protocolVersion='2025-11-25', capabilities={}, clientInfo=dict(name='test', version='1')))).encode() + b'\n',
                json.dumps(dict(jsonrpc='2.0', method='notifications/initialized')).encode() + b'\n',
                json.dumps(rpc('tools/list')).encode() + b'\n',
                json.dumps(rpc('tools/call', dict(name='apply_edits', arguments=dict(projectID=str(uuid.uuid4()), expectedRevision=1, edits=dict(typo=True))))).encode() + b'\n',
                json.dumps(rpc('tools/call', dict(name='get_project'))).encode() + b'\n',
                json.dumps(rpc('unknown')).encode() + b'\n',
                b'x' * (MAX_REQUEST + 1) + b'\n',
                json.dumps(rpc('ping')).encode() + b'\n']
    responses = run_frames(messages)
    assert len(responses) == len(messages) - 1
    assert [responses[i]['error']['code'] for i in (0, 1, 2, 5, 7, 8)] == [-32700, -32600, -32600, -32602, -32601, -32600]
    assert responses[6]['result']['isError'] and responses[6]['result']['structuredContent']['error']['code'] == 'connection_unavailable'
    assert responses[-1]['result'] == {}
    tools = responses[4]['result']['tools']
    assert len(tools) == 14 and all(tool['inputSchema']['additionalProperties'] is False for tool in tools)
    for tool in tools:
        assert tool['annotations']['openWorldHint'] is False
    # Every EditorEdits member must be discoverable by a client.
    import re
    swift = (ROOT / 'Screen/App/EditorCommands.swift').read_text().split('    func apply(')[0]
    fields = set(re.findall(r'    var (\w+):', swift))
    edits = next(tool for tool in tools if tool['name'] == 'apply_edits')['inputSchema']['properties']['edits']['properties']
    assert fields == set(edits), fields ^ set(edits)
    print('PASS: stdio JSON-RPC negotiation, discovery, schemas, malformed/oversized input, notifications, and offline diagnostics', flush=True)

    # Old protocol versions omit structured content; unknown versions negotiate latest.
    for version in ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25', 'future'):
        initialized, called = run_frames([
            json.dumps(rpc('initialize', dict(protocolVersion=version, capabilities={}, clientInfo={}))).encode() + b'\n',
            json.dumps(rpc('tools/call', dict(name='get_project'))).encode() + b'\n'])
        negotiated = '2025-11-25' if version == 'future' else version
        assert initialized['result']['protocolVersion'] == negotiated
        assert ('structuredContent' in called['result']) == (negotiated >= '2025-06-18')
    # Validate types before forwarding. JSON booleans are not numeric arguments/IDs.
    revision = dict(projectID=str(uuid.uuid4()), expectedRevision=0)
    invalid_calls = [
        dict(name='apply_edits', arguments=dict(**revision, edits={})),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(cursorScale=True))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(showCursor=1))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(cursorScale=4))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(ratio='typo'))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(crop=dict(rect=[[0, 0], [1]])))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(phoneVideoURL='https://example.com/a.mov'))),
        dict(name='apply_edits', arguments=dict(**revision, edits=dict(phoneVideoURL='file:///a\0.mov'))),
        dict(name='find_silences', arguments=dict(**revision, silence=dict(thresholdDB=-40, minimumPause=0, padding=0))),
        dict(name='get_job', arguments=dict(jobID='bad')),
        dict(name='get_job', arguments=dict(jobID=str(uuid.uuid4()), expectedRevision=0)),
        dict(name='get_preview_frame', arguments=dict(jobID=str(uuid.uuid4()), index=0.5)),
        dict(name='open_video', arguments=dict(path='relative.mov')),
        dict(name='render_preview', arguments=dict(**revision, times=list(range(13))))]
    responses = run_frames([messages[3]] + [json.dumps(rpc('tools/call', params)).encode() + b'\n' for params in invalid_calls])
    assert all(response['error']['code'] == -32602 for response in responses[1:]), responses
    bad_frames = [b'{"jsonrpc":"2.0","id":true,"method":"ping"}\n',
                  b'{"jsonrpc":"2.0","id":1.5,"method":"ping"}\n',
                  b'{"jsonrpc":"2.0","id":null,"method":"ping"}\n',
                  b'{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}\n',
                  b'{"jsonrpc":"2.0","id":1,"method":"ping","params":{"value":NaN}}\n',
                  b'{"jsonrpc":"2.0","method":"ping","params":[]}\n',
                  b'{"jsonrpc":"2.0","id":"string-id","method":"ping"}\n']
    responses = run_frames(bad_frames)
    assert [response['error']['code'] for response in responses[:-1]] == [-32600, -32600, -32600, -32602, -32700]
    assert responses[-1]['id'] == 'string-id' and responses[-1]['result'] == {}
    # Framing works across read boundaries, recovers from huge input, and handles EOF.
    fragmented = b'{"jsonrpc":"2.0","id":1,"method":"ping","params":{"padding":"' + b'x' * 20000 + b'"}}\n'
    assert run_frames([fragmented])[0]['result'] == {}
    assert run_frames([b'x' * (MAX_REQUEST * 3), b'\n', json.dumps(rpc('ping')).encode()])[-1]['result'] == {}
    duplicate = run_frames([messages[3], messages[3]])
    assert duplicate[-1]['error']['code'] == -32600
    check = subprocess.run([str(BRIDGE), '--socket', '/tmp/nonexistent-screentake-test.sock', '--check'], capture_output=True, timeout=10)
    assert check.returncode == 1 and json.loads(check.stdout)['error']['code'] == 'connection_unavailable'
    assert check.stderr == b''
    print('PASS: all protocol versions, numeric/boolean distinction, nested bounds, invalid UUIDs/paths, large/partial frames, EOF, and no runtime on PATH', flush=True)


def boundary_checks():
    """Hostile sockets cannot bypass private ownership checks or response limits."""
    with tempfile.TemporaryDirectory(prefix='sct-bridge-', dir='/tmp') as directory:
        os.chmod(directory, 0o700)
        path = str(Path(directory) / 'editor.sock')
        request = dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='get_project'))
        initialize = dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-11-25', capabilities={}, clientInfo={}))
        frames = [json.dumps(message).encode() + b'\n' for message in (initialize, request)]
        def call(endpoint=path):
            return run_frames(frames, endpoint)[-1]['result']['structuredContent']
        def fake_response(payload):
            if Path(path).exists():
                Path(path).unlink()
            server = socket.socket(socket.AF_UNIX)
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(1)
            failures = []
            def respond():
                try:
                    server.settimeout(10)
                    client, _ = server.accept()
                    with client:
                        client.makefile('rb').readline()
                        for offset in range(0, len(payload), 4096):
                            client.sendall(payload[offset:offset + 4096])
                except (BrokenPipeError, ConnectionResetError):
                    pass  # A bounded client deliberately closes an oversized response.
                except Exception as error:
                    failures.append(error)
                finally:
                    server.close()
            worker = threading.Thread(target=respond)
            worker.start()
            result = call()
            worker.join(timeout=10)
            assert not worker.is_alive() and not failures, failures
            return result
        success = dict(ok=True, project=dict(padding='x' * 25000))
        assert fake_response(json.dumps(success).encode() + b'\n') == success
        for payload in (b'{bad\n', b'{"ok":1}\n', b'{"ok":true}', b'x' * (16 * 1024 * 1024 + 1) + b'\n'):
            assert fake_response(payload)['error']['code'] == 'connection_unavailable'
        os.chmod(path, 0o666)
        assert '0600' in call()['error']['message']
        os.chmod(path, 0o600)
        os.chmod(directory, 0o755)
        assert '0700' in call()['error']['message']
        os.chmod(directory, 0o700)
        alias = str(Path(directory) / 'alias')
        os.symlink(path, alias)
        assert '0600' in call(alias)['error']['message']
        directory_alias = str(Path(directory) / 'linked')
        os.symlink(directory, directory_alias)
        assert not call(directory_alias + '/editor.sock')['ok']
        Path(path).unlink()
        Path(path).write_text('preserve')
        assert not call()['ok'] and Path(path).read_text() == 'preserve'
    # A disconnected MCP client must not kill the helper with SIGPIPE or hang it.
    process = subprocess.Popen(bridge_command('/tmp/nonexistent-screentake-test.sock'), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdout.close()
    try:
        process.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"ping"}\n')
        process.stdin.flush()
    except BrokenPipeError:
        pass
    process.stdin.close()
    assert process.wait(timeout=10) == 0 and process.stderr.read() == b''
    print('PASS: partial/invalid/oversized socket replies, private permissions, symlink/file rejection, and broken stdout', flush=True)


class Client:
    def __init__(self, path):
        self.process = subprocess.Popen(bridge_command(path),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=dict(os.environ, PATH='/nonexistent'))
        self.counter = 0
        self.rpc('initialize', dict(protocolVersion='2025-11-25', capabilities={}, clientInfo=dict(name='integration', version='1')))
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()

    def rpc(self, method, params=None):
        self.counter += 1
        request = dict(jsonrpc='2.0', id=self.counter, method=method, params=params or {})
        self.process.stdin.write(json.dumps(request).encode() + b'\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        assert line, self.process.stderr.read().decode()
        response = json.loads(line)
        assert response['id'] == self.counter and 'error' not in response, response
        return response['result']

    def call(self, name, **arguments):
        return self.rpc('tools/call', dict(name=name, arguments=arguments))['structuredContent']

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0
        assert self.process.stderr.read() == b''


def integration(path, source, destination):
    # Native framing rejects pipelining, oversized requests, and invalid JSON without
    # affecting the next client. Abandoned connections must not kill the server.
    for payload in (b'{}\n{}\n', b'x' * (MAX_REQUEST + 1)):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(10)
            client.connect(path)
            try:
                client.sendall(payload)
                assert not client.recv(1024)
            except (BrokenPipeError, ConnectionResetError):
                pass
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(path)
        client.sendall(b'{bad\n')
        result = json.loads(client.makefile('rb').readline())
        assert result['error']['code'] == 'invalid_request'
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(path)
        client.sendall(b'{')
    assert os.stat(path).st_mode & 0o777 == 0o600
    assert os.stat(Path(path).parent).st_mode & 0o777 == 0o700

    client = Client(path)
    assert len(client.rpc('tools/list')['tools']) == 14
    assert len(client.rpc('resources/list')['resources']) == 1
    assert client.call('get_capabilities')['ok']
    project = client.call('open_video', path=source)['project']
    def rev(p):
        return dict(projectID=p['id'], expectedRevision=p['revision'])
    stable = str(uuid.uuid4())
    changed = client.call('apply_edits', **rev(project), requestID=stable,
                          edits=dict(ratio='square', backgroundEnabled=False, trim=dict(start=0, end=1.5),
                                     crop=dict(rect=[[0, 0], [1, 1]])))
    assert changed['ok'] and changed['project']['settings']['ratio'] == 'square', changed
    edited = changed['project']
    client.close()
    # A new stdio bridge reconnects to the SAME session and shares retry/history.
    client = Client(path)
    replay = client.call('apply_edits', **rev(project), requestID=stable,
                         edits=dict(ratio='square', backgroundEnabled=False, trim=dict(start=0, end=1.5),
                                    crop=dict(rect=[[0, 0], [1, 1]])))
    assert replay['ok'] and replay['project']['revision'] == edited['revision']
    assert client.call('apply_edits', **rev(project), edits=dict(ratio='vertical'))['error']['code'] == 'stale_project'
    assert client.call('apply_edits', **rev(project), requestID=stable, edits=dict(ratio='vertical'))['error']['code'] == 'request_id_reused'
    resource = json.loads(client.rpc('resources/read', dict(uri=PROJECT_URI))['contents'][0]['text'])
    assert resource['id'] == edited['id'] and resource['settings']['ratio'] == 'square'
    undone = client.call('undo', **rev(edited))['project']
    assert undone['settings']['ratio'] == 'original'
    edited = client.call('redo', **rev(undone))['project']
    saved = client.call('save_project', **rev(edited), path=destination + '/Portable.screentake')
    assert saved['ok'] and not saved['project']['hasUnsavedWork'], saved
    edited = client.call('open_project', **rev(saved['project']), path=destination + '/Portable.screentake')['project']
    assert edited['settings']['ratio'] == 'square'

    def finish(job):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = client.call('get_job', jobID=job['id'])['job']
            if result['status'] in ('succeeded', 'failed', 'cancelled'):
                return result
            time.sleep(0.03)
        raise AssertionError('Job did not finish')
    job = finish(client.call('render_preview', **rev(edited), times=[0.5])['job'])
    assert job['status'] == 'succeeded', job
    image = client.rpc('tools/call', dict(name='get_preview_frame', arguments=dict(jobID=job['id'], index=0)))
    assert not image['isError']
    png = base64.b64decode(image['content'][1]['data'])
    assert png.startswith(b'\x89PNG\r\n\x1a\n')
    (Path(destination) / 'Preview.png').write_bytes(png)
    assert image['structuredContent']['frame']['width'] == image['structuredContent']['frame']['height']
    assert max(image['structuredContent']['frame'][key] for key in ('width', 'height')) <= 1024
    assert client.call('get_preview_frame', jobID=job['id'], index=99)['error']['code'] == 'unknown_frame'
    cancelled = client.call('render_preview', **rev(edited), times=[0.5])['job']
    cancellation = client.call('cancel_job', jobID=cancelled['id'])
    assert cancellation['ok']
    assert finish(cancelled)['status'] in ('cancelled', 'succeeded')  # A small preview can finish before the cancellation arrives.
    exported = finish(client.call('export_video', **rev(edited), path=destination + '/Export.mov')['job'])
    assert exported['status'] == 'succeeded' and Path(destination + '/Export.mov').stat().st_size > 0, exported
    failure = client.call('open_video', **rev(edited), path=destination + '/missing.mov')
    assert not failure['ok']
    assert client.call('get_project')['project']['id'] == edited['id']
    client.close()
    print('PASS: real stdio→socket→native session, reconnect/retries, revision protection, resource reads, shared undo/redo, portable project, preview image, jobs, and export', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge', type=Path, default=BRIDGE)
    parser.add_argument('--socket')
    parser.add_argument('--source')
    parser.add_argument('--destination')
    args = parser.parse_args()
    BRIDGE = args.bridge.resolve()
    protocol_checks()
    boundary_checks()
    if args.socket:
        integration(args.socket, args.source, args.destination)
