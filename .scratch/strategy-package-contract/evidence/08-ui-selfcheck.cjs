// Run from repository root with node.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const script = fs.readFileSync('python/operator_ui.html', 'utf8').split('<script>')[1].split('</script>')[0];
new vm.Script(script);
const span = (start, end) => script.slice(script.indexOf(start), script.indexOf(end));
const element = {innerHTML: ''}, calls = [], messages = [];
let success = true;
const context = vm.createContext({
  BigInt, newIdentity: () => '17',
  prompt: () => JSON.stringify({release_artifact: 'signed-target', definition_identity: 'b'.repeat(32), package_manifest_sha256: 'c'.repeat(64)}),
  document: {getElementById: () => element, createElement: () => ({
    set textContent(v) {this.innerHTML = v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');}
  })},
  toast: (...args) => messages.push(args),
  api: async (method, path, request) => {
    calls.push({method, path, request});
    if (method === 'POST') return [200, {ok: success, result: {successor_transition: {to_instance: 'd'.repeat(32), reason: success ? '' : 'responsibility open'}}}];
    return [200, {instances: [{binding: {strategy_identity: '1'.repeat(32), definition_identity: '2'.repeat(32), decision_domain: '3'.repeat(32), config_version: 1, config_sha256: 'a'.repeat(64)}, status: 'Ready', reason: '', successor_transition: {to_definition: '<img src=x>'}}]}];
  }
});
vm.runInContext(span('function escaped(', 'async function loadPackages(') +
  span('async function loadInstances(', 'async function controlStrategyInstance(') +
  span('async function replaceStrategyInstance(', 'async function createStrategyInstance('), context);
(async () => {
  for (const operation of ['replace', 'forward_rollback']) {
    await context.replaceStrategyInstance('1'.repeat(32), '2'.repeat(32), operation);
    const request = calls.at(-2).request;
    assert.equal(request.operation, operation);
    assert.equal(request.operation_identity, '0'.repeat(30) + '11');
    assert.equal(request.expected_definition_identity, '2'.repeat(32));
    assert.equal(request.release_artifact, 'signed-target');
  }
  assert.match(messages[0][0], /Ready/);
  assert.match(element.innerHTML, /&lt;img src=x&gt;/);
  assert(!element.innerHTML.includes('<img'));
  success = false;
  await context.replaceStrategyInstance('1'.repeat(32), '2'.repeat(32), 'replace');
  assert.equal(messages.at(-1)[1], 'bad');
  assert.match(messages.at(-1)[0], /responsibility open/);
  console.log('UI successor requests, identities, rejection and escaping: passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
