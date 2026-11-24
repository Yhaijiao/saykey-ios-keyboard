"""Read-only adapter to a local CapsWriter install. No upstream code is published.

Reuse the installed phoneme/rule classes and HotwordManager.correct method rather
than translating the fuzzy algorithm to Swift. Import source in an isolated,
in-memory namespace, avoiding desktop startup, keyboard hooks and file watchers.
"""
from __future__ import annotations
import ast
from dataclasses import dataclass
import hashlib
import json
import logging
from pathlib import Path
import re
import sys
import threading
import types
import uuid

HOT_FILES = {
    'hot': 'hot.txt', 'aliases': 'hot-personal-aliases.txt',
    'auto': 'auto-hotwords/hot-auto.txt', 'rule': 'hot-rule.txt',
}
SOURCE_FILES = [
    'algo_phoneme.py', 'algo_calc.py', 'rag_fast.py', 'rag_fast_batch.py',
    'hot_phoneme.py', 'hot_rule.py', 'hotword_sources.py', 'manager.py',
]
CONFIG_KEYS = ('hot', 'hot_thresh', 'hot_similar', 'hot_rule', 'trash_punc',
               'trash_punc_thresh', 'trash_punc_apps', 'traditional_convert')


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(',', ':')).encode()).hexdigest()[:16]


def read_snapshot(root):
    root = Path(root)
    names = [*HOT_FILES.values(), 'config_client.py',
             'core/client/output/text_output.py',
             *['core/client/hotword/' + name for name in SOURCE_FILES]]
    for _ in range(3):
        first = {name: (root / name).read_text(encoding='utf-8-sig')
                 if (root / name).is_file() else '' for name in names}
        second = {name: (root / name).read_text(encoding='utf-8-sig')
                  if (root / name).is_file() else '' for name in names}
        if first == second:
            if not first['core/client/hotword/hot_phoneme.py']:
                raise ValueError('Not a supported CapsWriter source directory')
            return first
    raise RuntimeError('Desktop files are changing; retry after the current update finishes')


def config_values(source):
    values = dict(hot=True, hot_thresh=.85, hot_similar=.6, hot_rule=True,
                  trash_punc='，。,.', trash_punc_thresh=8,
                  trash_punc_apps=[], traditional_convert=False)
    tree = ast.parse(source)
    cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'ClientConfig')
    for node in cls.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in CONFIG_KEYS:
                    values[target.id] = ast.literal_eval(node.value)
    return values


def extract(source, name, class_name=None):
    tree = ast.parse(source)
    nodes = tree.body
    if class_name:
        nodes = next(node.body for node in nodes
                     if isinstance(node, ast.ClassDef) and node.name == class_name)
    node = next(node for node in nodes if getattr(node, 'name', None) == name)
    node.decorator_list = []
    return ast.fix_missing_locations(ast.Module(body=[ast.ImportFrom(module='__future__',
               names=[ast.alias(name='annotations')], level=0), node], type_ignores=[]))


@dataclass
class EngineResult:
    text: str
    version: str
    source_version: str
    mode: str
    terms: int
    engine: str = 'CapsWriter installed hotword and rule source'


class DesktopEngine:
    mode = 'desktop-shared-hotword-source'

    def __init__(self, root, *, snapshot=None, cleaner=None, polisher=None):
        self.root = Path(root)
        self.cleaner = cleaner
        self.polisher = polisher
        self.lock = threading.RLock()
        self.fingerprint = None
        self._package_name = None
        self._instance_id = uuid.uuid4().hex
        self.refresh(snapshot)

    def refresh(self, snapshot=None):
        with self.lock:
            snapshot = read_snapshot(self.root) if snapshot is None else snapshot
            fingerprint = digest(snapshot)
            if fingerprint == self.fingerprint:
                return
            settings = config_values(snapshot['config_client.py'])
            if settings['traditional_convert']:
                raise ValueError('Traditional conversion is enabled; this prototype does not claim parity for it')
            name = '_cw_mobile_' + fingerprint + '_' + self._instance_id
            package = types.ModuleType(name)
            package.__path__ = []
            package.logger = logging.getLogger('capswriter-mobile-adapter')
            package.logger.addHandler(logging.NullHandler())
            sys.modules[name] = package
            loaded = {}
            try:
                for filename in SOURCE_FILES[:-1]:
                    module_name = name + '.' + filename[:-3]
                    module = types.ModuleType(module_name)
                    module.__file__ = str(self.root / 'core/client/hotword' / filename)
                    sys.modules[module_name] = module
                    exec(compile(snapshot['core/client/hotword/' + filename], module.__file__, 'exec'), module.__dict__)
                    loaded[filename[:-3]] = module
                phoneme = loaded['hot_phoneme']
                sources = loaded['hotword_sources']
                personal = sources.merge_personal(snapshot[HOT_FILES['hot']], snapshot[HOT_FILES['aliases']])
                automatic = sources.auto_without_personal(snapshot[HOT_FILES['auto']], personal)
                state = types.SimpleNamespace()
                state._reload_lock = threading.RLock()
                state._personal_pattern = sources.personal_pattern(personal)
                state.phoneme_corrector = phoneme.PhonemeCorrector(settings['hot_thresh'], settings['hot_similar'])
                state.auto_corrector = phoneme.PhonemeCorrector(.98, .98)
                count = state.phoneme_corrector.update_hotwords(personal)
                count += state.auto_corrector.update_hotwords(automatic)
                rule = loaded['hot_rule'].RuleCorrector()
                rule.update_rules(snapshot[HOT_FILES['rule']])
                env = {'CorrectionResult': phoneme.CorrectionResult}
                exec(compile(extract(snapshot['core/client/hotword/manager.py'], 'correct', 'HotwordManager'),
                             '<installed HotwordManager.correct>', 'exec'), env)
                output_source = snapshot['core/client/output/text_output.py']
                punc_env = {'re': re, 'Config': types.SimpleNamespace(**settings),
                            'get_active_window_info': lambda: {'process_name': ''}}
                # Reuse the installed semantic-count expression and functions.
                for node in ast.parse(output_source).body:
                    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == '_SEMANTIC_UNIT_RE' for t in node.targets):
                        exec(compile(ast.Module(body=[node], type_ignores=[]), '<semantic counter>', 'exec'), punc_env)
                exec(compile(extract(output_source, 'count_semantic_units'), '<semantic count>', 'exec'), punc_env)
                exec(compile(extract(output_source, 'strip_punc', 'TextOutput'), '<installed strip_punc>', 'exec'), punc_env)
            except Exception:
                self._remove_namespace(name)
                raise
            old_name = self._package_name
            self._package_name = name
            self.snapshot, self.settings, self.state, self.rule = snapshot, settings, state, rule
            self.correct_hotwords, self.strip_punc = env['correct'], punc_env['strip_punc']
            self.terms = count
            self.version = digest({key: snapshot[path] for key, path in HOT_FILES.items()})
            self.source_version = digest({key: value for key, value in snapshot.items() if key.endswith('.py')})
            self.fingerprint = fingerprint
            if old_name and old_name != name:
                self._remove_namespace(old_name)

    @staticmethod
    def _remove_namespace(name):
        for key in list(sys.modules):
            if key == name or key.startswith(name + '.'):
                sys.modules.pop(key, None)

    def correct(self, text):
        with self.lock:
            self.refresh()
            # Drop fillers and stutters first so hotwords and punctuation see clean text.
            if self.cleaner: text = self.cleaner.clean(text)
            result = self.correct_hotwords(self.state, text, k=10)
            text = result.text if self.settings['hot'] else text
            text = self.strip_punc(text)
            # ResultProcessor currently runs this unconditionally, even when hot_rule=False.
            text = self.rule.substitute(text)
            polisher = self.polisher
            version, source_version, mode, terms = self.version, self.source_version, self.mode, self.terms
        # Run optional local LLM polish outside the lock so status checks stay responsive.
        if polisher: text = polisher.polish(text)
        return EngineResult(text, version, source_version, mode, terms)

    def validate_hotwords(self, text, file_id='hot'):
        snapshot = read_snapshot(self.root)
        snapshot[HOT_FILES[file_id]] = text
        candidate = DesktopEngine(self.root, snapshot=snapshot)
        try: return candidate.terms
        finally: self._remove_namespace(candidate._package_name)

    def status(self):
        with self.lock:
            self.refresh()
            return dict(version=self.version, source_version=self.source_version,
                        mode=self.mode, terms=self.terms, engine='installed desktop hotword and rule source',
                        scope='ASR output -> filler cleanup -> hotword -> punctuation -> rules -> optional local LLM polish',
                        cleanup=self.cleaner.status() if self.cleaner else dict(enabled=False, file=''),
                        polish=self.polisher.status() if self.polisher else dict(enabled=False, file=''),
                        app_context='neutral; desktop per-app punctuation settings may differ')


class DemoEngine:
    mode = 'demo-exact-aliases'
    version = digest({'CapsWriter': ['卡普斯赖特'], 'iPhone': ['爱疯手机']})
    source_version = 'demo-1'
    terms = 2
    cleaner = None
    polisher = None

    def correct(self, text):
        if self.cleaner: text = self.cleaner.clean(text)
        for old, new in [('卡普斯赖特', 'CapsWriter'), ('爱疯手机', 'iPhone')]:
            text = text.replace(old, new)
        if self.polisher: text = self.polisher.polish(text)
        return EngineResult(text, self.version, self.source_version, self.mode, self.terms,
                            engine='demo exact aliases; not desktop phoneme parity')

    def status(self):
        return dict(version=self.version, source_version=self.source_version,
                    mode=self.mode, terms=self.terms, engine='demo exact aliases only')
