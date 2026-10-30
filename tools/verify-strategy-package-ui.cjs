// Exercise the shipped UI with its HTTP and DOM adapters, without a browser dependency.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const encode = text => String(text).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
function element() {
  return {style: {}, remove() {}, textContent: "", _html: null,
    get innerHTML() { return this._html ?? encode(this.textContent); },
    set innerHTML(value) { this._html = value; }};
}
const elements = new Map();
const toasts = [];
const packageRecord = {
  name: "<img src=x onerror=attack()>", definition_identity: "a21994db11534bf5b193c5aa89000010",
  package_manifest_sha256: "a".repeat(64), release_artifact: "bundle-a", active_release: true,
  validation: "passed", qualifications: [], trading_authorized: false
};
const prompts = ["/approved.json", "b".repeat(64), ""];
let outcome = "rejected";
let instanceStatus = "Ready";
let submittedBinding;
let renderedStatus = "Stopped";
const instanceCommands = [];
const context = vm.createContext({
  console, setTimeout() {}, location: {reload() {}},
  crypto: {randomUUID: () => "11111111-1111-4111-8111-111111111111"},
  prompt: () => prompts.shift() ?? "", window: {confirm: () => true},
  document: {createElement: element, body: {appendChild: el => toasts.push(el)},
    getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); }},
  fetch: async (url, options) => ({status: url === "/api/projection" ? 401 : 200, json: async () => {
    if (url === "/api/releases") return {active_artifact: "bundle-a", strategy_packages: [packageRecord],
      qualification_rejections: [{reason: "bad signature <unsafe>"}],
      release_records: [{artifact_id: "bundle-b", result: {status: "rejected", reason: "digest mismatch"}}]};
    if (url === "/risk-warning") return {warning_identity: "1", consequence: "offline test"};
    if (url === "/command") {
      instanceCommands.push(JSON.parse(options.body));
      return {result: {status: renderedStatus}};
    }
    if (url === "/api/strategy-instances") {
      if (options.method === "POST") {
        submittedBinding = JSON.parse(options.body);
        return {result: {status: instanceStatus, reason: "warmup <insufficient>"}};
      }
      return {instances: [{binding: {strategy_identity: "<unsafe>", definition_identity: "definition",
        decision_domain: "0".repeat(31) + "1", config_sha256: "c".repeat(64)},
        status: renderedStatus, trading_authorized: renderedStatus === "Trading", reason: "warmup <insufficient>"}]};
    }
    return {result: {status: outcome, reason: "digest mismatch"}};
  }})
});
const html = fs.readFileSync(path.join(__dirname, "../python/operator_ui.html"), "utf8");
vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
(async () => {
  await vm.runInContext("loadPackages()", context);
  const rendered = elements.get("packages").innerHTML;
  assert.ok(rendered.includes(packageRecord.definition_identity));
  assert.ok(rendered.includes("a".repeat(64)));
  assert.ok(rendered.includes("&lt;img"));
  assert.ok(!rendered.includes("<img"));
  assert.ok(rendered.includes("资格待取得"));
  assert.ok(rendered.includes("bad signature &lt;unsafe&gt;"));
  assert.ok(rendered.includes("digest mismatch"));
  for (const status of ["rejected", "unknown"]) {
    outcome = status;
    prompts.push("/approved.json", "b".repeat(64), "");
    await vm.runInContext("submitLifecycle('deploy_release',1)", context);
    assert.ok(toasts.at(-1).textContent.includes(status));
    assert.ok(toasts.at(-1).style.cssText.includes("var(--bad)"));
  }
  await vm.runInContext("loadInstances()", context);
  assert.ok(elements.get("instances").innerHTML.includes("&lt;unsafe&gt;"));
  assert.ok(elements.get("instances").innerHTML.includes("warmup &lt;insufficient&gt;"));
  for (const state of ["Ready", "Trading"]) {
    renderedStatus = state;
    await vm.runInContext("loadInstances()", context);
    assert.ok(elements.get("instances").innerHTML.includes(state === "Trading" ? "核心已授权交易" : "EnableTrading"));
  }
  await vm.runInContext("controlStrategyInstance('enable_trading','11111111111111111111111111111111','1')", context);
  assert.equal(instanceCommands.at(-1).strategy_identity, "1".repeat(32));
  assert.equal(instanceCommands.at(-1).risk_warning_acknowledged, true);
  for (const status of ["Ready", "Stopped"]) {
    instanceStatus = status;
    prompts.length = 0;
    prompts.push(JSON.stringify({strategy_identity: "1".repeat(32), config_json: "{}"}));
    await vm.runInContext("createStrategyInstance()", context);
    assert.equal(submittedBinding.strategy_identity, "1".repeat(32));
    assert.ok(toasts.at(-1).style.cssText.includes(status === "Ready" ? "var(--ok)" : "var(--bad)"));
  }
  console.log("strategy_package_ui=passed");
})().catch(error => { console.error(error); process.exitCode = 1; });
