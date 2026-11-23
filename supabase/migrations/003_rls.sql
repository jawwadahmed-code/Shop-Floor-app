-- 003_rls.sql : Row Level Security and permissions

alter table public.shops          enable row level security;
alter table public.employees      enable row level security;
alter table public.meter_readings enable row level security;
alter table public.reading_audit  enable row level security;   -- no policies = nobody but admin/service role

-- helper: id of the logged-in employee, only if the employee is active
create or replace function public.current_employee_id() returns integer
language sql stable security definer set search_path = public as $$
  select id from employees where auth_user_id = auth.uid() and is_active
$$;

-- Employees can read: active shops, their own profile, their own readings. Nothing else.
create policy shops_read on public.shops for select to authenticated
  using (is_active and public.current_employee_id() is not null);

create policy employees_read_own on public.employees for select to authenticated
  using (auth_user_id = auth.uid());

create policy readings_read_own on public.meter_readings for select to authenticated
  using (employee_id = public.current_employee_id());

-- There is deliberately NO insert / update / delete policy. Writes happen only through
-- the Edge Function (service role) -> submit_reading().

-- Table privileges: remove Supabase defaults, grant only SELECT
revoke all on public.shops, public.employees, public.meter_readings, public.reading_audit
  from anon, authenticated;
grant select on public.shops, public.employees, public.meter_readings to authenticated;

-- Function privileges
revoke execute on function public.submit_reading(uuid, integer, numeric, text, uuid) from public, anon, authenticated;
revoke execute on function public.admin_register_employee(text, text)               from public, anon, authenticated;
revoke execute on function public.admin_set_employee_active(text, boolean)          from public, anon, authenticated;
revoke execute on function public.admin_adjust_reset(bigint, numeric, text, text)   from public, anon, authenticated;
revoke execute on function public.admin_void_reading(bigint, text, text)            from public, anon, authenticated;
revoke execute on function public.current_employee_id()                             from public, anon;
grant  execute on function public.submit_reading(uuid, integer, numeric, text, uuid) to service_role;
grant  execute on function public.current_employee_id()                             to authenticated;
