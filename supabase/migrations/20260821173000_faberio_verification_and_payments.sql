-- Faberio: onboarding professionisti, verifica documentale e pagamenti marketplace.
-- I pagamenti restano inattivi finche Stripe non e configurato con credenziali test/live.

alter table public.pro_profiles
  add column if not exists business_address text,
  add column if not exists pec text,
  add column if not exists rea_number text,
  add column if not exists vat_check_status text not null default 'unchecked',
  add column if not exists vat_checked_at timestamptz,
  add column if not exists vat_checked_by uuid references public.profiles(id),
  add column if not exists verification_submitted_at timestamptz,
  add column if not exists verification_reviewed_at timestamptz,
  add column if not exists verification_reviewed_by uuid references public.profiles(id),
  add column if not exists verification_notes text,
  add column if not exists stripe_account_id text,
  add column if not exists stripe_onboarding_complete boolean not null default false,
  add column if not exists stripe_charges_enabled boolean not null default false,
  add column if not exists stripe_payouts_enabled boolean not null default false,
  add column if not exists stripe_details_submitted boolean not null default false;

alter table public.pro_profiles drop constraint if exists pro_profiles_vat_check_status_check;
alter table public.pro_profiles add constraint pro_profiles_vat_check_status_check
  check (vat_check_status in ('unchecked','pending','verified','invalid'));
create unique index if not exists pro_profiles_stripe_account_uidx
  on public.pro_profiles(stripe_account_id) where stripe_account_id is not null;

alter table public.pro_documents
  add column if not exists display_name text,
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint,
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references public.profiles(id),
  add column if not exists review_notes text;

alter table public.pro_documents drop constraint if exists pro_documents_document_type_check;
alter table public.pro_documents add constraint pro_documents_document_type_check check (
  document_type in ('visura_camerale','documento_identita','assicurazione_rc','durc','abilitazione_dm_37_08','altra_abilitazione')
);
alter table public.pro_documents drop constraint if exists pro_documents_status_check;
alter table public.pro_documents add constraint pro_documents_status_check
  check (status in ('pending','approved','rejected'));
alter table public.pro_documents drop constraint if exists pro_documents_size_check;
alter table public.pro_documents add constraint pro_documents_size_check
  check (size_bytes is null or (size_bytes > 0 and size_bytes <= 8388608));

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.job_requests(id),
  offer_id uuid not null references public.offers(id),
  client_id uuid not null references public.profiles(id),
  pro_id uuid not null references public.profiles(id),
  currency text not null default 'eur' check (currency = 'eur'),
  amount_pro numeric(12,2) not null check (amount_pro > 0),
  platform_fee_rate numeric(6,5) not null default 0.10 check (platform_fee_rate >= 0 and platform_fee_rate <= 1),
  platform_fee numeric(12,2) not null check (platform_fee >= 0),
  total_amount numeric(12,2) not null check (total_amount > 0),
  status text not null default 'pending' check (status in (
    'pending','checkout_created','paid','transfer_pending','transferred','refunded','partially_refunded','failed','cancelled','disputed'
  )),
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  stripe_charge_id text,
  stripe_transfer_id text,
  stripe_refund_id text,
  idempotency_key uuid not null default gen_random_uuid(),
  paid_at timestamptz,
  transferred_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (offer_id),
  unique (idempotency_key),
  unique (stripe_checkout_session_id),
  unique (stripe_payment_intent_id)
);

create table if not exists public.payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid references public.payments(id) on delete set null,
  provider_event_id text not null unique,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.payments enable row level security;
alter table public.payment_events enable row level security;

-- Bucket privato: i documenti non devono mai essere pubblicamente accessibili.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('pro-verification','pro-verification',false,8388608,array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Corregge l'helper amministratore: l'argomento non puo essere usato per testare un altro utente.
create or replace function public.is_admin(uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin') $$;

revoke execute on function public.is_admin(uuid) from public, anon;
grant execute on function public.is_admin(uuid) to authenticated;

-- Rimuove policy permissive precedenti e impedisce l'auto-promozione di ruolo/stato.
drop policy if exists profiles_read_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists admin_profiles_read_all on public.profiles;
drop policy if exists admin_profiles_update_all on public.profiles;
create policy profiles_read_own on public.profiles for select to authenticated
  using ((select auth.uid())=id);
create policy admin_profiles_read_all on public.profiles for select to authenticated
  using (public.is_admin());

drop policy if exists pro_profile_insert_own on public.pro_profiles;
drop policy if exists pro_profile_read_own on public.pro_profiles;
drop policy if exists pro_profile_update_own on public.pro_profiles;
drop policy if exists admin_pro_profiles_read_all on public.pro_profiles;
create policy pro_profile_read_own on public.pro_profiles for select to authenticated
  using ((select auth.uid())=user_id);
create policy admin_pro_profiles_read_all on public.pro_profiles for select to authenticated
  using (public.is_admin());

drop policy if exists documents_insert_own on public.pro_documents;
drop policy if exists documents_own on public.pro_documents;
drop policy if exists admin_documents_read_all on public.pro_documents;
create policy documents_read_own on public.pro_documents for select to authenticated
  using ((select auth.uid())=pro_id);
create policy documents_insert_own on public.pro_documents for insert to authenticated
  with check ((select auth.uid())=pro_id and status='pending');
create policy documents_delete_pending_own on public.pro_documents for delete to authenticated
  using ((select auth.uid())=pro_id and status='pending');
create policy admin_documents_read_all on public.pro_documents for select to authenticated
  using (public.is_admin());

drop policy if exists pro_docs_upload_own on storage.objects;
drop policy if exists pro_docs_read_own on storage.objects;
drop policy if exists pro_docs_delete_own on storage.objects;
drop policy if exists admin_pro_docs_read_all on storage.objects;
create policy pro_docs_upload_own on storage.objects for insert to authenticated
  with check (bucket_id='pro-verification' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy pro_docs_read_own on storage.objects for select to authenticated
  using (bucket_id='pro-verification' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy pro_docs_delete_own on storage.objects for delete to authenticated
  using (bucket_id='pro-verification' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy admin_pro_docs_read_all on storage.objects for select to authenticated
  using (bucket_id='pro-verification' and public.is_admin());

drop policy if exists payments_client_read on public.payments;
drop policy if exists payments_pro_read on public.payments;
drop policy if exists payments_admin_read on public.payments;
create policy payments_client_read on public.payments for select to authenticated
  using ((select auth.uid())=client_id);
create policy payments_pro_read on public.payments for select to authenticated
  using ((select auth.uid())=pro_id);
create policy payments_admin_read on public.payments for select to authenticated
  using (public.is_admin());
create policy payment_events_admin_read on public.payment_events for select to authenticated
  using (public.is_admin());

-- Correzione delle policy esistenti: ruoli espliciti e controlli di proprieta completi.
drop policy if exists approved_pro_read_open_requests on public.job_requests;
create policy approved_pro_read_open_requests on public.job_requests for select to authenticated
  using (exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.pro_status='approved'));

drop policy if exists pro_manage_own_offers on public.offers;
create policy pro_read_own_offers on public.offers for select to authenticated
  using ((select auth.uid())=pro_id);
create policy pro_insert_own_offers on public.offers for insert to authenticated
  with check (
    (select auth.uid())=pro_id
    and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.pro_status='approved')
  );

-- Aggiornamenti profilo consentiti solo sui campi anagrafici non privilegiati.
create or replace function public.update_my_profile(p_full_name text, p_phone text, p_address text)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  update public.profiles set
    full_name=nullif(trim(p_full_name),''), phone=nullif(trim(p_phone),''),
    address=nullif(trim(p_address),''), updated_at=now()
  where id=auth.uid();
end $$;

create or replace function public.submit_pro_verification(
  p_business_name text, p_vat_number text, p_tax_code text, p_business_address text,
  p_pec text, p_rea_number text, p_categories text[], p_service_areas text[]
) returns void language plpgsql security definer set search_path=public
as $$
declare v_vat text;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  v_vat := upper(regexp_replace(coalesce(p_vat_number,''),'[^A-Z0-9]','','g'));
  if v_vat ~ '^IT[0-9]{11}$' then v_vat:=substring(v_vat from 3); end if;
  if v_vat !~ '^[0-9]{11}$' then raise exception 'partita IVA non valida'; end if;
  if nullif(trim(p_business_name),'') is null or nullif(trim(p_business_address),'') is null
     or nullif(trim(p_pec),'') is null or coalesce(array_length(p_categories,1),0)=0
     or coalesce(array_length(p_service_areas,1),0)=0 then
    raise exception 'complete all required business data';
  end if;
  insert into public.pro_profiles(
    user_id,business_name,vat_number,tax_code,business_address,pec,rea_number,
    categories,service_areas,vat_check_status,verification_submitted_at,verification_notes,updated_at
  ) values (
    auth.uid(),trim(p_business_name),v_vat,nullif(upper(trim(p_tax_code)),''),trim(p_business_address),
    lower(trim(p_pec)),nullif(upper(trim(p_rea_number)),''),p_categories,p_service_areas,
    'pending',now(),null,now()
  ) on conflict(user_id) do update set
    business_name=excluded.business_name,vat_number=excluded.vat_number,tax_code=excluded.tax_code,
    business_address=excluded.business_address,pec=excluded.pec,rea_number=excluded.rea_number,
    categories=excluded.categories,service_areas=excluded.service_areas,
    vat_check_status=case when public.pro_profiles.vat_number is distinct from excluded.vat_number then 'pending' else public.pro_profiles.vat_check_status end,
    verification_submitted_at=now(),verification_notes=null,updated_at=now();
  update public.profiles set pro_status='pending', updated_at=now() where id=auth.uid() and role<>'admin';
end $$;

create or replace function public.admin_review_document(p_document_id uuid, p_status text, p_notes text default null)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('approved','rejected') then raise exception 'invalid status'; end if;
  update public.pro_documents set status=p_status,reviewed_at=now(),reviewed_by=auth.uid(),review_notes=nullif(trim(p_notes),'')
  where id=p_document_id;
  if not found then raise exception 'document not found'; end if;
end $$;

create or replace function public.admin_set_vat_check(p_user_id uuid, p_status text, p_notes text default null)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('verified','invalid') then raise exception 'invalid status'; end if;
  update public.pro_profiles set vat_check_status=p_status,vat_checked_at=now(),vat_checked_by=auth.uid(),
    verification_notes=coalesce(nullif(trim(p_notes),''),verification_notes),updated_at=now()
  where user_id=p_user_id;
  if not found then raise exception 'professional not found'; end if;
end $$;

create or replace function public.admin_decide_pro(p_user_id uuid, p_approve boolean, p_notes text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare v_categories text[]; v_missing text[];
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_approve then
    select categories into v_categories from public.pro_profiles where user_id=p_user_id and vat_check_status='verified';
    if v_categories is null then raise exception 'partita IVA non verificata'; end if;
    select array_agg(req.doc_type) into v_missing
    from (
      select unnest(array['visura_camerale','documento_identita','assicurazione_rc']) doc_type
      union
      select 'abilitazione_dm_37_08' where v_categories && array['Elettricista','Idraulico']
    ) req
    where not exists (
      select 1 from public.pro_documents d where d.pro_id=p_user_id and d.document_type=req.doc_type and d.status='approved'
    );
    if coalesce(array_length(v_missing,1),0)>0 then raise exception 'documenti mancanti o non approvati: %',array_to_string(v_missing,', '); end if;
    update public.profiles set pro_status='approved',role='pro',updated_at=now() where id=p_user_id;
  else
    update public.profiles set pro_status='pending',role=case when role='admin' then role else 'cliente'::public.user_role end,updated_at=now() where id=p_user_id;
  end if;
  update public.pro_profiles set verification_reviewed_at=now(),verification_reviewed_by=auth.uid(),
    verification_notes=nullif(trim(p_notes),''),updated_at=now() where user_id=p_user_id;
end $$;

-- Crea il riepilogo economico sul server: offerta + 10% a carico del cliente.
create or replace function public.prepare_payment(p_offer_id uuid)
returns table(payment_id uuid, amount_pro numeric, platform_fee numeric, total_amount numeric, currency text)
language plpgsql security definer set search_path=public
as $$
declare v_offer public.offers%rowtype; v_request public.job_requests%rowtype; v_pro public.pro_profiles%rowtype;
declare v_fee numeric(12,2); v_payment uuid;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  select * into v_offer from public.offers where id=p_offer_id and status='pending';
  if not found or v_offer.amount is null or v_offer.amount<=0 then raise exception 'offerta non disponibile'; end if;
  select * into v_request from public.job_requests where id=v_offer.request_id and client_id=auth.uid() and status in ('open','offers_received');
  if not found then raise exception 'request not available'; end if;
  select pp.* into v_pro from public.pro_profiles pp join public.profiles p on p.id=pp.user_id
  where pp.user_id=v_offer.pro_id and p.pro_status='approved' and pp.stripe_account_id is not null
    and pp.stripe_charges_enabled and pp.stripe_payouts_enabled;
  if not found then raise exception 'pagamenti del professionista non ancora attivi'; end if;
  v_fee:=round(v_offer.amount*0.10,2);
  insert into public.payments(request_id,offer_id,client_id,pro_id,amount_pro,platform_fee,total_amount)
  values(v_offer.request_id,v_offer.id,auth.uid(),v_offer.pro_id,v_offer.amount,v_fee,v_offer.amount+v_fee)
  on conflict(offer_id) do update set updated_at=now()
  returning id into v_payment;
  return query select p.id,p.amount_pro,p.platform_fee,p.total_amount,p.currency from public.payments p where p.id=v_payment;
end $$;

-- Funzioni privilegiate: nessuna esecuzione anonima o pubblica.
revoke execute on function public.update_my_profile(text,text,text) from public, anon;
revoke execute on function public.submit_pro_verification(text,text,text,text,text,text,text[],text[]) from public, anon;
revoke execute on function public.admin_review_document(uuid,text,text) from public, anon;
revoke execute on function public.admin_set_vat_check(uuid,text,text) from public, anon;
revoke execute on function public.admin_decide_pro(uuid,boolean,text) from public, anon;
revoke execute on function public.prepare_payment(uuid) from public, anon;
grant execute on function public.update_my_profile(text,text,text) to authenticated;
grant execute on function public.submit_pro_verification(text,text,text,text,text,text,text[],text[]) to authenticated;
grant execute on function public.admin_review_document(uuid,text,text) to authenticated;
grant execute on function public.admin_set_vat_check(uuid,text,text) to authenticated;
grant execute on function public.admin_decide_pro(uuid,boolean,text) to authenticated;
grant execute on function public.prepare_payment(uuid) to authenticated;

grant select on public.payments, public.payment_events to authenticated;
grant select,insert,delete on public.pro_documents to authenticated;
grant select on public.pro_profiles to authenticated;

-- Hardening delle funzioni gia presenti.
revoke execute on function public.accept_offer(uuid) from public, anon;
revoke execute on function public.get_accepted_job_contacts() from public, anon;
grant execute on function public.get_accepted_job_contacts() to authenticated;
-- accept_offer viene disabilitata: l'accettazione definitiva avviene solo dopo conferma Stripe.
