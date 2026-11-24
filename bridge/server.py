"""Authenticated LAN bridge. Optional voice relay; no audio/text persistence."""
from __future__ import annotations
import argparse
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import ipaddress
import json
from pathlib import Path
import secrets
import socket
import sys
import time
from urllib.parse import urlsplit, parse_qs

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup import Cleaner, FILE_NAME as CLEANUP_FILE
from polish import Polisher, FILE_NAME as POLISH_FILE
from engine import DemoEngine, DesktopEngine
from voice import VoiceRelay, DesktopASR, VoiceError, MAX_AUDIO, MAX_AUDIO_S16, MAX_CHUNK_S16
from hotwords import HotwordStore, HotwordError, MAX_HOT_BYTES

MAX_BODY = 32768
MAX_TEXT = 2000


def make_handler(engine, token, voice=None, hotwords=None):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'CapsWriterLab/0.1'
        def log_message(self, *args):
            pass  # Never log user text, bearer tokens or request bodies.

        def reply(self, status, value):
            data = json.dumps(value, ensure_ascii=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            try:
                remote = ipaddress.ip_address(self.client_address[0])
                if not (remote.is_private or remote.is_loopback):
                    self.reply(403, {'error': 'LAN only'}); return False
            except ValueError:
                self.reply(403, {'error': 'LAN only'}); return False
            if self.headers.get('Origin') or self.headers.get('Transfer-Encoding'):
                self.reply(403, {'error': 'Browser and chunked requests are not supported'}); return False
            actual = self.headers.get('Authorization', '')
            if not hmac.compare_digest(actual.encode(), ('Bearer ' + token).encode()):
                self.reply(401, {'error': 'Pairing token required'}); return False
            return True

        def do_GET(self):
            if not self.authorized(): return
            parts = urlsplit(self.path)
            if parts.path == '/v1/hotwords' and hotwords:
                try: self.reply(200, hotwords.read())
                except HotwordError as error: self.reply(error.status, {'error': str(error)})
                except Exception: self.reply(503, {'error': '热词文件暂不可用。'})
                return
            if parts.path == '/v1/voice/result' and voice:
                try: self.reply(200, voice.result(parse_qs(parts.query).get('id', [''])[0]))
                except VoiceError as error: self.reply(error.status, {'error': str(error)})
                return
            if self.path != '/v1/status': self.reply(404, {'error': 'Not found'}); return
            try:
                status = engine.status()
                status.update(voice.status() if voice else {'voice_enabled': False})
                self.reply(200, status)
            except Exception: self.reply(503, {'error': 'Desktop sources are updating or unavailable; retry'})

        def do_POST(self):
            if not self.authorized(): return
            parts = urlsplit(self.path)
            content_type = self.headers.get('Content-Type', '').split(';')[0].strip().lower()
            if parts.path == '/v1/voice/audio' and voice is not None and content_type == 'application/octet-stream':
                self.handle_voice_binary(parse_qs(parts.query)); return
            if parts.path == '/v1/voice/chunk' and voice is not None and content_type == 'application/octet-stream':
                self.handle_voice_chunk(parse_qs(parts.query)); return
            voice_paths = ('/v1/voice/agent', '/v1/voice/start', '/v1/voice/ack',
                           '/v1/voice/stop', '/v1/voice/cancel', '/v1/voice/consume', '/v1/voice/audio', '/v1/voice/text',
                           '/v1/voice/finish')
            is_voice = self.path in voice_paths and voice is not None
            is_hotwords = self.path == '/v1/hotwords/save' and hotwords is not None
            if self.path != '/v1/correct' and not is_voice and not is_hotwords:
                self.reply(404, {'error': 'Not found'}); return
            if self.headers.get('Content-Type', '').split(';')[0].strip().lower() != 'application/json':
                self.reply(415, {'error': 'JSON required'}); return
            try: length = int(self.headers.get('Content-Length', '-1'))
            except ValueError: length = -1
            limit = (MAX_AUDIO * 4 // 3 + MAX_BODY) if self.path == '/v1/voice/audio' else (MAX_HOT_BYTES * 6 + MAX_BODY if is_hotwords else MAX_BODY)
            if self.path == '/v1/voice/text': limit = MAX_BODY + 20000 * 6
            if not 0 < length <= limit:
                self.reply(413, {'error': 'Body length limit exceeded'}); return
            self.connection.settimeout(10)
            try:
                raw = self.rfile.read(length)
                if len(raw) != length: raise ValueError('Incomplete body')
                value = json.loads(raw)
                if not isinstance(value, dict): raise ValueError('Object required')
                if is_hotwords:
                    try:
                        self.reply(200, hotwords.save(value.get('file_id'), value.get('revision'), value.get('text')))
                    except HotwordError as error: self.reply(error.status, {'error': str(error)})
                    except Exception: self.reply(503, {'error': '保存失败，原始词库已保留。'})
                    return
                if is_voice:
                    self.handle_voice(value); return
                text = value.get('text') if isinstance(value, dict) else None
                if not isinstance(text, str) or len(text) > MAX_TEXT:
                    raise ValueError('Text must contain at most 2000 characters')
            except (ValueError, UnicodeError, TimeoutError):
                self.reply(400, {'error': 'Invalid JSON or text'}); return
            try: self.reply(200, asdict(engine.correct(text)))
            except Exception: self.reply(503, {'error': 'Desktop correction unavailable; check local console'})

        def handle_voice_binary(self, query):
            """Raw int16 upload. The job is marked as receiving before the body
            is read, so heartbeats stuck behind a slow upload don't fail it."""
            first = lambda key: query.get(key, [''])[0]
            job_id = first('id')
            try: length = int(self.headers.get('Content-Length', '-1'))
            except ValueError: length = -1
            if not 0 < length <= MAX_AUDIO_S16:
                self.reply(413, {'error': '录音最长 5 分钟。'}); return
            try:
                rate = int(first('sample_rate') or '0')
                voice.begin_receive(job_id, first('agent_id'), first('encoding'), rate, length)
            except ValueError: self.reply(400, {'error': 'Invalid sample rate'}); return
            except VoiceError as error: self.reply(error.status, {'error': str(error)}); return
            self.connection.settimeout(30)
            try:
                raw = self.rfile.read(length)
                if len(raw) != length: raise ValueError('Incomplete body')
            except (OSError, ValueError):
                voice.abort_receive(job_id)
                try: self.reply(400, {'error': '录音上传中断，请重试。'})
                except OSError: pass
                return
            try: self.reply(200, voice.upload_pcm(job_id, first('agent_id'), raw))
            except VoiceError as error: self.reply(error.status, {'error': str(error)})
            except Exception:
                voice.abort_receive(job_id)
                self.reply(503, {'error': '语音服务暂不可用，请检查电脑服务。'})

        def handle_voice_chunk(self, query):
            """A small live int16 chunk sent while the phone is recording."""
            first = lambda key: query.get(key, [''])[0]
            try: length = int(self.headers.get('Content-Length', '-1'))
            except ValueError: length = -1
            if not 0 <= length <= MAX_CHUNK_S16:
                self.reply(413, {'error': 'Audio chunk too large'}); return
            try: offset = int(first('offset'))
            except ValueError: self.reply(400, {'error': 'Invalid offset'}); return
            self.connection.settimeout(10)
            try:
                raw = self.rfile.read(length) if length else b''
                if len(raw) != length: raise ValueError('Incomplete body')
            except (OSError, ValueError):
                try: self.reply(400, {'error': 'Incomplete audio chunk'})
                except OSError: pass
                return
            try: self.reply(200, voice.append_chunk(first('id'), first('agent_id'), offset, raw))
            except VoiceError as error: self.reply(error.status, {'error': str(error)})
            except Exception: self.reply(503, {'error': '语音服务暂不可用，请检查电脑服务。'})

        def handle_voice(self, value):
            try:
                action = self.path.rsplit('/', 1)[-1]
                if action == 'start': result = voice.start()
                elif action == 'agent':
                    if not isinstance(value.get('active', True), bool):
                        raise VoiceError(400, 'Invalid active flag')
                    result = voice.agent(value.get('agent_id'), value.get('active', True))
                elif action == 'ack': result = voice.ack(value.get('id'), value.get('agent_id'))
                elif action == 'audio': result = voice.upload(value)
                elif action == 'text': result = voice.upload_text(value)
                elif action == 'finish': result = voice.finish_stream(value.get('id'), value.get('agent_id'), value.get('total'))
                elif action == 'stop': result = voice.stop(value.get('id'))
                elif action == 'cancel': result = voice.cancel(value.get('id'))
                else: result = voice.consume(value.get('id'))
                self.reply(200, result)
            except VoiceError as error: self.reply(error.status, {'error': str(error)})
            except Exception: self.reply(503, {'error': '语音服务暂不可用，请检查电脑服务。'})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop', type=Path, help='Read-only path to CapsWriter-v3')
    parser.add_argument('--demo', action='store_true')
    parser.add_argument('--host', default='127.0.0.1', help='Use your LAN IP explicitly to allow the phone')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--token-file', type=Path, help='Optional token file inside your private project folder')
    parser.add_argument('--asr-port', type=int, help='Enable voice via the existing loopback desktop ASR server, usually 6016')
    parser.add_argument('--stream-model', type=Path, help='Optional streaming Paraformer folder for live draft text while recording')
    parser.add_argument('--hotwords-state', type=Path, help='Private directory for hotword backups and temporary saves')
    parser.add_argument('--cleanup-file', type=Path, default=Path(__file__).resolve().parent / CLEANUP_FILE,
                        help='Filler and repeat cleanup rules; created with defaults when missing')
    parser.add_argument('--no-cleanup', action='store_true', help='Do not remove filler words or stuttered repeats')
    parser.add_argument('--polish-file', type=Path, default=Path(__file__).resolve().parent / POLISH_FILE,
                        help='Optional local Ollama polish settings; created with defaults when missing')
    parser.add_argument('--no-polish', action='store_true', help='Disable local Ollama speech polishing')
    parser.add_argument('--no-sentences', action='store_true',
                        help='Do not recognize and polish each sentence while recording (needs --stream-model)')
    parser.add_argument('--enable-hotword-save', action='store_true', help='Explicitly allow saving desktop hot.txt, personal aliases and rules')
    args = parser.parse_args()
    if bool(args.desktop) == bool(args.demo): parser.error('Choose exactly one of --desktop or --demo')
    ip = ipaddress.ip_address(args.host)
    if not (ip.is_loopback or ip.is_private) or ip.is_unspecified:
        parser.error('Bind to a specific LAN or loopback IP, never 0.0.0.0/public IP')
    engine = DemoEngine() if args.demo else DesktopEngine(args.desktop)
    if not args.no_cleanup:
        engine.cleaner = Cleaner(args.cleanup_file, create=True)
    if not args.no_polish and not args.demo:
        engine.polisher = Polisher(args.polish_file, create=True)
    token = secrets.token_urlsafe(24)
    if args.token_file:
        if args.token_file.exists():
            token = args.token_file.read_text(encoding='utf-8').strip()
            if len(token) < 24: parser.error('Stored token is too short')
        else:
            args.token_file.parent.mkdir(parents=True, exist_ok=True)
            args.token_file.write_text(token, encoding='utf-8')
    preview = None
    if args.stream_model:
        if not args.asr_port: parser.error('--stream-model needs --asr-port')
        from stream import load
        preview = load(args.stream_model)
    voice = VoiceRelay(engine, DesktopASR(args.asr_port), preview=preview,
                       sentences=not args.no_sentences) if args.asr_port else None
    if args.enable_hotword_save and (not args.desktop or not args.hotwords_state):
        parser.error('Hotword saving needs a desktop source and explicit private state directory')
    hotwords = HotwordStore(args.desktop, args.hotwords_state, writable=args.enable_hotword_save,
                           validate=engine.validate_hotwords) if args.desktop and args.hotwords_state else None
    server = ThreadingHTTPServer((args.host, args.port), make_handler(engine, token, voice, hotwords))
    server.daemon_threads = True
    print(f'CapsWriter Lab bridge: http://{args.host}:{args.port}', flush=True)
    print(f'Pairing token (keep local): {token}', flush=True)
    print(json.dumps(engine.status(), ensure_ascii=False), flush=True)
    if engine.cleaner: print(f'Speech cleanup rules: {args.cleanup_file}', flush=True)
    if engine.polisher: print(f'Local LLM polish config: {args.polish_file}', flush=True)
    print('Voice: existing local desktop ASR.' if voice else 'Voice disabled (text tests only).', flush=True)
    if preview: print('Live preview: streaming draft text while recording.', flush=True)
    if preview and not args.no_sentences:
        print('Sentences: each pause is recognized and polished while recording.', flush=True)
    print('The bridge saves no audio or text. Desktop ASR may use its normal logs. Ctrl+C stops.', flush=True)
    try: server.serve_forever(poll_interval=.5)
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == '__main__': main()
