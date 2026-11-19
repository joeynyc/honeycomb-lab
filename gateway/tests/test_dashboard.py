"""Offline regression tests for dashboard map geometry."""

import json
import shutil
import subprocess
import unittest
from pathlib import Path


DASHBOARD_PATH = Path(__file__).resolve().parents[1] / "dashboard.html"


class DashboardGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.node = shutil.which("node")
        if cls.node is None:
            raise unittest.SkipTest("Node.js is required to exercise dashboard geometry")
        cls.source = DASHBOARD_PATH.read_text()

    def view_box(self, nodes):
        source = self.source

        def section(start, end):
            start_index = source.index(start)
            end_index = source.index(end, start_index)
            return source[start_index:end_index]

        axial_to_pixel = section(
            "  function axialToPixel(", "\n  function hexPoints("
        )
        coordinate_filter = ""
        if "  function nodesWithCoordinates(" in source:
            coordinate_filter = section(
                "  function nodesWithCoordinates(", "\n  function computeViewBox("
            )
        compute_view_box = section(
            "  function computeViewBox(", "\n  function renderLattice("
        )
        script = (
            "var HEX_S = 70;\n"
            + axial_to_pixel
            + "\n"
            + coordinate_filter
            + "\n"
            + compute_view_box
            + """
var input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", function (chunk) { input += chunk; });
process.stdin.on("end", function () {
  process.stdout.write(JSON.stringify(computeViewBox(JSON.parse(input))));
});
"""
        )
        result = subprocess.run(
            [self.node, "-e", script],
            input=json.dumps(nodes),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def render_map_state(self, nodes):
        source = self.source

        def section(start, end):
            start_index = source.index(start)
            end_index = source.index(end, start_index)
            return source[start_index:end_index]

        script = (
            "var HEX_S = 70;\n"
            "var nodePositions = {};\n"
            "var hubId = null;\n"
            "var svgState = {};\n"
            "var svg = {setAttribute: function (name, value) { svgState[name] = value; }};\n"
            "var edgeLayer = {children: [], appendChild: function (el) { this.children.push(el); }};\n"
            "var dotLayer = {children: [], appendChild: function (el) { this.children.push(el); }};\n"
            "var renderedNodeIds = [];\n"
            "function svgEl(tag, attrs) { return {tag: tag, attrs: attrs || {}, setAttribute: function (name, value) { this.attrs[name] = value; }}; }\n"
            "function renderLattice() {}\n"
            "function renderNodes(nodes) { renderedNodeIds = nodes.map(function (n) { return n.id; }); }\n"
            "function renderEmptyState() {}\n"
            + section("  function axialToPixel(", "\n  function hexPoints(")
            + "\n"
            + section("  function findHub(", "\n  function nodesWithCoordinates(")
            + "\n"
            + section("  function nodesWithCoordinates(", "\n  function computeViewBox(")
            + "\n"
            + section("  function computeViewBox(", "\n  function renderLattice(")
            + "\n"
            + section("  function healthAlive(", "\n  var animDots")
            + "\n"
            + section("  function renderMap(", "\n  // First-run guidance:")
            + """
var input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", function (chunk) { input += chunk; });
process.stdin.on("end", function () {
  renderMap({nodes: JSON.parse(input), links: []});
  process.stdout.write(JSON.stringify({
    hubId: hubId,
    nodeIds: renderedNodeIds,
    edgeCount: edgeLayer.children.length,
    viewBox: svgState.viewBox
  }));
});
"""
        )
        result = subprocess.run(
            [self.node, "-e", script],
            input=json.dumps(nodes),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_complete_coordinates_produce_finite_view_box(self):
        view_box = self.view_box([{"axial": [0, 0]}, {"axial": [2, -1]}])
        self.assertTrue(
            all(isinstance(value, (int, float)) for value in view_box.values()),
            view_box,
        )

    def test_empty_nodes_keep_the_default_view_box(self):
        self.assertEqual(
            self.view_box([]),
            {"minX": -300, "minY": -300, "w": 600, "h": 600},
        )

    def test_incomplete_pair_does_not_poison_valid_nodes_view_box(self):
        valid_node = {"id": "valid", "axial": [0, 0]}
        expected = self.view_box([valid_node])
        actual = self.view_box([valid_node, {"id": "partial", "axial": [4]}])
        self.assertEqual(actual, expected)

    def test_missing_or_non_numeric_pair_is_ignored(self):
        valid_node = {"id": "valid", "axial": [1, -2]}
        expected = self.view_box([valid_node])
        actual = self.view_box(
            [
                valid_node,
                {"id": "missing"},
                {"id": "null-coordinate", "axial": [2, None]},
            ]
        )
        self.assertEqual(actual, expected)

    def test_incomplete_configured_hub_does_not_connect_valid_peers(self):
        state = self.render_map_state(
            [
                {"id": "hub", "hub": True, "axial": [3], "health": "online"},
                {"id": "peer-a", "axial": [0, 0], "health": "online"},
                {"id": "peer-b", "axial": [1, 0], "health": "online"},
            ]
        )
        self.assertEqual(state["nodeIds"], ["peer-a", "peer-b"])
        self.assertEqual((state["hubId"], state["edgeCount"]), ("hub", 0))


if __name__ == "__main__":
    unittest.main()
