create or replace function public.finalize_stripe_payment(
  p_payment_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text
) returns void language plpgsql security definer set search_path=public
as $$
declare v_payment public.payments%rowtype;
begin
  select * into v_payment from public.payments where id=p_payment_id for update;
  if not found then raise exception 'payment not found'; end if;
  if v_payment.status in ('paid','transferred','refunded','partially_refunded') then return; end if;
  if v_payment.status not in ('pending','checkout_created') then raise exception 'invalid payment status'; end if;

  update public.payments set
    status='paid', stripe_checkout_session_id=coalesce(p_checkout_session_id,stripe_checkout_session_id),
    stripe_payment_intent_id=coalesce(p_payment_intent_id,stripe_payment_intent_id),
    paid_at=now(), updated_at=now()
  where id=p_payment_id;

  update public.offers set status=case when id=v_payment.offer_id then 'accepted'::public.offer_status else 'rejected'::public.offer_status end
  where request_id=v_payment.request_id;
  update public.job_requests set status='accepted',updated_at=now() where id=v_payment.request_id;
end $$;

revoke execute on function public.finalize_stripe_payment(uuid,text,text) from public, anon, authenticated;
grant execute on function public.finalize_stripe_payment(uuid,text,text) to service_role;
