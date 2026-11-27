"""Rule-based speech cleanup: drop filler words and stuttered repeats.

Pure string rules, no model and no network, so it adds no measurable delay.
Every rule is deliberately narrow; when in doubt the text is left unchanged.
The word lists live in a small text file that is re-read when it changes.
"""
from __future__ import annotations
from pathlib import Path
import re
import threading

FILE_NAME = 'speech-cleanup.txt'
DEFAULTS = {
    'enabled': 'on',
    # Removed wherever they appear. Only sounds that are never part of a word.
    'fillers_anywhere': '嗯 呃 um uh uhm erm',
    # Removed only as a whole clause before a comma: "那个，我想问" -> "我想问".
    # "我要那个" and "好啊" are never touched.
    'fillers_alone': '啊 额 那个 这个 就是 就是说',
    # "然后然后去" -> "然后去". Words whose doubling is never intended.
    'repeat_words': ('然后 那个 这个 就是 就是说 我们 你们 他们 因为 所以 但是 如果 '
                     '还有 或者 而且 不过 其实 比如 比如说 我说 我觉得 我想 可以 应该 可能 现在'),
    # "我我我想" -> "我想". Single characters that never double in real words.
    'stutter_chars': '我 你 他 她 它 这 那 不 就 的 也 都 还 把 给 跟 再 没 但 挺 很',
    # "我今天我今天去" -> "我今天去": any 2-8 character phrase said twice in a row.
    'repeat_phrases': 'on',
    # "第一，Q一，三版方案" -> "第1，Q1，3版方案" (on / off).
    'arabic_numbers': 'on',
}
TEMPLATE = '''# SayKey 语音清理规则（删语气词、删重复词）
# 改完保存即可，下一句话就生效，不用重启桥接。
# 每行格式：名称 = 内容；词与词之间用空格隔开；# 开头的行是说明。
# 想恢复默认：删掉这个文件，重启桥接会重新生成。

# 总开关：on 开启，off 关闭（关闭后完全不改动识别结果）
enabled = {enabled}

# 出现在任何位置都删掉（只放绝不会是正常词一部分的语气词）
fillers_anywhere = {fillers_anywhere}

# 只有单独成一小句、后面跟逗号时才删掉
# 例：「那个，我想问一下」变成「我想问一下」；「我要那个」「好啊」不会动
fillers_alone = {fillers_alone}

# 连着说了两遍以上时只留一遍。例：「然后然后我们」变成「然后我们」
repeat_words = {repeat_words}

# 口吃的单字，连着重复时只留一个。例：「我我我想」变成「我想」
# 不要放「看、谢、妈」这类本来就会叠用的字
stutter_chars = {stutter_chars}

# 3 到 8 个字的短语连着说两遍时只留一遍（on / off）
# 例：「我今天我今天去了」变成「我今天去了」；「一步一步」这类以「一」开头的不会动
repeat_phrases = {repeat_phrases}

# 中文数字转阿拉伯数字（on / off）
# 例：「第一，Q一，三版方案」变成「第1，Q1，3版方案」；成语和「第一时间」「进一步」不动
arabic_numbers = {arabic_numbers}
'''

CJK = '一-鿿'
SOFT = '，,'                        # pauses inside a sentence
ALONE_END_FILLERS = {'啊', '额'}    # may also be dropped alone before '、' or at sentence end
POINTERS = ('这个', '那个')
OPENERS = set('“‘"\'（(《「『【[ ')
PUNCT = SOFT + '、。．.！!？?；;：:…—~～'
NUMERALS = set('零〇一二三四五六七八九十百千万亿两幺')
_HAS_DIGIT_OR_NUMERAL = re.compile(r'[0-9零〇一二三四五六七八九十百千万亿两幺]')
_SPLIT = re.compile('([' + re.escape(PUNCT) + r']+\s*)')
_PHRASE_3_8 = re.compile('([' + CJK + r']{3,8}?)\1+')
_PHRASE_2_8 = re.compile('([' + CJK + r']{2,8}?)\1+')

# Two-character words whose second character is in `stutter_chars` and can
# naturally precede the same character: "其他他们", "目的的", "成都都", "一把把".
PROTECTED_STUTTER_PREFIXES = {
    '其他', '利他', '排他', '吉他',
    '目的', '标的',
    '成都', '首都', '古都', '京都', '魔都', '帝都', '大都',
    '一把', '大把', '几把', '手把', '门把', '车把', '拖把', '扫把', '火把',
    '成就', '造就', '迁就', '将就',
    '归还', '偿还', '退还', '返还', '生还',
    '供给', '补给', '配给', '自给',
    '脚跟', '鞋跟', '高跟', '后跟',
    '淹没', '沉没', '埋没', '出没', '隐没', '覆没', '吞没',
}

# Characters that naturally form AA words ("仅仅", "刚刚"): 3+ copies collapse to 2.
DOUBLE_WORD_CHARS = '仅刚常渐稍偏恰悄默'
_DOUBLE_WORD_STUTTER = re.compile('([' + DOUBLE_WORD_CHARS + r'])\1{2,}')

# Characters whose 3+ repetition is normal tone ("对对对", "哈哈哈", "谢谢谢谢谢谢").
TONE_REPEAT_CHARS = set('对好行是哈嘿呵嘻嗯啊哦噢喔来走快慢谁叉点某等谢')
_TRIPLE_CHAR = re.compile('([' + CJK + r'])\1{2,}')

# Positive-negative question stutter: "是是是不是" -> "是不是".
# When only one extra character precedes X不X/X没X, strip only at clause start so
# "功能能不能" and "需要要不要" stay intact.
_ALT_QUESTION_STUTTER = re.compile('([' + CJK + r'])\1+([不没])\1')

# Catchphrases that often repeat across a comma: "就是，就是我们先测试一下".
COMMA_REPEAT_CATCHPHRASES = (
    '比如说', '就是说', '我觉得', '就是', '这个', '那个', '然后', '所以', '因为',
    '但是', '如果', '还有', '比如', '我们', '你们', '他们', '我说', '我想',
)

# Common two-character words that naturally reduplicate (ABAB) and must not be collapsed.
ABAB_WHITELIST = {
    '检查', '讨论', '确认', '研究', '休息', '考虑', '商量', '沟通', '了解', '学习',
    '练习', '准备', '整理', '清理', '打扫', '收拾', '活动', '放松', '体验', '感受',
    '品尝', '欣赏', '观察', '分析', '比较', '核对', '排查', '测试', '验证', '试探',
    '打听', '询问', '交流', '联系', '配合', '协作', '调整', '修改', '优化', '改进',
    '完善', '补充', '总结', '复习', '回顾', '思考', '琢磨', '冷静', '克制', '注意',
    '小心', '体谅', '照顾', '支持', '鼓励', '庆祝', '纪念', '感谢', '谢谢', '抱歉',
    '辛苦', '麻烦', '客气', '热闹', '开心', '高兴', '舒服', '凉快', '暖和', '清楚',
    '明白', '简单', '轻松', '愉快', '顺便', '随便', '慢慢', '好好', '早早', '快快',
    '轻轻', '悄悄', '多多', '少少', '非常', '特别', '相当', '超级', '十分', '很多',
    '好多', '不少', '各种', '各个', '每次', '每天', '加油', '努力', '保重', '平安',
    '顺利', '什么', '怎么', '哪里', '多少', '大概', '雪白', '通红', '漆黑', '碧绿',
    '金黄', '笔直', '冰凉', '滚烫', '火热', '粉红',
}

# English words that legitimately repeat ("very very", "no no", "had had").
ENGLISH_REPEAT_WHITELIST = {
    'very', 'so', 'no', 'yeah', 'yes', 'really', 'bye', 'ha', 'haha', 'oh',
    'ok', 'okay', 'well', 'hey', 'hi', 'wow', 'go', 'too', 'much', 'more',
    'far', 'long', 'had', 'that',
}
_ENGLISH_REPEAT = re.compile(r'(?<![A-Za-z0-9])([A-Za-z]+)(?:\s+\1)+(?![A-Za-z0-9])', re.IGNORECASE)

# P1: Chinese-to-Arabic numeral conversion (conservative, high-precision rules).
_CN_DIGITS = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
_CN_UNITS = {'十': 10, '百': 100, '千': 1000}
_CN_NUM = r'[零〇一二两三四五六七八九十百千]+'
_CN_CLASSIFIERS = '版页步轮遍集期章节条项种件本张台部篇句段位名家套份周号级代季档局场回届款组批笔单票'

# Fixed phrases and idioms whose Chinese numerals must never be converted.
_NUM_PROTECTED_PHRASES = (
    '第一时间', '第三方', '第三者', '第三产业', '第三世界', '安全第一', '质量第一',
    '用户第一', '客户第一', '世界第一', '天下第一', '第一手', '第一线', '第一印象',
    '第一眼', '第一反应', '第一志愿', '第一人称', '第二人称', '第三人称', '第二春',
    '第二故乡', '一二把手', '数一数二',
    '独一无二', '接二连三', '乱七八糟', '一五一十', '三心二意', '五颜六色', '七上八下',
    '九牛一毛', '十全十美', '百发百中', '千方百计', '万众一心', '一心一意', '一举两得',
    '一石二鸟', '一分为二', '一清二楚', '一干二净', '一无所有', '一模一样', '一刀两断',
    '一落千丈', '一目十行', '一知半解', '一帆风顺', '一马当先', '一步登天', '三长两短',
    '三言两语', '三番五次', '四面八方', '五湖四海', '五花八门', '六神无主', '七嘴八舌',
    '七零八落', '八仙过海', '九死一生', '十拿九稳', '十万火急', '半斤八两', '不三不四',
    '朝三暮四', '颠三倒四', '丢三落四', '横七竖八', '胡说八道', '举一反三', '说一不二',
    '挑三拣四', '推三阻四', '五光十色', '一朝一夕', '一言一行', '一举一动', '一草一木',
    '一丝一毫', '一板一眼', '进一步', '退一步', '一步一步', '高人一等', '略胜一筹',
    '星期一', '星期二', '星期三', '星期四', '星期五', '星期六',
    '周一', '周二', '周三', '周四', '周五', '周六',
    '礼拜一', '礼拜二', '礼拜三', '礼拜四', '礼拜五', '礼拜六',
)
_NUM_PROTECTED_RE = re.compile('|'.join(re.escape(p) for p in sorted(_NUM_PROTECTED_PHRASES, key=len, reverse=True)))
_NUM_MONTH_DAY_RE = re.compile(r'([一二三四五六七八九十]{1,2})月([一二三四五六七八九十]{1,3})(?=[日号]|$|[^' + CJK + r'])')
_NUM_ORDINAL_RE = re.compile(r'第(' + _CN_NUM + r')')
_NUM_AFTER_LETTER_RE = re.compile(r'(?<=[A-Za-z])(' + _CN_NUM + r')')
_NUM_BEFORE_ARABIC_RE = re.compile(r'(' + _CN_NUM + r')(?=(?:和|到|至|或|与|、|-)\d)')
_NUM_AFTER_ARABIC_RE = re.compile(r'(?<=\d(?:和|到|至|或|与|、|-))(' + _CN_NUM + r')')
_NUM_CLASSIFIER_RE = re.compile(r'(' + _CN_NUM + r')(?=[' + _CN_CLASSIFIERS + r'])')
_NUM_CLAUSE_END_RE = re.compile(r'([二三四五六七八九十百千]+)(?=$|[' + re.escape(PUNCT) + r'\s])')


def _cn_to_int(token):
    """Parse a clean Chinese integer (0..9999); return None if malformed."""
    if not token:
        return None
    if len(token) == 1:
        if token in _CN_DIGITS:
            return _CN_DIGITS[token]
        if token == '十':
            return 10
        return None
    total = 0
    current = None
    last_unit = 10000
    saw_unit = False
    for char in token:
        if char in _CN_DIGITS:
            if current is not None:
                return None  # Reject adjacent digits without units (e.g. "一二三")
            current = _CN_DIGITS[char]
        elif char in _CN_UNITS:
            unit = _CN_UNITS[char]
            if unit >= last_unit:
                return None  # Units must strictly descend (rejects "三十三十三")
            saw_unit = True
            digit = 1 if (current is None and unit == 10 and total == 0) else current
            if digit is None:
                return None
            total += digit * unit
            current = None
            last_unit = unit
        else:
            return None
    if not saw_unit:
        return None
    if current is not None:
        total += current
    return total


def _protected_spans(text):
    return [(m.start(), m.end()) for m in _NUM_PROTECTED_RE.finditer(text)]


def _overlaps(start, end, spans):
    return any(start < s_end and end > s_start for s_start, s_end in spans)


def _convert_arabic_numbers(text):
    """Convert selected Chinese numerals to Arabic digits while sparing idioms."""
    def sub_safe(pattern, replacer, source):
        spans = _protected_spans(source)
        return pattern.sub(lambda m: m.group(0) if _overlaps(m.start(), m.end(), spans) else replacer(m), source)

    def replace_month_day(m):
        month = _cn_to_int(m.group(1))
        day = _cn_to_int(m.group(2))
        if month is None or day is None or not (1 <= month <= 12 and 1 <= day <= 31):
            return m.group(0)
        return f'{month}月{day}'

    def replace_group1(m, prefix='', allow_one=True):
        token = m.group(1)
        if not allow_one and token == '一':
            return m.group(0)
        value = _cn_to_int(token)
        return f'{prefix}{value}' if value is not None else m.group(0)

    text = sub_safe(_NUM_MONTH_DAY_RE, replace_month_day, text)
    text = sub_safe(_NUM_ORDINAL_RE, lambda m: replace_group1(m, prefix='第'), text)
    text = sub_safe(_NUM_AFTER_LETTER_RE, lambda m: replace_group1(m), text)
    text = sub_safe(_NUM_BEFORE_ARABIC_RE, lambda m: replace_group1(m), text)
    text = sub_safe(_NUM_AFTER_ARABIC_RE, lambda m: replace_group1(m), text)
    text = sub_safe(_NUM_CLASSIFIER_RE, lambda m: replace_group1(m, allow_one=False), text)
    text = sub_safe(_NUM_CLAUSE_END_RE, lambda m: replace_group1(m, allow_one=False), text)
    return text


# The desktop model sometimes adds "Yeah." or "Yes." after Chinese speech,
# heard in the trailing silence. Drop it only as the last clause of text that
# is otherwise Chinese, so "Yes, we can" or an English answer stays.
_TRAILING_ACKS = {'yeah', 'yes', 'yep', 'yup', 'yeah yeah', 'uh huh', 'mm hmm'}
_HAS_CJK = re.compile('[' + CJK + ']')


_GLUED_ACK = re.compile('(?<=[' + CJK + r'])\s*(?:yeah|yep|yup)\s*$', re.IGNORECASE)  # not "yes": "答案是yes"


def _drop_trailing_english_ack(kept):
    # The split leaves an empty clause after the final mark.
    while kept and not kept[-1][0].strip() and not kept[-1][1].strip():
        kept = kept[:-1]
    if not kept:
        return kept
    # "我们明天开会Yeah。" with no mark in between.
    glued = _GLUED_ACK.sub('', kept[-1][0])
    if glued != kept[-1][0]:
        kept = kept[:-1] + [[glued, kept[-1][1] or '']]
        return kept
    if len(kept) < 2:
        return kept
    last = re.sub(r'[\s\-]+', ' ', kept[-1][0]).strip().lower()
    if last not in _TRAILING_ACKS:
        return kept
    if not any(_HAS_CJK.search(clause) for clause, _ in kept[:-1]):
        return kept
    kept = kept[:-1]
    punct = kept[-1][1].strip()
    if not punct or punct[0] in SOFT:
        kept[-1][1] = '。'
    return kept


def _on(value):
    return value.strip().lower() not in ('off', 'false', '0', 'no', '关', '关闭')


def parse(source):
    """Read `name = words` lines; unknown names and broken lines are ignored."""
    values = dict(DEFAULTS)
    for line in source.splitlines():
        line = line.split('#', 1)[0].strip()
        if '=' not in line and '＝' not in line:
            continue
        key, _, value = line.replace('＝', '=').partition('=')
        key = key.strip().lower()
        if key in values:
            values[key] = value.replace('，', ' ').replace(',', ' ').replace('、', ' ').strip()
    return values


def _alternation(words):
    return '|'.join(re.escape(word) for word in sorted(set(words), key=len, reverse=True))


class Rules:
    def __init__(self, values=None):
        values = dict(DEFAULTS, **(values or {}))
        self.enabled = _on(values['enabled'])
        anywhere = values['fillers_anywhere'].split()
        cjk = [word for word in anywhere if not word.isascii()]
        ascii_words = [word for word in anywhere if word.isascii()]
        self.filler_cjk = re.compile('(?:' + _alternation(cjk) + ')+') if cjk else None
        # Latin fillers must be whole words: "um" must not eat "umbrella".
        self.filler_ascii = (re.compile(r'(?<![A-Za-z0-9])(?:' + _alternation(ascii_words) + r')(?![A-Za-z0-9])',
                                        re.IGNORECASE) if ascii_words else None)
        self.alone = set(values['fillers_alone'].split())
        words = [word for word in values['repeat_words'].split() if len(word) > 1]
        self.repeat_words = re.compile('(' + _alternation(words) + r')\1+') if words else None
        chars = [char for char in values['stutter_chars'].split() if len(char) == 1]
        self.stutter = re.compile('([' + re.escape(''.join(chars)) + r'])\1+') if chars else None
        self.repeat_phrases = _on(values['repeat_phrases'])
        self.arabic_numbers = _on(values['arabic_numbers'])

    def _phrase(self, match):
        unit = match.group(1)
        # "一步一步" is a real pattern, and spoken numbers or ABAB words may repeat.
        if (unit[0] == '一' or len(set(unit)) == 1
                or unit in ABAB_WHITELIST
                or all(char in NUMERALS for char in unit)):
            return match.group(0)
        return unit

    def _stutter_char(self, text, match):
        char = match.group(1)
        start = match.start()
        if start > 0 and (text[start - 1] + char) in PROTECTED_STUTTER_PREFIXES:
            # Keep the two-character word intact: "其他他们" stays, "其他他他们" -> "其他他们".
            return char * 2
        return char

    def _alt_question(self, text, match):
        char = match.group(1)
        neg = match.group(2)
        run_len = len(match.group(0)) - 2  # number of leading `char`s before 不/没 + char
        if run_len == 2:
            # Only one extra character: strip only at the start of the clause.
            prefix = text[:match.start()]
            if prefix.strip(''.join(OPENERS)):
                return match.group(0)
        return char + neg + char

    def _triple_char(self, match):
        char = match.group(1)
        if char in TONE_REPEAT_CHARS or char in NUMERALS or char in DOUBLE_WORD_CHARS:
            return match.group(0)
        return char

    def _english_repeat(self, match):
        word = match.group(1)
        if word.lower() in ENGLISH_REPEAT_WHITELIST:
            return match.group(0)
        return word

    def _clause(self, text):
        if self.filler_cjk:
            text = self.filler_cjk.sub('', text)
        if self.filler_ascii and self.filler_ascii.search(text):
            cleaned = re.sub(r'\s{2,}', ' ', self.filler_ascii.sub('', text))
            # Do not leave a new space where the removed word used to touch the edge.
            if not text[:1].isspace(): cleaned = cleaned.lstrip()
            if not text[-1:].isspace(): cleaned = cleaned.rstrip()
            text = cleaned
        if self.stutter:
            # Positive-negative question stutter runs before single-char rules
            # so "是是是不是" collapses to "是不是" even though "是" is a tone char.
            text = _ALT_QUESTION_STUTTER.sub(lambda m: self._alt_question(text, m), text)
            text = _DOUBLE_WORD_STUTTER.sub(r'\1\1', text)
            text = self.stutter.sub(lambda m: self._stutter_char(text, m), text)
            text = _TRIPLE_CHAR.sub(self._triple_char, text)
        if self.repeat_words:
            text = self.repeat_words.sub(r'\1', text)
        if self.repeat_phrases:
            pattern = _PHRASE_2_8 if self.repeat_words else _PHRASE_3_8
            text = pattern.sub(self._phrase, text)
        if self.stutter or self.repeat_words:
            text = _ENGLISH_REPEAT.sub(self._english_repeat, text)
        return text

    def _collapse_comma_repeats(self, kept):
        """Drop a clause repeated immediately after a comma: '就是，就是我们' -> '就是我们'."""
        if not self.repeat_words and not self.repeat_phrases:
            return kept
        merged = []
        index = 0
        while index < len(kept):
            clause, punct = kept[index]
            soft = bool(punct) and punct.strip()[0] in SOFT
            if soft and index + 1 < len(kept):
                curr = clause.strip()
                nxt = kept[index + 1][0].lstrip()
                drop = False
                if self.repeat_words and curr in COMMA_REPEAT_CATCHPHRASES and nxt.startswith(curr):
                    drop = True
                elif (self.repeat_phrases and 3 <= len(curr) <= 10
                      and not _HAS_DIGIT_OR_NUMERAL.search(curr)
                      and nxt.startswith(curr)):
                    drop = True
                if drop:
                    index += 1
                    continue
            merged.append([clause, punct])
            index += 1
        return merged

    def clean(self, text):
        if not self.enabled or not text or not text.strip():
            return text
        parts = _SPLIT.split(text)
        # parts alternates clause, punctuation, clause, ... (punctuation may be absent at the end)
        kept = []  # [clause, punctuation]
        for index in range(0, len(parts), 2):
            original = parts[index]
            punct = parts[index + 1] if index + 1 < len(parts) else ''
            clause = self._clause(original)
            punct_head = punct.strip()[:1]
            soft = bool(punct_head) and punct_head in SOFT
            stripped = clause.strip()
            alone_boundary = soft or (stripped in ALONE_END_FILLERS and punct_head in ('', '、', '。', '！', '!', '？', '?'))
            if stripped in self.alone and alone_boundary:
                # "我要这个，那个，还有..." is a list, not a hesitation.
                before = parts[index - 2].rstrip() if index >= 2 else ''
                after = parts[index + 2].lstrip() if index + 2 < len(parts) else ''
                listing = stripped in POINTERS and (before.endswith(POINTERS) or after.startswith(POINTERS))
                # Let comma-repeat collapse handle "就是，就是我们先测试一下" cleanly.
                repeated = soft and stripped in COMMA_REPEAT_CATCHPHRASES and after.startswith(stripped)
                if not listing and not repeated:
                    clause = ''
            if clause != original and clause.strip() and soft and all(char in OPENERS for char in clause):
                # Only an opening quote is left: “嗯，可以” -> “可以”
                kept.append([clause, ''])
                continue
            if clause.strip() or not original.strip():
                # Untouched empty clauses (e.g. text starting with punctuation) stay as they are.
                kept.append([clause if clause.strip() else original, punct])
                continue
            # The whole clause was filler: drop it with one neighbouring mark.
            if kept and (not kept[-1][1] or kept[-1][1].strip()[0] in SOFT) and not soft:
                # "好的，嗯。" -> "好的。"   "好的，嗯" -> "好的"
                kept[-1][1] = punct
        kept = self._collapse_comma_repeats(kept)
        kept = _drop_trailing_english_ack(kept)
        result = ''.join(clause + punct for clause, punct in kept)
        # Clean stray leading punctuation or trailing comma after removals.
        result = re.sub('^[' + re.escape(SOFT + '、') + r']+\s*', '', result)
        result = re.sub('[' + re.escape(SOFT) + r']+\s*$', '', result)
        if self.arabic_numbers:
            result = _convert_arabic_numbers(result)
        # If nothing meaningful is left (the user only said "嗯"), keep the original.
        return result if re.sub('[' + re.escape(PUNCT) + r'\s]', '', result) else text


class Cleaner:
    """Rules backed by an optional text file; edits apply without a restart."""
    def __init__(self, path=None, create=False):
        self.path = Path(path) if path else None
        self.lock = threading.Lock()
        self.stamp = None
        self.rules = Rules()
        if self.path and create and not self.path.exists():
            try:
                self.path.write_text(TEMPLATE.format(**DEFAULTS), encoding='utf-8')
            except OSError:
                pass  # Read-only folder: built-in defaults still apply.
        self._reload()

    def _reload(self):
        if not self.path:
            return
        try:
            stat = self.path.stat()
            stamp = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            stamp = None
        if stamp == self.stamp:
            return
        try:
            rules = Rules(parse(self.path.read_text(encoding='utf-8-sig'))) if stamp else Rules()
        except (OSError, UnicodeError, re.error):
            return  # Keep the last good rules while the file is half-saved or broken.
        self.rules, self.stamp = rules, stamp

    def clean(self, text):
        try:
            with self.lock:
                self._reload()
                rules = self.rules
            return rules.clean(text)
        except Exception:
            return text  # Cleanup is optional; never lose a recognition result over it.

    def status(self):
        with self.lock:
            self._reload()
            return dict(enabled=self.rules.enabled, file=str(self.path) if self.path else '')
