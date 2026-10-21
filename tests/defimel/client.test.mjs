import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {JSDOM} from 'jsdom';
const files=['defimel.html','defimel-prova.html','defimel-cantieri/index.html'];
function setup(file){
 const html=readFileSync(new URL('../../'+file,import.meta.url),'utf8');
 const source=html.slice(html.indexOf('// Atomic DDT operations.'),html.indexOf('async function deleteDelivery('));
 const dom=new JSDOM('<div class="modal" id="modal"></div>',{url:'https://example.invalid'});
 const w=dom.window;let uploads=0,calls=0,failUpload=false,reply={data:null,error:null},refreshed=0;
 const ctx=vm.createContext({document:w.document,localStorage:w.localStorage,crypto:globalThis.crypto,
  S:{profile:{id:'user1',role:'worker'},jobs:[{id:'job',name:'Job',status:'active'}]},
  $:s=>w.document.querySelector(s),esc:x=>String(x),today:()=> '2026-10-21',
  openModal:html=>w.document.querySelector('#modal').innerHTML=html,closeModal:()=>{},
  showError:(el,s)=>el.textContent=s,alert:()=>{},confirm:()=>true,refresh:async()=>{refreshed++},
  sb:{from:()=>{throw Error('Non-atomic fallback forbidden')},storage:{from:()=>({upload:async()=>{uploads++;return {error:failUpload?Error('upload failed'):null}}})},rpc:async(name,op)=>{calls++;return reply.error?reply:{data:op.p_id,error:null}}}
 });
 vm.runInContext(source,ctx);
 const form=()=>{
  vm.runInContext('newDelivery()',ctx);
  Object.defineProperty(w.document.querySelector('#ddtPhoto'),'files',{value:[{name:'photo.jpg'}],configurable:true});
  w.document.querySelector('#ddtNumber').value='ABC';
  w.document.querySelector('#ocrRows').innerHTML='<div class="ocr-row"><input class="ocrName" value="Cavo"><input class="ocrQty" value="2"><input class="ocrUnit" value="m"><input class="ocrPrice" value="1.2"></div>';
  w.document.querySelector('#saveDdt').disabled=false;
 };
 return {ctx,w,form,save:()=>w.document.querySelector('#saveDdt').onclick(),
  setError:e=>reply={error:e},failUpload:()=>failUpload=true,counts:()=>({uploads,calls,refreshed}),
  pending:()=>vm.runInContext('readDeliveryOperation()',ctx)};
}
for(const file of files){
 test(file+': upload failure never creates a document',async()=>{const s=setup(file);s.form();s.failUpload();await s.save();assert.deepEqual(s.counts(),{uploads:1,calls:0,refreshed:0});assert.equal(s.pending(),null)});
 test(file+': lost response preserves operation and retries same id without uploading again',async()=>{
  const s=setup(file);s.form();s.setError({message:'Failed to fetch'});await s.save();const first=s.pending();assert.ok(first.p_id);
  s.setError(null);await s.save();assert.equal(s.pending(),null);assert.deepEqual(s.counts(),{uploads:1,calls:2,refreshed:1});
 });
 test(file+': invalid rows are rejected rather than silently discarded',async()=>{
  const s=setup(file);s.form();s.w.document.querySelector('.ocrQty').value='0';await s.save();assert.equal(s.counts().uploads,0);
 });
 test(file+': database rollback allows corrected input; missing RPC has no unsafe fallback',async()=>{
  const s=setup(file);s.form();s.setError({code:'PGRST202',message:'missing'});await s.save();assert.equal(s.pending(),null);
  assert.match(s.w.document.querySelector('#ddtError').textContent,/non ancora attivato/);
  s.setError({code:'23505',message:'Bolla già inserita'});await s.save();assert.equal(s.pending(),null);
 });
 test(file+': per-operation journal survives reload, isolates accounts and other tabs',async()=>{
  const s=setup(file);const a={p_id:'a'},b={p_id:'b'};
  s.ctx.a=a;s.ctx.b=b;vm.runInContext('writeDeliveryOperation(a);writeDeliveryOperation(b)',s.ctx);
  await vm.runInContext('submitDeliveryOperation(a)',s.ctx);assert.equal(s.pending().p_id,'b');
  vm.runInContext("S.profile.id='different-user'",s.ctx);assert.equal(s.pending(),null);
  vm.runInContext("S.profile.id='user1'",s.ctx);assert.equal(s.pending().p_id,'b');
 });
}
