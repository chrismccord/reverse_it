import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class BinaryVerificationTest(unittest.TestCase):
    def check_messages(self, messages):
        class Socket:
            def __init__(self, url, **callbacks):
                self.callbacks = callbacks

            def send(self, *args, **kwargs):
                pass

            def close(self):
                self.callbacks["on_close"](self, 1000, "")

            def run_forever(self, **kwargs):
                for message in messages:
                    self.callbacks["on_message"](self, message)
                self.close()

        websocket = SimpleNamespace(WebSocketApp=Socket, ABNF=SimpleNamespace(OPCODE_BINARY=2))
        spec = importlib.util.spec_from_file_location(
            "client", Path(__file__).with_name("python_client.py")
        )
        client = importlib.util.module_from_spec(spec)
        with patch.dict("sys.modules", {"requests": SimpleNamespace(), "websocket": websocket}):
            spec.loader.exec_module(client)
        with patch.object(client, "log"):
            return client.test_websocket()

    def text_checks(self):
        return [
            "Backend echo: Hello from Python!",
            "Backend echo: ",
            "Backend echo: " + "A" * 10000,
            *[f"Backend echo: Rapid message {i}" for i in range(1, 6)],
        ]

    def test_missing_binary_fails(self):
        self.assertFalse(self.check_messages(self.text_checks()))

    def test_binary_looking_text_fails(self):
        self.assertFalse(self.check_messages(self.text_checks() + ["\x01\x02\x03\x04\x05"]))

    def test_wrong_binary_payload_fails(self):
        self.assertFalse(self.check_messages(self.text_checks() + [bytes([5, 4, 3, 2, 1])]))

    def test_all_five_distinct_checks_pass(self):
        self.assertTrue(self.check_messages(self.text_checks() + [bytes([1, 2, 3, 4, 5])]))

    def test_duplicate_replies_do_not_replace_missing_checks(self):
        self.assertFalse(self.check_messages(
            [self.text_checks()[0]] * 5 + [bytes([1, 2, 3, 4, 5])]
        ))

    def test_missing_rapid_messages_fail(self):
        self.assertFalse(self.check_messages(
            self.text_checks()[:3] + ["Backend echo: Rapid message 5", bytes([1, 2, 3, 4, 5])]
        ))


if __name__ == "__main__":
    unittest.main()
