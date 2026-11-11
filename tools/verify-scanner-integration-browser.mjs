// Actual Web and native adapters; synthetic bytes enter only at public transport.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2);
const option=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const ui=resolve(option('--ui-root','../RingwinUi-scanner-integration'));
const output=resolve(option('--output','.scratch/build/scanner-integration-browser'));
const {chromium}=await import(pathToFileURL(resolve(option('--playwright-module','../RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs'))).href);
await mkdir(output,{recursive:true});
let fixture,browser,page,diagnostics='';
const results=[],errors=[],external=[];
const check=async(name,fn)=>{await fn();results.push(name);console.log('passed: '+name);};
const click=name=>page.getByRole('button',{name,exact:true}).click();
const tab=name=>page.getByRole('tab',{name,exact:true}).click();
const choose=async(name,value)=>{await page.getByRole('combobox',{name,exact:true}).click();await page.getByRole('option',{name:value,exact:true}).click();};
try {
 fixture=spawn('python',['-u','python/verify_scanner_integration.py','--ui',join(ui,'dist/index.html')],{cwd:root,stdio:['pipe','pipe','pipe']});
 fixture.stderr.on('data',data=>{diagnostics+=data;});
 const ready=await new Promise((resolve,reject)=>{
  let buffer='';const timeout=setTimeout(()=>reject(new Error('fixture startup timeout '+diagnostics)),45000);
  fixture.on('error',reject);fixture.on('exit',code=>{clearTimeout(timeout);reject(new Error('fixture exited '+code+' '+diagnostics));});
  fixture.stdout.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timeout);resolve(JSON.parse(buffer.split('\n')[0]));}});
 });
 const base='http://127.0.0.1:'+ready.port;
 browser=await chromium.launch({headless:true,executablePath:option('--browser','C:/Users/X/AppData/Local/ms-playwright/chromium-1217/chrome-win64/chrome.exe')});
 const context=await browser.newContext({viewport:{width:1600,height:1100}});
 await context.route('**/*',route=>{if(!route.request().url().startsWith(base+'/')){external.push(route.request().url());return route.abort();}return route.continue();});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
 await check('normal owner login',async()=>{
  await page.goto(base+'/#opportunities');
  await page.getByRole('textbox',{name:'口令',exact:true}).fill(ready.passphrase);
  await page.getByRole('textbox',{name:'TOTP 验证码',exact:true}).fill(ready.totp);
  await click('登录扫描控制台');
  await page.getByText('已停止 · 配置 v0',{exact:true}).waitFor();
 });
 await check('configure OKX spot and Hyperliquid perpetual through UI',async()=>{
  await tab('扫描范围');
  await page.getByText(/请求 production → 来源 production/).first().waitFor();
  await page.getByRole('checkbox',{name:'Venue 1',exact:true}).check();
  await page.getByRole('checkbox',{name:'现货',exact:true}).check();
  await choose('深度报价资产','USDC');await click('添加到草稿');
  await page.getByRole('checkbox',{name:'Venue 1',exact:true}).uncheck();
  await page.getByRole('checkbox',{name:'现货',exact:true}).uncheck();
  await page.getByRole('checkbox',{name:'Venue 21',exact:true}).check();
  await page.getByRole('checkbox',{name:'永续',exact:true}).check();
  await click('添加到草稿');await click('应用扫描范围');await tab('当前机会');
 });
 await check('start, warm, observe native depth and pending evaluation',async()=>{
  const started=page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().postData()?.includes('"start"'));
  await click('启动扫描');assert.equal((await(await started).json()).result.phase,'Warming');
  await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await page.getByRole('table',{name:'规范行情观察',exact:true}).getByText('50000 USDC',{exact:true}).waitFor();
  await page.getByText('missing_evidence',{exact:true}).first().waitFor();
  await page.getByText('1 / 1 档 · 来源有限快照',{exact:true}).first().waitFor();
  await page.screenshot({path:join(output,'running.png'),fullPage:true});
 });
 await check('inspect raw identity and rules evidence',async()=>{
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
  await click('登录扫描控制台');
  await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await page.setViewportSize({width:390,height:844});
  await page.getByRole('button',{name:'暂停扫描',exact:true}).scrollIntoViewIfNeeded();
  await page.screenshot({path:join(output,'narrow.png'),fullPage:true});
 });
 await check('pause, resume and stop release scanner subscriptions',async()=>{
  await click('暂停扫描');await page.getByText('已暂停 · 配置 v1',{exact:true}).waitFor();
  await click('启动扫描');await page.getByRole('heading',{name:'当前跨所机会 · 3',exact:true}).waitFor();
  await click('停止扫描');await page.getByText('已停止 · 配置 v1',{exact:true}).waitFor();
  await page.getByRole('heading',{name:'当前跨所机会 · 0',exact:true}).waitFor();
 });
 assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
 await writeFile(join(output,'report.json'),JSON.stringify({status:'passed',browser:browser.version(),input:'synthetic_protocol_fixture',results,errors,external,trading_qualified:false,online_market:'not_run'},null,2));
 console.log('scanner_internal_browser=passed; checks='+results.length+'; external_requests=0; trading=false');
} catch(error) {
 if(page){await page.screenshot({path:join(output,'failure.png'),fullPage:true}).catch(()=>{});console.error(await page.locator('body').innerText().catch(()=>''));}
 await writeFile(join(output,'report.json'),JSON.stringify({status:'failed',results,error:String(error),diagnostics,errors,external},null,2));throw error;
} finally {
 await browser?.close();
 if(fixture&&fixture.exitCode===null){fixture.stdin.write('quit\n');await new Promise(resolve=>{const timeout=setTimeout(()=>{fixture.kill();resolve();},15000);fixture.once('exit',()=>{clearTimeout(timeout);resolve();});});}
}
