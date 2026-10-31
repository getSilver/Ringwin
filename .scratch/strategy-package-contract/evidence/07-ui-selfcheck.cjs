// Run from the repository root: node .scratch/strategy-package-contract/evidence/07-ui-selfcheck.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('python/operator_ui.html', 'utf8');
const script = html.split('<script>')[1].split('</script>')[0];
new vm.Script(script);
const span = (start, end) => script.slice(script.indexOf(start), script.indexOf(end));
const element = {innerHTML: ''};
const calls = [], messages = [];
let success = true;
const context = vm.createContext({
  BigInt,
  prompt: () => JSON.stringify({config_version: 2, config_json: '{"warmup_events":2}',
    config_sha256: 'a'.repeat(64), transition: 'Keep'}),
  document: {getElementById: () => element, createElement: () => ({
    set textContent(v) {this.innerHTML = v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');}
  })},
  toast: (...args) => messages.push(args),
  api: async (method, path, request) => {
    calls.push({method, path, request});
    if (method === 'POST') return [200, {ok: success, result: {
      config_transition: {method: 'Keep', reason: success ? '' : 'drain incomplete'}}}];
    return [200, {instances: [{binding: {strategy_identity: '1'.repeat(32), definition_identity: '2'.repeat(32),
      decision_domain: '3'.repeat(32), config_version: 2, config_sha256: 'a'.repeat(64)},
      status: 'Ready', reason: '', config_transition: {method: 'Keep', reason: '<img src=x>'}}]}];
  }
});
vm.runInContext(span('function escaped(', 'async function loadPackages(') +
  span('async function loadInstances(', 'async function controlStrategyInstance(') +
  span('async function updateStrategyConfig(', 'async function createStrategyInstance('), context);
(async () => {
  await context.updateStrategyConfig('1'.repeat(32), 1);
  assert.equal(calls[0].request.operation, 'update_config');
  assert.equal(calls[0].request.expected_config_version, 1);
  assert.equal(calls[0].request.config_json, '{"warmup_events":2}');
  assert.match(messages[0][0], /Ready/);
  assert.equal(messages[0][1], 'ok');
  assert.match(element.innerHTML, /Keep/);
  assert.match(element.innerHTML, /&lt;img src=x&gt;/);
  assert(!element.innerHTML.includes('<img'));
  success = false;
  await context.updateStrategyConfig('1'.repeat(32), 1);
  assert.equal(messages[1][1], 'bad');
  assert.match(messages[1][0], /drain incomplete/);
  console.log('UI config request, transition display, failure and escaping: passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
