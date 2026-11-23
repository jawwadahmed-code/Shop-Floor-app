-- 001_schema.sql : tables, constraints, protection triggers
-- Run order: 001 -> 002 -> 003 -> 004 -> 005

-- ---------- SHOPS ----------
create table public.shops (
  id          integer generated always as identity primary key,
  code        text    not null unique,              -- e.g. HUB
  name        text    not null,
  meter_id    text,                                 -- physical meter number (optional)
  multiplier  numeric(10,4) not null default 1 check (multiplier > 0),  -- CT/PT multiplier
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- EMPLOYEES (profiles; passwords live in Supabase Auth only) ----------
create table public.employees (
  id             integer generated always as identity primary key,
  employee_code  text not null unique,              -- the Employee ID typed at login
  full_name      text,
  auth_user_id   uuid not null unique references auth.users(id),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

-- ---------- METER READINGS (one row per submission, never overwritten) ----------
create table public.meter_readings (
  id                bigint generated always as identity primary key,
  shop_id           integer      not null references public.shops(id),
  employee_id       integer      not null references public.employees(id),
  reading           numeric(14,2) not null check (reading >= 0),     -- cumulative meter reading
  recorded_at       timestamptz  not null default now(),             -- set by the server
  previous_reading  numeric(14,2),
  difference        numeric(14,2),                                   -- reading - previous_reading
  multiplier        numeric(10,4) not null,                          -- copy of shop multiplier at that time
  consumption_kwh   numeric(14,2),                                   -- difference * multiplier (null for baseline / reset)
  status            text not null check (status in ('BASELINE','OK','CHECK RESET','ADJUSTED RESET','VOID')),
  notes             text check (char_length(notes) <= 500),
  request_id        uuid not null unique                             -- prevents double submission
);
create index meter_readings_shop_idx     on public.meter_readings (shop_id, id desc);
create index meter_readings_employee_idx on public.meter_readings (employee_id, recorded_at desc);
create index meter_readings_time_idx     on public.meter_readings (recorded_at);

-- ---------- AUDIT TRAIL ----------
create table public.reading_audit (
  id          bigint generated always as identity primary key,
  reading_id  bigint not null references public.meter_readings(id),
  action      text   not null,                 -- ADJUST_RESET / VOID / RECALC
  old_values  jsonb,
  new_values  jsonb,
  reason      text,
  changed_by  text   not null,                 -- admin name
  changed_at  timestamptz not null default now()
);

-- ---------- PROTECTION: readings can never be deleted; core fields can never change ----------
create or replace function public.protect_readings() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Meter readings cannot be deleted. Use admin_void_reading().';
  end if;
  if new.shop_id <> old.shop_id or new.employee_id <> old.employee_id
     or new.reading <> old.reading or new.recorded_at <> old.recorded_at
     or new.request_id <> old.request_id or new.multiplier <> old.multiplier then
    raise exception 'Core fields of a meter reading cannot be changed.';
  end if;
  return new;
end $$;

create trigger trg_protect_readings
before update or delete on public.meter_readings
for each row execute function public.protect_readings();
