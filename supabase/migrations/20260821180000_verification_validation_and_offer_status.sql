create or replace function public.is_valid_it_vat(p_vat text)
returns boolean language plpgsql immutable set search_path=public
as $$
declare v text:=regexp_replace(coalesce(p_vat,''),'[^0-9]','','g'); s integer:=0; d integer;
begin
  if v !~ '^[0-9]{11}$' then return false; end if;
  for i in 1..11 loop
    d:=substring(v from i for 1)::integer;
    if mod(i,2)=0 then d:=d*2; if d>9 then d:=d-9; end if; end if;
    s:=s+d;
  end loop;
  return mod(s,10)=0;
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
  if not public.is_valid_it_vat(v_vat) then raise exception 'partita IVA formalmente non valida'; end if;
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

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.profiles (id,full_name,phone,address,pro_status)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),nullif(new.raw_user_meta_data->>'phone',''),
    nullif(new.raw_user_meta_data->>'address',''),case when new.raw_user_meta_data->>'signup_kind'='professionista' then 'pending'::public.pro_status else 'none'::public.pro_status end);
  if new.raw_user_meta_data->>'signup_kind'='professionista' then
    insert into public.pro_profiles(
      user_id,business_name,vat_number,tax_code,business_address,pec,rea_number,categories,service_areas,vat_check_status
    ) values(
      new.id,nullif(new.raw_user_meta_data->>'business_name',''),nullif(new.raw_user_meta_data->>'vat_number',''),
      nullif(new.raw_user_meta_data->>'tax_code',''),nullif(new.raw_user_meta_data->>'business_address',''),
      nullif(new.raw_user_meta_data->>'pec',''),nullif(new.raw_user_meta_data->>'rea_number',''),
      case when jsonb_typeof(new.raw_user_meta_data->'categories')='array' then array(select jsonb_array_elements_text(new.raw_user_meta_data->'categories')) else '{}'::text[] end,
      case when jsonb_typeof(new.raw_user_meta_data->'service_areas')='array' then array(select jsonb_array_elements_text(new.raw_user_meta_data->'service_areas')) else '{}'::text[] end,
      'pending'
    );
  end if;
  return new;
end $$;

create or replace function public.mark_request_has_offers()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  update public.job_requests set status='offers_received',updated_at=now()
  where id=new.request_id and status='open';
  return new;
end $$;

drop trigger if exists trg_mark_request_has_offers on public.offers;
create trigger trg_mark_request_has_offers after insert on public.offers
for each row execute function public.mark_request_has_offers();

revoke execute on function public.is_valid_it_vat(text) from public, anon;
grant execute on function public.is_valid_it_vat(text) to authenticated;
revoke execute on function public.mark_request_has_offers() from public, anon, authenticated;
