-- PROPOSAL ONLY. Target: fruzlkaqrogdfmzpwbft (DEFIMEL), NOT the Faberio DB.
-- Apply only after staging tests and fresh schema/data preflight. No data cleanup.
begin;
set local lock_timeout = '5s';
alter table public.delivery_notes add column save_payload jsonb;
-- Fails safely if existing duplicates appeared since the audit; never removes them.
create unique index delivery_notes_number_unique
  on public.delivery_notes (lower(btrim(document_number)))
  where nullif(btrim(document_number), '') is not null;

create function public.defimel_save_delivery(p_id uuid, p_document jsonb, p_items jsonb, p_recover boolean default false)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  d public.delivery_notes%rowtype;
  payload jsonb := jsonb_build_object('document', p_document, 'items', p_items);
  constraint_name text;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active) then
    raise exception 'Account non abilitato' using errcode='42501';
  end if;
  if p_id is null or nullif(btrim(p_document->>'document_number'),'') is null then
    raise exception 'Inserisci il numero della bolla.';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Materiali non validi'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Materiali obbligatori'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x where
    nullif(btrim(x->>'name'),'') is null or (x->>'qty')::numeric is null or
    (x->>'qty')::numeric <= 0 or (x->>'qty') in ('NaN','Infinity','-Infinity')) then
    raise exception 'Controlla descrizione e quantità di tutte le righe';
  end if;
  -- Same operation is serialized, including retries after a lost HTTP response.
  perform pg_advisory_xact_lock(hashtextextended(p_id::text, 0));
  select * into d from public.delivery_notes where id=p_id;
  if found then
    if d.save_payload is not null then
      if (d.uploaded_by<>auth.uid() and not (p_recover and app_private.is_admin())) or d.save_payload<>payload then
        raise exception 'Operazione già utilizzata con dati diversi';
      end if;
      return d.id;
    end if;
    if not p_recover or not app_private.is_admin() then raise exception 'Bolla già inserita'; end if;
    select * into d from public.delivery_notes where id=p_id for update;
    if not found or d.save_payload is not null or d.status<>'pending_review'
      or exists(select 1 from public.delivery_note_items where delivery_note_id=d.id) then
      raise exception 'Bolla già inserita';
    end if;
    -- Historical recovery adds ONLY rows. Original document/photo remain unchanged.
    if d.job_id is distinct from (p_document->>'job_id')::uuid
      or d.document_number is distinct from p_document->>'document_number'
      or d.document_date is distinct from (p_document->>'document_date')::date
      or d.supplier is distinct from p_document->>'supplier'
      or d.photo_path is distinct from p_document->>'photo_path' then
      raise exception 'I dati della bolla da recuperare sono cambiati. Riapri la bolla.';
    end if;
    update public.delivery_notes set save_payload=payload where id=d.id;
  else
    if p_recover then raise exception 'Bolla da recuperare non disponibile'; end if;
    if not exists(select 1 from storage.objects where bucket_id='defimel-files'
      and name=p_document->>'photo_path' and owner_id=auth.uid()::text) then
      raise exception 'Fotografia non disponibile: ripeti il caricamento';
    end if;
    insert into public.delivery_notes(id,job_id,uploaded_by,supplier,document_number,document_date,photo_path,raw_ocr_text,status,save_payload)
    values(p_id,(p_document->>'job_id')::uuid,auth.uid(),coalesce(p_document->>'supplier',''),
      btrim(p_document->>'document_number'),(p_document->>'document_date')::date,
      p_document->>'photo_path',coalesce(p_document->>'raw_ocr_text',''),'pending_review',payload);
  end if;
  insert into public.delivery_note_items(delivery_note_id,code,name,qty,unit,unit_price,price_basis,line_total)
  select p_id,coalesce(x->>'code',''),btrim(x->>'name'),(x->>'qty')::numeric,
    coalesce(nullif(x->>'unit',''),'pz'),(x->>'unit_price')::numeric,x->>'price_basis',(x->>'line_total')::numeric
  from jsonb_array_elements(p_items) x;
  return p_id;
exception when unique_violation then
  get stacked diagnostics constraint_name = CONSTRAINT_NAME;
  if constraint_name='delivery_notes_number_unique' then
    raise exception 'Bolla già inserita' using errcode='23505';
  end if;
  raise;
end $$;
revoke all on function public.defimel_save_delivery(uuid,jsonb,jsonb,boolean) from public, anon;
grant execute on function public.defimel_save_delivery(uuid,jsonb,jsonb,boolean) to authenticated;

-- An old cached client cannot create a header-only document anymore.
create function app_private.defimel_require_delivery_items()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if exists(select 1 from public.delivery_notes where id=new.id) and
     not exists(select 1 from public.delivery_note_items where delivery_note_id=new.id) then
    raise exception 'Salvataggio incompleto: aggiorna la pagina e riprova.';
  end if;
  return null;
end $$;
revoke all on function app_private.defimel_require_delivery_items() from public, anon;
create constraint trigger defimel_delivery_complete after insert on public.delivery_notes
  deferrable initially deferred for each row execute function app_private.defimel_require_delivery_items();

create function public.defimel_confirm_delivery(p_id uuid)
returns uuid language plpgsql security invoker set search_path='' as $$
declare d public.delivery_notes%rowtype; x record; material_id uuid;
begin
  if not app_private.is_admin() then raise exception 'Operazione riservata all’amministratore' using errcode='42501'; end if;
  select * into d from public.delivery_notes where id=p_id for update;
  if not found then raise exception 'Bolla non disponibile'; end if;
  if d.status='confirmed' then return d.id; end if;
  if d.status<>'pending_review' then raise exception 'Stato bolla non valido'; end if;
  if not exists(select 1 from public.delivery_note_items where delivery_note_id=d.id) then
    raise exception 'Bolla senza materiali: recuperala prima della conferma';
  end if;
  -- Two documents for one job must not consume the same requested material.
  perform pg_advisory_xact_lock(hashtextextended(d.job_id::text, 1));
  for x in select * from public.delivery_note_items where delivery_note_id=d.id order by id for update loop
    select id into material_id from public.material_requests
      where job_id=d.job_id and status in ('requested','ordered')
      and lower(btrim(name))=lower(btrim(x.name)) and lower(btrim(unit))=lower(btrim(x.unit))
      order by created_at,id limit 1 for update;
    if found then
      update public.material_requests set status='received',received_at=now(),supplier=d.supplier where id=material_id;
    else
      insert into public.material_requests(job_id,requested_by,name,qty,unit,status,received_at,supplier,note)
      values(d.job_id,auth.uid(),x.name,x.qty,x.unit,'received',now(),d.supplier,'Bolla '||d.document_number)
      returning id into material_id;
    end if;
    update public.delivery_note_items set linked_material_request_id=material_id where id=x.id;
  end loop;
  update public.delivery_notes set status='confirmed',confirmed_by=auth.uid(),confirmed_at=now() where id=d.id;
  return d.id;
end $$;
revoke all on function public.defimel_confirm_delivery(uuid) from public, anon;
grant execute on function public.defimel_confirm_delivery(uuid) to authenticated;
commit;
