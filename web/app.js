// 网页生成器：全部在浏览器里完成，不上传任何内容。与命令行共用 lib/ 里的生成逻辑。
import yaml from "../lib/js-yaml.mjs";
import { DEFAULTS, build, rsTag, ruleSetRefs, ruleSetUrl } from "../lib/build.js";
import { ABROAD, CN4, ENTRY } from "../lib/groups.js";
import { makeZip } from "./zip.js";

const $ = (id) => document.getElementById(id);
const STORE = "neu-v6-free-inputs";
const FIELDS = ["server", "sub", "advanced"];
const PLATFORM_NAMES = { mac: "macOS（sing-box App）", windows: "Windows（安装包）", android: "Android", ios: "iOS" };

let parsed = null; // { settings, proxies }
let choices = {}; // 分组名 → 用户选的默认出口

// ---------- 输入 ----------
function readYaml(id, label) {
  const text = $(id).value.trim();
  if (!text) return {};
  let v;
  try { v = yaml.load(text); } catch (e) { throw new Error(`「${label}」不是合法的 YAML：${e.message.split("\n")[0]}`); }
  if (v == null) return {};
  if (Array.isArray(v)) return { nodes: v }; // 直接贴了一串节点
  if (typeof v !== "object") throw new Error(`「${label}」格式不对：应为 YAML 对象`);
  return v;
}

function parseInputs() {
  const mode = document.querySelector("input[name=mode]:checked").value;
  const server = mode === "tunnel" ? readYaml("server", "服务器脚本输出") : {};
  const sub = readYaml("sub", "订阅内容");
  const adv = readYaml("advanced", "高级设置");
  if (mode === "tunnel" && !server.entry_servers) throw new Error("模式二需要粘贴服务器脚本（setup.sh）输出的那段设置，里面应有 entry_servers");
  const { proxies: subProxies = [], ...subRest } = sub;
  if (Object.keys(subRest).length && !subProxies.length && !sub.nodes) {
    throw new Error("订阅内容里没找到 proxies。请用 Clash / mihomo 格式的订阅（订阅转换时选 Clash）");
  }
  const settings = { ...server, ...adv };
  const proxies = [...subProxies, ...(sub.nodes || []), ...(server.nodes || []), ...(adv.nodes || [])];
  settings.clash_api_secret ||= randomSecret();
  return { settings, proxies, mode };
}

function randomSecret() {
  const b = new Uint8Array(18);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/[+/=]/g, "");
}

// ---------- 分组选择 ----------
function renderGroups() {
  // 用 mac 生成分组列表：它的按 App 分组最全（其他平台没有的分组，选了也会被忽略）
  const { config, panel, warnings, mode } = build({ ...withChoices(), mac_app: true }, parsed.proxies, "mac");
  entryNotes = Object.fromEntries(Object.entries(panel.node_notes).filter(([, n]) => n.startsWith("校园网 IPv6 连到")));
  const sel = Object.fromEntries(config.outbounds.filter((o) => o.type === "selector").map((o) => [o.tag, o]));
  const box = $("groups");
  box.innerHTML = "";
  const base = [ENTRY, CN4, ABROAD];
  const names = [...base, ...panel.groups.map((g) => g.name).filter((n) => !base.includes(n))];
  for (const name of names) {
    const s = sel[name];
    if (!s) continue;
    const desc = panel.groups.find((g) => g.name === name)?.desc || "";
    const row = document.createElement("label");
    row.className = "group";
    row.innerHTML = `<span class="gname"></span><select></select><small></small>`;
    row.querySelector(".gname").textContent = name;
    row.querySelector("small").textContent = desc;
    const select = row.querySelector("select");
    for (const opt of s.outbounds) select.add(new Option(opt, opt, false, opt === s.default));
    select.addEventListener("change", () => { choices[name] = select.value; refresh(); });
    box.append(row);
  }
  $("warnings").textContent = warnings.join("\n");
  $("summary").textContent = mode === "tunnel"
    ? `模式二·自带服务器：${panel.node_notes ? Object.values(panel.node_notes).filter((n) => n.startsWith("校园网 IPv6 连到")).length : 0} 个服务器入口，${countNodes(config)} 个落地节点（各有「经服务器」与「直连 v4」两个版本）`
    : `模式一·v6 优先直连：${countNodes(config)} 个订阅节点${countNodes(config) ? "" : "（全部直连）"}`;
}

// 订阅/自填节点数：不算服务器入口和「（直连 v4）」副本
const countNodes = (cfg) => cfg.outbounds.filter((o) => !["selector", "urltest", "direct"].includes(o.type)
  && !(o.tag.endsWith("（直连 v4）") && cfg.outbounds.some((x) => x.tag === o.tag.replace("（直连 v4）", "（经服务器）")))
  && !Object.keys(entryNotes).includes(o.tag)).length;
let entryNotes = {};

/** 用户在页面上选的默认出口 → group_defaults（三个总开关也走这里） */
function withChoices() {
  return { ...parsed.settings, group_defaults: { ...(parsed.settings.group_defaults || {}), ...choices } };
}

// ---------- 生成与下载 ----------
function refresh() {
  try {
    renderGroups();
    $("error").textContent = "";
  } catch (e) {
    $("error").textContent = e.message;
  }
}

function download(name, blob) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

let panelHtml = null;
async function getPanelHtml() {
  panelHtml ??= await (await fetch("../panel/index.html")).text();
  return panelHtml;
}

// Windows 脚本按字节取：它们带 UTF-8 BOM（Windows 自带的 PowerShell 5.1 靠它识别中文），按文本读会丢掉
const WINDOWS_SCRIPTS = ["install.ps1", "update.ps1", "uninstall.ps1", "helper.ps1"];
let windowsScripts = null;

// 规则集从 GitHub 下载（raw.githubusercontent.com 允许跨域），装进 zip 的 rules/
async function getRuleSets(settings) {
  const base = settings.rule_set_base || DEFAULTS.rule_set_base;
  const refs = ruleSetRefs("windows", settings);
  const out = [];
  for (const [i, ref] of refs.entries()) {
    $("secret").textContent = `正在下载规则集 ${i + 1} / ${refs.length}……`;
    const r = await fetch(ruleSetUrl(base, ref));
    if (!r.ok) throw new Error(`规则集下载失败：${ref}（HTTP ${r.status}）`);
    out.push({ name: `neu-v6-free/rules/${rsTag(ref)}.srs`, data: new Uint8Array(await r.arrayBuffer()) });
  }
  return out;
}
async function getWindowsScripts() {
  windowsScripts ??= await Promise.all(WINDOWS_SCRIPTS.map(async (n) => ({
    name: `neu-v6-free/${n}`, data: new Uint8Array(await (await fetch(`../windows/${n}`)).arrayBuffer()) })));
  return windowsScripts;
}

async function generate(platform) {
  const settings = withChoices();
  if (platform === "mac") settings.mac_app = true;
  const { config, panel } = build(settings, parsed.proxies, platform);
  const json = JSON.stringify(config, null, 2);
  if (platform === "windows") {
    const zip = makeZip([
      { name: "neu-v6-free/config.json", data: json },
      { name: "neu-v6-free/panel/index.html", data: await getPanelHtml() },
      { name: "neu-v6-free/panel/groups.json", data: JSON.stringify(panel, null, 1) },
      // 本地规则集：Windows 版启动不依赖网络（服务器不通时也能起来）
      ...await getRuleSets(settings),
      // 「我的规则」的空文件：install.ps1 只补缺的，不覆盖已有规则
      ...config.route.rule_set.filter((r) => r.tag.startsWith("user-"))
        .map((r) => ({ name: `neu-v6-free/rules/${r.tag}.json`, data: '{"version":2,"rules":[]}\n' })),
      ...await getWindowsScripts(),
    ]);
    download("neu-v6-free-windows.zip", zip);
    $("secret").textContent = `Windows 面板密钥：${settings.clash_api_secret}（面板 http://127.0.0.1:9090/ui 登录用，也在 config.json 里）`;
  } else {
    download(`neu-v6-free-${platform}.json`, new Blob([json], { type: "application/json" }));
  }
  return json;
}

// ---------- 记住输入（默认关闭，只存本浏览器） ----------
function loadSaved() {
  try {
    const v = JSON.parse(localStorage.getItem(STORE) || "null");
    if (!v) return;
    $("remember").checked = true;
    for (const f of FIELDS) $(f).value = v[f] || "";
    if (v.mode) document.querySelector(`input[name=mode][value=${v.mode}]`).checked = true;
  } catch { /* 隐私模式等情况下不可用，忽略 */ }
}

function save() {
  try {
    if (!$("remember").checked) { localStorage.removeItem(STORE); return; }
    const v = Object.fromEntries(FIELDS.map((f) => [f, $(f).value]));
    v.mode = document.querySelector("input[name=mode]:checked").value;
    localStorage.setItem(STORE, JSON.stringify(v));
  } catch { /* 忽略 */ }
}

function syncMode() {
  const tunnel = document.querySelector("input[name=mode]:checked").value === "tunnel";
  $("server-box").hidden = !tunnel;
}

$("parse").addEventListener("click", () => {
  try {
    parsed = parseInputs();
    choices = {};
    save();
    renderGroups();
    $("error").textContent = "";
    $("step2").hidden = false;
    $("step3").hidden = false;
    $("step2").scrollIntoView({ behavior: "smooth" });
  } catch (e) {
    $("error").textContent = e.message;
    $("step2").hidden = true;
    $("step3").hidden = true;
  }
});
for (const r of document.querySelectorAll("input[name=mode]")) r.addEventListener("change", syncMode);
$("remember").addEventListener("change", save);
for (const p of Object.keys(PLATFORM_NAMES)) {
  const b = document.createElement("button");
  b.textContent = `下载 ${PLATFORM_NAMES[p]}`;
  b.addEventListener("click", () => generate(p).catch((e) => { $("error").textContent = e.message; }));
  $("downloads").append(b);
}
loadSaved();
syncMode();

// 供自动化测试：window.neuV6.configFor("android") 返回与下载内容相同的配置文本（不触发下载）
window.neuV6 = {
  configFor(platform) {
    const s = withChoices();
    if (platform === "mac") s.mac_app = true;
    return JSON.stringify(build(s, parsed.proxies, platform).config, null, 2);
  },
  choose(group, value) { choices[group] = value; refresh(); },
};
