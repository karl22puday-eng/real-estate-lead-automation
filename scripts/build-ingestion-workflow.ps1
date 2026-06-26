# Generates workflows/01_kb_ingestion.json from the kb/*.md files.
# Re-run after editing the KB docs:  pwsh ./scripts/build-ingestion-workflow.ps1
# Embeds doc text inline because n8n Cloud cannot read local files.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$kb   = Join-Path $root 'kb'
$out  = Join-Path $root 'workflows\01_kb_ingestion.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'workflows') | Out-Null

# Set this to your Supabase project URL before importing into n8n.
$SUPA = 'https://rwarsojufsnceswxwwzk.supabase.co'

# --- read KB docs (ReadAllText => clean UTF-8 string, no ETS NoteProperties) ---
function Read-Doc($name) { return [System.IO.File]::ReadAllText((Join-Path $kb $name), [System.Text.Encoding]::UTF8) }
$docs = @(
  [ordered]@{ source = 'about.md';     text = (Read-Doc 'about.md')     },
  [ordered]@{ source = 'buying.md';    text = (Read-Doc 'buying.md')    },
  [ordered]@{ source = 'selling.md';   text = (Read-Doc 'selling.md')   },
  [ordered]@{ source = 'financing.md'; text = (Read-Doc 'financing.md') },
  [ordered]@{ source = 'areas.md';     text = (Read-Doc 'areas.md')     },
  [ordered]@{ source = 'faq.md';       text = (Read-Doc 'faq.md')       }
)
$docsJson = $docs | ConvertTo-Json -Depth 5

# --- Code node: chunk docs (docs injected as a JSON literal == valid JS) ---
$chunkBody = @'

const MAX = 600; // target chunk size in characters
const items = [];
for (const doc of docs) {
  const paras = doc.text.split(/\n\s*\n/).map(p => p.trim()).filter(Boolean);
  let buf = '';
  for (const p of paras) {
    const candidate = buf ? buf + '\n\n' + p : p;
    if (candidate.length > MAX && buf) {
      items.push({ json: { content: buf, source: doc.source } });
      buf = p;
    } else {
      buf = candidate;
    }
  }
  if (buf) items.push({ json: { content: buf, source: doc.source } });
}
return items;
'@
$jsChunk = 'const docs = ' + $docsJson + ';' + "`n" + $chunkBody

# --- Code node: build the row to insert (runs ONCE PER ITEM) ---
$jsBuildRow = @'
// Runs once per item. $json = the Gemini embedding response for this chunk.
const vals = $json.embedding && $json.embedding.values;
if (!Array.isArray(vals) || vals.length !== 768) {
  throw new Error('Embedding missing or wrong dimension: ' + (vals ? vals.length : 'none'));
}
const src = $('Chunk Docs').item.json;     // the matching chunk (paired item)
return {
  content: src.content,
  metadata: { source: src.source },
  embedding: '[' + vals.join(',') + ']'     // pgvector accepts the bracketed string form
};
'@

$geminiBody   = '={{ JSON.stringify({ model: "models/gemini-embedding-001", content: { parts: [ { text: $json.content } ] }, outputDimensionality: 768 }) }}'
$supabaseBody = '={{ JSON.stringify({ content: $json.content, metadata: $json.metadata, embedding: $json.embedding }) }}'

# --- nodes ---
$nodes = @(
  [ordered]@{
    parameters = @{}
    id = 'node-trigger'
    name = 'Manual Trigger'
    type = 'n8n-nodes-base.manualTrigger'
    typeVersion = 1
    position = @(240, 300)
  },
  [ordered]@{
    parameters = [ordered]@{ mode = 'runOnceForAllItems'; jsCode = $jsChunk }
    id = 'node-chunk'
    name = 'Chunk Docs'
    type = 'n8n-nodes-base.code'
    typeVersion = 2
    position = @(460, 300)
  },
  [ordered]@{
    parameters = [ordered]@{
      method = 'POST'
      url = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent'
      authentication = 'genericCredentialType'
      genericAuthType = 'httpHeaderAuth'
      sendBody = $true
      specifyBody = 'json'
      jsonBody = $geminiBody
      options = @{}
    }
    id = 'node-embed'
    name = 'Embed (Gemini)'
    type = 'n8n-nodes-base.httpRequest'
    typeVersion = 4.2
    position = @(680, 300)
    retryOnFail = $true
    maxTries = 3
    waitBetweenTries = 2000
  },
  [ordered]@{
    parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = $jsBuildRow }
    id = 'node-buildrow'
    name = 'Build Row'
    type = 'n8n-nodes-base.code'
    typeVersion = 2
    position = @(900, 300)
  },
  [ordered]@{
    parameters = [ordered]@{
      method = 'POST'
      url = ($SUPA + '/rest/v1/kb_documents')
      authentication = 'predefinedCredentialType'
      nodeCredentialType = 'supabaseApi'
      sendHeaders = $true
      headerParameters = @{ parameters = @( [ordered]@{ name = 'Prefer'; value = 'return=minimal' } ) }
      sendBody = $true
      specifyBody = 'json'
      jsonBody = $supabaseBody
      options = @{}
    }
    id = 'node-insert'
    name = 'Insert (Supabase)'
    type = 'n8n-nodes-base.httpRequest'
    typeVersion = 4.2
    position = @(1120, 300)
    retryOnFail = $true
    maxTries = 3
    waitBetweenTries = 2000
  }
)

# --- connections (explicit nesting; unary comma keeps single-element arrays as arrays) ---
function Conn($to) { return @{ main = ,(,([ordered]@{ node = $to; type = 'main'; index = 0 })) } }
$connections = [ordered]@{
  'Manual Trigger'   = Conn 'Chunk Docs'
  'Chunk Docs'       = Conn 'Embed (Gemini)'
  'Embed (Gemini)'   = Conn 'Build Row'
  'Build Row'        = Conn 'Insert (Supabase)'
}

$workflow = [ordered]@{
  name = '01 KB Ingestion'
  nodes = $nodes
  connections = $connections
  active = $false
  settings = @{ executionOrder = 'v1' }
}

$json = $workflow | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($out, $json)
Write-Output "Wrote $out"
Write-Output "Validating JSON..."
$null = Get-Content $out -Raw | ConvertFrom-Json
Write-Output "Valid JSON. Nodes: $($nodes.Count)"
