-- 004_views.sql : reporting views for a future management dashboard.
-- Not readable by the app users (anon / authenticated). A dashboard should connect with a
-- server-side key or a dedicated read-only database role.

create or replace view public.v_readings_report as          -- shop-wise cumulative readings + employee records
select r.id as reading_id, s.code as shop_code, s.name as shop_name,
       public.factory_date(r.recorded_at) as reading_date, r.recorded_at,
       r.reading, r.previous_reading, r.difference, r.multiplier,
       r.consumption_kwh, r.status, r.notes,
       e.employee_code, e.full_name as employee_name
from public.meter_readings r
join public.shops s     on s.id = r.shop_id
join public.employees e on e.id = r.employee_id;

create or replace view public.v_daily_consumption as         -- shop-wise daily consumption
select shop_code, shop_name, reading_date,
       sum(consumption_kwh)                       as consumption_kwh,
       (array_agg(reading order by reading_id desc))[1] as closing_reading,
       count(*) filter (where status = 'CHECK RESET') as open_reset_flags
from public.v_readings_report
where status <> 'VOID'
group by shop_code, shop_name, reading_date;

create or replace view public.v_monthly_consumption as       -- monthly consumption per shop
select shop_code, shop_name, date_trunc('month', reading_date)::date as month,
       sum(consumption_kwh) as consumption_kwh
from public.v_daily_consumption
group by shop_code, shop_name, date_trunc('month', reading_date);

create or replace view public.v_factory_daily as             -- total factory, per day
select reading_date, sum(consumption_kwh) as consumption_kwh
from public.v_daily_consumption group by reading_date;

create or replace view public.v_factory_monthly as           -- total factory, per month
select month, sum(consumption_kwh) as consumption_kwh
from public.v_monthly_consumption group by month;

create or replace view public.v_employee_submissions as      -- employee-wise submissions
select employee_code, employee_name, reading_date, count(*) as submissions,
       min(recorded_at) as first_submission, max(recorded_at) as last_submission
from public.v_readings_report group by employee_code, employee_name, reading_date;

create or replace view public.v_missing_readings as          -- active shops with no reading on a day (last 30 days)
select s.code as shop_code, s.name as shop_name, d::date as missing_date
from public.shops s
cross join generate_series(public.factory_date(now()) - 30, public.factory_date(now()) - 1, interval '1 day') d
where s.is_active
  and d::date >= public.factory_date(s.created_at)
  and not exists (select 1 from public.meter_readings r
                  where r.shop_id = s.id and r.status <> 'VOID'
                    and public.factory_date(r.recorded_at) = d::date);

create or replace view public.v_shop_latest as               -- delayed readings: days since last reading
select s.code as shop_code, s.name as shop_name,
       max(r.recorded_at) as last_reading_at,
       public.factory_date(now()) - public.factory_date(max(r.recorded_at)) as days_since_last
from public.shops s
left join public.meter_readings r on r.shop_id = s.id and r.status <> 'VOID'
where s.is_active group by s.id, s.code, s.name;

create or replace view public.v_meter_resets as              -- resets and adjustments with audit info
select v.reading_id, v.shop_code, v.shop_name, v.recorded_at, v.previous_reading, v.reading,
       v.status, v.consumption_kwh as adjusted_kwh,
       a.reason, a.changed_by, a.changed_at
from public.v_readings_report v
left join public.reading_audit a on a.reading_id = v.reading_id and a.action = 'ADJUST_RESET'
where v.status in ('CHECK RESET', 'ADJUSTED RESET');

revoke all on public.v_readings_report, public.v_daily_consumption, public.v_monthly_consumption,
  public.v_factory_daily, public.v_factory_monthly, public.v_employee_submissions,
  public.v_missing_readings, public.v_shop_latest, public.v_meter_resets from anon, authenticated;
grant select on public.v_readings_report, public.v_daily_consumption, public.v_monthly_consumption,
  public.v_factory_daily, public.v_factory_monthly, public.v_employee_submissions,
  public.v_missing_readings, public.v_shop_latest, public.v_meter_resets to service_role;
