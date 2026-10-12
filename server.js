// Rasoi local server: serves the app and holds the Gemini key.
// Run: node server.js   then open http://localhost:8787
// No npm packages needed (Node 18+).
const http = require('http');
const fs = require('fs');
const path = require('path');

// ---- load .env ----
const env = {};
try {
  fs.readFileSync(path.join(__dirname, '.env'), 'utf8').split('\n').forEach(l => {
    const m = l.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/); if (m) env[m[1]] = m[2];
  });
} catch (e) { console.error('Missing .env file'); }
const GEMINI_KEY = env.GEMINI_API_KEY;
const MODEL = env.GEMINI_MODEL || 'gemini-flash-latest';
const PROMPT_VERSION = 'v2';

// The ingredient directory, shared with the app (used by the grounding check)
global.window = global.window || {};
require('./web/ingredients.js');
const DIRECTORY = global.window.INGREDIENTS;
const PORT = Number(env.PORT || 8787);
// Generation settings. Change them in .env, then restart the server.
const THINKING = env.GEMINI_THINKING || 'high';                 // Gemini's version of "effort": low | high
const MAX_TOKENS = Number(env.GEMINI_MAX_TOKENS || 16384);   // thinking counts against this
const TEMPERATURE = env.GEMINI_TEMPERATURE != null ? Number(env.GEMINI_TEMPERATURE) : 0.5;

// ---- prompt ----
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
  type: 'OBJECT',
  properties: {
    possible: { type: 'BOOLEAN' },
    reason: { type: 'STRING', description: 'If possible is false, what is missing. Otherwise empty.' },
    unlock: { type: 'STRING', description: 'If possible is false, the one ingredient that would unlock the most dishes. Otherwise empty.' },
    nearest_dish: { type: 'STRING', description: 'If possible is false, the dish they are closest to making. Otherwise empty.' },
    nearest_missing: { type: 'ARRAY', items: { type: 'STRING' }, description: 'If possible is false, the 1-2 ingredients missing for nearest_dish. Otherwise empty.' },
    meals: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          slot: { type: 'STRING', enum: ['breakfast', 'lunch'] },
          candidates: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                dish: { type: 'STRING' },
                why: { type: 'STRING', description: 'One short line on why it suits what they have.' },
                uses: { type: 'ARRAY', items: { type: 'STRING' } },
                minutes: { type: 'INTEGER' }
              },
              required: ['dish', 'why', 'uses', 'minutes']
            }
          }
        },
        required: ['slot', 'candidates']
      }
    }
  },
  required: ['possible', 'reason', 'unlock', 'nearest_dish', 'nearest_missing', 'meals']
};

function buildUserPrompt({ ingredients, staples, slot, diet, avoid }) {
  const list = ingredients.map(i => `- ${i.name}${i.quantity != null ? ` (${i.quantity} ${i.unit})` : ''}`).join('\n');
  const slots = slot === 'both' ? 'one breakfast and one lunch' : `one ${slot}`;
  return `My kitchen has exactly:\n${list}\n\nStaples I always have: ${(staples || []).join(', ') || 'none'}.\nFood preference: ${diet}.\nRecently suggested (do not repeat): ${(avoid || []).join(', ') || 'none'}.\n\nSuggest ${slots}.`;
}

// ---- grounding check in code: never trust the model's claim ----
// Check 1: every item in "uses" must be in the kitchen.
// Check 2: the "why" line must not mention any directory ingredient the user doesn't have.
const GENERIC = new Set(['toast', 'wrap', 'bun', 'cream', 'cereal', 'oil', 'cooking oil', 'refined oil', 'corn', 'cheese slice', 'sev', 'namkeen', 'water', 'paani', 'pani', 'salt', 'namak', 'egg', 'beans', 'peas', 'achar', 'chutney']);
const DERIVED = { roti: ['atta', 'multigrain atta'], buttermilk: ['curd'] };   // made at home from something they have
const norm = s => String(s).toLowerCase().trim();
const termsOf = item => [item.name, ...item.aliases].map(norm).filter(t => t.length >= 4 && !GENERIC.has(t));
const escRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function groundCheck(result, ingredients, staples = []) {
  const owned = new Set([...ingredients.map(i => norm(i.name)), ...staples.map(norm)]);
  const ownedText = [...owned].join(' | ');
  const allowed = item => {
    const n = norm(item.name);
    if (owned.has(n)) return true;
    if ((DERIVED[n] || []).some(b => owned.has(b))) return true;
    return [n, ...item.aliases.map(norm)].some(t => ownedText.includes(t));   // "onion" when they have "red onion"
  };
  const dropped = [];
  for (const meal of result.meals || []) {
    meal.candidates = (meal.candidates || []).filter(c => {
      const missingUses = (c.uses || []).filter(u => !owned.has(norm(u)));
      if (missingUses.length) { dropped.push({ slot: meal.slot, dish: c.dish, check: 'uses', missing: missingUses }); return false; }
      const why = norm(c.why || '');
      const mentioned = DIRECTORY.filter(item => !allowed(item) && termsOf(item).some(t => new RegExp(`\\b${escRe(t)}\\b`).test(why)));
      if (mentioned.length) { dropped.push({ slot: meal.slot, dish: c.dish, check: 'why', missing: mentioned.map(m => m.name) }); return false; }
      return true;
    });
  }
  result.meals = (result.meals || []).filter(m => m.candidates.length);
  return dropped;
}

const FALLBACKS = (env.GEMINI_FALLBACKS || 'gemini-3.1-flash-lite,gemini-flash-lite-latest').split(',').map(x => x.trim()).filter(Boolean);
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function callGemini(model, body) {
  const ac = new AbortController(); const to = setTimeout(() => ac.abort(), 45000);
  try {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: 'POST', signal: ac.signal,
      headers: { 'content-type': 'application/json', 'x-goog-api-key': GEMINI_KEY },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: SYSTEM }] },
        contents: [{ role: 'user', parts: [{ text: buildUserPrompt(body) }] }],
        generationConfig: { responseMimeType: 'application/json', responseSchema: SCHEMA, maxOutputTokens: MAX_TOKENS, temperature: TEMPERATURE, thinkingConfig: { thinkingLevel: THINKING } }
      })
    });
    return { r, j: await r.json() };
  } catch (e) { return { r: { ok: false, status: 504 }, j: { error: { status: 'TIMEOUT', message: 'The AI took too long to answer.' } } }; }
  finally { clearTimeout(to); }
}

async function suggest(body) {
  const t0 = Date.now();
  // Try the main model (with one retry), then lighter fallbacks. Free-tier Gemini is often busy.
  const plan = [MODEL, MODEL, ...FALLBACKS];
  let r, j, used;
  for (let n = 0; n < plan.length; n++) {
    used = plan[n];
    ({ r, j } = await callGemini(used, body));
    if (r.ok) break;
    const st = j.error && j.error.status;
    const transient = r.status === 503 || r.status === 504 || r.status === 500 || st === 'UNAVAILABLE' || st === 'TIMEOUT' || st === 'RESOURCE_EXHAUSTED';
    console.warn(`[${used}] ${r.status} ${st}`);
    if (!transient) break;
    await sleep(n === 0 ? 1200 : 300);
  }
  if (!r.ok) {
    const status = j.error && j.error.status;
    const msg = status === 'RESOURCE_EXHAUSTED' ? 'The free daily AI limit is used up. Try again later.'
      : (status === 'UNAVAILABLE' || status === 'TIMEOUT') ? 'The AI is busy right now. Try again in a minute.'
      : 'Something went wrong with the AI. Try again.';
    const e = new Error(msg); e.status = r.status === 429 ? 429 : 503; throw e;
  }
  const cand = j.candidates && j.candidates[0];
  const finish = cand && cand.finishReason;
  if (finish === 'MAX_TOKENS') { const e = new Error('The answer was cut off. Try again.'); e.status = 502; throw e; }
  if (finish && finish !== 'STOP') { const e = new Error('The AI declined this request. Try different ingredients.'); e.status = 502; throw e; }
  const text = (cand.content.parts || []).map(p => p.text || '').join('');
  let data; try { data = JSON.parse(text); } catch (e) { const er = new Error('The AI returned an unreadable answer. Try again.'); er.status = 502; throw er; }
  const raw = JSON.parse(JSON.stringify(data));
  const dropped = groundCheck(data, body.ingredients, body.staples || []);
  const u = j.usageMetadata || {};
  return {
    result: data, raw, dropped,
    usage: { model: used, prompt_version: PROMPT_VERSION, effort: THINKING, temperature: TEMPERATURE, input_tokens: u.promptTokenCount || 0, output_tokens: (u.candidatesTokenCount || 0) + (u.thoughtsTokenCount || 0), thinking_tokens: u.thoughtsTokenCount || 0, latency_ms: Date.now() - t0, stop_reason: finish }
  };
}

// ---- tiny static server + API ----
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };
const server = http.createServer(async (req, res) => {
  if (req.method === 'POST' && req.url === '/api/suggest') {
    let raw = ''; req.on('data', c => { raw += c; if (raw.length > 1e5) req.destroy(); });
    req.on('end', async () => {
      try {
        const body = JSON.parse(raw);
        if (!Array.isArray(body.ingredients) || body.ingredients.length < 2) throw Object.assign(new Error('Add at least 2 ingredients.'), { status: 400 });
        const out = await suggest(body);
        res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(out));
      } catch (e) {
        console.error('suggest failed:', e.message);
        res.writeHead(e.status || 500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }
  const WEB = path.join(__dirname, 'web');
  const file = path.join(WEB, decodeURIComponent((req.url.split('?')[0] === '/' ? '/index.html' : req.url.split('?')[0])));
  if (!file.startsWith(WEB)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream' }); res.end(buf);
  });
});
server.on('error', e => {
  if (e.code === 'EADDRINUSE') { console.log(`Rasoi is already running. Open http://localhost:${PORT}`); process.exit(0); }
  throw e;
});
if (require.main === module) server.listen(PORT, () => console.log(`Rasoi running at http://localhost:${PORT}  (model: ${MODEL}, thinking: ${THINKING}, temperature: ${TEMPERATURE})`));

module.exports = { suggest, buildUserPrompt, groundCheck, SYSTEM, SCHEMA };
