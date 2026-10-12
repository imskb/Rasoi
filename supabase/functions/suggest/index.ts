// Rasoi · Supabase Edge Function "suggest"
// Holds the Gemini key (as a secret), checks the user is logged in, enforces a daily limit,
// calls Gemini, runs the grounding check in code, saves the suggestion, and returns it.
//
// Secrets to set in Supabase (Edge Functions → Secrets):
//   GEMINI_API_KEY        required
//   GEMINI_MODEL          default gemini-3.5-flash
//   GEMINI_FALLBACKS      default gemini-3.1-flash-lite,gemini-flash-lite-latest
//   GEMINI_THINKING       default high   (low | high)
//   GEMINI_TEMPERATURE    default 0.5
//   DAILY_LIMIT           default 15
//   GEMINI_MAX_TOKENS     default 16384 (thinking tokens count against it)
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const env = (k: string, d = "") => Deno.env.get(k) ?? d;
const GEMINI_KEY = env("GEMINI_API_KEY");
const MODEL = env("GEMINI_MODEL", "gemini-3.5-flash");
const FALLBACKS = env("GEMINI_FALLBACKS", "gemini-3.1-flash-lite,gemini-flash-lite-latest").split(",").map((x) => x.trim()).filter(Boolean);
const THINKING = env("GEMINI_THINKING", "high");
const TEMPERATURE = Number(env("GEMINI_TEMPERATURE", "0.5"));
const DAILY_LIMIT = Number(env("DAILY_LIMIT", "15"));
const MAX_TOKENS = Number(env("GEMINI_MAX_TOKENS", "16384"));   // thinking counts against this, so keep it generous
const PROMPT_VERSION = "v2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });

// ---------------- prompt ----------------
const SYSTEM = `You suggest home-cooked Indian meals from what is in one person's kitchen.

Hard rules:
- Use ONLY the ingredients the user lists, plus their stated staples. Never introduce any other ingredient, not even a small one like curry leaves, coriander or mustard seeds unless listed.
- The ingredient list is the COMPLETE contents of their kitchen. If something is not listed, they do not have it. Absence means absent, not "probably available".
- Quantities, when given, are what they have. Do not suggest a dish that needs clearly more than that.
- Respect the food preference: veg = no egg, meat or fish; egg = vegetarian plus eggs; nonveg = anything.
- Do not repeat any dish in the "recently suggested" list.
- Realistic everyday home cooking, under 45 minutes.
- If a reasonable dish is not possible for a requested meal, set possible=false, leave that meal out, and name the ONE ingredient that would unlock the most options. Never invent a marginal dish just to fill the slot.
- When possible=false, also give nearest_dish: the dish they are closest to making, and nearest_missing: the 1 or 2 ingredients they lack for it.
- In "why", mention only ingredients they actually have.
- For each meal, give 3 different candidate dishes that all follow these rules.
- "uses" lists only ingredients from the user's list (not staples), spelled exactly as the user's list spells them.`;

const SCHEMA = {
  type: "OBJECT",
  properties: {
    possible: { type: "BOOLEAN" },
    reason: { type: "STRING", description: "If possible is false, what is missing. Otherwise empty." },
    unlock: { type: "STRING", description: "If possible is false, the one ingredient that would unlock the most dishes. Otherwise empty." },
    nearest_dish: { type: "STRING", description: "If possible is false, the dish they are closest to making. Otherwise empty." },
    nearest_missing: { type: "ARRAY", items: { type: "STRING" }, description: "If possible is false, the 1-2 ingredients missing for nearest_dish. Otherwise empty." },
    meals: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          slot: { type: "STRING", enum: ["breakfast", "lunch"] },
          candidates: {
            type: "ARRAY",
            items: {
              type: "OBJECT",
              properties: {
                dish: { type: "STRING" },
                why: { type: "STRING", description: "One short line on why it suits what they have." },
                uses: { type: "ARRAY", items: { type: "STRING" } },
                minutes: { type: "INTEGER" },
              },
              required: ["dish", "why", "uses", "minutes"],
            },
          },
        },
        required: ["slot", "candidates"],
      },
    },
  },
  required: ["possible", "reason", "unlock", "nearest_dish", "nearest_missing", "meals"],
};

type Ing = { name: string; quantity: number | null; unit: string | null };
function buildUserPrompt(ings: Ing[], staples: string[], slot: string, diet: string, avoid: string[]) {
  const list = ings.map((i) => `- ${i.name}${i.quantity != null ? ` (${i.quantity} ${i.unit})` : ""}`).join("\n");
  const slots = slot === "both" ? "one breakfast and one lunch" : `one ${slot}`;
  return `My kitchen has exactly:\n${list}\n\nStaples I always have: ${staples.join(", ") || "none"}.\nFood preference: ${diet}.\nRecently suggested (do not repeat): ${avoid.join(", ") || "none"}.\n\nSuggest ${slots}.`;
}

// ---------------- grounding check (same as server.js) ----------------
const GENERIC = new Set(["toast", "wrap", "bun", "cream", "cereal", "oil", "cooking oil", "refined oil", "corn", "cheese slice", "sev", "namkeen", "water", "paani", "pani", "salt", "namak", "egg", "beans", "peas", "achar", "chutney"]);
const DERIVED: Record<string, string[]> = { roti: ["atta", "multigrain atta"], buttermilk: ["curd"] };
const norm = (s: unknown) => String(s ?? "").toLowerCase().trim();
const escRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
type Dir = { name: string; aliases: string[] };

// deno-lint-ignore no-explicit-any
function groundCheck(result: any, ings: Ing[], staples: string[], directory: Dir[]) {
  const owned = new Set([...ings.map((i) => norm(i.name)), ...staples.map(norm)]);
  const ownedText = [...owned].join(" | ");
  const allowed = (item: Dir) => {
    const n = norm(item.name);
    if (owned.has(n)) return true;
    if ((DERIVED[n] || []).some((b) => owned.has(b))) return true;
    return [n, ...item.aliases.map(norm)].some((t) => ownedText.includes(t));
  };
  const terms = (item: Dir) => [item.name, ...item.aliases].map(norm).filter((t) => t.length >= 4 && !GENERIC.has(t));
  const dropped: unknown[] = [];
  for (const meal of result.meals || []) {
    // deno-lint-ignore no-explicit-any
    meal.candidates = (meal.candidates || []).filter((c: any) => {
      const missingUses = (c.uses || []).filter((u: string) => !owned.has(norm(u)));
      if (missingUses.length) { dropped.push({ slot: meal.slot, dish: c.dish, check: "uses", missing: missingUses }); return false; }
      const why = norm(c.why);
      const mentioned = directory.filter((item) => !allowed(item) && terms(item).some((t) => new RegExp(`\\b${escRe(t)}\\b`).test(why)));
      if (mentioned.length) { dropped.push({ slot: meal.slot, dish: c.dish, check: "why", missing: mentioned.map((m) => m.name) }); return false; }
      return true;
    });
  }
  // deno-lint-ignore no-explicit-any
  result.meals = (result.meals || []).filter((m: any) => m.candidates.length);
  return dropped;
}

// ---------------- Gemini ----------------
async function callGemini(model: string, userPrompt: string) {
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), 40000);
  try {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST",
      signal: ac.signal,
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM }] },
        contents: [{ role: "user", parts: [{ text: userPrompt }] }],
        generationConfig: {
          responseMimeType: "application/json", responseSchema: SCHEMA, maxOutputTokens: MAX_TOKENS,
          temperature: TEMPERATURE, thinkingConfig: { thinkingLevel: THINKING },
        },
      }),
    });
    return { ok: r.ok, status: r.status, j: await r.json() };
  } catch (_e) {
    return { ok: false, status: 504, j: { error: { status: "TIMEOUT" } } };
  } finally { clearTimeout(to); }
}

// ---------------- handler ----------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });
  if (!GEMINI_KEY) return reply(500, { error: "The AI isn't configured yet." });

  // 1. Who is calling? Use their own login token, so the database's per-user rules apply.
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY") || env("SUPABASE_PUBLISHABLE_KEY") || env("RASOI_PUBLISHABLE_KEY"), { global: { headers: { Authorization: auth } } });
  const { data: userData, error: userErr } = await sb.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
  if (userErr || !userData?.user) return reply(401, { error: "Please log in again." });
  const userId = userData.user.id;

  // 2. Daily limit, counted from the suggestions this user saved today (India time).
  const istToday = new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);   // e.g. 2026-10-13
  const startUtc = new Date(`${istToday}T00:00:00+05:30`);
  const { count } = await sb.from("suggestions").select("id", { count: "exact", head: true }).eq("user_id", userId).gte("created_at", startUtc.toISOString());
  if ((count ?? 0) >= DAILY_LIMIT) return reply(429, { error: `You've used today's ${DAILY_LIMIT} suggestions. Come back tomorrow.` });

  // 3. Read the request. The kitchen is read from the database, not trusted from the browser.
  // deno-lint-ignore no-explicit-any
  let body: any = {};
  try { body = await req.json(); } catch (_e) { /* empty body is fine */ }
  const slot = ["breakfast", "lunch", "both"].includes(body.slot) ? body.slot : "both";
  const avoid: string[] = Array.isArray(body.avoid) ? body.avoid.slice(0, 12).map(String) : [];
  const [ingQ, stQ, profQ, dirQ] = await Promise.all([
    sb.from("user_ingredients").select("name, quantity, unit").eq("user_id", userId),
    sb.from("user_staples").select("name").eq("user_id", userId),
    sb.from("profiles").select("diet").eq("id", userId).maybeSingle(),
    sb.from("ingredient_catalog").select("name, aliases"),
  ]);
  const ings: Ing[] = (ingQ.data || []).map((r) => ({ name: r.name, quantity: r.quantity == null ? null : Number(r.quantity), unit: r.unit }));
  const staples: string[] = (stQ.data || []).map((r) => r.name);
  const diet = profQ.data?.diet || "veg";
  if (ings.length < 2) return reply(400, { error: "Add at least 2 ingredients." });

  // 4. Call Gemini: main model with one retry, then lighter fallbacks.
  const t0 = Date.now();
  const userPrompt = buildUserPrompt(ings, staples, slot, diet, avoid);
  const plan = [MODEL, MODEL, ...FALLBACKS];
  // deno-lint-ignore no-explicit-any
  let res: any, used = MODEL;
  for (let n = 0; n < plan.length; n++) {
    used = plan[n];
    res = await callGemini(used, userPrompt);
    if (res.ok) break;
    const st = res.j?.error?.status;
    const transient = [500, 503, 504].includes(res.status) || ["UNAVAILABLE", "TIMEOUT", "RESOURCE_EXHAUSTED"].includes(st);
    console.warn(`[${used}] ${res.status} ${st}`);
    if (!transient) break;
    await new Promise((r) => setTimeout(r, n === 0 ? 1200 : 300));
  }
  if (!res.ok) {
    const st = res.j?.error?.status;
    return reply(503, { error: st === "RESOURCE_EXHAUSTED" ? "The free daily AI limit is used up. Try again later." : "The AI is busy right now. Try again in a minute." });
  }
  const cand = res.j.candidates?.[0];
  const finish = cand?.finishReason;
  if (finish === "MAX_TOKENS") return reply(502, { error: "The answer was cut off. Try again." });
  if (finish && finish !== "STOP") return reply(502, { error: "The AI declined this request. Try different ingredients." });
  // deno-lint-ignore no-explicit-any
  let data: any;
  try { data = JSON.parse((cand.content.parts || []).map((p: { text?: string }) => p.text || "").join("")); }
  catch (_e) { return reply(502, { error: "The AI returned an unreadable answer. Try again." }); }
  const raw = structuredClone(data);
  const dropped = groundCheck(data, ings, staples, (dirQ.data || []) as Dir[]);

  // 5. Pick one candidate per meal at random, avoiding recent dishes.
  const slots = slot === "both" ? ["breakfast", "lunch"] : [slot];
  const meals = [];
  for (const s of slots) {
    // deno-lint-ignore no-explicit-any
    const m = (data.meals || []).find((x: any) => x.slot === s);
    if (!m?.candidates.length) continue;
    // deno-lint-ignore no-explicit-any
    const fresh = m.candidates.filter((c: any) => !avoid.includes(c.dish));
    const from = fresh.length ? fresh : m.candidates;
    const c = from[Math.floor(Math.random() * from.length)];
    meals.push({ id: crypto.randomUUID(), slot: s, dish: c.dish, minutes: c.minutes, uses: c.uses, why: c.why });
  }
  const possible = meals.length === slots.length;
  const u = res.j.usageMetadata || {};
  const suggestion = {
    id: crypto.randomUUID(), slot, possible,
    reason: possible ? "" : (data.reason || `Not enough for a proper ${slots.filter((s) => !meals.some((m) => m.slot === s)).join(" or ")}.`),
    unlock: possible ? null : (data.unlock || null),
    nearest_dish: possible ? null : (data.nearest_dish || null),
    nearest_missing: possible ? [] : (data.nearest_missing || []),
    meals, created_at: new Date().toISOString(),
  };

  // 6. Save it (as the user, so the per-user rules apply), then return it.
  const ins = await sb.from("suggestions").insert({
    id: suggestion.id, user_id: userId, slot, possible, reason: suggestion.reason || null, unlock_ingredient: suggestion.unlock,
    ingredients_snapshot: ings, model: used, effort: THINKING, temperature: TEMPERATURE, prompt_version: PROMPT_VERSION,
    input_tokens: u.promptTokenCount || 0, output_tokens: (u.candidatesTokenCount || 0) + (u.thoughtsTokenCount || 0),
    cost_usd: 0, latency_ms: Date.now() - t0, stop_reason: finish,
    raw_output: raw, grounding_dropped: dropped, nearest_dish: suggestion.nearest_dish, nearest_missing: suggestion.nearest_missing,
  });
  if (ins.error) console.error("save suggestion", ins.error.message);
  else if (meals.length) {
    const mi = await sb.from("suggestion_meals").insert(meals.map((m) => ({ ...m, suggestion_id: suggestion.id, user_id: userId })));
    if (mi.error) console.error("save meals", mi.error.message);
  }

  return reply(200, { suggestion, remaining_today: Math.max(0, DAILY_LIMIT - (count ?? 0) - 1) });
});
