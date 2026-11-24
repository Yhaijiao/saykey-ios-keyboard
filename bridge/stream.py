"""Optional live preview: a small streaming model turns audio chunks into draft
text while the phone is still recording. The accurate desktop model still
produces the final text after stop. Everything stays in memory."""
from __future__ import annotations
from pathlib import Path
import sys
import threading

RATE = 16000
MAX_PREVIEW_CHARS = 4000
MODEL_FILES = ('tokens.txt', 'encoder.int8.onnx', 'decoder.int8.onnx')


def _join(left, right):
    if not left or not right:
        return left + right
    # Keep a space between English words, none between Chinese characters.
    if left[-1].isascii() and left[-1].isalnum() and right[0].isascii() and right[0].isalnum():
        return left + ' ' + right
    return left + right


class LivePreview:
    """Streaming Paraformer (sherpa-onnx). Load once; one session per recording."""
    def __init__(self, model_dir, threads=2):
        model_dir = Path(model_dir)
        missing = [name for name in MODEL_FILES if not (model_dir / name).is_file()]
        if missing:
            raise FileNotFoundError(f'Streaming model files missing in {model_dir}: {", ".join(missing)}')
        import sherpa_onnx
        self.recognizer = sherpa_onnx.OnlineRecognizer.from_paraformer(
            tokens=str(model_dir / 'tokens.txt'), encoder=str(model_dir / 'encoder.int8.onnx'),
            decoder=str(model_dir / 'decoder.int8.onnx'), num_threads=threads, sample_rate=RATE,
            feature_dim=80, enable_endpoint_detection=True, rule1_min_trailing_silence=2.4,
            rule2_min_trailing_silence=1.2, rule3_min_utterance_length=20,
            decoding_method='greedy_search')

    def session(self):
        return PreviewSession(self.recognizer)


class PreviewSession:
    def __init__(self, recognizer):
        self.recognizer = recognizer
        self.stream = recognizer.create_stream()
        self.committed = ''
        self.lock = threading.Lock()
        # Samples fed so far, and one (end sample, draft text) per finished
        # utterance. The relay cuts the audio at these pauses so each
        # sentence can be recognized and polished while the next is spoken.
        self.fed = 0
        self.current = ''
        self.utterances = []

    def feed(self, pcm_s16):
        """Feed int16 little-endian mono 16 kHz bytes; return the draft so far."""
        import numpy
        samples = numpy.frombuffer(pcm_s16, dtype='<i2').astype(numpy.float32) / 32768.0
        with self.lock:
            if len(samples):
                self.stream.accept_waveform(RATE, samples)
                self.fed += len(samples)
            while self.recognizer.is_ready(self.stream):
                self.recognizer.decode_stream(self.stream)
            current = self.recognizer.get_result(self.stream).strip()
            if self.recognizer.is_endpoint(self.stream):
                # Each pause ends an utterance; keep its text and start fresh so
                # a five-minute recording never grows one huge stream.
                self.committed = _join(self.committed, current)
                if current:
                    self.utterances.append((self.fed, current))
                current = ''
                self.recognizer.reset(self.stream)
            self.current = current
            return _join(self.committed, current)[-MAX_PREVIEW_CHARS:]


def load(model_dir):
    """Load the preview model, or explain clearly why it cannot be used."""
    try:
        return LivePreview(model_dir)
    except ImportError:
        sys.exit('Live preview needs sherpa-onnx and numpy: pip install -r bridge/requirements-stream.txt')
    except FileNotFoundError as error:
        sys.exit(str(error))
