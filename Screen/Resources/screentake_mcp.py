#!/usr/bin/env python3
"""ScreenTake stdio MCP bridge. Python 3 standard library; no network service."""
import argparse
import json
import math
import os
from pathlib import Path
import socket
import stat
import sys
import uuid

MAX_REQUEST = 1024 * 1024
MAX_RESPONSE = 16 * 1024 * 1024
PROTOCOLS = ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25')
PROJECT_URI = 'screentake://editor/project'


def obj(properties, required=(), **extra):
    return dict(type='object', properties=properties, required=list(required), additionalProperties=False, **extra)


def number(low=None, high=None, **extra):
    result = dict(type='number', **extra)
    if low is not None:
        result['minimum'] = low
    if high is not None:
        result['maximum'] = high
    return result


def enum(*values):
    return dict(type='string', enum=list(values))


def array(item, **extra):
    return dict(type='array', items=item, **extra)


UUID = dict(type='string', format='uuid')
BOOL = dict(type='boolean')
TIME = number(0)
FILE_URL = dict(type='string', pattern=r'^file:///', description='Absolute local file URL, e.g. file:///Users/me/take.mov.')
CUT = obj(dict(id=UUID, start=TIME, end=TIME), ('id', 'start', 'end'))
EXACT_RANGE = obj(dict(startValue=dict(type='integer', minimum=0), startScale=dict(type='integer', minimum=1),
                      durationValue=dict(type='integer', minimum=1), durationScale=dict(type='integer', minimum=1)),
                  ('startValue', 'startScale', 'durationValue', 'durationScale'))
CAMERA = obj(dict(layout=enum('overlay', 'fullScreen'), zoom=number(1, 3), centerX=number(0, 1), centerY=number(0, 1),
                  followFace=BOOL, smoothTransition=BOOL, transitionDuration=number(0.1, 2),
                  transitionMotion=enum('smooth', 'linear', 'easeIn', 'easeOut')),
             description='Replaces camera framing; omitted members use native defaults.')
EDITS = obj(dict(
    trim=obj(dict(start=TIME, end=dict(type=['number', 'null'], minimum=0), cuts=array(CUT), splits=array(TIME),
                  clipOrder=array(EXACT_RANGE)), description='Replaces the timeline. Seconds refer to source time; clipOrder preserves rational CMTime ranges.'),
    removeRanges=array(CUT, description='Append cuts in source seconds. Supply a UUID for each cut.'),
    ratio=enum('original', 'landscape', 'desktop', 'square', 'portrait', 'vertical'),
    layout=enum('desktop', 'iPhone', 'duo', 'iPhoneDuoClosed', 'iPhoneDuoUnfolded'),
    wallpaper=enum('sonoma', 'aurora', 'sunset', 'ocean', 'blossom', 'nebula', 'moss', 'dusk', 'prism', 'lagoon', 'ember', 'midnight'),
    backgroundEnabled=BOOL, desktopCornerRadius=number(0, 0.5),
    crop=obj(dict(rect=array(array(number(0, 1), minItems=2, maxItems=2), minItems=2, maxItems=2,
                            description='CGRect encoded as [[x,y],[width,height]], normalized to source dimensions.')), ('rect',)),
    phoneMode=enum('fit', 'fill'), phoneVideoURL=FILE_URL,
    showCursor=BOOL, cursorShape=enum('arrow', 'hand', 'circle'), cursorScale=number(0.5, 3),
    zoomEnabled=BOOL, zoomLevel=number(1, 10),
    zoomSegments=array(obj(dict(id=UUID, start=TIME, end=TIME, zoom=number(1, 10), centerX=number(0, 1),
                               centerY=number(0, 1), followsCursor=BOOL),
                          ('id', 'start', 'end', 'zoom', 'centerX', 'centerY', 'followsCursor'))),
    restoreAutomaticZooms=BOOL,
    webcamEnabled=BOOL, webcamShape=enum('circle', 'roundedSquare'),
    webcamPosition=enum('topLeft', 'topCenter', 'topRight', 'middleLeft', 'center', 'middleRight', 'bottomLeft', 'bottomCenter', 'bottomRight'),
    webcamSize=enum('small', 'medium', 'large'), videoOverlayURL=FILE_URL, cameraLayout=CAMERA,
    cameraLayoutChanges=array(obj(dict(start=TIME, settings=CAMERA), ('start', 'settings'))),
    videoOverlayTiming=obj(dict(start=TIME, duration=number(0, exclusiveMinimum=0), sourceStart=TIME), ('start', 'duration', 'sourceStart')),
    voiceOvers=array(obj(dict(id=UUID, url=FILE_URL, start=TIME, sourceStart=TIME, duration=number(0, exclusiveMinimum=0),
                             sourceDuration=number(0, exclusiveMinimum=0)),
                        ('id', 'url', 'start', 'sourceStart', 'duration', 'sourceDuration'))),
    audioEnabled=BOOL, originalAudioVolume=number(0, 1), voiceOverEnabled=BOOL, voiceOverVolume=number(0, 1),
    exportResolution=enum('preserveSource', 'uhd4k', 'fhd1080')),
    minProperties=1, description='Partial settings batch, committed as one undo operation. Omitted top-level fields stay unchanged. Arrays replace their previous values except removeRanges. Read get_project for current values.')


def tools():
    retry = dict(requestID=dict(**UUID, description='Optional stable UUID for retries. Reuse it only with identical arguments. Successful mutations are deduplicated for the last 100 IDs.'))
    revision = dict(projectID=UUID, expectedRevision=dict(type='integer', minimum=0))
    path = dict(path=dict(type='string', pattern=r'^/', description='Absolute local file path.'))
    specifications = [
        ('get_capabilities', 'List the native editor commands and revision/job requirements.', {}, (), True, False),
        ('get_project', 'Read the project open in the native editor, complete settings, revision, busy state, and undo availability. Read this before editing.', {}, (), True, False),
        ('open_video', 'Open local video in the native editor. When replacing a video, supply its projectID and expectedRevision; discardUnsaved=true explicitly permits replacement of unsaved work.', dict(**path, **revision, discardUnsaved=BOOL), ('path',), False, True),
        ('open_project', 'Open a portable .screenize project in the native editor. Replacing work has the same revision and discard requirements as open_video.', dict(**path, **revision, discardUnsaved=BOOL), ('path',), False, True),
        ('save_project', 'Atomically save the current editable project with embedded media to a .screenize package.', dict(**path, **revision), ('path', 'projectID', 'expectedRevision'), False, True),
        ('apply_edits', 'Apply validated settings to the same draft displayed by the UI. Uses one shared undo operation. Stale revisions are rejected.', dict(**revision, edits=EDITS), ('projectID', 'expectedRevision', 'edits'), False, False),
        ('find_silences', 'Start an analysis job suggesting removals in retained source time. Suggestions do not change the timeline; review and apply them with apply_edits.', dict(**revision, silence=obj(dict(thresholdDB=number(-80, 0), minimumPause=number(0, exclusiveMinimum=0), padding=TIME), ('thresholdDB', 'minimumPause', 'padding'))), ('projectID', 'expectedRevision'), False, False),
        ('render_preview', 'Start a preview job at 1–12 edited-video timestamps. Poll get_job, then call get_preview_frame to see a PNG.', dict(**revision, times=array(TIME, minItems=1, maxItems=12)), ('projectID', 'expectedRevision'), False, False),
        ('export_video', 'Start a job rendering the current draft and atomically saving video to the destination. Poll get_job; cancel_job can stop encoding and preserve an existing destination.', dict(**path, **revision), ('path', 'projectID', 'expectedRevision'), False, True),
        ('get_job', 'Read queued/running/cancelling/succeeded/failed/cancelled status, progress, output, preview frame indices, or silence suggestions. The last 50 jobs are retained.', dict(jobID=UUID), ('jobID',), True, False),
        ('cancel_job', 'Request cancellation of a known job. Poll get_job until teardown reaches a terminal state.', dict(jobID=UUID), ('jobID',), False, False),
        ('undo', 'Undo the last settings change made by either the UI or a tool.', revision, ('projectID', 'expectedRevision'), False, False),
        ('redo', 'Redo a settings change from the shared history.', revision, ('projectID', 'expectedRevision'), False, False),
        ('get_preview_frame', 'Return a PNG image from a completed render_preview job, scaled to at most 1024 pixels per side. No arbitrary file reads.', dict(jobID=UUID, index=dict(type='integer', minimum=0)), ('jobID', 'index'), True, False),
    ]
    return [dict(name=name, description=description, inputSchema=obj(dict(**properties, **retry), required),
                 annotations=dict(readOnlyHint=read_only, destructiveHint=destructive, idempotentHint=read_only or name == 'cancel_job', openWorldHint=False))
            for name, description, properties, required, read_only, destructive in specifications]


def validate(value, schema, location='arguments'):
    """Validate our published schema subset before calling the native decoder."""
    types = schema.get('type', [])
    types = [types] if isinstance(types, str) else types
    actual = ('null' if value is None else 'boolean' if isinstance(value, bool) else
              'integer' if isinstance(value, int) else 'number' if isinstance(value, float) else
              'string' if isinstance(value, str) else 'object' if isinstance(value, dict) else
              'array' if isinstance(value, list) else 'unknown')
    if actual not in types and not (actual == 'integer' and 'number' in types):
        raise RPCError(-32602, f'{location}: expected {" or ".join(types)}.')
    if value is None:
        return
    if 'enum' in schema and value not in schema['enum']:
        raise RPCError(-32602, f'{location}: unsupported value {value!r}.')
    if actual in ('integer', 'number'):
        if not math.isfinite(value):
            raise RPCError(-32602, f'{location}: must be finite.')
        if 'minimum' in schema and value < schema['minimum'] or 'maximum' in schema and value > schema['maximum'] or 'exclusiveMinimum' in schema and value <= schema['exclusiveMinimum']:
            raise RPCError(-32602, f'{location}: outside the allowed range.')
    elif actual == 'object':
        missing = set(schema.get('required', [])) - value.keys()
        unknown = value.keys() - schema.get('properties', {}).keys()
        if missing or unknown:
            raise RPCError(-32602, f'{location}: missing {sorted(missing)}; unknown {sorted(unknown)}.')
        if len(value) < schema.get('minProperties', 0):
            raise RPCError(-32602, f'{location}: provide at least one edit.')
        for key, member in value.items():
            validate(member, schema['properties'][key], f'{location}.{key}')
    elif actual == 'array':
        if len(value) < schema.get('minItems', 0) or len(value) > schema.get('maxItems', MAX_REQUEST):
            raise RPCError(-32602, f'{location}: invalid number of items.')
        for index, member in enumerate(value):
            validate(member, schema['items'], f'{location}[{index}]')
    elif actual == 'string':
        if schema.get('format') == 'uuid':
            try:
                uuid.UUID(value)
            except ValueError:
                raise RPCError(-32602, f'{location}: provide a UUID.') from None
        if schema.get('pattern'):
            import re
            if not re.search(schema['pattern'], value) or '\0' in value:
                raise RPCError(-32602, f'{location}: invalid local path or URL.')


class RPCError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


def editor_call(path, request):
    directory = os.lstat(str(Path(path).parent))
    endpoint = os.lstat(path)
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid() or stat.S_IMODE(directory.st_mode) != 0o700:
        raise OSError('The socket directory must be private (0700) and owned by your user.')
    if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.getuid() or stat.S_IMODE(endpoint.st_mode) != 0o600:
        raise OSError('The socket must be private (0600) and owned by your user.')
    wire = json.dumps(request, allow_nan=False, separators=(',', ':')).encode() + b'\n'
    if len(wire) > MAX_REQUEST:
        raise OSError('The native request exceeds 1 MiB.')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(125)
        client.connect(path)
        client.sendall(wire)
        with client.makefile('rb') as stream:
            response = stream.readline(MAX_RESPONSE + 1)
        if len(response) > MAX_RESPONSE or not response.endswith(b'\n'):
            raise OSError('Invalid or oversized response from the editor.')
        result = json.loads(response)
        if not isinstance(result, dict) or not isinstance(result.get('ok'), bool):
            raise OSError('Invalid response from the editor.')
        return result


class Bridge:
    def __init__(self, socket_path):
        self.socket_path = socket_path
        self.protocol = None
        self.catalog = tools()

    def dispatch(self, request):
        if not isinstance(request, dict) or request.get('jsonrpc') != '2.0' or not isinstance(request.get('method'), str):
            raise RPCError(-32600, 'Expected a JSON-RPC 2.0 request object.')
        method, params = request['method'], request.get('params', {})
        if not isinstance(params, dict):
            raise RPCError(-32602, 'params must be an object.')
        if 'id' not in request:
            return None  # Notifications never produce stdout responses.
        if isinstance(request['id'], bool) or not isinstance(request['id'], (int, str)):
            raise RPCError(-32600, 'Request id must be a string or integer.')
        if method == 'initialize':
            if self.protocol is not None:
                raise RPCError(-32600, 'Already initialized.')
            if not isinstance(params.get('protocolVersion'), str) or not isinstance(params.get('capabilities'), dict) or not isinstance(params.get('clientInfo'), dict):
                raise RPCError(-32602, 'Provide protocolVersion, capabilities, and clientInfo.')
            version = params['protocolVersion']
            self.protocol = version if version in PROTOCOLS else PROTOCOLS[-1]
            return dict(protocolVersion=self.protocol, capabilities=dict(tools=dict(listChanged=False), resources=dict(subscribe=False, listChanged=False)),
                        serverInfo=dict(name='screentake', version='1.0.0'),
                        instructions='Operate the project open in ScreenTake. Read get_project before editing and pass projectID/expectedRevision. Use stable requestID UUIDs for retriable mutations. Rendering and analysis return jobs; poll get_job. Retrieve preview images with get_preview_frame. ScreenTake must be running with its AI connection enabled.')
        if method == 'ping':
            return {}
        if self.protocol is None:
            raise RPCError(-32600, 'Initialize first.')
        if method == 'tools/list':
            return dict(tools=self.catalog)
        if method == 'resources/list':
            return dict(resources=[dict(uri=PROJECT_URI, name='Current editor project', description='Live settings and revision from the native editor.', mimeType='application/json')])
        if method == 'resources/templates/list':
            return dict(resourceTemplates=[])
        if method == 'resources/read':
            if params.get('uri') != PROJECT_URI:
                raise RPCError(-32602, 'Unknown resource URI.')
            result = self.native(dict(id=str(uuid.uuid4()), operation='get_project'))
            if not result.get('ok'):
                raise RPCError(-32000, result['error']['message'])
            return dict(contents=[dict(uri=PROJECT_URI, mimeType='application/json', text=json.dumps(result['project'], allow_nan=False))])
        if method == 'tools/call':
            tool = next((tool for tool in self.catalog if tool['name'] == params.get('name')), None)
            if tool is None:
                raise RPCError(-32602, 'Unknown tool.')
            arguments = params.get('arguments', {})
            validate(arguments, tool['inputSchema'])
            arguments = dict(arguments)
            request_id = arguments.pop('requestID', str(uuid.uuid4()))
            if tool['name'] == 'get_preview_frame':
                result = self.native(dict(artifact='preview_frame', **arguments))
            else:
                result = self.native(dict(id=request_id, operation=tool['name'], **arguments))
            content = []
            if result.get('ok') and 'frame' in result:
                frame = dict(result['frame'])
                content.append(dict(type='image', data=frame.pop('data'), mimeType=frame['mimeType']))
                result = dict(ok=True, frame=frame)
            content.insert(0, dict(type='text', text=json.dumps(result, allow_nan=False)))
            response = dict(content=content, isError=not result.get('ok', False))
            if self.protocol >= '2025-06-18':
                response['structuredContent'] = result
            return response
        raise RPCError(-32601, f'Unknown method: {method}')

    def native(self, request):
        try:
            return editor_call(self.socket_path, request)
        except (OSError, ValueError) as error:
            return dict(ok=False, error=dict(code='connection_unavailable', message=f'{error}. Start ScreenTake and check ScreenTake → AI Connection. After a connection loss, use the same requestID to retry a mutation; it may already have completed.'))


def serve(bridge, input_stream, output_stream):
    while True:
        line = input_stream.readline(MAX_REQUEST + 1)
        if not line:
            return
        request, request_id = None, None
        try:
            if len(line) > MAX_REQUEST:
                while not line.endswith(b'\n'):
                    line = input_stream.readline(MAX_REQUEST + 1)
                    if not line:
                        break
                raise RPCError(-32600, 'Request exceeds 1 MiB.')
            try:
                request = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
            except (ValueError, UnicodeError, RecursionError):
                raise RPCError(-32700, 'Invalid JSON.') from None
            if isinstance(request, dict):
                candidate = request.get('id')
                if isinstance(candidate, (int, str)) and not isinstance(candidate, bool):
                    request_id = candidate
            result = bridge.dispatch(request)
            if result is None:
                continue
            response = dict(jsonrpc='2.0', id=request_id, result=result)
        except RPCError as error:
            if isinstance(request, dict) and 'id' not in request and request.get('jsonrpc') == '2.0' and isinstance(request.get('method'), str):
                continue
            response = dict(jsonrpc='2.0', id=request_id, error=dict(code=error.code, message=error.message))
        except (RecursionError, OverflowError, ValueError):
            response = dict(jsonrpc='2.0', id=request_id, error=dict(code=-32602, message='Invalid parameters.'))
        output_stream.write(json.dumps(response, allow_nan=False, separators=(',', ':')).encode() + b'\n')
        output_stream.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=f'/tmp/screentake-{os.getuid()}/editor.sock', help='Override the local socket path for diagnostics/tests.')
    parser.add_argument('--check', action='store_true', help='Print a read-only connection check and exit.')
    args = parser.parse_args()
    bridge = Bridge(args.socket)
    if args.check:
        result = bridge.native(dict(id=str(uuid.uuid4()), operation='get_capabilities'))
        print(json.dumps(result, indent=2))
        return 0 if result.get('ok') else 1
    serve(bridge, sys.stdin.buffer, sys.stdout.buffer)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
