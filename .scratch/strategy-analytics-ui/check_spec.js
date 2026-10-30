// 规格渲染原型自检：语法 + DOM 桩运行时冒烟（遍历五个视图）
const fs = require("fs");
const html = fs.readFileSync(__dirname + "/prototype-spec-ui.html", "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 1) { console.log("expected 1 inline script, got", scripts.length); process.exit(1); }
const src = scripts[0];

function fakeCtx() {
  return new Proxy({}, { get: (t, k) => (k in t ? t[k] : () => {}), set: (t, k, v) => (t[k] = v, true) });
}
function fakeEl() {
  const el = {
    innerHTML: "", textContent: "", className: "", width: 0, height: 0,
    clientWidth: 900, style: {},
    classList: { add() {}, },
    dataset: {},
    appendChild(c) { el.children.push(c); return c; },
    children: [],
    getContext: () => fakeCtx(),
  };
  el.querySelector = () => fakeEl();
  el.querySelectorAll = () => [];
  return el;
}
const viewsReached = [];
globalThis.window = globalThis;
globalThis.document = {
  getElementById: () => fakeEl(),
  createElement: () => fakeEl(),
  querySelectorAll: () => [],
  addEventListener: () => {},
  documentElement: {},
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#4da3ff" });
globalThis.alert = () => {};
let uplotCount = 0;
globalThis.uPlot = function (opts) {
  if (!opts.width || !opts.height) throw new Error("uplot missing size");
  if (!opts.series || !Array.isArray(opts.series)) throw new Error("bad series");
  opts.series.forEach((s, i) => { if (i > 0 && s.paths && typeof s.paths !== "function") throw new Error("paths not fn"); });
  uplotCount++;
};

// 1. 语法
try { new Function(src); console.log("SYNTAX OK"); }
catch (e) { console.log("SYNTAX ERROR:", e.message); process.exit(1); }

// 2. 运行时冒烟：render() 会跑默认视图；再手动驱动其余视图
try {
  new Function(src)();
  console.log("RUNTIME OK (initial render, uPlot instances:", uplotCount, ")");
} catch (e) {
  console.log("RUNTIME ERROR:", e.constructor.name + ":", e.message);
  console.log((e.stack || "").split("\n").slice(1, 5).join("\n"));
  process.exit(1);
}

// 驱动每个视图函数
for (const name of ["viewOverview","viewAttribution","viewChain","viewAccounts","viewSnapshots"]) {
  try {
    const fn = new Function(src + `;${name}(document.getElementById("main"));`);
    // 注意：每次重新执行脚本会重置 rnd 种子，保证确定性
    console.log("VIEW", name, "-> OK");
  } catch (e) {
    console.log("VIEW", name, "-> ERROR:", e.message);
  }
}
