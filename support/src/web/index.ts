// index.ts — самодостаточная веб-страница (SPA) одной строкой (порт web/index.ts MA).
//
// Ванильный JS + inline-CSS, без сборщика. Клиентский код НАМЕРЕННО без
// template-literal'ов (backtick/${}) — конфликтуют с этой обёрткой; строки
// собираются конкатенацией.
//
// Режимы (как в MA): гость — без аккаунта, история в localStorage, stateless
// /support/guest/chat; авторизованный — серверные чаты + контекст тикетов по
// email; админ — вкладки Настройки / База знаний / CRM / MCP / Пользователи.
// SSE-события чата: status (поиск в KB, вызовы инструментов), token, done, error.

export const INDEX_HTML = String.raw`<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Поддержка Second Brain</title>
<style>
:root{
  --bg:#f7f7f8; --panel:#ffffff; --border:#e3e3e8; --text:#1a1a1a; --muted:#6b7280;
  --accent:#0d9488; --accent-fg:#ffffff; --user:#d9f2ef; --assist:#f1f1f4; --danger:#dc2626; --ok:#16a34a;
}
:root[data-theme="dark"]{
  --bg:#0f1117; --panel:#171a21; --border:#2a2e37; --text:#e8e8ea; --muted:#9aa0ab;
  --accent:#14b8a6; --accent-fg:#062b28; --user:#134e4a; --assist:#20242d; --danger:#f87171; --ok:#4ade80;
}
*{box-sizing:border-box}
body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  background:var(--bg);color:var(--text);height:100vh;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;background:var(--panel);
  border-bottom:1px solid var(--border)}
header h1{font-size:15px;margin:0;font-weight:600}
header .spacer{flex:1}
button{font:inherit;cursor:pointer;border:1px solid var(--border);background:var(--panel);
  color:var(--text);border-radius:8px;padding:6px 12px}
button.primary{background:var(--accent);color:var(--accent-fg);border-color:transparent}
button.ghost{border-color:transparent;background:transparent;color:var(--muted)}
button.danger{color:var(--danger)}
button:disabled{opacity:.5;cursor:default}
.tabs{display:flex;gap:4px;padding:0 16px;background:var(--panel);border-bottom:1px solid var(--border)}
.tabs button{border:none;border-bottom:2px solid transparent;border-radius:0;padding:8px 12px;background:transparent}
.tabs button.active{border-bottom-color:var(--accent);color:var(--accent);font-weight:600}
.main{flex:1;display:flex;min-height:0}
.view{flex:1;display:none;min-height:0}
.view.active{display:flex}
.sidebar{width:250px;border-right:1px solid var(--border);background:var(--panel);
  display:flex;flex-direction:column;min-height:0}
.sidebar .list{flex:1;overflow:auto;padding:8px}
.sidebar .chat-item{padding:8px 10px;border-radius:8px;cursor:pointer;display:flex;
  align-items:center;gap:6px;color:var(--text)}
.sidebar .chat-item:hover{background:var(--assist)}
.sidebar .chat-item.active{background:var(--user)}
.sidebar .chat-item .t{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sidebar .chat-item .del{opacity:0;color:var(--muted)}
.sidebar .chat-item:hover .del{opacity:1}
.pane{flex:1;display:flex;flex-direction:column;min-height:0}
.messages{flex:1;overflow:auto;padding:18px;display:flex;flex-direction:column;gap:12px}
.msg{max-width:760px;padding:10px 14px;border-radius:12px;white-space:pre-wrap;word-wrap:break-word}
.msg.user{align-self:flex-end;background:var(--user)}
.msg.assistant{align-self:flex-start;background:var(--assist)}
.msg .meta{font-size:11px;color:var(--muted);margin-top:6px}
.msg .thinking{color:var(--muted);font-style:italic}
.composer{border-top:1px solid var(--border);padding:12px;background:var(--panel);display:flex;gap:8px}
.composer textarea{flex:1;resize:none;font:inherit;padding:10px;border-radius:10px;
  border:1px solid var(--border);background:var(--bg);color:var(--text);max-height:140px}
.admin{flex:1;overflow:auto;padding:20px;display:flex;flex-direction:column;gap:14px;max-width:900px}
.admin h2{margin:6px 0 0;font-size:16px}
.admin label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--muted)}
.admin input,.admin select,.admin textarea{font:inherit;padding:6px 8px;
  border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text)}
.admin textarea.code{font:12px/1.4 ui-monospace,Menlo,monospace;min-height:220px}
.admin .row{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end}
.admin .row label{flex:1;min-width:140px}
.admin table{border-collapse:collapse;width:100%;font-size:13px}
.admin th,.admin td{border:1px solid var(--border);padding:6px 8px;text-align:left}
.status{font-size:12px;color:var(--muted)}
.pill{font-size:11px;padding:2px 8px;border-radius:999px;background:var(--assist);color:var(--muted)}
.pill.ok{color:var(--ok)}
.pill.bad{color:var(--danger)}
.dialog-back{position:fixed;inset:0;background:rgba(0,0,0,.4);display:none;
  align-items:center;justify-content:center;z-index:10}
.dialog-back.open{display:flex}
.banner{padding:8px 16px;background:var(--assist);color:var(--muted);font-size:13px;
  border-bottom:1px solid var(--border)}
.dialog{background:var(--panel);border:1px solid var(--border);border-radius:12px;
  padding:24px;width:320px;display:flex;flex-direction:column;gap:12px}
.dialog h2{margin:0;font-size:16px}
.dialog input{font:inherit;padding:8px 10px;border-radius:8px;border:1px solid var(--border);
  background:var(--bg);color:var(--text)}
.dialog .err{color:var(--danger);font-size:12px;min-height:14px}
.sources{font-size:11px;color:var(--muted);margin-top:6px}
.fb{display:flex;gap:8px;margin-top:10px;align-items:center;flex-wrap:wrap}
.fb input{font:inherit;padding:5px 8px;border-radius:8px;border:1px solid var(--border);
  background:var(--bg);color:var(--text)}
.ticket{border:1px solid var(--border);border-radius:10px;margin-bottom:10px;background:var(--panel)}
.ticket .head{padding:10px 12px;cursor:pointer;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.ticket .detail{display:none;padding:4px 12px 12px;border-top:1px solid var(--border)}
.ticket.open .detail{display:block}
.tmsg{margin:8px 0;padding:8px 10px;border-radius:8px;background:var(--assist);white-space:pre-wrap}
.tmsg.user{background:var(--user)}
.tmsg .who{font-size:11px;color:var(--muted);margin-bottom:2px}
.pill.st-open{color:var(--danger)}
.pill.st-pending{color:#d97706}
.pill.st-closed{color:var(--ok)}
</style>
</head>
<body>
<header>
  <h1>Поддержка Second Brain</h1>
  <span id="llmStatus" class="pill">…</span>
  <span class="spacer"></span>
  <button id="themeBtn" class="ghost" title="Тема">🌓</button>
  <span id="authArea"></span>
</header>
<div id="tabs" class="tabs" style="display:none"></div>
<div id="banner" class="banner" style="display:none"></div>
<div class="main">

  <!-- Чат -->
  <div id="viewChat" class="view active">
    <div class="sidebar">
      <div style="padding:8px"><button id="newChatBtn" class="primary" style="width:100%">+ Новое обращение</button></div>
      <div id="chatList" class="list"></div>
    </div>
    <div class="pane">
      <div id="messages" class="messages"></div>
      <div class="composer">
        <textarea id="input" rows="2" placeholder="Опишите вопрос или проблему…"></textarea>
        <button id="sendBtn" class="primary">Отправить</button>
      </div>
    </div>
  </div>

  <!-- Админ: Настройки -->
  <div id="viewSettings" class="view"><div class="admin">
    <h2>Модель ответов</h2>
    <div class="row">
      <label>Провайдер
        <select id="setProvider">
          <option value="ollama">Локальная (Ollama на VPS)</option>
          <option value="deepseek">DeepSeek (облако)</option>
          <option value="openrouter">OpenRouter (облако)</option>
        </select>
      </label>
      <label>Локальная модель <select id="setLocalModel"></select></label>
      <label>Облачная модель <input id="setRemoteModel" list="remoteModels" /><datalist id="remoteModels"></datalist></label>
      <label>API-ключ (write-only) <input id="setKey" type="password" placeholder="" /></label>
    </div>
    <h2>Поведение</h2>
    <label>Системный промпт <textarea id="setSys" rows="5"></textarea></label>
    <div class="row">
      <label>RAG topK <input id="setTopK" type="number" min="1" max="20" /></label>
      <label>RAG minScore <input id="setMinScore" type="number" step="0.05" min="0" max="1" /></label>
      <label>RAG бюджет, ток. <input id="setBudget" type="number" step="100" min="100" max="8000" /></label>
      <label>Макс. итераций tool-loop <input id="setIter" type="number" min="1" max="10" /></label>
    </div>
    <div class="row">
      <button id="saveSettingsBtn" class="primary">Сохранить</button>
      <span id="settingsStatus" class="status"></span>
    </div>
    <label>Модель эмбеддингов (после смены — переиндексируйте базу знаний)
      <input id="setEmbed" />
    </label>
  </div></div>

  <!-- Админ: База знаний -->
  <div id="viewKb" class="view"><div class="admin">
    <h2>База знаний (FAQ и документация)</h2>
    <div class="row">
      <span id="kbMeta" class="status"></span>
      <span class="spacer"></span>
      <button id="kbReindexBtn" class="primary">Переиндексировать</button>
    </div>
    <div class="row">
      <label>Файл <select id="kbFileSel"></select></label>
      <button id="kbNewBtn">+ Новый файл</button>
      <button id="kbDelBtn" class="danger">Удалить</button>
    </div>
    <label>Содержимое <textarea id="kbContent" class="code"></textarea></label>
    <div class="row">
      <button id="kbSaveBtn" class="primary">Сохранить файл</button>
      <span id="kbStatus" class="status"></span>
    </div>
    <h2>Тестовый поиск</h2>
    <div class="row">
      <label>Запрос <input id="kbQuery" placeholder="почему не работает авторизация" /></label>
      <button id="kbSearchBtn">Искать</button>
    </div>
    <div id="kbHits"></div>
  </div></div>

  <!-- Админ: Обращения (CRM) -->
  <div id="viewCrm" class="view"><div class="admin">
    <h2>Обращения</h2>
    <div class="row">
      <label style="flex:0;min-width:160px">Фильтр
        <select id="ticketFilter">
          <option value="">все</option>
          <option value="open">открытые</option>
          <option value="pending">в работе</option>
          <option value="closed">закрытые</option>
        </select>
      </label>
      <button id="ticketsRefreshBtn">Обновить</button>
      <span id="ticketsStatus" class="status"></span>
    </div>
    <div id="ticketList"></div>
    <details>
      <summary class="status" style="cursor:pointer">Продвинутый режим: JSON-редакторы (users.json / tickets.json)</summary>
      <h2>CRM: пользователи (users.json)</h2>
      <label><textarea id="crmUsers" class="code"></textarea></label>
      <div class="row"><button id="crmUsersSaveBtn" class="primary">Сохранить пользователей</button><span id="crmUsersStatus" class="status"></span></div>
      <h2>CRM: тикеты (tickets.json)</h2>
      <label><textarea id="crmTickets" class="code"></textarea></label>
      <div class="row"><button id="crmTicketsSaveBtn" class="primary">Сохранить тикеты</button><span id="crmTicketsStatus" class="status"></span></div>
    </details>
  </div></div>

  <!-- Админ: MCP -->
  <div id="viewMcp" class="view"><div class="admin">
    <h2>MCP-серверы (инструменты ассистента)</h2>
    <div id="mcpTable"></div>
    <div class="row">
      <button id="mcpRefreshBtn">Переподключить</button>
      <span id="mcpStatus" class="status"></span>
    </div>
    <label>Конфигурация (JSON, секреты в env/args сохраняются как введено)
      <textarea id="mcpJson" class="code"></textarea>
    </label>
    <div class="row"><button id="mcpSaveBtn" class="primary">Сохранить конфигурацию</button></div>
  </div></div>

  <!-- Админ: Пользователи -->
  <div id="viewUsers" class="view"><div class="admin">
    <h2>Аккаунты веб-интерфейса</h2>
    <div id="usersTable"></div>
    <h2>Создать аккаунт</h2>
    <div class="row">
      <label>Логин <input id="nuName" /></label>
      <label>Email (связь с CRM) <input id="nuEmail" /></label>
      <label>Пароль <input id="nuPass" type="password" /></label>
      <label style="flex:0;min-width:90px">Админ <input id="nuAdmin" type="checkbox" style="width:20px;height:20px" /></label>
      <button id="nuCreateBtn" class="primary">Создать</button>
    </div>
    <span id="usersStatus" class="status"></span>
  </div></div>

</div>

<!-- Вход (модально; аккаунт не обязателен) -->
<div id="loginBack" class="dialog-back">
  <div class="dialog">
    <h2>Вход в поддержку</h2>
    <input id="loginUser" placeholder="Логин" autocomplete="username" />
    <input id="loginPass" type="password" placeholder="Пароль" autocomplete="current-password" />
    <div id="loginErr" class="err"></div>
    <div style="display:flex;gap:8px;justify-content:flex-end">
      <button id="loginCancel" class="ghost">Отмена</button>
      <button id="loginSubmit" class="primary">Войти</button>
    </div>
    <div class="status">Аккаунт выдаёт администратор. Без входа чат тоже работает — история хранится только в этом браузере.</div>
  </div>
</div>

<script>
(function(){
"use strict";
var API = "/support";
var state = { me:null, currentId:null, busy:false, tab:"chat", kbFiles:[], settings:null, guest:[] };

function $(id){ return document.getElementById(id); }
function el(tag, cls, text){ var e=document.createElement(tag); if(cls)e.className=cls; if(text!=null)e.textContent=text; return e; }
function ls(key, val){ try{ if(val===undefined) return localStorage.getItem(key); localStorage.setItem(key,val); }catch(e){} return null; }

function applyTheme(t){ document.documentElement.setAttribute("data-theme", t); ls("theme", t); }
(function initTheme(){
  var t = ls("theme");
  if(!t){ t = (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "dark":"light"; }
  applyTheme(t);
})();

function api(path, opts){
  opts = opts || {};
  var init = { method: opts.method || "GET", credentials:"include", headers:{} };
  if(opts.body!==undefined){ init.headers["Content-Type"]="application/json"; init.body=JSON.stringify(opts.body); }
  return fetch(API+path, init).then(function(r){
    if(r.status===204) return null;
    return r.json().then(function(j){ if(!r.ok){ var m=(j&&j.error&&j.error.message)||("Ошибка "+r.status); var e=new Error(m); e.code=j&&j.error&&j.error.code; throw e; } return j; });
  });
}

// ── Вкладки ──
var TABS = [
  {id:"chat", title:"Чат", admin:false},
  {id:"settings", title:"Настройки", admin:true},
  {id:"kb", title:"База знаний", admin:true},
  {id:"crm", title:"CRM", admin:true},
  {id:"mcp", title:"MCP", admin:true},
  {id:"users", title:"Пользователи", admin:true}
];
function viewId(tab){ return "view"+tab.charAt(0).toUpperCase()+tab.slice(1); }
function renderTabs(){
  var bar=$("tabs"); bar.innerHTML="";
  var visible = TABS.filter(function(t){ return !t.admin || (state.me && state.me.isAdmin); });
  if(visible.length<=1){ bar.style.display="none"; }
  else {
    bar.style.display="flex";
    visible.forEach(function(t){
      var b=el("button",(state.tab===t.id?"active":""),t.title);
      b.onclick=function(){ selectTab(t.id); };
      bar.appendChild(b);
    });
  }
}
function selectTab(tab){
  state.tab=tab;
  ["viewChat","viewSettings","viewKb","viewCrm","viewMcp","viewUsers"].forEach(function(v){
    $(v).classList.remove("active");
  });
  $(viewId(tab)).classList.add("active");
  renderTabs();
  if(tab==="settings") loadSettings();
  if(tab==="kb") loadKb();
  if(tab==="crm") loadCrm();
  if(tab==="mcp") loadMcp();
  if(tab==="users") loadUsers();
}

// ── Авторизация ──
function renderAuth(){
  var a = $("authArea"); a.innerHTML="";
  if(state.me){
    a.appendChild(el("span","pill", state.me.username + (state.me.isAdmin?" · админ":"")));
    var out = el("button","ghost","Выйти");
    out.onclick = doLogout;
    a.appendChild(out);
    $("banner").style.display="none";
  } else {
    var login = el("button","primary","Войти");
    login.onclick = function(){ $("loginErr").textContent=""; $("loginBack").classList.add("open"); $("loginUser").focus(); };
    a.appendChild(login);
    $("banner").style.display="block";
    $("banner").textContent="Гостевой режим: история обращения хранится только в этом браузере. Войдите, чтобы сохранять обращения на сервере и получать ответы с учётом ваших прошлых заявок.";
  }
}
function doLogin(){
  var u=$("loginUser").value, p=$("loginPass").value;
  api("/auth/login",{method:"POST",body:{username:u,password:p}}).then(function(res){
    state.me = res.user; $("loginPass").value="";
    $("loginBack").classList.remove("open");
    boot();
  }).catch(function(e){ $("loginErr").textContent = e.message; });
}
function doLogout(){
  api("/auth/logout",{method:"POST"}).then(function(){ state.me=null; state.currentId=null; boot(); });
}

// ── Чат ──
function loadChats(){
  var list=$("chatList"); list.innerHTML="";
  if(!state.me){
    var note = el("div","status","Гость: одно обращение, история в этом браузере. Войдите, чтобы вести несколько обращений.");
    note.style.padding="8px"; list.appendChild(note);
    return Promise.resolve();
  }
  return api("/chats").then(function(page){
    (page.items||[]).forEach(function(s){
      var item = el("div","chat-item"+(s.id===state.currentId?" active":""));
      var t = el("div","t", s.title || "Без темы");
      var del = el("span","del","✕");
      del.onclick=function(ev){ ev.stopPropagation(); if(confirm("Удалить обращение?")) api("/chats/"+s.id,{method:"DELETE"}).then(function(){ if(state.currentId===s.id){ state.currentId=null; clearMessages(); } loadChats(); }); };
      item.onclick=function(){ selectChat(s.id); };
      item.appendChild(t); item.appendChild(del); list.appendChild(item);
    });
  });
}
function clearMessages(){ $("messages").innerHTML=""; }
function addMessage(role, content){
  var m = el("div","msg "+role);
  var body = el("div", null, content);
  m.appendChild(body);
  $("messages").appendChild(m);
  $("messages").scrollTop = $("messages").scrollHeight;
  return { el:m, body:body };
}
function setMeta(m, res){
  var parts=[];
  if(res.usage) parts.push("↑"+res.usage.promptTokens+" ↓"+res.usage.completionTokens+" ток.");
  if(res.timings && res.timings.tokensPerSecond) parts.push(res.timings.tokensPerSecond+" ток/с");
  if(res.toolCalls && res.toolCalls.length) parts.push("инструменты: "+res.toolCalls.map(function(t){return t.name+(t.ok?"":"⚠");}).join(", "));
  if(res.droppedCount) parts.push("обрезано сообщений: "+res.droppedCount);
  if(parts.length) m.el.appendChild(el("div","meta", parts.join(" · ")));
  if(res.sources && res.sources.length){
    var src = res.sources.map(function(s){ return s.path+(s.section?(" · "+s.section):"")+" ("+s.score+")"; }).join("; ");
    m.el.appendChild(el("div","sources","Источники: "+src));
  }
}

function streamChat(path, body, assistant){
  return fetch(API+path, { method:"POST", credentials:"include",
    headers:{"Content-Type":"application/json"}, body:JSON.stringify(body) }).then(function(r){
    if(!r.ok){ return r.json().then(function(j){ throw new Error((j&&j.error&&j.error.message)||("Ошибка "+r.status)); }); }
    var reader = r.body.getReader(); var dec = new TextDecoder(); var buf=""; var done=null; var streamed=false;
    function handle(ev, data){
      if(ev==="status"){ try{ var s=JSON.parse(data); assistant.body.textContent=""; assistant.body.appendChild(el("span","thinking",s.status)); }catch(e){} }
      else if(ev==="token"){ try{ var d=JSON.parse(data);
        if(!streamed){ assistant.body.textContent=""; streamed=true; }
        assistant.body.textContent += d.delta; $("messages").scrollTop=$("messages").scrollHeight; }catch(e){} }
      else if(ev==="done"){ try{ done=JSON.parse(data); }catch(e){} }
      else if(ev==="error"){ var er=JSON.parse(data); throw new Error(er.error.message); }
    }
    function pump(){
      return reader.read().then(function(res){
        if(res.done) return done;
        buf += dec.decode(res.value, {stream:true});
        var idx;
        while((idx=buf.indexOf("\n\n"))>=0){
          var chunk = buf.slice(0,idx); buf=buf.slice(idx+2);
          var ev="message", data="";
          chunk.split("\n").forEach(function(line){
            if(line.indexOf("event:")===0) ev=line.slice(6).trim();
            else if(line.indexOf("data:")===0) data+=line.slice(5).trim();
          });
          if(data) handle(ev, data);
        }
        return pump();
      });
    }
    return pump();
  });
}

function send(){
  if(state.busy) return;
  var text = $("input").value.trim();
  if(!text) return;
  $("input").value="";
  state.busy=true; $("sendBtn").disabled=true;
  addMessage("user", text);
  var assistant = addMessage("assistant", "");
  assistant.body.appendChild(el("span","thinking","…"));

  var finishOk = function(done){
    if(done){
      var content = done.assistantMessage ? done.assistantMessage.content
        : (done.message ? done.message.content : assistant.body.textContent);
      assistant.body.textContent = content;
      setMeta(assistant, done);
      if(state.me) loadChats();
      else {
        state.guest.push({role:"user",content:text});
        state.guest.push({role:"assistant",content:content});
        ls("guestHistory", JSON.stringify(state.guest));
      }
      addFeedbackBar(assistant.el);
    }
  };
  var fail = function(e){ assistant.body.textContent = "⚠ "+e.message; };
  var always = function(){ state.busy=false; $("sendBtn").disabled=false; $("input").focus(); };

  if(state.me){
    ensureSession().then(function(sid){
      return streamChat("/chats/"+sid+"/messages", {content:text, stream:true}, assistant);
    }).then(finishOk).catch(fail).then(always);
  } else {
    var msgs = state.guest.concat([{role:"user",content:text}]);
    streamChat("/guest/chat", {messages:msgs, stream:true}, assistant).then(finishOk).catch(fail).then(always);
  }
}
// ── Фидбек «решено/не решено» → обращение в CRM ──
var fbCurrent=null;
function addFeedbackBar(msgEl){
  if(fbCurrent && fbCurrent.parentNode) fbCurrent.parentNode.removeChild(fbCurrent);
  var bar=el("div","fb");
  bar.appendChild(el("span","status","Ответ помог?"));
  var yes=el("button",null,"✓ Да, решено");
  var no=el("button",null,"Нет, передать в поддержку");
  bar.appendChild(yes); bar.appendChild(no);
  msgEl.appendChild(bar); fbCurrent=bar;
  $("messages").scrollTop=$("messages").scrollHeight;
  yes.onclick=function(){ sendFeedback(bar,true,null,null); };
  no.onclick=function(){
    if(state.me) sendFeedback(bar,false,null,null);
    else showGuestFeedbackForm(bar);
  };
}
function showGuestFeedbackForm(bar){
  bar.innerHTML="";
  bar.appendChild(el("span","status","Оставьте email — поддержка ответит:"));
  var em=document.createElement("input"); em.placeholder="email"; em.type="email";
  var cm=document.createElement("input"); cm.placeholder="комментарий (необязательно)"; cm.style.minWidth="200px";
  var send=el("button","primary","Отправить в поддержку");
  bar.appendChild(em); bar.appendChild(cm); bar.appendChild(send);
  em.focus();
  send.onclick=function(){ sendFeedback(bar,false,em.value.trim(),cm.value.trim()); };
}
function sendFeedback(bar,resolved,email,comment){
  var body={resolved:resolved};
  if(state.me && state.currentId){ body.chatId=state.currentId; }
  else { body.messages=state.guest; if(email) body.email=email; if(comment) body.comment=comment; }
  api("/feedback",{method:"POST",body:body}).then(function(r){
    bar.innerHTML="";
    if(r.ticketId){
      bar.appendChild(el("span","status", resolved
        ? ("Спасибо! Обращение "+r.ticketId+" отмечено решённым.")
        : ("Обращение "+r.ticketId+" передано в поддержку — мы свяжемся с вами.")));
    } else {
      bar.appendChild(el("span","status","Спасибо за отметку!"));
    }
  }).catch(function(e){
    var err=el("span","status","⚠ "+e.message);
    bar.appendChild(err);
    setTimeout(function(){ if(err.parentNode) err.parentNode.removeChild(err); }, 4000);
  });
}

function ensureSession(){
  if(state.currentId) return Promise.resolve(state.currentId);
  return api("/chats",{method:"POST",body:{}}).then(function(s){
    state.currentId=s.id; ls("lastChatId", s.id); loadChats(); return s.id;
  });
}
function selectChat(id){
  state.currentId=id; ls("lastChatId", id); clearMessages();
  api("/chats/"+id).then(function(res){
    var lastB=null, lastRole=null;
    (res.messages||[]).forEach(function(m){
      var b=addMessage(m.role, m.content);
      if(m.usage||m.toolCalls) setMeta(b, {usage:m.usage, toolCalls:m.toolCalls});
      lastB=b; lastRole=m.role;
    });
    // Плашка фидбека переживает перерисовку: диалог мог быть открыт заново.
    if(lastRole==="assistant" && lastB) addFeedbackBar(lastB.el);
    loadChats();
  }).catch(function(){
    // Диалог удалён/чужой (протухший lastChatId) — начинаем с чистого листа.
    state.currentId=null; ls("lastChatId","");
  });
}
function newChat(){
  state.currentId=null; ls("lastChatId","");
  clearMessages();
  if(!state.me){ state.guest=[]; ls("guestHistory","[]"); }
  loadChats(); $("input").focus();
}

function loadHealth(){
  api("/llm/health").then(function(h){
    var label = h.provider==="ollama" ? "локальная модель" : h.provider;
    $("llmStatus").textContent = (h.reachable||h.provider!=="ollama") ? (label+" · готов") : (label+" · недоступна");
    $("llmStatus").className = "pill "+((h.reachable||h.provider!=="ollama")?"ok":"bad");
  }).catch(function(){ $("llmStatus").textContent="—"; });
}

// ── Админ: Настройки ──
function loadSettings(){
  Promise.all([api("/admin/settings"), api("/admin/models")]).then(function(res){
    var s=res[0], models=res[1];
    state.settings=s;
    $("setProvider").value=s.provider;
    var sel=$("setLocalModel"); sel.innerHTML="";
    (models.local||[]).forEach(function(m){
      var o=el("option",null,m.name+(m.parameterSize?(" · "+m.parameterSize):"")); o.value=m.name; sel.appendChild(o);
    });
    if(s.localModel){
      if(!(models.local||[]).some(function(m){return m.name===s.localModel;})){
        var o=el("option",null,s.localModel+" (не установлена)"); o.value=s.localModel; sel.appendChild(o);
      }
      sel.value=s.localModel;
    }
    var dl=$("remoteModels"); dl.innerHTML="";
    var suggestions=(models.remote&&models.remote[s.provider])||[].concat(models.remote&&models.remote.deepseek||[],models.remote&&models.remote.openrouter||[]);
    (suggestions||[]).forEach(function(m){ var o=el("option"); o.value=m; dl.appendChild(o); });
    $("setRemoteModel").value=s.remoteModel||"";
    $("setKey").placeholder = s.hasLlmKey ? ("сохранён "+s.llmKeyHint+" — введите, чтобы заменить") : "не задан";
    $("setKey").value="";
    $("setSys").value=s.systemPrompt||"";
    $("setTopK").value=s.rag.topK; $("setMinScore").value=s.rag.minScore; $("setBudget").value=s.rag.budgetTokens;
    $("setIter").value=s.maxIterations;
    $("setEmbed").value=s.embedModel||"";
  }).catch(function(e){ $("settingsStatus").textContent=e.message; });
}
function saveSettings(){
  var body = {
    provider: $("setProvider").value,
    localModel: $("setLocalModel").value,
    remoteModel: $("setRemoteModel").value,
    systemPrompt: $("setSys").value,
    embedModel: $("setEmbed").value,
    maxIterations: parseInt($("setIter").value,10),
    rag: { topK: parseInt($("setTopK").value,10), minScore: parseFloat($("setMinScore").value), budgetTokens: parseInt($("setBudget").value,10) }
  };
  var key=$("setKey").value.trim();
  if(key) body.llmApiKey=key;
  api("/admin/settings",{method:"PATCH",body:body}).then(function(){
    $("settingsStatus").textContent="Сохранено"; $("setKey").value="";
    setTimeout(function(){$("settingsStatus").textContent="";},1500);
    loadSettings(); loadHealth();
  }).catch(function(e){ $("settingsStatus").textContent=e.message; });
}

// ── Админ: База знаний ──
function loadKb(){
  api("/admin/kb").then(function(res){
    state.kbFiles=res.files||[];
    var sel=$("kbFileSel"); var prev=sel.value; sel.innerHTML="";
    state.kbFiles.forEach(function(f){ var o=el("option",null,f); o.value=f; sel.appendChild(o); });
    if(prev && state.kbFiles.indexOf(prev)>=0) sel.value=prev;
    var m=res.meta||{};
    $("kbMeta").textContent = "Статус: "+(res.indexing?"индексация…":(m.status||"—"))
      +" · чанков: "+(m.chunkCount||0)
      +(m.embeddingTag?(" · эмбеддер: "+m.embeddingTag):"")
      +(m.lastError?(" · ошибка: "+m.lastError):"");
    if(res.indexing) setTimeout(loadKb, 2000);
    if(sel.value) loadKbFile();
    else $("kbContent").value="";
  });
}
function loadKbFile(){
  var name=$("kbFileSel").value;
  if(!name) return;
  api("/admin/kb/file?name="+encodeURIComponent(name)).then(function(res){
    $("kbContent").value=res.content;
  });
}
function saveKbFile(){
  var name=$("kbFileSel").value;
  if(!name) return;
  api("/admin/kb/file",{method:"PUT",body:{name:name,content:$("kbContent").value}}).then(function(){
    $("kbStatus").textContent="Сохранено. Не забудьте переиндексировать.";
    setTimeout(function(){$("kbStatus").textContent="";},3000);
  }).catch(function(e){ $("kbStatus").textContent=e.message; });
}
function newKbFile(){
  var name=prompt("Имя файла (имя.md):");
  if(!name) return;
  if(!/\.md$/.test(name)){ alert("Имя должно оканчиваться на .md"); return; }
  api("/admin/kb/file",{method:"PUT",body:{name:name,content:"# "+name.replace(/\.md$/,"")+"\n\n"}}).then(function(){
    loadKb();
  }).catch(function(e){ alert(e.message); });
}
function delKbFile(){
  var name=$("kbFileSel").value;
  if(!name || !confirm("Удалить файл "+name+"?")) return;
  api("/admin/kb/file?name="+encodeURIComponent(name),{method:"DELETE"}).then(loadKb).catch(function(e){ alert(e.message); });
}
function reindexKb(){
  api("/admin/kb/reindex",{method:"POST"}).then(function(){ loadKb(); }).catch(function(e){ alert(e.message); });
}
function searchKbUi(){
  var q=$("kbQuery").value.trim();
  if(!q) return;
  api("/admin/kb/search",{method:"POST",body:{query:q}}).then(function(res){
    var box=$("kbHits"); box.innerHTML="";
    if(!(res.hits||[]).length){ box.appendChild(el("div","status","Ничего не найдено.")); return; }
    res.hits.forEach(function(h){
      var d=el("div","msg assistant");
      d.appendChild(el("div","meta",h.path+(h.section?(" · "+h.section):"")+" · score "+h.score));
      d.appendChild(el("div",null,h.preview));
      box.appendChild(d);
    });
  });
}

// ── Админ: Обращения (CRM) ──
function fmtDate(s){ return (s||"").slice(0,16).replace("T"," "); }
function stPill(s){
  var label = s==="open"?"открыт":(s==="pending"?"в работе":"закрыт");
  return el("span","pill st-"+s,label);
}
function loadTickets(){
  api("/admin/crm/tickets").then(function(res){
    var filter=$("ticketFilter").value;
    var items=(res.items||[]).filter(function(t){ return !filter || t.status===filter; });
    var box=$("ticketList"); box.innerHTML="";
    $("ticketsStatus").textContent = items.length ? (items.length+" обращений") : "";
    if(!items.length){ box.appendChild(el("div","status","Обращений нет.")); return; }
    items.forEach(function(t){ box.appendChild(renderTicket(t)); });
  });
}
function renderTicket(t){
  var card=el("div","ticket");
  var head=el("div","head");
  head.appendChild(el("span","pill",t.id));
  head.appendChild(stPill(t.status));
  var subj=el("span",null,t.subject||"(без темы)");
  subj.style.fontWeight="600"; subj.style.flex="1"; subj.style.minWidth="180px";
  head.appendChild(subj);
  head.appendChild(el("span","status", t.user ? (t.user.name+" · "+t.user.email) : t.user_id));
  head.appendChild(el("span","status",fmtDate(t.updated_at)));
  card.appendChild(head);

  var detail=el("div","detail");
  (t.messages||[]).forEach(function(m){
    var b=el("div","tmsg "+(m.author==="user"?"user":""));
    b.appendChild(el("div","who",(m.author==="user"?"Клиент":"Поддержка")+" · "+fmtDate(m.at)));
    b.appendChild(el("div",null,m.text));
    detail.appendChild(b);
  });
  if(t.tags && t.tags.length) detail.appendChild(el("div","status","Теги: "+t.tags.join(", ")));

  var ctl=el("div","row");
  var lbl=el("label",null,"Статус"); lbl.style.flex="0"; lbl.style.minWidth="140px";
  var sel=document.createElement("select");
  [["open","открыт"],["pending","в работе"],["closed","закрыт"]].forEach(function(o){
    var op=el("option",null,o[1]); op.value=o[0]; sel.appendChild(op);
  });
  sel.value=t.status;
  sel.onchange=function(){
    api("/admin/crm/tickets/"+t.id+"/status",{method:"POST",body:{status:sel.value}}).then(loadTickets)
      .catch(function(e){ alert(e.message); });
  };
  lbl.appendChild(sel); ctl.appendChild(lbl);
  var reply=document.createElement("input"); reply.placeholder="Ответ поддержки…"; reply.style.flex="1";
  var send=el("button","primary","Ответить");
  send.onclick=function(){
    var txt=reply.value.trim(); if(!txt) return;
    api("/admin/crm/tickets/"+t.id+"/comment",{method:"POST",body:{text:txt}}).then(loadTickets)
      .catch(function(e){ alert(e.message); });
  };
  ctl.appendChild(reply); ctl.appendChild(send);
  detail.appendChild(ctl);
  card.appendChild(detail);

  head.onclick=function(){ card.classList.toggle("open"); };
  return card;
}

function loadCrm(){
  loadTickets();
  api("/admin/crm/users").then(function(res){ $("crmUsers").value=JSON.stringify(res.items,null,2); });
  api("/admin/crm/tickets").then(function(res){
    $("crmTickets").value=JSON.stringify((res.items||[]).map(function(t){ var c=Object.assign({},t); delete c.user; return c; }),null,2);
  });
}
function saveCrm(kind){
  var ta = kind==="users" ? $("crmUsers") : $("crmTickets");
  var status = kind==="users" ? $("crmUsersStatus") : $("crmTicketsStatus");
  var items;
  try{ items=JSON.parse(ta.value); }catch(e){ status.textContent="Некорректный JSON: "+e.message; return; }
  api("/admin/crm/"+kind,{method:"PUT",body:{items:items}}).then(function(){
    status.textContent="Сохранено"; setTimeout(function(){status.textContent="";},1500);
  }).catch(function(e){ status.textContent=e.message; });
}

// ── Админ: MCP ──
function loadMcp(){
  api("/admin/mcp-servers").then(function(res){
    var box=$("mcpTable"); box.innerHTML="";
    var tbl=el("table");
    var head=el("tr"); ["Имя","Команда","Вкл","Подключён","Инструментов","Ошибка"].forEach(function(h){ head.appendChild(el("th",null,h)); });
    tbl.appendChild(head);
    (res.items||[]).forEach(function(s){
      var tr=el("tr");
      tr.appendChild(el("td",null,s.name));
      tr.appendChild(el("td",null,s.command));
      tr.appendChild(el("td",null,s.enabled?"да":"нет"));
      tr.appendChild(el("td",null,s.connected?"да":"нет"));
      tr.appendChild(el("td",null,String(s.toolCount)));
      tr.appendChild(el("td",null,s.error||""));
      tbl.appendChild(tr);
    });
    box.appendChild(tbl);
  });
}
function refreshMcp(){
  $("mcpStatus").textContent="Переподключаю…";
  api("/admin/mcp-servers/refresh",{method:"POST"}).then(function(){
    $("mcpStatus").textContent=""; loadMcp();
  }).catch(function(e){ $("mcpStatus").textContent=e.message; });
}
function saveMcp(){
  var servers;
  try{ servers=JSON.parse($("mcpJson").value); }catch(e){ alert("Некорректный JSON: "+e.message); return; }
  api("/admin/mcp-servers",{method:"PUT",body:{servers:servers}}).then(function(){
    $("mcpJson").value=""; loadMcp();
  }).catch(function(e){ alert(e.message); });
}

// ── Админ: Пользователи ──
function loadUsers(){
  api("/admin/users").then(function(res){
    var box=$("usersTable"); box.innerHTML="";
    var tbl=el("table");
    var head=el("tr"); ["Логин","Email","Роль","Создан",""].forEach(function(h){ head.appendChild(el("th",null,h)); });
    tbl.appendChild(head);
    (res.items||[]).forEach(function(u){
      var tr=el("tr");
      tr.appendChild(el("td",null,u.username));
      tr.appendChild(el("td",null,u.email||"—"));
      tr.appendChild(el("td",null,u.isAdmin?"админ":"пользователь"));
      tr.appendChild(el("td",null,(u.createdAt||"").slice(0,10)));
      var td=el("td");
      var del=el("button","danger","Удалить");
      del.onclick=function(){ if(confirm("Удалить аккаунт "+u.username+"?")) api("/admin/users/"+u.id,{method:"DELETE"}).then(loadUsers); };
      td.appendChild(del); tr.appendChild(td);
      tbl.appendChild(tr);
    });
    box.appendChild(tbl);
  });
}
function createUser(){
  api("/admin/users",{method:"POST",body:{
    username:$("nuName").value, password:$("nuPass").value,
    email:$("nuEmail").value, isAdmin:$("nuAdmin").checked
  }}).then(function(){
    $("nuName").value=""; $("nuEmail").value=""; $("nuPass").value=""; $("nuAdmin").checked=false;
    $("usersStatus").textContent="Создан"; setTimeout(function(){$("usersStatus").textContent="";},1500);
    loadUsers();
  }).catch(function(e){ $("usersStatus").textContent=e.message; });
}

// ── Инициализация ──
function boot(){
  renderAuth();
  clearMessages();
  selectTab("chat");
  if(!state.me){
    try{ state.guest = JSON.parse(ls("guestHistory")||"[]")||[]; }catch(e){ state.guest=[]; }
    var lastB=null, lastRole=null;
    state.guest.forEach(function(m){ lastB=addMessage(m.role, m.content); lastRole=m.role; });
    // После перезагрузки страницы кнопки «решено / в поддержку» остаются.
    if(lastRole==="assistant" && lastB) addFeedbackBar(lastB.el);
  } else {
    // Вошедший: после перезагрузки открываем последний диалог (id в браузере).
    var last = state.currentId || ls("lastChatId");
    if(last) selectChat(last);
  }
  loadChats(); loadHealth();
}

// ── События ──
$("themeBtn").onclick=function(){ applyTheme(document.documentElement.getAttribute("data-theme")==="dark"?"light":"dark"); };
$("newChatBtn").onclick=newChat;
$("sendBtn").onclick=send;
$("input").addEventListener("keydown",function(e){ if(e.key==="Enter" && !e.shiftKey){ e.preventDefault(); send(); } });
$("loginSubmit").onclick=doLogin;
$("loginCancel").onclick=function(){ $("loginBack").classList.remove("open"); };
$("loginPass").addEventListener("keydown",function(e){ if(e.key==="Enter") doLogin(); });
$("saveSettingsBtn").onclick=saveSettings;
$("kbFileSel").onchange=loadKbFile;
$("kbSaveBtn").onclick=saveKbFile;
$("kbNewBtn").onclick=newKbFile;
$("kbDelBtn").onclick=delKbFile;
$("kbReindexBtn").onclick=reindexKb;
$("kbSearchBtn").onclick=searchKbUi;
$("crmUsersSaveBtn").onclick=function(){ saveCrm("users"); };
$("crmTicketsSaveBtn").onclick=function(){ saveCrm("tickets"); };
$("ticketsRefreshBtn").onclick=loadTickets;
$("ticketFilter").onchange=loadTickets;
$("mcpRefreshBtn").onclick=refreshMcp;
$("mcpSaveBtn").onclick=saveMcp;
$("nuCreateBtn").onclick=createUser;

api("/auth/me").then(function(r){ state.me=r.user; boot(); }).catch(function(){ state.me=null; boot(); });
setInterval(loadHealth, 30000);
})();
</script>
</body>
</html>`;
