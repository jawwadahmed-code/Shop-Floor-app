-- 002_functions.sql : submission logic (called only by the Edge Function) + admin tools

-- Factory-local date (change the time zone here if needed)
create or replace function public.factory_date(ts timestamptz) returns date
language sql immutable as $$ select (ts at time zone 'Asia/Karachi')::date $$;

-- ============ SUBMIT A READING ============
-- Locks the shop row so two simultaneous submissions for the same shop run one after the other.
create or replace function public.submit_reading(
  p_auth_user_id uuid, p_shop_id integer, p_reading numeric, p_notes text, p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp   public.employees;
  v_shop  public.shops;
  v_prev  public.meter_readings;
  v_row   public.meter_readings;
  v_diff  numeric;
  v_cons  numeric;
  v_status text;
begin
  select * into v_emp from employees where auth_user_id = p_auth_user_id;
  if v_emp.id is null or not v_emp.is_active then
    return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED',
      'message', 'Your account is not authorized to submit readings.');
  end if;

  if p_reading is null or p_reading < 0 or p_reading >= 1e12 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_READING',
      'message', 'Enter a valid meter reading (zero or more).');
  end if;

  -- LOCK this shop until the transaction ends
  select * into v_shop from shops where id = p_shop_id for update;
  if v_shop.id is null then
    return jsonb_build_object('ok', false, 'code', 'INVALID_SHOP', 'message', 'Unknown shop.');
  end if;

  -- Same request sent twice (retry / double click): return the saved row, do not insert again
  select * into v_row from meter_readings where request_id = p_request_id;
  if v_row.id is not null then
    if v_row.employee_id <> v_emp.id then
      return jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED', 'message', 'Invalid request.');
    end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'reading', to_jsonb(v_row),
                              'shop_name', v_shop.name);
  end if;

  if not v_shop.is_active then
    return jsonb_build_object('ok', false, 'code', 'SHOP_INACTIVE', 'message', 'This shop is not active.');
  end if;

  -- previous valid reading of the SAME shop (VOID rows are ignored)
  select * into v_prev from meter_readings
   where shop_id = p_shop_id and status <> 'VOID'
   order by id desc limit 1;

  -- Accidental second entry of the same value within 2 minutes
  if v_prev.id is not null and v_prev.reading = p_reading
     and v_prev.recorded_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'code', 'DUPLICATE',
      'message', 'This same reading was just submitted for this shop. Please check before entering again.');
  end if;

  if v_prev.id is null then
    v_status := 'BASELINE';
  else
    v_diff := p_reading - v_prev.reading;
    if v_diff < 0 then
      v_status := 'CHECK RESET';                       -- never a silent negative consumption
    else
      v_status := 'OK';
      v_cons := round(v_diff * v_shop.multiplier, 2);
    end if;
  end if;

  insert into meter_readings
    (shop_id, employee_id, reading, previous_reading, difference, multiplier,
     consumption_kwh, status, notes, request_id)
  values
    (p_shop_id, v_emp.id, p_reading, v_prev.reading, v_diff, v_shop.multiplier,
     v_cons, v_status, nullif(btrim(p_notes), ''), p_request_id)
  returning * into v_row;

  return jsonb_build_object('ok', true, 'duplicate', false, 'reading', to_jsonb(v_row),
                            'shop_name', v_shop.name);
end $$;

-- ============ ADMIN TOOLS (run from the Supabase SQL Editor only) ============

-- Link an Auth user (already created in the dashboard as <id>@meter.local) to an employee profile
create or replace function public.admin_register_employee(p_employee_code text, p_full_name text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  select id into v_uid from auth.users
   where lower(email) = lower(btrim(p_employee_code)) || '@meter.local';
  if v_uid is null then
    raise exception 'No Auth user %@meter.local. Create it in Authentication > Users first.', p_employee_code;
  end if;
  insert into employees (employee_code, full_name, auth_user_id)
  values (lower(btrim(p_employee_code)), p_full_name, v_uid);
  return 'Employee ' || lower(btrim(p_employee_code)) || ' registered.';
end $$;

-- Enable / disable an employee (also blocks new logins in Auth)
create or replace function public.admin_set_employee_active(p_employee_code text, p_active boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  update employees set is_active = p_active
   where employee_code = lower(btrim(p_employee_code)) returning auth_user_id into v_uid;
  if v_uid is null then raise exception 'Employee not found.'; end if;
  update auth.users
     set banned_until = case when p_active then null else now() + interval '100 years' end
   where id = v_uid;
  return 'Employee ' || p_employee_code || case when p_active then ' enabled.' else ' disabled.' end;
end $$;

-- Give a CHECK RESET reading its real consumption (kWh), with reason
create or replace function public.admin_adjust_reset(
  p_reading_id bigint, p_adjusted_kwh numeric, p_reason text, p_admin text)
returns text language plpgsql security definer set search_path = public as $$
declare v_r public.meter_readings;
begin
  if coalesce(btrim(p_reason),'') = '' or coalesce(btrim(p_admin),'') = '' then
    raise exception 'Reason and admin name are required.';
  end if;
  if p_adjusted_kwh is null or p_adjusted_kwh < 0 then raise exception 'Adjusted kWh must be 0 or more.'; end if;
  select * into v_r from meter_readings where id = p_reading_id;
  if v_r.id is null then raise exception 'Reading not found.'; end if;
  perform 1 from shops where id = v_r.shop_id for update;
  select * into v_r from meter_readings where id = p_reading_id;
  if v_r.status <> 'CHECK RESET' then raise exception 'Only a CHECK RESET reading can be adjusted (status is %).', v_r.status; end if;

  update meter_readings set consumption_kwh = p_adjusted_kwh, status = 'ADJUSTED RESET' where id = p_reading_id;
  insert into reading_audit (reading_id, action, old_values, new_values, reason, changed_by)
  values (p_reading_id, 'ADJUST_RESET',
          jsonb_build_object('status', v_r.status, 'consumption_kwh', v_r.consumption_kwh),
          jsonb_build_object('status', 'ADJUSTED RESET', 'consumption_kwh', p_adjusted_kwh),
          p_reason, p_admin);
  return 'Reading ' || p_reading_id || ' adjusted.';
end $$;

-- Cancel a wrong reading (kept in history as VOID) and re-calculate the next reading of that shop
create or replace function public.admin_void_reading(p_reading_id bigint, p_reason text, p_admin text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_r public.meter_readings; v_next public.meter_readings; v_prev public.meter_readings;
  v_diff numeric; v_cons numeric; v_status text;
begin
  if coalesce(btrim(p_reason),'') = '' or coalesce(btrim(p_admin),'') = '' then
    raise exception 'Reason and admin name are required.';
  end if;
  select * into v_r from meter_readings where id = p_reading_id;
  if v_r.id is null then raise exception 'Reading not found.'; end if;
  perform 1 from shops where id = v_r.shop_id for update;
  select * into v_r from meter_readings where id = p_reading_id;
  if v_r.status = 'VOID' then raise exception 'Reading is already VOID.'; end if;

  update meter_readings set status = 'VOID', consumption_kwh = null where id = p_reading_id;
  insert into reading_audit (reading_id, action, old_values, new_values, reason, changed_by)
  values (p_reading_id, 'VOID',
          jsonb_build_object('status', v_r.status, 'consumption_kwh', v_r.consumption_kwh),
          jsonb_build_object('status', 'VOID'), p_reason, p_admin);

  -- re-calculate the next valid reading of the same shop against its new previous reading
  select * into v_next from meter_readings
   where shop_id = v_r.shop_id and status <> 'VOID' and id > p_reading_id order by id limit 1;
  if v_next.id is not null then
    select * into v_prev from meter_readings
     where shop_id = v_r.shop_id and status <> 'VOID' and id < v_next.id order by id desc limit 1;
    v_cons := null; v_diff := null;
    if v_prev.id is null then
      v_status := 'BASELINE';
    else
      v_diff := v_next.reading - v_prev.reading;
      if v_diff < 0 then
        v_status := case when v_next.status = 'ADJUSTED RESET' then 'ADJUSTED RESET' else 'CHECK RESET' end;
        v_cons   := case when v_next.status = 'ADJUSTED RESET' then v_next.consumption_kwh else null end;
      else
        v_status := 'OK'; v_cons := round(v_diff * v_next.multiplier, 2);
      end if;
    end if;
    update meter_readings
       set previous_reading = v_prev.reading, difference = v_diff,
           consumption_kwh = v_cons, status = v_status
     where id = v_next.id;
    insert into reading_audit (reading_id, action, old_values, new_values, reason, changed_by)
    values (v_next.id, 'RECALC',
            jsonb_build_object('previous_reading', v_next.previous_reading, 'consumption_kwh', v_next.consumption_kwh, 'status', v_next.status),
            jsonb_build_object('previous_reading', v_prev.reading, 'consumption_kwh', v_cons, 'status', v_status),
            'Recalculated after reading ' || p_reading_id || ' was voided: ' || p_reason, p_admin);
  end if;
  return 'Reading ' || p_reading_id || ' voided.';
end $$;
