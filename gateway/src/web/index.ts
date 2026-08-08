// index.ts (web) — две inline-страницы без сборщика: чистый чат-ассистент и
// админка (аудит перехватов + стоимость + настройки). String.raw, без
// template-literal'ов в клиентском коде.

export const CHAT_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ассистент</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; }
  header { padding:14px 18px; border-bottom:1px solid #232734; font-weight:600; }
  #log { max-width:820px; margin:0 auto; padding:18px; }
  .msg { padding:10px 14px; border-radius:10px; margin:10px 0; white-space:pre-wrap; word-wrap:break-word; }
  .user { background:#1b2230; }
  .bot { background:#161a22; border:1px solid #232734; }
  .warn { background:#2a1d1d; border:1px solid #5a2b2b; color:#ffb4b4; }
  form { position:sticky; bottom:0; background:#0f1115; max-width:820px; margin:0 auto; padding:12px 18px; display:flex; gap:8px; border-top:1px solid #232734; }
  textarea { flex:1; resize:none; background:#161a22; color:#e6e6e6; border:1px solid #2b3140; border-radius:8px; padding:10px; font:inherit; }
  button { background:#3b82f6; color:#fff; border:0; border-radius:8px; padding:0 18px; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
</style></head><body>
<header>Ассистент</header>
<div id="log"></div>
<form id="f"><textarea id="t" rows="2" placeholder="Спроси что-нибудь…"></textarea><button id="b">→</button></form>
<script>
  var log = document.getElementById('log'), f = document.getElementById('f'), t = document.getElementById('t'), b = document.getElementById('b');
  function add(cls, text) { var d = document.createElement('div'); d.className = 'msg ' + cls; d.textContent = text; log.appendChild(d); window.scrollTo(0, document.body.scrollHeight); return d; }
  f.addEventListener('submit', function(e) {
    e.preventDefault();
    var prompt = t.value.trim(); if (!prompt) return;
    add('user', prompt); t.value = ''; b.disabled = true;
    var thinking = add('bot', '…');
    fetch('/gw/chat', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ prompt: prompt }) })
      .then(function(r){ return r.json().then(function(j){ return { ok:r.ok, j:j }; }); })
      .then(function(res){
        thinking.remove();
        if (!res.ok) { add('warn', (res.j.error && res.j.error.message) || 'Ошибка'); return; }
        add(res.j.blocked ? 'warn' : 'bot', res.j.answer);
      })
      .catch(function(){ thinking.remove(); add('warn', 'Сеть недоступна'); })
      .then(function(){ b.disabled = false; t.focus(); });
  });
  t.addEventListener('keydown', function(e){ if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); f.requestSubmit(); } });
</script></body></html>`;

export const ADMIN_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Gateway · админка</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; }
  .wrap { max-width:960px; margin:0 auto; padding:18px; }
  h1 { font-size:18px; } h2 { font-size:15px; margin-top:26px; border-bottom:1px solid #232734; padding-bottom:6px; }
  input, textarea, select { background:#161a22; color:#e6e6e6; border:1px solid #2b3140; border-radius:7px; padding:8px; font:inherit; width:100%; }
  label { display:block; margin:10px 0 4px; color:#9aa4b2; font-size:12px; }
  button { background:#3b82f6; color:#fff; border:0; border-radius:7px; padding:8px 16px; font-weight:600; cursor:pointer; margin-top:12px; }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(130px,1fr)); gap:10px; }
  .card { background:#161a22; border:1px solid #232734; border-radius:10px; padding:12px; }
  .card b { font-size:20px; display:block; }
  table { width:100%; border-collapse:collapse; font-size:12px; margin-top:8px; }
  th,td { text-align:left; padding:6px 8px; border-bottom:1px solid #1c212c; vertical-align:top; }
  .tag { display:inline-block; padding:1px 6px; border-radius:5px; font-size:11px; }
  .block { background:#3a1d1d; color:#ffb4b4; } .mask { background:#3a3320; color:#ffe08a; } .redact { background:#20303a; color:#8ad0ff; }
  .muted { color:#9aa4b2; }
  .bar { display:flex; align-items:center; gap:14px; flex-wrap:wrap; margin-top:10px; }
  .inline { display:inline-flex; align-items:center; gap:5px; margin:0; color:#e6e6e6; font-size:13px; }
  .inline input { width:auto; }
  button.sm { margin-top:0; padding:5px 12px; font-size:12px; }
</style></head><body><div class="wrap">
<h1>LLM Gateway · админка</h1>
<label>Admin-токен (Bearer)</label>
<input id="token" placeholder="GW_API_TOKEN" autocomplete="off">
<button id="load">Загрузить</button>
<div id="out" style="display:none">
  <h2>Статистика</h2>
  <div class="cards" id="stats"></div>
  <h2>Настройки</h2>
  <div class="row">
    <div><label>URL LLM</label><input id="s_url"></div>
    <div><label>Модель</label><input id="s_model"></div>
  </div>
  <div class="row">
    <div><label>Ключ DeepSeek (пусто = не менять)</label><input id="s_key" placeholder="sk-… (write-only)"></div>
    <div><label>Политика input guard</label><select id="s_policy"><option value="mask">mask — маскировать и пропустить</option><option value="block">block — блокировать</option></select></div>
  </div>
  <div class="row">
    <div><label>Rate limit (запросов/мин на IP)</label><input id="s_rate" type="number"></div>
    <div><label>Суточный лимит запросов</label><input id="s_daily" type="number"></div>
  </div>
  <label>Системный промпт (персона)</label><textarea id="s_prompt" rows="4"></textarea>
  <div><button id="save">Сохранить</button> <span id="saved" class="muted"></span></div>
  <h2>Журнал запросов</h2>
  <div class="bar">
    <label class="inline"><input type="radio" name="mode" value="all" checked> Все запросы</label>
    <label class="inline"><input type="radio" name="mode" value="intercepted"> Только перехваты</label>
    <label class="inline"><input type="checkbox" id="auto"> Автообновление (5 с)</label>
    <button id="refresh" class="sm">Обновить</button>
  </div>
  <table id="audit"><thead><tr><th>Время</th><th>Промпт (маскир.)</th><th>Input</th><th>Output</th><th>Ответ</th><th>Ток./$</th></tr></thead><tbody></tbody></table>
</div>
<script>
  var $ = function(id){ return document.getElementById(id); };
  function tok(){ return 'Bearer ' + $('token').value.trim(); }
  function api(path, opts){ opts = opts || {}; opts.headers = Object.assign({ 'Authorization': tok(), 'Content-Type':'application/json' }, opts.headers||{}); return fetch(path, opts).then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); }); }
  function card(label, val){ return '<div class="card"><span class="muted">'+label+'</span><b>'+val+'</b></div>'; }
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  function mode(){ var r=document.querySelector('input[name=mode]:checked'); return r ? r.value : 'all'; }
  function renderAudit(items){
    var tb = $('audit').querySelector('tbody'); tb.innerHTML='';
    if (!items.length) { tb.innerHTML = '<tr><td colspan="6" class="muted">пусто — сделай запрос в чате /gw/</td></tr>'; return; }
    items.forEach(function(it){
      var inp = it.inputAction==='allow' ? '<span class="muted">allow</span>' : '<span class="tag '+it.inputAction+'">'+it.inputAction+'</span> '+it.inputFindings.map(function(f){return f.kind;}).join(', ');
      var outp = it.outputVerdict==='pass' ? '<span class="muted">pass</span>' : '<span class="tag '+it.outputVerdict+'">'+it.outputVerdict+'</span> '+it.outputIssues.map(function(x){return x.kind;}).join(', ');
      tb.innerHTML += '<tr><td>'+esc(it.createdAt.replace('T',' ').slice(11,19))+'</td><td>'+esc(it.userPreview.slice(0,70))+'</td><td>'+inp+'</td><td>'+outp+'</td><td>'+esc((it.answer||'').slice(0,70))+'</td><td>'+it.totalTokens+' / $'+(it.costUsd||0).toFixed(5)+'</td></tr>';
    });
  }
  function loadAudit(){
    var path = mode()==='intercepted' ? '/gw/admin/interceptions?limit=200' : '/gw/admin/audit?limit=200';
    return Promise.all([api('/gw/admin/stats'), api(path)]).then(function(res){
      var st=res[0];
      $('stats').innerHTML = card('Всего', st.total) + card('Заблокировано', st.blocked) + card('Перехватов', st.intercepted) + card('Токенов', st.totalTokens) + card('Стоимость', '$'+(st.totalCostUsd||0).toFixed(4));
      renderAudit(res[1].items);
    });
  }
  function loadAll(){
    api('/gw/admin/settings')
      .then(function(s){
        localStorage.setItem('gwtok', $('token').value.trim());
        $('out').style.display='block';
        $('s_url').value=s.llmUrl; $('s_model').value=s.model; $('s_policy').value=s.inputPolicy;
        $('s_rate').value=s.rateLimitPerMin; $('s_daily').value=s.dailyLimit; $('s_prompt').value=s.systemPrompt;
        $('s_key').placeholder = s.hasLlmKey ? ('задан ····'+s.llmKeyTail+' (пусто = не менять)') : 'sk-… (ключ не задан)';
        return loadAudit();
      })
      .catch(function(e){ alert('Ошибка: '+e.message+' — проверь токен'); });
  }
  $('load').addEventListener('click', loadAll);
  $('refresh').addEventListener('click', function(){ loadAudit().catch(function(){}); });
  Array.prototype.forEach.call(document.querySelectorAll('input[name=mode]'), function(r){
    r.addEventListener('change', function(){ loadAudit().catch(function(){}); });
  });
  var timer = null;
  $('auto').addEventListener('change', function(){
    if (timer) { clearInterval(timer); timer = null; }
    if ($('auto').checked) { timer = setInterval(function(){ loadAudit().catch(function(){}); }, 5000); }
  });
  $('save').addEventListener('click', function(){
    var patch = { llmUrl:$('s_url').value, model:$('s_model').value, inputPolicy:$('s_policy').value, rateLimitPerMin:Number($('s_rate').value), dailyLimit:Number($('s_daily').value), systemPrompt:$('s_prompt').value };
    if ($('s_key').value.trim()) patch.llmApiKey = $('s_key').value.trim();
    api('/gw/admin/settings', { method:'PUT', body: JSON.stringify(patch) }).then(function(){ $('saved').textContent='сохранено'; $('s_key').value=''; setTimeout(function(){ $('saved').textContent=''; }, 2000); loadAll(); }).catch(function(e){ alert('Ошибка сохранения: '+e.message); });
  });
  var saved = localStorage.getItem('gwtok'); if (saved) { $('token').value = saved; }
</script></div></body></html>`;
