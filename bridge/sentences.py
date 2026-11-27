"""Sentence-by-sentence recognition while the phone is still recording.

The live preview marks each pause in the speech. The audio up to that pause
is sent to the accurate desktop model and then polished, while the user keeps
talking, so the draft on the phone turns into finished sentences one by one.
These results are for the live draft only: the pause marks can land inside a
word, so at stop the whole recording is recognized again and that text, after
one paragraph pass, is the result. Everything stays in memory.
"""
from __future__ import annotations
import queue
import threading

RATE = 16000
# Shorter slices (a cough, a click) are not worth a recognition round trip.
MIN_SEGMENT_BYTES = RATE * 2 * 3 // 10
MAX_SENTENCES = 400


def join_text(parts):
    """Join sentences: no space between Chinese, one space between English."""
    result = ''
    for part in parts:
        part = (part or '').strip()
        if not part:
            continue
        if result and result[-1].isascii() and not result[-1].isspace() and part[0].isascii() and part[0].isalnum():
            result += ' '
        result += part
    return result


class SentencePipeline:
    """One per recording. `recognize(pcm_s16, index)` returns raw text from
    the accurate model; `polish(raw)` returns the text to show."""

    def __init__(self, recognize, polish):
        self.recognize, self.polish = recognize, polish
        self.lock = threading.Lock()
        self.items = []
        self.failed = False
        self.finishing = False
        self.queue = queue.Queue()
        self.thread = threading.Thread(target=self._run, name='sentence-pipeline', daemon=True)
        self.thread.start()

    @property
    def count(self):
        with self.lock:
            return len(self.items)

    @property
    def end(self):
        """Byte offset in the recording where the last queued sentence ends."""
        with self.lock:
            return self.items[-1]['end'] if self.items else 0

    def add(self, end, pcm, draft):
        """Queue the audio of one finished sentence, `pcm` ending at byte `end`."""
        with self.lock:
            if self.finishing or len(self.items) >= MAX_SENTENCES:
                self.failed = True
                return
            item = dict(end=end, draft=draft, raw=None, text=None)
            self.items.append(item)
        self.queue.put((item, len(self.items) - 1, pcm))

    def _run(self):
        while True:
            entry = self.queue.get()
            if entry is None:
                return
            item, index, pcm = entry
            # After stop or cancel nobody shows these any more; skip them so
            # the desktop model is free for the whole-recording pass.
            if self.finishing:
                continue
            try:
                raw = self.recognize(pcm, index) if len(pcm) >= MIN_SEGMENT_BYTES else ''
                if not isinstance(raw, str):
                    raise ValueError('Invalid recognition result')
            except Exception:
                with self.lock:
                    self.failed = True
                continue
            text = raw
            if raw.strip() and not self.finishing:
                try:
                    text = self.polish(raw)
                except Exception:
                    text = raw
            with self.lock:
                item['raw'], item['text'] = raw, text

    def display(self, live):
        """Finished sentences, drafts of those still in flight, then the
        sentence being spoken now."""
        with self.lock:
            parts = [item['text'] if item['text'] is not None else item['draft'] for item in self.items]
        return join_text(parts + [live])

    def abandon(self):
        with self.lock:
            self.finishing = True
        self.queue.put(None)
