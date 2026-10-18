"""Small protocol tests without a downloaded model or GPU."""
import importlib.util
from pathlib import Path
import unittest
import http.client
import json
import threading
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("qwen_server", Path(__file__).with_name("qwen-server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class QwenProtocolTests(unittest.TestCase):
    def payload(self):
        return dict(model=server.MODEL_ID, response_format="pcm", input="Конь на эф три.",
                    voice="Ryan", language="Russian", instructions="Measured delivery.")

    def test_request(self):
        self.assertEqual(server.validate(self.payload())[:3], ("Конь на эф три.", "Ryan", "Russian"))

    def test_invalid_fields(self):
        for field, value in [("input", ""), ("input", "x" * 4001), ("voice", "onyx"),
                             ("voice", []), ("language", "invalid"), ("response_format", "wav"),
                             ("model", "other/model"), ("instructions", None)]:
            with self.subTest(field=field, value=str(value)[:20]):
                payload = self.payload()
                payload[field] = value
                with self.assertRaises(ValueError):
                    server.validate(payload)

    def test_pcm_resampling_preserves_duration_and_finite_range(self):
        import numpy as np
        for rate in [24000, 48000, 44100]:
            pcm = server.pcm24(np.sin(np.arange(rate) * 0.1), rate)
            self.assertEqual(len(pcm), 48000)
        with self.assertRaises(ValueError):
            server.pcm24(np.array([float("nan")]), 24000)

    def test_http_contract_and_browser_rejection(self):
        import numpy as np
        calls = []
        cleaned = []
        class Model:
            def generate_custom_voice(self, **kwargs):
                calls.append(kwargs)
                yield SimpleNamespace(audio=np.ones(2400) * 0.1, sample_rate=24000, token_count=2)
        http_server = server.ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(Model(), lambda: cleaned.append(True)))
        thread = threading.Thread(target=http_server.serve_forever, daemon=True)
        thread.start()
        try:
            client = http.client.HTTPConnection("127.0.0.1", http_server.server_port, timeout=5)
            client.request("POST", "/v1/audio/speech", json.dumps(self.payload()), {"Content-Type": "application/json"})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "audio/pcm")
            self.assertEqual(len(response.read()), 4800)
            client.close()
            self.assertEqual(calls[0]["language"], "Russian")
            self.assertEqual(len(cleaned), 1)
            client = http.client.HTTPConnection("127.0.0.1", http_server.server_port, timeout=5)
            client.request("POST", "/v1/audio/speech", json.dumps(self.payload()), {"Origin": "https://example.com"})
            self.assertEqual(client.getresponse().status, 403)
            client.close()
            self.assertEqual(len(calls), 1)
        finally:
            http_server.shutdown()
            http_server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
