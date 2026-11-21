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

English: the frequency dictionaries shipped in symspellpy 6.10.2 (MIT), which
SymSpell derived from Google Books Ngram data (CC BY 3.0) and SCOWL.

Books are not chat. Every follower is reweighted by how much more (or less)
common it is in everyday language than in books, using the word frequency
lists of wordfreq 3.1.1 (data CC BY-SA 4.0: subtitles, social media, web
text and more). That turns "的 -> 发展 社会 经济" into "的 -> 是 时候 人".
Pass the folder `wordfreq/data` from the wordfreq wheel.

Idioms and two-part allegorical sayings:
- 成语: THUOCL_chengyu.txt from THUOCL (MIT, Tsinghua University), with
  document frequencies. "画蛇" suggests "添足".
- 歇后语: xiehouyu.json from pwxcoo/chinese-xinhua (MIT). Typing the first
  part ("外甥打灯笼") suggests the second ("——照舅（旧）").

    python3 scripts/build_suggestions.py --zh-unigrams zh1.tsv --zh-bigrams zh2.tsv \
        --en-unigrams frequency_dictionary_en_82_765.txt \
        --en-bigrams frequency_bigramdictionary_en_243_342.txt \
        --wordfreq wordfreq/data --idioms THUOCL_chengyu.txt --xiehouyu xiehouyu.json \
        --output ios/Shared
"""
import argparse
from collections import defaultdict
import gzip
import json
from pathlib import Path
import re
import sys

FIRST_YEAR = '1980'
MIN_COUNT = 300
ZH_KEYS = 16000
IDIOMS = 6000
IDIOM_TAILS = 3
XIEHOUYU_RIDDLE = 10
EN_KEYS = 9000
EN_WORDS = 20000
# Followers that only reflect the book corpus (official documents), not chat.
ZH_SKIP = {'党', '省', '主席', '同志', '大锅饭', '国', '军', '主义', '党委', '政府'}
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


def wordfreq(folder, language):
    """wordfreq 'large' list -> {word: share of all words}. Needs msgpack."""
    import msgpack
    with gzip.open(folder / f'large_{language}.msgpack.gz') as handle:
        buckets = msgpack.load(handle, raw=False)
    shares = {}
    for index, bucket in enumerate(buckets[1:]):
        for word in bucket: shares.setdefault(word, 10 ** (-index / 100))
    return shares


def everyday_weight(unigrams, everyday):
    """How much more common a word is in everyday language than in books."""
    total = sum(unigrams.values())
    def weight(word):
        share = everyday.get(word, 0)
        if not share: return 0.02
        book = unigrams.get(word, 0) / total
        return 1.0 if not book else min(20.0, max(0.02, share / book))
    return weight


def read_counts(path, separator):
    counts = {}
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        parts = line.rsplit(separator, 1)
        if len(parts) == 2 and parts[1].strip().isdigit(): counts[parts[0]] = int(parts[1])
    return counts


def table(scores, ranking, keys, skip):
    """Top followers per key; frequent keys keep more of them."""
    ordered = sorted((key for key in scores if key in ranking), key=lambda key: -ranking[key])[:keys]
    result = {}
    for index, key in enumerate(ordered):
        limit = 8 if index < 3000 else 5
        followers = sorted(scores[key].items(), key=lambda item: (-item[1], item[0]))
        chosen = [word for word, _ in followers if word not in skip][:limit]
        if chosen: result[key] = chosen
    return result


def lines(rows):
    return [key + '\t' + ' '.join(followers) for key, followers in rows.items()]


def chinese(unigrams, bigrams, everyday):
    weight = everyday_weight(unigrams, everyday)
    scores = defaultdict(lambda: defaultdict(float))
    for pair, count in bigrams.items():
        first, second = pair.split(' ')
        scores[first][second] += count * weight(second)
    # A word that continues the key ("今" -> "今天") is a suggestion too.
    for word, count in unigrams.items():
        for cut in range(1, len(word)):
            head, tail = word[:cut], word[cut:]
            if head in unigrams: scores[head][tail] += count * weight(word)
    # Keys in the order people type them, not the order books print them.
    ranking = {key: everyday.get(key, 0) * 1e12 + unigrams.get(key, 0) for key in unigrams}
    return table(scores, ranking, ZH_KEYS, ZH_SKIP), ranking


def read_idioms(path):
    """THUOCL lines 'idiom<TAB>document frequency' -> idioms, most used first."""
    rows = []
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit() and re.fullmatch(r'[一-鿿]{4}', parts[0]):
            rows.append((parts[0], int(parts[1])))
    rows.sort(key=lambda row: (-row[1], row[0]))
    return [idiom for idiom, _ in rows[:IDIOMS]]


def add_idioms(rows, ranking, idioms):
    """'画蛇' -> '添足' and '画蛇添' -> '足'. Common words such as '不可' keep
    their usual followers first; rarer keys lead with the idiom."""
    tails = defaultdict(list)
    for idiom in idioms:
        for cut in (2, 3):
            if idiom[cut:] not in tails[idiom[:cut]]: tails[idiom[:cut]].append(idiom[cut:])
    common = set(sorted(ranking, key=lambda key: -ranking[key])[:3000])
    for key, endings in tails.items():
        endings = endings[:IDIOM_TAILS]
        usual = [word for word in rows.get(key, []) if word not in endings]
        rows[key] = (usual[:3] + endings + usual[3:] if key in common else endings + usual)[:8]


def add_xiehouyu(rows, path):
    """'外甥打灯笼' -> '——照舅（旧）'; several answers become several followers."""
    added = 0
    for entry in json.loads(path.read_text(encoding='utf-8')):
        riddle = entry.get('riddle', '').strip()
        if not re.fullmatch(r'[一-鿿]{3,%d}' % XIEHOUYU_RIDDLE, riddle): continue
        answers = []
        for answer in re.split(r'[；;]', entry.get('answer', '')):
            answer = re.sub(r'\s+', '', answer).strip('，。、')
            if answer and len(answer) <= 16: answers.append('——' + answer)
        if not answers: continue
        known = rows.get(riddle, [])
        rows[riddle] = [a for a in answers if a not in known] + known
        added += 1
    return added


def english(unigrams, bigrams, everyday):
    plain = re.compile(r"[a-z]+")
    weight = everyday_weight(unigrams, everyday)
    scores = defaultdict(lambda: defaultdict(float))
    for pair, count in bigrams.items():
        first, second = pair.split(' ')
        if plain.fullmatch(first) and plain.fullmatch(second) and second in unigrams:
            scores[first][second] += count * weight(second) ** 0.5
    # Completions follow everyday frequency; the book list only vets spelling.
    ranking = {word: everyday.get(word, 0) * 1e12 + count for word, count in unigrams.items()}
    words = [word for word in sorted(ranking, key=lambda word: -ranking[word])
             if plain.fullmatch(word) and word not in EN_SKIP
             and (len(word) > 1 or word in {'a', 'i'})][:EN_WORDS]
    return lines(table(scores, ranking, EN_KEYS, EN_SKIP)), words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--aggregate', type=int, choices=[1, 2])
    parser.add_argument('--zh-unigrams', type=Path)
    parser.add_argument('--zh-bigrams', type=Path)
    parser.add_argument('--en-unigrams', type=Path)
    parser.add_argument('--en-bigrams', type=Path)
    parser.add_argument('--wordfreq', type=Path)
    parser.add_argument('--idioms', type=Path)
    parser.add_argument('--xiehouyu', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.aggregate: aggregate(args.aggregate); return
    rows, ranking = chinese(read_counts(args.zh_unigrams, '\t'), read_counts(args.zh_bigrams, '\t'),
                            wordfreq(args.wordfreq, 'zh'))
    add_idioms(rows, ranking, read_idioms(args.idioms))
    sayings = add_xiehouyu(rows, args.xiehouyu)
    zh = lines(rows)
    en, words = english(read_counts(args.en_unigrams, ' '), read_counts(args.en_bigrams, ' '),
                        wordfreq(args.wordfreq, 'en'))
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'xiehouyu': sayings}
    for name, content in [('suggest-zh.txt', zh), ('suggest-en.txt', en), ('suggest-en-words.txt', words)]:
        target = args.output / name
        target.write_text("\n".join(content) + "\n", encoding="utf-8")
        report[name] = {"lines": len(content), 'bytes': target.stat().st_size}
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
