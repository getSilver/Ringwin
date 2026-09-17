// 运行时自检：用最小 DOM 桩执行原型脚本，捕获第一个运行时错误
const fs = require("fs");
const html = fs.readFileSync(__dirname + "/prototype-analytics-ui.html", "utf8");
const src = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function fakeEl() {
  return {
    innerHTML: "", textContent: "", className: "",
    classList: { add(){}, },
    clientWidth: 600,
    querySelector: () => fakeEl(),
    querySelectorAll: () => [],
    appendChild: () => {},
  };
}
const errors = [];
globalThis.window = globalThis;
globalThis.document = {
  getElementById: () => { const el = fakeEl(); el.querySelectorAll = () => []; return el; },
  addEventListener: () => {},
  documentElement: {},
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#4da3ff" });
globalThis.location = { search: "?variant=A", };
globalThis.history = { replaceState(){} };
globalThis.uPlot = class {
  constructor(opts, data, el) { if (!opts.width || !opts.height) errors.push("uplot missing size"); }
};

try {
  new Function(src)();
  console.log("RUN OK (default variant)");
} catch (e) {
  console.log("RUNTIME ERROR:", e.constructor.name + ":", e.message);
  const st = (e.stack||"").split("\n").slice(0,4).join("\n");
  console.log(st);
}

// 遍历所有变体
for (const v of ["A","A:0","A:1","A:2","A:3","B","B:0","B:2","C"]) {
  try {
    globalThis.location.search = "?variant=" + v;
    // render 已在闭包外不可达；重新执行整个脚本来模拟
    new Function("location", src)( { search:"?variant="+v, } );
    console.log("VARIANT", v, "-> OK");
  } catch(e) {
    console.log("VARIANT", v, "-> ERROR:", e.message);
  }
}
