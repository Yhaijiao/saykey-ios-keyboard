"""Build a bounded offline lexicon from public MIT-licensed jieba+pypinyin data.

Never reads desktop hotwords. Inputs are explicit public-package paths.

Besides jieba's most frequent words, the lexicon takes in (2026-11):
- every HSK word (drkameleon/complete-hsk-vocabulary complete.json, MIT),
  so daily vocabulary such as 微信 / 快递 is always present;
- scripts/zh-everyday.txt, chat phrases written for SayKey (好的, 在吗);
- idioms ranked by THUOCL_chengyu.txt (thunlp/THUOCL, MIT).

    python3 scripts/build_pinyin_lexicon.py --dictionary jieba/dict.txt \
        --hsk complete.json --idioms THUOCL_chengyu.txt --output ios/Shared/pinyin-lexicon.json
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
import sys

from pypinyin import Style, lazy_pinyin, pinyin

SEEDS = {
    'nihao': ['你好'], 'xiexie': ['谢谢'], 'zaijian': ['再见'], 'shijie': ['世界'],
    'wo': ['我'], 'ni': ['你'], 'hao': ['好'], 'de': ['的'], 'shi': ['是'],
    'ceshi': ['测试'], 'zhongwen': ['中文'], 'shuru': ['输入'], 'shouji': ['手机'],
    'jintian': ['今天'], 'mingtian': ['明天'], 'women': ['我们'], 'nihaoma': ['你好吗'],
    'xianzai': ['现在'], 'keyi': ['可以'], 'zhongguo': ['中国'],
}


def extra_words(args, rows):
    """Daily words, chat phrases and idioms with a frequency on jieba's scale."""
    def at_rank(rank): return rows[min(rank, len(rows) - 1)][1]
    known = dict(rows)
    extra = {}
    if args.hsk:
        by_level = {1: at_rank(3000), 2: at_rank(5000), 3: at_rank(9000), 4: at_rank(15000),
                    5: at_rank(25000), 6: at_rank(35000), 7: at_rank(45000)}
        for entry in json.loads(args.hsk.read_text(encoding='utf-8')):
            word = entry['simplified']
            levels = [int(level.split('-')[1]) for level in entry.get('level', [])
                      if re.fullmatch(r'(old|new)-[0-9]', level)]
            if levels and re.fullmatch(r'[\u4e00-\u9fff]{2,6}', word):
                extra[word] = max(known.get(word, 0), by_level.get(min(levels), at_rank(45000)))
    if args.everyday and args.everyday.exists():
        for line in args.everyday.read_text(encoding='utf-8').splitlines():
            word = line.strip()
            if re.fullmatch(r'[\u4e00-\u9fff]{2,6}', word):
                extra[word] = max(known.get(word, 0), extra.get(word, 0), at_rank(1500))
    if args.idioms:
        idioms = []
        for line in args.idioms.read_text(encoding='utf-8').splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit() and re.fullmatch(r'[\u4e00-\u9fff]{4,8}', parts[0]):
                idioms.append((int(parts[1]), parts[0]))
        idioms.sort(reverse=True)
        for rank, (_, word) in enumerate(idioms[:8000]):
            # The best known idioms rank with everyday words; rare ones stay findable.
            extra[word] = max(known.get(word, 0), extra.get(word, 0), at_rank(12000 + rank * 6))
    return extra


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dictionary', type=Path, required=True)
    parser.add_argument('--hsk', type=Path)
    parser.add_argument('--idioms', type=Path)
    parser.add_argument('--everyday', type=Path, default=Path(__file__).with_name('zh-everyday.txt'))
    parser.add_argument('--top', type=int, default=40000)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = []
    source = args.dictionary.read_bytes()
    for line in source.decode('utf-8').splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r'[\u4e00-\u9fff]{1,6}', parts[0]):
            rows.append((parts[0], int(parts[1])))
    rows.sort(key=lambda row: (-row[1], row[0]))
    jieba_frequencies = dict(rows)
    extra = extra_words(args, rows)
    selected = dict(rows[:args.top])
    selected.update((word, freq) for word, freq in rows if len(word) == 1)
    for word, freq in extra.items(): selected[word] = max(selected.get(word, 0), freq)
    result = defaultdict(list)
    for key, words in SEEDS.items(): result[key].extend(words)
    for word, freq in sorted(selected.items(), key=lambda row: (-row[1], row[0])):
        readings = (pinyin(word, style=Style.NORMAL, heteronym=True)[0] if len(word) == 1
                    else [''.join(lazy_pinyin(word, style=Style.NORMAL))])
        for reading in readings:
            key = reading.replace('ü', 'v').lower()
            if re.fullmatch('[a-z]{1,32}', key) and word not in result[key] and len(result[key]) < 40:
                result[key].append(word)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frequencies = dict(jieba_frequencies)
    for word, freq in extra.items(): frequencies[word] = max(frequencies.get(word, 0), freq)
    # Jieba's tokenizer dictionary omits productive phrases such as 我妈 / 我买.
    # Add a small public starter vocabulary; this is not personal word learning.
    common = {}
    for prefix in ['我', '你', '他', '她']:
        for suffix in ['妈', '爸', '哥', '姐', '妹', '弟', '家', '想', '要', '有', '没', '买', '卖', '会', '能', '不', '是', '说', '在', '的']:
            word = prefix + suffix
            spelling = ''.join(lazy_pinyin(word, style=Style.NORMAL)).replace('ü', 'v')
            common[word] = max(1, int(min(frequencies.get(prefix, 1), frequencies.get(suffix, 1)) * 0.35))
            if word not in result[spelling] and len(result[spelling]) < 40: result[spelling].append(word)
    total = sum(frequencies.values())
    seeds = {word for words in SEEDS.values() for word in words}
    costs = {}
    for spelling, words in result.items():
        scored = []
        for word in words:
            frequency = max(frequencies.get(word, 1), common.get(word, 1), 100000 if word in seeds else 1)
            reading_rank = 0
            if len(word) == 1:
                readings = [reading.replace('ü', 'v') for reading in pinyin(word, style=Style.NORMAL, heteronym=True)[0]]
                if spelling in readings: reading_rank = readings.index(spelling)
            cost = round(math.log(total / frequency) + reading_rank * 2.5, 4)
            seed_order = SEEDS.get(spelling, []).index(word) if word in SEEDS.get(spelling, []) else 1000
            scored.append((seed_order, cost, word))
        scored.sort()
        result[spelling] = [word for _, _, word in scored]
        costs[spelling] = [cost for _, cost, _ in scored]
    args.output.write_text(json.dumps(dict(sorted(result.items())), ensure_ascii=False,
                                      separators=(',', ':')), encoding='utf-8')
    costs_output = args.output.with_name('pinyin-costs.json')
    costs_output.write_text(json.dumps(dict(sorted(costs.items())), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    # Preserve syllable boundaries for full spelling mixed with initials.
    patterns = defaultdict(list)
    for spelling, words in result.items():
        for word in words:
            syllables = ([spelling] if len(word) == 1 else
                         [part.replace('ü', 'v') for part in lazy_pinyin(word, style=Style.NORMAL)])
            if ''.join(syllables) == spelling:
                patterns["'".join(syllables)].append(word)
    args.output.with_name('pinyin-syllables.json').write_text(
        json.dumps(dict(sorted(patterns.items())), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(json.dumps({'pinyin_keys': len(result), 'word_entries': sum(map(len, result.values())),
                      'output_bytes': args.output.stat().st_size,
                      'jieba_dict_sha256': hashlib.sha256(source).hexdigest()}, indent=2))


if __name__ == '__main__': main()
