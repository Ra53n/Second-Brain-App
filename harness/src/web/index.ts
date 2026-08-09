// web/index.ts — чат (вход/регистрация + список чатов + лента + режим) и админка
// (логи всех пользователей + алерты). String.raw, без сборщика, ES5-стиль JS.

import type { FastifyInstance } from "fastify";

export const CHAT_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat</title>
<style>
  :root { color-scheme: dark; --bg:#0c0e13; --panel:#12151c; --panel2:#161a22; --line:#222736; --line2:#2b3140; --text:#e8eaf0; --muted:#93a0b4; --accent:#4f8cff; --accent-hover:#3b7bf0; }
  * { box-sizing:border-box; }
  html,body { height:100%; margin:0; }
  body { font:15px/1.55 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--text); }
  button { font:inherit; } textarea:focus, input:focus { outline:none; }
  #app { display:flex; height:100vh; }
  #sidebar { width:264px; flex:0 0 264px; background:var(--panel); border-right:1px solid var(--line); display:flex; flex-direction:column; }
  #sidebar .top { padding:12px; }
  #new { width:100%; background:var(--accent); color:#fff; border:0; border-radius:10px; padding:11px; font-weight:600; cursor:pointer; transition:background .15s; }
  #new:hover { background:var(--accent-hover); }
  #chatlist { overflow-y:auto; flex:1; padding:4px 8px; }
  #userbar { padding:12px; border-top:1px solid var(--line); font-size:13px; display:flex; justify-content:space-between; align-items:center; gap:8px; }
  #userbar #uname { color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  #userbar a { color:var(--accent); text-decoration:none; } #userbar a:hover { text-decoration:underline; }
  #userbar button { background:transparent; color:var(--muted); border:1px solid var(--line2); border-radius:7px; padding:4px 10px; cursor:pointer; font-size:12px; }
  #userbar button:hover { color:var(--text); border-color:var(--muted); }
  .chatitem { padding:9px 10px; border-radius:9px; margin-bottom:2px; cursor:pointer; display:flex; justify-content:space-between; gap:6px; align-items:center; transition:background .12s; }
  .chatitem:hover { background:var(--panel2); } .chatitem.active { background:#1b2333; }
  .chatitem .t { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
  .chatitem .x { color:#6b7280; opacity:0; padding:0 3px; border-radius:5px; } .chatitem:hover .x { opacity:.8; } .chatitem .x:hover { opacity:1; background:#3a1d1d; color:#ff9b9b; }
  .chatitem .m { font-size:10px; color:#6b7280; margin-top:1px; }
  #main { flex:1; display:flex; flex-direction:column; min-width:0; }
  #thread { flex:1; overflow-y:auto; padding:24px 18px; }
  .msg { max-width:720px; margin:0 auto 16px; }
  .msg .who { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; margin-bottom:4px; }
  .bubble { border-radius:14px; padding:11px 15px; white-space:pre-wrap; word-break:break-word; }
  .user .bubble { background:linear-gradient(180deg,#22354d,#1c2c42); border:1px solid #2b425f; }
  .assistant .bubble { background:var(--panel2); border:1px solid var(--line); }
  .trace { max-width:720px; margin:2px auto 10px; font-size:12px; }
  .trace summary { cursor:pointer; color:var(--muted); list-style:none; padding:5px 0; }
  .trace summary::-webkit-details-marker { display:none; }
  .trace summary:hover { color:var(--text); }
  .chip { display:inline-block; padding:2px 8px; margin:2px 3px 0 0; border-radius:999px; background:#1c2430; color:#9ecbff; font-size:11px; }
  .chip.bad { background:#3a1d1d; color:#ff9b9b; } .chip.warn { background:#332a1a; color:#ffe08a; } .chip.ok { background:#153020; color:#8fe6a4; }
  .tracebody { margin-top:8px; border-left:2px solid var(--line); padding-left:12px; }
  .find { color:#ffb4b4; } .corr { color:#ffd27a; }
  .pwned { background:#3a1d1d; color:#ff6b6b; font-weight:700; }
  #composer { padding:10px 18px 16px; }
  #composer .composer-inner { max-width:720px; margin:0 auto; }
  .inputbar { display:flex; align-items:flex-end; gap:8px; background:var(--panel2); border:1px solid var(--line2); border-radius:16px; padding:8px 8px 8px 14px; transition:border-color .15s; }
  .inputbar:focus-within { border-color:var(--accent); }
  #input { flex:1; background:transparent; color:var(--text); border:0; padding:6px 0; font:inherit; resize:none; max-height:180px; line-height:1.5; }
  #send { flex:0 0 auto; align-self:flex-end; background:var(--accent); color:#fff; border:0; border-radius:11px; padding:9px 18px; font-weight:600; cursor:pointer; transition:background .15s; }
  #send:hover { background:var(--accent-hover); } #send:disabled { opacity:.5; cursor:default; }
  .modewrap { display:flex; align-items:center; gap:8px; font-size:13px; color:var(--muted); margin-bottom:8px; }
  .seg { display:inline-flex; border:1px solid var(--line2); border-radius:9px; overflow:hidden; }
  .seg button { background:transparent; color:var(--muted); border:0; padding:5px 14px; cursor:pointer; transition:background .12s,color .12s; }
  .seg button:hover { color:var(--text); } .seg button.on { background:var(--accent); color:#fff; }
  .empty { color:#6b7280; text-align:center; margin-top:60px; }
  .typing { color:var(--muted); font-style:italic; }
  .dots::after { content:'…'; animation: dots 1.2s steps(4,end) infinite; }
  @keyframes dots { 0%{content:''} 25%{content:'.'} 50%{content:'..'} 75%{content:'…'} 100%{content:'…'} }
  /* Overlay входа */
  #auth { position:fixed; inset:0; background:radial-gradient(1200px 600px at 50% -10%, #16203a, var(--bg)); display:flex; align-items:center; justify-content:center; }
  #auth .card { width:360px; background:var(--panel); border:1px solid var(--line); border-radius:16px; padding:26px; box-shadow:0 20px 60px rgba(0,0,0,.4); }
  #auth h2 { margin:0 0 4px; font-size:20px; } #auth .sub { color:var(--muted); font-size:13px; margin-bottom:16px; }
  #auth input { width:100%; background:var(--bg); color:var(--text); border:1px solid var(--line2); border-radius:10px; padding:11px; font:inherit; margin-bottom:10px; }
  #auth input:focus { border-color:var(--accent); }
  #auth button.primary { width:100%; background:var(--accent); color:#fff; border:0; border-radius:10px; padding:11px; font-weight:600; cursor:pointer; transition:background .15s; }
  #auth button.primary:hover { background:var(--accent-hover); }
  #auth .toggle { text-align:center; margin-top:14px; font-size:13px; color:var(--muted); }
  #auth .toggle a { color:var(--accent); cursor:pointer; }
  #auth .err { color:#ff9b9b; font-size:13px; min-height:18px; margin-bottom:6px; }
</style></head><body>

<div id="auth" style="display:none">
  <div class="card">
    <h2 id="authTitle">Вход</h2>
    <div class="sub">Чат с execution loop. Войдите или зарегистрируйтесь.</div>
    <div class="err" id="authErr"></div>
    <input id="au" placeholder="Логин" autocomplete="username">
    <input id="ap" type="password" placeholder="Пароль" autocomplete="current-password">
    <button class="primary" id="authGo">Войти</button>
    <div class="toggle" id="authToggle">Нет аккаунта? <a>Регистрация</a></div>
  </div>
</div>

<div id="app" style="display:none">
  <div id="sidebar">
    <div class="top"><button id="new">＋ Новый чат</button></div>
    <div id="chatlist"></div>
    <div id="userbar"><span id="uname"></span><span><a id="adminLink" href="/chat/admin" style="display:none">админка</a> <button id="logout">Выйти</button></span></div>
  </div>
  <div id="main">
    <div id="thread"><div class="empty">Выбери или создай чат</div></div>
    <div id="composer">
      <div class="composer-inner">
        <div class="modewrap">Режим чата:
          <span class="seg"><button data-mode="normal" id="mNormal">Обычный</button><button data-mode="loop" id="mLoop">Execution Loop</button></span>
        </div>
        <div class="inputbar">
          <textarea id="input" rows="1" placeholder="Сообщение…  (Cmd/Ctrl+Enter — отправить)"></textarea>
          <button id="send">Отправить</button>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
  var $ = function(id){ return document.getElementById(id); };
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  function jfetch(url, opts){ opts=opts||{}; opts.headers=opts.headers||{}; return fetch(url,opts).then(function(r){ return r.json().then(function(j){ return {ok:r.ok,status:r.status,j:j}; }); }); }
  var state = { me:null, chats:[], activeId:null, chat:null, poll:null, registerMode:false };

  // ── Auth overlay ──
  function showAuth(){ $('app').style.display='none'; $('auth').style.display='flex'; }
  function renderAuthMode(){
    $('authTitle').textContent = state.registerMode ? 'Регистрация' : 'Вход';
    $('authGo').textContent = state.registerMode ? 'Зарегистрироваться' : 'Войти';
    $('authToggle').innerHTML = state.registerMode ? 'Уже есть аккаунт? <a>Вход</a>' : 'Нет аккаунта? <a>Регистрация</a>';
    $('authToggle').querySelector('a').addEventListener('click', function(){ state.registerMode=!state.registerMode; renderAuthMode(); });
  }
  function doAuth(){
    var u=$('au').value.trim(), p=$('ap').value;
    if(!u||!p){ $('authErr').textContent='Введите логин и пароль'; return; }
    var path = state.registerMode ? '/chat/auth/register' : '/chat/auth/login';
    jfetch(path, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({username:u,password:p}) })
      .then(function(res){ if(!res.ok){ $('authErr').textContent=(res.j.error&&res.j.error.message)||'Ошибка'; return; } boot(); })
      .catch(function(e){ $('authErr').textContent='Сеть: '+e.message; });
  }

  // ── Чаты ──
  function loadChats(){
    return jfetch('/chat/chats').then(function(res){
      state.chats = (res.j.items)||[];
      renderChats();
      if(!state.activeId && state.chats.length) selectChat(state.chats[0].id);
      else if(!state.chats.length){ state.chat=null; renderThread(); }
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
        var del=e.target.getAttribute('data-del');
        if(del){ e.stopPropagation(); delChat(del); return; }
        selectChat(el.getAttribute('data-id'));
      });
    });
  }
  function newChat(){ jfetch('/chat/chats',{method:'POST'}).then(function(res){ state.activeId=res.j.id; loadChats().then(function(){ selectChat(res.j.id); }); }); }
  function delChat(id){ jfetch('/chat/chats/'+id,{method:'DELETE'}).then(function(){ if(state.activeId===id){ state.activeId=null; state.chat=null; } loadChats(); }); }
  function selectChat(id){ state.activeId=id; renderChats(); return jfetch('/chat/chats/'+id).then(function(res){ if(!res.ok){ loadChats(); return; } state.chat=res.j; renderThread(); renderMode(); maybePoll(); }); }
  function renderMode(){ var mode=state.chat&&state.chat.chat?state.chat.chat.mode:'normal'; $('mNormal').className=mode==='normal'?'on':''; $('mLoop').className=mode==='loop'?'on':''; }
  function setMode(mode){ if(!state.activeId) return; jfetch('/chat/chats/'+state.activeId,{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:mode})}).then(function(){ if(state.chat&&state.chat.chat) state.chat.chat.mode=mode; renderMode(); loadChats(); }); }

  function traceHtml(loop, mid){
    if(!loop) return '';
    var chips=(loop.phases||[]).map(function(p){
      var cls='chip', label=({generating:'генерация',verifying:'корректность',securityReview:'security'})[p.phase]||p.phase;
      if((p.findings||[]).some(function(f){return f.severity==='critical'||f.severity==='high';})) cls='chip bad';
      else if((p.correctnessIssues||[]).length) cls='chip warn'; else cls='chip ok';
      return '<span class="'+cls+'">'+label+(p.round>1?' к'+p.round:'')+'</span>';
    }).join('');
    var body=(loop.phases||[]).map(function(p){
      var f=(p.findings||[]).map(function(x){return '<div class="find">['+x.severity+'] '+esc(x.issue)+'</div>';}).join('');
      var c=(p.correctnessIssues||[]).map(function(x){return '<div class="corr">• '+esc(x)+'</div>';}).join('');
      var gw=(p.gateway&&p.gateway.inputAction&&p.gateway.inputAction!=='allow')?'<div style="color:#9aa4b2">gateway: '+p.gateway.inputAction+' ['+(p.gateway.findingTypes||[]).join(', ')+']</div>':'';
      return '<div style="margin:4px 0"><b>'+esc(p.display||p.phase)+'</b>'+c+f+gw+'</div>';
    }).join('');
    var pw=loop.pwned?'<span class="chip pwned">PWNED</span>':'';
    var meta=(loop.totalTokens||0)+' токенов · '+(((loop.durationMs||0)/1000).toFixed(1))+' с';
    return '<details class="trace" data-mid="'+mid+'"><summary>execution loop: '+chips+' '+pw+' · '+meta+'</summary><div class="tracebody">'+body+'</div></details>';
  }
  // Живой статус: последняя фаза трейса описывает, что агент делает сейчас.
  function progressLabel(loop){
    if(loop&&loop.phases&&loop.phases.length){ var p=loop.phases[loop.phases.length-1]; return esc(p.display||p.phase); }
    return 'Генерирую ответ';
  }
  function renderThread(){
    var thr=$('thread');
    if(!state.chat){ thr.innerHTML='<div class="empty">Создай чат кнопкой слева</div>'; return; }
    var msgs=state.chat.messages||[];
    if(!msgs.length){ thr.innerHTML='<div class="empty">Напиши первое сообщение</div>'; return; }
    // Запоминаем раскрытые трейсы и близость к низу — чтобы poll их не сбрасывал.
    var openMids={}; Array.prototype.forEach.call(thr.querySelectorAll('.trace[open]'), function(d){ openMids[d.getAttribute('data-mid')]=1; });
    var nearBottom = thr.scrollHeight - thr.scrollTop - thr.clientHeight < 120;
    thr.innerHTML=msgs.map(function(m){
      if(m.role==='user') return '<div class="msg user"><div class="who">вы</div><div class="bubble">'+esc(m.content)+'</div></div>';
      var trace=traceHtml(m.loop, m.id);
      var body;
      if(m.status==='pending') body='<span class="typing">'+progressLabel(m.loop)+'<span class="dots"></span></span>';
      else if(m.status==='failed') body=esc(m.errorText||'ошибка');
      else body=esc(m.content);
      return trace+'<div class="msg assistant"><div class="who">ассистент</div><div class="bubble">'+body+'</div></div>';
    }).join('');
    // Восстанавливаем раскрытые трейсы после перерисовки.
    Array.prototype.forEach.call(thr.querySelectorAll('.trace'), function(d){ if(openMids[d.getAttribute('data-mid')]) d.open=true; });
    if(nearBottom) thr.scrollTop=thr.scrollHeight;
  }
  function maybePoll(){
    if(state.poll) clearInterval(state.poll);
    var pending=(state.chat&&state.chat.messages||[]).some(function(m){return m.status==='pending';});
    if(!pending) return;
    state.poll=setInterval(function(){ jfetch('/chat/chats/'+state.activeId).then(function(res){ if(!res.ok){clearInterval(state.poll);return;} state.chat=res.j; renderThread(); if(!(state.chat.messages||[]).some(function(m){return m.status==='pending';})){ clearInterval(state.poll); loadChats(); } }); },1500);
  }
  function sendMsg(){
    var text=$('input').value.trim(); if(!text||!state.activeId) return;
    $('send').disabled=true; $('input').value='';
    jfetch('/chat/chats/'+state.activeId+'/messages',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({content:text})})
      .then(function(res){ $('send').disabled=false; if(!res.ok){ alert((res.j.error&&res.j.error.message)||'Ошибка'); return; } selectChat(state.activeId); })
      .catch(function(e){ $('send').disabled=false; alert('Сеть: '+e.message); });
  }
  function logout(){ jfetch('/chat/auth/logout',{method:'POST'}).then(function(){ state.me=null; state.activeId=null; state.chat=null; state.chats=[]; showAuth(); }); }

  // ── Загрузка ──
  function boot(){
    jfetch('/chat/auth/me').then(function(res){
      state.me = res.j.user;
      if(!state.me){ showAuth(); return; }
      $('auth').style.display='none'; $('app').style.display='flex';
      $('uname').textContent = state.me.username + (state.me.isAdmin?' (admin)':'');
      $('adminLink').style.display = state.me.isAdmin ? 'inline' : 'none';
      loadChats();
    }).catch(function(){ showAuth(); });
  }

  $('authGo').addEventListener('click', doAuth);
  $('ap').addEventListener('keydown', function(e){ if(e.key==='Enter'){ doAuth(); } });
  $('new').addEventListener('click', newChat);
  $('send').addEventListener('click', sendMsg);
  $('logout').addEventListener('click', logout);
  $('mNormal').addEventListener('click', function(){ setMode('normal'); });
  $('mLoop').addEventListener('click', function(){ setMode('loop'); });
  $('input').addEventListener('keydown', function(e){ if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){ e.preventDefault(); sendMsg(); } });
  // Авто-высота поля ввода.
  $('input').addEventListener('input', function(){ this.style.height='auto'; this.style.height=Math.min(this.scrollHeight,180)+'px'; });
  renderAuthMode(); boot();
</script></body></html>`;

export const ADMIN_PAGE = String.raw`<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chat · админка</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:#0f1115; color:#e6e6e6; }
  .wrap { max-width:1100px; margin:0 auto; padding:18px; }
  h1 { font-size:18px; } h2 { font-size:15px; margin-top:24px; border-bottom:1px solid #232734; padding-bottom:6px; }
  a { color:#8ad0ff; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(130px,1fr)); gap:10px; }
  .card { background:#161a22; border:1px solid #232734; border-radius:10px; padding:12px; }
  .card span { color:#9aa4b2; font-size:12px; } .card b { font-size:16px; display:block; }
  .controls { margin:12px 0; display:flex; gap:14px; align-items:center; flex-wrap:wrap; font-size:13px; }
  table { width:100%; border-collapse:collapse; font-size:12px; margin-top:8px; }
  th,td { text-align:left; padding:6px 8px; border-bottom:1px solid #1c212c; vertical-align:top; }
  .muted { color:#9aa4b2; }
  .tag { display:inline-block; padding:1px 6px; border-radius:5px; font-size:11px; margin:1px; }
  .t-pwned{background:#3a1d1d;color:#ff6b6b;font-weight:700;} .t-security-high{background:#3a1d1d;color:#ff9b9b;}
  .t-gateway-intercept{background:#332a1a;color:#ffe08a;} .t-blocked{background:#2a1a2a;color:#e0a0ff;} .t-refusal{background:#1a2a2a;color:#8fe0d0;} .t-failed{background:#2a2a2a;color:#bbb;}
  #err { color:#ff9b9b; margin-top:10px; }
</style></head><body><div class="wrap">
<h1>Chat · админка <a href="/chat/" style="font-size:13px">← к чату</a></h1>
<div id="err"></div>
<div id="out" style="display:none">
  <h2>Статистика</h2>
  <div class="cards" id="stats"></div>
  <h2>Пользователи</h2>
  <table id="users"><thead><tr><th>Логин</th><th>Роль</th><th>Создан</th></tr></thead><tbody></tbody></table>
  <h2>Журнал сообщений</h2>
  <div class="controls">
    <label><input type="radio" name="mode" value="all" checked> Все</label>
    <label><input type="radio" name="mode" value="alerts"> Только алерты</label>
    <label><input type="checkbox" id="auto"> Автообновление (5 с)</label>
    <button id="refresh">Обновить</button>
  </div>
  <table id="msgs"><thead><tr><th>Время</th><th>Пользователь</th><th>Чат</th><th>Роль</th><th>Текст</th><th>Алерты</th></tr></thead><tbody></tbody></table>
</div>
<script>
  var $=function(id){return document.getElementById(id);};
  function esc(s){ var d=document.createElement('div'); d.textContent=s==null?'':String(s); return d.innerHTML; }
  function api(p){ return fetch(p).then(function(r){ if(r.status===401||r.status===403) throw new Error('нужен вход администратором — откройте /chat/ и войдите как админ'); if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); }); }
  function card(l,v){ return '<div class="card"><span>'+l+'</span><b>'+esc(v)+'</b></div>'; }
  var timer=null;
  function mode(){ return document.querySelector('input[name=mode]:checked').value; }
  function loadStats(){ return api('/chat/admin/stats').then(function(s){ $('stats').innerHTML=card('Пользователи',s.users)+card('Чаты',s.chats)+card('Сообщения',s.messages)+card('Алерты',s.alerts)+card('PWNED',s.pwned)+card('Стоимость','$'+(s.costUsd||0).toFixed(5)); }); }
  function loadUsers(){ return api('/chat/admin/users').then(function(j){ var tb=$('users').querySelector('tbody'); tb.innerHTML=(j.items||[]).map(function(u){ return '<tr><td>'+esc(u.username)+'</td><td>'+(u.isAdmin?'admin':'user')+'</td><td>'+esc((u.createdAt||'').replace('T',' ').slice(0,19))+'</td></tr>'; }).join(''); }); }
  function loadMsgs(){
    var path='/chat/admin/messages'+(mode()==='alerts'?'?alertsOnly=1':'');
    return api(path).then(function(j){
      var tb=$('msgs').querySelector('tbody');
      if(!(j.items||[]).length){ tb.innerHTML='<tr><td colspan="6" class="muted">пусто</td></tr>'; return; }
      tb.innerHTML=j.items.map(function(m){
        var kinds=(m.alertKinds||[]).map(function(k){ return '<span class="tag t-'+k+'">'+k+'</span>'; }).join('');
        return '<tr><td>'+esc((m.createdAt||'').replace('T',' ').slice(11,19))+'</td><td>'+esc(m.username)+'</td><td>'+esc((m.chatTitle||'').slice(0,24))+'</td><td>'+m.role+'</td><td>'+esc((m.content||'').slice(0,90))+'</td><td>'+kinds+'</td></tr>';
      }).join('');
    });
  }
  function loadAll(){ return Promise.all([loadStats(),loadUsers(),loadMsgs()]); }
  function refresh(){ loadAll().then(function(){ $('out').style.display='block'; $('err').textContent=''; }).catch(function(e){ $('err').innerHTML=esc(e.message); $('out').style.display='none'; }); }
  Array.prototype.forEach.call(document.querySelectorAll('input[name=mode]'), function(r){ r.addEventListener('change', function(){ loadMsgs().catch(function(){}); }); });
  $('refresh').addEventListener('click', refresh);
  $('auto').addEventListener('change', function(){ if(this.checked){ timer=setInterval(function(){ loadMsgs().catch(function(){}); },5000); } else if(timer){ clearInterval(timer); } });
  refresh();
</script></div></body></html>`;

export function registerWebRoutes(app: FastifyInstance): void {
  const html = (page: string) => (_req: unknown, reply: { type: (t: string) => { send: (b: string) => unknown } }) =>
    reply.type("text/html; charset=utf-8").send(page);
  app.get("/chat", html(CHAT_PAGE) as never);
  app.get("/chat/", html(CHAT_PAGE) as never);
  app.get("/chat/admin", html(ADMIN_PAGE) as never);
}
