-- Admin commands. Run in Supabase Dashboard > SQL Editor. Never exposed to the app.

-- 1) After creating the Auth user (Authentication > Users > Add user, email = 1234@meter.local):
select admin_register_employee('1234', 'Employee Name');

-- 2) Disable / re-enable an employee
select admin_set_employee_active('1234', false);
select admin_set_employee_active('1234', true);

-- 3) Add a new shop (appears in the app automatically)
insert into shops (code, name, meter_id, multiplier) values ('SHOP6', 'SHOP 6', 'MTR-006', 1);

-- 4) Change a shop's multiplier / meter ID (affects NEW readings only)
update shops set multiplier = 40, meter_id = 'MTR-001' where code = 'HUB';

-- 5) Deactivate a shop (history is kept)
update shops set is_active = false where code = 'SHOP6';

-- 6) List readings flagged CHECK RESET
select * from v_meter_resets where status = 'CHECK RESET';

-- 7) Resolve a CHECK RESET: enter the real consumption (kWh) for that reading
select admin_adjust_reset(123, 85.5, 'Meter replaced on 12-Nov, consumption from log sheet', 'Admin Name');

-- 8) Cancel a wrong reading (kept as VOID; the next reading is recalculated)
select admin_void_reading(123, 'Typing mistake - 100500 entered instead of 10500', 'Admin Name');

-- 9) Audit trail
select * from reading_audit order by changed_at desc;
