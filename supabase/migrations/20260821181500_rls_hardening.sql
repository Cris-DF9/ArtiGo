create unique index if not exists offers_one_active_per_pro_request
  on public.offers(request_id,pro_id) where status in ('pending','accepted');
create unique index if not exists pro_documents_one_active_per_type
  on public.pro_documents(pro_id,document_type) where status in ('pending','approved');

drop policy if exists client_requests_all_own on public.job_requests;
drop policy if exists admin_requests_read_all on public.job_requests;
drop policy if exists approved_pro_read_open_requests on public.job_requests;
create policy client_requests_read_own on public.job_requests for select to authenticated
  using ((select auth.uid())=client_id);
create policy client_requests_insert_own on public.job_requests for insert to authenticated
  with check ((select auth.uid())=client_id and status='open');
create policy client_requests_delete_own_open on public.job_requests for delete to authenticated
  using ((select auth.uid())=client_id and status='open');
create policy admin_requests_read_all on public.job_requests for select to authenticated
  using (public.is_admin());
create policy approved_pro_read_open_requests on public.job_requests for select to authenticated
  using (
    status in ('open','offers_received')
    and exists(
      select 1 from public.profiles p join public.pro_profiles pp on pp.user_id=p.id
      where p.id=(select auth.uid()) and p.pro_status='approved' and category=any(pp.categories)
    )
  );

drop policy if exists admin_offers_read_all on public.offers;
drop policy if exists client_read_request_offers on public.offers;
drop policy if exists client_update_offer_on_own_request on public.offers;
drop policy if exists pro_read_own_offers on public.offers;
drop policy if exists pro_insert_own_offers on public.offers;
create policy admin_offers_read_all on public.offers for select to authenticated using (public.is_admin());
create policy client_read_request_offers on public.offers for select to authenticated
  using (exists(select 1 from public.job_requests r where r.id=offers.request_id and r.client_id=(select auth.uid())));
create policy pro_read_own_offers on public.offers for select to authenticated
  using ((select auth.uid())=pro_id);
create policy pro_insert_own_offers on public.offers for insert to authenticated
  with check (
    (select auth.uid())=pro_id
    and exists(
      select 1 from public.profiles p
      join public.pro_profiles pp on pp.user_id=p.id
      join public.job_requests r on r.id=offers.request_id
      where p.id=(select auth.uid()) and p.pro_status='approved'
        and r.status in ('open','offers_received') and r.category=any(pp.categories)
    )
  );

drop policy if exists admin_notifications_read_all on public.notifications;
drop policy if exists notifications_own on public.notifications;
drop policy if exists notifications_update_own on public.notifications;
create policy admin_notifications_read_all on public.notifications for select to authenticated using (public.is_admin());
create policy notifications_own on public.notifications for select to authenticated using ((select auth.uid())=user_id);
create policy notifications_update_own on public.notifications for update to authenticated
  using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);

drop policy if exists admin_activity_read on public.activity_log;
create policy admin_activity_read on public.activity_log for select to authenticated using (public.is_admin());

drop policy if exists pro_docs_delete_own on storage.objects;
create policy pro_docs_delete_own on storage.objects for delete to authenticated
  using (
    bucket_id='pro-verification'
    and (storage.foldername(name))[1]=(select auth.uid())::text
    and exists(
      select 1 from public.pro_documents d
      where d.pro_id=(select auth.uid()) and d.storage_path=name and d.status in ('pending','rejected')
    )
  );
