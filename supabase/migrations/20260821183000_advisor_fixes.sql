-- Trigger functions are internal only and must not be callable through the Data API.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.log_offer_insert() from public, anon, authenticated;
revoke execute on function public.log_offer_status_update() from public, anon, authenticated;
revoke execute on function public.log_profile_insert() from public, anon, authenticated;
revoke execute on function public.log_profile_status_update() from public, anon, authenticated;
revoke execute on function public.log_request_insert() from public, anon, authenticated;
revoke execute on function public.log_request_status_update() from public, anon, authenticated;
revoke execute on function public.mark_request_has_offers() from public, anon, authenticated;
revoke execute on function public.accept_offer(uuid) from public, anon, authenticated;

create index if not exists activity_log_offer_idx on public.activity_log(offer_id);
create index if not exists activity_log_request_idx on public.activity_log(request_id);
create index if not exists activity_log_user_idx on public.activity_log(user_id);
create index if not exists job_requests_client_idx on public.job_requests(client_id);
create index if not exists notifications_user_idx on public.notifications(user_id);
create index if not exists offers_pro_idx on public.offers(pro_id);
create index if not exists payment_events_payment_idx on public.payment_events(payment_id);
create index if not exists payments_client_idx on public.payments(client_id);
create index if not exists payments_pro_idx on public.payments(pro_id);
create index if not exists payments_request_idx on public.payments(request_id);
create index if not exists pro_documents_reviewed_by_idx on public.pro_documents(reviewed_by);
create index if not exists pro_profiles_vat_checked_by_idx on public.pro_profiles(vat_checked_by);
create index if not exists pro_profiles_reviewed_by_idx on public.pro_profiles(verification_reviewed_by);
