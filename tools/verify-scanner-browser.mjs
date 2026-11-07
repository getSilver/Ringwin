// Offline browser acceptance against the actual Web app and local Zig authority.
// Requires an existing RingwinUi build, playwright-core, and Chromium. No Venue IO.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name)+1] : fallback;
const ui = resolve(option('--ui-root', join(root, '../RingwinUi-scanner')));
const output = resolve(option('--output', join(root, '.scratch/build/scanner-browser')));
const modulePath = option('--playwright-module', 'playwright-core');
const { chromium } = await import(modulePath.startsWith('file:') || modulePath === 'playwright-core' ? modulePath : pathToFileURL(resolve(modulePath)).href);
await mkdir(output, { recursive: true });
const results = [], errors = [], external = [];
let fixture, browser, page, csrf, base;
let diagnostics = '';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const click = name => page.getByRole('button', { name, exact: true }).click();
const tab = name => page.getByRole('button', { name, exact: true }).or(page.getByRole('tab', { name, exact: true })).click();
const textbox = name => page.getByRole('textbox', { name, exact: true });
const choose = async (name, value) => {
  await page.getByRole('combobox', { name, exact: true }).click();
  await page.getByRole('option', { name: value, exact: true }).click();
};
const check = async (name, fn) => {
  const start = performance.now();
  let timeout;
  try { await Promise.race([fn(),new Promise((_,reject) => { timeout=setTimeout(()=>reject(new Error('check timeout: '+name)),45000); })]); }
  finally { clearTimeout(timeout); }
  results.push({ name, status: 'passed', milliseconds: Math.round(performance.now()-start) });
  console.log('passed: '+name);
};
const shot = name => page.screenshot({ path: join(output, name+'.png'), fullPage: true, animations:'disabled' });
const count = n => page.getByRole('heading', { name: '当前候选 · '+n, exact: true }).waitFor();
const command = async value => { fixture.stdin.write(value+'\n'); await sleep(150); };
const api = (operation, payload) => page.evaluate(async ({csrf, operation, payload}) => {
  const response = await fetch('/api/scanner', {method:'POST', headers:{'Content-Type':'application/json','X-Owner-CSRF':csrf}, body:JSON.stringify({operation,payload})});
  return {status:response.status, body:await response.json()};
}, {csrf, operation, payload});

try {
  fixture = spawn('python', ['-u', 'python/verify_scanner_console.py', '--serve-ui', join(ui, 'dist/index.html')], {cwd:root, stdio:['pipe','pipe','pipe']});
  fixture.stderr.on('data', data => { diagnostics += data; });
  const ready = await new Promise((resolve, reject) => {
    let buffer = '';
    const timeout = setTimeout(() => reject(new Error('offline fixture startup timeout')), 60000);
    fixture.on('error', reject);
    fixture.on('exit', code => { clearTimeout(timeout); reject(new Error('fixture exited '+code+': '+diagnostics)); });
    fixture.stdout.on('data', data => {
      buffer += data;
      if (buffer.includes('\n')) { clearTimeout(timeout); try { resolve(JSON.parse(buffer.split('\n')[0])); } catch(e) { reject(e); } }
    });
  });
  base = 'http://127.0.0.1:'+ready.port;
  browser = await chromium.launch({ headless:true, ...(option('--browser') ? {executablePath:option('--browser')} : {}) });
  const context = await browser.newContext({viewport:{width:1600,height:1100}});
  // Reject external requests before they can leave the page.
  await context.route('**/*', route => {
    const url = route.request().url();
    if (!url.startsWith(base+'/') && !url.startsWith('data:') && !url.startsWith('blob:')) { external.push(url); return route.abort(); }
    return route.continue();
  });
  page = await context.newPage();
  page.setDefaultTimeout(12000);
  page.on('pageerror', error => errors.push(error.message));
  await check('owner login and stopped projection', async () => {
    await page.goto(base+'/?scanner=live#opportunities');
    await textbox('口令').fill(ready.passphrase);
    await textbox('TOTP 验证码').fill(ready.totp);
    const login = page.waitForResponse(r => r.url() === base+'/login');
    await click('登录扫描控制台');
    csrf = (await (await login).json()).csrf_token;
    await page.getByText('Stopped · 配置 v0', {exact:true}).waitFor();
  });
  await check('keyboard navigation and scope validation', async () => {
    const current = page.getByRole('button', {name:'当前候选',exact:true});
    await current.focus(); await page.keyboard.press('ArrowRight');
    assert(await page.getByRole('button',{name:'扫描范围',exact:true}).evaluate(element => element === document.activeElement));
    await page.keyboard.press('Enter');
    await page.getByRole('checkbox',{name:'Venue 1',exact:true}).check();
    await page.getByRole('checkbox',{name:'Venue 21',exact:true}).check();
    await page.getByRole('checkbox',{name:'线性永续',exact:true}).check();
    await choose('深度报价资产','USDT');
    await textbox('盘口深度最低金额（可空）').fill('1');
    await textbox('盘口深度最高金额（可空）').fill('0');
    await click('加入或更新草稿');
    await page.getByText('Error: 深度最低金额不能超过最高金额',{exact:true}).waitFor();
    await textbox('盘口深度最低金额（可空）').fill('0');
    await textbox('盘口深度最高金额（可空）').fill('');
    await click('加入或更新草稿');
    assert.equal((await api('history',{kind:'config',limit:50})).body.result.rows.length,0);
  });
  await check('optimistic config conflict preserves draft', async () => {
    const scope = venue => ({venue,product:'linear',environment:'simulation',include_assets:[],exclude_assets:[],quote_asset:'1',min_depth_atoms:'0',max_depth_atoms:null,new_instruments:false});
    assert.equal((await api('configure',{expected_version:'0',scopes:[scope('1'),scope('21')]})).status,200);
    await click('提交扫描范围');
    await page.getByText(/scanner config version conflict/).waitFor();
    await sleep(1500);
    assert(await page.getByText(/scanner config version conflict/).isVisible(), 'successful polling must not erase an action error');
    await shot('scope-conflict');
    await click('放弃草稿');
    await page.getByText('Stopped · 配置 v1',{exact:true}).waitFor();
  });
  await check('start, complete replacement, filtering and evidence', async () => {
    await click('启动扫描'); await tab('当前候选'); await count(6);
    await page.getByText('Running · 配置 v1',{exact:true}).waitFor();
    await textbox('搜索资产或 Venue 身份').fill('NO_SUCH_ASSET'); await count(0);
    await textbox('搜索资产或 Venue 身份').fill('BTC'); await count(6);
    await choose('模式','双 IOC'); await count(2);
    await choose('状态','evaluated'); await count(1);
    await choose('模式','全部模式'); await choose('状态','全部状态');
    await textbox('搜索资产或 Venue 身份').fill(''); await count(6);
    await shot('live-running');
    await page.getByRole('button',{name:/^查看证据 /}).first().click();
    await page.getByRole('dialog',{name:'候选证据详情'}).waitFor();
    await choose('策略与组合归属','策略 9 / 组合 10');
  });
  await check('actual core accepts approval and rejects stale version', async () => {
    await click('读取核心批准版本'); await click('提交配对批准请求'); await click('关闭证据详情');
    await tab('核心请求'); await page.getByText(/核心 v1/).waitFor(); await shot('core-accepted');
    await tab('当前候选'); await page.getByRole('button',{name:/^查看证据 /}).first().click();
    await textbox('预期核心批准版本').fill('0'); await click('提交配对批准请求'); await click('关闭证据详情');
    await tab('核心请求'); await page.getByText('rejected',{exact:true}).waitFor();
  });
  await check('lost acknowledgement resolves under original identity', async () => {
    await command('drop_next_pair_ack');
    await tab('当前候选'); await page.getByRole('button',{name:/^查看证据 /}).first().click();
    await click('读取核心批准版本'); await click('提交配对批准请求'); await click('关闭证据详情');
    await tab('核心请求'); await page.getByText('unknown',{exact:true}).waitFor();
    const query = page.getByRole('button',{name:/^查询原请求 /}).first();
    const identity = (await query.innerText()).replace('查询原请求 ','').trim();
    await query.click(); await page.getByText(/核心 v2/).waitFor();
    assert.equal(await query.innerText(),'查询原请求 '+identity);
  });
  await check('actual core confirms revocation', async () => {
    await tab('当前候选'); await page.getByRole('button',{name:/^查看证据 /}).first().click();
    await click('读取核心批准版本'); await click('提交配对撤销请求'); await click('关闭证据详情');
    await tab('核心请求'); await page.getByText(/核心 v3/).waitFor();
  });
  await check('history, summary, expiry and input recovery', async () => {
    await tab('历史与统计'); await click('查询历史');
    await page.getByRole('table',{name:'扫描历史'}).getByText(/representative/).first().waitFor();
    assert(await page.getByRole('button',{name:'上一页',exact:true}).isDisabled());
    assert(await page.getByRole('button',{name:'下一页',exact:true}).isDisabled());
    await click('重建统计汇总'); await page.getByRole('table',{name:'扫描历史'}).getByText(/scanner_summary_v1/).waitFor();
    await command('expire'); await tab('当前候选'); await page.getByText('expired',{exact:true}).first().waitFor();
    await page.getByRole('button',{name:/^查看证据 /}).first().click();
    assert(await page.getByRole('button',{name:'提交配对批准请求',exact:true}).isDisabled());
    await click('关闭证据详情');
    await click('停止扫描'); await count(0);
    await command('reset'); await click('启动扫描'); await count(6);
    await page.getByText('Running · 配置 v1',{exact:true}).waitFor();
  });
  await check('disconnection clears candidates and refresh restores them', async () => {
    const fail = route => route.abort();
    await page.route(base+'/api/scanner',fail);
    await page.getByText(/连接中断，候选已撤销/).waitFor(); await count(0);
    await page.unroute(base+'/api/scanner',fail);
    await count(6);
  });
  await check('late response cannot restore a superseded session', async () => {
    let unblock, captured, restore, returned;
    const release = new Promise(resolve => { unblock=resolve; });
    const held = new Promise(resolve => { captured=resolve; });
    const fresh = new Promise(resolve => { restore=resolve; });
    const oldReturned = new Promise(resolve => { returned=resolve; });
    let claimed = false;
    const hold = async route => {
      if (route.request().method() !== 'GET') return route.continue();
      if (claimed) { await fresh; return route.continue(); }
      claimed = true;
      const response = await route.fetch(); captured();
      await release; await route.fulfill({response}); returned();
    };
    await page.route(base+'/api/scanner',hold);
    try {
      await held;
      await click('停止扫描'); await count(0);
      await click('启动扫描'); await count(0);
      unblock(); await oldReturned; await sleep(250); await count(0);
    } finally { unblock(); restore(); await page.unrouteAll({behavior:'wait'}); }
    await count(6);
  });
  await check('narrow viewport controls and table scrolling', async () => {
    await page.setViewportSize({width:390,height:844});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth>innerWidth),false);
    await tab('扫描范围'); await textbox('纳入资产（可空）').fill('BTC');
    await tab('当前候选'); await shot('live-mobile');
    assert(await page.getByRole('table',{name:'扫描候选'}).evaluate(table => {
      for (let element=table; element; element=element.parentElement) {
        if (element.scrollWidth>element.clientWidth && ['auto','scroll'].includes(getComputedStyle(element).overflowX)) {
          element.scrollLeft=element.scrollWidth;
          return element.scrollLeft>0;
        }
      }
      return false;
    }), 'wide candidate table must remain horizontally scrollable');
    await page.getByRole('button',{name:/^查看证据 /}).first().click();
    await page.getByRole('dialog',{name:'候选证据详情'}).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth>innerWidth),false);
    assert(await page.getByRole('dialog',{name:'候选证据详情'}).getByText(/"base_asset":/).evaluate(element => element.scrollWidth<=element.clientWidth+1), 'candidate evidence must wrap inside the narrow dialog');
    await shot('evidence-mobile'); await click('关闭证据详情');
    await click('停止扫描'); await count(0);
    await page.setViewportSize({width:1600,height:1100});
  });
  await check('memory history survives page reload and expires after 24 hours', async () => {
    const before = (await api('history',{kind:'events'})).body.result.rows.length;
    assert(before>0);
    const code = new Promise(resolve => {
      let buffer='';
      const read=data=>{buffer+=data; if(buffer.includes('\n')){fixture.stdout.off('data',read);resolve(JSON.parse(buffer.split('\n')[0]).totp);}};
      fixture.stdout.on('data',read);
    });
    fixture.stdin.write('login_code\n');
    await page.reload();
    await textbox('口令').fill(ready.passphrase); await textbox('TOTP 验证码').fill(await code);
    const response=page.waitForResponse(r=>r.url()===base+'/login');
    await click('登录扫描控制台'); csrf=(await(await response).json()).csrf_token;
    await tab('历史与统计'); await click('查询历史');
    assert.equal((await api('history',{kind:'events'})).body.result.rows.length,before);
    await page.getByText('最近 24 小时 · 服务端内存记录 · 刷新页面保留，服务重启清空。',{exact:true}).waitFor();
    await command('advance_day');
    assert.equal((await api('history',{kind:'events'})).body.result.rows.length,0);
    const summary=(await api('summary')).body.result;
    assert.deepEqual(summary.groups,{}); assert.equal(summary.storage,'memory');
  });
  await check('scanner service restart clears history but preserves core approval', async () => {
    await command('restart_console');
    assert.equal((await api('history',{kind:'events'})).body.result.rows.length,0);
    assert.equal((await api('history',{kind:'operations'})).body.result.rows.length,0);
    assert.equal((await api('core_version','9')).body.result.core_version,'3');
    await tab('当前候选'); await count(0);
    await page.getByText('Stopped · 配置 v1',{exact:true}).waitFor();
  });
  await check('expired owner session clears projection and reload offers login', async () => {
    await context.clearCookies();
    await page.getByText(/连接中断，候选已撤销/).waitFor(); await count(0);
    await page.reload(); await page.getByRole('button',{name:'登录扫描控制台',exact:true}).waitFor();
  });
  await check('isolated demo multi-venue multi-product scope', async () => {
    await page.goto(base+'/?demo=scanner#opportunities');
    await page.getByRole('switch',{name:'演示场景工具',exact:true}).click();
    await click('配置扫描范围');
    for (const name of ['OKX','Binance','现货','永续']) await page.getByRole('checkbox',{name,exact:true}).check();
    await textbox('纳入资产').fill(''); await textbox('盘口深度最低金额（USDT，可空）').fill('0');
    await click('添加到草稿');
    assert.equal(await page.getByRole('table',{name:'扫描范围草稿'}).getByRole('row').count(),5);
    await click('应用扫描范围'); await click('启动扫描'); await click('推进 1 秒'); await click('推进 1 秒');
    await tab('当前机会');
    assert(await page.getByRole('table',{name:'当前跨所机会'}).getByRole('button',{name:/^查看 /}).count()>0);
    await shot('demo-multiple-products');
    await click('模拟行情中断'); await click('恢复并重新预热'); await click('推进 1 秒'); await click('推进 1 秒');
    await click('模拟历史容量不足'); await click('推进 1 秒'); await click('恢复历史记录');
    await click('无新行情 16 秒'); await tab('历史统计');
    await page.getByRole('table',{name:'历史机会事件'}).waitFor();
    await page.getByText('历史存在覆盖缺口',{exact:true}).waitFor();
    await tab('扫描范围'); await textbox('排除资产').fill('BTC'); await click('添加到草稿');
    await click('应用扫描范围'); await click('推进 1 秒'); await click('推进 1 秒'); await tab('当前机会');
    assert.equal(await page.getByRole('table',{name:'当前跨所机会'}).getByText('BTC / USDT',{exact:true}).count(),0);
    assert(await page.getByRole('table',{name:'当前跨所机会'}).getByRole('button',{name:/^查看 /}).count()>0);
    await tab('扫描范围'); await textbox('盘口深度最高金额（USDT，可空）').fill('0'); await click('添加到草稿');
    await click('应用扫描范围'); await click('推进 1 秒'); await click('推进 1 秒'); await tab('当前机会');
    await page.getByRole('heading',{name:'当前跨所机会 · 0',exact:true}).waitFor();
    assert.equal(await page.getByRole('table',{name:'当前跨所机会'}).getByRole('button',{name:/^查看 /}).count(),0);
    await tab('操作记录'); await page.getByRole('table',{name:'扫描操作记录'}).waitFor();
  });
  assert.deepEqual(errors,[], 'browser exceptions'); assert.deepEqual(external,[], 'external requests');
  await writeFile(join(output,'report.json'),JSON.stringify({status:'passed',browser:browser.version(),viewports:['1600x1100','390x844'],authority:'actual_local_Zig',input:'deterministic_offline',external_requests:external,errors,results},null,2));
  console.log('scanner_browser_offline=passed; checks='+results.length+'; external_requests=0; trading=false');
} catch(error) {
  if (page) { await shot('failure').catch(()=>{}); console.error((await page.locator('body').innerText().catch(()=>''))); }
  await writeFile(join(output,'report.json'),JSON.stringify({status:'failed',results,error:String(error),errors,external},null,2));
  throw error;
} finally {
  await browser?.close();
  if (fixture && fixture.exitCode === null) {
    fixture.stdin.write('quit\n');
    await new Promise(resolve => {
      const timeout = setTimeout(() => { fixture.kill(); resolve(); },15000);
      fixture.once('exit',()=>{clearTimeout(timeout);resolve();});
    });
  }
}
