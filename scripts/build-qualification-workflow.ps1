# Generates workflows/02_lead_qualification.json — the main real-estate lead brain.
# Re-run after edits:  pwsh ./scripts/build-qualification-workflow.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'workflows\02_lead_qualification.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'workflows') | Out-Null

# Set these before importing into n8n.
$SUPA   = 'https://YOUR-PROJECT.supabase.co'
$TG_CHAT = 'YOUR_TELEGRAM_CHAT_ID'

# ---------- Code: Validate & Normalize ----------
$jsValidate = @'
// Webhook payload is under .body (also works if Meta Lead Ads is mapped to the same shape)
const inb = ($input.first().json.body) || {};
const s = v => (v == null ? '' : String(v)).trim();
const email = s(inb.email).toLowerCase();
const full_name = s(inb.full_name);
const message = s(inb.message);
const intent = s(inb.intent).toLowerCase();
const errors = [];
if (!full_name) errors.push('full_name is required');
if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) errors.push('a valid email is required');
if (!intent) errors.push('intent is required');

// dedup key: stable 53-bit hash of email|message (no external deps)
function cyrb53(str, seed = 0) {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
  for (let i = 0, ch; i < str.length; i++) {
    ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
  h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
  h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
}

return [{ json: {
  valid: errors.length === 0,
  errors,
  full_name, email, message, intent,
  phone: s(inb.phone),
  property_type: s(inb.property_type),
  location: s(inb.location),
  budget: s(inb.budget),
  timeline: (s(inb.timeline) || 'browsing').toLowerCase(),
  financing: (s(inb.financing) || 'researching').toLowerCase(),
  source: s(inb.source) || 'website',
  dedup_key: cyrb53(email + '|' + message)
}}];
'@

# ---------- Code: Assemble Prompt (collapses RAG matches -> one grounded prompt) ----------
$jsAssemble = @'
// Normalize RAG output (HTTP node may spread the array into items, or return one array item)
const items = $input.all();
let matches = [];
if (items.length === 1 && Array.isArray(items[0].json)) matches = items[0].json;
else matches = items.map(i => i.json);
const context = matches.map(m => m && m.content).filter(Boolean).join('\n\n---\n\n')
  || '(no agency context retrieved)';

const lead = $('Validate').first().json;

const systemPrompt =
  'You are a lead qualification assistant for Crestview Realty, a residential real estate brokerage. ' +
  'Use ONLY the CONTEXT to answer anything about the agency, buying/selling process, areas, or fees; ' +
  'if the context does not cover it, say a Crestview agent will follow up. Return STRICT JSON only ' +
  '(no prose, no markdown) with exactly these keys: {"summary": string (<=2 sentences describing the ' +
  'lead and what they want), "financing_signal":"high|medium|low", "timeline_signal":"high|medium|low", ' +
  '"fit_signal":"high|medium|low", "reply": string (warm, helpful 2-3 sentence reply to the lead, ' +
  'grounded in CONTEXT, inviting them to a no-pressure consultation)}. ' +
  'financing_signal: pre-approved or cash buyer = high; needs a lender = medium; just researching = low. ' +
  'timeline_signal: asap or 1-3 months = high; 3-6 months = medium; just browsing = low. ' +
  'fit_signal: how well their intent, area, and budget match what Crestview serves per CONTEXT.';

const userPrompt =
  'CONTEXT:\n' + context + '\n\nLEAD:\n' +
  'Name: ' + lead.full_name + '\n' +
  'Intent: ' + (lead.intent || '(not given)') + '\n' +
  'Property type: ' + (lead.property_type || '(any)') + '\n' +
  'Area: ' + (lead.location || '(not given)') + '\n' +
  'Budget: ' + (lead.budget || '(not given)') + '\n' +
  'Timeline: ' + lead.timeline + '\n' +
  'Financing: ' + lead.financing + '\n' +
  'Message: ' + (lead.message || '(none)');

return [{ json: { systemPrompt, userPrompt } }];
'@

# ---------- Code: Parse + Score (real-estate weighting) ----------
$jsScore = @'
const lead = $('Validate').first().json;
let ai;
try {
  ai = JSON.parse($json.choices[0].message.content);
} catch (e) {
  ai = { summary: '(AI JSON parse failed)', financing_signal: 'low', timeline_signal: 'low',
         fit_signal: 'low', reply: 'Thanks for reaching out. A Crestview agent will be in touch shortly.' };
}
// Normalize the model's signal vocabulary (it is inconsistent about casing/synonyms).
const norm = v => {
  const x = String(v == null ? '' : v).trim().toLowerCase();
  if (['high', 'strong', 'hot', 'urgent', 'good'].includes(x)) return 'high';
  if (['medium', 'med', 'moderate', 'warm', 'mid'].includes(x)) return 'medium';
  return 'low';
};
const fin = norm(ai.financing_signal), tl = norm(ai.timeline_signal), fit = norm(ai.fit_signal);
// Deterministic real-estate score: financing readiness + timeline urgency + fit.
const F = { high: 40, medium: 22, low: 8 };   // financing readiness (strongest buy/sell signal)
const T = { high: 35, medium: 20, low: 8 };   // timeline urgency
const M = { high: 25, medium: 14, low: 4 };   // fit (intent / area / budget match)
const score = Math.min(100, F[fin] + T[tl] + M[fit]);
const temperature = score >= 70 ? 'hot' : score >= 40 ? 'warm' : 'cold';

return [{ json: {
  full_name: lead.full_name, email: lead.email, phone: lead.phone, message: lead.message,
  intent: lead.intent, property_type: lead.property_type, location: lead.location,
  budget: lead.budget, timeline: lead.timeline, financing: lead.financing,
  source: lead.source, dedup_key: lead.dedup_key,
  ai_summary: ai.summary, reply: ai.reply,
  financing_signal: fin, timeline_signal: tl, fit_signal: fit,
  score, temperature
}}];
'@

# ---------- Code: Check Dedup (normalize RPC result + carry lead fields forward) ----------
$jsCheckDedup = @'
const items = $input.all();
const row = (items.length === 1 && Array.isArray(items[0].json)) ? items[0].json[0] : items[0].json;
const found = !!(row && (row.found === true || row.found === 'true'));
const lead = $('Validate').first().json;
return [{ json: { ...lead, found } }];
'@

# ---------- expression bodies ----------
$embedBody = '={{ JSON.stringify({ model: "models/gemini-embedding-001", content: { parts: [ { text: $json.message } ] }, outputDimensionality: 768 }) }}'
$ragBody   = '={{ JSON.stringify({ query_embedding: "[" + $json.embedding.values.join(",") + "]", match_count: 5 }) }}'
$groqBody  = '={{ JSON.stringify({ model: "llama-3.3-70b-versatile", temperature: 0.2, response_format: { type: "json_object" }, messages: [ { role: "system", content: $json.systemPrompt }, { role: "user", content: $json.userPrompt } ] }) }}'
$insertBody = '={{ JSON.stringify({ full_name: $json.full_name, email: $json.email, phone: $json.phone, message: $json.message, intent: $json.intent, property_type: $json.property_type, location: $json.location, budget: $json.budget, timeline: $json.timeline, financing: $json.financing, source: $json.source, score: $json.score, temperature: $json.temperature, ai_summary: $json.ai_summary, dedup_key: $json.dedup_key }) }}'
$resp400Body = '={{ JSON.stringify({ ok: false, errors: $json.errors }) }}'
$resp200Body = '={{ JSON.stringify({ ok: true, score: $(''Parse and Score'').first().json.score, temperature: $(''Parse and Score'').first().json.temperature, reply: $(''Parse and Score'').first().json.reply }) }}'
$dedupBody   = '={{ JSON.stringify({ p_key: $json.dedup_key }) }}'
$respDupBody = '={{ JSON.stringify({ ok: true, duplicate: true, message: "We already have your inquiry on file. Your Crestview agent will be in touch shortly." }) }}'

# Telegram hot-lead alert text (plain text; pulls full data from Parse and Score)
$tgText = @'
=HOT LEAD ({{ $('Parse and Score').first().json.score }}/100) - {{ $('Parse and Score').first().json.intent }}
Name: {{ $('Parse and Score').first().json.full_name }}
Phone: {{ $('Parse and Score').first().json.phone || 'n/a' }} | Email: {{ $('Parse and Score').first().json.email }}
Area: {{ $('Parse and Score').first().json.location || 'n/a' }} | Budget: {{ $('Parse and Score').first().json.budget || 'n/a' }}
Timeline: {{ $('Parse and Score').first().json.timeline }} | Financing: {{ $('Parse and Score').first().json.financing }}

{{ $('Parse and Score').first().json.ai_summary }}
'@

# ---------- nodes ----------
$nodes = @(
  [ordered]@{ parameters=[ordered]@{ httpMethod='POST'; path='realestate-intake'; responseMode='responseNode'; options=@{} };
    id='n-webhook'; name='Webhook'; type='n8n-nodes-base.webhook'; typeVersion=2; position=@(220,400) },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsValidate };
    id='n-validate'; name='Validate'; type='n8n-nodes-base.code'; typeVersion=2; position=@(440,400) },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-valid'; leftValue='={{ $json.valid }}'; rightValue=$true;
          operator=[ordered]@{ type='boolean'; operation='true'; singleValue=$true } } );
        combinator='and' } };
    id='n-if'; name='IF Valid'; type='n8n-nodes-base.if'; typeVersion=2; position=@(660,400) },

  [ordered]@{ parameters=[ordered]@{ respondWith='json'; responseBody=$resp400Body; options=[ordered]@{ responseCode=400 } };
    id='n-resp400'; name='Respond 400'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(880,580) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url=($SUPA + '/rest/v1/rpc/lead_exists');
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendBody=$true; specifyBody='json'; jsonBody=$dedupBody; options=@{} };
    id='n-dedup'; name='Dedup Check'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(880,300);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsCheckDedup };
    id='n-checkdedup'; name='Check Dedup'; type='n8n-nodes-base.code'; typeVersion=2; position=@(1080,300) },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-exists'; leftValue='={{ $json.found }}'; rightValue=$true;
          operator=[ordered]@{ type='boolean'; operation='true'; singleValue=$true } } );
        combinator='and' } };
    id='n-ifexists'; name='IF Exists'; type='n8n-nodes-base.if'; typeVersion=2; position=@(1280,300) },

  [ordered]@{ parameters=[ordered]@{ respondWith='json'; responseBody=$respDupBody; options=[ordered]@{ responseCode=200 } };
    id='n-respdup'; name='Respond Duplicate'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(1280,520) },

  [ordered]@{ parameters=[ordered]@{ method='POST';
        url='https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent';
        authentication='genericCredentialType'; genericAuthType='httpHeaderAuth';
        sendBody=$true; specifyBody='json'; jsonBody=$embedBody; options=@{} };
    id='n-embed'; name='Embed Lead'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(1480,300);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url=($SUPA + '/rest/v1/rpc/match_documents');
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendBody=$true; specifyBody='json'; jsonBody=$ragBody; options=@{} };
    id='n-rag'; name='RAG Retrieve'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(1700,300);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsAssemble };
    id='n-assemble'; name='Assemble Prompt'; type='n8n-nodes-base.code'; typeVersion=2; position=@(1920,300) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url='https://api.groq.com/openai/v1/chat/completions';
        authentication='genericCredentialType'; genericAuthType='httpHeaderAuth';
        sendBody=$true; specifyBody='json'; jsonBody=$groqBody; options=@{} };
    id='n-groq'; name='Groq Agent'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(2140,300);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsScore };
    id='n-score'; name='Parse and Score'; type='n8n-nodes-base.code'; typeVersion=2; position=@(2360,300) },

  [ordered]@{ parameters=[ordered]@{ method='POST'; url=($SUPA + '/rest/v1/leads?on_conflict=dedup_key');
        authentication='predefinedCredentialType'; nodeCredentialType='supabaseApi';
        sendHeaders=$true; headerParameters=@{ parameters=@(
          [ordered]@{ name='Prefer'; value='resolution=merge-duplicates,return=representation' } ) };
        sendBody=$true; specifyBody='json'; jsonBody=$insertBody; options=@{} };
    id='n-insert'; name='Insert Lead'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(2560,300);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-hot'; leftValue='={{ $json.temperature }}'; rightValue='hot';
          operator=[ordered]@{ type='string'; operation='equals' } } );
        combinator='and' } };
    id='n-ifhot'; name='IF Hot'; type='n8n-nodes-base.if'; typeVersion=2; position=@(2780,300) },

  [ordered]@{ parameters=[ordered]@{ resource='message'; operation='sendMessage'; chatId=$TG_CHAT; text=$tgText; additionalFields=@{} };
    id='n-telegram'; name='Telegram Alert'; type='n8n-nodes-base.telegram'; typeVersion=1.2; position=@(3000,200);
    retryOnFail=$true; maxTries=2; waitBetweenTries=1500 },

  [ordered]@{ parameters=[ordered]@{ respondWith='json'; responseBody=$resp200Body; options=[ordered]@{ responseCode=200 } };
    id='n-resp200'; name='Respond OK'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(3240,300) }
)

# ---------- connections ----------
function One($to) { return @{ main = ,(,([ordered]@{ node=$to; type='main'; index=0 })) } }
$connections = [ordered]@{
  'Webhook'         = One 'Validate'
  'Validate'        = One 'IF Valid'
  'IF Valid'        = @{ main = @(
                          (,([ordered]@{ node='Dedup Check'; type='main'; index=0 })),
                          (,([ordered]@{ node='Respond 400'; type='main'; index=0 }))
                        ) }
  # Early dedup short-circuit: if the lead already exists, respond "duplicate" and skip AI+notify.
  'Dedup Check'     = One 'Check Dedup'
  'Check Dedup'     = One 'IF Exists'
  'IF Exists'       = @{ main = @(
                          (,([ordered]@{ node='Respond Duplicate'; type='main'; index=0 })),
                          (,([ordered]@{ node='Embed Lead';        type='main'; index=0 }))
                        ) }
  'Embed Lead'      = One 'RAG Retrieve'
  'RAG Retrieve'    = One 'Assemble Prompt'
  'Assemble Prompt' = One 'Groq Agent'
  'Groq Agent'      = One 'Parse and Score'
  # Linear: Insert is an UPSERT (merge-duplicates) so it ALWAYS returns the row -> downstream
  # always fires, for new leads and duplicates alike. Idempotent (same dedup_key -> same row).
  'Parse and Score' = One 'Insert Lead'
  'Insert Lead'     = One 'IF Hot'
  # Hot leads -> Telegram alert -> respond; others respond directly. Both converge on Respond OK.
  'IF Hot'          = @{ main = @(
                          (,([ordered]@{ node='Telegram Alert'; type='main'; index=0 })),
                          (,([ordered]@{ node='Respond OK';     type='main'; index=0 }))
                        ) }
  'Telegram Alert'  = One 'Respond OK'
}

$workflow = [ordered]@{
  name='02 Lead Qualification'; nodes=$nodes; connections=$connections;
  active=$false; settings=@{ executionOrder='v1' }
}

$json = $workflow | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($out, $json)
Write-Output "Wrote $out"
$null = Get-Content $out -Raw | ConvertFrom-Json
Write-Output "Valid JSON. Nodes: $($nodes.Count)"
