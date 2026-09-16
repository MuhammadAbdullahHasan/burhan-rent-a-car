-- Burhan Rent-A-Car -- initial Postgres schema.
-- Mirrors the validated local SQLite schema (lib/src/db/schema.dart) plus
-- owner_id/RLS, per the locked architecture spec §2/§4/§6. No historical
-- data lives here yet -- this project starts empty and is seeded once the
-- real CSV is imported (bulk load directly against Postgres, then reseed
-- rentals_rental_no_seq to MAX(rental_no) WHERE NOT is_placeholder, per §7).

create table customers (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null default auth.uid() references auth.users(id),
  full_name           text,
  phone               text,
  phone_normalized    text,
  cnic                text,
  cnic_normalized     text,
  license_no          text,
  license_city        text,
  possible_duplicate  boolean not null default false,
  is_deleted          boolean not null default false,
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_customers_owner on customers(owner_id);
create index idx_customers_phone on customers(phone_normalized);
create index idx_customers_cnic on customers(cnic_normalized);
create index idx_customers_name on customers(lower(full_name));

create table vehicles (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null default auth.uid() references auth.users(id),
  registration_no     text,
  registration_norm   text,
  chassis_no          text,
  engine_no           text,
  company             text,
  model_name          text,
  trim                text,
  horsepower          text,
  color               text,
  reg_year            integer,
  insurance_due_on    date,
  is_deleted          boolean not null default false,
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_vehicles_owner on vehicles(owner_id);
-- Unique per owner, not globally -- each owner's inventory is independent.
create unique index idx_vehicles_reg on vehicles(owner_id, registration_norm)
  where registration_norm is not null;

-- Authoritative source of new rental numbers (locked spec §2 and §5): a
-- single monotonic counter, seeded past every historical number and only
-- ever incremented. Starts at 1 since no history has been imported yet.
create sequence rentals_rental_no_seq;

create table rentals (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null default auth.uid() references auth.users(id),
  rental_no           integer unique,
  is_placeholder      boolean not null default false,
  customer_id         uuid references customers(id),
  vehicle_id          uuid references vehicles(id),
  start_date          date,
  start_time          text,
  end_date            date,
  end_time            text,
  book_days           integer,
  amount              numeric,
  balance             numeric,
  status              text,
  remarks             text,
  ref_name            text,
  ref_contact         text,
  ref_relation        text,
  is_deleted          boolean not null default false,
  version             integer not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_rentals_owner on rentals(owner_id);
create index idx_rentals_customer on rentals(customer_id);
create index idx_rentals_vehicle on rentals(vehicle_id);
create index idx_rentals_start on rentals(start_date);

-- Atomically assigns the next permanent rental number -- the online path
-- of §2. Offline-created rentals call this only once they sync; a rental
-- number is never guessed or reserved client-side.
--
-- Next number = one past the highest ever seen, from EITHER source:
--   * the highest rental_no actually stored (live, soft-deleted or
--     placeholder alike -- a retired number is never handed out again), or
--   * the sequence, which acts as a floor for numbers that exist only in
--     the historical dataset not yet loaded here.
-- An advisory lock serialises concurrent syncs from different devices.
create function allocate_rental_no() returns integer
  language plpgsql security definer set search_path = public as $$
declare
  data_max integer;
  seq_pos bigint;
  next_no integer;
begin
  perform pg_advisory_xact_lock(hashtext('allocate_rental_no'));
  select coalesce(max(rental_no), 0) into data_max from rentals;
  select case when is_called then last_value else last_value - 1 end
    into seq_pos from rentals_rental_no_seq;
  next_no := greatest(data_max, seq_pos) + 1;
  perform setval('rentals_rental_no_seq', next_no);
  return next_no;
end;
$$;
revoke execute on function allocate_rental_no() from public, anon;
grant execute on function allocate_rental_no() to authenticated;

-- Development dataset: highest real number is #60, so the first rental
-- created in the app becomes #61. Re-run against MAX(rental_no) after the
-- real historical import.
select setval('rentals_rental_no_seq', 60);

-- Durable audit trail (locked spec §5/§6): one row per create/update/
-- delete, written by the app (or, later, a trigger) alongside the change.
create table audit_log (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null default auth.uid() references auth.users(id),
  entity_type    text not null,
  entity_id      uuid not null,
  action         text not null,
  changed_fields jsonb,
  actor          uuid references auth.users(id),
  created_at     timestamptz not null default now()
);
create index idx_audit_owner on audit_log(owner_id, created_at desc);

alter table customers enable row level security;
alter table vehicles enable row level security;
alter table rentals enable row level security;
alter table audit_log enable row level security;

-- Single-owner today, but enforced per-row at the DB layer regardless --
-- ready for a second staff login later without any policy changes.
create policy "owner reads own customers" on customers for select using (owner_id = auth.uid());
create policy "owner writes own customers" on customers for insert with check (owner_id = auth.uid());
create policy "owner updates own customers" on customers for update using (owner_id = auth.uid());
create policy "owner deletes own customers" on customers for delete using (owner_id = auth.uid());

create policy "owner reads own vehicles" on vehicles for select using (owner_id = auth.uid());
create policy "owner writes own vehicles" on vehicles for insert with check (owner_id = auth.uid());
create policy "owner updates own vehicles" on vehicles for update using (owner_id = auth.uid());
create policy "owner deletes own vehicles" on vehicles for delete using (owner_id = auth.uid());

create policy "owner reads own rentals" on rentals for select using (owner_id = auth.uid());
create policy "owner writes own rentals" on rentals for insert with check (owner_id = auth.uid());
create policy "owner updates own rentals" on rentals for update using (owner_id = auth.uid());
create policy "owner deletes own rentals" on rentals for delete using (owner_id = auth.uid());

create policy "owner reads own audit log" on audit_log for select using (owner_id = auth.uid());
create policy "owner writes own audit log" on audit_log for insert with check (owner_id = auth.uid());

-- Agreement photos, one row per image, synced like every other entity.
-- Stored base64-encoded so the same payload shape works over PostgREST in
-- both directions without binary escaping.
create table attachments (
  id               uuid primary key,
  owner_id         uuid not null default auth.uid() references auth.users(id),
  entity_type      text not null,
  entity_id        uuid not null,
  kind             text not null,
  mime_type        text,
  image_base64     text not null,
  thumbnail_base64 text,
  is_deleted       boolean not null default false,
  version          integer not null default 1,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index idx_attachments_entity on attachments(entity_type, entity_id);
alter table attachments enable row level security;
create policy "owner reads own attachments" on attachments for select using (owner_id = auth.uid());
create policy "owner writes own attachments" on attachments for insert with check (owner_id = auth.uid());
create policy "owner updates own attachments" on attachments for update using (owner_id = auth.uid());
create policy "owner deletes own attachments" on attachments for delete using (owner_id = auth.uid());

-- Incremental pull: "everything changed since this device last synced".
create index idx_customers_updated on customers(owner_id, updated_at);
create index idx_vehicles_updated on vehicles(owner_id, updated_at);
create index idx_rentals_updated on rentals(owner_id, updated_at);
