# Generates workflows/03_meta_lead_intake.json — Facebook/Instagram Lead Ads -> intake pipeline.
# Receives Meta's lead webhook, fetches the full lead via the Graph API, maps it to the
# standard intake shape, and forwards it to the existing realestate-intake webhook so it
# runs through the SAME validate/dedup/RAG/score/route pipeline (single source of truth).
# Re-run after edits:  pwsh ./scripts/build-meta-lead-workflow.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'workflows\03_meta_lead_intake.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'workflows') | Out-Null

# Set these before importing into n8n.
$INTAKE = 'https://karlchretien.app.n8n.cloud/webhook/realestate-intake'  # your production intake webhook
$VERIFY = 'YOUR_VERIFY_TOKEN'   # arbitrary string; must match the token you enter in Meta's webhook setup

# ---------- Code: Extract Lead IDs (Meta batches leadgen notifications) ----------
$jsExtract = @'
// Meta POSTs { object:'page', entry:[ { changes:[ { field:'leadgen', value:{ leadgen_id, form_id, page_id } } ] } ] }
const body = ($input.first().json.body) || {};
const out = [];
for (const e of (body.entry || [])) {
  for (const c of (e.changes || [])) {
    const v = (c && c.value) || {};
    if (v.leadgen_id) out.push({ json: {
      leadgen_id: String(v.leadgen_id),
      form_id: v.form_id || null,
      page_id: v.page_id || null
    }});
  }
}
// Empty array => no leadgen_id present (e.g. a non-lead event); branch stops cleanly.
return out;
'@

# ---------- Code: Map Meta Fields (field_data -> standard intake shape) ----------
$jsMap = @'
// Graph API returned { id, created_time, field_data:[{name,values}] } for this lead.
const fd = {};
for (const f of ($json.field_data || [])) fd[f.name] = (f.values && f.values[0]) || '';
const lc = s => String(s || '').trim().toLowerCase();
const timelineMap = {
  'asap': 'asap', 'immediately': 'asap',
  '1-3 months': '1-3 months', '3-6 months': '3-6 months',
  'just browsing': 'browsing', 'browsing': 'browsing'
};
const finMap = {
  'pre-approved': 'pre-approved', 'cash': 'cash', 'cash buyer': 'cash',
  'need a lender': 'need lender', 'just researching': 'researching'
};
return [{ json: {
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
}}];
'@

# ---------- expression bodies ----------
$challengeBody = '={{ $json.query["hub.challenge"] }}'
$graphUrl      = '=https://graph.facebook.com/v19.0/{{ $json.leadgen_id }}?fields=field_data,created_time'
$forwardBody   = '={{ JSON.stringify({ full_name: $json.full_name, email: $json.email, phone: $json.phone, intent: $json.intent, property_type: $json.property_type, location: $json.location, budget: $json.budget, timeline: $json.timeline, financing: $json.financing, message: $json.message, source: $json.source }) }}'

# ---------- nodes ----------
$nodes = @(
  # --- Verification handshake (Meta sends a GET once when you register the webhook) ---
  [ordered]@{ parameters=[ordered]@{ httpMethod='GET'; path='meta-lead'; responseMode='responseNode'; options=@{} };
    id='n-verify'; name='Webhook Verify (GET)'; type='n8n-nodes-base.webhook'; typeVersion=2; position=@(220,200) },

  [ordered]@{ parameters=[ordered]@{ conditions=[ordered]@{
        options=[ordered]@{ caseSensitive=$true; leftValue=''; typeValidation='loose' };
        conditions=@( [ordered]@{ id='cond-token'; leftValue='={{ $json.query["hub.verify_token"] }}'; rightValue=$VERIFY;
          operator=[ordered]@{ type='string'; operation='equals' } } );
        combinator='and' } };
    id='n-iftoken'; name='IF Token Valid'; type='n8n-nodes-base.if'; typeVersion=2; position=@(440,200) },

  [ordered]@{ parameters=[ordered]@{ respondWith='text'; responseBody=$challengeBody; options=@{} };
    id='n-challenge'; name='Respond Challenge'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(680,120) },

  [ordered]@{ parameters=[ordered]@{ respondWith='text'; responseBody='forbidden'; options=[ordered]@{ responseCode=403 } };
    id='n-forbidden'; name='Respond Forbidden'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(680,280) },

  # --- Lead delivery (Meta POSTs each new lead notification) ---
  [ordered]@{ parameters=[ordered]@{ httpMethod='POST'; path='meta-lead'; responseMode='responseNode'; options=@{} };
    id='n-lead'; name='Webhook Lead (POST)'; type='n8n-nodes-base.webhook'; typeVersion=2; position=@(220,460) },

  # Ack Meta immediately (it requires a fast 200 or it retries / disables the subscription).
  [ordered]@{ parameters=[ordered]@{ respondWith='text'; responseBody='EVENT_RECEIVED'; options=[ordered]@{ responseCode=200 } };
    id='n-ack'; name='Respond 200'; type='n8n-nodes-base.respondToWebhook'; typeVersion=1; position=@(440,360) },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForAllItems'; jsCode=$jsExtract };
    id='n-extract'; name='Extract Lead IDs'; type='n8n-nodes-base.code'; typeVersion=2; position=@(440,560) },

  # Fetch the lead's answers from the Graph API. Credential: Header Auth -> Authorization: Bearer <PAGE_TOKEN>.
  [ordered]@{ parameters=[ordered]@{ method='GET'; url=$graphUrl;
        authentication='genericCredentialType'; genericAuthType='httpHeaderAuth'; options=@{} };
    id='n-fetch'; name='Fetch Lead (Graph API)'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(660,560);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 },

  [ordered]@{ parameters=[ordered]@{ mode='runOnceForEachItem'; jsCode=$jsMap };
    id='n-map'; name='Map Meta Fields'; type='n8n-nodes-base.code'; typeVersion=2; position=@(880,560) },

  # Forward into the existing pipeline (same webhook the web form uses).
  [ordered]@{ parameters=[ordered]@{ method='POST'; url=$INTAKE;
        sendBody=$true; specifyBody='json'; jsonBody=$forwardBody; options=@{} };
    id='n-forward'; name='Forward to Intake'; type='n8n-nodes-base.httpRequest'; typeVersion=4.2; position=@(1100,560);
    retryOnFail=$true; maxTries=3; waitBetweenTries=2000 }
)

# ---------- connections ----------
function One($to) { return @{ main = ,(,([ordered]@{ node=$to; type='main'; index=0 })) } }
$connections = [ordered]@{
  'Webhook Verify (GET)' = One 'IF Token Valid'
  'IF Token Valid'       = @{ main = @(
                              (,([ordered]@{ node='Respond Challenge'; type='main'; index=0 })),
                              (,([ordered]@{ node='Respond Forbidden'; type='main'; index=0 }))
                            ) }
  # POST branch: ack Meta immediately AND process the lead in parallel.
  'Webhook Lead (POST)'  = @{ main = @(
                              (,(
                                [ordered]@{ node='Respond 200';      type='main'; index=0 },
                                [ordered]@{ node='Extract Lead IDs'; type='main'; index=0 }
                              ))
                            ) }
  'Extract Lead IDs'     = One 'Fetch Lead (Graph API)'
  'Fetch Lead (Graph API)' = One 'Map Meta Fields'
  'Map Meta Fields'      = One 'Forward to Intake'
}

$workflow = [ordered]@{
  name='03 Meta Lead Intake'; nodes=$nodes; connections=$connections;
  active=$false; settings=@{ executionOrder='v1' }
}

$json = $workflow | ConvertTo-Json -Depth 40
[System.IO.File]::WriteAllText($out, $json)
Write-Output "Wrote $out"
$null = Get-Content $out -Raw | ConvertFrom-Json
Write-Output "Valid JSON. Nodes: $($nodes.Count)"
