"""Wiring tests for gateway/nodes.py hub and LM Link probes.

Parser fixtures live in test_engines.py (twins of ProbeParsersTests.swift).
These checks make sure the probes actually call those parsers the way
HealthMonitor does — models from `lms ps`, not the HTTP catalog.
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import nodes  # noqa: E402

_LMS_PS = """
       IDENTIFIER                     TYPE   DEVICE       SIZE      CONTEXT
       qwen2.5-7b-instruct            LLM    local        4.68 GB   32768
       llama-3.2-3b-instruct          LLM    gaming-pc    2.02 GB   8192
       text-embedding-nomic           EMBEDDING local     0.55 GB   2048
"""

_LINK_STATUS = """
    LM Link
    Status: Online

    Peers:
    - gaming-pc
      Status: connected
      Models: 2
    - old-laptop
      Status: offline
"""

_LMS_LS = """
        LLM MODELS                      PARAMS   DEVICE      SIZE
        llama-3.2-3b-instruct           3B       gaming-pc   2.02 GB
        qwen2.5-7b-instruct             7B       local       4.68 GB
        mistral-nemo-12b                12B      gaming-pc   7.10 GB
"""


def _lms_output(args, timeout=8.0):
    if args == ["ps"]:
        return _LMS_PS
    if args == ["link", "status"]:
        return _LINK_STATUS
    if args == ["ls"]:
        return _LMS_LS
    return ""


class HubProbe(unittest.TestCase):
    def test_models_come_from_lms_ps_not_http_catalog(self):
        node = {
            "id": "hub",
            "name": "Hub",
            "baseURL": "http://127.0.0.1:1234",
            "probe": "lmstudio-hub",
        }
        with (
            patch.object(nodes, "_lms_output", side_effect=_lms_output),
            patch.object(
                nodes,
                "_http_models",
                return_value=(True, ["catalog-model-must-not-appear"], 11.0),
            ),
            patch.object(nodes, "_peer_names", return_value=["gaming-pc"]),
        ):
            result = nodes._probe_lmstudio_hub(node)
        self.assertEqual(
            result["models"],
            ["qwen2.5-7b-instruct", "text-embedding-nomic"],
        )
        self.assertTrue(result["inferenceOK"])
        self.assertEqual(result["pathBadge"], "LMS")
        self.assertIn("lm-link", result["detail"])
        self.assertIn("2 loaded", result["detail"])
        self.assertNotIn("catalog-model-must-not-appear", result["models"])


class LMLinkPeerProbe(unittest.TestCase):
    def test_connected_peer_uses_device_filter_and_http(self):
        node = {
            "id": "pc",
            "name": "Gaming PC",
            "baseURL": "http://127.0.0.1:1234",
            "probe": "lmlink-peer",
            "lmLinkPeer": "gaming-pc",
        }
        with (
            patch.object(nodes, "_lms_output", side_effect=_lms_output),
            patch.object(
                nodes, "_http_models", return_value=(True, ["ignored-catalog"], 9.0)
            ),
        ):
            result = nodes._probe_lmlink_peer(node)
        self.assertEqual(result["models"], ["llama-3.2-3b-instruct"])
        self.assertTrue(result["inferenceOK"])
        self.assertEqual(result["health"], "online")
        self.assertEqual(result["pathBadge"], "LM LINK")
        self.assertIn("1 loaded on gaming-pc", result["detail"])

    def test_offline_peer_does_not_inherit_connected_status(self):
        node = {
            "id": "old",
            "name": "Old Laptop",
            "baseURL": "http://127.0.0.1:1234",
            "probe": "lmlink-peer",
            "lmLinkPeer": "old-laptop",
        }
        with (
            patch.object(nodes, "_lms_output", side_effect=_lms_output),
            patch.object(
                nodes, "_http_models", return_value=(True, ["x"], 9.0)
            ),
        ):
            result = nodes._probe_lmlink_peer(node)
        self.assertEqual(result["health"], "offline")
        self.assertFalse(result["inferenceOK"])
        self.assertEqual(result["pathBadge"], "DOWN")
        self.assertEqual(result["models"], [])

    def test_disk_inventory_when_nothing_loaded_on_peer(self):
        empty_ps = "No models are currently loaded.\n"

        def lms(args, timeout=8.0):
            if args == ["ps"]:
                return empty_ps
            if args == ["link", "status"]:
                return _LINK_STATUS
            if args == ["ls"]:
                return _LMS_LS
            return ""

        node = {
            "id": "pc",
            "name": "Gaming PC",
            "baseURL": "http://127.0.0.1:1234",
            "lmLinkPeer": "gaming-pc",
        }
        with (
            patch.object(nodes, "_lms_output", side_effect=lms),
            patch.object(
                nodes, "_http_models", return_value=(True, [], 9.0)
            ),
        ):
            result = nodes._probe_lmlink_peer(node)
        self.assertEqual(result["models"], [])
        self.assertIn("2 on disk · none loaded", result["detail"])


class SSHServeProbe(unittest.TestCase):
    def test_historical_and_alias_names_share_the_probe(self):
        self.assertIs(nodes._PROBES["ssh-serve"], nodes._PROBES["vllm-ssh"])
        self.assertTrue(nodes._is_ssh_serve("vllm-ssh"))
        self.assertTrue(nodes._is_ssh_serve("ssh-serve"))
        self.assertFalse(nodes._is_ssh_serve("http-only"))
        self.assertFalse(nodes._is_ssh_serve(None))


if __name__ == "__main__":
    unittest.main()
