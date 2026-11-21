"""Build a bounded offline lexicon from public MIT-licensed jieba+pypinyin data.

Never reads desktop hotwords. Inputs are explicit public-package paths:

- --dictionary: jieba 0.42.1 dict.txt (MIT).
- --wordfreq: the folder wordfreq/data from the wordfreq 3.1.1 wheel (data
  CC BY-SA 4.0). Its everyday-language shares (subtitles, social media, web)
  are blended with jieba's counts so chat words rank as people use them.
- --idioms: THUOCL_chengyu.txt from THUOCL (MIT), with document frequencies.
- --idiom-pinyin: idiom.json from pwxcoo/chinese-xinhua (MIT), whose readings
  are better than pypinyin's guesses for idioms (e.g. 一石二鸟).

    python3 scripts/build_pinyin_lexicon.py --dictionary jieba/dict.txt \
        --wordfreq wordfreq/data --idioms THUOCL_chengyu.txt \
        --idiom-pinyin idiom.json --output ios/Shared/pinyin-lexicon.json
"""
import argparse
from collections import defaultdict
import gzip
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


WORDS = 30000
IDIOMS = 6000


def wordfreq(folder):
    """wordfreq 'large' Chinese list -> {word: share of all words}. Needs msgpack."""
    import msgpack
    with gzip.open(folder / 'large_zh.msgpack.gz') as handle:
        buckets = msgpack.load(handle, raw=False)
    shares = {}
    for index, bucket in enumerate(buckets[1:]):
        for word in bucket: shares.setdefault(word, 10 ** (-index / 100))
    return shares


def idioms(path, readings_path, limit):
    """Most used idioms first, each with its toneless syllables."""
    rows = []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit() and re.fullmatch(r'[\u4e00-\u9fff]{4}', parts[0]):
            rows.append((parts[0], int(parts[1])))
    rows.sort(key=lambda row: (-row[1], row[0]))
    import unicodedata
    readings = {}
    for entry in json.loads(readings_path.read_text(encoding='utf-8')):
        plain = unicodedata.normalize('NFKD', entry.get('pinyin', ''))
        plain = ''.join(c for c in plain if not unicodedata.combining(c)).lower().replace('ü', 'v')
        syllables = re.findall(r'[a-z]+', plain)
        if len(syllables) == len(entry.get('word', '')): readings[entry['word']] = syllables
    result = []
    for idiom, count in rows[:limit]:
        syllables = readings.get(idiom) or [part.replace('ü', 'v') for part in lazy_pinyin(idiom, style=Style.NORMAL)]
        if all(re.fullmatch('[a-z]{1,6}', part) for part in syllables): result.append((idiom, count, syllables))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dictionary', type=Path, required=True)
    parser.add_argument('--wordfreq', type=Path, required=True)
    parser.add_argument('--idioms', type=Path, required=True)
    parser.add_argument('--idiom-pinyin', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    counts = {}
    source = args.dictionary.read_bytes()
    for line in source.decode('utf-8').splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r'[\u4e00-\u9fff]{1,6}', parts[0]):
            counts[parts[0]] = int(parts[1])
    # Blend book-ish jieba counts with everyday shares (geometric mean), on
    # jieba's scale so the costs below keep their meaning.
    everyday = wordfreq(args.wordfreq)
    jieba_total = sum(counts.values())
    blended = {}
    # Everyday-only single characters are mostly variants or slang; skip them.
    for word in set(counts) | {w for w in everyday if re.fullmatch(r'[\u4e00-\u9fff]{2,6}', w)}:
        book = counts.get(word, 0) / jieba_total
        share = everyday.get(word, 0)
        value = math.sqrt(book * share) if book and share else (book * 0.2 if book else share * 0.3)
        blended[word] = max(1, int(value * jieba_total))
    rows = sorted(blended.items(), key=lambda row: (-row[1], row[0]))
    selected = dict(rows[:WORDS])
    idiom_rows = idioms(args.idioms, args.idiom_pinyin, IDIOMS)
    # Idioms are rare as words but people mean them when they spell them out;
    # floor their frequency so a full spelling finds them first.
    idiom_floor = sorted(blended.values(), reverse=True)[min(len(rows) - 1, 20000)]
    for idiom, count, _ in idiom_rows:
        blended[idiom] = max(blended.get(idiom, 1), idiom_floor + count // 50)
    idiom_syllables = {idiom: syllables for idiom, _, syllables in idiom_rows}
    selected.update((word, freq) for word, freq in rows if len(word) == 1)
    result = defaultdict(list)
    for key, words in SEEDS.items(): result[key].extend(words)
    for word, syllables in idiom_syllables.items(): selected[word] = blended[word]
    for word, freq in sorted(selected.items(), key=lambda row: (-row[1], row[0])):
        readings = (pinyin(word, style=Style.NORMAL, heteronym=True)[0] if len(word) == 1
                    else [''.join(idiom_syllables[word])] if word in idiom_syllables
                    else [''.join(lazy_pinyin(word, style=Style.NORMAL))])
        for reading in readings:
            key = reading.replace('ü', 'v').lower()
            if re.fullmatch('[a-z]{1,32}', key) and word not in result[key] and len(result[key]) < 40:
                result[key].append(word)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frequencies = dict(blended)
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
            syllables = ([spelling] if len(word) == 1 else idiom_syllables.get(word) or
                         [part.replace('ü', 'v') for part in lazy_pinyin(word, style=Style.NORMAL)])
            if ''.join(syllables) == spelling:
                patterns["'".join(syllables)].append(word)
    args.output.with_name('pinyin-syllables.json').write_text(
        json.dumps(dict(sorted(patterns.items())), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(json.dumps({'pinyin_keys': len(result), 'word_entries': sum(map(len, result.values())),
                      'idioms': len(idiom_rows), 'output_bytes': args.output.stat().st_size,
                      'jieba_dict_sha256': hashlib.sha256(source).hexdigest()}, indent=2))


if __name__ == '__main__': main()
