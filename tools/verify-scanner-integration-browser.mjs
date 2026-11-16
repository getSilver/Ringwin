// Actual Web and native adapters; synthetic bytes enter only at public transport.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2);
const option=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const ui=resolve(option('--ui-root','../RingwinUi'));
const output=resolve(option('--output','.scratch/build/scanner-integration-browser'));
const {chromium}=await import(pathToFileURL(resolve(option('--playwright-module','../RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs'))).href);
await mkdir(output,{recursive:true});
let fixture,browser,page,vite,diagnostics='';
const results=[],errors=[],external=[];
const check=async(name,fn)=>{await fn();results.push(name);console.log('passed: '+name);};
const click=name=>page.getByRole('button',{name,exact:true}).click();
const tab=name=>page.getByRole('tab',{name,exact:true}).click();
const choose=async(name,value)=>{await page.getByRole('combobox',{name,exact:true}).click();await page.getByRole('option',{name:value,exact:true}).click();};
try {
 fixture=spawn('python',['-u','python/verify_scanner_integration.py','--ui',join(ui,'dist/index.html'),...(args.includes('--refresh')?['--refresh']:[]),...(args.includes('--large-catalogue')?['--large-catalogue']:[])],{cwd:root,stdio:['pipe','pipe','pipe']});
 fixture.stderr.on('data',data=>{diagnostics+=data;});
 const ready=await new Promise((resolve,reject)=>{
  let buffer='';const timeout=setTimeout(()=>reject(new Error('fixture startup timeout '+diagnostics)),45000);
  fixture.on('error',reject);fixture.on('exit',code=>{clearTimeout(timeout);reject(new Error('fixture exited '+code+' '+diagnostics));});
  fixture.stdout.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timeout);resolve(JSON.parse(buffer.split('\n')[0]));}});
 });
 let base='http://127.0.0.1:'+ready.port;
 if(args.includes('--dev')) {
  vite=spawn(process.execPath,[join(ui,'node_modules/vite/bin/vite.js'),'--port','5187'],{
   cwd:ui,env:{...process.env,RINGWIN_CONTROL_PROXY_URL:base,VITE_RINGWIN_LIVE_API:'1'},stdio:['ignore','pipe','pipe']});
  vite.stderr.on('data',data=>{diagnostics+=data;});
  await new Promise((resolve,reject)=>{
   const timeout=setTimeout(()=>reject(new Error('Vite startup timeout '+diagnostics)),30000);
   vite.once('exit',code=>{clearTimeout(timeout);reject(new Error('Vite exited '+code+' '+diagnostics));});
   vite.stdout.on('data',data=>{if(String(data).includes('5187')){clearTimeout(timeout);resolve();}});
  });
  base='http://127.0.0.1:5187';
 }
 browser=await chromium.launch({headless:true,executablePath:option('--browser','C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe')});
 const newSession=async()=>{
  const session=await browser.newContext({viewport:{width:1600,height:1100}});
  await session.route('**/*',route=>{if(!route.request().url().startsWith(base+'/')){external.push(route.request().url());return route.abort();}return route.continue();});
  page=await session.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
  return session;
 };
 let context=await newSession();
 await check('normal owner login',async()=>{
  await page.goto(base+'/#opportunities');
  await page.getByRole('textbox',{name:'口令',exact:true}).fill(ready.passphrase);
  await page.getByRole('textbox',{name:'TOTP 验证码',exact:true}).fill(ready.totp);
  await click('登录');
  await page.getByText('已停止 · 配置 v0',{exact:true}).waitFor();
 });
 await check('save named exchange settings through UI and recover on reopening',async()=>{
  await tab('扫描范围');
  assert.equal(await page.getByRole('checkbox',{name:'我的现货',exact:true}).count(),0);
  await click('Settings');
  await click('交易所');
  assert(await page.getByRole('button',{name:'保存交易所',exact:true}).isDisabled());
  await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('  我的现货  ');
  await click('保存交易所');
  await page.getByRole('table',{name:'已保存交易所'}).getByText('我的现货',{exact:true}).waitFor();
  await choose('交易所类型','Hyperliquid');
  await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('我的永续');
  await click('保存交易所');
  await page.getByRole('table',{name:'已保存交易所'}).getByText('我的永续',{exact:true}).waitFor();
  await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('重复来源');
  await click('保存交易所');
  await page.getByText(/duplicate exchange source/).waitFor();
  assert.equal(await page.getByRole('table',{name:'已保存交易所'}).getByText('重复来源',{exact:true}).count(),0);
  await page.keyboard.press('Escape');
  await page.getByRole('checkbox',{name:'我的现货',exact:true}).waitFor();
  await page.getByRole('checkbox',{name:'我的永续',exact:true}).waitFor();
  await click('Settings');
  await page.getByRole('table',{name:'已保存交易所'}).getByText('我的现货',{exact:true}).waitFor();
  await page.keyboard.press('Escape');
 });
 if(args.includes('--large-catalogue')) await check('native directory above 64 remains ready and usable on the scope page',async()=>{
  const response=await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET'&&r.status()===200);
  const view=(await response.json()).result;
  assert.equal(view.catalogue.length,67);
  assert.equal(view.exchanges.find(s=>s.type==='hyperliquid').catalogue_state,'ready');
  assert.equal(await page.getByText('扫描响应格式无效',{exact:true}).count(),0);
  await writeFile(join(output,'large-catalogue-view.json'),JSON.stringify(view,null,2));
 });
 await check('configure OKX spot and Hyperliquid perpetual through UI',async()=>{
  await tab('扫描范围');
  await page.getByText(/请求 production → 来源 production/).first().waitFor();
  await page.getByRole('checkbox',{name:'我的现货',exact:true}).check();
  await page.getByRole('checkbox',{name:'现货',exact:true}).check();
  await page.getByRole('textbox',{name:'纳入资产（可空）',exact:true}).fill('ETH');
  await choose('深度报价资产','USDT');await click('添加到草稿');
  await page.getByRole('checkbox',{name:'我的现货',exact:true}).uncheck();
  await page.getByRole('checkbox',{name:'现货',exact:true}).uncheck();
  await page.getByRole('checkbox',{name:'我的永续',exact:true}).check();
  await page.getByRole('checkbox',{name:'永续',exact:true}).check();
  await click('添加到草稿');await click('应用扫描范围');await tab('当前机会');
 });
 await check('start, warm, observe native depth and pending evaluation',async()=>{
  const started=page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().postData()?.includes('"start"'));
  await click('启动扫描');assert.equal((await(await started).json()).result.phase,'Warming');
  await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await page.getByRole('table',{name:'规范行情观察',exact:true}).getByText('3000.01 USDT',{exact:true}).waitFor();
  await page.getByText('价格与盘口范围来自规范输入。缺少研究计划、模型、校准或费用时，完整周期收益待验证。',{exact:true}).waitFor();
  await page.getByText('1 / 1 档 · 来源有限快照',{exact:true}).first().waitFor();
  await page.screenshot({path:join(output,'running.png'),fullPage:true});
 });
 await check('inspect actual native observation and RawIngress evidence',async()=>{
  const authenticated=await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET');
  const view=(await authenticated.json()).result;
  assert.equal(view.market.observations.length,2);
  assert(view.market.observations.every(row=>row.continuous));
  assert.equal(view.market.evidence.length,2);
  assert(view.market.evidence.every(row=>row.input_kind==='synthetic_protocol_fixture'&&row.raw_sha256&&row.raw_sequence));
  assert.deepEqual(view.market.missing_evaluation,['research_plan','model','calibration','fees']);
  assert.equal(view.snapshot.candidates.length,3);
  assert(view.snapshot.candidates.every(row=>row.reason==='missing_evidence'&&!row.recommended));
 });
 await check('candidate evidence preserves native raw proof',async()=>{
  await page.getByRole('button',{name:/^查看证据 /}).first().click();
  await page.getByRole('dialog',{name:'候选证据详情'}).getByText(/synthetic_protocol_fixture/).waitFor();
  await click('关闭证据详情');
 });
 await check('history, refresh and narrow viewport',async()=>{
  await tab('历史统计');await choose('历史类别','batches');await click('查询历史');
  await page.getByText(/raw_sha256/).first().waitFor().catch(async()=>{
   // Batches retain an evidence digest; protocol bytes remain in server RawIngress.
   await page.getByText(/scanner_console_v1/).first().waitFor();
  });
  await page.reload();
  await page.getByRole('textbox',{name:'口令',exact:true}).fill(ready.passphrase);
  await page.getByRole('textbox',{name:'TOTP 验证码',exact:true}).fill(ready.totp_next);
  await click('登录');
  await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await click('Settings');
  await click('交易所');
  await page.getByRole('table',{name:'已保存交易所'}).getByText('我的现货',{exact:true}).waitFor();
  await page.getByRole('table',{name:'已保存交易所'}).getByText('我的永续',{exact:true}).waitFor();
  await page.keyboard.press('Escape');
  await tab('扫描范围');
  await page.getByRole('checkbox',{name:'我的现货',exact:true}).waitFor();
  await page.getByRole('table',{name:'实际生效范围'}).getByText('我的永续',{exact:true}).waitFor();
  await tab('当前机会');
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('button',{name:'暂停扫描',exact:true}).scrollIntoViewIfNeeded();
  await page.screenshot({path:join(output,'narrow.png'),fullPage:true});
 });
 if(args.includes('--refresh')) await check('both dynamic sources refresh rules, retire markets and recover independently',async()=>{
  const view=async()=>(await(await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET'&&r.status()===200)).json()).result;
  const until=async predicate=>{let last;for(let n=0;n<35;n++){last=await view();if(predicate(last))return last;}await writeFile(join(output,'transition-timeout.json'),JSON.stringify(last,null,2));throw new Error('combined catalogue transition timeout');};
  for(const [kind,venue] of [['okx','1'],['hyperliquid','21']]){
   const key=venue+':production';
   const before=await view();
   const other=before.market.evidence.find(row=>row.venue!==venue).session;
   const rules=before.market.observations.find(row=>row.venue===venue).rules_version;
   fixture.stdin.write('catalogue-'+kind+'-added\n');
   await until(v=>v.catalogue.some(row=>row.venue===venue&&(row.specification?.coin==='SOL'||row.specification?.base==='SOL')));
   assert.equal((await view()).market.active_subscriptions,2);
   fixture.stdin.write('catalogue-'+kind+'-rules\n');
   await until(v=>v.market.observations.some(row=>row.venue===venue&&row.continuous&&row.rules_version!==rules));
   for(const mode of ['failed','capacity','gone']){
    console.log('refresh: '+kind+' '+mode);
    fixture.stdin.write('catalogue-'+kind+'-'+mode+'\n');
    const failed=await until(v=>v.market.discovery[key].state===(mode==='gone'?'ready':'failed')&&!v.market.observations.some(row=>row.venue===venue));
    assert.equal(failed.snapshot.candidates.length,0);
    assert.equal(failed.market.evidence.find(row=>row.venue!==venue).session,other);
    fixture.stdin.write('catalogue-'+kind+'-initial\n');
    await until(v=>v.market.observations.some(row=>row.venue===venue&&row.continuous)&&v.snapshot.candidates.length===3);
   }
  }
  await page.screenshot({path:join(output,'refreshed.png'),fullPage:true});
 });
 await check('pause, resume and stop release scanner subscriptions',async()=>{
  await click('暂停扫描');await page.getByText('已暂停 · 配置 v1',{exact:true}).waitFor();
  await click('启动扫描');await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await click('停止扫描');await page.getByText('已停止 · 配置 v1',{exact:true}).waitFor();
  await page.getByRole('heading',{name:'当前跨所机会 · 0',exact:true}).waitFor();
 });
 if(args.includes('--restart')) await check('service restart recovers settings, scopes and identities without public requests',async()=>{
  await page.setViewportSize({width:1600,height:1100});
  const command=async value=>{
   const reply=new Promise((resolve,reject)=>{const timeout=setTimeout(()=>reject(new Error('fixture command timeout')),30000);fixture.stdout.once('data',data=>{clearTimeout(timeout);resolve(JSON.parse(String(data).trim()));});});
   fixture.stdin.write(value+'\n');return reply;
  };
  const response=await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET');
  const before=(await response.json()).result;
  await context.close();
  const restarted=await command('restart');assert.equal(restarted.after,restarted.requests);
  context=await newSession();await page.goto(base+'/app/scanner/opportunities');
  await page.getByRole('textbox',{name:'口令',exact:true}).fill(ready.passphrase);
  await page.getByRole('textbox',{name:'TOTP 验证码',exact:true}).fill(restarted.totp);
  await click('登录');await page.getByText('已停止 · 配置 v1',{exact:true}).waitFor();
  const current=(await(await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET')).json()).result;
  assert.deepEqual(current.config,before.config);
  assert.deepEqual(current.catalogue,before.catalogue);
  assert.deepEqual(current.exchanges,before.exchanges);
  assert.equal(current.market.observations.length,0);assert.equal(current.market.active_subscriptions,0);
  await page.waitForTimeout(1100);
  assert.equal((await command('requests')).requests,restarted.requests);
  await click('启动扫描');await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await click('停止扫描');
 });
 if(args.includes('--draft-conflict')) {
  await page.setViewportSize({width:1600,height:1100});
  await check('rename preserves stale draft conflict and cannot restore removed scopes',async()=>{
   await tab('扫描范围');
   const authenticated=await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET');
   const headers={'Content-Type':'application/json','X-Owner-CSRF':authenticated.request().headers()['x-owner-csrf']};
   const before=await page.evaluate(async headers=>{
    const current=await(await fetch('/api/scanner',{headers})).json();
    const scopes=current.result.config.scopes.filter(row=>row.venue==='21');
    const response=await fetch('/api/scanner',{method:'POST',headers,body:JSON.stringify({operation:'configure',
      payload:{expected_version:current.result.config.version,scopes}})});
    return {status:response.status,body:await response.json()};
   },headers);
   assert.equal(before.status,200);assert.equal(before.body.result.config.scopes.length,1);
   await page.getByText(/草稿基于 v1 · 当前生效 v2/).waitFor();
   await click('Settings');await click('交易所');await click('编辑 我的现货');
   await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('仅改显示名称');await click('保存交易所');
   await page.getByRole('table',{name:'已保存交易所'}).getByText('仅改显示名称',{exact:true}).waitFor();
   await page.keyboard.press('Escape');
   await page.getByRole('table',{name:'范围草稿'}).getByText('仅改显示名称',{exact:true}).waitFor();
   const response=page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().postData()?.includes('"configure"'));
   await click('应用扫描范围');assert.equal((await response).status(),409);
   await page.getByText(/scanner config version conflict/).waitFor();
   const current=await page.evaluate(async headers=>(await(await fetch('/api/scanner',{headers})).json()).result,headers);
   assert.deepEqual(current.config.scopes.map(row=>row.venue),['21']);
   await click('放弃草稿');await tab('当前机会');await tab('扫描范围');
   await page.getByText(/草稿基于 v2 · 当前生效 v2/).waitFor();
   await click('应用扫描范围');
   await page.getByRole('table',{name:'实际生效范围'}).getByText('我的永续',{exact:true}).waitFor();
  });
 }
 if(args.includes('--settings-lifecycle')) {
  await page.setViewportSize({width:1600,height:1100});
  await check('rename updates dynamic source names, search, draft and history',async()=>{
   await click('启动扫描');await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
   const before=await page.getByRole('button',{name:/^查看证据 /}).allTextContents();
   await tab('扫描范围');
   await click('Settings');await click('交易所');await click('编辑 我的现货');
   await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('改名后的市场');await click('保存交易所');
   await page.getByRole('table',{name:'已保存交易所'}).getByText('改名后的市场',{exact:true}).waitFor();
   await page.keyboard.press('Escape');
   await page.getByRole('table',{name:'范围草稿'}).getByText('改名后的市场',{exact:true}).waitFor();
   await page.getByRole('table',{name:'实际生效范围'}).getByText('改名后的市场',{exact:true}).waitFor();
   await tab('当前机会');await page.getByRole('textbox',{name:'搜索资产或交易所',exact:true}).fill('改名后的市场');
   await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
   assert.deepEqual(await page.getByRole('button',{name:/^查看证据 /}).allTextContents(),before);
   await page.getByRole('textbox',{name:'搜索资产或交易所',exact:true}).fill('我的现货');
   await page.getByRole('heading',{name:'当前跨所机会 · 0',exact:true}).waitFor();
   await page.getByRole('textbox',{name:'搜索资产或交易所',exact:true}).fill('');
   await tab('历史统计');await choose('历史类别','batches');await click('查询历史');
   await page.getByRole('table',{name:'扫描历史'}).getByText(/改名后的市场/).first().waitFor();
  });
  await check('setting environment switch rewarms only its new source and reports actual environment',async()=>{
   await tab('扫描范围');await click('Settings');await click('交易所');await click('编辑 改名后的市场');
   await choose('交易所环境','demo');await click('保存交易所');
   await page.getByRole('table',{name:'已保存交易所'}).getByText('demo',{exact:true}).waitFor();
   await page.keyboard.press('Escape');
   await page.getByText(/改名后的市场 · 请求 demo → 来源 production/).waitFor();
   await tab('当前机会');await page.getByRole('heading',{name:'当前跨所机会 · 0',exact:true}).waitFor();
   await page.getByRole('table',{name:'规范行情观察'}).getByText(/demo · 规则/).waitFor();
  });
  await check('delete removes draft and saved scopes while keeping readable historical names',async()=>{
   await tab('扫描范围');await click('Settings');await click('交易所');await click('删除 改名后的市场');
   await page.getByRole('status').getByText(/已删除 改名后的市场/).waitFor();
   await page.keyboard.press('Escape');
   await page.getByRole('checkbox',{name:'我的永续',exact:true}).waitFor();
   await page.getByRole('checkbox',{name:'改名后的市场',exact:true}).waitFor({state:'detached'});
   assert.equal(await page.getByRole('table',{name:'实际生效范围'}).getByText('改名后的市场',{exact:true}).count(),0);
   await tab('历史统计');await choose('历史类别','batches');await click('查询历史');
   await page.getByRole('table',{name:'扫描历史'}).getByText(/改名后的市场/).first().waitFor();
   await page.screenshot({path:join(output,'lifecycle.png'),fullPage:true});
  });
 }
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
 await writeFile(join(output,'report.json'),JSON.stringify({status:'passed',browser:browser.version(),input:'synthetic_protocol_fixture',results,errors,external,trading_qualified:false,online_market:'not_run'},null,2));
 console.log('scanner_internal_browser=passed; checks='+results.length+'; external_requests=0; trading=false');
} catch(error) {
 if(page){await page.screenshot({path:join(output,'failure.png'),fullPage:true}).catch(()=>{});console.error(await page.locator('body').innerText().catch(()=>''));}
 await writeFile(join(output,'report.json'),JSON.stringify({status:'failed',results,error:String(error),diagnostics,errors,external},null,2));throw error;
} finally {
 await browser?.close();
 if(vite&&vite.exitCode===null) {vite.kill();await new Promise(resolve=>vite.once('exit',resolve));}
 if(fixture&&fixture.exitCode===null){fixture.stdin.write('quit\n');await new Promise(resolve=>{const timeout=setTimeout(()=>{fixture.kill();resolve();},15000);fixture.once('exit',()=>{clearTimeout(timeout);resolve();});});}
}
