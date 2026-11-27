import base64
import json
import struct
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from engine import DemoEngine
from server import make_handler
from voice import VoiceRelay, VoiceError, DesktopASR, MAX_SECONDS


class FakeASR:
    def available(self): return True
    def transcribe(self, pcm, task_id):
        self.pcm, self.task_id = pcm, task_id
        return '卡普斯赖特'


class VoiceTests(unittest.TestCase):
    def setUp(self):
        self.now = 100
        self.asr = FakeASR()
        self.relay = VoiceRelay(DemoEngine(), self.asr, clock=lambda: self.now)
        self.agent = 'test-phone-agent-id'
        self.audio = struct.pack('<f', .1) * 4000

    def begin(self):
        self.relay.agent(self.agent)
        job = self.relay.start()
        self.relay.ack(job['id'], self.agent)
        return job['id']

    def payload(self, job_id, audio=None):
        return dict(id=job_id, agent_id=self.agent, encoding='f32le', sample_rate=16000,
                    audio=base64.b64encode(self.audio if audio is None else audio).decode())

    def test_full_record_stop_recognize_correct_consume(self):
        job_id = self.begin()
        self.assertEqual(self.relay.stop(job_id)['state'], 'stopping')
        result = self.relay.upload(self.payload(job_id))
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['text'], 'CapsWriter')
        self.assertEqual(self.asr.pcm, self.audio)
        self.assertEqual(self.asr.task_id, job_id)
        self.assertEqual(self.relay.consume(job_id)['text'], '')
        with self.assertRaises(VoiceError): self.relay.upload(self.payload(job_id))

    def test_cold_or_dead_agent_cannot_record(self):
        with self.assertRaisesRegex(VoiceError, '主 App'): self.relay.start()
        job_id = self.begin(); self.now += 9
        self.assertEqual(self.relay.result(job_id)['state'], 'recording')  # cellular blip
        self.now += 12
        self.assertEqual(self.relay.result(job_id)['state'], 'error')
        with self.assertRaises(VoiceError): self.relay.upload(self.payload(job_id))

    def test_phone_transcript_uses_same_correction_without_server_asr(self):
        job_id = self.begin(); self.relay.stop(job_id)
        value = dict(id=job_id, agent_id=self.agent, text='卡普斯赖特')
        self.assertEqual(self.relay.upload_text(value)['text'], 'CapsWriter')
        self.assertFalse(hasattr(self.asr, 'pcm'))
        with self.assertRaises(VoiceError): self.relay.upload_text(value)
        self.assertEqual(self.relay.consume(job_id)['text'], '')

    def test_phone_transcript_validates_agent_bounds_and_cancel(self):
        job_id = self.begin()
        for text in ('', ' ', None, '字' * 20001):
            with self.assertRaises(VoiceError):
                self.relay.upload_text(dict(id=job_id, agent_id=self.agent, text=text))
        with self.assertRaises(VoiceError):
            self.relay.upload_text(dict(id=job_id, agent_id='wrong', text='测试'))
        self.relay.cancel(job_id)
        with self.assertRaises(VoiceError):
            self.relay.upload_text(dict(id=job_id, agent_id=self.agent, text='测试'))

    def test_cancel_during_phone_correction_cannot_resurrect_text(self):
        entered, release = threading.Event(), threading.Event()
        class SlowEngine(DemoEngine):
            def correct(self, text, **options):
                entered.set(); release.wait(2)
                return super().correct(text)
        self.relay.engine = SlowEngine()
        job_id = self.begin()
        worker = threading.Thread(target=lambda: self.relay.upload_text(dict(id=job_id, agent_id=self.agent, text='测试')))
        worker.start()
        try:
            self.assertTrue(entered.wait(2)); self.relay.cancel(job_id)
        finally:
            release.set(); worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.relay.result(job_id)['state'], 'cancelled')
        self.assertEqual(self.relay.result(job_id)['text'], '')

    def test_isolation_and_no_parallel_capture(self):
        job_id = self.begin()
        with self.assertRaises(VoiceError): self.relay.start()
        with self.assertRaises(VoiceError): self.relay.agent('other-phone-agent-id')
        with self.assertRaises(VoiceError): self.relay.ack(job_id, 'wrong')
        with self.assertRaises(VoiceError): self.relay.result('wrong')

    def test_cancel_clears_and_rejects_audio(self):
        job_id = self.begin()
        self.assertEqual(self.relay.cancel(job_id)['text'], '')
        with self.assertRaises(VoiceError): self.relay.upload(self.payload(job_id))
        self.relay.start()

    def test_audio_bounds_finite_encoding(self):
        job_id = self.begin()
        for audio in (b'', b'x', struct.pack('<f', float('nan')) * 4000,
                      struct.pack('<f', 3.0) * 4000):
            with self.assertRaises(VoiceError): self.relay.upload(self.payload(job_id, audio))
        payload = self.payload(job_id); payload['audio'] = 'not-base64'
        with self.assertRaises(VoiceError): self.relay.upload(payload)
        payload = self.payload(job_id); payload['sample_rate'] = 48000
        with self.assertRaises(VoiceError): self.relay.upload(payload)

    def test_expiry_and_agent_closed(self):
        job_id = self.begin(); self.relay.agent(self.agent, False)
        self.assertEqual(self.relay.result(job_id)['state'], 'error')
        self.now += MAX_SECONDS + 181
        with self.assertRaises(VoiceError): self.relay.result(job_id)

    def test_live_recording_can_cross_one_minute(self):
        job_id = self.begin()
        for _ in range(17):
            self.now += 4
            self.relay.agent(self.agent)
        self.assertEqual(self.relay.result(job_id)['state'], 'recording')
        self.relay.stop(job_id)
        result = self.relay.upload(self.payload(job_id, struct.pack('<f', .1) * (16000 * 65)))
        self.assertEqual(result['state'], 'done')

    def test_stale_recognition_cannot_overwrite_cancellation(self):
        job_id = self.begin()
        def transcribe(pcm, task_id):
            self.relay.cancel(task_id)
            return 'late result'
        self.asr.transcribe = transcribe
        result = self.relay.upload(self.payload(job_id))
        self.assertEqual(result['state'], 'cancelled')
        self.assertEqual(result['text'], '')

    def s16(self, seconds=1.0, value=3277):
        return struct.pack('<h', value) * int(16000 * seconds)

    def test_binary_int16_upload_survives_slow_transfer(self):
        job_id = self.begin(); self.relay.stop(job_id)
        pcm = self.s16()
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, len(pcm))
        self.assertEqual(self.relay.result(job_id)['state'], 'processing')
        self.now += 120  # heartbeats queued behind a slow upload
        self.assertEqual(self.relay.result(job_id)['state'], 'processing')
        result = self.relay.upload_pcm(job_id, self.agent, pcm)
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['text'], 'CapsWriter')
        self.assertEqual(len(self.asr.pcm), len(pcm) * 2)
        self.assertAlmostEqual(struct.unpack('<f', self.asr.pcm[:4])[0], 3277 / 32768, places=5)
        self.assertNotIn('receiving_since', result)

    def test_long_recording_upload_is_not_cut_by_total_age(self):
        job_id = self.begin()
        for _ in range(29):
            self.now += 10; self.relay.agent(self.agent)
        self.relay.stop(job_id)
        pcm = self.s16(seconds=2)
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, len(pcm))
        self.now += 60
        self.assertEqual(self.relay.upload_pcm(job_id, self.agent, pcm)['state'], 'done')
        self.now += 100
        self.assertEqual(self.relay.result(job_id)['state'], 'done')  # still readable

    def test_interrupted_binary_upload_can_retry(self):
        job_id = self.begin(); self.relay.stop(job_id)
        pcm = self.s16()
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, len(pcm))
        self.relay.abort_receive(job_id)
        self.assertEqual(self.relay.result(job_id)['state'], 'stopping')
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, len(pcm))
        self.assertEqual(self.relay.upload_pcm(job_id, self.agent, pcm)['state'], 'done')

    def test_stalled_binary_upload_expires(self):
        job_id = self.begin(); self.relay.stop(job_id)
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, 32000)
        self.now += 201
        self.assertEqual(self.relay.result(job_id)['state'], 'error')

    def test_binary_upload_validation_and_cancel(self):
        job_id = self.begin()
        for encoding, rate, length in (('f32le', 16000, 32000), ('s16le', 8000, 32000),
                                       ('s16le', 16000, 3), ('s16le', 16000, 10),
                                       ('s16le', 16000, 16000 * 301 * 2)):
            with self.assertRaises(VoiceError):
                self.relay.begin_receive(job_id, self.agent, encoding, rate, length)
        with self.assertRaises(VoiceError):
            self.relay.begin_receive(job_id, 'wrong', 's16le', 16000, 32000)
        self.relay.begin_receive(job_id, self.agent, 's16le', 16000, 32000)
        self.relay.cancel(job_id)
        with self.assertRaises(VoiceError): self.relay.upload_pcm(job_id, self.agent, self.s16())
        self.assertEqual(self.relay.result(job_id)['state'], 'cancelled')

    def test_asr_failure_is_recoverable(self):
        job_id = self.begin()
        def fail(*args): raise ConnectionError('private implementation detail')
        self.asr.transcribe = fail
        result = self.relay.upload(self.payload(job_id))
        self.assertEqual(result['state'], 'error')
        self.assertNotIn('private', result['error'])


class FakePreview:
    def __init__(self): self.sessions = []
    def session(self):
        preview = self
        class Session:
            def __init__(self): self.fed = b''; preview.sessions.append(self)
            def feed(self, pcm):
                self.fed += pcm
                return f'草稿{len(self.fed)}'
        return Session()


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.now = 100
        self.asr = FakeASR()
        self.preview = FakePreview()
        self.relay = VoiceRelay(DemoEngine(), self.asr, clock=lambda: self.now, preview=self.preview)
        self.agent = 'test-phone-agent-id'
        self.relay.agent(self.agent)
        self.job_id = self.relay.start()['id']
        self.relay.ack(self.job_id, self.agent)

    def chunk(self, offset, pcm):
        return self.relay.append_chunk(self.job_id, self.agent, offset, pcm)

    def test_status_advertises_streaming(self):
        status = self.relay.status()
        self.assertTrue(status['audio_stream_v1']); self.assertTrue(status['live_preview'])
        self.assertFalse(VoiceRelay(DemoEngine(), self.asr).status()['live_preview'])

    def test_chunks_give_partial_and_finish_without_upload(self):
        pcm = struct.pack('<h', 3277) * 16000
        first = self.chunk(0, pcm[:16000])
        self.assertEqual((first['received'], first['partial']), (16000, '草稿16000'))
        self.chunk(16000, pcm[16000:])
        self.assertEqual(self.relay.result(self.job_id)['partial'], '草稿32000')
        self.relay.stop(self.job_id)
        result = self.relay.finish_stream(self.job_id, self.agent, len(pcm))
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['text'], 'CapsWriter')
        self.assertEqual(len(self.asr.pcm), len(pcm) * 2)
        self.assertAlmostEqual(struct.unpack('<f', self.asr.pcm[:4])[0], 3277 / 32768, places=5)
        self.assertEqual(self.relay.audio, bytearray())
        self.assertEqual(self.relay.consume(self.job_id)['partial'], '')

    def test_duplicate_overlap_and_gap_are_reported_by_received(self):
        self.chunk(0, b'\x01\x00' * 100)
        self.assertEqual(self.chunk(0, b'\x01\x00' * 100)['received'], 200)  # resent
        self.assertEqual(self.chunk(100, b'\x02\x00' * 100)['received'], 300)  # overlap
        self.assertEqual(self.chunk(1000, b'\x03\x00' * 10)['received'], 300)  # gap: resend from 300
        self.assertEqual(self.preview.sessions[0].fed, b'\x01\x00' * 100 + b'\x02\x00' * 50)

    def test_incomplete_stream_falls_back_to_whole_upload(self):
        self.chunk(0, b'\x00\x00' * 16000)
        self.relay.stop(self.job_id)
        with self.assertRaisesRegex(VoiceError, '不完整'):
            self.relay.finish_stream(self.job_id, self.agent, 64000)
        self.assertEqual(self.relay.result(self.job_id)['state'], 'stopping')
        pcm = b'\x00\x00' * 32000
        self.relay.begin_receive(self.job_id, self.agent, 's16le', 16000, len(pcm))
        self.assertEqual(self.relay.upload_pcm(self.job_id, self.agent, pcm)['state'], 'done')

    def test_chunk_validation_and_state(self):
        for offset, pcm in ((-2, b'\x00\x00'), (1, b'\x00\x00'), (0, b'\x00'),
                            ('0', b'\x00\x00'), (0, b'\x00' * (16000 * 2 * 10 + 2))):
            with self.assertRaises(VoiceError): self.chunk(offset, pcm)
        with self.assertRaises(VoiceError):
            self.relay.append_chunk(self.job_id, 'wrong', 0, b'\x00\x00')
        self.relay.cancel(self.job_id)
        with self.assertRaises(VoiceError): self.chunk(0, b'\x00\x00')
        self.assertEqual(self.relay.result(self.job_id)['partial'], '')
        self.assertEqual(self.relay.audio, bytearray())

    def test_chunks_keep_job_alive_without_heartbeats(self):
        for index in range(10):
            self.now += 5
            self.chunk(index * 16000, b'\x00\x00' * 8000)
        self.assertEqual(self.relay.result(self.job_id)['state'], 'recording')

    def test_preview_failure_does_not_break_recording(self):
        def boom(pcm): raise RuntimeError('model crashed')
        self.preview.sessions[0].feed = boom
        self.assertEqual(self.chunk(0, b'\x00\x00' * 8000)['received'], 16000)
        self.relay.stop(self.job_id)
        self.assertEqual(self.relay.finish_stream(self.job_id, self.agent, 16000)['state'], 'done')

    def test_new_recording_starts_with_empty_buffer(self):
        self.chunk(0, b'\x00\x00' * 8000)
        self.relay.cancel(self.job_id)
        job = self.relay.start()
        self.assertEqual((job['received'], job['partial']), (0, ''))
        self.assertEqual(len(self.preview.sessions), 2)


class SentencePreview:
    """Ends an utterance every `every` bytes of audio, like a pause."""
    def __init__(self, every): self.every, self.sessions = every, []
    def session(self):
        preview = self
        class Session:
            def __init__(self):
                self.fed, self.utterances, self.current = 0, [], ''
                preview.sessions.append(self)
            def feed(self, pcm):
                self.fed += len(pcm) // 2
                self.current = f'说{len(self.utterances)}'
                if self.fed * 2 % preview.every == 0:
                    self.utterances.append((self.fed, self.current)); self.current = ''
                return 'ignored'
        return Session()


class SentenceASR:
    def __init__(self): self.calls, self.gate = [], threading.Event(); self.gate.set()
    def available(self): return True
    def transcribe(self, pcm, task_id):
        self.gate.wait(5)
        self.calls.append((task_id, len(pcm)))
        return '整段' if task_id.count('-') == 0 else f'第{len(self.calls)}句。'


class SentencePipelineTests(unittest.TestCase):
    def setUp(self):
        self.asr = SentenceASR()
        self.relay = VoiceRelay(DemoEngine(), self.asr, preview=SentencePreview(32000))
        self.agent = 'test-phone-agent-id'
        self.relay.agent(self.agent)
        self.job_id = self.relay.start()['id']
        self.relay.ack(self.job_id, self.agent)

    def chunk(self, offset, pcm):
        return self.relay.append_chunk(self.job_id, self.agent, offset, pcm)

    def wait_for(self, predicate):
        for _ in range(200):
            if predicate(): return
            threading.Event().wait(.01)
        self.fail('timed out')

    def test_sentences_show_while_recording_but_final_text_is_whole_recording(self):
        second = b'\x10\x00' * 16000
        self.chunk(0, second)
        self.wait_for(lambda: self.relay.sentences.display('') == '第1句。')
        partial = self.chunk(32000, second[:16000])['partial']
        self.assertEqual(partial, '第1句。说1')
        self.chunk(48000, second[16000:])
        self.chunk(64000, second[:16000])  # a short tail after the last pause
        self.relay.stop(self.job_id)
        result = self.relay.finish_stream(self.job_id, self.agent, 80000)
        self.assertEqual(result['state'], 'done')
        # Pause marks can split a word, so the sentence texts are never joined
        # into the result: the whole recording is recognized once more.
        self.assertEqual(result['text'], '整段')
        ids = [task for task, _ in self.asr.calls]
        self.assertEqual(ids[-1], self.job_id)
        self.assertNotIn(f'{self.job_id}-tail', ids)
        # float32 audio: twice the int16 size of all 2.5 s.
        self.assertEqual(self.asr.calls[-1][1], 160000)

    def test_pending_sentences_are_skipped_after_stop(self):
        from sentences import SentencePipeline
        gate, seen = threading.Event(), []
        def recognize(pcm, index):
            seen.append(index); gate.wait(5); return '句'
        pipeline = SentencePipeline(recognize, lambda raw: raw)
        pcm = b'\x10\x00' * 16000
        pipeline.add(32000, pcm, '一')
        pipeline.add(64000, pcm, '二')
        self.wait_for(lambda: seen == [0])
        pipeline.abandon()
        gate.set()
        pipeline.thread.join(2)
        self.assertFalse(pipeline.thread.is_alive())
        self.assertEqual(seen, [0])

    def test_draft_shows_until_sentence_is_recognized(self):
        self.asr.gate.clear()
        partial = self.chunk(0, b'\x10\x00' * 16000)['partial']
        self.assertEqual(partial, '说0')
        self.asr.gate.set()

    def test_failed_sentence_falls_back_to_whole_recording(self):
        calls = []
        def transcribe(pcm, task_id):
            calls.append(task_id)
            if task_id.endswith('-s0'): raise ConnectionError('busy')
            return '整段'
        self.asr.transcribe = transcribe
        self.chunk(0, b'\x10\x00' * 16000)
        self.relay.stop(self.job_id)
        result = self.relay.finish_stream(self.job_id, self.agent, 32000)
        self.assertEqual(result['text'], '整段')
        self.assertEqual(calls[-1], self.job_id)

    def test_cancel_abandons_pipeline(self):
        self.chunk(0, b'\x10\x00' * 16000)
        pipeline = self.relay.sentences
        self.relay.cancel(self.job_id)
        self.relay.result(self.job_id)
        self.assertIsNone(self.relay.sentences)
        self.assertTrue(pipeline.finishing)

    def test_switch_off_keeps_old_behavior(self):
        relay = VoiceRelay(DemoEngine(), self.asr, preview=SentencePreview(32000), sentences=False)
        relay.agent(self.agent)
        job_id = relay.start()['id']; relay.ack(job_id, self.agent)
        self.assertIsNone(relay.sentences)


class JoinTextTests(unittest.TestCase):
    def test_join(self):
        from sentences import join_text
        self.assertEqual(join_text(['你好。', '', '再见。']), '你好。再见。')
        self.assertEqual(join_text(['Hello.', 'World']), 'Hello. World')
        self.assertEqual(join_text(['我说', 'OK']), '我说OK')


class VoiceHTTPTests(unittest.TestCase):
    def test_authenticated_phone_to_desktop_roundtrip(self):
        relay = VoiceRelay(DemoEngine(), FakeASR())
        server = ThreadingHTTPServer(('127.0.0.1', 0), make_handler(DemoEngine(), 'test-token', relay))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def request(path, value=None, token='test-token'):
            req = Request(f'http://127.0.0.1:{server.server_port}' + path,
                          json.dumps(value).encode() if value is not None else None,
                          {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            try:
                with urlopen(req, timeout=5) as response: return response.status, json.load(response)
            except HTTPError as response: return response.code, json.load(response)
        try:
            self.assertEqual(request('/v1/voice/start', {}, 'wrong')[0], 401)
            self.assertEqual(request('/v1/voice/agent', {'agent_id': 'http-test-phone-id'})[0], 200)
            code, job = request('/v1/voice/start', {}); self.assertEqual(code, 200)
            job_id = job['id']
            self.assertEqual(request('/v1/voice/ack', {'id': job_id, 'agent_id': 'http-test-phone-id'})[1]['state'], 'recording')
            request('/v1/voice/stop', {'id': job_id})
            result = request('/v1/voice/audio', dict(id=job_id, agent_id='http-test-phone-id',
                sample_rate=16000, encoding='f32le', audio=base64.b64encode(struct.pack('<f', 0) * 4000).decode()))
            self.assertEqual(result[1]['text'], 'CapsWriter')
            self.assertEqual(request('/v1/voice/result?id=' + job_id)[1]['state'], 'done')
            self.assertTrue(request('/v1/status')[1]['phone_asr_v1'])
            self.assertTrue(request('/v1/status')[1]['audio_s16_v1'])
            request('/v1/voice/consume', {'id': job_id})
            code, binary_job = request('/v1/voice/start', {}); self.assertEqual(code, 200)
            binary_id = binary_job['id']
            request('/v1/voice/ack', {'id': binary_id, 'agent_id': 'http-test-phone-id'})
            request('/v1/voice/stop', {'id': binary_id})
            def binary(query, body, token='test-token'):
                req = Request(f'http://127.0.0.1:{server.server_port}/v1/voice/audio?' + query, body,
                              {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/octet-stream'})
                try:
                    with urlopen(req, timeout=5) as response: return response.status, json.load(response)
                except HTTPError as response: return response.code, json.load(response)
            query = f'id={binary_id}&agent_id=http-test-phone-id&encoding=s16le&sample_rate=16000'
            pcm = struct.pack('<h', 0) * 16000
            self.assertEqual(binary(query, pcm, 'wrong')[0], 401)
            self.assertEqual(binary(query.replace('s16le', 'f32le'), pcm)[0], 400)
            code, value = binary(query, pcm)
            self.assertEqual((code, value['text']), (200, 'CapsWriter'))
            job_id = binary_id
            request('/v1/voice/consume', {'id': job_id})
            code, phone_job = request('/v1/voice/start', {}); self.assertEqual(code, 200)
            phone_id = phone_job['id']
            request('/v1/voice/ack', {'id': phone_id, 'agent_id': 'http-test-phone-id'})
            phone_value = dict(id=phone_id, agent_id='http-test-phone-id', text='卡普斯赖特')
            self.assertEqual(request('/v1/voice/text', phone_value, 'wrong')[0], 401)
            self.assertEqual(request('/v1/voice/text', phone_value)[1]['text'], 'CapsWriter')
            self.assertEqual(request('/v1/voice/text', phone_value)[0], 409)
            request('/v1/voice/consume', {'id': phone_id})
            self.assertTrue(request('/v1/status')[1]['audio_stream_v1'])
            code, stream_job = request('/v1/voice/start', {}); self.assertEqual(code, 200)
            stream_id = stream_job['id']
            request('/v1/voice/ack', {'id': stream_id, 'agent_id': 'http-test-phone-id'})
            def chunk(offset, body, token='test-token'):
                req = Request(f'http://127.0.0.1:{server.server_port}/v1/voice/chunk?id={stream_id}'
                              f'&agent_id=http-test-phone-id&offset={offset}', body,
                              {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/octet-stream'})
                try:
                    with urlopen(req, timeout=5) as response: return response.status, json.load(response)
                except HTTPError as response: return response.code, json.load(response)
            half = struct.pack('<h', 0) * 8000
            self.assertEqual(chunk(0, half, 'wrong')[0], 401)
            self.assertEqual(chunk(0, half)[1]['received'], 16000)
            self.assertEqual(chunk('x', half)[0], 400)
            self.assertEqual(chunk(16000, half)[1]['received'], 32000)
            request('/v1/voice/stop', {'id': stream_id})
            finish = dict(id=stream_id, agent_id='http-test-phone-id', total=40000)
            self.assertEqual(request('/v1/voice/finish', finish)[0], 409)
            finish['total'] = 32000
            code, value = request('/v1/voice/finish', finish)
            self.assertEqual((code, value['text']), (200, 'CapsWriter'))
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_real_websocket_wire_protocol_with_loopback_fixture(self):
        try:
            from websockets.sync.server import serve
        except ImportError:
            self.skipTest('Install bridge/requirements.txt to check the WebSocket transport')
        seen = {}
        def handler(connection):
            combined = bytearray(); packets = 0
            while True:
                value = json.loads(connection.recv()); seen.update(value)
                combined.extend(base64.b64decode(value['data'])); packets += 1
                if value['is_final']: break
            seen['combined'] = bytes(combined); seen['packets'] = packets
            connection.send(json.dumps(dict(task_id='unrelated', is_final=True, text='wrong')))
            connection.send(json.dumps(dict(task_id=value['task_id'], is_final=False, text='partial')))
            connection.send(json.dumps(dict(task_id=value['task_id'], is_final=True, text='final result')))
        with serve(handler, '127.0.0.1', 0, subprotocols=['binary'], max_size=2**22) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                asr = DesktopASR(server.socket.getsockname()[1])
                pcm = struct.pack('<f', .25) * (16000 * 65)
                self.assertEqual(asr.transcribe(pcm, 'task-protocol'), 'final result')
                self.assertEqual(seen['combined'], pcm)
                self.assertGreater(seen['packets'], 4)
                self.assertEqual(seen['source'], 'mic')
                self.assertTrue(seen['is_final'])
                self.assertEqual(seen['seg_overlap'], 4)
            finally:
                server.shutdown(); thread.join()


if __name__ == '__main__': unittest.main()
