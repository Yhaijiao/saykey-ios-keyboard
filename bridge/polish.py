"""Optional local Ollama speech polisher with VRAM and latency safeguards.

Runs after rule-based cleanup (fillers, stutters, numerals) and hotwords so
the LLM only refines punctuation and sentence breaks. Uses only Python's
standard library and only talks to loopback Ollama endpoints.
"""
from __future__ import annotations
import ipaddress
import json
from pathlib import Path
import re
import sys
import threading
import time
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

FILE_NAME = 'llm-polish.txt'
DEFAULTS = {
    'enabled': 'on',
    'endpoint': 'http://127.0.0.1:11434',
    'model': 'qwen3.5:4b',
    # Unload from VRAM after 10 min idle so RTX 4070 does not spill ASR to RAM.
    'keep_alive': '10m',
    # Hard per-request cap so a cold model load never stalls phone insertion.
    'timeout': '4.0',
    # Skip very short utterances ("好的", "收到") to keep zero latency.
    'min_chars': '8',
    # Warn when average generation exceeds 0.05 s/char (VRAM spill symptom).
    'slow_sec_per_char': '0.05',
    # Disable Qwen3 reasoning tokens for low latency and clean output.
    'think': 'off',
}
TEMPLATE = '''# SayKey 本地大模型润色配置（Ollama）
# 改完保存即可，下一句话生效，不用重启桥接。
# 仅允许连接本机（127.0.0.1 / localhost）的 Ollama，绝不联网外发语音文字。
# 如果本机未启动 Ollama 或响应超时，会自动降级为规则清理结果，不卡上屏。

# 总开关：on 开启，off 关闭
enabled = {enabled}

# 本机 Ollama 地址（仅允许 localhost / 127.0.0.1）
endpoint = {endpoint}

# Ollama 模型名（与电脑版 CapsWriter 一致）
model = {model}

# 闲置多久卸载显存，防止与 Qwen3-ASR 抢占 RTX 4070 显存导致越用越慢
keep_alive = {keep_alive}

# 单次润色最长等待秒数；超时直接返回规则清理结果，不拖慢上屏
timeout = {timeout}

# 少于这个字数的短句跳过大模型，零延迟上屏
min_chars = {min_chars}

# 平均每字生成超过此秒数时在日志报警（排查显存溢出）
slow_sec_per_char = {slow_sec_per_char}

# 关闭模型思考过程（Qwen3 系列保持 off 以保证速度）
think = {think}
'''

SYSTEM_PROMPT = (
    '你是语音输入标点润色助手。语气词和口吃已由前置规则清理。'
    '你只做断句和标点微调，严格保持原意和措辞：'
    '不要增删信息，不要改写数字、英文、版本号或符号（例如 +1、Q1、v0.4.29 保持原样），'
    '不要解释，直接输出润色后的文字。'
)

# Added for the final pass over a whole recording when it is long enough to
# have more than one topic.
PARAGRAPH_PROMPT = (
    '这是一整段说完的话。如果内容较长且明显换了话题，可以在换话题处分段，'
    '段与段之间只用一个换行；内容短或只有一个话题就不要分段。'
)
PARAGRAPH_MIN_CHARS = 150
# A long paragraph needs more generation time than one sentence.
PARAGRAPH_SEC_PER_CHAR = 0.03
PARAGRAPH_MAX_TIMEOUT = 20.0

_THINK_RE = re.compile(r'<think>.*?</think>', re.DOTALL | re.IGNORECASE)
_TOKEN_RE = re.compile(r'[+\-]?\d+(?:\.\d+)*|[A-Za-z][A-Za-z0-9._+-]*')


def _on(value):
    return str(value).strip().lower() not in ('off', 'false', '0', 'no', '关', '关闭')


def _is_loopback_endpoint(url):
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return False
    if parts.scheme not in ('http', 'https') or not parts.hostname:
        return False
    host = parts.hostname.lower()
    if host == 'localhost':
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def parse(source):
    """Read `name = value` lines; unknown keys and broken lines are ignored."""
    values = dict(DEFAULTS)
    for line in source.splitlines():
        line = line.split('#', 1)[0].strip()
        if '=' not in line and '＝' not in line:
            continue
        key, _, value = line.replace('＝', '=').partition('=')
        key = key.strip().lower()
        if key in values:
            values[key] = value.strip()
    return values


def _safe_float(value, default, low, high):
    try:
        num = float(value)
        return max(low, min(high, num))
    except (TypeError, ValueError):
        return default


def _safe_int(value, default, low, high):
    try:
        num = int(value)
        return max(low, min(high, num))
    except (TypeError, ValueError):
        return default


def _extract_tokens(text):
    return [m.group(0).lower() for m in _TOKEN_RE.finditer(text)]


def _accept_polished(source, candidate):
    """Reject empty, wildly resized, or token-mangled LLM outputs."""
    if not candidate or not candidate.strip():
        return False
    src_len = len(source.strip())
    cand_len = len(candidate.strip())
    if src_len == 0:
        return False
    if cand_len < max(1, int(src_len * 0.6)) or cand_len > max(src_len + 12, int(src_len * 1.35)):
        return False
    # Preserve every numeric/symbol/English token (e.g. "+1", "Q1", "v0.4.29").
    if _extract_tokens(source) != _extract_tokens(candidate):
        return False
    return True


def _clean_response(text):
    text = _THINK_RE.sub('', text).strip()
    if text.startswith('```') and text.endswith('```'):
        lines = text.splitlines()
        if len(lines) >= 2:
            text = '\n'.join(lines[1:-1]).strip()
    return text


class PolishConfig:
    def __init__(self, values=None):
        values = dict(DEFAULTS, **(values or {}))
        self.enabled = _on(values['enabled'])
        endpoint = values['endpoint'].rstrip('/')
        self.endpoint = endpoint if _is_loopback_endpoint(endpoint) else ''
        self.model = values['model'] or DEFAULTS['model']
        self.keep_alive = values['keep_alive'] or DEFAULTS['keep_alive']
        self.timeout = _safe_float(values['timeout'], 4.0, 0.5, 30.0)
        self.min_chars = _safe_int(values['min_chars'], 8, 1, 200)
        self.slow_sec_per_char = _safe_float(values['slow_sec_per_char'], 0.05, 0.005, 2.0)
        self.think = _on(values['think'])


class Polisher:
    """File-backed local Ollama polisher with cooldown and timing telemetry."""

    def __init__(self, path=None, create=False, transport=None, clock=time.monotonic, log_stream=None):
        self.path = Path(path) if path else None
        self.lock = threading.Lock()
        self.stamp = None
        self.config = PolishConfig()
        self.transport = transport or self._post_json
        self.clock = clock
        self.log_stream = log_stream if log_stream is not None else sys.stderr
        self._opener = build_opener(ProxyHandler({}))
        self._cooldown_until = 0.0
        self._last_metrics = None
        if self.path and create and not self.path.exists():
            try:
                self.path.write_text(TEMPLATE.format(**DEFAULTS), encoding='utf-8')
            except OSError:
                pass
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
            cfg = PolishConfig(parse(self.path.read_text(encoding='utf-8-sig'))) if stamp else PolishConfig()
        except (OSError, UnicodeError):
            return
        self.config, self.stamp = cfg, stamp
        self._cooldown_until = 0.0

    def _post_json(self, url, payload, timeout):
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        req = Request(url, data=body, headers={'Content-Type': 'application/json'}, method='POST')
        with self._opener.open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode('utf-8'))

    def _log(self, message):
        try:
            print(message, file=self.log_stream, flush=True)
        except Exception:
            pass

    def polish(self, text, paragraph=False):
        if not text or not text.strip():
            return text
        with self.lock:
            self._reload()
            cfg = self.config
            now = self.clock()
            if not cfg.enabled or not cfg.endpoint or len(text.strip()) < cfg.min_chars:
                return text
            if now < self._cooldown_until:
                return text

        system, timeout = SYSTEM_PROMPT, cfg.timeout
        if paragraph:
            timeout = min(PARAGRAPH_MAX_TIMEOUT, max(cfg.timeout, len(text) * PARAGRAPH_SEC_PER_CHAR))
            if len(text.strip()) >= PARAGRAPH_MIN_CHARS:
                system = SYSTEM_PROMPT + PARAGRAPH_PROMPT
        payload = {
            'model': cfg.model,
            'system': system,
            'prompt': text,
            'stream': False,
            'keep_alive': cfg.keep_alive,
            'think': cfg.think,
            'options': {'temperature': 0.1},
        }
        started = self.clock()
        try:
            reply = self.transport(cfg.endpoint + '/api/generate', payload, timeout)
        except (URLError, TimeoutError, OSError, ValueError, KeyError) as error:
            elapsed = self.clock() - started
            cooldown = 10.0 if isinstance(error, TimeoutError) else 30.0
            with self.lock:
                self._cooldown_until = self.clock() + cooldown
                self._last_metrics = dict(status='fallback', elapsed=round(elapsed, 3))
            self._log(f'[polish] fallback after {elapsed:.2f}s (cooldown {int(cooldown)}s)')
            return text
        except Exception:
            return text

        elapsed = self.clock() - started
        candidate = _clean_response(str(reply.get('response', '')))
        eval_count = reply.get('eval_count')
        eval_ns = reply.get('eval_duration')
        chars = max(1, len(candidate) if candidate else len(text))
        sec_per_char = (eval_ns / 1e9 / max(1, eval_count)) if (eval_ns and eval_count) else (elapsed / chars)

        accepted = _accept_polished(text, candidate)
        status = 'ok' if accepted else 'rejected'
        slow = sec_per_char > cfg.slow_sec_per_char
        with self.lock:
            self._last_metrics = dict(
                status=status,
                chars=len(text),
                elapsed=round(elapsed, 3),
                sec_per_char=round(sec_per_char, 4),
                slow=slow,
            )
        # Never log user text — timing and counts only.
        self._log(
            f'[polish] chars={len(text)} elapsed={elapsed:.3f}s '
            f'per_char={sec_per_char:.4f}s status={status}'
        )
        if slow:
            self._log(
                f'[polish] WARNING slow generation: {sec_per_char:.3f}s/char > '
                f'{cfg.slow_sec_per_char:.3f}s/char (check GPU VRAM / keep_alive={cfg.keep_alive})'
            )
        return candidate if accepted else text

    def status(self):
        with self.lock:
            self._reload()
            return dict(
                enabled=self.config.enabled and bool(self.config.endpoint),
                model=self.config.model,
                keep_alive=self.config.keep_alive,
                file=str(self.path) if self.path else '',
                last=self._last_metrics,
            )
