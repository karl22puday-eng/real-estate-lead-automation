-- Real Estate Lead Automation & CRM System
-- Supabase / Postgres schema
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> Run

-- 1) Enable pgvector for RAG embeddings
create extension if not exists vector;

-- 2) LEADS — this is the "CRM" table (real-estate fields)
create table if not exists leads (
  id              uuid primary key default gen_random_uuid(),
  full_name       text not null,
  email           text not null,
  phone           text,
  message         text,                    -- raw inquiry from the form / lead ad
  intent          text,                    -- "buy" | "sell" | "rent" | "invest"
  property_type   text,                    -- house | condo | townhouse | land | multi-family
  location        text,                    -- target area / neighborhood / city
  budget          text,                    -- price range bucket from the form
  timeline        text,                    -- "asap" | "1-3 months" | "3-6 months" | "browsing"
  financing       text,                    -- "pre-approved" | "cash" | "need lender" | "researching"
  source          text default 'website',  -- website | facebook | instagram | referral ...
  score           int  default 0,          -- 0..100 from the scorer
  temperature     text default 'cold',     -- "hot" | "warm" | "cold"
  ai_summary      text,                    -- AI qualification summary
  stage           text default 'new',      -- new -> contacted -> showing -> offer -> closed/lost
  created_at      timestamptz default now()
);

-- Idempotency helper: fast lookups + dashboard sort
create index if not exists leads_email_idx on leads (email);
create index if not exists leads_score_idx on leads (score desc);

-- 3) KNOWLEDGE BASE — agency docs for RAG (about, buying, selling, financing, areas, faq)
create table if not exists kb_documents (
  id          uuid primary key default gen_random_uuid(),
  content     text not null,
  metadata    jsonb default '{}'::jsonb,
  embedding   vector(768)                  -- 768 = Gemini gemini-embedding-001 (outputDimensionality=768)
);

-- 4) Similarity search used by the RAG retrieval step (cosine distance)
create or replace function match_documents (
  query_embedding vector(768),
  match_count int default 5
) returns table (id uuid, content text, metadata jsonb, similarity float)
language sql stable as $$
  select id, content, metadata,
         1 - (kb_documents.embedding <=> query_embedding) as similarity
  from kb_documents
  order by kb_documents.embedding <=> query_embedding
  limit match_count;
$$;

-- 5) ROW LEVEL SECURITY (secure by default)
-- n8n uses the service_role key, which BYPASSES RLS -> inserts/reads still work.
-- The public dashboard uses the anon key, which RLS blocks by default.
alter table leads        enable row level security;
alter table kb_documents enable row level security;
-- No anon policies on leads/kb_documents => anon is fully blocked on the raw tables.

-- 6) SANITIZED PUBLIC VIEW for the dashboard (NO PII — no email/phone exposed)
-- The dashboard's anon key reads ONLY this view: first name, intent, location, score, etc.
create or replace view leads_public as
  select id,
         split_part(full_name, ' ', 1) as first_name,
         intent,
         property_type,
         location,
         score,
         temperature,
         stage,
         created_at
  from leads
  order by score desc, created_at desc;

grant select on leads_public to anon;

-- 7) DEDUP / IDEMPOTENCY support for lead intake
-- dedup_key = stable hash of email|message; UNIQUE so a re-submit upserts instead of duplicating.
alter table leads add column if not exists dedup_key text unique;

-- Existence check for the workflow's early dedup short-circuit. Returns exactly ONE row
-- {found boolean} so the n8n IF node always has data to branch on (an empty result set would
-- stop the flow). Lets duplicates skip the AI calls + notifications entirely.
create or replace function lead_exists(p_key text)
returns table(found boolean)
language sql stable as $$
  select exists(select 1 from leads where dedup_key = p_key);
$$;
</content>
