// web/index.ts — две inline-страницы: чат с execution loop (публичная) и админка
// (настройки агента + журнал прогонов). String.raw, без сборщика.

import type { FastifyInstance } from "fastify";

export const RUN_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat · execution loop</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  body { margin:0; font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; }
  .wrap { max-width:860px; margin:0 auto; padding:18px; }
  header { font-weight:600; font-size:18px; }
  .muted { color:#9aa4b2; font-size:13px; }
  textarea { width:100%; background:#161a22; color:#e6e6e6; border:1px solid #2b3140; border-radius:8px; padding:10px; font:inherit; margin-top:10px; }
  button { background:#3b82f6; color:#fff; border:0; border-radius:8px; padding:10px 20px; font-weight:600; cursor:pointer; margin-top:12px; }
  button:disabled { opacity:.5; cursor:default; }
  .inline { display:inline-flex; align-items:center; gap:6px; margin-left:14px; }
  .inline input { width:auto; }
  #steps { margin-top:20px; }
  .step { background:#161a22; border:1px solid #232734; border-radius:9px; padding:10px 12px; margin:8px 0; }
  .step .ph { font-size:11px; color:#9aa4b2; text-transform:uppercase; letter-spacing:.04em; }
  .step .dp { margin-top:2px; }
  .find { color:#ffb4b4; font-size:13px; margin-top:4px; }
  .corr { color:#ffd27a; font-size:13px; margin-top:4px; }
  .warnrow { color:#ffe08a; font-size:13px; }
  .status { display:inline-block; padding:2px 8px; border-radius:6px; font-size:12px; margin-left:8px; }
  .running { background:#20303a; color:#8ad0ff; } .finished { background:#1e3320; color:#9ae6a4; }
  .failed { background:#3a1d1d; color:#ffb4b4; } .paused { background:#332a1a; color:#ffe08a; }
  .pwned { background:#3a1d1d; color:#ff6b6b; font-weight:700; }
  .result { background:#12211a; border:1px solid #274b36; border-radius:9px; padding:12px; margin-top:12px; white-space:pre-wrap; word-break:break-word; }
  .result h3 { margin:0 0 6px; font-size:13px; color:#9ae6a4; }
  a { color:#8ad0ff; }
</style></head><body><div class="wrap">
<header>Chat · execution loop</header>
<div class="muted">Даёт результат по твоей задаче, сам проверяет его на корректность и на безопасность, при провале переделывает — и показывает весь цикл. Все вызовы к модели идут через LLM Gateway. <a href="/chat/admin">админка →</a></div>

<textarea id="prompt" rows="3" placeholder="Впиши задачу: вопрос, текст, код, план…"></textarea>
<div>
  <button id="run">Запустить</button>
  <label class="inline"><input type="checkbox" id="secure" checked> защиты включены</label>
</div>

<div id="steps"></div>
<script>
  var $ = function(id){ return document.getElementById(id); };
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  var poll = null;
  function render(data){
    var run = data.run, steps = data.steps || [];
    var head = '<div class="step"><b>'+esc(run.taskPrompt.slice(0,80))+'</b><span class="status '+run.status+'">'+run.status+'</span>'+
      (run.outcome ? '<span class="status finished">'+esc(run.outcome)+'</span>' : '')+
      (run.pwned ? '<span class="status pwned">PWNED</span>' : '')+
      '<div class="muted">круг '+run.round+'/'+run.maxRounds+' · $'+(run.costUsd||0).toFixed(5)+(run.secure?'':' · baseline (secure=off)')+'</div>'+
      (run.errorText ? '<div class="find">'+esc(run.errorText)+'</div>' : '')+'</div>';
    var body = steps.map(function(s){
      var finds = JSON.parse(s.findings_json||'[]');
      var corr = JSON.parse(s.correctness_json||'[]');
      var gw = JSON.parse(s.gateway_json||'{}');
      var fh = finds.map(function(f){ return '<div class="find">['+f.severity+'] '+esc(f.issue)+'</div>'; }).join('');
      var ch = corr.map(function(c){ return '<div class="corr">• '+esc(c.issue)+'</div>'; }).join('');
      var gwl = (gw.inputAction && gw.inputAction!=='allow') ? '<div class="muted">gateway: '+gw.inputAction+' ['+(gw.findingTypes||[]).join(', ')+']</div>' : '';
      return '<div class="step"><div class="ph">'+esc(s.phase)+' · круг '+s.round+'</div><div class="dp">'+esc(s.display)+'</div>'+ch+fh+gwl+
        (s.pwned? '<div class="find">⚠ канарейка утекла в ответе</div>':'')+'</div>';
    }).join('');
    var warns = (run.warnings||[]).map(function(w){ return '<div class="warnrow">'+esc(w)+'</div>'; }).join('');
    var result = run.result ? '<div class="result"><h3>Итоговый результат</h3>'+esc(run.result)+'</div>' : '';
    $('steps').innerHTML = head + body + warns + result;
  }
  function track(id){
    if (poll) clearInterval(poll);
    poll = setInterval(function(){
      fetch('/chat/runs/'+id).then(function(r){return r.json();}).then(function(d){
        render(d);
        if (d.run.status!=='running') clearInterval(poll);
      }).catch(function(){});
    }, 1500);
  }
  $('run').addEventListener('click', function(){
    var prompt = $('prompt').value.trim();
    if (!prompt) { alert('Впиши задачу'); return; }
    $('run').disabled = true;
    fetch('/chat/runs', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ prompt: prompt, secure: $('secure').checked }) })
      .then(function(r){ return r.json().then(function(j){ return {ok:r.ok,j:j}; }); })
      .then(function(res){ $('run').disabled=false; if(!res.ok){ alert((res.j.error&&res.j.error.message)||'Ошибка'); return; } $('steps').innerHTML='<div class="muted">цикл запущен…</div>'; track(res.j.id); })
      .catch(function(e){ $('run').disabled=false; alert('Сеть: '+e.message); });
  });
  $('prompt').addEventListener('keydown', function(e){ if (e.key==='Enter' && (e.metaKey||e.ctrlKey)) { e.preventDefault(); $('run').click(); } });
</script></div></body></html>`;

export const ADMIN_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat · админка</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; }
  .wrap { max-width:1000px; margin:0 auto; padding:18px; }
  h1 { font-size:18px; } h2 { font-size:15px; margin-top:26px; border-bottom:1px solid #232734; padding-bottom:6px; }
  input { background:#161a22; color:#e6e6e6; border:1px solid #2b3140; border-radius:7px; padding:8px; font:inherit; width:100%; }
  label { display:block; margin:10px 0 4px; color:#9aa4b2; font-size:12px; }
  button { background:#3b82f6; color:#fff; border:0; border-radius:7px; padding:8px 16px; font-weight:600; cursor:pointer; margin-top:12px; }
  button.sm { margin-top:0; padding:5px 12px; font-size:12px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; }
  .card { background:#161a22; border:1px solid #232734; border-radius:10px; padding:12px; }
  .card span { color:#9aa4b2; font-size:12px; } .card b { font-size:15px; display:block; word-break:break-word; }
  table { width:100%; border-collapse:collapse; font-size:12px; margin-top:8px; }
  th,td { text-align:left; padding:6px 8px; border-bottom:1px solid #1c212c; vertical-align:top; }
  .muted { color:#9aa4b2; }
  .st { display:inline-block; padding:1px 6px; border-radius:5px; font-size:11px; }
  .running{background:#20303a;color:#8ad0ff;} .finished{background:#1e3320;color:#9ae6a4;} .failed{background:#3a1d1d;color:#ffb4b4;} .paused{background:#332a1a;color:#ffe08a;}
  .pwned{background:#3a1d1d;color:#ff6b6b;font-weight:700;}
  pre { white-space:pre-wrap; word-break:break-word; background:#0b0d11; padding:8px; border-radius:6px; font-size:12px; }
  tr.clk { cursor:pointer; } tr.clk:hover td { background:#141821; }
</style></head><body><div class="wrap">
<h1>Chat · админка</h1>
<label>Admin-токен (Bearer)</label>
<input id="token" placeholder="токен" autocomplete="off">
<button id="load">Загрузить</button>
<div id="out" style="display:none">
  <h2>Настройки агента</h2>
  <div class="cards" id="cfg"></div>
  <label>Схема цикла</label><pre id="loop"></pre>
  <label>Системный промпт (превью, канарейка скрыта)</label>
  <pre id="sysprompt"></pre>
  <h2>Прогоны <button id="refresh" class="sm">обновить</button></h2>
  <table id="runs"><thead><tr><th>Время</th><th>Задача</th><th>Статус</th><th>Исход</th><th>Круг</th><th>$</th><th>pwned</th></tr></thead><tbody></tbody></table>
  <div id="detail"></div>
</div>
<script>
  var $ = function(id){ return document.getElementById(id); };
  function tok(){ return 'Bearer ' + $('token').value.trim(); }
  function api(path){ return fetch(path, { headers:{ 'Authorization': tok() } }).then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); }); }
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  function card(l,v){ return '<div class="card"><span>'+l+'</span><b>'+esc(v)+'</b></div>'; }
  function loadCfg(){
    return api('/chat/admin/config').then(function(c){
      $('cfg').innerHTML = card('Версия', c.version)+card('Модель', c.model)+card('Gateway', c.gwUrl)+
        card('maxRounds', c.maxRounds)+card('secure по умолч.', c.defaultSecure)+
        card('Rate limit/мин', c.rateLimitPerMin)+card('Суточный лимит', c.dailyLimit)+card('Канарейка', c.canaryEnabled?'включена':'нет');
      $('loop').textContent = c.loop;
      $('sysprompt').textContent = c.systemPromptPreview;
    });
  }
  function loadRuns(){
    return api('/chat/admin/runs?limit=100').then(function(j){
      var tb=$('runs').querySelector('tbody'); tb.innerHTML='';
      if(!j.items.length){ tb.innerHTML='<tr><td colspan="7" class="muted">пусто — запусти прогон на /chat/</td></tr>'; return; }
      j.items.forEach(function(r){
        var tr=document.createElement('tr'); tr.className='clk';
        tr.innerHTML='<td>'+esc((r.created_at||'').replace('T',' ').slice(5,19))+'</td><td>'+esc(r.task_title)+'</td>'+
          '<td><span class="st '+r.status+'">'+r.status+'</span></td><td>'+esc(r.outcome||'')+'</td><td>'+r.round+'</td>'+
          '<td>$'+(r.cost_usd||0).toFixed(5)+'</td><td>'+(r.pwned?'<span class="st pwned">PWNED</span>':'')+'</td>';
        tr.addEventListener('click', function(){ detail(r.id); });
        tb.appendChild(tr);
      });
    });
  }
  function detail(id){
    api('/chat/admin/runs/'+id+'/steps').then(function(d){
      var steps=d.steps||[];
      var html='<h2>Прогон '+esc(id.slice(0,8))+'</h2>';
      steps.forEach(function(s){
        var finds=JSON.parse(s.findings_json||'[]'); var corr=JSON.parse(s.correctness_json||'[]'); var gw=JSON.parse(s.gateway_json||'{}'); var eg=JSON.parse(s.egress_json||'[]');
        html+='<div class="card"><span>'+esc(s.phase)+' · круг '+s.round+'</span><div>'+esc(s.display)+'</div>';
        corr.forEach(function(c){ html+='<div style="color:#ffd27a">• '+esc(c.issue)+'</div>'; });
        finds.forEach(function(f){ html+='<div style="color:#ffb4b4">['+f.severity+'] '+esc(f.issue)+'</div>'; });
        if(gw.inputAction&&gw.inputAction!=='allow') html+='<div class="muted">gateway перехват: '+gw.inputAction+' ['+(gw.findingTypes||[]).join(', ')+']</div>';
        if(eg.length) html+='<div class="muted">egress срезал: '+esc(eg.join('; '))+'</div>';
        if(s.pwned) html+='<div style="color:#ff6b6b">⚠ канарейка утекла</div>';
        html+='<div class="muted">ответ: '+esc((s.answer_preview||'').slice(0,240))+'</div></div>';
      });
      $('detail').innerHTML=html; $('detail').scrollIntoView({behavior:'smooth'});
    }).catch(function(e){ alert(e.message); });
  }
  function loadAll(){ loadCfg().then(loadRuns).then(function(){ localStorage.setItem('chattok',$('token').value.trim()); $('out').style.display='block'; }).catch(function(e){ alert('Ошибка: '+e.message+' — проверь токен'); }); }
  $('load').addEventListener('click', loadAll);
  $('refresh').addEventListener('click', function(){ loadRuns().catch(function(){}); });
  var saved=localStorage.getItem('chattok'); if(saved) $('token').value=saved;
</script></div></body></html>`;

export function registerWebRoutes(app: FastifyInstance): void {
  const html = (page: string) => (_req: unknown, reply: { type: (t: string) => { send: (b: string) => unknown } }) =>
    reply.type("text/html; charset=utf-8").send(page);
  app.get("/chat", html(RUN_PAGE) as never);
  app.get("/chat/", html(RUN_PAGE) as never);
  app.get("/chat/admin", html(ADMIN_PAGE) as never);
}
