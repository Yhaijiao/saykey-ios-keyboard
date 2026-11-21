"""Build the bundled next-word suggestion tables from public n-gram counts.

Never reads desktop hotwords or anything the user typed. Inputs are explicit
paths to public data:

Chinese: Google Books Ngram Viewer exports, version 20200217, corpus chi_sim
(CC BY 3.0). First reduce the raw shards to "ngram<TAB>count" with this
script's --aggregate mode, for example:

    curl -s https://storage.googleapis.com/books/ngrams/books/20200217/chi_sim/1-00000-of-00001.gz \
        | zcat | python3 scripts/build_suggestions.py --aggregate 1 > zh1.tsv
    for i in 0 1 2 3 4 5; do
        curl -s https://storage.googleapis.com/books/ngrams/books/20200217/chi_sim/2-0000$i-of-00006.gz \
            | zcat | python3 scripts/build_suggestions.py --aggregate 2
    done > zh2.tsv

Everyday weighting (2026-11): the book corpus favours official prose (的 ->
发展/社会/经济). Followers are re-weighted toward daily vocabulary using the
HSK word list from drkameleon/complete-hsk-vocabulary (MIT, complete.json)
and scripts/zh-everyday.txt (written for SayKey); formal words are damped.

Idioms and xiehouyu: THUOCL_chengyu.txt from thunlp/THUOCL (MIT, with
document frequencies) and xiehouyu.json from pwxcoo/chinese-xinhua (MIT).

English: the frequency dictionaries shipped in symspellpy 6.10.2 (MIT), which
SymSpell derived from Google Books Ngram data (CC BY 3.0) and SCOWL.

    python3 scripts/build_suggestions.py --zh-unigrams zh1.tsv --zh-bigrams zh2.tsv \
        --en-unigrams frequency_dictionary_en_82_765.txt \
        --en-bigrams frequency_bigramdictionary_en_243_342.txt \
        --hsk complete.json --idioms THUOCL_chengyu.txt --xiehouyu xiehouyu.json --output ios/Shared
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import sys

FIRST_YEAR = '1980'
MIN_COUNT = 300
ZH_KEYS = 12000
EN_KEYS = 9000
EN_WORDS = 20000
IDIOMS = 8000
# Followers that only reflect the book corpus (official documents), not chat.
ZH_SKIP = {'党', '省', '主席', '同志', '大锅饭', '国', '军', '主义', '党委', '政府'}
# Official-prose words: still offered, but well below everyday ones.
ZH_FORMAL = set('''
发展 社会 经济 问题 国家 管理 技术 建设 改革 企业 政策 群众 领导 干部 人民 革命
主义 制度 体制 生产 文化 政治 历史 理论 思想 科学 研究 工作 组织 部门 单位 地区
方面 过程 水平 条件 作用 意义 原则 关系 系统 结构 因素 基础 实践 阶段 规定 措施
效益 增长 战略 机制 中央 我国 全国 各级 党委 政府 同志 主席 委员会 代表 会议 决定
报告 文件 精神 方针 任务 目标 质量 产品 市场 资金 投资 财政 农业 工业 农村 城市
重要 主要 影响 要求 认为 必须 国际 中心 概念 角度 进行 提高 加强 实现 具有 存在
表明 根据 通过 对于 关于 以及 其 该 此 之 于 而 则 即 及 与 乃 亦 皆 均 系 所
世界 中国 国内 人类 全面 有关 有效 积极 广大 重大 基本 一定 所谓 具体 相应 分析
采取 形成 提出 确定 保证 坚持 促进 推动 开展 参加 发挥 统一 民族 领域 对象 内容
'''.split())
# A prediction bar should not volunteer these.
EN_SKIP = {'fuck', 'fucking', 'fucked', 'shit', 'bitch', 'cunt', 'nigger', 'nigga', 'porn', 'sex',
           'sexy', 'dick', 'cock', 'pussy', 'whore', 'slut', 'rape', 'nude', 'naked', 'xxx'}


def aggregate(order):
    """Raw Google Books shard on stdin -> 'ngram<TAB>count since 1980' on stdout."""
    word = r'[一-鿿]{1,6}' if order == 1 else r'[一-鿿]{1,4} [一-鿿]{1,4}'
    pattern = re.compile(word)
    for line in sys.stdin:
        tab = line.find('\t')
        if tab < 0 or not pattern.fullmatch(line, 0, tab): continue
        total = 0
        for field in line[tab + 1:].split('\t'):
            year, count, _ = field.split(',')
            if year >= FIRST_YEAR: total += int(count)
        if total >= MIN_COUNT: sys.stdout.write(f'{line[:tab]}\t{total}\n')


def read_counts(path, separator):
    counts = {}
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        parts = line.rsplit(separator, 1)
        if len(parts) == 2 and parts[1].strip().isdigit(): counts[parts[0]] = int(parts[1])
    return counts


def table(scores, ranking, keys, skip):
    """Top followers per key; frequent keys keep more of them."""
    ordered = sorted((key for key in scores if key in ranking), key=lambda key: -ranking[key])[:keys]
    lines = []
    for index, key in enumerate(ordered):
        limit = 8 if index < 3000 else 5
        followers = sorted(scores[key].items(), key=lambda item: (-item[1], item[0]))
        chosen = [word for word, _ in followers if word not in skip][:limit]
        if chosen: lines.append(key + '\t' + ' '.join(chosen))
    return lines


def read_everyday(path):
    return [line.strip() for line in path.read_text(encoding='utf-8').splitlines()
            if line.strip() and not line.startswith('#')]


def read_hsk(path):
    """Word -> lowest HSK level (old 1-6 or new 1-7) it appears at."""
    levels = {}
    for entry in json.loads(path.read_text(encoding='utf-8')):
        found = [int(level.split('-')[1]) for level in entry.get('level', [])
                 if re.fullmatch(r'(old|new)-[0-9]', level)]
        if found: levels[entry['simplified']] = min(found)
    return levels


def everyday_weight(word, hsk, everyday):
    """How much a follower's book count is trusted as everyday usage."""
    if word in everyday: return 4.0
    if word in ZH_FORMAL: return 0.15
    level = hsk.get(word)
    if level is None: return 0.6
    return {1: 3.0, 2: 3.0, 3: 2.2, 4: 1.4}.get(level, 0.9)


def chinese(unigrams, bigrams, hsk, everyday):
    scores = defaultdict(lambda: defaultdict(int))
    for pair, count in bigrams.items():
        first, second = pair.split(' ')
        scores[first][second] += count
    # A word that continues the key ("今" -> "今天") is a suggestion too.
    for word, count in unigrams.items():
        for cut in range(1, len(word)):
            head, tail = word[:cut], word[cut:]
            if head in unigrams: scores[head][tail] += count
    # Everyday phrases the books barely contain: 好 -> 的, 谢谢 -> 你.
    base = sorted(unigrams.values(), reverse=True)[min(2000, len(unigrams) - 1)]
    for word in everyday:
        for cut in range(1, len(word)):
            head, tail = word[:cut], word[cut:]
            scores[head][tail] += base // 4
            unigrams.setdefault(head, base)
    weighted = {key: {word: count * everyday_weight(word, hsk, everyday) for word, count in followers.items()}
                for key, followers in scores.items()}
    return table(weighted, unigrams, ZH_KEYS, ZH_SKIP)


def idioms(path, limit):
    """Most used idioms first, one per line."""
    rows = []
    for line in path.read_text(encoding='utf-8').splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r'[一-鿿]{4,8}', parts[0]) and parts[1].isdigit():
            rows.append((int(parts[1]), parts[0]))
    rows.sort(key=lambda row: (-row[0], row[1]))
    seen, result = set(), []
    for _, word in rows:
        if word not in seen: seen.add(word); result.append(word)
    return result[:limit]


def xiehouyu(path):
    """'riddle<TAB>answer' lines; only short, plain ones."""
    lines, seen = [], set()
    for entry in json.loads(path.read_text(encoding='utf-8')):
        riddle = entry['riddle'].strip(); answer = entry['answer'].strip()
        if not re.fullmatch(r'[一-鿿，、]{4,10}', riddle): continue
        # Several answers: the first is the best known one.
        answer = re.split(r'[；;]', answer)[0].strip()
        if not re.fullmatch(r'[一-鿿，、（）—]{2,10}', answer) or riddle in seen: continue
        seen.add(riddle); lines.append(riddle + '\t' + answer)
    return lines


def english(unigrams, bigrams):
    plain = re.compile(r"[a-z]+")
    scores = defaultdict(lambda: defaultdict(int))
    for pair, count in bigrams.items():
        first, second = pair.split(' ')
        if plain.fullmatch(first) and plain.fullmatch(second) and second in unigrams:
            scores[first][second] += count
    words = [word for word, _ in sorted(unigrams.items(), key=lambda item: -item[1])
             if plain.fullmatch(word) and word not in EN_SKIP
             and (len(word) > 1 or word in {'a', 'i'})][:EN_WORDS]
    return table(scores, unigrams, EN_KEYS, EN_SKIP), words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--aggregate', type=int, choices=[1, 2])
    parser.add_argument('--zh-unigrams', type=Path)
    parser.add_argument('--zh-bigrams', type=Path)
    parser.add_argument('--en-unigrams', type=Path)
    parser.add_argument('--en-bigrams', type=Path)
    parser.add_argument('--hsk', type=Path)
    parser.add_argument('--idioms', type=Path)
    parser.add_argument('--xiehouyu', type=Path)
    parser.add_argument('--everyday', type=Path, default=Path(__file__).with_name('zh-everyday.txt'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.aggregate: aggregate(args.aggregate); return
    everyday = read_everyday(args.everyday)
    zh = chinese(read_counts(args.zh_unigrams, '\t'), read_counts(args.zh_bigrams, '\t'),
                 read_hsk(args.hsk), set(everyday))
    en, words = english(read_counts(args.en_unigrams, ' '), read_counts(args.en_bigrams, ' '))
    args.output.mkdir(parents=True, exist_ok=True)
    report = {}
    outputs = [('suggest-zh.txt', zh), ('suggest-en.txt', en), ('suggest-en-words.txt', words),
               ('suggest-idioms.txt', idioms(args.idioms, IDIOMS)), ('suggest-xiehouyu.txt', xiehouyu(args.xiehouyu))]
    for name, lines in outputs:
        target = args.output / name
        target.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        report[name] = {'lines': len(lines), 'bytes': target.stat().st_size}
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
