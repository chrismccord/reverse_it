import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class HTTPStatusTest(unittest.TestCase):
    def check_responses(self, failing_path=None):
        def response(url, **kwargs):
            path = url.removeprefix("http://localhost:4000")
            status = 502 if path == failing_path else 404 if path == "/nonexistent" else 200
            return SimpleNamespace(
                status_code=status, text="hello", json=lambda: {"echo": "hello", "headers": {}}
            )

        requests = SimpleNamespace(get=response, post=response)
        spec = importlib.util.spec_from_file_location(
            "client", Path(__file__).with_name("python_client.py")
        )
        client = importlib.util.module_from_spec(spec)
        with patch.dict("sys.modules", {"requests": requests, "websocket": SimpleNamespace()}):
            spec.loader.exec_module(client)
        with patch.object(client, "log"):
            return client.test_http()

    def test_unexpected_status_at_each_endpoint_fails(self):
        for path in ["/hello", "/api/status", "/echo", "/headers", "/nonexistent"]:
            with self.subTest(path=path):
                self.assertFalse(self.check_responses(path))

    def test_expected_responses_including_404_pass(self):
        self.assertTrue(self.check_responses())


if __name__ == "__main__":
    unittest.main()
