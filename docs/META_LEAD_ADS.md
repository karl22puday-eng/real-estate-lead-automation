# Connecting Meta (Facebook & Instagram) Lead Ads

The system captures leads from a **web form** out of the box. This guide shows how to feed
**Meta Lead Ads** (Facebook / Instagram lead-gen forms) into the *same* qualification
pipeline, so an ad lead gets validated, deduped, AI-qualified, scored, stored, and routed
exactly like a website lead — no separate flow to maintain.

> Why this matters: in lead-gen, **speed-to-lead** wins. Meta delivers the lead the moment
> someone submits the in-app form; this pipeline turns that into a qualified, scored CRM
> record and an instant alert in seconds — instead of an agent checking Ads Manager hours
> later.

---

## How it works

```
Facebook / Instagram Lead Ad
        │  (user submits the native lead form)
        ▼
Meta Lead Ads webhook  ──►  n8n "Facebook Lead Ads" Trigger
        │                         │ pulls full lead field_data via Graph API
        │                         ▼
        │                   Map fields → the standard intake shape
        │                         ▼
        └──────────────►  same pipeline: Validate → Dedup → Embed → RAG →
                          Groq qualify → Score → Supabase upsert → hot? Telegram
```

There are **two ways** to wire it. Option A is the cleanest for production.

---

## Option A — n8n's built-in Facebook Lead Ads Trigger (recommended)

n8n ships a native **Facebook Lead Ads Trigger** node that subscribes to the lead webhook
and fetches each new lead automatically.

1. **Meta setup (one time)**
   - Create a Meta app at <https://developers.facebook.com> → add the **Webhooks** and
     **Lead Ads** products.
   - Connect the Facebook **Page** that runs the ads and generate a **long-lived Page
     access token** with `leads_retrieval`, `pages_show_list`, and
     `pages_read_engagement` permissions.
   - (Store `META_APP_ID`, `META_APP_SECRET`, `META_PAGE_ACCESS_TOKEN` in n8n credentials
     — see `.env.example`.)

2. **In n8n** — create a second workflow `03_meta_lead_intake`:
   - **Facebook Lead Ads Trigger** node → authenticate with the Page, select the Page and
     (optionally) the specific form. n8n auto-registers the webhook subscription.
   - **Set / Code node — map Meta fields to the intake shape.** Meta returns
     `field_data` as an array of `{name, values}`. Map them to the fields this pipeline
     expects (see the mapping table below) and wrap them under `body` so the existing
     `Validate` node reads them unchanged.
   - Then either: call the existing intake webhook via an **HTTP Request** node, or copy
     the qualification nodes into this workflow. Calling the webhook keeps a single source
     of truth.

3. **Done.** Submit a Meta **test lead** (Meta's Lead Ads Testing Tool) and watch it flow
   through to the dashboard + Telegram.

---

## Option B — Meta webhook → n8n Webhook node (no native node)

If you'd rather not use the native node (or you're on a plan without it):

1. Add a **Webhook** node in n8n with a path like `meta-lead`.
2. In the Meta app's **Webhooks** product, subscribe the Page to the `leadgen` field and
   point the callback URL at your n8n webhook. Handle Meta's verification challenge
   (echo `hub.challenge`) — a small IF/Respond branch does this.
3. Meta's webhook payload contains a `leadgen_id`, **not** the answers. Add an **HTTP
   Request** node to call the Graph API:
   `GET https://graph.facebook.com/v19.0/{leadgen_id}?access_token={PAGE_TOKEN}`
   which returns the `field_data`.
4. Map `field_data` → intake shape (table below) → POST to the `realestate-intake`
   webhook, or continue inline into the qualification nodes.

---

## Field mapping (Meta → this pipeline)

Configure your Meta lead form's questions so they map cleanly. The pipeline expects:

| Pipeline field  | Meta lead-form question (example)        | Notes |
|-----------------|------------------------------------------|-------|
| `full_name`     | Full name                                | required |
| `email`         | Email                                    | required, validated |
| `phone`         | Phone number                             | Meta often prefills this |
| `intent`        | "Are you looking to…" (Buy/Sell/Rent/Invest) | required; lowercase it in the map |
| `property_type` | "Property type"                          | optional |
| `location`      | "Preferred area / city"                  | optional |
| `budget`        | "Budget range"                           | optional |
| `timeline`      | "When are you looking to move?"          | map to `asap` / `1-3 months` / `3-6 months` / `browsing` |
| `financing`     | "Financing status"                       | map to `pre-approved` / `cash` / `need lender` / `researching` |
| `message`       | "Anything else we should know?"          | free text; used for RAG + dedup |
| `source`        | — (set in the map)                       | set to `"facebook"` or `"instagram"` so the CRM shows the channel |

**Example map (Code node) — turns Meta `field_data` into the intake `body`:**

```js
// $json.field_data = [{ name: 'email', values: ['a@b.com'] }, ...]
const fd = {};
for (const f of ($json.field_data || [])) fd[f.name] = (f.values && f.values[0]) || '';

const timelineMap = {
  'asap': 'asap', 'immediately': 'asap',
  '1-3 months': '1-3 months', '3-6 months': '3-6 months',
  'just browsing': 'browsing', 'browsing': 'browsing'
};
const finMap = {
  'pre-approved': 'pre-approved', 'cash': 'cash', 'cash buyer': 'cash',
  'need a lender': 'need lender', 'just researching': 'researching'
};
const lc = s => String(s || '').trim().toLowerCase();

return [{ json: { body: {
  full_name: fd.full_name || fd.name || '',
  email: fd.email || '',
  phone: fd.phone_number || fd.phone || '',
  intent: lc(fd.intent),
  property_type: fd.property_type || '',
  location: fd.location || fd.city || '',
  budget: fd.budget || '',
  timeline: timelineMap[lc(fd.timeline)] || 'browsing',
  financing: finMap[lc(fd.financing)] || 'researching',
  message: fd.message || fd.notes || '',
  source: 'facebook'
} } }];
```

Because every Meta lead is wrapped under `body` with the same field names, the existing
`Validate` node, dedup, scoring, and routing all work **unchanged**.

---

## Notes & gotchas
- **Same-day token:** Page access tokens expire — use a **long-lived** token and refresh
  before expiry, or the trigger silently stops receiving leads.
- **Dedup still applies:** the pipeline dedups on `email|message`, so a lead who submits
  both the web form and a Meta ad with the same message won't be double-counted.
- **CRM source field:** setting `source: 'facebook'` lets you report lead volume and
  quality **by channel** straight from the `leads` table.
- **Swap the CRM:** the same mapped payload can be POSTed to GoHighLevel, HubSpot, or any
  CRM's contact API instead of (or in addition to) Supabase — only the final write node
  changes.
