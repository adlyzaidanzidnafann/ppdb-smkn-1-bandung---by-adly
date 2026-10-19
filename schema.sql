-- PPDB SMKN 1 Bandung — jalankan utuh di Supabase > SQL Editor

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'siswa' check (role in ('siswa','panitia')),
  nama text not null,
  created_at timestamptz default now()
);

create table jalur (
  id uuid primary key default gen_random_uuid(),
  nama text not null,
  kuota int not null default 0 check (kuota >= 0),
  persyaratan text[] not null default '{}',
  aktif boolean not null default true,
  buka timestamptz,
  tutup timestamptz
);

create table pendaftaran (
  id uuid primary key default gen_random_uuid(),
  siswa_id uuid not null unique references profiles(id) on delete cascade,
  jalur_id uuid not null references jalur(id),
  nama_lengkap text not null,
  nisn text not null check (nisn ~ '^[0-9]{10}$'),
  asal_sekolah text not null,
  tgl_lahir date not null,
  alamat text not null,
  no_hp text not null,
  status text not null default 'draft'
    check (status in ('draft','diajukan','revisi','terverifikasi','diterima','ditolak')),
  catatan_revisi text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table dokumen (
  id uuid primary key default gen_random_uuid(),
  pendaftaran_id uuid not null references pendaftaran(id) on delete cascade,
  jenis text not null,
  path text not null,
  created_at timestamptz default now(),
  unique (pendaftaran_id, jenis)
);

create table pengumuman (
  id uuid primary key default gen_random_uuid(),
  judul text not null,
  isi text not null,
  terbit boolean not null default false,
  created_at timestamptz default now()
);

create table notifikasi (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  pesan text not null,
  dibaca boolean not null default false,
  created_at timestamptz default now()
);

create or replace function is_panitia() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'panitia');
$$;

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, role, nama)
  values (new.id, 'siswa', coalesce(nullif(new.raw_user_meta_data->>'nama',''), new.email));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create or replace function guard_pendaftaran() returns trigger
language plpgsql security definer set search_path = public as $$
declare j jalur;
begin
  new.updated_at := now();
  if is_panitia() then
    if new.status = 'diterima' and old.status <> 'diterima' and
       (select count(*) from pendaftaran where jalur_id = new.jalur_id and status = 'diterima')
       >= (select kuota from jalur where id = new.jalur_id) then
      raise exception 'Kuota jalur sudah penuh';
    end if;
    return new;
  end if;
  new.siswa_id := old.siswa_id;
  new.catatan_revisi := old.catatan_revisi;
  if new.status <> old.status then
    if not (new.status = 'diajukan' and old.status in ('draft','revisi')) then
      raise exception 'Perubahan status tidak diizinkan';
    end if;
    select * into j from jalur where id = new.jalur_id;
    if not j.aktif or (j.buka is not null and now() < j.buka) or (j.tutup is not null and now() > j.tutup) then
      raise exception 'Jalur sedang tidak dibuka';
    end if;
    if (select count(distinct d.jenis) from dokumen d
        where d.pendaftaran_id = new.id and d.jenis = any(j.persyaratan))
       < coalesce(array_length(j.persyaratan,1),0) then
      raise exception 'Dokumen persyaratan belum lengkap';
    end if;
  end if;
  return new;
end $$;
create trigger trg_guard before update on pendaftaran
  for each row execute function guard_pendaftaran();

create or replace function notif_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> old.status then
    if new.status = 'diajukan' then
      insert into notifikasi(user_id, pesan)
        select id, 'Pendaftaran baru/ulang diajukan: ' || new.nama_lengkap from profiles where role = 'panitia';
    else
      insert into notifikasi(user_id, pesan) values (new.siswa_id,
        'Status pendaftaran Anda: ' || new.status ||
        case when new.status = 'revisi' then ' — lihat catatan revisi di dashboard' else '' end);
    end if;
  end if;
  return new;
end $$;
create trigger trg_notif after update on pendaftaran
  for each row execute function notif_status();

alter table profiles enable row level security;
alter table jalur enable row level security;
alter table pendaftaran enable row level security;
alter table dokumen enable row level security;
alter table pengumuman enable row level security;
alter table notifikasi enable row level security;

create policy p_sel on profiles for select using (id = auth.uid() or is_panitia());

create policy j_sel on jalur for select to authenticated using (true);
create policy j_all on jalur for all using (is_panitia()) with check (is_panitia());

create policy r_sel on pendaftaran for select using (siswa_id = auth.uid() or is_panitia());
create policy r_ins on pendaftaran for insert with check (siswa_id = auth.uid() and status = 'draft');
create policy r_upd_s on pendaftaran for update
  using (siswa_id = auth.uid() and status in ('draft','revisi')) with check (siswa_id = auth.uid());
create policy r_upd_p on pendaftaran for update using (is_panitia()) with check (is_panitia());

create policy d_sel on dokumen for select using (
  is_panitia() or exists (select 1 from pendaftaran r where r.id = pendaftaran_id and r.siswa_id = auth.uid()));
create policy d_ins on dokumen for insert with check (
  exists (select 1 from pendaftaran r where r.id = pendaftaran_id and r.siswa_id = auth.uid()
          and r.status in ('draft','revisi')));
create policy d_del on dokumen for delete using (
  exists (select 1 from pendaftaran r where r.id = pendaftaran_id and r.siswa_id = auth.uid()
          and r.status in ('draft','revisi')));

create policy a_sel on pengumuman for select using (terbit or is_panitia());
create policy a_all on pengumuman for all using (is_panitia()) with check (is_panitia());

create policy n_sel on notifikasi for select using (user_id = auth.uid());
create policy n_upd on notifikasi for update using (user_id = auth.uid()) with check (user_id = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dokumen','dokumen', false, 2097152, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do nothing;

create policy s_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'dokumen' and (storage.foldername(name))[1] = auth.uid()::text);
create policy s_sel on storage.objects for select to authenticated
  using (bucket_id = 'dokumen' and ((storage.foldername(name))[1] = auth.uid()::text or is_panitia()));
create policy s_del on storage.objects for delete to authenticated
  using (bucket_id = 'dokumen' and (storage.foldername(name))[1] = auth.uid()::text);

insert into jalur (nama, kuota, persyaratan) values
  ('Domisili', 100, array['Kartu Keluarga','Akta Kelahiran']),
  ('Prestasi', 60, array['Rapor','Sertifikat Prestasi']),
  ('Afirmasi', 40, array['Kartu KIP/KKS/SKTM','Kartu Keluarga']);

-- Jadikan akun panitia (jalankan SETELAH akunnya mendaftar):
-- update profiles set role = 'panitia' where id = (select id from auth.users where email = 'panitia@contoh.sch.id');
