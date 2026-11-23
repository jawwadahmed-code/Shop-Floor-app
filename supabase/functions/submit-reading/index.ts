// Edge Function: submit-reading
// The ONLY way a reading gets written. The browser never holds a secret key.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { ok: false, message: "Method not allowed." });

  // 1. Who is calling? (verify the login token)
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json(401, { ok: false, code: "NO_LOGIN", message: "Please log in again." });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) {
    return json(401, { ok: false, code: "NO_LOGIN", message: "Session expired. Please log in again." });
  }

  // 2. Validate the input
  let body: any;
  try { body = await req.json(); } catch { return json(400, { ok: false, message: "Invalid request." }); }

  const shopId = Number(body?.shop_id);
  const reading = typeof body?.reading === "number" ? body.reading : Number(body?.reading);
  const notes = typeof body?.notes === "string" ? body.notes.trim().slice(0, 500) : "";
  const requestId = String(body?.request_id ?? "");

  if (!Number.isInteger(shopId) || shopId <= 0)
    return json(400, { ok: false, code: "INVALID_SHOP", message: "Please select a shop." });
  if (!Number.isFinite(reading) || reading < 0 || reading >= 1e12)
    return json(400, { ok: false, code: "INVALID_READING", message: "Enter a valid meter reading (zero or more)." });
  if (!UUID.test(requestId))
    return json(400, { ok: false, message: "Invalid request." });

  // 3. Save through the database function (locks the shop, calculates, inserts)
  const { data, error } = await admin.rpc("submit_reading", {
    p_auth_user_id: userData.user.id,
    p_shop_id: shopId,
    p_reading: reading,
    p_notes: notes,
    p_request_id: requestId,
  });

  if (error) {
    console.error("submit_reading failed:", error.message);
    return json(500, { ok: false, code: "DB_ERROR", message: "The reading could not be saved. Please try again." });
  }
  if (!data?.ok) {
    const status = data?.code === "NOT_AUTHORIZED" ? 403 : data?.code === "DUPLICATE" ? 409 : 400;
    return json(status, data);
  }
  return json(200, data);
});
