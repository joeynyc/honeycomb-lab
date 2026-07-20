import XCTest
@testable import Honeycomb

final class ProbeParsersTests: XCTestCase {

    // MARK: - lms ps (loaded models)

    private let lmsPS = """
       IDENTIFIER                     TYPE   DEVICE       SIZE      CONTEXT
       qwen2.5-7b-instruct            LLM    local        4.68 GB   32768
       llama-3.2-3b-instruct          LLM    gaming-pc    2.02 GB   8192
       text-embedding-nomic           EMBEDDING local     0.55 GB   2048
    """

    func testLoadedModelsLocalExcludesPeerRows() {
        let models = ProbeParsers.lmStudioLoadedModels(
            in: lmsPS, deviceFilter: nil, excludeDevices: ["gaming-pc"]
        )
        XCTAssertEqual(models, ["qwen2.5-7b-instruct", "text-embedding-nomic"])
    }

    func testLoadedModelsDeviceFilterKeepsOnlyPeer() {
        let models = ProbeParsers.lmStudioLoadedModels(
            in: lmsPS, deviceFilter: "gaming-pc"
        )
        XCTAssertEqual(models, ["llama-3.2-3b-instruct"])
    }

    func testLoadedModelsNoneLoaded() {
        let text = "No models are currently loaded.\nTo load a model, use lms load."
        XCTAssertEqual(
            ProbeParsers.lmStudioLoadedModels(in: text, deviceFilter: nil), []
        )
    }

    func testLoadedModelsSkipsHeaderAndHintRows() {
        let text = """
        IDENTIFIER   TYPE   SIZE
        To load a model, run lms load
        SIZE totals: 4.68 GB
        """
        XCTAssertEqual(
            ProbeParsers.lmStudioLoadedModels(in: text, deviceFilter: nil), []
        )
    }

    // MARK: - lms link status (peer connectivity)

    private let linkStatus = """
    LM Link
    Status: Online

    Peers:
    - gaming-pc
      Status: connected
      Models: 2
    - old-laptop
      Status: offline
    """

    func testLinkPeerConnected() {
        XCTAssertTrue(ProbeParsers.lmLinkPeerConnected(in: linkStatus, name: "gaming-pc"))
    }

    func testLinkPeerOffline() {
        XCTAssertFalse(ProbeParsers.lmLinkPeerConnected(in: linkStatus, name: "old-laptop"))
    }

    func testLinkPeerMissing() {
        // "connected" appears for another peer; unknown names must not
        // inherit it via the fallback unless the name also appears.
        XCTAssertFalse(ProbeParsers.lmLinkPeerConnected(in: linkStatus, name: "no-such-box"))
    }

    func testLinkPeerCaseInsensitive() {
        XCTAssertTrue(ProbeParsers.lmLinkPeerConnected(in: linkStatus, name: "Gaming-PC"))
    }

    // MARK: - lms ls (models on a remote device)

    func testModelsOnDevice() {
        let text = """
        LLM MODELS                      PARAMS   DEVICE      SIZE
        llama-3.2-3b-instruct           3B       gaming-pc   2.02 GB
        qwen2.5-7b-instruct             7B       local       4.68 GB
        mistral-nemo-12b                12B      gaming-pc   7.10 GB
        """
        let models = ProbeParsers.lmStudioModelsOnDevice(in: text, device: "gaming-pc")
        XCTAssertEqual(models, ["llama-3.2-3b-instruct", "mistral-nemo-12b"])
    }

    // MARK: - free -m + nvidia-smi (hardware metrics over SSH)

    func testHardwareMetricsParsesMemoryAndGPU() {
        let output = """
        45312 122880
        87
        """
        let metrics = ProbeParsers.hardwareMetrics(fromFreeAndSMI: output)
        XCTAssertEqual(metrics?.memUsedMB, 45312)
        XCTAssertEqual(metrics?.memTotalMB, 122880)
        XCTAssertEqual(metrics?.gpuUtilPct, 87)
    }

    func testHardwareMetricsGPUOnlyWhenMemLineMalformed() {
        // nvidia-smi N/A row (GB10) — mem line garbled, util line absent
        let metrics = ProbeParsers.hardwareMetrics(fromFreeAndSMI: "Mem: N/A\n")
        XCTAssertNil(metrics?.memUsedMB)
        XCTAssertNil(metrics?.gpuUtilPct)
    }

    // MARK: - vLLM /metrics (Prometheus)

    func testVLLMMetrics() {
        let prom = """
        # HELP vllm:kv_cache_usage_perc KV-cache usage. 1 means 100 percent usage.
        # TYPE vllm:kv_cache_usage_perc gauge
        vllm:kv_cache_usage_perc{model_name="qwen2.5-7b"} 0.42
        vllm:num_requests_running{model_name="qwen2.5-7b"} 3.0
        vllm:generation_tokens_total{model_name="qwen2.5-7b"} 123456.0
        """
        let m = ProbeParsers.vllmMetrics(fromPrometheus: prom)
        XCTAssertEqual(m.kvCachePct ?? 0, 42.0, accuracy: 0.001)
        XCTAssertEqual(m.running, 3)
        XCTAssertEqual(m.genTotal ?? 0, 123456.0, accuracy: 0.001)
    }

    func testVLLMMetricsMissingGauges() {
        let m = ProbeParsers.vllmMetrics(fromPrometheus: "# nothing here\n")
        XCTAssertNil(m.kvCachePct)
        XCTAssertNil(m.running)
        XCTAssertNil(m.genTotal)
    }

    // MARK: - models JSON (/v1/models and /api/tags)

    func testModelsOpenAIList() {
        let json = Data(#"{"object":"list","data":[{"id":"qwen2.5-7b"},{"id":"llama-3.2-3b"}]}"#.utf8)
        XCTAssertEqual(ProbeParsers.models(from: json), ["qwen2.5-7b", "llama-3.2-3b"])
    }

    func testModelsLMStudioShape() {
        let json = Data(#"{"models":[{"id":"mistral-nemo-12b"}]}"#.utf8)
        XCTAssertEqual(ProbeParsers.models(from: json), ["mistral-nemo-12b"])
    }

    func testModelsOllamaTags() {
        let json = Data(#"{"models":[{"name":"llama3:8b"},{"model":"phi3:mini"}]}"#.utf8)
        XCTAssertEqual(ProbeParsers.models(from: json), ["llama3:8b", "phi3:mini"])
    }

    func testModelsEmptyList() {
        let json = Data(#"{"object":"list","data":[]}"#.utf8)
        XCTAssertEqual(ProbeParsers.models(from: json), [])
    }

    func testModelsGarbage() {
        XCTAssertEqual(ProbeParsers.models(from: Data("not json".utf8)), [])
    }

    // MARK: - docker ps (running inference containers)

    private let dockerPsMixed = """
    agents-a1-nvfp4\tnvcr.io/nvidia/vllm:26.06-py3
    minimax-model-nfs\tgists/nfs-server:latest
    hermes-firecrawl-api\tghcr.io/firecrawl/firecrawl:latest
    hermes-searxng\tsearxng/searxng:latest
    """

    func testRunningInferencePicksVLLMOnly() {
        let names = ProbeParsers.runningInferenceContainers(dockerPs: dockerPsMixed)
        XCTAssertEqual(names, ["agents-a1-nvfp4"])
    }

    func testRunningInferenceIncludesPreferredNonVLLM() {
        let names = ProbeParsers.runningInferenceContainers(
            dockerPs: dockerPsMixed,
            preferred: "hermes-searxng"
        )
        XCTAssertEqual(names, ["agents-a1-nvfp4", "hermes-searxng"])
    }

    func testRunningInferencePreferredNotRunningIgnored() {
        let names = ProbeParsers.runningInferenceContainers(
            dockerPs: dockerPsMixed,
            preferred: "nemotron-puzzle-75b"
        )
        XCTAssertEqual(names, ["agents-a1-nvfp4"])
    }

    func testRunningInferenceEmpty() {
        XCTAssertEqual(ProbeParsers.runningInferenceContainers(dockerPs: ""), [])
    }

    func testRunningInferenceCaseInsensitiveImage() {
        let text = "qwen\tNVCR.IO/NVIDIA/VLLM:latest\n"
        XCTAssertEqual(
            ProbeParsers.runningInferenceContainers(dockerPs: text),
            ["qwen"]
        )
    }

    // MARK: - vLLM API port (docker inspect Entrypoint/Cmd)

    func testVLLMPortFromArgArrayCmd() {
        let text = #"null ["vllm","serve","deepseek-ai/DeepSeek-V4","--port","8888","--host","0.0.0.0"]"#
        XCTAssertEqual(ProbeParsers.vllmAPIPort(fromDockerInspect: text), 8888)
    }

    func testVLLMPortInsideBashWrapperString() {
        // bash -lc serve script: the whole command line is one escaped JSON string
        let text = #"null ["bash","-lc","export PATH=...; exec /usr/local/bin/vllm serve deepseek-ai/DeepSeek-V4-Flash-DSpark --port 8888 --tensor-parallel-size 2"]"#
        XCTAssertEqual(ProbeParsers.vllmAPIPort(fromDockerInspect: text), 8888)
    }

    func testVLLMPortEqualsForm() {
        let text = #"["vllm","serve"] ["m","--port=9010"]"#
        XCTAssertEqual(ProbeParsers.vllmAPIPort(fromDockerInspect: text), 9010)
    }

    func testVLLMPortDefaultsTo8000WhenServePresentWithoutFlag() {
        let text = #"null ["vllm","serve","meta-llama/Llama-3.3-70B"]"#
        XCTAssertEqual(ProbeParsers.vllmAPIPort(fromDockerInspect: text), 8000)
    }

    func testVLLMPortNilWhenNoVLLMCommand() {
        XCTAssertNil(ProbeParsers.vllmAPIPort(fromDockerInspect: ""))
        XCTAssertNil(ProbeParsers.vllmAPIPort(fromDockerInspect: #"null ["redis-server"]"#))
    }

    func testVLLMPortIgnoresGarbagePortValues() {
        // out-of-range port falls back to the vLLM default, not nil
        let text = #"null ["vllm","serve","m","--port","999999"]"#
        XCTAssertEqual(ProbeParsers.vllmAPIPort(fromDockerInspect: text), 8000)
    }
}
