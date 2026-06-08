-- 이미지 업로드용 공개 버킷. 경로 규약: <uid>/<category>/<filename>
insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

-- 공개 읽기
create policy "media public read"
  on storage.objects for select
  using (bucket_id = 'media');

-- 본인 폴더(<uid>/...)에만 업로드/수정/삭제 (authenticated, JWT sub = 폴더명)
create policy "media owner insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = app.uid()::text);

create policy "media owner update"
  on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = app.uid()::text);

create policy "media owner delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = app.uid()::text);
