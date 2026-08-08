// index.ts — две страницы без сборщика: чат для атакующего и админка владельца.
//
// Разметка отдаётся строкой (порт подхода support/src/web): у сервиса нет
// фронтенд-сборки, а лаборатории хватает одного экрана на роль.

export const CHAT_PAGE = `<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Аврора — рабочий ассистент</title>
<style>
 :root { color-scheme: light dark; --bg:#fff; --fg:#111; --mut:#666; --line:#dcdcdc; --acc:#2d6cdf; --box:#f5f6f8; }
 @media (prefers-color-scheme: dark) { :root { --bg:#16181c; --fg:#e8e8ea; --mut:#9aa0a6; --line:#2c2f36; --acc:#6ea1ff; --box:#1f2229; } }
 * { box-sizing:border-box }
 body { margin:0; font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--fg) }
 header { padding:14px 18px; border-bottom:1px solid var(--line); display:flex; gap:10px; align-items:baseline }
 header b { font-size:16px } header span { color:var(--mut); font-size:13px }
 main { max-width:820px; margin:0 auto; padding:18px }
 .msg { padding:10px 14px; border-radius:10px; margin:10px 0; white-space:pre-wrap; word-wrap:break-word }
 .user { background:var(--acc); color:#fff; margin-left:15% }
 .bot { background:var(--box); margin-right:10% }
 .tools { font-size:12px; color:var(--mut); margin:-4px 0 10px 4px }
 form { display:flex; gap:8px; margin-top:16px }
 input,textarea,button { font:inherit; border-radius:8px; border:1px solid var(--line); padding:10px 12px; background:var(--bg); color:var(--fg) }
 textarea { flex:1; resize:vertical; min-height:56px }
 button { background:var(--acc); color:#fff; border:0; cursor:pointer; padding:10px 18px }
 button:disabled { opacity:.5; cursor:default }
 .gate { max-width:420px; margin:12vh auto; text-align:center }
 .gate input { width:100%; margin:8px 0 }
 .err { color:#d33; font-size:13px; min-height:18px }
 .bar { display:flex; justify-content:space-between; align-items:center; font-size:13px; color:var(--mut) }
 .bar button { background:none; color:var(--mut); border:1px solid var(--line); padding:4px 10px }
</style></head><body>
<header><b>Аврора</b><span>внутренний ассистент «Нордвинд Системс»</span></header>
<main>
 <div id="gate" class="gate">
  <p>Доступ к ассистенту по коду.</p>
  <input id="label" placeholder="как тебя записать (необязательно)" autocomplete="off">
  <input id="code" type="password" placeholder="код доступа" autocomplete="off">
  <p class="err" id="gateErr"></p>
  <button id="enter">Войти</button>
 </div>
 <div id="app" hidden>
  <div class="bar"><span id="who"></span><button id="reset">Очистить диалог</button></div>
  <div id="feed"></div>
  <p class="err" id="err"></p>
  <form id="f"><textarea id="t" placeholder="Спроси что-нибудь…"></textarea><button id="send">Отправить</button></form>
 </div>
</main>
<script>
const $ = (id) => document.getElementById(id);
const api = (path, body) => fetch("/lab" + path, {
  method: body ? "POST" : "GET",
  headers: { "content-type": "application/json" },
  credentials: "same-origin",
  body: body ? JSON.stringify(body) : undefined,
}).then(async (r) => { const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j?.error?.message || r.statusText); return j; });

function bubble(role, text, tools) {
  const d = document.createElement("div");
  d.className = "msg " + (role === "user" ? "user" : "bot");
  d.textContent = text;
  $("feed").append(d);
  if (tools && tools.length) {
    const t = document.createElement("div");
    t.className = "tools"; t.textContent = "инструменты: " + tools.join(", ");
    $("feed").append(t);
  }
  window.scrollTo(0, document.body.scrollHeight);
}

async function boot() {
  try {
    const me = await api("/me");
    $("gate").hidden = true; $("app").hidden = false;
    $("who").textContent = "сессия: " + (me.session.label || me.session.id.slice(0, 8));
    for (const m of me.history) bubble(m.role, m.content);
  } catch { /* не вошли — показываем ворота */ }
}

$("enter").onclick = async () => {
  $("gateErr").textContent = "";
  try {
    await api("/enter", { code: $("code").value, label: $("label").value });
    location.reload();
  } catch (e) { $("gateErr").textContent = e.message; }
};
$("code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("enter").click(); });

$("f").onsubmit = async (e) => {
  e.preventDefault();
  const text = $("t").value.trim();
  if (!text) return;
  $("err").textContent = ""; $("send").disabled = true;
  bubble("user", text); $("t").value = "";
  try {
    const r = await api("/message", { text });
    bubble("assistant", r.answer, r.tools);
  } catch (e) { $("err").textContent = e.message; }
  finally { $("send").disabled = false; $("t").focus(); }
};
$("t").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) $("f").requestSubmit();
});
$("reset").onclick = async () => { await api("/reset", {}); $("feed").innerHTML = ""; };
boot();
</script></body></html>`;

export const ADMIN_PAGE = `<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agent-lab — админка</title>
<style>
 :root { color-scheme: light dark; --bg:#fff; --fg:#111; --mut:#666; --line:#dcdcdc; --acc:#2d6cdf; --box:#f5f6f8; }
 @media (prefers-color-scheme: dark) { :root { --bg:#16181c; --fg:#e8e8ea; --mut:#9aa0a6; --line:#2c2f36; --acc:#6ea1ff; --box:#1f2229; } }
 * { box-sizing:border-box }
 body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--fg) }
 main { max-width:1000px; margin:0 auto; padding:20px }
 h1 { font-size:18px } h2 { font-size:15px; margin-top:28px }
 input,select,button,textarea { font:inherit; border-radius:8px; border:1px solid var(--line); padding:7px 10px; background:var(--bg); color:var(--fg) }
 button { background:var(--acc); color:#fff; border:0; cursor:pointer }
 .grid { display:grid; grid-template-columns:180px 1fr; gap:8px 12px; align-items:center; max-width:640px }
 table { border-collapse:collapse; width:100%; font-size:13px; margin-top:8px }
 th,td { border-bottom:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top }
 td.wrap { white-space:pre-wrap; max-width:380px; word-wrap:break-word }
 .tag { display:inline-block; padding:1px 7px; border-radius:99px; font-size:12px; background:var(--box); margin-right:4px }
 .hit { background:#d33; color:#fff } .warn { background:#c80; color:#fff } .ok { background:#2a2; color:#fff }
 .err { color:#d33; min-height:18px } .mut { color:var(--mut) }
 code { background:var(--box); padding:1px 5px; border-radius:4px }
</style></head><body><main>
<h1>agent-lab — админка</h1>
<div id="gate">
 <p class="mut">Вставь admin-токен (<code>LAB_API_TOKEN</code> из /etc/agent-lab.env).</p>
 <input id="token" type="password" placeholder="токен" style="width:340px"> <button id="login">Войти</button>
 <p class="err" id="gateErr"></p>
</div>
<div id="app" hidden>
 <h2>Настройки</h2>
 <div class="grid">
  <label>Уровень защиты</label><select id="securityLevel"><option value="easy">easy — без правил (baseline)</option><option value="normal">normal — правила + обёртка данных</option><option value="hard">hard — плюс egress-guard</option></select>
  <label>URL LLM</label><input id="llmUrl">
  <label>Модель</label><input id="model">
  <label>Ключ LLM</label><input id="llmApiKey" type="password" placeholder="пусто = не менять">
  <label>Провайдер поиска</label><select id="searchProvider"><option value="none">нет</option><option value="tavily">Tavily</option><option value="brave">Brave</option><option value="serper">Serper</option></select>
  <label>Ключ поиска</label><input id="searchApiKey" type="password" placeholder="пусто = не менять">
  <label>Код доступа</label><input id="accessCode" type="password" placeholder="пусто = не менять">
  <label>Температура</label><input id="temperature" type="number" step="0.1" min="0" max="2">
  <label>Лимит токенов</label><input id="maxTokens" type="number">
  <label>Итераций tool-loop</label><input id="maxIterations" type="number">
  <label>Обменов в сутки</label><input id="dailyExchangeLimit" type="number">
 </div>
 <p><button id="save">Сохранить</button> <span class="mut" id="saved"></span></p>
 <p class="err" id="err"></p>

 <h2>Флаги <button id="rotate" style="font-size:12px;padding:3px 9px">Перевыпустить</button></h2>
 <table id="flags"></table>

 <h2>Скорборд</h2>
 <table id="score"></table>

 <h2>Журнал попыток <button id="refresh" style="font-size:12px;padding:3px 9px">Обновить</button></h2>
 <table id="attempts"></table>
</div>
<script>
const $ = (id) => document.getElementById(id);
let TOKEN = sessionStorage.getItem("labToken") || "";
const api = (path, method = "GET", body) => fetch("/lab" + path, {
  method, headers: { "content-type": "application/json", authorization: "Bearer " + TOKEN },
  body: body ? JSON.stringify(body) : undefined,
}).then(async (r) => { const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j?.error?.message || r.statusText); return j; });

const FIELDS = ["llmUrl","model","temperature","maxTokens","maxIterations","dailyExchangeLimit","securityLevel","searchProvider"];

async function loadAll() {
  const { settings } = await api("/admin/settings");
  for (const f of FIELDS) if ($(f)) $(f).value = settings[f];
  $("llmApiKey").placeholder = settings.hasLlmKey ? "задан …" + settings.llmKeyTail : "не задан";
  $("searchApiKey").placeholder = settings.hasSearchKey ? "задан …" + settings.searchKeyTail : "не задан";
  $("accessCode").placeholder = settings.hasAccessCode ? "задан (пусто = не менять)" : "НЕ ЗАДАН — вход закрыт";

  const { flags } = await api("/admin/flags");
  $("flags").innerHTML = "<tr><th>Где спрятан</th><th>Значение</th></tr>" +
    flags.map((f) => "<tr><td>" + f.key + "</td><td><code>" + esc(f.value) + "</code></td></tr>").join("");

  const sc = await api("/admin/scoreboard");
  const taken = new Map(sc.scoreboard.map((s) => [s.flag, s]));
  $("score").innerHTML = "<tr><th>Флаг</th><th>Статус</th><th>Кто</th><th>Когда</th><th>Уровень</th></tr>" +
    sc.flags.map((k) => { const s = taken.get(k);
      return "<tr><td>" + k + "</td><td>" + (s ? "<span class='tag hit'>захвачен</span>" : "<span class='tag ok'>держится</span>") +
        "</td><td>" + (s ? esc(s.sessionLabel) : "—") + "</td><td>" + (s ? fmt(s.at) : "—") + "</td><td>" + (s ? s.level : "—") + "</td></tr>"; }).join("");

  await loadAttempts();
}

async function loadAttempts() {
  const { attempts } = await api("/admin/attempts?limit=200");
  $("attempts").innerHTML = "<tr><th>Когда</th><th>Кто</th><th>Ур.</th><th>Запрос</th><th>Ответ</th><th>Инструменты</th><th>Итог</th></tr>" +
    attempts.map((a) => "<tr><td>" + fmt(a.createdAt) + "</td><td>" + esc(a.sessionLabel) + "</td><td>" + a.securityLevel +
      "</td><td class='wrap'>" + esc(a.userText) + "</td><td class='wrap'>" + esc(a.answerText) + "</td><td>" + a.tools.join(", ") +
      "</td><td>" + badges(a) + "</td></tr>").join("");
}

function badges(a) {
  let out = "";
  for (const f of a.captured) out += "<span class='tag hit'>выдан " + f + "</span>";
  for (const f of a.exfiltrated) out += "<span class='tag hit'>эксфильтрация " + f + "</span>";
  for (const f of a.quoted) out += "<span class='tag warn'>упомянут " + f + "</span>";
  for (const b of a.blocked) out += "<span class='tag warn'>срезано: " + esc(b) + "</span>";
  return out || "<span class='tag ok'>чисто</span>";
}
const esc = (s) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const fmt = (iso) => new Date(iso).toLocaleString("ru-RU");

$("login").onclick = async () => {
  TOKEN = $("token").value.trim(); $("gateErr").textContent = "";
  try { await api("/admin/settings"); sessionStorage.setItem("labToken", TOKEN); $("gate").hidden = true; $("app").hidden = false; await loadAll(); }
  catch (e) { $("gateErr").textContent = e.message; }
};
$("save").onclick = async () => {
  $("err").textContent = ""; $("saved").textContent = "";
  const body = {};
  for (const f of FIELDS) { const el = $(f); if (!el) continue; body[f] = el.type === "number" ? Number(el.value) : el.value; }
  for (const f of ["llmApiKey","searchApiKey","accessCode"]) if ($(f).value.trim()) body[f] = $(f).value.trim();
  try { await api("/admin/settings", "PUT", body); for (const f of ["llmApiKey","searchApiKey","accessCode"]) $(f).value = "";
        $("saved").textContent = "сохранено"; await loadAll(); }
  catch (e) { $("err").textContent = e.message; }
};
$("rotate").onclick = async () => { if (confirm("Перевыпустить все флаги? Прежние захваты останутся в журнале.")) { await api("/admin/flags/rotate", "POST", {}); await loadAll(); } };
$("refresh").onclick = loadAttempts;
if (TOKEN) { $("token").value = TOKEN; $("login").click(); }
</script></main></body></html>`;
