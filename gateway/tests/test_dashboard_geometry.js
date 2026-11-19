const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const dashboard = process.env.HONEYCOMB_DASHBOARD_HTML ||
  fs.readFileSync(path.join(__dirname, "../dashboard.html"), "utf8");

function extractFunction(name) {
  const start = dashboard.indexOf(`function ${name}(`);
  if (start === -1) return null;
  const open = dashboard.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < dashboard.length; i++) {
    if (dashboard[i] === "{") depth++;
    if (dashboard[i] === "}") depth--;
    if (depth === 0) return dashboard.slice(start, i + 1);
  }
  assert.fail(`unterminated dashboard function ${name}`);
}

function createLayer() {
  const layer = {
    children: [],
    appendChild(element) { this.children.push(element); }
  };
  Object.defineProperty(layer, "innerHTML", {
    set() { this.children = []; }
  });
  return layer;
}

const geometry = vm.createContext({
  latticeLayer: createLayer(),
  svgEl: (tag, attrs) => ({ tag, attrs })
});
vm.runInContext([
  "var HEX_S = 70;",
  ...["axialToPixel", "hexPoints", "hexDisk", "computeViewBox", "latticeCells", "renderLattice"]
    .map(extractFunction)
    .filter(Boolean)
].join("\n"), geometry);

function polygonPoints(axial) {
  const p = geometry.axialToPixel(axial[0], axial[1], 70);
  return geometry.hexPoints(p.x, p.y, 70 * 0.94);
}

function renderedPolygons(nodes) {
  const layer = createLayer();
  geometry.latticeLayer = layer;
  geometry.renderLattice(nodes, geometry.computeViewBox(nodes));
  return layer.children.map((element) => element.attrs.points);
}

function originRenderedPolygons(nodes) {
  const vb = geometry.computeViewBox(nodes);
  const occupied = new Set(nodes.map((node) => node.axial.join(",")));
  return Array.from(geometry.hexDisk(3))
    .filter(([q, r]) => {
      const p = geometry.axialToPixel(q, r, 70);
      return p.x >= vb.minX - 70 && p.x <= vb.minX + vb.w + 70 &&
        p.y >= vb.minY - 70 && p.y <= vb.minY + vb.h + 70;
    })
    .filter(([q, r]) => !occupied.has(`${q},${r}`))
    .map(([q, r]) => polygonPoints([q, r]));
}

test("keeps the origin-centered rendered lattice for ordinary layouts", () => {
  const nodes = [{ axial: [0, 0] }, { axial: [1, 0] }];
  assert.deepEqual(renderedPolygons(nodes), originRenderedPolygons(nodes));
});

test("keeps the existing rendered lattice for an empty layout", () => {
  assert.deepEqual(renderedPolygons([]), originRenderedPolygons([]));
});

test("renders background polygons around a positive-offset cluster", () => {
  const nodes = [{ axial: [10, 10] }, { axial: [11, 10] }];
  const polygons = renderedPolygons(nodes);
  assert.ok(polygons.length > 0, "expected visible background polygons");
  assert.ok(polygons.includes(polygonPoints([9, 10])));
  for (const node of nodes) assert.ok(!polygons.includes(polygonPoints(node.axial)));
});

test("renders background polygons around a negative-offset cluster", () => {
  const nodes = [{ axial: [-10, -10] }, { axial: [-11, -10] }];
  const polygons = renderedPolygons(nodes);
  assert.ok(polygons.length > 0, "expected visible background polygons");
  assert.ok(polygons.includes(polygonPoints([-9, -10])));
  for (const node of nodes) assert.ok(!polygons.includes(polygonPoints(node.axial)));
});

test("anchors polygons around a moderately displaced cluster", () => {
  const nodes = [{ axial: [3, 3] }, { axial: [4, 3] }];
  assert.ok(renderedPolygons(nodes).includes(polygonPoints([2, 3])));
});
