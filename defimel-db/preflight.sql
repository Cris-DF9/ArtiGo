-- READ ONLY. Run on DEFIMEL fruzlkaqrogdfmzpwbft before any activation.
select version();
select table_name,column_name,udt_name,is_nullable,column_default
from information_schema.columns where table_schema='public'
and table_name in ('delivery_notes','delivery_note_items','material_requests','profiles')
order by table_name,ordinal_position;
select tablename,policyname,cmd,roles,qual,with_check from pg_policies
where schemaname in ('public','storage') and tablename in ('delivery_notes','delivery_note_items','material_requests','profiles','objects');
select indexname,indexdef from pg_indexes where schemaname='public' and tablename='delivery_notes';
select tgname,pg_get_triggerdef(oid) from pg_trigger
where tgrelid='public.delivery_notes'::regclass and not tgisinternal;
select lower(btrim(document_number)) as normalized_number,count(*) from public.delivery_notes
where nullif(btrim(document_number),'') is not null group by 1 having count(*)>1;
select d.id,d.status,d.document_number,count(i.id) as item_count
from public.delivery_notes d left join public.delivery_note_items i on i.delivery_note_id=d.id
group by d.id having count(i.id)=0;
select count(*) as notes from public.delivery_notes;
select count(*) as items from public.delivery_note_items;
select p.proname,p.prosecdef,pg_get_functiondef(p.oid) from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('defimel_save_delivery','defimel_confirm_delivery');
