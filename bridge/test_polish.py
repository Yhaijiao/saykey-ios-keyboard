import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import URLError

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup import Cleaner
from engine import DemoEngine
from polish import PolishConfig, Polisher, parse


class PolishTests(unittest.TestCase):
    def test_rejects_non_loopback_endpoints(self):
        self.assertEqual(PolishConfig(parse('endpoint = https://example.com')).endpoint, '')
        self.assertEqual(PolishConfig(parse('endpoint = http://192.168.1.5:11434')).endpoint, '')
        self.assertEqual(PolishConfig(parse('endpoint = http://127.0.0.1:11434/')).endpoint, 'http://127.0.0.1:11434')
        self.assertEqual(PolishConfig(parse('endpoint = http://localhost:11434')).endpoint, 'http://localhost:11434')

    def test_sends_keep_alive_and_think_off_and_strips_think_tags(self):
        seen = []
        logs = io.StringIO()

        def transport(url, payload, timeout):
            seen.append((url, payload, timeout))
            return {
                'response': '<think>internal</think>我觉得这个方案还可以，明天开始测试吧。',
                'eval_count': 20,
                'eval_duration': 200_000_000,  # 0.01s/char
            }

        polisher = Polisher(transport=transport, log_stream=logs)
        result = polisher.polish('我觉得这个方案还可以明天开始测试吧')
        self.assertEqual(result, '我觉得这个方案还可以，明天开始测试吧。')
        self.assertEqual(len(seen), 1)
        url, payload, timeout = seen[0]
        self.assertEqual(url, 'http://127.0.0.1:11434/api/generate')
        self.assertEqual(payload['keep_alive'], '10m')
        self.assertIs(payload['think'], False)
        self.assertEqual(timeout, 4.0)
        # Logs contain metrics only, never user text.
        self.assertIn('status=ok', logs.getvalue())
        self.assertNotIn('方案', logs.getvalue())
        self.assertNotIn('WARNING', logs.getvalue())

    def test_paragraph_pass_gets_split_hint_and_longer_timeout(self):
        seen = []
        def transport(url, payload, timeout):
            seen.append((payload['system'], timeout))
            return {'response': payload['prompt']}
        polisher = Polisher(transport=transport, log_stream=io.StringIO())
        long_text = '今天我们讨论一下项目进度' * 20
        polisher.polish(long_text, paragraph=True)
        polisher.polish('我觉得这个方案还可以明天开始测试吧', paragraph=True)
        polisher.polish(long_text)
        (long_system, long_timeout), (short_system, short_timeout), (plain_system, plain_timeout) = seen
        self.assertIn('分段', long_system); self.assertGreater(long_timeout, 4.0)
        self.assertNotIn('分段', short_system); self.assertEqual(short_timeout, 4.0)
        self.assertNotIn('分段', plain_system); self.assertEqual(plain_timeout, 4.0)

    def test_short_utterances_skip_llm(self):
        called = False

        def transport(url, payload, timeout):
            nonlocal called
            called = True
            return {'response': '好的。'}

        polisher = Polisher(transport=transport, log_stream=io.StringIO())
        self.assertEqual(polisher.polish('好的没问题'), '好的没问题')
        self.assertFalse(called)

    def test_guardrail_rejects_mangled_symbols_or_numbers(self):
        def mangle(url, payload, timeout):
            return {'response': '这个方案加号一，问一已经完成了。'}

        polisher = Polisher(transport=mangle, log_stream=io.StringIO())
        source = '这个方案 +1，Q1 已经完成了'
        self.assertEqual(polisher.polish(source), source)
        self.assertEqual(polisher.status()['last']['status'], 'rejected')

    def test_slow_generation_logs_warning_without_user_text(self):
        logs = io.StringIO()

        def slow_transport(url, payload, timeout):
            return {
                'response': '我觉得这个方案还可以，明天开始测试吧。',
                'eval_count': 10,
                'eval_duration': 2_000_000_000,  # 0.20s/char > 0.05s/char
            }

        polisher = Polisher(transport=slow_transport, log_stream=logs)
        polisher.polish('我觉得这个方案还可以明天开始测试吧')
        output = logs.getvalue()
        self.assertIn('WARNING slow generation', output)
        self.assertNotIn('方案', output)
        self.assertTrue(polisher.status()['last']['slow'])

    def test_connection_failure_falls_back_and_enters_cooldown(self):
        calls = 0
        now = [100.0]

        def failing(url, payload, timeout):
            nonlocal calls
            calls += 1
            raise URLError('connection refused')

        polisher = Polisher(transport=failing, clock=lambda: now[0], log_stream=io.StringIO())
        source = '我觉得这个方案还可以明天开始测试吧'
        self.assertEqual(polisher.polish(source), source)
        self.assertEqual(calls, 1)
        # Within 30s cooldown, Ollama is skipped immediately.
        now[0] = 110.0
        self.assertEqual(polisher.polish(source), source)
        self.assertEqual(calls, 1)
        # After cooldown expires, it retries.
        now[0] = 135.0
        self.assertEqual(polisher.polish(source), source)
        self.assertEqual(calls, 2)

    def test_file_hot_reload_and_engine_pipeline(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'llm-polish.txt'
            polisher = Polisher(
                path, create=True,
                transport=lambda u, p, t: {'response': p['prompt'] + '。', 'eval_count': 10, 'eval_duration': 100_000_000},
                log_stream=io.StringIO(),
            )
            self.assertTrue(path.is_file())
            engine = DemoEngine()
            engine.cleaner = Cleaner()
            engine.polisher = polisher
            self.assertEqual(engine.correct('嗯，卡普斯赖特今天下午开会讨论方案').text, 'CapsWriter今天下午开会讨论方案。')
            path.write_text('enabled = off\n', encoding='utf-8')
            os.utime(path, ns=(1, 1))
            self.assertEqual(engine.correct('嗯，卡普斯赖特今天下午开会讨论方案').text, 'CapsWriter今天下午开会讨论方案')


if __name__ == '__main__':
    unittest.main()
