// Findit website. Same screens and rules as the Android app, talking to the
// same API (/api/). Every piece of text from the server is put on the page
// with textContent, never as HTML, so posts and comments can't inject code.
import { ICONS } from "./icons.js?v=2";

// ===================================================================== basics
const app = document.getElementById("app");
const overlayRoot = document.getElementById("overlay-root");
const FOUND = "#2e7d5b";
const LOST = "#d9822b";
const DEFAULT_CENTER = [12.9716, 77.5946]; // Bengaluru

function h(tag, props, ...children) {
  const [name, ...classes] = tag.split(".");
  const el = document.createElement(name || "div");
  if (classes.length) el.className = classes.join(" ");
  for (const [key, value] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "class") el.className += (el.className ? " " : "") + value;
    else if (key === "style" && typeof value === "object") Object.assign(el.style, value);
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === "value") el.value = value;
    else if (key === "checked") el.checked = !!value;
    else if (value === true) el.setAttribute(key, "");
    else el.setAttribute(key, value);
  }
  append(el, children);
  return el;
}
// Replace an element's content; nulls are skipped and nested lists flattened.
function fill(el, ...children) { el.replaceChildren(); return append(el, children); }
function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}
function icon(name, size = 24, extraClass = "") {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", `icon ${extraClass}`.trim());
  svg.setAttribute("aria-hidden", "true");
  svg.style.width = svg.style.height = `${size}px`;
  svg.innerHTML = ICONS[name] || ICONS.help_outline; // trusted, bundled icon paths
  return svg;
}
const store = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch { /* private mode */ } },
};

function timeAgo(iso) {
  if (!iso) return "";
  const time = new Date(iso);
  const mins = Math.floor((Date.now() - time.getTime()) / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days} d ago`;
  return `${time.getDate()}/${time.getMonth() + 1}/${time.getFullYear()}`;
}
function formatDistance(m) {
  if (m === null || m === undefined) return "";
  return m < 1000 ? `${m} m away` : `${(m / 1000).toFixed(1)} km away`;
}
const CATEGORY_ICONS = {
  electronics: "smartphone", wallet: "account_balance_wallet", keys: "vpn_key", documents: "badge",
  bag: "backpack", jewellery: "watch", clothing: "checkroom", books: "menu_book", pet: "pets",
};
const HANDOVER_ICONS = { left_there: "place", police: "local_police", desk: "support_agent", kept: "back_hand" };
const categoryIcon = (c) => CATEGORY_ICONS[c] || "category";
const handoverIcon = (v) => HANDOVER_ICONS[v] || "help_outline";

// Honeypot: a field people never see. The server refuses the request if a bot fills it.
function honeypot() {
  return h("div.hp", { "aria-hidden": "true" },
    h("label", {}, "Leave this field empty ", h("input", { type: "text", name: "website", tabindex: "-1", autocomplete: "off" })));
}
const honeypotValue = (root) => root.querySelector('input[name="website"]')?.value || "";

// ===================================================================== api
class ApiError extends Error {
  constructor(message, { status = 0, code = null, body = {}, fields = {} } = {}) {
    super(message);
    Object.assign(this, { status, code, body, fields });
  }
}
const state = { token: store.get("findit_token"), user: null, meta: null };
try { state.user = JSON.parse(store.get("findit_user") || "null"); } catch { state.user = null; }

function flatten(value) {
  if (Array.isArray(value)) return value.map(flatten).join(" ");
  if (value && typeof value === "object") return Object.values(value).map(flatten).join(" ");
  return String(value);
}

async function api(path, { method = "GET", body, form, query, auth = true, timeout = 30000 } = {}) {
  let url = path;
  if (query) {
    const params = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) if (v !== null && v !== undefined && v !== "") params.set(k, v);
    const qs = params.toString();
    if (qs) url += `?${qs}`;
  }
  const headers = { Accept: "application/json" };
  const sentToken = auth ? state.token : null;
  if (sentToken) headers.Authorization = `Token ${sentToken}`;
  let payload;
  if (form) payload = form;
  else if (body !== undefined) { headers["Content-Type"] = "application/json"; payload = JSON.stringify(body); }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  let response;
  try {
    response = await fetch(url, { method, headers, body: payload, signal: controller.signal, credentials: "omit" });
  } catch (e) {
    throw new ApiError(e.name === "AbortError" ? "The server took too long to answer. Try again." : "Can't reach the server. Check your connection.");
  } finally {
    clearTimeout(timer);
  }
  let data = null;
  const text = await response.text();
  if (text) { try { data = JSON.parse(text); } catch { data = null; } }
  if (response.ok) return data;
  if (response.status === 401 && sentToken && sentToken === state.token) signOut(true);
  let message = `Something went wrong (error ${response.status}).`;
  const fields = {};
  let code = null;
  if (data && typeof data === "object" && !Array.isArray(data)) {
    code = typeof data.code === "string" ? data.code : null;
    if (data.detail) message = flatten(data.detail);
    else {
      for (const [k, v] of Object.entries(data)) fields[k] = flatten(v);
      const first = Object.values(fields)[0];
      if (first) message = first;
    }
  } else if (response.status === 429) message = "Too many requests. Please wait a minute and try again.";
  throw new ApiError(message, { status: response.status, code, body: data || {}, fields });
}

async function loadMeta() {
  if (!state.meta) state.meta = await api("/api/meta/", { auth: false });
  return state.meta;
}
const categoryLabel = (value) => state.meta?.categories.find((c) => c.value === value)?.label || value;

function saveSession(token, user) {
  state.token = token;
  state.user = user;
  store.set("findit_token", token);
  store.set("findit_user", JSON.stringify(user));
}
function signOut(expired = false) {
  state.token = null;
  state.user = null;
  store.set("findit_token", null);
  store.set("findit_user", null);
  resetTabs();
  closeOverlays();
  location.hash = "#/login";
  if (expired) snack("You were logged out. Please log in again.");
}

// ===================================================================== location
const geo = {
  lat: null, lng: null, note: null,
  last() {
    try { return JSON.parse(store.get("findit_last_location") || "null"); } catch { return null; }
  },
  get(options) {
    return new Promise((resolve, reject) => {
      if (!navigator.geolocation) return reject(new Error("This browser can't share your location."));
      navigator.geolocation.getCurrentPosition(
        (p) => {
          const pos = { lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy };
          store.set("findit_last_location", JSON.stringify({ lat: pos.lat, lng: pos.lng }));
          resolve(pos);
        },
        (err) => reject(new Error(err.code === 1
          ? "Location permission is off. Allow location for this site in your browser settings."
          : "Couldn't get your location.")),
        options,
      );
    });
  },
  // Quick, for the feed and map: a recent position is fine.
  async quick() {
    try {
      const pos = await this.get({ enableHighAccuracy: false, maximumAge: 300000, timeout: 10000 });
      Object.assign(this, { lat: pos.lat, lng: pos.lng, note: null });
    } catch (e) {
      const last = this.last();
      this.lat = last?.lat ?? null;
      this.lng = last?.lng ?? null;
      this.note = last ? "Using your last known location." : `${e.message} Showing newest posts everywhere.`;
    }
  },
  // Accurate, for tagging a found item.
  current() { return this.get({ enableHighAccuracy: true, maximumAge: 0, timeout: 20000 }); },
};

// ===================================================================== overlays
let snackTimer = null;
function snack(message, error = false) {
  document.querySelector(".snackbar")?.remove();
  clearTimeout(snackTimer);
  const low = !document.querySelector(".navbar") || !!document.querySelector(".composer");
  const el = h("div.snackbar", { role: "status", class: `${error ? "error" : ""} ${low ? "low" : ""}` }, message);
  document.body.append(el);
  snackTimer = setTimeout(() => el.remove(), 4000);
}
function closeOverlays() { fill(overlayRoot, ); document.querySelector(".menu")?.remove(); }

function openScrim(content, { bottom = false, onClose } = {}) {
  const scrim = h("div.scrim", { class: bottom ? "bottom" : "" }, content);
  const close = () => { scrim.remove(); document.removeEventListener("keydown", onKey); onClose?.(); };
  const onKey = (e) => { if (e.key === "Escape") close(); };
  scrim.addEventListener("click", (e) => { if (e.target === scrim) close(); });
  document.addEventListener("keydown", onKey);
  overlayRoot.append(scrim);
  setTimeout(() => content.querySelector("input:not([type=hidden]):not([tabindex='-1']), textarea, button")?.focus(), 30);
  return close;
}

// A dialog. `actions` are [{label, value, kind}]; resolves with the chosen value (or null).
function dialog({ title, body, actions, onSubmit }) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (value) => { if (done) return; done = true; close(); resolve(value); };
    const form = h("form.dialog", { role: "dialog", "aria-modal": "true", "aria-label": title, novalidate: true },
      h("h2", {}, title),
      body,
      h("div.actions", {}, actions.map((a) => h("button.btn", {
        type: a.submit ? "submit" : "button",
        class: a.kind === "filled" ? "btn-filled" : "btn-text",
        onclick: a.submit ? null : () => finish(a.value),
      }, a.label))));
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const value = onSubmit ? onSubmit(form) : true;
      if (value !== undefined && value !== false) finish(value);
    });
    const close = openScrim(form, { onClose: () => { if (!done) { done = true; resolve(null); } } });
  });
}
const confirmDialog = (title, text, action) =>
  dialog({ title, body: h("p.variant", { style: { margin: 0 } }, text), actions: [
    { label: "Cancel", value: false }, { label: action, value: true, kind: "filled" }] });

function field(label, input, { helper, error } = {}) {
  if (!input.id) input.id = `f${Math.random().toString(36).slice(2, 9)}`;
  if (!input.hasAttribute("placeholder")) input.setAttribute("placeholder", " ");
  const wrap = h("div.field", { class: error ? "invalid" : "" }, input, h("label", { for: input.id }, label));
  if (input.tagName === "SELECT") wrap.append(icon("expand_more", 24, "select-arrow"));
  if (error) wrap.append(h("div.helper.err", {}, error));
  else if (helper) wrap.append(h("div.helper", {}, helper));
  return wrap;
}
function setFieldError(wrap, message) {
  wrap.classList.toggle("invalid", !!message);
  wrap.querySelector(".helper.err")?.remove();
  const helper = wrap.querySelector(".helper");
  if (helper) helper.hidden = !!message;
  if (message) wrap.append(h("div.helper.err", {}, message));
}

// A one-field prompt (like the app's promptText).
function promptText({ title, message, hint, confirm = "Send", required = true, multiline = true }) {
  const input = multiline ? h("textarea", { rows: 3, placeholder: hint || " " }) : h("input", { placeholder: hint || " " });
  return dialog({
    title,
    body: h("div", {}, message ? h("p.variant", { style: { margin: "0 0 4px" } }, message) : null, field("", input)),
    actions: [{ label: "Cancel", value: null }, { label: confirm, submit: true, kind: "filled" }],
    onSubmit: () => {
      const text = input.value.trim();
      if (required && !text) { input.focus(); return false; }
      return text;
    },
  });
}

function sheet(content) {
  const box = h("div.sheet", { role: "dialog", "aria-modal": "true" }, h("div.handle"), content);
  return openScrim(box, { bottom: true });
}

function menu(anchor, items) {
  document.querySelector(".menu")?.remove();
  const rect = anchor.getBoundingClientRect();
  const el = h("div.menu", { role: "menu", style: { top: `${rect.bottom + 4}px`, right: `${Math.max(8, window.innerWidth - rect.right)}px` } },
    items.map((item) => h("button", { role: "menuitem", class: item.danger ? "btn-error" : "", onclick: () => { el.remove(); item.action(); } }, item.label)));
  const off = (e) => { if (!el.contains(e.target) && e.target !== anchor) { el.remove(); document.removeEventListener("click", off, true); } };
  setTimeout(() => document.addEventListener("click", off, true));
  document.body.append(el);
}

function message({ icon: iconName, title, body, actionLabel, onAction }) {
  return h("div.message", {},
    icon(iconName, 48),
    h("div.title-m", {}, title),
    body ? h("div.variant", {}, body) : null,
    actionLabel ? h("button.btn.btn-tonal", { type: "button", onclick: onAction }, actionLabel) : null);
}
const spinner = (small = false) => h("div.spinner", { class: small ? "small" : "", role: "status", "aria-label": "Loading" });

function seg(options, selected, onChange) {
  const box = h("div.seg", { role: "radiogroup" });
  const draw = (value) => {
    fill(box, ...options.map((o) => h("button", {
      type: "button", role: "radio", "aria-checked": String(o.value === value), class: o.value === value ? "on" : "",
      onclick: () => { draw(o.value); onChange(o.value); },
    }, o.icon ? icon(o.icon, 18) : null, o.label)));
  };
  draw(selected);
  return box;
}

function appbar(title, { back = false, actions = [], bottom = null, dark = false } = {}) {
  const row = h("div.appbar-row", { class: back ? "has-back" : "" },
    back ? h("button.icon-btn", { type: "button", "aria-label": "Back", class: dark ? "on-dark" : "", onclick: goBack }, icon("arrow_back")) : null,
    h("h1.appbar-title", { style: { margin: 0, fontWeight: 400 } }, title),
    ...actions);
  return h("header.appbar", {}, row, bottom ? h("div.appbar-bottom", {}, bottom) : null);
}
function actionBtn(name, label, onClick) {
  return h("button.icon-btn", { type: "button", "aria-label": label, title: label, onclick: onClick }, icon(name));
}

// ===================================================================== post card
function typeBadge(type) { return h("span.badge", { class: type }, type === "found" ? "FOUND" : "LOST"); }
function statusBadge(status) {
  if (status === "open") return null;
  const [label, color] = { claimed: ["Claimed", "var(--blue)"], returned: ["Returned", "var(--green)"], hidden: ["Under review", "var(--red)"] }[status] || [status, "var(--grey)"];
  return h("span.badge.status", { style: { color, background: `color-mix(in srgb, ${color} 12%, transparent)` } }, label);
}
function netImage(url, placeholderIcon, alt = "") {
  const box = h("div.thumb");
  const placeholder = icon(placeholderIcon);
  if (!url) { box.append(placeholder); return box; }
  const img = h("img", { src: url, alt, loading: "lazy", decoding: "async" });
  img.addEventListener("error", () => img.replaceWith(placeholder));
  box.append(img);
  return box;
}
function postCard(post, { trailing = null } = {}) {
  const meta = [formatDistance(post.distance_m), timeAgo(post.created_at)].filter(Boolean).join(" · ");
  return h("a.card.post-card", { href: `#/post/${post.id}`, "data-post": post.id },
    netImage(post.thumbnail, categoryIcon(post.category), post.title),
    h("div.body", {},
      h("div.row", {}, typeBadge(post.post_type), statusBadge(post.status), h("span.spacer"), trailing),
      h("div.post-title", {}, post.title),
      post.landmark ? h("div.meta-line", {}, icon("place", 14), h("span", {}, post.landmark)) : null,
      post.post_type === "found" && post.handover_label
        ? h("div.meta-line", { style: { marginTop: "2px" } }, icon(handoverIcon(post.handover), 14), h("span", {}, post.handover_label)) : null,
      h("div.stats", {},
        icon(post.has_voted ? "arrow_upward" : "arrow_upward", 16, post.has_voted ? "voted" : ""),
        h("span", {}, ` ${post.score}   `),
        icon("mode_comment", 15),
        h("span", {}, ` ${post.comment_count}`),
        h("span.meta", {}, meta))));
}

// ===================================================================== router
const tabs = {}; // feed, map, activity screens are kept alive like the app's IndexedStack
let current = null; // { el, cleanup }
let depth = 0;

function resetTabs() {
  for (const key of Object.keys(tabs)) { tabs[key].cleanup?.(); delete tabs[key]; }
}
function goBack() {
  if (depth > 0) history.back();
  else location.hash = "#/";
}
window.addEventListener("hashchange", () => { route(); });

function parseRoute() {
  const path = location.hash.replace(/^#/, "") || "/";
  const parts = path.split("/").filter(Boolean);
  return parts;
}

async function route() {
  closeOverlays();
  const parts = parseRoute();
  const signedIn = !!state.token;
  if (!signedIn && parts[0] !== "login") { location.replace("#/login"); return; }
  if (signedIn && parts[0] === "login") { location.replace("#/"); return; }
  try { await loadMeta(); } catch { /* screens show their own errors */ }

  if (current && !current.keep) current.cleanup?.();
  current = null;

  const tabName = parts.length === 0 || parts[0] === "feed" ? "feed"
    : ["map", "messages", "activity"].includes(parts[0]) ? parts[0] : null;
  if (tabName) {
    depth = 0;
    showTab(tabName);
    return;
  }
  depth += 1;
  let screen;
  if (parts[0] === "login") { depth = 0; screen = loginScreen(); }
  else if (parts[0] === "post" && parts[2] === "claims") screen = claimsScreen(Number(parts[1]));
  else if (parts[0] === "post") screen = postScreen(Number(parts[1]));
  else if (parts[0] === "new") screen = createScreen(parts[1] === "lost" ? "lost" : "found");
  else if (parts[0] === "chat") screen = chatScreen(Number(parts[1]));
  else { location.replace("#/"); return; }
  current = screen;
  fill(app, screen.el);
  window.scrollTo(0, 0);
  screen.mounted?.();
}

function showTab(name) {
  if (!tabs[name]) tabs[name] = { feed: feedScreen, map: mapScreen, messages: messagesScreen, activity: activityScreen }[name]();
  const tab = tabs[name];
  current = { ...tab, keep: true };
  const nav = h("nav.navbar", { "aria-label": "Main" }, [
    ["feed", "#/", "dynamic_feed", "Feed"], ["map", "#/map", "map", "Map"],
    ["messages", "#/messages", "chat_bubble", "Messages"], ["activity", "#/activity", "person", "My activity"],
  ].map(([key, href, iconName, label]) => h("a", { href, class: key === name ? "active" : "", "aria-current": key === name ? "page" : null },
    h("span.pill", {}, icon(key === name ? `${iconName}_fill` : iconName),
      key === "messages" ? h("span.nav-badge", { hidden: !unreadCount }, unreadCount > 99 ? "99+" : String(unreadCount)) : null),
    label)));
  const fab = h("button.fab", { type: "button", onclick: newPostChoice }, icon("add_a_photo"), "Post");
  fill(app, tab.el, fab, nav);
  if (tab.scrollY !== undefined) window.scrollTo(0, tab.scrollY);
  tab.shown?.();
  refreshUnread();
}
window.addEventListener("scroll", () => {
  if (current?.keep) {
    const tab = Object.values(tabs).find((t) => t.el === current.el);
    if (tab) tab.scrollY = window.scrollY;
  }
  document.querySelectorAll(".appbar").forEach((bar) => bar.classList.toggle("scrolled", window.scrollY > 4));
}, { passive: true });

// The number on the Messages tab, refreshed every 30 s while the page is open.
let unreadCount = 0;
async function refreshUnread() {
  if (!state.token || document.hidden) return;
  try {
    const data = await api("/api/me/unread/");
    unreadCount = data?.unread || 0;
  } catch { return; }
  document.querySelectorAll(".nav-badge").forEach((b) => {
    b.hidden = !unreadCount;
    b.textContent = unreadCount > 99 ? "99+" : String(unreadCount);
  });
}
setInterval(refreshUnread, 30000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshUnread(); });

// Open (or reuse) the chat about a post. The author passes the other person's id.
async function openChat(postId, withUser = null) {
  try {
    const convo = await api(`/api/posts/${postId}/conversation/`, { method: "POST", body: withUser ? { user_id: withUser } : {} });
    location.hash = `#/chat/${convo.id}`;
  } catch (err) { snack(err.message, true); }
}

function newPostChoice() {
  const close = sheet(h("div", {},
    h("button.list-tile", { type: "button", onclick: () => { close(); location.hash = "#/new/found"; } },
      icon("photo_camera"), h("div", {}, h("div.body-l", {}, "I found something"), h("div.variant", {}, "Take a photo; we tag where you are"))),
    h("button.list-tile", { type: "button", onclick: () => { close(); location.hash = "#/new/lost"; } },
      icon("search"), h("div", {}, h("div.body-l", {}, "I lost something"), h("div.variant", {}, "Describe it so finders can match it")))));
}

// ===================================================================== login
function loginScreen() {
  let registering = false;
  let pending = null; // waiting for the email code
  let resendIn = 0;
  let timer = null;
  const el = h("main.login");

  const draw = () => {
    clearInterval(timer);
    fill(el, h("div.login-box", {}, pending ? codeStep() : formStep()));
  };

  function formStep() {
    const errors = h("div");
    const username = h("input", { name: "username", autocomplete: "username", autocapitalize: "none", required: true });
    const email = h("input", { name: "email", type: "email", autocomplete: "email" });
    const display = h("input", { name: "display_name", autocomplete: "nickname" });
    const password = h("input", { name: "password", type: "password", autocomplete: registering ? "new-password" : "current-password" });
    const toggle = h("button.icon-btn", { type: "button", "aria-label": "Show password", onclick: () => {
      const show = password.type === "password";
      password.type = show ? "text" : "password";
      fill(toggle, icon(show ? "visibility_off" : "visibility"));
    } }, icon("visibility"));
    const fUser = field(registering ? "Username" : "Username or email", username);
    const fEmail = field("Email", email, { helper: "We'll send a code to confirm it's yours." });
    const fName = field("Display name (optional)", display);
    const fPass = field("Password", password, { helper: registering ? "At least 8 characters." : null });
    fPass.append(h("div.suffix", {}, toggle));
    const submit = h("button.btn.btn-filled.btn-block", { type: "submit" }, registering ? "Create account" : "Log in");
    const form = h("form", { novalidate: true },
      icon("travel_explore", 64, "logo"),
      h("div.headline-m.center", {}, "Findit"),
      h("div.center", { style: { marginTop: "4px", marginBottom: "16px" } }, "Found something? Lost something? Your neighbours can help."),
      fUser, registering ? fEmail : null, registering ? fName : null, fPass, honeypot(), errors, submit,
      h("button.btn.btn-text", { type: "button", onclick: () => { registering = !registering; draw(); } },
        registering ? "I already have an account" : "New here? Create an account"));

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      [fUser, fEmail, fPass].forEach((f) => setFieldError(f, null));
      fill(errors, );
      let bad = false;
      if (!username.value.trim()) { setFieldError(fUser, "Required"); bad = true; }
      if (registering && !email.value.includes("@")) { setFieldError(fEmail, "Enter a valid email"); bad = true; }
      if (password.value.length < (registering ? 8 : 1)) { setFieldError(fPass, registering ? "At least 8 characters" : "Required"); bad = true; }
      if (bad) return;
      submit.disabled = true;
      fill(submit, spinner(true));
      try {
        if (registering) {
          const data = await api("/api/auth/register/", { method: "POST", auth: false, body: {
            username: username.value.trim(), email: email.value.trim(), password: password.value,
            display_name: display.value.trim(), website: honeypotValue(form) } });
          if (data.token) { finishLogin(data); return; }
          startCode(data);
        } else {
          const data = await api("/api/auth/login/", { method: "POST", auth: false, body: {
            username: username.value.trim(), password: password.value, website: honeypotValue(form) } });
          finishLogin(data);
        }
      } catch (err) {
        if (err.code === "email_unverified") { startCode(err.body); return; }
        const map = { username: fUser, email: fEmail, password: fPass };
        let shown = false;
        for (const [k, v] of Object.entries(err.fields || {})) if (map[k]) { setFieldError(map[k], v); shown = true; }
        if (!shown) fill(errors, h("p.err-text", { role: "alert" }, err.message));
        submit.disabled = false;
        fill(submit, registering ? "Create account" : "Log in");
      }
    });
    return form;
  }

  function startCode(data) {
    pending = { username: data.username, hint: data.email_hint || "your email", message: data.detail, failed: !!data.email_failed };
    resendIn = data.resend_in || (pending.failed ? 0 : 60);
    draw();
  }

  function codeStep() {
    const code = h("input.code-input", { inputmode: "numeric", autocomplete: "one-time-code", maxlength: "6", placeholder: "------" });
    const fCode = field("", code);
    fCode.querySelector("label").remove();
    const confirmBtn = h("button.btn.btn-filled.btn-block", { type: "submit" }, "Confirm");
    const resend = h("button.btn.btn-text", { type: "button" });
    const drawResend = () => {
      resend.disabled = resendIn > 0;
      resend.textContent = resendIn > 0 ? `Send a new code in ${resendIn}s` : "Send a new code";
    };
    drawResend();
    timer = setInterval(() => { if (resendIn > 0) { resendIn -= 1; drawResend(); } }, 1000);
    resend.addEventListener("click", async () => {
      try {
        const data = await api("/api/auth/resend-code/", { method: "POST", auth: false, body: { username: pending.username } });
        resendIn = data?.resend_in || 60;
        snack(data?.detail || "A new code is on its way.");
      } catch (err) {
        resendIn = err.body?.resend_in || 0;
        snack(err.message, true);
      }
      drawResend();
    });
    const form = h("form", { novalidate: true },
      icon("mail", 56, "logo"),
      h("div.headline-s.center", {}, "Check your email"),
      h("p.center", {}, `We sent a 6-digit code to ${pending.hint}. It expires in 10 minutes. Can't see it? Check spam.`),
      pending.failed ? h("p.err-text.center", {}, pending.message) : null,
      fCode, confirmBtn, resend,
      h("button.btn.btn-text", { type: "button", onclick: () => { pending = null; draw(); } }, "Back to log in"));
    code.addEventListener("input", () => { code.value = code.value.replace(/\D/g, "").slice(0, 6); if (code.value.length === 6) form.requestSubmit(); });
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      if (code.value.length !== 6) { setFieldError(fCode, "Enter the 6 digits from the email."); return; }
      confirmBtn.disabled = true;
      try {
        finishLogin(await api("/api/auth/verify-email/", { method: "POST", auth: false, body: { username: pending.username, code: code.value } }));
      } catch (err) {
        setFieldError(fCode, err.message);
        confirmBtn.disabled = false;
      }
    });
    setTimeout(() => code.focus(), 50);
    return form;
  }

  function finishLogin(data) {
    clearInterval(timer);
    saveSession(data.token, data.user);
    resetTabs();
    location.hash = "#/";
  }

  draw();
  return { el, cleanup: () => clearInterval(timer) };
}

// ===================================================================== feed
function feedScreen() {
  const s = { posts: [], page: 1, hasMore: true, loading: false, locating: true, gen: 0, error: null, type: null, category: null, sort: "near", radius: 5 };
  const search = h("input", { type: "search", placeholder: "Search: wallet, keys, Gate 2...", "aria-label": "Search posts", enterkeyhint: "search" });
  let debounce = null;
  search.addEventListener("input", () => { clearTimeout(debounce); debounce = setTimeout(refresh, 450); });
  const typeSeg = seg([{ value: null, label: "All" }, { value: "found", label: "Found" }, { value: "lost", label: "Lost" }], null, (v) => { s.type = v; refresh(); });
  const bar = appbar("Findit", {
    actions: [
      actionBtn("my_location", "Update my location", async () => { await geo.quick(); refresh(); }),
      actionBtn("tune", "Filters", openFilters),
    ],
    bottom: h("div", {}, h("div.search", {}, icon("search"), search), h("div", { style: { height: "8px" } }), typeSeg),
  });
  const head = h("div");
  const list = h("div");
  const end = h("div.list-end");
  const el = h("main.with-nav", {}, bar, head, list, end);

  const observer = new IntersectionObserver((entries) => { if (entries[0].isIntersecting) loadMore(); }, { rootMargin: "400px" });
  observer.observe(end);

  function drawHead() {
    const filters = [
      s.category ? categoryLabel(s.category) : null,
      geo.lat !== null ? `within ${s.radius} km` : null,
      { top: "top first", new: "newest first" }[s.sort] || "nearest first",
    ].filter(Boolean).join(" · ");
    fill(head, 
      geo.note ? h("div.note-line", { style: { paddingTop: "8px" } }, icon("location_off", 16), h("span", {}, geo.note)) : null,
      h("div.filters-line.label-m.muted", {}, filters));
  }
  function drawEnd() {
    if (s.error && !s.posts.length) {
      fill(end, message({ icon: "cloud_off", title: "Couldn't load posts", body: s.error, actionLabel: "Try again", onAction: refresh }));
    } else if (!s.loading && !s.locating && !s.posts.length) {
      fill(end, message({ icon: "inventory_2", title: "Nothing here yet", body: "No posts match. Try a bigger distance in filters, or be the first to post." }));
    } else if (s.loading || s.locating) fill(end, spinner());
    else fill(end, s.hasMore ? "" : h("span.body-s", {}, "You're all caught up"));
  }

  async function refresh() {
    s.gen += 1;
    Object.assign(s, { posts: [], page: 1, hasMore: true, error: null, loading: false });
    fill(list, );
    drawHead();
    await loadMore();
  }
  async function loadMore() {
    if (s.loading || !s.hasMore || s.locating) return;
    const gen = s.gen;
    s.loading = true;
    drawEnd();
    try {
      const data = await api("/api/posts/", { query: {
        lat: geo.lat, lng: geo.lng, radius_km: geo.lat !== null ? s.radius : null, type: s.type, category: s.category,
        q: search.value.trim(), sort: geo.lat === null && s.sort === "near" ? "new" : s.sort, page: s.page } });
      if (gen !== s.gen) return;
      s.posts.push(...data.results);
      append(list, data.results.map((p) => postCard(p)));
      s.hasMore = !!data.next;
      s.page += 1;
    } catch (err) {
      if (gen !== s.gen) return;
      s.error = err.message;
      s.hasMore = false;
      if (s.posts.length) snack(err.message, true);
    } finally {
      if (gen === s.gen) { s.loading = false; drawEnd(); }
    }
  }

  function openFilters() {
    let { category, sort, radius } = s;
    const radiusLabel = h("div.title-s", {}, `Within ${radius} km of you`);
    const range = h("input", { type: "range", min: "1", max: "100", step: "1", value: String(radius), "aria-label": "Distance" });
    range.addEventListener("input", () => { radius = Number(range.value); radiusLabel.textContent = `Within ${radius} km of you`; });
    const select = h("select", {}, h("option", { value: "" }, "All categories"),
      (state.meta?.categories || []).map((c) => h("option", { value: c.value, selected: c.value === category }, c.label)));
    select.addEventListener("change", () => { category = select.value || null; });
    const close = sheet(h("div.pad", {},
      h("div.title-s", { style: { marginBottom: "8px" } }, "Sort by"),
      seg([{ value: "near", label: "Nearest", icon: "near_me" }, { value: "new", label: "Newest", icon: "schedule" }, { value: "top", label: "Top", icon: "arrow_upward" }], sort, (v) => { sort = v; }),
      h("div", { style: { height: "20px" } }), radiusLabel, range,
      field("Category", select),
      h("button.btn.btn-filled.btn-block", { type: "button", style: { marginTop: "20px" }, onclick: () => {
        Object.assign(s, { category, sort, radius });
        close();
        refresh();
      } }, "Apply")));
  }

  // Coming back from a post: update just that card, like the app.
  async function refreshCard(id) {
    const card = list.querySelector(`[data-post="${id}"]`);
    if (!card) return;
    try {
      const fresh = await api(`/api/posts/${id}/`, { query: { lat: geo.lat, lng: geo.lng } });
      if (fresh.status === "returned" || fresh.status === "hidden") card.remove();
      else card.replaceWith(postCard(fresh));
    } catch (err) {
      if (err.status === 404) card.remove();
    }
  }

  drawHead();
  drawEnd();
  geo.quick().then(() => { s.locating = false; refresh(); });
  return { el, refresh, refreshCard, cleanup: () => observer.disconnect() };
}

// ===================================================================== map
function baseLayer() {
  return L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  });
}
function postMarker(post) {
  const color = post.post_type === "found" ? FOUND : LOST;
  if (post.location_is_approximate) {
    return L.circle([post.latitude, post.longitude], { radius: post.approx_radius_m || 250, color, weight: 2, fillColor: color, fillOpacity: 0.18 });
  }
  return L.circleMarker([post.latitude, post.longitude], { radius: 9, color: "#fff", weight: 2, fillColor: color, fillOpacity: 1 });
}

function mapScreen() {
  let type = null;
  let map = null;
  let layer = null;
  let timer = null;
  let gen = 0;
  const box = h("div.map-box");
  const errorBox = h("div.map-error", { hidden: true });
  const loading = h("div.map-loading", { hidden: true }, spinner(true));
  const bar = appbar("Map", {
    actions: [actionBtn("my_location", "Go to my location", async () => {
      await geo.quick();
      if (geo.lat !== null) map?.setView([geo.lat, geo.lng], 15);
      else snack(geo.note || "Couldn't get your location.", true);
    })],
    bottom: seg([{ value: null, label: "All" }, { value: "found", label: "Found" }, { value: "lost", label: "Lost" }], null, (v) => { type = v; load(); }),
  });
  const legend = h("div.map-legend", {}, h("span.dot", { style: { background: FOUND } }), " Found   ", h("span.dot", { style: { background: LOST } }), " Lost");
  const el = h("main.map-screen", {}, bar, h("div", { style: { position: "relative", flex: "1", display: "flex" } }, box, errorBox, loading), legend);

  function init() {
    if (map || typeof L === "undefined") return;
    map = L.map(box, { zoomControl: true, attributionControl: true }).setView(DEFAULT_CENTER, 13);
    baseLayer().addTo(map);
    layer = L.layerGroup().addTo(map);
    map.on("moveend", () => { clearTimeout(timer); timer = setTimeout(load, 350); });
    geo.quick().then(() => { if (geo.lat !== null) map.setView([geo.lat, geo.lng], 14); else load(); });
  }
  async function load() {
    if (!map) return;
    const b = map.getBounds();
    const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
    const my = ++gen;
    loading.hidden = false;
    try {
      const posts = await api("/api/posts/map/", { query: {
        bbox: [clamp(b.getWest(), -180, 180), clamp(b.getSouth(), -90, 90), clamp(b.getEast(), -180, 180), clamp(b.getNorth(), -90, 90)].map((n) => n.toFixed(6)).join(","),
        type } });
      if (my !== gen) return;
      errorBox.hidden = true;
      layer.clearLayers();
      for (const post of posts) postMarker(post).on("click", () => preview(post)).addTo(layer);
    } catch (err) {
      if (my !== gen) return;
      errorBox.hidden = false;
      errorBox.textContent = err.message;
    } finally {
      if (my === gen) loading.hidden = true;
    }
  }
  function preview(post) {
    const close = sheet(h("div", { style: { paddingBottom: "16px" } },
      postCard(post),
      post.location_is_approximate ? h("p.body-s", { style: { margin: "4px 20px" } }, "The finder kept this item, so only the approximate area is shown.") : null));
    overlayRoot.querySelector(".post-card")?.addEventListener("click", () => close());
  }
  return {
    el,
    shown() { setTimeout(() => { init(); map?.invalidateSize(); }, 30); },
    reload: load,
    cleanup() { clearTimeout(timer); map?.remove(); },
  };
}

// ===================================================================== post detail
function postScreen(id) {
  let post = null;
  let comments = [];
  let replyTo = null;
  let miniMap = null;
  const body = h("div", {}, h("div.splash", { style: { minHeight: "60vh" } }, spinner()));
  const more = h("button.icon-btn", { type: "button", "aria-label": "More options", hidden: true });
  const titleEl = appbar("", { back: true, actions: [more] });
  const el = h("main", {}, titleEl, body);

  async function load() {
    try {
      [post, comments] = await Promise.all([
        api(`/api/posts/${id}/`, { query: { lat: geo.lat, lng: geo.lng } }),
        api(`/api/posts/${id}/comments/`),
      ]);
      draw();
    } catch (err) {
      fill(body, message({ icon: "error_outline", title: err.message, actionLabel: "Try again", onAction: load }));
    }
  }
  async function run(task, done) {
    try {
      await task();
      if (done) snack(done);
      await load();
    } catch (err) { snack(err.message, true); }
  }

  function draw() {
    miniMap?.remove();
    miniMap = null;
    titleEl.querySelector(".appbar-title").textContent = post.post_type === "found" ? "Found item" : "Lost item";
    more.hidden = false;
    fill(more, icon("more_vert"));
    more.onclick = () => menu(more, post.is_owner ? [
      { label: post.post_type === "found" ? "Mark as returned" : "I got it back", action: async () => {
        if (await confirmDialog(post.post_type === "found" ? "Mark as returned?" : "Got it back?", "The post leaves the feed.", "Yes"))
          run(() => api(`/api/posts/${id}/resolve/`, { method: "POST" }), "Great news! Marked as resolved.");
      } },
      { label: "Keep it up another month", action: () => run(() => api(`/api/posts/${id}/renew/`, { method: "POST" }), "Post will stay up for another month.") },
      { label: "Delete post", danger: true, action: async () => {
        if (!(await confirmDialog("Delete this post?", "This can't be undone.", "Delete"))) return;
        try { await api(`/api/posts/${id}/`, { method: "DELETE" }); snack("Post deleted."); tabs.feed?.refresh(); goBack(); }
        catch (err) { snack(err.message, true); }
      } },
    ] : [{ label: "Report post", action: report }]);

    const images = post.images || [];
    const gallery = images.length ? galleryView(images) : null;
    const author = post.author;
    fill(body, 
      gallery,
      h("div.section", {},
        h("div.row", {}, typeBadge(post.post_type), statusBadge(post.status), icon(categoryIcon(post.category), 16, "muted"), h("span.body-s", {}, post.category_label)),
        h("h2.headline-s", { style: { margin: "8px 0 4px" } }, post.title),
        h("div.row", { style: { flexWrap: "wrap" } },
          h("span.body-s", {}, `by ${author.display_name}`),
          post.author_returned_count > 0 ? h("span.chip", {}, icon("volunteer_activism", 14), `Returned ${post.author_returned_count} item${post.author_returned_count === 1 ? "" : "s"}`) : null,
          h("span.body-s", {}, `· ${post.post_type === "found" ? "found" : "lost"} ${timeAgo(post.occurred_at)}`)),
        post.description ? h("p.body-l", { style: { margin: "12px 0 0", whiteSpace: "pre-wrap" } }, post.description) : null),
      post.post_type === "found" && post.handover ? h("div.handover-card", {},
        h("div.row", {}, icon(handoverIcon(post.handover)), h("span.title-s", {}, post.handover_label)),
        post.handover_details ? h("div.title-m", { style: { fontWeight: 700, marginTop: "6px" } }, post.handover_details) : null,
        h("div.label-l", { style: { marginTop: "8px" } }, "What to do"),
        h("div", { style: { marginTop: "2px" } }, post.guidance)) : null,
      claimSection(),
      !post.is_owner && post.status !== "hidden" ? h("div.section", {},
        h("button.btn.btn-outlined.btn-block", { type: "button", onclick: () => openChat(id) },
          icon("chat_bubble", 18), post.post_type === "found" ? "Message the finder" : `Message ${post.author.display_name}`)) : null,
      locationSection(),
      h("div.section.row", {},
        h("button.btn.btn-tonal", { type: "button", onclick: () => run(() => api(`/api/posts/${id}/vote/`, { method: "POST" })) },
          icon(post.has_voted ? "arrow_circle_up_fill" : "arrow_circle_up", 18), `${post.score}  Upvote`),
        h("span.spacer"),
        h("span.body-s", {}, `Posted ${timeAgo(post.created_at)}`)),
      commentsSection(),
      composer());
    setTimeout(drawMiniMap, 0);
  }

  function galleryView(images) {
    const strip = h("div.gallery", {}, images.map((img) => h("img", { src: img.url, alt: post.title, loading: "lazy" })));
    const counter = h("div.gallery-count", {}, `1/${images.length}`);
    strip.addEventListener("scroll", () => {
      const index = Math.round(strip.scrollLeft / strip.clientWidth);
      counter.textContent = `${index + 1}/${images.length}`;
    }, { passive: true });
    const nav = (dir) => h("button.icon-btn.on-dark.gallery-nav", { type: "button", class: dir < 0 ? "prev" : "next", "aria-label": dir < 0 ? "Previous photo" : "Next photo",
      onclick: () => strip.scrollBy({ left: dir * strip.clientWidth, behavior: "smooth" }) }, icon(dir < 0 ? "chevron_left" : "chevron_right"));
    return h("div.gallery-wrap", {}, strip, images.length > 1 ? [counter, nav(-1), nav(1)] : null);
  }

  function claimSection() {
    if (post.is_owner) {
      if (!post.claims_enabled) return null;
      const pending = post.pending_claim_count || 0;
      return h("div.section", {}, h("a.btn.btn-outlined.btn-block", { href: `#/post/${id}/claims` },
        icon("how_to_reg", 18), pending > 0 ? `Review claims (${pending} waiting)` : "Review claims"));
    }
    const claim = post.my_claim;
    if (claim) {
      const [iconName, color, title] = {
        approved: ["check_circle_fill", "var(--green)", "The finder approved your claim"],
        rejected: ["cancel_fill", "var(--red)", "The finder didn't approve your claim"],
        revoked: ["undo", "var(--grey)", "The finder cancelled their approval"],
      }[claim.status] || ["hourglass_top", "var(--orange)", "Claim sent, waiting for the finder"];
      return h("div.card.claim-card", {},
        h("div.row", {}, h("span", { style: { color } }, icon(iconName)), h("span.title-s", {}, title)),
        claim.finder_response ? [h("div.label-m", { style: { marginTop: "8px" } }, "Message from the finder:"), h("div.body-l", {}, claim.finder_response)] : null,
        claim.status === "approved" ? h("p.body-s", { style: { margin: "8px 0 0" } }, "Meet in a public place. Never pay anyone to get your item back.") : null,
        claim.status === "pending" ? h("div", { style: { textAlign: "right" } },
          h("button.btn.btn-text", { type: "button", onclick: () => run(() => api(`/api/claims/${claim.id}/withdraw/`, { method: "POST" }), "Claim withdrawn.") }, "Withdraw claim")) : null);
    }
    if (post.claims_enabled && post.status === "open") {
      return h("div.section", {}, h("button.btn.btn-filled.btn-block", { type: "button", onclick: claimDialog }, icon("front_hand", 18), "This is mine: claim it"));
    }
    return null;
  }

  async function claimDialog() {
    const answer = h("input", { autocomplete: "off" });
    const note = h("textarea", { rows: 2 });
    const fAnswer = field("Your answer", answer);
    const result = await dialog({
      title: "Claim this item",
      body: h("div", {},
        h("p.variant", { style: { margin: 0 } }, "The finder asks a question only the owner would know. They'll see your answer and decide."),
        h("p.title-s", { style: { margin: "12px 0 0" } }, post.verification_question),
        fAnswer, field("Message to the finder (optional)", note), honeypot()),
      actions: [{ label: "Cancel", value: null }, { label: "Send claim", submit: true, kind: "filled" }],
      onSubmit: (form) => {
        if (!answer.value.trim()) { setFieldError(fAnswer, "Answer the finder's question to send a claim."); return false; }
        return { answer: answer.value.trim(), message: note.value.trim(), website: honeypotValue(form) };
      },
    });
    if (result) run(() => api(`/api/posts/${id}/claims/`, { method: "POST", body: result }), "Claim sent. The finder will review it.");
  }

  function report() {
    const reasons = state.meta?.report_reasons || [];
    const close = sheet(h("div", {},
      h("div.title-m", { style: { padding: "4px 24px 8px" } }, "Why are you reporting this post?"),
      reasons.map((r) => h("button.list-tile", { type: "button", onclick: async () => {
        close();
        try {
          const data = await api(`/api/posts/${id}/report/`, { method: "POST", body: { reason: r.value, details: "", website: "" } });
          snack(data?.detail || "Reported.");
        } catch (err) { snack(err.message, true); }
      } }, h("span.body-l", {}, r.label)))));
  }

  function locationSection() {
    return h("div.section", {},
      h("div.title-s", {}, post.post_type === "found" ? "Where it was found" : "Where it was lost"),
      h("div.mini-map", { id: `mini-${id}` }),
      post.landmark ? h("div.row", { style: { marginTop: "6px" } }, icon("place", 18), h("span", {}, post.landmark)) : null,
      post.location_is_approximate ? h("p.body-s", { style: { margin: "4px 0 0" } },
        `Approximate area (about ${Math.round(post.approx_radius_m || 250)} m). The exact spot is shared once the finder approves your claim.`) : null,
      post.accuracy_m ? h("p.body-s.muted", { style: { margin: "4px 0 0" } }, `GPS accuracy when posted: about ${Math.round(post.accuracy_m)} m`) : null);
  }
  function drawMiniMap() {
    const box = document.getElementById(`mini-${id}`);
    if (!box || typeof L === "undefined") return;
    miniMap = L.map(box, { zoomControl: false, scrollWheelZoom: false, attributionControl: true })
      .setView([post.latitude, post.longitude], post.location_is_approximate ? 15 : 16);
    baseLayer().addTo(miniMap);
    postMarker(post).addTo(miniMap);
  }

  function commentsSection() {
    const byParent = new Map();
    for (const c of comments) {
      const key = c.parent || 0;
      if (!byParent.has(key)) byParent.set(key, []);
      byParent.get(key).push(c);
    }
    const nodes = [];
    const walk = (parent, level) => {
      for (const c of byParent.get(parent) || []) {
        nodes.push(h("div.comment", { class: level > 0 ? "reply" : "" },
          h("div.who", {},
            h("span.label-l", {}, c.author.display_name),
            c.is_post_author ? h("span.op-tag", {}, post.post_type === "found" ? "FINDER" : "OWNER") : null,
            h("span.body-s.muted", {}, timeAgo(c.created_at))),
          h("div", { style: { whiteSpace: "pre-wrap" } }, c.body),
          h("button.btn.btn-text", { type: "button", style: { height: "32px", padding: "0 8px", marginLeft: "-8px" }, onclick: () => {
            replyTo = c;
            draw();
            setTimeout(() => document.querySelector(".composer input:not([tabindex='-1'])")?.focus(), 0);
          } }, "Reply")));
        walk(c.id, level + 1);
      }
    };
    walk(0, 0);
    return h("div", { style: { paddingBottom: "8px" } },
      h("div.title-s", { style: { padding: "20px 16px 4px" } }, `Comments (${comments.length})`),
      comments.length ? nodes : h("p.body-s", { style: { padding: "0 16px" } }, "No comments yet. Know whose this is? Say so here."));
  }

  function composer() {
    const input = h("input", { placeholder: "Add a comment", "aria-label": "Add a comment", maxlength: "2000" });
    const send = h("button.icon-btn", { type: "submit", "aria-label": "Send" }, icon("send"));
    const form = h("form", {}, input, honeypot(), send);
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const text = input.value.trim();
      if (!text) return;
      send.disabled = true;
      try {
        await api(`/api/posts/${id}/comments/`, { method: "POST", body: { body: text, parent: replyTo?.id ?? null, website: honeypotValue(form) } });
        replyTo = null;
        await load();
      } catch (err) { snack(err.message, true); send.disabled = false; }
    });
    return h("div.composer", {},
      replyTo ? h("div.replying", {}, h("span", { style: { flex: 1 } }, `Replying to ${replyTo.author.display_name}`),
        h("button.icon-btn", { type: "button", "aria-label": "Cancel reply", style: { width: "32px", height: "32px" }, onclick: () => { replyTo = null; draw(); } }, icon("close", 18))) : null,
      form);
  }

  load();
  return { el, cleanup: () => { miniMap?.remove(); tabs.feed?.refreshCard(id); } };
}

// ===================================================================== claims review
function claimsScreen(id) {
  let post = null;
  let claims = null;
  const body = h("div", {}, h("div.splash", { style: { minHeight: "60vh" } }, spinner()));
  const el = h("main", {}, appbar("Claims", { back: true }), body);

  async function load() {
    try {
      [post, claims] = await Promise.all([api(`/api/posts/${id}/`), api(`/api/posts/${id}/claims/`)]);
      draw();
    } catch (err) {
      fill(body, message({ icon: "error_outline", title: err.message, actionLabel: "Try again", onAction: load }));
    }
  }
  async function decide(claim, approve, response) {
    try {
      await api(`/api/claims/${claim.id}/decide/`, { method: "POST", body: { decision: approve ? "approve" : "reject", response } });
      snack(approve ? "Approved. Now meet them somewhere public." : "Claim rejected.");
      await load();
    } catch (err) { snack(err.message, true); }
  }
  async function followUp() {
    const question = await promptText({
      title: "Ask a follow-up question",
      message: "Each person with a waiting claim gets it privately in Messages, so they can't copy each other. Ask about something not visible in your photos.",
      hint: "e.g. What's written on the back? What else was inside?",
      confirm: "Ask",
    });
    if (!question) return;
    try {
      const data = await api(`/api/posts/${id}/follow-up/`, { method: "POST", body: { question } });
      snack(data.detail);
    } catch (err) { snack(err.message, true); }
  }
  function draw() {
    const anyApproved = claims.some((c) => c.status === "approved");
    fill(body, h("div", { style: { padding: "16px" } },
      h("div.card", { style: { background: "var(--surface-highest)", padding: "14px" } },
        h("div.label-m", {}, "Your question"),
        h("div.title-m", {}, post.verification_question),
        h("p.body-s", { style: { margin: "8px 0 0" } }, "Approve only someone whose answer matches. Hand over in a public place, and never ask for or send money.")),
      claims.some((c) => c.status === "pending") && !anyApproved ? [
        h("button.btn.btn-outlined.btn-block", { type: "button", style: { marginTop: "8px" }, onclick: followUp }, icon("quiz", 18), "Ask a follow-up question"),
        claims.filter((c) => c.status === "pending").length > 1
          ? h("p.body-s", { style: { margin: "6px 0 0" } }, "Several people answered? Ask a second question only the owner could know, chat with them, or hand the item over at a police station where they can check proof.")
          : null,
      ] : null,
      !claims.length ? message({ icon: "inbox", title: "No claims yet", body: "When someone says it's theirs, their answer shows up here." }) : null,
      claims.map((claim) => {
        const [color, label] = { approved: ["var(--green)", "APPROVED"], rejected: ["var(--red)", "REJECTED"], revoked: ["var(--grey)", "APPROVAL CANCELLED"] }[claim.status] || ["var(--orange)", "WAITING"];
        const name = claim.claimant.display_name;
        return h("div.card", { style: { marginTop: "12px", padding: "14px" } },
          h("div.row", {},
            h("div", { style: { width: "40px", height: "40px", borderRadius: "50%", background: "var(--primary-container)", color: "var(--on-primary-container)", display: "grid", placeItems: "center", fontWeight: 500 } }, (name[0] || "?").toUpperCase()),
            h("div", { style: { flex: 1, marginLeft: "4px" } }, h("div.title-s", {}, name), h("div.body-s", {}, timeAgo(claim.created_at))),
            h("span", { style: { color, fontSize: "11px", fontWeight: 700 } }, label)),
          h("div.label-m", { style: { marginTop: "10px" } }, "Their answer"),
          h("div.body-l", { style: { fontWeight: 600 } }, claim.answer),
          claim.message ? [h("div.label-m", { style: { marginTop: "8px" } }, "Message"), h("div", {}, claim.message)] : null,
          claim.finder_response ? [h("div.label-m", { style: { marginTop: "8px" } }, "Your reply"), h("div", {}, claim.finder_response)] : null,
          h("div.row", { style: { justifyContent: "flex-end", marginTop: "10px", flexWrap: "wrap" } },
            h("button.btn.btn-text", { type: "button", onclick: () => openChat(id, claim.claimant.id) }, icon("chat_bubble", 18), "Message"),
            claim.status === "pending" ? [h("button.btn.btn-text", { type: "button", onclick: async () => {
              const r = await promptText({ title: "Reject this claim?", message: "Optionally tell them why.", hint: "The answer didn't match", confirm: "Reject", required: false });
              if (r !== null) decide(claim, false, r);
            } }, "Reject"),
            h("button.btn.btn-filled", { type: "button", disabled: anyApproved, onclick: async () => {
              const r = await promptText({ title: `Approve ${name}?`, message: "Tell them where and when to collect the item. Only they will see this.", hint: "e.g. Gate 2 of the metro station, tomorrow 5 pm. Call me on ...", confirm: "Approve" });
              if (r !== null) decide(claim, true, r);
            } }, "Approve")] : null),
          claim.status === "approved" && post.status !== "returned" ? h("div", { style: { textAlign: "right", marginTop: "6px" } },
            h("button.btn.btn-text", { type: "button", onclick: async () => {
              const reason = await promptText({ title: `Cancel approval for ${name}?`, message: "They'll lose the exact location and the item opens for claims again. They won't be able to claim it a second time.", hint: "e.g. Didn't turn up / the answer was a lucky guess", confirm: "Cancel approval", required: false });
              if (reason === null) return;
              try {
                await api(`/api/claims/${claim.id}/revoke/`, { method: "POST", body: { response: reason } });
                snack("Approval cancelled. You can approve someone else now.");
                await load();
              } catch (err) { snack(err.message, true); }
            } }, icon("undo", 18), "Cancel approval")) : null);
      })));
  }
  load();
  return { el };
}

// ===================================================================== messages
function messagesScreen() {
  let chats = null;
  let error = null;
  const list = h("div");
  const el = h("main.with-nav", {}, appbar("Messages"), list);

  function draw() {
    if (error && !chats) { fill(list, message({ icon: "cloud_off", title: error, actionLabel: "Try again", onAction: refresh })); return; }
    if (!chats) { fill(list, h("div.list-end", {}, spinner())); return; }
    if (!chats.length) {
      fill(list, h("div", { style: { paddingTop: "60px" } }, message({ icon: "chat_bubble", title: "No messages yet", body: "Open a post and tap \u201cMessage the finder\u201d to ask about an item." })));
      return;
    }
    fill(list, chats.map((c) => {
      const unread = c.unread > 0;
      const last = c.last_message;
      const preview = c.blocked ? "Chat blocked" : last ? (last.sender_is_me ? `You: ${last.body}` : last.body) : "";
      return h("a.chat-tile", { href: `#/chat/${c.id}`, class: unread ? "unread" : "" },
        h("div.chat-thumb", {}, netImage(c.post.thumbnail, categoryIcon(c.post.category), c.post.title)),
        h("div.chat-body", {},
          h("div.row", {}, h("span.chat-name", {}, c.other_user.display_name), h("span.spacer"), h("span.body-s.muted", {}, timeAgo(c.last_message_at))),
          h("div.row", {}, typeBadge(c.post.post_type), h("span.label-m.chat-post", {}, c.post.title)),
          h("div.row", {}, h("span.chat-preview", {}, preview), unread ? h("span.count-badge", {}, String(c.unread)) : null)));
    }));
  }
  async function refresh() {
    try {
      const data = await api("/api/conversations/");
      chats = data.results;
      error = null;
    } catch (err) { error = err.message; }
    draw();
    refreshUnread();
  }
  draw();
  refresh();
  return { el, refresh, shown: refresh };
}

function chatScreen(id) {
  const msgs = [];
  let blocked = false;
  let blockedByMe = false;
  let polling = false;
  let loaded = false;
  let convo = null;
  const list = h("div.chat-list", { role: "log", "aria-live": "polite" });
  const safety = h("div.chat-safety", { hidden: true });
  const more = h("button.icon-btn", { type: "button", "aria-label": "More options" }, icon("more_vert"));
  const bar = appbar("Chat", { back: true, actions: [more] });
  const input = h("textarea", { rows: 1, maxlength: "2000", placeholder: "Message", "aria-label": "Message" });
  const send = h("button.icon-btn", { type: "submit", "aria-label": "Send" }, icon("send"));
  const form = h("form.chat-form", {}, input, send);
  const composer = h("div.composer");
  const el = h("main.chat-screen", {}, bar, safety, list, composer);

  function bubble(m) {
    return h("div.bubble", { class: m.sender_is_me ? "mine" : "theirs", "data-id": m.id },
      h("div.bubble-text", {}, m.body), h("div.bubble-time", {}, timeAgo(m.created_at)));
  }
  function drawComposer() {
    if (blocked) {
      fill(composer, h("p.center.muted", { style: { margin: "8px" } },
        blockedByMe ? "You blocked this chat. Unblock it from the menu to send messages." : "This chat is blocked."));
    } else if (!composer.contains(form)) fill(composer, form);
  }
  function drawEmpty() {
    if (loaded && !msgs.length && !list.querySelector(".message")) {
      fill(list, message({ icon: "chat_bubble", title: "No messages yet", body: "Say hello. Ask about details only the owner would know, and agree to meet somewhere public." }));
    }
  }
  async function poll() {
    if (polling || document.hidden) return;
    polling = true;
    try {
      const after = msgs.length ? msgs[msgs.length - 1].id : null;
      const data = await api(`/api/conversations/${id}/messages/`, { query: { after } });
      const atBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 80;
      const fresh = data.results.filter((m) => !msgs.some((x) => x.id === m.id));
      if (fresh.length && !msgs.length) list.replaceChildren();
      for (const m of fresh) { msgs.push(m); list.append(bubble(m)); }
      blocked = data.blocked;
      blockedByMe = data.blocked_by_me;
      if (data.safety_note) { safety.hidden = false; fill(safety, icon("shield", 18), h("span", {}, data.safety_note)); }
      loaded = true;
      drawComposer();
      drawEmpty();
      if (fresh.length && (atBottom || msgs.length === fresh.length)) window.scrollTo(0, document.body.scrollHeight);
    } catch (err) {
      if (!loaded) fill(list, message({ icon: "cloud_off", title: err.message, actionLabel: "Try again", onAction: poll }));
    } finally { polling = false; }
  }
  async function loadInfo() {
    try {
      convo = await api(`/api/conversations/${id}/`);
      const title = bar.querySelector(".appbar-title");
      fill(title, h("div.chat-title", {}, convo.other_user.display_name), h("div.body-s.chat-sub", {}, convo.post.title));
    } catch { /* the messages call shows the error */ }
  }
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    send.disabled = true;
    try {
      const m = await api(`/api/conversations/${id}/messages/`, { method: "POST", body: { body: text } });
      input.value = "";
      input.style.height = "";
      if (!msgs.some((x) => x.id === m.id)) {
        if (!msgs.length) list.replaceChildren();
        msgs.push(m);
        list.append(bubble(m));
      }
      window.scrollTo(0, document.body.scrollHeight);
    } catch (err) { snack(err.message, true); }
    finally { send.disabled = false; input.focus(); }
  });
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); } });
  input.addEventListener("input", () => { input.style.height = ""; input.style.height = `${Math.min(input.scrollHeight, 120)}px`; });
  more.addEventListener("click", () => menu(more, [
    convo ? { label: "View post", action: () => { location.hash = `#/post/${convo.post.id}`; } } : null,
    !blocked ? { label: "Block chat", action: async () => {
      if (!(await confirmDialog("Block this chat?", "Neither of you will be able to send messages. You can unblock it later.", "Block"))) return;
      try { snack((await api(`/api/conversations/${id}/block/`, { method: "POST" })).detail); poll(); } catch (err) { snack(err.message, true); }
    } } : null,
    blockedByMe ? { label: "Unblock chat", action: async () => {
      try { snack((await api(`/api/conversations/${id}/unblock/`, { method: "POST" })).detail); blocked = false; drawComposer(); poll(); } catch (err) { snack(err.message, true); }
    } } : null,
    { label: "Report chat", action: async () => {
      const reason = await promptText({ title: "Report this chat?", message: "A moderator will read it. Tell us what happened (optional).", hint: "e.g. Asked me to pay to get the item back", confirm: "Report", required: false });
      if (reason === null) return;
      try { snack((await api(`/api/conversations/${id}/report/`, { method: "POST", body: { reason } })).detail); } catch (err) { snack(err.message, true); }
    } },
  ].filter(Boolean)));

  fill(list, h("div.list-end", {}, spinner()));
  loadInfo();
  poll();
  const timer = setInterval(poll, 4000);
  return { el, mounted: () => input.focus(), cleanup: () => { clearInterval(timer); tabs.messages?.refresh(); refreshUnread(); } };
}

// ===================================================================== activity
function activityScreen() {
  let tab = "posts";
  let posts = null;
  let claims = null;
  let error = null;
  const content = h("div");
  const tabsBar = h("div.tabs", { role: "tablist" });
  const name = state.user ? (state.user.display_name || state.user.username) : null;
  const bar = appbar(name ? `Hi, ${name}` : "My activity", {
    actions: [actionBtn("logout", "Log out", async () => {
      if (!(await confirmDialog("Log out?", "You can log back in any time.", "Log out"))) return;
      api("/api/auth/logout/", { method: "POST" }).catch(() => {});
      signOut();
    })],
  });
  bar.append(tabsBar);
  const el = h("main.with-nav", {}, bar, content);

  function drawTabs() {
    fill(tabsBar, ...[["posts", "My posts"], ["claims", "My claims"]].map(([key, label]) =>
      h("button", { type: "button", role: "tab", "aria-selected": String(tab === key), class: tab === key ? "on" : "", onclick: () => { tab = key; drawTabs(); draw(); } }, label)));
  }
  function draw() {
    if (error) { fill(content, message({ icon: "cloud_off", title: error, actionLabel: "Try again", onAction: refresh })); return; }
    if (tab === "posts") {
      if (!posts) { fill(content, h("div.list-end", {}, spinner())); return; }
      if (!posts.length) { fill(content, h("div", { style: { paddingTop: "60px" } }, message({ icon: "post_add", title: "You haven't posted yet", body: "Tap Post to share something you found or lost." }))); return; }
      fill(content, h("div", { style: { paddingTop: "8px" } }, posts.map((p) => postCard(p, {
        trailing: p.pending_claims > 0 ? h("span.count-badge", {}, `${p.pending_claims} claim${p.pending_claims === 1 ? "" : "s"}`) : null }))));
      return;
    }
    if (!claims) { fill(content, h("div.list-end", {}, spinner())); return; }
    if (!claims.length) { fill(content, h("div", { style: { paddingTop: "60px" } }, message({ icon: "front_hand", title: "No claims sent", body: "When you claim an item a finder kept, you can follow it here." }))); return; }
    fill(content, h("div", { style: { paddingTop: "8px" } }, claims.map((c) => {
      const [iconName, color, label] = {
        approved: ["check_circle_fill", "var(--green)", "Approved"], rejected: ["cancel_fill", "var(--red)", "Not approved"],
        revoked: ["undo", "var(--grey)", "Approval cancelled"] }[c.status] || ["hourglass_top", "var(--orange)", "Waiting for the finder"];
      return h("a.card.claim-row", { href: `#/post/${c.post_id}` },
        h("span", { style: { color } }, icon(iconName)),
        h("div", { style: { minWidth: 0 } },
          h("div.body-l", {}, c.post_title),
          h("div.variant", {}, `${label} · ${timeAgo(c.created_at)}`),
          c.finder_response ? h("div", { style: { fontWeight: 600, marginTop: "4px" } }, `Finder: ${c.finder_response}`) : null));
    })));
  }
  async function refresh() {
    try {
      const [p, c] = await Promise.all([api("/api/me/posts/"), api("/api/me/claims/")]);
      posts = p.results;
      claims = c.results;
      error = null;
    } catch (err) { error = err.message; }
    draw();
  }
  drawTabs();
  draw();
  refresh();
  return { el, refresh, shown: refresh };
}

// ===================================================================== create post
// Shrinks a photo to at most 2000 px (like the app) and re-encodes it as JPEG,
// which also applies the camera's rotation and drops hidden location data.
async function preparePhoto(file) {
  let bitmap;
  try { bitmap = await createImageBitmap(file, { imageOrientation: "from-image" }); }
  catch { bitmap = await new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("That file isn't a photo we can read."));
    img.src = URL.createObjectURL(file);
  }); }
  const scale = Math.min(1, 2000 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
  if (!blob) throw new Error("Couldn't prepare that photo.");
  return { blob, url: URL.createObjectURL(blob), width: canvas.width, height: canvas.height };
}

function blurEditor(photo, regions) {
  return new Promise((resolve) => {
    const boxes = regions.map((r) => ({ ...r }));
    const img = h("img", { src: photo.url, alt: "Photo to blur" });
    const wrap = h("div.blur-canvas-wrap", {}, img);
    const count = h("span.body-s", { style: { marginLeft: "auto", color: "rgba(255,255,255,.7)" } });
    const drawBoxes = () => {
      wrap.querySelectorAll(".blur-box").forEach((b) => b.remove());
      for (const b of boxes) wrap.append(h("div.blur-box", { style: { left: `${b.x * 100}%`, top: `${b.y * 100}%`, width: `${b.w * 100}%`, height: `${b.h * 100}%` } }));
      count.textContent = `${boxes.length} area${boxes.length === 1 ? "" : "s"}`;
    };
    let start = null;
    let live = null;
    const point = (e) => {
      const r = img.getBoundingClientRect();
      return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) };
    };
    wrap.addEventListener("pointerdown", (e) => { start = point(e); wrap.setPointerCapture(e.pointerId); live = h("div.blur-box"); wrap.append(live); });
    wrap.addEventListener("pointermove", (e) => {
      if (!start) return;
      const p = point(e);
      Object.assign(live.style, { left: `${Math.min(start.x, p.x) * 100}%`, top: `${Math.min(start.y, p.y) * 100}%`, width: `${Math.abs(p.x - start.x) * 100}%`, height: `${Math.abs(p.y - start.y) * 100}%` });
    });
    wrap.addEventListener("pointerup", (e) => {
      if (!start) return;
      const p = point(e);
      const box = { x: Math.min(start.x, p.x), y: Math.min(start.y, p.y), w: Math.abs(p.x - start.x), h: Math.abs(p.y - start.y) };
      start = null;
      live?.remove();
      if (box.w > 0.02 && box.h > 0.02 && boxes.length < 30) boxes.push(box);
      drawBoxes();
    });
    const done = () => { editor.remove(); resolve(boxes); };
    const editor = h("div.blur-editor", { role: "dialog", "aria-modal": "true", "aria-label": "Hide private details" },
      h("div.appbar-row.has-back", {},
        h("button.icon-btn.on-dark", { type: "button", "aria-label": "Close", onclick: () => { editor.remove(); resolve(regions); } }, icon("close")),
        h("div.appbar-title", {}, "Hide private details"),
        h("button.btn.btn-text", { type: "button", style: { color: "#fff" }, onclick: done }, "Done")),
      h("div.hint", {}, "Drag a box over ID numbers, card numbers, addresses or faces. Those areas are blurred before the photo is posted."),
      h("div.blur-stage", {}, wrap),
      h("div.blur-tools", {},
        h("button.btn.btn-text", { type: "button", onclick: () => { boxes.pop(); drawBoxes(); } }, icon("undo", 18), "Undo"),
        h("button.btn.btn-text", { type: "button", onclick: () => { boxes.length = 0; drawBoxes(); } }, icon("delete", 18), "Clear"),
        count));
    document.body.append(editor);
    drawBoxes();
  });
}

function createScreen(postType) {
  const found = postType === "found";
  const maxImages = state.meta?.max_images || 5;
  const draft = { photos: [], lat: null, lng: null, accuracy: null, pinMoved: false, locating: false, locError: null, handover: "" };
  let pickerMap = null;
  let marker = null;
  let submitting = false;
  const errors = {};

  const photoRow = h("div.photo-row");
  const photoErr = h("div");
  const camInput = h("input", { type: "file", accept: "image/*", capture: "environment", hidden: true });
  const galInput = h("input", { type: "file", accept: "image/*", hidden: true });
  camInput.addEventListener("change", () => addPhoto(camInput, true));
  galInput.addEventListener("change", () => addPhoto(galInput, false));

  const mapBox = h("div.picker-map");
  const locStatus = h("span", { style: { flex: 1 } });
  const useLoc = h("button.btn.btn-text", { type: "button", onclick: () => captureLocation() }, "Use my location");

  const landmark = h("input", { maxlength: "200", placeholder: "e.g. Near Gate 2, Orion Mall food court" });
  const title = h("input", { maxlength: "120", placeholder: found ? "Black wallet near bus stop" : "Lost: blue backpack" });
  const category = h("select", {}, (state.meta?.categories || []).map((c) => h("option", { value: c.value, selected: c.value === "other" }, c.label)));
  const docsWarn = h("div.warn-box", { hidden: true }, "Blur ID numbers, card numbers and addresses on every photo before posting.");
  category.addEventListener("change", () => { docsWarn.hidden = category.value !== "documents"; });
  const description = h("textarea", { rows: 3, maxlength: "2000", placeholder: found
    ? "Colour, brand, what's inside. Keep one detail back for your verification question."
    : "Colour, brand, marks, anything that helps a finder recognise it" });
  const when = h("input", { type: "datetime-local" });
  const pad = (n) => String(n).padStart(2, "0");
  const localValue = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  when.value = localValue(new Date());
  when.max = localValue(new Date());
  const details = h("input", { maxlength: "200" });
  const question = h("input", { maxlength: "200", placeholder: "What's the phone wallpaper? What's inside the wallet?" });

  const fLandmark = field(found ? "Landmark (required)" : "Landmark or area", landmark);
  const fTitle = field("Title", title);
  const fCategory = field("Category", category);
  const fDescription = field("Description", description);
  const fWhen = field(found ? "When you found it" : "When you lost it", when);
  const fDetails = field("Police station name", details);
  const fQuestion = field("Verification question", question, { helper: "Only the real owner should know the answer. Don't reveal it in the description." });
  const handoverBox = h("div");
  const handoverErr = h("div");
  const submit = h("button.btn.btn-filled.btn-block", { type: "submit" }, icon("send", 18), "Post");
  const formErr = h("div");

  const form = h("form.form-pad", { novalidate: true },
    section(found ? "1. Photos" : "1. Photos (optional)", found ? "Take a clear photo. Your location is tagged when you take it." : "A photo of the item, if you have one."),
    photoRow, photoErr, camInput, galInput,
    section(found ? "2. Where you found it" : "2. Where you lost it", "Tap the map to move the pin if GPS is off."),
    mapBox, h("div.loc-status", {}, icon("my_location", 18), locStatus, useLoc),
    fLandmark,
    section("3. About the item", null),
    fTitle, fCategory, docsWarn, fDescription, fWhen,
    found ? [section("4. What did you do with it?", "This tells the owner exactly where to go."), handoverBox, handoverErr, fDetails, fQuestion] : null,
    honeypot(), formErr,
    h("div.submit-row", {}, submit),
    h("p.body-s.center", {}, "Photos are cleaned of hidden location data before they are stored."));
  const el = h("main", {}, appbar(found ? "Post a found item" : "Post a lost item", { back: true }), form);

  function section(text, sub) {
    return h("div.form-section", {}, h("h2", {}, text), sub ? h("div.body-s.variant", {}, sub) : null);
  }

  function drawPhotos() {
    fill(photoRow, 
      ...draft.photos.map((photo, i) => h("div.photo-tile", {},
        h("img", { src: photo.url, alt: `Photo ${i + 1}` }),
        h("button.round-btn.close", { type: "button", "aria-label": "Remove photo", onclick: () => { URL.revokeObjectURL(photo.url); draft.photos.splice(i, 1); drawPhotos(); } }, icon("close", 18)),
        h("button.round-btn.blur", { type: "button", "aria-label": "Blur private details", class: photo.regions.length ? "on" : "", onclick: async () => { photo.regions = await blurEditor(photo, photo.regions); drawPhotos(); } }, icon("blur_on", 18)))),
      draft.photos.length < maxImages ? [
        h("button.add-tile", { type: "button", onclick: () => camInput.click() }, icon("photo_camera"), "Camera"),
        h("button.add-tile", { type: "button", onclick: () => galInput.click() }, icon("photo_library"), "Gallery"),
      ] : null);
  }
  async function addPhoto(input, fromCamera) {
    const file = input.files?.[0];
    input.value = "";
    if (!file) return;
    if (draft.photos.length >= maxImages) { snack(`You can add up to ${maxImages} photos.`); return; }
    try {
      const photo = await preparePhoto(file);
      draft.photos.push({ ...photo, regions: [] });
      drawPhotos();
    } catch (err) { snack(err.message, true); return; }
    if (found && !draft.pinMoved) {
      if (fromCamera) captureLocation();
      else if (draft.lat === null) { captureLocation(); snack("Photo from gallery: check the pin is where you found the item."); }
      else snack("Photo from gallery: check the pin is where you found the item.");
    }
  }

  function drawLocStatus() {
    let text;
    if (draft.locating) text = "Getting your location...";
    else if (draft.locError) text = draft.locError;
    else if (draft.lat === null) text = found ? "Location will be tagged when you take the photo." : "Tap the map to set the place.";
    else if (draft.pinMoved) text = "Pin placed by you.";
    else text = draft.accuracy !== null && draft.accuracy > 100
      ? `GPS is rough here (about ${Math.round(draft.accuracy)} m off). Tap the map to put the pin on the exact spot.`
      : `Tagged from GPS (about ${draft.accuracy !== null ? Math.round(draft.accuracy) : "?"} m accuracy).`;
    locStatus.textContent = text;
    useLoc.disabled = draft.locating;
  }
  function setPin(lat, lng, byHand) {
    draft.lat = lat;
    draft.lng = lng;
    if (byHand) { draft.pinMoved = true; draft.accuracy = null; }
    if (pickerMap) {
      if (!marker) {
        marker = L.marker([lat, lng], { draggable: true, icon: L.divIcon({ className: "", html: `<span class="dot" style="background:${found ? FOUND : LOST};width:22px;height:22px;display:block"></span>`, iconSize: [22, 22], iconAnchor: [11, 11] }) }).addTo(pickerMap);
        marker.on("dragend", () => { const p = marker.getLatLng(); setPin(p.lat, p.lng, true); });
      } else marker.setLatLng([lat, lng]);
      if (!byHand) pickerMap.setView([lat, lng], 17);
    }
    drawLocStatus();
  }
  async function captureLocation() {
    draft.locating = true;
    draft.locError = null;
    drawLocStatus();
    try {
      const pos = await geo.current();
      draft.accuracy = pos.accuracy;
      draft.pinMoved = false;
      draft.locating = false;
      setPin(pos.lat, pos.lng, false);
    } catch (err) {
      draft.locating = false;
      draft.locError = `${err.message} Tap the map to place the pin.`;
      drawLocStatus();
    }
  }

  function drawHandover() {
    const options = state.meta?.handover_options || [];
    fill(handoverBox, ...options.map((o) => h("label.radio-tile", {},
      h("input", { type: "radio", name: "handover", value: o.value, checked: draft.handover === o.value, onchange: () => { draft.handover = o.value; drawHandover(); } }),
      icon(handoverIcon(o.value)),
      h("div", {}, h("div.body-l", {}, o.label),
        draft.handover === o.value && o.guidance ? h("div.body-s.variant", {}, `Owner will see: ${o.guidance}`) : null))));
    const needsDetails = draft.handover === "police" || draft.handover === "desk";
    fDetails.hidden = !needsDetails;
    fDetails.querySelector("label").textContent = draft.handover === "police" ? "Police station name" : "Desk or office name";
    details.placeholder = draft.handover === "police" ? "Rajajinagar Police Station" : "Mall security, ground floor";
    fQuestion.hidden = draft.handover !== "kept";
  }

  function showErrors(fields) {
    const map = { landmark: fLandmark, title: fTitle, category: fCategory, description: fDescription, occurred_at: fWhen, handover_details: fDetails, verification_question: fQuestion };
    for (const [key, wrap] of Object.entries(map)) setFieldError(wrap, fields[key] || null);
    fill(photoErr, ...["images", "blur_regions"].filter((k) => fields[k]).map((k) => h("p.err-text", {}, fields[k])));
    fill(handoverErr, fields.handover ? h("p.err-text", {}, fields.handover) : "");
    const where = fields.latitude || fields.longitude;
    fill(formErr, where ? h("p.err-text", {}, where) : "");
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (submitting) return;
    const problems = {};
    if (title.value.trim().length < 3) problems.title = "Give it a short title";
    if (found && !draft.photos.length) problems.images = "Add at least one photo of the item you found.";
    if (found && !landmark.value.trim()) problems.landmark = "Add a landmark; GPS is often off indoors.";
    if (draft.lat === null) problems.latitude = "Set the location on the map first.";
    if (found && !draft.handover) problems.handover = "Tell the owner what you did with the item.";
    if (found && (draft.handover === "police" || draft.handover === "desk") && !details.value.trim())
      problems.handover_details = draft.handover === "police" ? "Name the police station." : "Name the desk or office.";
    if (found && draft.handover === "kept" && !question.value.trim())
      problems.verification_question = "Ask something only the owner would know, e.g. 'What is the phone wallpaper?'";
    if (found && category.value === "documents" && draft.photos.length && !draft.photos.some((p) => p.regions.length))
      problems.blur_regions = "Blur ID numbers, card numbers and addresses before posting documents.";
    showErrors(problems);
    if (Object.keys(problems).length) { snack(Object.values(problems)[0], true); return; }

    const data = new FormData();
    const put = (k, v) => { if (v !== null && v !== undefined && String(v) !== "") data.append(k, v); };
    put("post_type", postType);
    put("title", title.value.trim());
    put("description", description.value.trim());
    put("category", category.value);
    put("latitude", draft.lat.toFixed(7));
    put("longitude", draft.lng.toFixed(7));
    put("accuracy_m", draft.accuracy !== null ? draft.accuracy.toFixed(1) : null);
    put("landmark", landmark.value.trim());
    const occurred = when.value ? new Date(when.value) : new Date();
    put("occurred_at", (occurred > new Date() ? new Date() : occurred).toISOString());
    if (found) {
      put("handover", draft.handover);
      put("handover_details", details.value.trim());
      put("verification_question", question.value.trim());
    }
    if (draft.photos.some((p) => p.regions.length)) put("blur_regions", JSON.stringify(draft.photos.map((p) => p.regions)));
    draft.photos.forEach((p, i) => data.append("images", p.blob, `photo-${i + 1}.jpg`));
    put("website", honeypotValue(form));

    submitting = true;
    submit.disabled = true;
    fill(submit, spinner(true), "Posting...");
    try {
      const post = await api("/api/posts/", { method: "POST", form: data, timeout: 120000 });
      snack(found ? "Posted. Thanks for helping!" : "Posted. We hope it turns up soon.");
      tabs.feed?.refresh();
      tabs.activity?.refresh();
      location.replace(`#/post/${post.id}`);
    } catch (err) {
      showErrors(err.fields || {});
      snack(err.message, true);
      submitting = false;
      submit.disabled = false;
      fill(submit, icon("send", 18), "Post");
    }
  });

  drawPhotos();
  drawLocStatus();
  if (found) drawHandover();
  return {
    el,
    mounted() {
      if (typeof L === "undefined") return;
      const last = geo.lat !== null ? [geo.lat, geo.lng] : (geo.last() ? [geo.last().lat, geo.last().lng] : DEFAULT_CENTER);
      pickerMap = L.map(mapBox, { scrollWheelZoom: false }).setView(last, 15);
      baseLayer().addTo(pickerMap);
      pickerMap.on("click", (e) => setPin(e.latlng.lat, e.latlng.lng, true));
      if (!found) captureLocation();
    },
    cleanup() { pickerMap?.remove(); draft.photos.forEach((p) => URL.revokeObjectURL(p.url)); },
  };
}

// ===================================================================== start
function start() {
  if (typeof L === "undefined") {
    // Leaflet is loaded with `defer` before this module, so this is rare.
    window.addEventListener("load", route, { once: true });
    return;
  }
  route();
  refreshUnread();
}
start();
