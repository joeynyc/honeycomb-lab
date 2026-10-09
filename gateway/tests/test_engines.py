"""Tests for gateway/engines.py — same fixtures as the Swift side
(Tests/HoneycombTests/ProbeParsersTests.swift) so both frontends parse
the fleet identically. Run: python3 -m unittest discover gateway/tests
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import engines  # noqa: E402


class MetricsFromPrometheus(unittest.TestCase):
    def test_vllm(self):
        prom = (
            "# HELP vllm:kv_cache_usage_perc KV-cache usage. 1 means 100 percent usage.\n"
            "# TYPE vllm:kv_cache_usage_perc gauge\n"
            'vllm:kv_cache_usage_perc{model_name="qwen2.5-7b"} 0.42\n'
            'vllm:num_requests_running{model_name="qwen2.5-7b"} 3.0\n'
            'vllm:generation_tokens_total{model_name="qwen2.5-7b"} 123456.0\n'
        )
        m = engines.metrics_from_prometheus(prom)
        self.assertAlmostEqual(m["kvCachePct"], 42.0)
        self.assertEqual(m["runningRequests"], 3)
        self.assertAlmostEqual(m["genTokensTotal"], 123456.0)

    def test_sglang(self):
        prom = (
            'sglang:token_usage{model_name="qwen3-32b"} 0.17\n'
            'sglang:num_running_reqs{model_name="qwen3-32b"} 2.0\n'
            'sglang:cache_hit_rate{model_name="qwen3-32b"} 0.61\n'
            'sglang:generation_tokens_total{model_name="qwen3-32b"} 98765.0\n'
        )
        m = engines.metrics_from_prometheus(prom)
        self.assertAlmostEqual(m["kvCachePct"], 17.0)
        self.assertEqual(m["runningRequests"], 2)
        self.assertAlmostEqual(m["genTokensTotal"], 98765.0)

    def test_llamacpp(self):
        prom = (
            "llamacpp:kv_cache_usage_ratio 0.25\n"
            "llamacpp:requests_processing 1\n"
            "llamacpp:tokens_predicted_total 4242\n"
        )
        m = engines.metrics_from_prometheus(prom)
        self.assertAlmostEqual(m["kvCachePct"], 25.0)
        self.assertEqual(m["runningRequests"], 1)
        self.assertAlmostEqual(m["genTokensTotal"], 4242.0)

    def test_missing_gauges(self):
        self.assertEqual(engines.metrics_from_prometheus("# nothing here\n"), {})


class RunningInferenceContainers(unittest.TestCase):
    mixed = (
        "agents-a1-nvfp4\tnvcr.io/nvidia/vllm:26.06-py3\n"
        "minimax-model-nfs\tgists/nfs-server:latest\n"
        "hermes-firecrawl-api\tghcr.io/firecrawl/firecrawl:latest\n"
        "hermes-searxng\tsearxng/searxng:latest\n"
    )

    def test_picks_vllm_only(self):
        self.assertEqual(
            engines.running_inference_containers(self.mixed), ["agents-a1-nvfp4"]
        )

    def test_includes_preferred_non_vllm(self):
        self.assertEqual(
            engines.running_inference_containers(self.mixed, "hermes-searxng"),
            ["agents-a1-nvfp4", "hermes-searxng"],
        )

    def test_preferred_not_running_ignored(self):
        self.assertEqual(
            engines.running_inference_containers(self.mixed, "nemotron-puzzle-75b"),
            ["agents-a1-nvfp4"],
        )

    def test_empty(self):
        self.assertEqual(engines.running_inference_containers(""), [])

    def test_case_insensitive_image(self):
        self.assertEqual(
            engines.running_inference_containers("qwen\tNVCR.IO/NVIDIA/VLLM:latest\n"),
            ["qwen"],
        )

    def test_matches_sglang_and_llama_images(self):
        text = (
            "sg1\tlmsysorg/sglang:latest\n"
            "cpp1\tghcr.io/ggml-org/llama.cpp:server\n"
            "redis\tredis:7\n"
        )
        self.assertEqual(
            engines.running_inference_containers(text), ["sg1", "cpp1"]
        )


class ServeFromDockerInspect(unittest.TestCase):
    def test_port_from_arg_array_cmd(self):
        text = 'null ["vllm","serve","deepseek-ai/DeepSeek-V4","--port","8888","--host","0.0.0.0"]'
        engine, port = engines.serve_from_docker_inspect(text)
        self.assertEqual(engine.name, "vllm")
        self.assertEqual(port, 8888)

    def test_port_inside_bash_wrapper_string(self):
        text = (
            'null ["bash","-lc","export PATH=...; exec /usr/local/bin/vllm serve'
            ' deepseek-ai/DeepSeek-V4-Flash-DSpark --port 8888 --tensor-parallel-size 2"]'
        )
        engine, port = engines.serve_from_docker_inspect(text)
        self.assertEqual(engine.name, "vllm")
        self.assertEqual(port, 8888)

    def test_port_equals_form(self):
        text = '["vllm","serve"] ["m","--port=9010"]'
        self.assertEqual(engines.serve_from_docker_inspect(text)[1], 9010)

    def test_vllm_defaults_to_8000(self):
        engine, port = engines.serve_from_docker_inspect(
            'null ["vllm","serve","meta-llama/Llama-3.3-70B"]'
        )
        self.assertEqual(engine.name, "vllm")
        self.assertEqual(port, 8000)

    def test_sglang_explicit_port(self):
        text = 'null ["python3","-m","sglang.launch_server","--model-path","Qwen/Qwen3-32B","--port","30001","--tp","2"]'
        engine, port = engines.serve_from_docker_inspect(text)
        self.assertEqual(engine.name, "sglang")
        self.assertEqual(port, 30001)

    def test_sglang_defaults_to_30000(self):
        text = 'null ["bash","-lc","python3 -m sglang.launch_server --model-path Qwen/Qwen3-32B"]'
        engine, port = engines.serve_from_docker_inspect(text)
        self.assertEqual(engine.name, "sglang")
        self.assertEqual(port, 30000)

    def test_llamacpp_explicit_port(self):
        text = '["/app/llama-server"] ["-m","/models/qwen.gguf","--port","9000","-ngl","99"]'
        engine, port = engines.serve_from_docker_inspect(text)
        self.assertEqual(engine.name, "llama.cpp")
        self.assertEqual(port, 9000)

    def test_llamacpp_defaults_to_8080(self):
        engine, port = engines.serve_from_docker_inspect(
            '["/app/llama-server"] ["-m","/models/qwen.gguf"]'
        )
        self.assertEqual(engine.name, "llama.cpp")
        self.assertEqual(port, 8080)

    def test_none_when_no_known_engine(self):
        self.assertEqual(engines.serve_from_docker_inspect(""), (None, None))
        self.assertEqual(
            engines.serve_from_docker_inspect('null ["redis-server"]'), (None, None)
        )

    def test_ignores_garbage_port_values(self):
        # out-of-range port falls back to the engine default, not None
        text = 'null ["vllm","serve","m","--port","999999"]'
        self.assertEqual(engines.serve_from_docker_inspect(text)[1], 8000)

    def test_detection_priority_vllm_over_llama(self):
        # a vLLM serve of a llama model must match vllm, not llama.cpp
        engine, _ = engines.serve_from_docker_inspect(
            'null ["vllm","serve","meta-llama/Llama-3.3-70B"]'
        )
        self.assertEqual(engine.name, "vllm")


class ModelsFromJSON(unittest.TestCase):
    def test_openai_list(self):
        raw = '{"object":"list","data":[{"id":"qwen2.5-7b"},{"id":"llama-3.2-3b"}]}'
        self.assertEqual(engines.models_from_json(raw), ["qwen2.5-7b", "llama-3.2-3b"])

    def test_lmstudio_shape(self):
        self.assertEqual(
            engines.models_from_json('{"models":[{"id":"mistral-nemo-12b"}]}'),
            ["mistral-nemo-12b"],
        )

    def test_ollama_tags(self):
        raw = '{"models":[{"name":"llama3:8b"},{"model":"phi3:mini"}]}'
        self.assertEqual(engines.models_from_json(raw), ["llama3:8b", "phi3:mini"])

    def test_empty_list(self):
        self.assertEqual(engines.models_from_json('{"object":"list","data":[]}'), [])

    def test_garbage(self):
        self.assertEqual(engines.models_from_json("not json"), [])
        self.assertEqual(engines.models_from_json(b"not json"), [])

    def test_bytes_input(self):
        self.assertEqual(
            engines.models_from_json(b'{"data":[{"id":"m1"}]}'), ["m1"]
        )

    def test_lmstudio_v0_filters_to_loaded(self):
        raw = """{"data":[
            {"id":"qwen2.5-7b-instruct","state":"loaded"},
            {"id":"mistral-nemo-12b","state":"not-loaded"}
        ]}"""
        ids, loaded_only = engines.models_listing_from_json(raw)
        self.assertEqual(ids, ["qwen2.5-7b-instruct"])
        self.assertTrue(loaded_only)
        self.assertEqual(engines.models_from_json(raw), ["qwen2.5-7b-instruct"])

    def test_lmstudio_v0_empty_loaded_is_still_loaded_only(self):
        raw = '{"data":[{"id":"mistral-nemo-12b","state":"not-loaded"}]}'
        ids, loaded_only = engines.models_listing_from_json(raw)
        self.assertEqual(ids, [])
        self.assertTrue(loaded_only)


# Fixtures copied from Tests/HoneycombTests/ProbeParsersTests.swift so both
# frontends stay pinned to identical lms CLI parsing.

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


class LMStudioLoadedModels(unittest.TestCase):
    def test_local_excludes_peer_rows(self):
        self.assertEqual(
            engines.lm_studio_loaded_models(
                _LMS_PS, device_filter=None, exclude_devices=["gaming-pc"]
            ),
            ["qwen2.5-7b-instruct", "text-embedding-nomic"],
        )

    def test_device_filter_keeps_only_peer(self):
        self.assertEqual(
            engines.lm_studio_loaded_models(_LMS_PS, device_filter="gaming-pc"),
            ["llama-3.2-3b-instruct"],
        )

    def test_none_loaded(self):
        text = "No models are currently loaded.\nTo load a model, use lms load."
        self.assertEqual(
            engines.lm_studio_loaded_models(text, device_filter=None), []
        )

    def test_skips_header_and_hint_rows(self):
        text = (
            "IDENTIFIER   TYPE   SIZE\n"
            "To load a model, run lms load\n"
            "SIZE totals: 4.68 GB\n"
        )
        self.assertEqual(
            engines.lm_studio_loaded_models(text, device_filter=None), []
        )


class LMLinkPeerConnected(unittest.TestCase):
    def test_connected(self):
        self.assertTrue(
            engines.lm_link_peer_connected(_LINK_STATUS, "gaming-pc")
        )

    def test_offline(self):
        self.assertFalse(
            engines.lm_link_peer_connected(_LINK_STATUS, "old-laptop")
        )

    def test_missing_does_not_inherit_other_peer(self):
        # "connected" appears for another peer; unknown names must not
        # inherit it via the fallback unless the name also appears.
        self.assertFalse(
            engines.lm_link_peer_connected(_LINK_STATUS, "no-such-box")
        )

    def test_case_insensitive(self):
        self.assertTrue(
            engines.lm_link_peer_connected(_LINK_STATUS, "Gaming-PC")
        )

    def test_disconnected_is_not_connected(self):
        text = "Peers:\n- gaming-pc\n  Status: disconnected\n"
        self.assertFalse(engines.lm_link_peer_connected(text, "gaming-pc"))

    def test_fallback_ignores_disconnected(self):
        self.assertFalse(
            engines.lm_link_peer_connected("gaming-pc disconnected", "gaming-pc")
        )

    def test_peer_name_is_not_a_substring_match(self):
        # Peer "pc" must not claim the "gaming-pc" block's status.
        text = "Peers:\n- gaming-pc\n  Status: connected\n- pc\n  Status: offline\n"
        self.assertFalse(engines.lm_link_peer_connected(text, "pc"))

    def test_peer_label_with_suffix(self):
        text = "Peers:\n- gaming-pc (Windows)\n  Status: connected\n"
        self.assertTrue(engines.lm_link_peer_connected(text, "gaming-pc"))


class LMStudioModelsOnDevice(unittest.TestCase):
    def test_models_on_device(self):
        text = """
        LLM MODELS                      PARAMS   DEVICE      SIZE
        llama-3.2-3b-instruct           3B       gaming-pc   2.02 GB
        qwen2.5-7b-instruct             7B       local       4.68 GB
        mistral-nemo-12b                12B      gaming-pc   7.10 GB
        """
        self.assertEqual(
            engines.lm_studio_models_on_device(text, "gaming-pc"),
            ["llama-3.2-3b-instruct", "mistral-nemo-12b"],
        )


if __name__ == "__main__":
    unittest.main()
