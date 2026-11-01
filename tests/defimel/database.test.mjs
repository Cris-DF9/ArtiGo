import { PGlite } from '@electric-sql/pglite';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
const schema=JSON.parse(readFileSync(new URL('./schema-snapshot.json',import.meta.url)));
const proposal=readFileSync(new URL('../../defimel-db/proposals/atomic-deliveries.sql',import.meta.url),'utf8');
const admin='00000000-0000-4000-8000-000000000001',worker='00000000-0000-4000-8000-000000000002',other='00000000-0000-4000-8000-000000000003',secretary='00000000-0000-4000-8000-000000000004',inactive='00000000-0000-4000-8000-000000000005',job='00000000-0000-4000-8000-000000000010';
let serial=100;const id=()=>`00000000-0000-4000-8000-${String(serial++).padStart(12,'0')}`;
async function fixture(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create schema auth;create schema app_private;create schema storage;
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create table public.jobs(id uuid primary key,status text,created_by uuid);create table public.assignments(job_id uuid,worker_id uuid);
 create table storage.objects(bucket_id text,name text,owner_id text);
 grant usage on schema public,auth,app_private,storage to authenticated;
 grant select on storage.objects to authenticated;`);
 for(const t of schema.tables)await db.exec(`create table public.${t.table_name}(${t.columns});`);
 await db.exec('alter table public.profiles add primary key(id)');
 for(const c of schema.constraints)await db.exec(`alter table public.${c.tbl} add constraint ${c.conname} ${c.def};`);
 for(const h of schema.helpers)await db.exec(h);
 for(const t of schema.tables)await db.exec(`alter table public.${t.table_name} enable row level security`);
 for(const p of schema.policies)await db.exec(`create policy ${p.policyname} on public.${p.tablename} for ${p.cmd} to authenticated ${p.qual?'using ('+p.qual+')':''} ${p.with_check?'with check ('+p.with_check+')':''}`);
 for(const g of schema.grants)await db.exec(`grant ${g.privilege_type} on public.${g.table_name} to authenticated`);
 await db.exec(`insert into public.profiles(id,email,role,active) values('${admin}','admin@example.invalid','admin',true),('${worker}','worker@example.invalid','worker',true),('${other}','other@example.invalid','worker',true),('${secretary}','secretary@example.invalid','secretary',true),('${inactive}','inactive@example.invalid','worker',false);
 insert into public.jobs values('${job}','active','${admin}');
 insert into storage.objects values('defimel-files','${worker}/photo.jpg','${worker}'),('defimel-files','${other}/photo.jpg','${other}'),('defimel-files','${secretary}/photo.jpg','${secretary}');`);
 return db;
}
async function as(db,user){await db.exec(`reset role;set request.jwt.claim.sub='${user}';set role authenticated;`)}
const doc=(number,user=worker)=>({job_id:job,supplier:'Test',document_number:number,document_date:'2026-10-21',photo_path:`${user}/photo.jpg`,raw_ocr_text:'test'});
const items=[{code:'X',name:'Cavo',qty:2,unit:'m',unit_price:1.2,price_basis:'',line_total:2.4}];
const save=(db,uuid,d,rows=items,recover=false)=>db.query('select public.defimel_save_delivery($1,$2,$3,$4) as id',[uuid,d,rows,recover]);
const count=async(db,table)=>Number((await db.query(`select count(*) as n from public.${table}`)).rows[0].n);

test('atomic DDT integration against production schema/policies snapshot',async t=>{
 const db=await fixture();
 // Legacy rows must survive proposal, even empty rows. No retroactive cleanup.
 const legacy=id();await db.query(`insert into delivery_notes(id,job_id,uploaded_by,document_number,document_date,supplier,photo_path) values($1,$2,$3,'OLD','2026-10-21','Test',$4)`,[legacy,job,worker,`${worker}/photo.jpg`]);
 await db.exec(proposal);
 await as(db,worker);
 await t.test('success and identical retry commit exactly once',async()=>{
  const uuid=id();await save(db,uuid,doc('A'));await save(db,uuid,doc('A'));
  assert.equal(await count(db,'delivery_notes'),2);assert.equal(await count(db,'delivery_note_items'),1);
  await assert.rejects(save(db,uuid,doc('B')),/dati diversi/);
 });
 await t.test('item failure rolls back header; same id can be retried',async()=>{
  const uuid=id();await assert.rejects(save(db,uuid,doc('FAIL'),[{...items[0],unit_price:'bad'}]),/numeric/);
  assert.equal((await db.query('select id from delivery_notes where id=$1',[uuid])).rows.length,0);
  await save(db,uuid,doc('FAIL'));assert.equal(await count(db,'delivery_note_items'),2);
 });
 await t.test('duplicate number is global, trimmed, case insensitive, literal',async()=>{
  await as(db,other);await assert.rejects(save(db,id(),doc(' a ',other)),/Bolla già inserita/);
  await save(db,id(),doc('A_%',other));await save(db,id(),doc('A_X',other));await as(db,worker);
 });
 await t.test('empty rows, absent photo and inactive account are rejected',async()=>{
  await assert.rejects(save(db,id(),doc('EMPTY'),[]),/obbligatori/);
  await assert.rejects(save(db,id(),{...doc('PHOTO'),photo_path:'missing'}),/Fotografia/);
  await as(db,inactive);await assert.rejects(save(db,id(),doc('INACTIVE')),/Account/);await as(db,worker);
 });
 await t.test('legacy cached two-step save cannot leave a header',async()=>{
  await assert.rejects(db.query(`insert into delivery_notes(job_id,uploaded_by,document_number) values($1,$2,'CACHED')`,[job,worker]),/Salvataggio incompleto/);
  assert.equal((await db.query("select id from delivery_notes where document_number='CACHED'")).rows.length,0);
 });
 await t.test('historical recovery requires admin, empty pending row and matching metadata',async()=>{
  await assert.rejects(save(db,legacy,doc('OLD'),items,true),/Bolla già inserita/);
  await as(db,admin);await assert.rejects(save(db,legacy,doc('CHANGED'),items,true),/cambiati/);
  await save(db,legacy,doc('OLD'),items,true);await save(db,legacy,doc('OLD'),items,true);
  const d=(await db.query('select * from delivery_notes where id=$1',[legacy])).rows[0];
  assert.equal(d.uploaded_by,worker);assert.equal(d.photo_path,`${worker}/photo.jpg`);
  await assert.rejects(save(db,legacy,doc('OLD'),[{...items[0],qty:5}],true),/dati diversi/);
 });
 await t.test('confirmation rolls back material writes on failure and retries once',async()=>{
  await db.exec('reset role');await db.exec(`create function public.test_fail() returns trigger language plpgsql as $$begin raise exception 'injected failure';end$$;
  create trigger fail_confirmation before update on delivery_notes for each row when(new.status='confirmed') execute function public.test_fail();`);
  await as(db,admin);await assert.rejects(db.query('select defimel_confirm_delivery($1)',[legacy]),/injected failure/);
  assert.equal(await count(db,'material_requests'),0);
  await db.exec('reset role;drop trigger fail_confirmation on delivery_notes');await as(db,admin);
  await db.query('select defimel_confirm_delivery($1)',[legacy]);await db.query('select defimel_confirm_delivery($1)',[legacy]);
  assert.equal(await count(db,'material_requests'),1);
  await as(db,worker);await assert.rejects(db.query('select defimel_confirm_delivery($1)',[legacy]),/amministratore/);
  await save(db,legacy,doc('OLD')); // Retry remains safe even after admin confirmation.
 });
 await t.test('secretary can save; foreign id replay and anonymous RPC are rejected',async()=>{
  await as(db,secretary);await save(db,id(),doc('SECRETARY',secretary));
  await as(db,other);await assert.rejects(save(db,legacy,doc('OLD',other)),/duplicate key|Bolla già inserita/);
  await db.exec('reset role;set role anon');await assert.rejects(save(db,id(),doc('ANON')),/permission denied/);
 });
 await db.close();
});

test('proposal fails on pre-existing duplicates without deleting either row',async()=>{
 const db=await fixture();await db.query(`insert into delivery_notes(job_id,uploaded_by,document_number) values($1,$2,'DUP'),($1,$2,' dup ')`,[job,worker]);
 await assert.rejects(db.exec(proposal),/unique index/);await db.exec('rollback');
 assert.equal(await count(db,'delivery_notes'),2);
 assert.equal((await db.query("select column_name from information_schema.columns where table_name='delivery_notes' and column_name='save_payload'")).rows.length,0);
 await db.close();
});
