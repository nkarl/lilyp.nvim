// Optional actual-browser check: Node 22+ and Chrome/Chromium, no npm packages.
import assert from 'node:assert/strict';
import {possibleChords, containsCenter} from '../scripts/svg_viewer/group.js';

assert(possibleChords([60, 64, 67, 72]).some(c => c.name === 'C major' && c.complete));
assert(possibleChords([60, 64, 67]).some(c => c.name === 'A minor seventh' && c.missing.join() === '9'));
assert.deepEqual(possibleChords([67, 60, 64, 60]), possibleChords([60, 64, 67]));
assert.equal(possibleChords([60.5, 64, 67]).length, 0);
assert(!containsCenter({left:0,right:10,top:0,bottom:10}, {left:9,top:4,width:2,height:2}));
assert(containsCenter({left:0,right:10,top:0,bottom:10}, {left:8.9,top:4,width:2,height:2}));
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, writeFile, copyFile, mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const folder = await mkdtemp(join(tmpdir(), 'lilyp-browser-test-'));
const source = join(folder, 'main.ly');
await mkdir(join(folder, 'sections'));
await copyFile(join(root, 'tests/fixtures/main.ly'),source);
await copyFile(join(root, 'tests/fixtures/style.ily'),join(folder,'style.ily'));
await copyFile(join(root, 'tests/fixtures/sections/refrain.ily'),join(folder,'sections/refrain.ily'));
// Exercise an actual exported LilyPond font alias, rather than synthetic CSS.
await writeFile(source,(await readFile(source,'utf8')).replace('  <<','  <<\n    \\new ChordNames { \\chordmode { g1:7/d } }'));
const stylePath=join(folder,'style.ily');
await writeFile(stylePath,(await readFile(stylePath,'utf8'))+'\n\\paper { property-defaults.fonts.sans = "LilyPond Sans Serif" }\n');
await writeFile(stylePath,(await readFile(stylePath,'utf8'))+'\nauditNote = \\tweak font-size #-1 \\etc\n');
const partPath=join(folder,'sections/refrain.ily');
await writeFile(partPath,(await readFile(partPath,'utf8')).replace('g4 a b c','\\tuplet 3/2 { <g \\auditNote e>4 a b } c2')
  .replace(' | } }',' | } } % <img src=x onerror=window.inspectorInjected=true>'));
await writeFile(partPath,(await readFile(partPath,'utf8'))+"\ninspectorMusic = \\relative c' { \\time 4/4 \\tempo \"Andante\" 4 = 90 \\mark \\markup \\musicglyph \"scripts.segno\" <c e g>8.\\mf( d16) r8 e f2-> }\n");
await writeFile(source,(await readFile(source,'utf8'))+'\n\\score { \\new Staff { \\inspectorMusic } \\layout {} }\n');


const host = spawn('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE', '-l', join(root, 'tests/browser-host.lua'), folder], {stdio: ['ignore', 'ignore', 'pipe']});
let hostErrors = '';
host.stderr.on('data', chunk => hostErrors += chunk);
const readyPath = join(folder, 'ready.json');
let ready;
const remote = async expression => {
  const child = spawn('nvim', ['--server', ready.socket, '--remote-expr', expression], {stdio: ['ignore', 'pipe', 'pipe']});
  let stdout='', stderr='';
  child.stdout.on('data', chunk => stdout += chunk);
  child.stderr.on('data', chunk => stderr += chunk);
  await new Promise((accept,reject) => child.on('exit', code => code === 0 ? accept() : reject(new Error(stderr))));
  return stdout.trim();
};
const wait = async predicate => {
  const deadline = Date.now() + 10000;
  while (!await predicate()) {
    assert(Date.now() < deadline, 'Timed out waiting for browser/bridge');
    await new Promise(accept => setTimeout(accept, 50));
  }
};
let chrome, websocket;
try {
  await wait(async () => {
    assert(host.exitCode === null, hostErrors);
    try {ready=JSON.parse(await readFile(readyPath,'utf8'));return true;} catch {return false;}
  });
  const url = ready.url;
  chrome = spawn(process.env.LILYP_TEST_BROWSER || 'chromium', ['--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', '--user-data-dir=' + join(folder, 'chrome'), 'about:blank'], {stdio: ['ignore', 'ignore', 'pipe']});
  let diagnostic = '';
  chrome.stderr.on('data', chunk => diagnostic += chunk);
  await wait(() => diagnostic.includes('DevTools listening on '));
  const endpoint = diagnostic.match(/DevTools listening on (ws:\/\/[^\s]+)/)[1];
  const targets = await (await fetch(endpoint.replace('ws:', 'http:').replace(/\/devtools\/browser\/.*/, '/json/list'))).json();
  websocket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await new Promise(accept => websocket.addEventListener('open', accept, {once: true}));
  let counter = 0;
  const pending = new Map();
  websocket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (pending.has(message.id)) {
      const {accept, reject} = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error))); else accept(message.result);
    }
  });
  const call = (method, params = {}) => new Promise((accept, reject) => {
    const id = ++counter; pending.set(id, {accept, reject}); websocket.send(JSON.stringify({id, method, params}));
  });
  const evaluate = async expression => {
    // DOM aliases belong to the harness; production modules expose no globals.
    const script = `{
      const main = document.querySelector('main');
      const inspector = document.querySelector('#source-inspector');
      const originDetails = document.querySelector('#origin-details');
      const originContext = document.querySelector('#origin-context');
      const inspectorClose = document.querySelector('#inspector-close');
      ${expression}
    }`;
    const result = await call('Runtime.evaluate', {expression: script, returnByValue: true, awaitPromise: true});
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const checkFonts = async label => {
    await evaluate('document.fonts.ready.then(() => true)');
    await call('DOM.enable');
    await call('CSS.enable');
    const document=await call('DOM.getDocument');
    const selector='main > svg text[font-family="LilyPond Sans Serif"]';
    const node=await call('DOM.querySelector',{nodeId:document.root.nodeId,selector});
    assert(node.nodeId,'Fixture did not export the LilyPond sans-serif alias');
    const actual=await call('CSS.getPlatformFontsForNode',{nodeId:node.nodeId});
    assert(actual.fonts.length>0,'Chord label was not rendered');
    assert(!actual.fonts.some(font=>font.familyName==='Liberation Serif'),'Chord alias fell back to a serif font');
    const families=await evaluate('getComputedStyle(document.querySelector('+JSON.stringify(selector)+')).fontFamily');
    assert(families.includes('Nimbus Sans') && families.includes('sans-serif'));
    const explicit=await evaluate(`getComputedStyle(document.querySelector('main > svg text[font-family="Noto Serif"]')).fontFamily`);
    assert(explicit.includes('Noto Serif'),'An explicitly chosen family was replaced');
    console.log('PASS: '+label+' font alias uses '+actual.fonts.map(font=>font.familyName).join(', ')+'; explicit lyric font preserved');
  };
  await call('Emulation.setDeviceMetricsOverride', {width: 1100, height: 800, deviceScaleFactor: 1, mobile: false});
  await call('Page.navigate', {url});
  await wait(() => evaluate('document.querySelectorAll("main > svg").length === 1'));
  assert(await evaluate('document.querySelectorAll("[data-note]").length > 0'));
  await checkFonts('interactive viewer');
  assert.equal(await evaluate(`getComputedStyle(main.querySelector('path[fill="currentColor"]')).fill`),'rgb(0, 0, 0)');
  const manifest=JSON.parse(await readFile(join(ready.artifact.directory,'manifest.json'),'utf8'));
  const pointAt=async key=>{
    await evaluate(`main.querySelector('[data-note="${key}"]').scrollIntoView({block:'center',inline:'nearest'})`);
    await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
    return await evaluate(`(()=>{const node=main.querySelector('[data-note="${key}"]');const r=node.getBoundingClientRect();for(let y=1;y<16;y++)for(let x=1;x<16;x++){const px=r.left+r.width*x/16,py=r.top+r.height*y/16;if(document.elementFromPoint(px,py)?.closest('[data-note]')?.dataset.note==='${key}')return {x:px,y:py};}return null;})()`);
  };
  const hover=async key=>{
    const point=await pointAt(key);assert(point,'No pointer target for '+key);
    await call('Input.dispatchMouseEvent',{type:'mouseMoved',...point});
    await wait(()=>evaluate(`!document.querySelector('#source-inspector').hidden && document.querySelector('#source-inspector').dataset.key==='${key}'`));
    await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation => animation.playState !== "running")'));
    return point;
  };
  if (!process.argv.includes('--groups-only')) {
  const editorBefore=await remote("luaeval('_G.lilyp_browser_editor_state()')");
  assert.equal(await evaluate('document.querySelectorAll("aside").length'),1,'Viewer has more than one information card');
  await evaluate('window.originalInformationCard=inspector');
  for(const kind of ['token','macro','structural']){
    const key=ready.samples[kind];assert.notEqual(key,undefined,'Fixture lacks '+kind+' origins');
    await hover(key);
    assert.equal(await evaluate('document.querySelector("#source-inspector").dataset.kind'),kind);
    assert.equal(await evaluate('document.querySelector("#origin-focus").textContent'),manifest.origins[key].focus);
    assert(await evaluate('document.querySelector("#source-inspector").textContent.includes("Read-only")'));
    assert(await evaluate('!originDetails.hidden && getComputedStyle(inspectorClose).visibility === "hidden" && !document.querySelector("#technical-details").open && inspector.dataset.mode === "compact"'));
    assert.equal(await evaluate('inspector.querySelectorAll("input,textarea,img,script").length'),0);
  }
  assert.equal(await remote("luaeval('_G.lilyp_browser_editor_state()')"),editorBefore,'Hover changed the editor');
  assert.equal(await evaluate('window.inspectorInjected'),undefined,'Source excerpt executed as markup');
  // A late response for an earlier target must not replace the current card.
  await evaluate(`window.originalInspectorFetch=window.fetch;window.delayedInspectStarted=false;window.fetch=async(input,options)=>{const response=await window.originalInspectorFetch(input,options);if(input==='inspect'&&!window.delayedInspectStarted){window.delayedInspectStarted=true;await new Promise(done=>setTimeout(done,700));}return response;};`);
  const pendingPoint=await pointAt(ready.first.key);
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...pendingPoint});
  await wait(()=>evaluate('window.delayedInspectStarted'));
  await hover(ready.samples.macro);
  await new Promise(done=>setTimeout(done,800));
  assert.equal(await evaluate('document.querySelector("#source-inspector").dataset.key'),String(ready.samples.macro));
  assert(await evaluate('document.querySelector("#source-inspector pre").textContent.includes("<img")'),'Markup probe was not included in the source excerpt');
  await evaluate('window.fetch=window.originalInspectorFetch');
  await remote("luaeval('_G.lilyp_browser_dirty()')");
  await wait(()=>evaluate('document.querySelector("#origin-hint").textContent.includes("Unsaved edits. Save and press F5 in Neovim")'));
  const dirtyEditor=await remote("luaeval('_G.lilyp_browser_editor_state()')");
  await hover(ready.samples.structural);
  assert.equal(await evaluate('document.querySelector("#origin-focus").textContent'),manifest.origins[ready.samples.structural].focus);
  assert.equal(await remote("luaeval('_G.lilyp_browser_editor_state()')"),dirtyEditor,'Inspection changed an unsaved buffer');
  await remote("luaeval('_G.lilyp_browser_discard()')");
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('document.querySelector("#source-inspector").hidden'));
  assert.equal(await evaluate('main.querySelectorAll("[data-hover]").length'),0);
  console.log('PASS: read-only token/macro/structural hover, frozen excerpts, unsaved-state indication, safe source text, stale response rejection, and Escape dismissal');

  const clickObject=async key=>{
    let point=await pointAt(key);
    if(!point){await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});point=await pointAt(key);}
    assert(point,'Selection target obscured: '+key);
    await call('Input.dispatchMouseEvent',{type:'mouseMoved',...point});
    await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...point});
    await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...point});
    await wait(()=>evaluate(`inspector.dataset.key==='${key}' && inspector.dataset.mode==='expanded' && Boolean(inspector.dataset.mapping)`));
    await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation => animation.playState !== "running")'));
  };
  assert.notEqual(ready.samples.resolved,undefined,'Fixture lacks a resolved note');
  const selectionKey=ready.samples.chord;
  const selectedMusic=manifest.origins[selectionKey].inspection.symbol;
  assert.equal(selectedMusic.chord_size,3);
  const selectionPointer=await hover(selectionKey);
  const compactPosition=await evaluate('({x:inspector.getBoundingClientRect().left,y:inspector.getBoundingClientRect().top})');
  assert(Math.abs(compactPosition.x-selectionPointer.x)<1 && Math.abs(compactPosition.y-selectionPointer.y-16)<1,'Preview did not open just below the pointer');
  const compactHeight=await evaluate('inspector.getBoundingClientRect().height');
  await writeFile(join(folder,'hover-summary.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  const previewContent=await evaluate('({title:document.querySelector("#origin-kind").textContent,summary:document.querySelector("#origin-summary").textContent,source:inspector.querySelector("pre").textContent})');
  assert(previewContent.title.includes(selectedMusic.pitch),'Hover omitted the symbol pitch');
  assert(previewContent.summary.includes('Eighth note, dotted'),'Hover omitted the musical summary');
  await clickObject(selectionKey);
  assert(await evaluate('inspector === window.originalInformationCard && !originDetails.hidden && !inspectorClose.hidden'));
  assert(await evaluate('inspector.getBoundingClientRect().height')>compactHeight,'Click did not reveal technical details');
  assert(await evaluate('document.querySelector("#technical-details").open'),'Click required another action to show technical details');
  assert.deepEqual(await evaluate('({title:document.querySelector("#origin-kind").textContent,summary:document.querySelector("#origin-summary").textContent,source:inspector.querySelector("pre").textContent})'),previewContent,'Click replaced the hover content');
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${compactPosition.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${compactPosition.y})<1`),'Click moved the hover anchor');
  assert.equal(await evaluate('inspector.dataset.mapping'),'resolved');
  assert(await evaluate(`originContext.textContent.includes(${JSON.stringify(selectedMusic.pitch)}) && originContext.textContent.includes("8.") && originContext.textContent.includes("Note ${selectedMusic.chord_member} of 3")`));
  assert.equal(await evaluate('inspector.querySelectorAll("input,textarea").length'),0);
  await writeFile(join(folder,'selection.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate('document.querySelector("#technical-details").open=false');
  await new Promise(done=>setTimeout(done,550));
  assert(await evaluate('!document.querySelector("#technical-details").open'),'Polling reopened manually collapsed details');
  await clickObject(selectionKey);
  assert(await evaluate('document.querySelector("#technical-details").open'),'Another click did not reveal technical details');
  const cardPoint=await evaluate('(()=>{const r=inspector.getBoundingClientRect();return {x:r.right-20,y:r.top+20};})()');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',x:cardPoint.x,y:cardPoint.y-24});
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...cardPoint});
  await new Promise(done=>setTimeout(done,300));
  assert(await evaluate('!inspector.hidden && inspector.dataset.mode === "expanded"'),'Moving into the card dismissed details');
  await hover(ready.samples.structural);
  assert(await evaluate(`inspector.dataset.mode==='compact' && inspector.dataset.key==='${ready.samples.structural}'`),'Detailed card blocked inspection of another symbol');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',x:5,y:5});
  await new Promise(done=>setTimeout(done,350));
  assert(await evaluate('!inspector.hidden'),'Pointer departure dismissed inspection');
  assert(await evaluate('inspector === window.originalInformationCard'),'Inspection replaced the card node');
  await clickObject(selectionKey);
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(a=>a.playState!=="running")'));
  const noteAnchor=await evaluate('({x:inspector.getBoundingClientRect().left+scrollX,y:inspector.getBoundingClientRect().top+scrollY,scrollX,scrollY})');
  await evaluate('main.style.paddingBottom=`${inspector.scrollHeight+innerHeight}px`;window.scrollBy(0,inspector.getBoundingClientRect().bottom+100)');
  await new Promise(done=>setTimeout(done,650));
  assert(await evaluate('!inspector.hidden && getComputedStyle(inspector).position==="absolute" && inspector.getBoundingClientRect().bottom<0'),'Scrolling did not retain the note card outside the viewport');
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left+scrollX-${noteAnchor.x})<1 && Math.abs(inspector.getBoundingClientRect().top+scrollY-${noteAnchor.y})<1`),'Polling moved the note card’s document anchor');
  await evaluate(`window.scrollTo(${noteAnchor.scrollX},${noteAnchor.scrollY})`);
  await new Promise(done=>setTimeout(done,350));
  assert(await evaluate(`!inspector.hidden && Math.abs(inspector.getBoundingClientRect().top+scrollY-${noteAnchor.y})<1`),'Returning to the note dismissed or moved its card');
  await evaluate('main.style.removeProperty("padding-bottom");inspector.focus({preventScroll:true});document.querySelector("#viewer-help > summary").focus({preventScroll:true})');
  await new Promise(done=>setTimeout(done,350));
  assert(await evaluate('!inspector.hidden'),'Focus departure dismissed the note card');
  await remote("luaeval('_G.lilyp_browser_dirty()')");
  await wait(()=>evaluate('document.querySelector("#origin-hint").textContent.includes("Unsaved edits. Save and press F5 in Neovim")'));
  assert(await evaluate(`originContext.textContent.includes(${JSON.stringify(selectedMusic.pitch)})`),'Compiled pitch changed after unsaved edits');
  await remote("luaeval('_G.lilyp_browser_discard()')");
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('inspector.hidden'));
  await clickObject(ready.samples.helper);
  assert.equal(await evaluate('inspector.dataset.mapping'),'resolved');
  assert(await evaluate('originContext.textContent.includes("Note 2 of 2")'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await clickObject(ready.samples.rest);
  assert.equal(await evaluate('inspector.dataset.mapping'),'resolved');
  assert(await evaluate('document.querySelector("#origin-kind").textContent === "Rest" && !originContext.textContent.includes("Written pitch")'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await clickObject(ready.samples.structural);
  assert.equal(await evaluate('inspector.dataset.mapping'),'resolved');
  assert(await evaluate('originContext.children.length > 0'));
  assert(!await evaluate('document.querySelector("#origin-reason").textContent.includes("Musical context unavailable")'));
  for (const category of ['lyric','chord','key','meter','tempo','mark','dynamic','articulation','slur']) {
    await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
    const key=ready.samples['symbol_'+category];
    assert.notEqual(key,undefined,'Fixture lacks '+category+' symbol');
    await clickObject(key);
    assert.equal(await evaluate('inspector.dataset.symbol'),category);
    assert.equal(await evaluate('inspector.dataset.mapping'),'resolved');
    assert(await evaluate('originContext.children.length > 0 && !originContext.textContent.includes("Written pitch")'));
    assert(!await evaluate('document.querySelector("#origin-reason").textContent.includes("Musical context unavailable")'));
  }
  const emptyMargin=await evaluate('({x:8,y:document.querySelector("header").getBoundingClientRect().bottom+8})');
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...emptyMargin});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...emptyMargin});
  assert(await evaluate('inspector.hidden'),'Clicking empty score space did not dismiss the popup');
  console.log('PASS: retained detailed inspection, pointer/focus departure, switching symbols, scroll retention and stable document anchoring, resolved note/helper/rest and lyric/chord/marking/structure cards, compiled details after dirty edits, and read-only controls');

  // Hold the navigation request until after dismissal. Its eventual editor
  // acknowledgement must not be mistaken for a new F7 reveal request.
  await evaluate(`window.navigationFetch=window.fetch;window.releaseNavigation=null;window.navigationFinished=false;window.navigationPolls=0;
    window.fetch=async(input,options)=>{
      if(input==='click')await new Promise(done=>window.releaseNavigation=done);
      const response=await window.navigationFetch(input,options);
      if(input==='click')window.navigationFinished=true;
      if(String(input).startsWith('state?')&&window.navigationFinished)window.navigationPolls++;
      return response;
    };`);
  await clickObject(ready.first.key);
  await wait(()=>evaluate('typeof window.releaseNavigation === "function"'));
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...emptyMargin});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...emptyMargin});
  assert(await evaluate('inspector.hidden'));
  await evaluate('window.releaseNavigation()');
  await wait(()=>evaluate('window.navigationFinished && window.navigationPolls >= 2'));
  assert(await evaluate('inspector.hidden'),'Delayed click acknowledgement reopened dismissed inspection');
  await evaluate('window.fetch=window.navigationFetch');
  await remote("luaeval('_G.lilyp_browser_forward()')");
  await wait(()=>evaluate(`!inspector.hidden && inspector.dataset.mode==='expanded' && inspector.dataset.key==='${ready.first.key}'`));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('inspector.hidden'));
  // A repeated F7 on the same source object is a fresh reveal, not an echo.
  await remote("luaeval('_G.lilyp_browser_forward()')");
  await wait(()=>evaluate(`!inspector.hidden && inspector.dataset.mode==='expanded' && inspector.dataset.key==='${ready.first.key}'`));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  console.log('PASS: delayed click dismissal stays closed; explicit and repeated F7 still reveal inspection');

  const dimensions = () => evaluate('(() => {const r=document.querySelector("main > svg").getBoundingClientRect();return {width:r.width,height:r.height,left:r.left};})()');
  const originalSize = await dimensions();
  assert(Math.abs(originalSize.width - 210 * 96 / 25.4) < 1, 'A4 page lost its physical width');
  assert(Math.abs(originalSize.height - 297 * 96 / 25.4) < 1, 'A4 page lost its physical height');
  assert.equal(await evaluate('document.querySelector("#zoom")'), null);
  const midi = await readFile(join(folder,'build/main.midi'));
  // Browser page zoom reduces the CSS viewport and increases device pixels per
  // CSS pixel. The engraved page must retain its dimensions and overflow it.
  await call('Emulation.setDeviceMetricsOverride', {width:550,height:400,deviceScaleFactor:2,mobile:false});
  const zoomedSize = await dimensions();
  assert(Math.abs(zoomedSize.width-originalSize.width)<1 && Math.abs(zoomedSize.height-originalSize.height)<1,
    'Page resized to fit the zoomed viewport');
  assert(await evaluate('document.documentElement.scrollWidth > document.documentElement.clientWidth'), 'Zoomed page did not overflow horizontally');
  assert(zoomedSize.left >= 0, 'Left edge of an overflowing page became inaccessible');

  await remote("luaeval('_G.lilyp_browser_forward()')");
  await wait(() => evaluate(`document.querySelectorAll('[data-highlight]').length === 1 && !inspector.hidden && inspector.dataset.key==='${ready.first.key}'`));
  const bounds = await evaluate('(() => {const r=document.querySelector("[data-highlight]").getBoundingClientRect(); return {width:r.width,height:r.height};})()');
  assert(bounds.width > 0 && bounds.height > 0);
  assert(await evaluate('!inspector.hidden'),'F7 did not open the selected-object inspector');
  assert(await evaluate('inspector.dataset.mode === "expanded" && !originDetails.hidden && inspector === window.originalInformationCard'));
  // At browser zoom the fixed inspector may cover the next pointer target.
  const closePoint=await evaluate('(()=>{const b=document.querySelector("#inspector-close").getBoundingClientRect();return {x:b.x+b.width/2,y:b.y+b.height/2};})()');
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...closePoint});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...closePoint});
  assert(await evaluate('inspector.hidden'),'Close selection button did not dismiss it');
  await remote("luaeval('_G.lilyp_browser_reset()')");
  const clickPoint=await hover(ready.first.key);
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...clickPoint});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...clickPoint});
  await wait(async () => (await evaluate('document.querySelector("#status").textContent')) === 'Source opened in Neovim');
  await wait(async () => await remote("luaeval('_G.lilyp_browser_clicked()')") === 'true');
  await evaluate('window.scrollTo(80,300)');
  const x = await evaluate('window.scrollX');
  const y = await evaluate('window.scrollY');
  await remote("luaeval('_G.lilyp_browser_rebuild()')");
  await wait(async () => (await evaluate('main.dataset.revision')) !== ready.revision);
  const rebuiltSize=await dimensions();
  assert(Math.abs(rebuiltSize.width-originalSize.width)<1 && Math.abs(rebuiltSize.height-originalSize.height)<1);
  assert.equal(await evaluate('window.devicePixelRatio'), 2, 'Rebuild reset browser zoom emulation');
  assert(Math.abs(await evaluate('window.scrollX') - x) < 5, 'Rebuild lost horizontal position');
  assert.deepEqual(await readFile(join(folder,'build/main.midi')),midi,'Viewer change altered MIDI');
  assert(Math.abs(await evaluate('window.scrollY') - y) < 5, 'Rebuild lost scroll position');
  assert.equal(await evaluate('document.querySelectorAll("[data-highlight]").length'), 1);
  assert(await evaluate('document.querySelector("#source-inspector").hidden'),'Rebuild retained an old inspection card');
  await call('Emulation.setDeviceMetricsOverride', {width:1100,height:800,deviceScaleFactor:1,mobile:false});
  assert(Math.abs((await dimensions()).width-originalSize.width)<1);
  await evaluate('window.scrollTo(0,0)');
  const screenshot = await call('Page.captureScreenshot', {format: 'png'});
  const screenshotPath = join(folder, 'viewer.png');
  await writeFile(screenshotPath, Buffer.from(screenshot.data, 'base64'));
  console.log('PASS: browser SVG rendering, visible highlight, click bridge, refresh, fixed physical dimensions, zoomed viewport overflow, and scroll retention');
  console.log('Screenshot: ' + screenshotPath);
  // F7 can select before the browser has loaded its first generation.
  await remote("luaeval('_G.lilyp_browser_forward()')");
  await call('Page.reload', {ignoreCache: true});
  await wait(()=>evaluate(`document.querySelector('#source-inspector')?.dataset.mode==='expanded' && document.querySelector('#source-inspector').dataset.key==='${ready.first.key}' && !document.querySelector('#origin-details').hidden && document.querySelector('#origin-context').children.length>0`));
  console.log('PASS: first-load F7 expands the unified information card');
  // Presentation polish: summaries lead; full context remains discoverable and
  // keyboard reachable without stealing focus from ordinary source navigation.
  assert(await evaluate(`document.querySelector('#origin-kind').textContent.includes(${JSON.stringify(manifest.origins[ready.first.key].inspection.symbol.pitch)})`));
  assert(await evaluate('document.querySelector("#technical-details").open'),'F7 did not reveal technical details');
  await evaluate('document.querySelector("#technical-details").open=false');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "current"'));
  assert.equal(await evaluate('document.querySelector("#score-state").getAttribute("aria-live")'),'polite');
  assert.equal(await evaluate('document.querySelector("#page-count").textContent'),'1 page');
  await evaluate('document.querySelector("#show-details").focus()');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r',unmodifiedText:'\r'});
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
  assert(await evaluate('document.activeElement === inspector'),'Details button did not focus inspection');
  await call('Emulation.setDeviceMetricsOverride',{width:1100,height:1200,deviceScaleFactor:1,mobile:false});
  await new Promise(done=>setTimeout(done,100));
  const beforeDisclosure=await evaluate('({x:inspector.getBoundingClientRect().left,y:inspector.getBoundingClientRect().top})');
  assert(await evaluate('!originContext.textContent.includes("Symbol") && !originContext.textContent.includes("Shared source")'),'Singleton source or symbol heading was repeated');
  assert.equal(await evaluate('originContext.querySelectorAll(".detail-group").length'),2,'Pitch and rhythm were not grouped');
  await evaluate(`window.originalResizeAnimate=inspector.animate;
    inspector.animate=function(...args){const motion=window.originalResizeAnimate.apply(this,args);window.resizeMotion=motion;return motion;};`);
  await evaluate('document.querySelector("#technical-details > summary").focus()');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r',unmodifiedText:'\r'});
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
  await wait(()=>evaluate('document.querySelector("#technical-details").open'));
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert.equal(await evaluate('window.resizeMotion.effect.getTiming().easing'),'ease-in-out');
  assert(await evaluate('window.resizeMotion.effect.getKeyframes().every(frame=>!("left" in frame) && !("top" in frame))'),'Expansion animated the anchor');
  await evaluate('inspector.animate=window.originalResizeAnimate');
  const fullSize=()=>evaluate('getComputedStyle(inspector).maxWidth==="none" && getComputedStyle(inspector).maxHeight==="none" && inspector.scrollHeight<=inspector.clientHeight+1');
  await wait(fullSize);
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${beforeDisclosure.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${beforeDisclosure.y})<1`),'Disclosure moved the card despite available space');

  await writeFile(join(folder,'polish-technical.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate('document.querySelector("#technical-details").open=false');
  await call('Emulation.setDeviceMetricsOverride',{width:1100,height:800,deviceScaleFactor:1,mobile:false});
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  await wait(fullSize);
  await writeFile(join(folder,'polish-desktop.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('inspector.hidden && document.activeElement === document.querySelector("#viewer-help > summary")'));
  assert(await evaluate('document.querySelector("#show-details").disabled'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r',unmodifiedText:'\r'});
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
  assert(await evaluate('document.querySelector("#viewer-help").open'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('!document.querySelector("#viewer-help").open'));

  // Polling/status responses are overridden only in this browser to exercise
  // presentation states; compiled sources, hashes, and server guards stay real.
  await evaluate(`window.polishFetch=window.fetch;window.polishState='current';window.polishLongPath=false;
    window.fetch=async(input,options)=>{
      const polling=String(input).startsWith('state?');
      if(polling && window.polishState==='offline')throw new TypeError('Test connection lost');
      const response=await window.polishFetch(input,options);
      if(!polling && input!=='inspect')return response;
      const result=await response.json();
      result.stale=window.polishState==='stale';result.dirty=window.polishState==='dirty';
      if(input==='inspect' && window.polishLongPath){
        result.origin.path='sections/'+('long-folder-name/'.repeat(12))+'Lời-ca-rất-dài.ily';
        result.origin.inspection={tag:'unsupported'};
      }
      return new Response(JSON.stringify(result),{status:response.status,headers:{'Content-Type':'application/json'}});
    };`);
  await evaluate("window.polishState='stale'");
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "stale"'));
  await clickObject(ready.first.key);
  await wait(()=>evaluate('document.querySelector("#status").textContent === "Source opened in Neovim"'));
  assert.equal(await evaluate('document.querySelector("#score-state").textContent'),'Source changed','Navigation feedback hid a persistent freshness warning');
  await evaluate("window.polishState='dirty'");
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "dirty"'));
  await evaluate("window.polishState='offline'");
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "disconnected"'));
  assert.equal(await evaluate('main.querySelectorAll("svg").length'),1,'Connection loss cleared the compiled score');
  assert(await evaluate('document.querySelector("#status").textContent.includes("Reconnecting")'));
  await evaluate("window.polishState='current'");
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "current"'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Emulation.setDeviceMetricsOverride',{width:390,height:720,deviceScaleFactor:1,mobile:false});
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await evaluate('window.polishLongPath=true');
  await clickObject(ready.samples.symbol_lyric);
  assert.equal(await evaluate('inspector.dataset.mapping'),'unavailable');
  assert.equal(await evaluate('document.querySelector("#origin-kind").textContent'),'Unsupported symbol');
  assert.equal(await evaluate('document.querySelector("#origin-summary").textContent'),'');
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#origin-kind")).color'),'rgb(133, 83, 0)');
  assert(await evaluate('document.querySelector("#origin-full-path").textContent.length > 180'));
  assert(await evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  await wait(fullSize);
  assert.equal(await evaluate('inspector.dataset.placement'),'score');
  assert(await evaluate('inspector.getBoundingClientRect().right > document.documentElement.clientWidth'),'Narrow viewport shrank or shifted the note card');
  assert(await evaluate('!document.querySelector("#source-path").open && document.querySelector("#origin-location").textContent.length < 80'));
  await writeFile(join(folder,'polish-narrow-collapsed.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate('document.querySelector("#source-path > summary").focus()');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,text:'\r',unmodifiedText:'\r'});
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});
  await wait(()=>evaluate('document.querySelector("#source-path").open'));
  await wait(fullSize);
  await writeFile(join(folder,'polish-narrow.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate("window.polishState='offline'");
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "disconnected"'));
  await writeFile(join(folder,'polish-disconnected.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate('window.fetch=window.polishFetch');
  await wait(()=>evaluate('document.querySelector("#score-state").dataset.state === "current"'));
  await call('Emulation.setDeviceMetricsOverride',{width:1100,height:800,deviceScaleFactor:1,mobile:false});
  await call('Emulation.setEmulatedMedia',{features:[]});
  console.log('PASS: musical summaries, technical disclosure, keyboard focus/help, stable freshness versus feedback, reconnect retention, narrow/long-path layout, unsupported symbols, and reduced motion');
  console.log('Polish screenshots: '+folder);
  // Semantic styling tokens must reach both CSS and presentation effects.
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await evaluate(`document.documentElement.style.setProperty('--color-inspection-active','#123456');
    document.documentElement.style.setProperty('--inspection-gap','20px');
    document.documentElement.style.setProperty('--motion-open-duration','137ms');
    window.originalCardAnimate=inspector.animate;
    inspector.animate=function(...args){const motion=window.originalCardAnimate.apply(this,args);window.tokenOpeningMotion=motion;return motion;};`);
  const tokenPointer=await pointAt(ready.first.key);
  await clickObject(ready.first.key);
  assert.equal(await evaluate('getComputedStyle(main.querySelector("[data-highlight]")).stroke'),'rgb(18, 52, 86)','Score highlight ignored its semantic color');
  assert.equal(await evaluate('window.tokenOpeningMotion.effect.getTiming().duration'),137,'Opening motion ignored its duration token');
  assert(await evaluate('window.tokenOpeningMotion.effect.getKeyframes().every(frame=>!["left","top"].some(key=>key in frame))'),'Motion moved the anchor');
  assert.equal(await evaluate('window.tokenOpeningMotion.effect.getTiming().easing'),'ease-in-out');
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${tokenPointer.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${tokenPointer.y}-20)<1`),'Placement ignored its cursor anchor or gap token');
  await evaluate(`inspector.animate=window.originalCardAnimate;
    for(const name of ['--color-inspection-active','--inspection-gap','--motion-open-duration'])document.documentElement.style.removeProperty(name);
    window.dispatchEvent(new Event('resize'));`);
  console.log('PASS: semantic color, placement, and motion tokens drive rendered effects');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Emulation.setDeviceMetricsOverride',{width:550,height:420,deviceScaleFactor:1,mobile:false});
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  const edgePointer=await hover(selectionKey);
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${edgePointer.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${edgePointer.y}-16)<1`),'Viewport edge shifted the hover card away from the cursor');
  const edgeAnchor=await evaluate('({x:inspector.getBoundingClientRect().left,y:inspector.getBoundingClientRect().top})');
  await clickObject(selectionKey);
  await evaluate('document.querySelector("#technical-details").open=true');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${edgeAnchor.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${edgeAnchor.y})<1`),'Offscreen expansion moved the preview anchor');
  await wait(fullSize);
  assert(await evaluate('inspector.getBoundingClientRect().bottom > innerHeight'),'Details did not extend below the viewport');
  assert(await evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'),'Reduced motion animated expansion');
  await writeFile(join(folder,'polish-constrained.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await call('Emulation.setDeviceMetricsOverride',{width:1100,height:800,deviceScaleFactor:1,mobile:false});
  await call('Emulation.setEmulatedMedia',{features:[]});
  console.log('PASS: offscreen expansion retains its cursor anchor, fits disclosed content, and respects reduced motion');
  }
  // Real compiler metadata and real pointer gestures, including cross-staff
  // measure membership, strict inclusion, card lifetimes and selected-note chord analysis.
  const selectionSourceBefore = await readFile(source, 'utf8');
  await writeFile(source, selectionSourceBefore + `\nselectionMusic = { <c' e' g'>2 a'2 | d'1 }\n\\score { << \\new Staff \\selectionMusic \\new Staff \\selectionMusic >> \\layout {} }\n`);
  const selectionRevision = await evaluate('main.dataset.revision');
  await remote("luaeval('_G.lilyp_browser_rebuild()')");
  await wait(()=>evaluate(`main.dataset.revision !== ${JSON.stringify(selectionRevision)}`));
  const selectionSource = await readFile(source, 'utf8');
  const selectionEditor = await remote("luaeval('_G.lilyp_browser_editor_state()')");
  const selectionMidiPath = join(folder, 'build/main.midi');
  const selectionMidi = await readFile(selectionMidiPath);
  await evaluate(`window.selectionHeads=[...main.querySelectorAll('[data-measure]')].filter(n=>n.dataset.measure.split(':')[0]===String(Math.max(...[...main.querySelectorAll('[data-measure]')].map(n=>Number(n.dataset.measure.split(':')[0])))));
    window.selectionMeasure=window.selectionHeads.filter(n=>n.dataset.measure===window.selectionHeads.find(n=>n.dataset.pitch==='60').dataset.measure);
    window.selectionStart=window.selectionMeasure.filter(n=>n.dataset.pitch==='67').sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0];
    window.selectionStart.scrollIntoView({block:'center',inline:'center'});`);
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  const drag = async (start, end) => {
    await call('Input.dispatchMouseEvent', {type:'mouseMoved', ...start});
    await call('Input.dispatchMouseEvent', {type:'mousePressed', button:'left', buttons:1, clickCount:1, ...start});
    await call('Input.dispatchMouseEvent', {type:'mouseMoved', button:'left', buttons:1, ...end});
    await call('Input.dispatchMouseEvent', {type:'mouseReleased', button:'left', buttons:0, clickCount:1, ...end});
  };
  const start = await evaluate(`(()=>{const n=window.selectionStart,r=n.getBoundingClientRect();for(let y=1;y<10;y++)for(let x=1;x<10;x++){const px=r.left+r.width*x/20,py=r.top+r.height*y/20;if(document.elementFromPoint(px,py)?.closest('[data-measure]')===n)return {x:px,y:py};}return null})()`);
  const end = await evaluate(`(()=>{const rs=window.selectionMeasure.filter(n=>n.dataset.pitch!=='69').map(n=>n.getBoundingClientRect());return {x:Math.max(...rs.map(r=>r.right))+1,y:Math.max(...rs.map(r=>r.bottom))+1}})()`);
  assert(start, 'No upper-left notehead hit target');
  await drag(start,end);
  await wait(()=>evaluate('!inspector.hidden && inspector.dataset.symbol === "group"'));
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Cross-staff chord noteheads were not selected independently');
  assert.equal(await evaluate('main.querySelectorAll("[data-selection-region]").length'),1,'Selection did not share one rectangular background');
  assert(await evaluate(`(()=>{const region=main.querySelector('[data-selection-region]'),r=region.getBoundingClientRect(),style=getComputedStyle(region);
    return region===region.parentElement.firstElementChild && style.fill==='rgb(230, 240, 233)' && style.strokeWidth==='2px' && style.pointerEvents==='none'
      && [...main.querySelectorAll('[data-musical-selection]')].every(n=>{const b=n.getBoundingClientRect();return r.left<b.left && r.top<b.top && r.right>b.right && r.bottom>b.bottom;});})()`),'Shared selection background did not enclose all notes behind the music');
  await wait(()=>evaluate('document.querySelectorAll(".group-note pre").length===6'));
  assert(await evaluate('document.querySelector("#group-content").textContent.includes("C major")'));
  assert(await evaluate('document.querySelector("#more-chords").textContent.includes("A minor seventh") && !document.querySelector("#more-chords").open'),'Incomplete interpretations should be available behind More possibilities');
  assert.equal(await remote("luaeval('_G.lilyp_browser_editor_state()')"),selectionEditor,'Drag navigated or edited source');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  const groupKey = await evaluate('inspector.dataset.key');
  assert(await evaluate('getComputedStyle(inspector).maxHeight==="none" && getComputedStyle(inspector).maxWidth==="none" && inspector.scrollHeight<=inspector.clientHeight+1'),'Group card was constrained or required internal scrolling');
  await evaluate('window.fullGroupWidth=inspector.getBoundingClientRect().width');
  const groupScroll = await evaluate('({x:window.scrollX,y:window.scrollY})');
  const groupAnchor = await evaluate('({x:inspector.getBoundingClientRect().left,y:inspector.getBoundingClientRect().top})');
  assert(await evaluate(`(()=>{const area=main.querySelector('[data-selection-region]').getBoundingClientRect(),card=inspector.getBoundingClientRect(),gap=parseFloat(getComputedStyle(inspector).getPropertyValue('--inspection-gap'));return Math.abs(card.left-area.left)<1 && Math.abs(card.top-area.bottom-gap)<1;})()`),'Group card was not anchored below the highlighted selection');
  await evaluate('document.querySelector("#more-chords").open=true');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${groupAnchor.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${groupAnchor.y})<1`),'Chord disclosure expansion moved the selection anchor');
  assert(await evaluate('inspector.scrollHeight<=inspector.clientHeight+1'),'Expanded chord possibilities were clipped inside the card');
  await evaluate('document.querySelector("#more-chords").open=false');

  const groupInside = await evaluate('(()=>{const r=inspector.getBoundingClientRect();return {x:r.right-25,y:r.top+20}})()');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...groupInside});
  await evaluate('main.style.paddingBottom=`${inspector.scrollHeight+innerHeight}px`;window.scrollBy(0,inspector.getBoundingClientRect().bottom+100)');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  assert(await evaluate(`!inspector.hidden && inspector.dataset.key===${JSON.stringify(groupKey)} && Math.abs(inspector.getBoundingClientRect().left+window.scrollX-${groupAnchor.x+groupScroll.x})<1 && Math.abs(inspector.getBoundingClientRect().top+window.scrollY-${groupAnchor.y+groupScroll.y})<1`),'Scrolling changed the group card’s document anchor');
  assert(await evaluate('[...main.querySelectorAll("[data-musical-selection]")].every(n=>n.getBoundingClientRect().bottom<document.querySelector("header").getBoundingClientRect().bottom)'),'Test did not scroll the selected notes out of view');
  assert(await evaluate('getComputedStyle(inspector).position==="absolute" && inspector.dataset.placement==="score" && inspector.getBoundingClientRect().bottom<0'),'The group card stayed in the viewport instead of scrolling away with the score');
  await new Promise(done=>setTimeout(done,650));
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().top+window.scrollY-${groupAnchor.y+groupScroll.y})<1`),'Polling moved the group card back into the viewport');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',x:30,y:100});
  await new Promise(done=>setTimeout(done,250));
  assert(await evaluate('!inspector.hidden && inspector.dataset.symbol==="group"'),'Hovering empty space dismissed the group card');
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Outside hover cleared the musical selection');
  await evaluate('document.querySelector("#show-details").click()');
  await evaluate(`window.scrollTo(${groupScroll.x},${groupScroll.y})`);
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  assert(await evaluate('!inspector.hidden'),'Returning to the selected notes dismissed the card');
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${groupAnchor.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${groupAnchor.y})<1`),'Returning to the score changed the card’s original position');
  await evaluate('main.style.removeProperty("padding-bottom")');
  const replacementKeys=await evaluate('[...main.querySelectorAll("[data-measure]:not([data-musical-selection]) [data-note]")].map(n=>Number(n.dataset.note))');
  let replacementKey, replacementPoint;
  for (const key of replacementKeys) {
    const point=await pointAt(key);
    if (point) { replacementKey=key;replacementPoint=point;break; }
  }
  assert(replacementPoint,'No unselected note was accessible outside the persistent card');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...replacementPoint});
  await wait(()=>evaluate(`!inspector.hidden && inspector.dataset.key===String(${replacementKey}) && inspector.dataset.symbol!=="group"`));
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Hovering a new note cleared the musical selection');
  await evaluate('document.querySelector("#show-details").click()');
  assert(await evaluate('!inspector.hidden && inspector.dataset.symbol==="group"'),'Details did not restore the group card after note hover');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left+window.scrollX-${groupAnchor.x+groupScroll.x})<1 && Math.abs(inspector.getBoundingClientRect().top+window.scrollY-${groupAnchor.y+groupScroll.y})<1`),'Reopening the group card re-anchored it to the current viewport');
  await evaluate(`window.scrollTo(${groupScroll.x},${groupScroll.y})`);
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');

  assert(await evaluate('!document.querySelector("#chord-scope") && !document.querySelector("#group-content select")'),'Obsolete analysis scope control remains');
  assert.deepEqual(await evaluate('[...document.querySelectorAll("#group-content > ul strong")].map(n=>n.textContent)'),['C major'],'Chord analysis included unselected A notes from the measure');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert(await evaluate('inspector.hidden && main.querySelectorAll("[data-musical-selection]").length===6'));
  const clickSelectionPoint=async point=>{
    await call('Input.dispatchMouseEvent',{type:'mouseMoved',...point});
    await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...point});
    await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...point});
  };
  const selectedGap=await evaluate('(()=>{const r=main.querySelector("[data-selection-region]").getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2}})()');
  await clickSelectionPoint(selectedGap);
  assert(await evaluate(`!inspector.hidden && inspector.dataset.key===${JSON.stringify(groupKey)} && main.querySelectorAll('[data-musical-selection]').length===6`),'Clicking blank space inside the selected area did not reopen the retained group');
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left+window.scrollX-${groupAnchor.x+groupScroll.x})<1 && Math.abs(inspector.getBoundingClientRect().top+window.scrollY-${groupAnchor.y+groupScroll.y})<1`),'Selection-area click changed the original card anchor');
  await evaluate('document.querySelector("#inspector-close").click()');
  const selectedHeadKey=await evaluate('Number(window.selectionStart.querySelector("[data-note]").dataset.note)');
  const selectedHeadPoint=await pointAt(selectedHeadKey);
  assert(selectedHeadPoint,'Selected notehead was not reachable');
  await clickSelectionPoint(selectedHeadPoint);
  assert(await evaluate(`!inspector.hidden && inspector.dataset.key===${JSON.stringify(groupKey)} && main.querySelectorAll('[data-musical-selection]').length===6`),'Clicking a selected notehead navigated instead of reopening the group');
  await evaluate('document.querySelector("#more-chords").open=true');
  await clickSelectionPoint(selectedHeadPoint);
  assert(await evaluate('!inspector.hidden && document.querySelector("#more-chords").open'),'Repeated selected-area click closed the card or reset its disclosure');
  await evaluate('document.querySelector("#more-chords").open=false');
  assert.equal(await remote("luaeval('_G.lilyp_browser_editor_state()')"),selectionEditor,'Reopening through the selected area changed the editor');

  await evaluate('document.querySelector("#show-details").click()');
  assert(await evaluate('!inspector.hidden && document.querySelector("#group-content > ul strong").textContent==="C major"'));
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  await writeFile(join(folder,'group-selection.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),0);
  assert.equal(await evaluate('main.querySelectorAll("[data-selection-region]").length'),0,'Clearing the selection retained its background');
  // The same notes produce the same anchor for a different release point.
  const releaseBeyond=await evaluate('(()=>{const rs=window.selectionMeasure.filter(n=>n.dataset.pitch!=="69").map(n=>n.getBoundingClientRect());return {x:Math.max(...rs.map(r=>r.right))+4,y:Math.max(...rs.map(r=>r.bottom))+10}})()');
  await drag(start,releaseBeyond);
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6);
  assert(await evaluate(`Math.abs(inspector.getBoundingClientRect().left-${groupAnchor.x})<1 && Math.abs(inspector.getBoundingClientRect().top-${groupAnchor.y})<1`),'Pointer release position changed the anchor for the same selected notes');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  // A short, narrow viewport must not shrink or reposition the group card.
  await call('Emulation.setDeviceMetricsOverride',{width:390,height:460,deviceScaleFactor:1,mobile:false});
  await evaluate(`window.scrollTo(${groupScroll.x},${groupScroll.y})`);
  const narrowStart=await evaluate(`(()=>{const n=window.selectionStart,r=n.getBoundingClientRect();for(let y=1;y<10;y++)for(let x=1;x<10;x++){const px=r.left+r.width*x/20,py=r.top+r.height*y/20;if(document.elementFromPoint(px,py)?.closest('[data-measure]')===n)return {x:px,y:py};}return null})()`);
  const narrowEnd=await evaluate('(()=>{const rs=window.selectionMeasure.filter(n=>n.dataset.pitch!=="69").map(n=>n.getBoundingClientRect());return {x:Math.max(...rs.map(r=>r.right))+1,y:Math.max(...rs.map(r=>r.bottom))+1}})()');
  assert(narrowStart,'No narrow-viewport note target');
  await drag(narrowStart,narrowEnd);
  await wait(()=>evaluate('inspector.getAnimations({subtree:true}).every(animation=>animation.playState!=="running")'));
  assert(await evaluate(`(()=>{const area=main.querySelector('[data-selection-region]').getBoundingClientRect(),r=inspector.getBoundingClientRect(),gap=parseFloat(getComputedStyle(inspector).getPropertyValue('--inspection-gap'));return Math.abs(r.top-area.bottom-gap)<1 && Math.abs(r.left-area.left)<1 && r.bottom>document.documentElement.clientHeight && r.right>document.documentElement.clientWidth && Math.abs(r.width-window.fullGroupWidth)<2 && inspector.scrollHeight<=inspector.clientHeight+1;})()`),'Viewport edge moved the group card above its selected area');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Emulation.setDeviceMetricsOverride',{width:1100,height:800,deviceScaleFactor:1,mobile:false});
  await evaluate(`window.scrollTo(${groupScroll.x},${groupScroll.y})`);
  // A marquee can begin in the workspace margin, without hitting notation.
  const marginStart=await evaluate(`(()=>{const page=window.selectionStart.closest('svg').getBoundingClientRect(),rs=window.selectionMeasure.map(n=>n.getBoundingClientRect());return {x:page.left-12,y:Math.min(...rs.map(r=>r.top))-18}})()`);
  assert(await evaluate(`!document.elementFromPoint(${marginStart.x},${marginStart.y})?.closest('[data-note], [data-measure]')`),'Margin start unexpectedly hit notation');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...marginStart});
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...marginStart});
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,x:marginStart.x+8,y:marginStart.y+8});
  assert(await evaluate('!document.querySelector("#selection-area").hidden && !main.querySelector("[data-musical-selection]")'),'Empty-space drag did not show a rectangle before reaching notes');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,...end});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Margin drag did not acquire the enclosed measure');
  await writeFile(join(folder,'margin-drag.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  const beyondBar=await evaluate('(()=>{const rs=window.selectionHeads.map(n=>n.getBoundingClientRect());return {x:Math.max(...rs.map(r=>r.right))+12,y:Math.max(...rs.map(r=>r.bottom))+12}})()');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,...beyondBar});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),8,'Margin drag changed measure when extended beyond a barline');
  // Shrink to no notes, then expand again: the acquired measure stays fixed.
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,x:marginStart.x+8,y:marginStart.y+8});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),0);
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,...beyondBar});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...beyondBar});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),8);
  assert.deepEqual(await evaluate('[...document.querySelectorAll("#group-content > ul strong")].map(n=>n.textContent)'),['A minor seventh'],'Chord suggestions did not update to include newly selected A notes');
  assert.equal(await remote("luaeval('_G.lilyp_browser_editor_state()')"),selectionEditor,'Margin drag navigated or edited source');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  // Reverse direction and one large pointer step choose the nearest enclosed
  // note, rather than whichever source object happens to be serialized first.
  await drag(beyondBar,marginStart);
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),2,'Reverse margin drag did not acquire the nearest measure');
  assert(await evaluate('[...main.querySelectorAll("[data-musical-selection]")].every(n=>n.dataset.pitch==="62")'));
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  // Releasing an empty-space drag without any notes leaves no selection/card.
  await drag(marginStart,{x:marginStart.x+8,y:marginStart.y+8});
  assert(await evaluate('inspector.hidden && !main.querySelector("[data-musical-selection]") && document.querySelector("#selection-area").hidden'));
  // Ending exactly at a notehead center excludes that notehead.
  const strictEnd=await evaluate('(()=>{const n=window.selectionMeasure.filter(n=>n.dataset.pitch==="64").sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0],r=n.getBoundingClientRect();return {x:r.right+1,y:r.top+r.height/2}})()');
  await drag(start,strictEnd);
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),1,'Rectangle boundary included a notehead center');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  // Crossing the next barline still excludes its noteheads. The upper A is
  // above the starting G and therefore remains outside this rectangle.

  const crossEnd=await evaluate('(()=>{const rs=window.selectionHeads.map(n=>n.getBoundingClientRect());return {x:Math.max(...rs.map(r=>r.right))+1,y:Math.max(...rs.map(r=>r.bottom))+1}})()');
  await drag(start,crossEnd);
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),7,'A drag crossing the barline selected another measure');
  // Cancelling a replacement drag restores the previous target group.
  await evaluate('document.querySelector("#inspector-close").click()');
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...start});
  await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...start});
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,...strictEnd});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...strictEnd});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),7,'Cancelled drag replaced the previous selection');
  await evaluate('window.selectionStart.focus({preventScroll:true})');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Space did not toggle an individual chord member');
  assert(await evaluate('!document.querySelector("#group-content select")'),'New selection restored an analysis scope control');
  assert(await evaluate('parseFloat(getComputedStyle(window.selectionStart).outlineWidth)<=1 && parseFloat(getComputedStyle(window.selectionStart).outlineOffset)<=1'),'SVG keyboard focus obscured the selection region');
  await evaluate('window.selectionRegionOffset=main.querySelector("[data-selection-region]").getBoundingClientRect().top-main.querySelector("[data-musical-selection]").getBoundingClientRect().top;window.scrollBy(0,20)');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  assert(await evaluate('!inspector.hidden'),'Score scrolling dismissed the selected-note card');
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),6,'Scrolling cleared selection');
  assert(await evaluate('Math.abs(main.querySelector("[data-selection-region]").getBoundingClientRect().top-main.querySelector("[data-musical-selection]").getBoundingClientRect().top-window.selectionRegionOffset)<1'),'Scrolling moved the selection background away from its notes');
  await evaluate('document.querySelector("#inspector-close").click()');
  await writeFile(join(folder,'selection-region.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png'})).data,'base64'));
  await evaluate('document.querySelector("#show-details").click()');
  assert(await evaluate('!inspector.hidden'));
  await evaluate('document.querySelector(".brand").click()');
  assert(await evaluate('inspector.hidden && main.querySelectorAll("[data-musical-selection]").length===6'),'Outside toolbar click did not dismiss only the group card');
  await evaluate('document.querySelector("#show-details").click()');
  await evaluate('document.querySelector("#inspector-close").click();main.dispatchEvent(new MouseEvent("click",{bubbles:true}))');
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),0,'Empty space retained selection');
  // Old/ambiguous metadata is unavailable rather than inferred from geometry.
  await evaluate('window.unavailableMeasures=[...main.querySelectorAll("[data-measure]")].map(n=>[n,n.dataset.measure]);window.unavailableMeasures.forEach(([n])=>n.removeAttribute("data-measure"));window.selectionStart.scrollIntoView({block:"center",inline:"center"})');
  await evaluate('new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)))');
  const unavailableStart=await evaluate(`(()=>{const n=window.selectionStart,r=n.getBoundingClientRect();for(let y=1;y<16;y++)for(let x=1;x<16;x++){const px=r.left+r.width*x/16,py=r.top+r.height*y/16;if(n.contains(document.elementFromPoint(px,py)))return {x:px,y:py};}return null})()`);
  await drag(unavailableStart,{x:unavailableStart.x+50,y:unavailableStart.y+20});
  assert(await evaluate('document.querySelector("#status").textContent.includes("Measure information unavailable")'));
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),0);
  await evaluate('window.unavailableMeasures.forEach(([n,measure])=>{if(n!==window.selectionStart)n.dataset.measure=measure})');
  // Keyboard creates a fresh selection; generation replacement clears it.
  await evaluate('window.selectionMeasure.find(n=>n.hasAttribute("data-measure")).focus({preventScroll:true})');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),1);
  const beforeSelectionRebuild=await evaluate('main.dataset.revision');
  await remote("luaeval('_G.lilyp_browser_rebuild()')");
  await wait(()=>evaluate(`main.dataset.revision!==${JSON.stringify(beforeSelectionRebuild)}`));
  assert(await evaluate('inspector.hidden && !main.querySelector("[data-musical-selection]")'));
  assert.equal(await readFile(source,'utf8'),selectionSource,'Selection changed score source');
  assert.deepEqual(await readFile(selectionMidiPath),selectionMidi,'Selection changed MIDI');
  // A delayed source response must keep the reader's disclosure and focus.
  await evaluate(`window.focusFetch=window.fetch;window.groupRequestWaiting=false;
    window.groupDetailsGate=new Promise(resolve=>window.releaseGroupDetails=resolve);
    window.fetch=async(input,options)=>{const response=await window.focusFetch(input,options);
      if(input==='inspect'){window.groupRequestWaiting=true;await window.groupDetailsGate;}return response;};
    [...main.querySelectorAll('[data-measure]')].at(-1).focus({preventScroll:true});`);
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  await wait(()=>evaluate('window.groupRequestWaiting'));
  await evaluate('document.querySelector(".group-note").open=true;document.querySelector(".group-note > summary").focus({preventScroll:true});window.releaseGroupDetails()');
  await wait(()=>evaluate('document.querySelector(".group-note pre")'));
  assert(await evaluate('document.querySelector(".group-note").open && document.activeElement===document.querySelector(".group-note > summary")'),'Source details arriving dropped disclosure state or keyboard focus');
  await evaluate('window.fetch=window.focusFetch');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  // Rendering must consume its supplied analysis, even when the notes could
  // produce a different result if the view tried to calculate it itself.
  assert(await evaluate(`(async()=>{
    const {renderGroup}=await import('./group.js');
    const surface=document.createElement('section');
    const notes=[...main.querySelectorAll('[data-measure]')].slice(0,3);
    const model={notes,analysis:{tag:'supported',candidates:[]},origins:new Map(),errors:new Map(),keyOf:n=>n.dataset.selectionIndex};
    const render=()=>renderGroup(surface,model,()=>({fields:[]}),()=>({}));
    render();
    if(!surface.textContent.includes('No complete chord matches.') || surface.querySelector('ul'))return false;
    model.analysis={tag:'supported',candidates:[{name:'Supplied chord result',matched:[0],missing:[],outside:[],complete:true}]};
    render();
    if(surface.querySelector('ul strong')?.textContent!=='Supplied chord result')return false;
    model.analysis={tag:'unsupported'};render();
    return surface.textContent.includes('Chord suggestions require twelve-tone pitches.') && !surface.querySelector('ul');
  })()`),'Group rendering recalculated or ignored its supplied analysis result');
  // Compiler pitches remain usable when a note's source reader is unsupported.
  await evaluate(`window.groupFetch=window.fetch;window.fetch=async(input,options)=>{
    const response=await window.groupFetch(input,options);
    if(input==='inspect'){const data=await response.json();data.origin.inspection={tag:'unsupported'};return new Response(JSON.stringify(data),{status:response.status,headers:{'Content-Type':'application/json'}})}return response};
    main.querySelector('[data-measure]').focus({preventScroll:true});`);
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  await wait(()=>evaluate('document.querySelector(".group-note pre") && document.querySelector(".group-note summary").textContent.includes("details unavailable")'));
  assert.equal(await evaluate('main.querySelectorAll("[data-musical-selection]").length'),1,'Unavailable source details discarded a selected note');
  await evaluate('window.fetch=window.groupFetch');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await evaluate('window.microtoneTarget=main.querySelector("[data-measure]");window.originalGroupPitch=window.microtoneTarget.dataset.pitch;window.microtoneTarget.dataset.pitch="121/2";window.microtoneTarget.focus({preventScroll:true})');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  assert(await evaluate('document.querySelector("#group-content").textContent.includes("Chord suggestions require twelve-tone pitches.")'),'Selection analysis did not produce an explicit unsupported result');
  await evaluate('window.microtoneTarget.dataset.pitch=window.originalGroupPitch');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await evaluate('document.querySelector("#show-details").click()');
  assert(await evaluate('document.querySelector("#group-content").textContent.includes("Chord suggestions require twelve-tone pitches.")'),'Reopening the card recalculated the retained analysis');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await evaluate('window.microtoneTarget.focus({preventScroll:true})');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32,text:' '});
  assert(!await evaluate('document.querySelector("#group-content").textContent.includes("Chord suggestions require twelve-tone pitches.")'),'A new selection retained obsolete analysis');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  console.log('PASS: margin-start and reverse dragging, fixed measure acquisition, empty marquee, cross-staff single-measure drag, chord members, grouped source details and delayed-response focus retention, retained analysis-action results, selected-note chord suggestions, keyboard toggle, card/selection dismissal and selected-area reopening, unavailable measure metadata, rebuild invalidation and unchanged editor/source/MIDI');
  console.log('Group screenshot: '+join(folder,'group-selection.png'));
  const staticUrl=await remote("luaeval('_G.lilyp_browser_static_preview()')");
  await call('Page.navigate',{url:staticUrl});
  await wait(()=>evaluate('document.querySelectorAll("main > svg").length === 1'));
  await checkFonts('static preview');

} finally {
  websocket?.close();
  if (chrome) { const closed = new Promise(accept => chrome.on('exit', accept)); chrome.kill(); await closed; }
  if (ready && host.exitCode === null) await remote("luaeval('_G.lilyp_browser_stop()')");
  if (host.exitCode === null) {
    const closed = new Promise(accept => host.on('exit',accept));
    setTimeout(() => {if (host.exitCode === null) host.kill();},1000).unref();
    await closed;
  }
}
