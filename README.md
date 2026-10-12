# Rasoi

Tell Rasoi what's in your kitchen and it suggests what to cook, using only what you have.

**Live:** _link coming_ · Built with plain HTML/JS, Supabase (auth, Postgres, edge function) and Gemini.

## How it works

```
Browser (web/) ──► Supabase Edge Function "suggest" ──► Gemini 3.5 Flash
      │                    │  checks login, 15/day limit,
      │                    │  reads the user's kitchen from the DB,
      │                    │  grounding check in code, saves the result
      └──────────► Supabase Postgres (row-level security: each user sees only their own rows)
```

- **Grounding:** the prompt says the ingredient list is complete ("absence means absent"), and code then drops any dish whose ingredients or reason mention something the user doesn't have.
- **Structured output:** Gemini must answer in a JSON schema: 3 candidate dishes per meal, or `possible: false` with the one ingredient that would unlock the most and the nearest dish.
- **Logged for evals:** every suggestion stores the model, thinking level, temperature, prompt version, tokens, latency, all candidates and what the grounding check removed.

## Folders

| Path | What |
| --- | --- |
| `web/` | The app. This folder is what gets hosted (Cloudflare Pages, output directory `web`). |
| `web/ingredients.js` | 225 Indian kitchen ingredients with category, default unit, allowed units and Hindi/regional aliases |
| `supabase/functions/suggest/` | The AI call, as a Supabase Edge Function |
| `supabase-setup.sql` | Tables, row-level security, sign-up trigger and the ingredient seed |
| `server.js` | Local preview server (`node server.js`, then http://localhost:8787) |

Secrets live in Supabase (Edge Functions → Secrets), never in this repo.
