#!/usr/bin/env python3
"""Loopback-only Qwen3-TTS adapter. The app contract is mono signed PCM16 at 24 kHz."""
import argparse
import json
import math
import os
from pathlib import Path
import select
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"
VOICES = {"Ryan", "Aiden", "Uncle_Fu", "Dylan", "Eric", "Vivian", "Serena", "Ono_Anna", "Sohee"}


def validate(payload):
    if not isinstance(payload, dict):
        raise ValueError("object_required")
    if payload.get("model") != MODEL_ID or payload.get("response_format") != "pcm":
        raise ValueError("unsupported_format_or_model")
    text, voice = payload.get("input"), payload.get("voice")
    language, instructions = payload.get("language"), payload.get("instructions", "")
    if not isinstance(text, str) or not text.strip() or len(text) > 4000:
        raise ValueError("invalid_text")
    if not isinstance(voice, str) or voice not in VOICES:
        raise ValueError("invalid_voice")
    if language not in ("Russian", "English"):
        raise ValueError("invalid_language")
    if not isinstance(instructions, str) or len(instructions) > 500:
        raise ValueError("invalid_instructions")
    return text.strip(), voice, language, instructions


def pcm24(audio, sample_rate):
    import numpy as np
    from scipy.signal import resample_poly
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if not len(audio) or not np.isfinite(audio).all():
        raise ValueError("invalid_audio")
    if sample_rate != 24000:
        divisor = math.gcd(sample_rate, 24000)
        audio = resample_poly(audio, 24000 // divisor, sample_rate // divisor)
    return (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()


def make_handler(model, cleanup=lambda: None):
    generation_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No text, request headers, or model output in logs.

        def reply(self, status, body, content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            if self.path != "/health":
                self.reply(404, b'{}')
                return
            self.reply(200, json.dumps({"service": "chessarena-qwen-tts-v1", "model": MODEL_ID}).encode())

        def disconnected(self):
            ready, _, _ = select.select([self.connection], [], [], 0)
            if not ready:
                return False
            try:
                return self.connection.recv(1, socket.MSG_PEEK) == b""
            except OSError:
                return True

        def do_POST(self):
            if self.path != "/v1/audio/speech":
                self.reply(404, b'{}')
                return
            # This endpoint serves the native app, not arbitrary browser pages.
            if self.headers.get("Origin") or self.headers.get("Transfer-Encoding"):
                self.reply(403, b'{"error":"unsupported_request"}')
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 32768:
                    raise ValueError("invalid_length")
                self.connection.settimeout(10)
                text, voice, language, instructions = validate(json.loads(self.rfile.read(length)))
            except (ValueError, TypeError, OSError):
                self.reply(400, b'{"error":"invalid_request"}')
                return
            if not generation_lock.acquire(blocking=False):
                self.reply(503, b'{"error":"busy"}')
                return
            started = time.monotonic()
            try:
                chunks = []
                size = 0
                tokens = 0
                # Streaming internally lets a cancelled HTTP request release the model promptly.
                results = model.generate_custom_voice(
                    text=text, speaker=voice, language=language, instruct=instructions,
                    stream=True, streaming_interval=0.5, max_tokens=1500,
                )
                try:
                    for result in results:
                        if self.disconnected():
                            return
                        if time.monotonic() - started > 110:
                            raise TimeoutError("synthesis_timeout")
                        tokens += result.token_count
                        if tokens >= 1500:
                            raise ValueError("synthesis_too_long")
                        chunk = pcm24(result.audio, result.sample_rate)
                        size += len(chunk)
                        if size > 10_000_000:
                            raise ValueError("audio_too_large")
                        chunks.append(chunk)
                finally:
                    results.close()
                    # Closing a generator early skips mlx-audio's normal end-of-stream cleanup.
                    cleanup()
                if not chunks:
                    raise ValueError("empty_audio")
                self.reply(200, b"".join(chunks), "audio/pcm")
                print(f"speech ok bytes={size} seconds={time.monotonic() - started:.2f}", flush=True)
            except Exception as error:
                # Report only the exception type, never source text or raw model errors.
                print(f"speech failed type={type(error).__name__}", flush=True)
                self.reply(500, b'{"error":"synthesis_failed"}')
            finally:
                generation_lock.release()

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()
    if args.parent_pid:
        def watch_parent():
            while True:
                time.sleep(2)
                if os.getppid() != args.parent_pid:
                    os._exit(0)
        threading.Thread(target=watch_parent, daemon=True).start()

    from mlx_audio.tts.utils import load_model
    print("Loading local Qwen3-TTS 1.7B…", flush=True)
    model = load_model(str(args.model.resolve()))
    def cleanup():
        import mlx.core as mx
        model.speech_tokenizer.decoder.reset_streaming_state()
        mx.clear_cache()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(model, cleanup))
    server.daemon_threads = True
    print(f"Ready: http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
