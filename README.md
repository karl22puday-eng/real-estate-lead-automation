# Real Estate Lead Automation & CRM System

> Capture a real-estate lead — from a **web form or a Meta (Facebook/Instagram) Lead Ad** —
> qualify it with a **RAG-grounded AI agent**, score it **0–100**, store it in a **Supabase
> CRM**, and auto-route **hot buyers/sellers to the agent's phone via Telegram** — all
> orchestrated in **n8n**, on a 100% free stack.

<p>
  <img alt="n8n" src="https://img.shields.io/badge/n8n-workflow_automation-EA4B71" />
  <img alt="Meta" src="https://img.shields.io/badge/Meta_Lead_Ads-FB_%2F_IG-0866FF" />
  <img alt="Groq" src="https://img.shields.io/badge/Groq-Llama_3.3_70B-F55036" />
  <img alt="Gemini" src="https://img.shields.io/badge/Gemini-embeddings_768d-4285F4" />
  <img alt="Supabase" src="https://img.shields.io/badge/Supabase-pgvector-3ECF8E" />
  <img alt="RAG" src="https://img.shields.io/badge/RAG-vector_search-8b7cff" />
</p>

**🔗 Live demo** *(after deploy — see setup)*
- **Capture form:** `https://<your-user>.github.io/real-estate-lead-automation/`
- **Lead dashboard:** `https://<your-user>.github.io/real-estate-lead-automation/dashboard.html`

A lead submits the form (or a Facebook lead ad) → it's qualified, scored, stored, and
surfaced on the agent dashboard in seconds.

---

## ✨ What it does

A residential brokerage (**Crestview Realty**) needs to handle inbound leads instantly,
because in real estate the first agent to respond usually wins the client. This system:

1. **Captures** a lead from a public web form **or a Meta Lead Ad** (Facebook/Instagram) —
   both feed the same pipeline. *(See [`docs/META_LEAD_ADS.md`](docs/META_LEAD_ADS.md).)*
2. **Validates** the input at the edge and **deduplicates** it (idempotent — a double
   submit never creates a second lead or a second alert).
3. **Retrieves** relevant agency knowledge via **RAG** (vector search over embedded docs:
   buying/selling process, financing, areas, fees) so the AI replies with *real* info.
4. **Qualifies** the lead with an LLM agent that emits **structured JSON signals**
   (financing readiness / timeline / fit).
5. **Scores** the lead **0–100 deterministically in code** (the model only emits signals;
   the math is auditable) and labels it `hot` / `warm` / `cold`.
6. **Stores** it in a Supabase CRM via an idempotent upsert, tagged by **channel**
   (website / facebook / instagram).
7. **Routes** hot leads to the agent's **Telegram** instantly, and returns a friendly,
   grounded reply to the visitor.
8. **Displays** everything on a live, read-only dashboard sorted by score.

---

## 🏗 Architecture

```
  Lead source                         n8n workflow (realestate-intake webhook)                    Agent
     │                                                                                              ▲
 ┌───┴─────────┐   POST    ┌──────────────────────────────────────────────────────────┐           │
 │ Web form    │ ───JSON──►│  Validate ─► Dedup check ─► [exists?] ─► (short-circuit)   │  🔥 Telegram│
 │ (Pages)     │◄─reply────│      │                          │                          │   hot alert │
 ├─────────────┤           │      ▼ new lead                 ▼                          │────────────►│
 │ Meta Lead   │ ──Graph──►│  Embed (Gemini) ─► RAG match_documents (pgvector)          │            │
 │ Ad (FB/IG)  │   API     │      └─► Groq agent (JSON) ─► Score 0–100 ─► Upsert lead ──┼─► hot? ─────┘
 └─────────────┘           └───────────────────────────────────────────┬──────────────┘
 ┌──────────┐   reads (anon, RLS)                                       ▼
 │Dashboard │◄───────────────────────────────  Supabase  ◄──── leads (CRM) + kb_documents (vectors)
 │ (Pages)  │       leads_public view           (Postgres)
 └──────────┘
```

---

## 🧱 Tech stack (100% free, no credit card)

| Layer | Tool | Role |
|---|---|---|
| Orchestration | **n8n Cloud** | Webhook intake, branching, retries, the whole pipeline |
| Ad lead source | **Meta Lead Ads** | Facebook/Instagram lead-gen forms → same pipeline |
| Reasoning LLM | **Groq — Llama 3.3 70B** | Lead qualification, structured-JSON output |
| Embeddings | **Google Gemini — `gemini-embedding-001`** (768-dim) | Vectorizing docs + lead messages for RAG |
| Database / CRM | **Supabase (Postgres)** | Leads table, pipeline stages |
| Vector store | **Supabase pgvector** | Cosine similarity retrieval (`match_documents`) |
| Frontend | **GitHub Pages** | Capture form + dashboard (static, deployed via Actions) |
| Notifications | **Telegram Bot** | Real-time hot-lead alerts to the agent |

---

## 🔬 How it works

### Deterministic scoring tuned for real estate
The LLM only emits three signals; the score is computed in code, so every number is
reproducible and defensible. Weighting reflects what actually predicts a closing:

| Signal | high | medium | low | What it measures |
|---|---|---|---|---|
| **Financing** | 40 | 22 | 8 | pre-approved / cash → ready to transact |
| **Timeline** | 35 | 20 | 8 | ASAP / 1–3 mo → urgency |
| **Fit** | 25 | 14 | 4 | intent + area + budget match our market |

`score = min(100, financing + timeline + fit)` → `hot ≥ 70`, `warm ≥ 40`, else `cold`.
A pre-approved buyer who wants to move ASAP in a covered area scores hot and pings the
agent immediately; a "just browsing / just researching" lead is captured but not escalated.

### RAG grounding
The lead's message is embedded (768-dim) and matched against agency docs (`kb/`) stored as
`vector(768)` in pgvector via a cosine `match_documents` RPC. The top-5 chunks are injected
as **CONTEXT**, and the agent answers *only* from that context — so replies cite the real
buying process, financing facts, areas served, and fees.

### One pipeline, many sources
Website form submissions and Meta Lead Ads are both normalized to the same intake shape, so
they share one validation/scoring/routing path. Adding Instagram, a portal, or a different
CRM is a mapping change, not a new system.

### Idempotency by design
Every lead gets a stable `dedup_key` (hash of email + message). An **early existence check**
short-circuits duplicates *before* any AI calls run — so a re-submit returns in ~1s with no
embedding cost, no second row, and no duplicate alert. The final write is an `on_conflict`
**upsert** as a second line of defense against races.

### Security
- Secrets live in **n8n credentials** / a gitignored `.env` — never in code.
- The database uses **Row-Level Security**; the public dashboard's anon key can read **only**
  a **sanitized view** (`leads_public`) exposing first name, intent, area, score, temperature,
  stage, and date — **no email or phone**.

---

## 📂 Repository structure

```
real-estate-lead-automation/
├─ frontend/
│  ├─ index.html              # Capture form (POSTs to the n8n webhook)
│  └─ dashboard.html          # Read-only CRM dashboard (Supabase anon + RLS)
├─ workflows/
│  ├─ 01_kb_ingestion.json    # One-time RAG ingestion (chunk → embed → store)
│  └─ 02_lead_qualification.json  # The main brain (17 nodes)
├─ scripts/
│  ├─ build-ingestion-workflow.ps1     # Reproducibly generate the workflow JSON
│  └─ build-qualification-workflow.ps1  # …from source, instead of hand-editing
├─ db/
│  └─ schema.sql              # pgvector, leads, RLS, sanitized view, RPCs
├─ kb/                        # Agency docs (about, buying, selling, financing, areas, faq)
├─ docs/
│  ├─ BUILD_GUIDE.md          # Setup walkthrough
│  └─ META_LEAD_ADS.md        # Connect Facebook/Instagram Lead Ads to the same pipeline
└─ .github/workflows/
   └─ deploy-pages.yml        # CI: deploy the frontend to GitHub Pages
```

> The n8n workflows are **generated by scripts**, not hand-authored — so the source of
> truth (KB docs, node config) lives in version control and the JSON is reproducible.

---

## 🚀 Run it yourself

1. **Supabase** — create a project, run [`db/schema.sql`](db/schema.sql) in the SQL editor
   (enables pgvector + creates tables, RLS, the sanitized view, and RPCs).
2. **Keys** — copy [`.env.example`](.env.example) → `.env` and fill in Supabase, Groq,
   Gemini, and Telegram values.
3. **Build the workflows** — set your Supabase URL (and Telegram chat id) at the top of the
   two scripts in [`scripts/`](scripts/), run them, then import the generated
   [`workflows/`](workflows/) JSON into n8n and attach credentials.
4. **Knowledge base** — run `01_kb_ingestion` once to embed the `kb/` docs.
5. **Frontend** — point the webhook URL in `frontend/index.html` and the Supabase URL +
   anon key in `frontend/dashboard.html` at your instances; GitHub Pages auto-deploys via
   the included Action.
6. **(Optional) Meta Lead Ads** — follow [`docs/META_LEAD_ADS.md`](docs/META_LEAD_ADS.md)
   to feed Facebook/Instagram lead ads into the same pipeline.

Full details in [`docs/BUILD_GUIDE.md`](docs/BUILD_GUIDE.md).

---

## 🧠 Engineering decisions & what I learned

- **Score what predicts a close.** Generic "budget/urgency/fit" misses what matters in real
  estate. Financing readiness (pre-approved/cash) is the strongest signal a lead will
  actually transact, so it carries the most weight — the scoring is tuned to the domain, not
  copy-pasted.
- **One pipeline, multiple sources.** Website form and Meta Lead Ads normalize to the same
  intake shape, so validation, scoring, and routing are written once. New channels are a
  mapping, not a rebuild.
- **The LLM emits signals; code computes the score.** Letting a model output a raw 0–100 is
  unauditable and drifts. Constraining it to `high/medium/low` and scoring in code makes
  every result explainable — and survives inconsistent model casing (normalized in code).
- **Raw HTTP nodes over pre-built integrations.** Using `HTTP Request` for Gemini, Groq, and
  Supabase gives full control — critical for the pgvector quirk where embeddings insert as a
  `'[...]'` string, and for forcing Groq's JSON mode.
- **Idempotency or duplicate alerts.** Real-estate leads often submit twice. An early dedup
  short-circuit + an upsert on a natural key means no duplicate rows, no double agent pings.
- **Sanitized view > exposing the table.** The dashboard's anon key reads a dedicated
  PII-free view — least privilege by construction, no lead emails/phones ever shipped to the
  browser.

---

## 🗺 Roadmap

- [ ] Auto first-touch SMS/email to the lead (Twilio / Gmail).
- [ ] Drip nurture sequence for long-cycle ("browsing") leads.
- [ ] Lead lifecycle automation (stage transitions: `new → contacted → showing → offer → closed/lost`).
- [ ] Round-robin routing to multiple agents by area/price band.
- [ ] Native Meta Lead Ads trigger workflow (`03_meta_lead_intake`) committed alongside.

---

*Built with a 100% free, no-subscription stack — n8n · Meta Lead Ads · Groq · Gemini ·
Supabase · GitHub Pages · Telegram.*
</content>
