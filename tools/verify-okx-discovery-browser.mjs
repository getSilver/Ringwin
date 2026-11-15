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
const output=resolve(option('--output','.scratch/build/okx-discovery-browser'));
const {chromium}=await import(pathToFileURL(resolve(option('--playwright-module','../RingwinUi/.scratch/build/scanner-qa/node_modules/playwright-core/index.mjs'))).href);
await mkdir(output,{recursive:true});
let fixture,browser,page,vite,diagnostics='';
const results=[],errors=[],external=[];
const check=async(name,fn)=>{await fn();results.push(name);console.log('passed: '+name);};
const click=name=>page.getByRole('button',{name,exact:true}).click();
const tab=name=>page.getByRole('tab',{name,exact:true}).click();
const choose=async(name,value)=>{await page.getByRole('combobox',{name,exact:true}).click();await page.getByRole('option',{name:value,exact:true}).click();};
try {
 fixture=spawn('python',['-u','python/verify_scanner_integration.py','--dynamic-okx','--ui',join(ui,'dist/index.html')],{cwd:root,stdio:['pipe','pipe','pipe']});
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
 const context=await browser.newContext({viewport:{width:1600,height:1100}});
 await context.route('**/*',route=>{if(!route.request().url().startsWith(base+'/')){external.push(route.request().url());return route.abort();}return route.continue();});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
 await check('normal owner login',async()=>{
  await page.goto(base+'/#opportunities');
  await page.getByRole('textbox',{name:'口令',exact:true}).fill(ready.passphrase);
  await page.getByRole('textbox',{name:'TOTP 验证码',exact:true}).fill(ready.totp);
  await click('登录');
  await page.getByText('已停止 · 配置 v0',{exact:true}).waitFor();
 });
 await check('save named OKX and discover ETH without a market configuration file',async()=>{
  await click('Settings');await click('交易所');
  await page.getByRole('textbox',{name:'交易所名称',exact:true}).fill('动态 OKX');
  await click('保存交易所');
  await page.getByRole('table',{name:'已保存交易所'}).getByText('动态 OKX',{exact:true}).waitFor();
  await page.keyboard.press('Escape');await tab('扫描范围');
  await page.getByRole('checkbox',{name:'动态 OKX',exact:true}).check();
  await page.getByRole('checkbox',{name:'现货',exact:true}).check();
  await choose('深度报价资产','USDT');
  await click('添加到草稿');await click('应用扫描范围');await tab('当前机会');
 });
 await check('native ETH spot input reaches scanner and visible depth coverage',async()=>{
  await click('启动扫描');
  const table=page.getByRole('table',{name:'规范行情观察',exact:true});
  await table.getByText('动态 OKX · ETH / USDT',{exact:true}).waitFor();
  await table.getByText('3000.01 USDT',{exact:true}).waitFor();
  await table.getByText('1 / 1 档 · 来源有限快照',{exact:true}).waitFor();
  const response=await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET'&&r.status()===200);const view=(await response.json()).result;
  assert.equal(view.market.observations.length,1);assert(view.market.observations[0].continuous);
  assert.equal(view.market.evidence[0].input_kind,'synthetic_protocol_fixture');
  assert.equal(view.market.discovery['1:production'].evidence.length,2);
  assert.equal(view.snapshot.cursor === '0',false);
  await writeFile(join(output,'scanner-view.json'),JSON.stringify(view,null,2));
  await page.screenshot({path:join(output,'running.png'),fullPage:true});
 });
 await check('stop releases subscriptions and keeps saved scope',async()=>{
  await click('停止扫描');await page.getByText('已停止 · 配置 v1',{exact:true}).waitFor();
  await tab('扫描范围');
  await page.getByRole('table',{name:'实际生效范围'}).getByText('动态 OKX',{exact:true}).waitFor();
  const view=(await(await page.waitForResponse(r=>r.url().endsWith('/api/scanner')&&r.request().method()==='GET'&&r.status()===200)).json()).result;
  assert.equal(view.market.active_subscriptions,0);assert.equal(view.config.version,'1');
 });
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
