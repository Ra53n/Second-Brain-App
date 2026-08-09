// web/index.ts — чат-интерфейс (сайдбар со списком чатов + лента + ввод +
// переключатель режима) и админка (журнал + настройки). String.raw, без сборщика.

import type { FastifyInstance } from "fastify";

export const CHAT_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  html,body { height:100%; margin:0; }
  body { font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; display:flex; }
  #sidebar { width:250px; flex:0 0 250px; border-right:1px solid #232734; display:flex; flex-direction:column; height:100vh; }
  #sidebar .top { padding:12px; border-bottom:1px solid #232734; }
  #new { width:100%; background:#3b82f6; color:#fff; border:0; border-radius:8px; padding:9px; font-weight:600; cursor:pointer; }
  #chatlist { overflow-y:auto; flex:1; }
  .chatitem { padding:10px 12px; border-bottom:1px solid #1a1e27; cursor:pointer; display:flex; justify-content:space-between; gap:6px; }
  .chatitem:hover { background:#161a22; } .chatitem.active { background:#1b2230; }
  .chatitem .t { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .chatitem .x { color:#6b7280; opacity:0; } .chatitem:hover .x { opacity:1; }
  .chatitem .m { font-size:10px; color:#6b7280; }
  #main { flex:1; display:flex; flex-direction:column; height:100vh; }
  #thread { flex:1; overflow-y:auto; padding:18px; }
  .msg { max-width:760px; margin:0 auto 14px; }
  .msg .who { font-size:11px; color:#9aa4b2; text-transform:uppercase; letter-spacing:.04em; margin-bottom:3px; }
  .bubble { border-radius:10px; padding:10px 13px; white-space:pre-wrap; word-break:break-word; }
  .user .bubble { background:#1e2a3a; } .assistant .bubble { background:#161a22; border:1px solid #232734; }
  .trace { max-width:760px; margin:0 auto 14px; font-size:12px; }
  .trace summary { cursor:pointer; color:#9aa4b2; list-style:none; }
  .trace summary::-webkit-details-marker { display:none; }
  .chip { display:inline-block; padding:1px 7px; margin:2px 3px 0 0; border-radius:6px; background:#1c2430; color:#9ecbff; font-size:11px; }
  .chip.bad { background:#3a1d1d; color:#ff9b9b; } .chip.warn { background:#332a1a; color:#ffe08a; } .chip.ok { background:#1e3320; color:#9ae6a4; }
  .tracebody { margin-top:6px; border-left:2px solid #232734; padding-left:10px; }
  .tphase { margin:4px 0; }
  .find { color:#ffb4b4; } .corr { color:#ffd27a; }
  .pwned { background:#3a1d1d; color:#ff6b6b; font-weight:700; }
  #composer { border-top:1px solid #232734; padding:12px 18px; }
  #composer .row { max-width:760px; margin:0 auto; display:flex; gap:10px; align-items:flex-end; }
  #input { flex:1; background:#161a22; color:#e6e6e6; border:1px solid #2b3140; border-radius:10px; padding:10px; font:inherit; resize:none; }
  #send { background:#3b82f6; color:#fff; border:0; border-radius:10px; padding:10px 18px; font-weight:600; cursor:pointer; }
  #send:disabled { opacity:.5; cursor:default; }
  .modewrap { max-width:760px; margin:0 auto 8px; display:flex; align-items:center; gap:8px; font-size:13px; color:#9aa4b2; }
  .seg { display:inline-flex; border:1px solid #2b3140; border-radius:8px; overflow:hidden; }
  .seg button { background:transparent; color:#9aa4b2; border:0; padding:5px 12px; cursor:pointer; font:inherit; }
  .seg button.on { background:#3b82f6; color:#fff; }
  .empty { color:#6b7280; text-align:center; margin-top:40px; }
  .typing { color:#9aa4b2; }
</style></head><body>
<div id="sidebar">
  <div class="top"><button id="new">＋ Новый чат</button></div>
  <div id="chatlist"></div>
</div>
<div id="main">
  <div id="thread"><div class="empty">Выбери или создай чат</div></div>
  <div id="composer">
    <div class="modewrap">Режим чата:
      <span class="seg"><button data-mode="normal" id="mNormal">Обычный</button><button data-mode="loop" id="mLoop">Execution Loop</button></span>
    </div>
    <div class="row">
      <textarea id="input" rows="2" placeholder="Сообщение… (Cmd/Ctrl+Enter — отправить)"></textarea>
      <button id="send">Отправить</button>
    </div>
  </div>
</div>
<script>
  var $ = function(id){ return document.getElementById(id); };
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  var state = { chats:[], activeId:null, chat:null, poll:null };

  function api(path, opts){ return fetch(path, opts).then(function(r){ return r.json().then(function(j){ return {ok:r.ok, j:j}; }); }); }

  function loadChats(){
    return api('/chat/chats').then(function(res){
      state.chats = res.j.items||[];
      renderChats();
      if (!state.activeId && state.chats.length) selectChat(state.chats[0].id);
    });
  }
  function renderChats(){
    $('chatlist').innerHTML = state.chats.map(function(c){
      return '<div class="chatitem'+(c.id===state.activeId?' active':'')+'" data-id="'+c.id+'">'+
        '<div class="t">'+esc(c.title)+'<div class="m">'+(c.mode==='loop'?'Execution Loop':'Обычный')+'</div></div>'+
        '<div class="x" data-del="'+c.id+'">✕</div></div>';
    }).join('');
    Array.prototype.forEach.call(document.querySelectorAll('.chatitem'), function(el){
      el.addEventListener('click', function(e){
        var del = e.target.getAttribute('data-del');
        if (del){ e.stopPropagation(); delChat(del); return; }
        selectChat(el.getAttribute('data-id'));
      });
    });
  }
  function newChat(){ api('/chat/chats', {method:'POST'}).then(function(res){ state.activeId=res.j.id; loadChats().then(function(){ selectChat(res.j.id); }); }); }
  function delChat(id){ api('/chat/chats/'+id, {method:'DELETE'}).then(function(){ if(state.activeId===id){ state.activeId=null; state.chat=null; } loadChats(); }); }

  function selectChat(id){
    state.activeId = id;
    renderChats();
    return api('/chat/chats/'+id).then(function(res){ state.chat=res.j; renderThread(); renderMode(); maybePoll(); });
  }
  function renderMode(){
    var mode = state.chat && state.chat.chat ? state.chat.chat.mode : 'normal';
    $('mNormal').className = mode==='normal'?'on':''; $('mLoop').className = mode==='loop'?'on':'';
  }
  function setMode(mode){
    if(!state.activeId) return;
    api('/chat/chats/'+state.activeId, {method:'PATCH', headers:{'Content-Type':'application/json'}, body:JSON.stringify({mode:mode})})
      .then(function(){ if(state.chat&&state.chat.chat) state.chat.chat.mode=mode; renderMode(); loadChats(); });
  }

  function traceHtml(loop){
    if(!loop) return '';
    var chips = (loop.phases||[]).map(function(p){
      var cls='chip', label=({generating:'генерация',verifying:'корректность',securityReview:'security'})[p.phase]||p.phase;
      if((p.findings||[]).some(function(f){return f.severity==='critical'||f.severity==='high';})) cls='chip bad';
      else if((p.correctnessIssues||[]).length) cls='chip warn';
      else cls='chip ok';
      return '<span class="'+cls+'">'+label+(p.round>1?' к'+p.round:'')+'</span>';
    }).join('');
    var body = (loop.phases||[]).map(function(p){
      var f=(p.findings||[]).map(function(x){return '<div class="find">['+x.severity+'] '+esc(x.issue)+'</div>';}).join('');
      var c=(p.correctnessIssues||[]).map(function(x){return '<div class="corr">• '+esc(x)+'</div>';}).join('');
      var gw=(p.gateway&&p.gateway.inputAction&&p.gateway.inputAction!=='allow')?'<div style="color:#9aa4b2">gateway: '+p.gateway.inputAction+' ['+(p.gateway.findingTypes||[]).join(', ')+']</div>':'';
      return '<div class="tphase"><b>'+esc(p.display||p.phase)+'</b>'+c+f+gw+'</div>';
    }).join('');
    var pw = loop.pwned?'<span class="chip pwned">PWNED</span>':'';
    return '<details class="trace"><summary>execution loop: '+chips+' '+pw+' · $'+(loop.costUsd||0).toFixed(5)+'</summary><div class="tracebody">'+body+'</div></details>';
  }
  function renderThread(){
    if(!state.chat){ $('thread').innerHTML='<div class="empty">Выбери или создай чат</div>'; return; }
    var msgs = state.chat.messages||[];
    if(!msgs.length){ $('thread').innerHTML='<div class="empty">Напиши первое сообщение</div>'; return; }
    $('thread').innerHTML = msgs.map(function(m){
      if(m.role==='user') return '<div class="msg user"><div class="who">вы</div><div class="bubble">'+esc(m.content)+'</div></div>';
      var trace = traceHtml(m.loop);
      var body = m.status==='pending' ? '<span class="typing">печатает…</span>' : (m.status==='failed' ? esc(m.errorText||'ошибка') : esc(m.content));
      return trace + '<div class="msg assistant"><div class="who">ассистент</div><div class="bubble">'+body+'</div></div>';
    }).join('');
    $('thread').scrollTop = $('thread').scrollHeight;
  }
  function maybePoll(){
    if(state.poll) clearInterval(state.poll);
    var pending = (state.chat&&state.chat.messages||[]).some(function(m){return m.status==='pending';});
    if(!pending) return;
    state.poll = setInterval(function(){
      api('/chat/chats/'+state.activeId).then(function(res){
        state.chat=res.j; renderThread();
        if(!(state.chat.messages||[]).some(function(m){return m.status==='pending';})) { clearInterval(state.poll); loadChats(); }
      });
    }, 1500);
  }
  function sendMsg(){
    var text=$('input').value.trim(); if(!text||!state.activeId) return;
    $('send').disabled=true; $('input').value='';
    api('/chat/chats/'+state.activeId+'/messages', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({content:text})})
      .then(function(res){ $('send').disabled=false; if(!res.ok){ alert((res.j.error&&res.j.error.message)||'Ошибка'); return; } selectChat(state.activeId); })
      .catch(function(e){ $('send').disabled=false; alert('Сеть: '+e.message); });
  }

  $('new').addEventListener('click', newChat);
  $('send').addEventListener('click', sendMsg);
  $('mNormal').addEventListener('click', function(){ setMode('normal'); });
  $('mLoop').addEventListener('click', function(){ setMode('loop'); });
  $('input').addEventListener('keydown', function(e){ if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){ e.preventDefault(); sendMsg(); } });
  loadChats().then(function(){ if(!state.chats.length) newChat(); });
</script></body></html>`;

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
  .muted { color:#9aa4b2; } pre { white-space:pre-wrap; word-break:break-word; background:#0b0d11; padding:8px; border-radius:6px; font-size:12px; }
  tr.clk { cursor:pointer; } tr.clk:hover td { background:#141821; }
  .pwned{background:#3a1d1d;color:#ff6b6b;font-weight:700;padding:1px 6px;border-radius:5px;}
</style></head><body><div class="wrap">
<h1>Chat · админка</h1>
<label>Admin-токен (Bearer)</label>
<input id="token" placeholder="токен" autocomplete="off"><button id="load">Загрузить</button>
<div id="out" style="display:none">
  <h2>Настройки агента</h2>
  <div class="cards" id="cfg"></div>
  <label>Режимы</label><pre id="modes"></pre>
  <label>Схема execution loop</label><pre id="loop"></pre>
  <label>Системный промпт (превью, канарейка скрыта)</label><pre id="sys"></pre>
  <h2>Чаты <button id="refresh" class="sm">обновить</button></h2>
  <table id="chats"><thead><tr><th>Заголовок</th><th>Режим</th><th>Обновлён</th></tr></thead><tbody></tbody></table>
  <div id="detail"></div>
</div>
<script>
  var $=function(id){return document.getElementById(id);};
  function tok(){ return 'Bearer '+$('token').value.trim(); }
  function api(p){ return fetch(p,{headers:{Authorization:tok()}}).then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); }); }
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  function card(l,v){ return '<div class="card"><span>'+l+'</span><b>'+esc(v)+'</b></div>'; }
  function loadCfg(){ return api('/chat/admin/config').then(function(c){
    $('cfg').innerHTML=card('Версия',c.version)+card('Модель',c.model)+card('Gateway',c.gwUrl)+card('maxRounds',c.maxRounds)+card('Окно истории',c.historyWindow)+card('Rate/мин',c.rateLimitPerMin)+card('Канарейка',c.canaryEnabled?'включена':'нет');
    $('modes').textContent=c.modes; $('loop').textContent=c.loop; $('sys').textContent=c.systemPromptPreview; }); }
  function loadChats(){ return api('/chat/admin/chats').then(function(j){
    var tb=$('chats').querySelector('tbody'); tb.innerHTML='';
    if(!j.items.length){ tb.innerHTML='<tr><td colspan="3" class="muted">пусто</td></tr>'; return; }
    j.items.forEach(function(c){ var tr=document.createElement('tr'); tr.className='clk';
      tr.innerHTML='<td>'+esc(c.title)+'</td><td>'+(c.mode==='loop'?'Execution Loop':'Обычный')+'</td><td>'+esc((c.updatedAt||'').replace('T',' ').slice(5,19))+'</td>';
      tr.addEventListener('click', function(){ detail(c.id); }); tb.appendChild(tr); }); }); }
  function detail(id){ api('/chat/admin/chats/'+id).then(function(d){
    var html='<h2>Чат: '+esc(d.chat.title)+'</h2>';
    (d.messages||[]).forEach(function(m){
      html+='<div class="card"><span>'+m.role+' · '+m.status+'</span><div>'+esc((m.content||'').slice(0,400))+'</div>';
      if(m.loop){ (m.loop.phases||[]).forEach(function(p){
        html+='<div class="muted">'+esc(p.phase)+' к'+p.round+': '+esc(p.display)+'</div>';
        (p.correctnessIssues||[]).forEach(function(c){ html+='<div style="color:#ffd27a">• '+esc(c)+'</div>'; });
        (p.findings||[]).forEach(function(f){ html+='<div style="color:#ffb4b4">['+f.severity+'] '+esc(f.issue)+'</div>'; });
        if(p.gateway&&p.gateway.inputAction&&p.gateway.inputAction!=='allow') html+='<div class="muted">gateway: '+p.gateway.inputAction+' ['+(p.gateway.findingTypes||[]).join(', ')+']</div>';
      }); if(m.loop.pwned) html+='<div><span class="pwned">PWNED</span></div>'; }
      html+='</div>';
    });
    $('detail').innerHTML=html; $('detail').scrollIntoView({behavior:'smooth'}); }).catch(function(e){ alert(e.message); }); }
  function loadAll(){ loadCfg().then(loadChats).then(function(){ localStorage.setItem('chattok',$('token').value.trim()); $('out').style.display='block'; }).catch(function(e){ alert('Ошибка: '+e.message+' — проверь токен'); }); }
  $('load').addEventListener('click', loadAll);
  $('refresh').addEventListener('click', function(){ loadChats().catch(function(){}); });
  var s=localStorage.getItem('chattok'); if(s) $('token').value=s;
</script></div></body></html>`;

export function registerWebRoutes(app: FastifyInstance): void {
  const html = (page: string) => (_req: unknown, reply: { type: (t: string) => { send: (b: string) => unknown } }) =>
    reply.type("text/html; charset=utf-8").send(page);
  app.get("/chat", html(CHAT_PAGE) as never);
  app.get("/chat/", html(CHAT_PAGE) as never);
  app.get("/chat/admin", html(ADMIN_PAGE) as never);
}
