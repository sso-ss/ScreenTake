#!/usr/bin/env python3
"""Protocol checks; optional real native socket integration driven by test_editor_mcp.swift."""
import argparse
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'Screen/Resources/screentake_mcp.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def protocol_checks():
    bridge = module.Bridge('/tmp/nonexistent-screentake-test.sock')
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
                b'x' * (module.MAX_REQUEST + 1) + b'\n',
                json.dumps(rpc('ping')).encode() + b'\n']
    output = io.BytesIO()
    module.serve(bridge, io.BytesIO(b''.join(messages)), output)
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
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
    assert fields == set(module.EDITS['properties']), fields ^ set(module.EDITS['properties'])
    print('PASS: stdio JSON-RPC negotiation, discovery, schemas, malformed/oversized input, notifications, and offline diagnostics', flush=True)


class Client:
    def __init__(self, path):
        self.process = subprocess.Popen([sys.executable, str(ROOT / 'Screen/Resources/screentake_mcp.py'), '--socket', path],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
    for payload in (b'{}\n{}\n', b'x' * (module.MAX_REQUEST + 1)):
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
    resource = json.loads(client.rpc('resources/read', dict(uri=module.PROJECT_URI))['contents'][0]['text'])
    assert resource['id'] == edited['id'] and resource['settings']['ratio'] == 'square'
    undone = client.call('undo', **rev(edited))['project']
    assert undone['settings']['ratio'] == 'original'
    edited = client.call('redo', **rev(undone))['project']
    saved = client.call('save_project', **rev(edited), path=destination + '/Portable.screenize')
    assert saved['ok'] and not saved['project']['hasUnsavedWork'], saved
    edited = client.call('open_project', **rev(saved['project']), path=destination + '/Portable.screenize')['project']
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
    parser.add_argument('--socket')
    parser.add_argument('--source')
    parser.add_argument('--destination')
    args = parser.parse_args()
    protocol_checks()
    if args.socket:
        integration(args.socket, args.source, args.destination)
