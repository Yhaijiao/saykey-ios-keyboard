from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup import Cleaner, Rules, parse
from engine import DemoEngine


class RuleTests(unittest.TestCase):
    def check(self, cases, rules=None):
        rules = rules or Rules()
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(rules.clean(source), expected)

    def test_fillers_are_removed(self):
        self.check([
            ('嗯，我想去吃饭。', '我想去吃饭。'),
            ('我想，嗯，去吃饭。', '我想，去吃饭。'),
            ('我想嗯去吃饭', '我想去吃饭'),
            ('呃呃呃这个方案不错', '这个方案不错'),
            ('好的，嗯。', '好的。'),
            ('好的，嗯', '好的'),
            ('好的。嗯。明天见。', '好的。明天见。'),
            ('好的。嗯，然后我们走吧。', '好的。然后我们走吧。'),
            ('那个，我想问一下。', '我想问一下。'),
            ('我觉得，那个，可以试试。', '我觉得，可以试试。'),
            ('啊，对了，明天开会。', '对了，明天开会。'),
            ('就是，嗯，我不太确定。', '我不太确定。'),
            ('Um, I think we should go.', 'I think we should go.'),
            ('I think uh we should go', 'I think we should go'),
        ])

    def test_trailing_english_ack_after_chinese_is_dropped(self):
        self.check([
            ('上一句话就可以看见有一个问题。Yeah.', '上一句话就可以看见有一个问题。'),
            ('我们明天开会，yes', '我们明天开会。'),
            ('我们明天开会Yeah。', '我们明天开会。'),
            ('好的。Yep!', '好的。'),
            # Kept: an English sentence, a meaningful yes, a mid-text yeah.
            ('Yes, we can do it. Yeah.', 'Yes, we can do it. Yeah.'),
            ('答案是yes。', '答案是yes。'),
            ('Yeah，我觉得可以。', 'Yeah，我觉得可以。'),
        ])

    def test_normal_words_survive(self):
        unchanged = [
            '我要那个。', '那个人是谁？', '把那个给我，谢谢。', '这个，那个，还有那个都要。',
            '好啊，没问题。', '是啊。', '金额是多少？', '额外的费用', '就是这样。', '哦，好的。',
            'The umbrella is under the hut.', '版本 v0.4.21，价格 3.5 元，共 1,000 个。',
            '哪个？那个。', '然后，我们出发。',
        ]
        self.check([(text, text) for text in unchanged])

    def test_stutters_and_repeats_collapse(self):
        self.check([
            ('我我我想去', '我想去'),
            ('这这个不行', '这个不行'),
            ('我嗯我觉得可以', '我觉得可以'),
            ('然后然后我们就走了', '然后我们就走了'),
            ('那个那个那个文件在哪', '那个文件在哪'),
            ('比如比如说今天', '比如说今天'),
            ('我今天我今天去了公司', '我今天去了公司'),
            ('我们可以我们可以先试一下', '我们可以先试一下'),
        ])

    def test_real_reduplication_survives(self):
        unchanged = [
            '看看', '谢谢你', '妈妈说常常想想', '我们研究研究，讨论讨论。', '休息休息', '哈哈哈哈哈哈',
            '谢谢谢谢谢谢', '一步一步来', '一个人一个人地进', '实实在在', '明明白白', '很多很多年以前',
            '对对对', '好好好', '2020 年 1212 号', '三十三十三', '非常非常好', '加油加油',
        ]
        self.check([(text, text) for text in unchanged])

    def test_only_fillers_keeps_original(self):
        self.check([('嗯', '嗯'), ('嗯。', '嗯。'), ('呃，嗯。', '呃，嗯。'), ('', ''), ('  ', '  ')])

    def test_punctuation_is_preserved(self):
        self.check([
            ('今天天气不错，我们去公园吧！你觉得呢？', '今天天气不错，我们去公园吧！你觉得呢？'),
            ('第一，嗯，要准时；第二，呃，要带电脑。', '第1，要准时；第2，要带电脑。'),
            ('他说：“嗯，可以。”', '他说：“可以。”'),
        ])

    def test_arabic_numbers_p1(self):
        # All P1 examples from docs/从CapsWriter移植的语音优化.md.
        self.check([
            ('第一，Q一，Q二，功能添加三', '第1，Q1，Q2，功能添加3'),
            ('三版方案', '3版方案'),
            ('十月二十二', '10月22'),
            ('二和3、两到3期', '2和3、2到3期'),
            ('第一时间、第三方、安全第一', '第一时间、第三方、安全第一'),
            ('独一无二、接二连三、乱七八糟', '独一无二、接二连三、乱七八糟'),
            ('进一步、一张嘴', '进一步、一张嘴'),
            # Additional safe boundary cases.
            ('十二月五号开会', '12月5号开会'),
            ('3到五轮测试', '3到5轮测试'),
            ('周一和星期三见', '周一和星期三见'),
        ])
        self.assertEqual(Rules(parse('arabic_numbers = off')).clean('第一，Q一，三版方案'), '第一，Q一，三版方案')

    def test_switches_and_custom_lists(self):
        self.assertEqual(Rules(parse('enabled = off')).clean('嗯，我我想'), '嗯，我我想')
        self.assertEqual(Rules(parse('repeat_phrases = off')).clean('我今天我今天去'), '我今天我今天去')
        self.assertEqual(Rules(parse('fillers_anywhere = 嗯、呃，唉')).clean('唉我知道了'), '我知道了')
        self.assertEqual(Rules(parse('fillers_alone =\nstutter_chars =\nrepeat_words =')).clean('那个，我我然后然后'),
                         '那个，我我然后然后')
        # Unknown names, comments and broken lines never raise.
        self.assertEqual(Rules(parse('# note\nwhat = ever\nbroken line\nenabled ＝ on')).clean('嗯好'), '好')
        # Regex metacharacters in a user word are treated literally.
        self.assertEqual(Rules(parse('fillers_anywhere = ( [ .* +')).clean('嗯好'), '嗯好')

    def test_capswriter_acceptance_cases(self):
        # All 10 acceptance examples from docs/从CapsWriter移植的语音优化.md.
        self.check([
            ('嗯，我我我觉得这个这个方案呃还可以', '我觉得这个方案还可以'),
            ('额，就是，就是我们先测试一下', '就是我们先测试一下'),
            ('这个额度够不够啊', '这个额度够不够啊'),
            ('好啊，对对对，没问题', '好啊，对对对，没问题'),
            ('是是是不是要先检查检查', '是不是要先检查检查'),
            ('我想想想再说', '我想再说'),
            ('功能能不能用', '功能能不能用'),
            ('其他他们都来了', '其他他们都来了'),
            ('仅仅仅仅是这样', '仅仅是这样'),
            ('um I I think the the plan works', 'I think the plan works'),
        ])

    def test_extended_stutter_and_filler_edges(self):
        self.check([
            # Extra English fillers and English repeat whitelist.
            ('Uhm, erm, let us go.', 'let us go.'),
            ('It is very very good, no no really really!', 'It is very very good, no no really really!'),
            ('I had had that that book', 'I had had that that book'),
            # Protected two-char prefixes before stutter chars.
            ('这个目的的含义', '这个目的的含义'),
            ('成都都下雨了', '成都都下雨了'),
            ('一把把椅子', '一把把椅子'),
            # Positive-negative question stutter vs normal phrasing.
            ('需要要不要改', '需要要不要改'),
            ('是是不是这样', '是不是这样'),
            ('对了，能能不能行', '对了，能不能行'),
            # Double-character words collapse 3+ to 2.
            ('刚刚刚刚说完', '刚刚说完'),
            # Comma-separated catchphrases and 3-10 char clauses (digits preserved).
            ('然后，然后我们就出发', '然后我们就出发'),
            ('我觉得，我觉得方案不错', '我觉得方案不错'),
            ('今天下午，今天下午开会', '今天下午开会'),
            ('第1版，第1版先发', '第1版，第1版先发'),
            ('一二三，一二三开始', '一二三，一二三开始'),
            # Standalone 额/啊 before 顿号 or at sentence end.
            ('额、好的', '好的'),
            ('好的，额', '好的'),
            # ABAB reduplication whitelist vs stuttered 2-char words.
            ('先确认确认再说', '先确认确认再说'),
            ('方案方案定了', '方案定了'),
        ])

    def test_long_text_is_fast(self):
        import time
        text = '然后我们今天去了公司，开了一个很长的会。' * 1000
        started = time.perf_counter()
        self.assertEqual(Rules().clean(text), text)
        self.assertLess(time.perf_counter() - started, 1.0)


class CleanerFileTests(unittest.TestCase):
    def test_file_is_created_and_reloaded_without_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'speech-cleanup.txt'
            cleaner = Cleaner(path, create=True)
            self.assertTrue(path.is_file())
            self.assertEqual(cleaner.clean('嗯，好的'), '好的')
            path.write_text('enabled = off\n', encoding='utf-8')
            os.utime(path, ns=(1, 1))
            self.assertEqual(cleaner.clean('嗯，好的'), '嗯，好的')
            self.assertFalse(cleaner.status()['enabled'])
            path.unlink()  # A deleted file falls back to the built-in defaults.
            self.assertEqual(cleaner.clean('嗯，好的'), '好的')

    def test_unreadable_file_keeps_working(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'speech-cleanup.txt'
            path.write_bytes(b'\xff\xfe\xff broken')
            self.assertEqual(Cleaner(path).clean('嗯，好的'), '好的')

    def test_engine_cleans_before_correction(self):
        engine = DemoEngine()
        self.assertEqual(engine.correct('嗯，卡普斯赖特').text, '嗯，CapsWriter')
        engine.cleaner = Cleaner()
        self.assertEqual(engine.correct('嗯，卡普斯赖特').text, 'CapsWriter')


if __name__ == '__main__':
    unittest.main()
