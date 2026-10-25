// 订阅 / 节点链接 → mihomo（Clash Meta）格式的节点列表。浏览器与 Node 共用，不做网络操作。
//
// 认得的格式：
//   Clash / mihomo 配置（YAML 或 JSON，取 proxies）
//   sing-box 配置（取 outbounds 里的代理出站，原样使用）
//   节点链接：一行一个，或整体 base64（v2rayN 等订阅）。vless / vmess / trojan / ss / hysteria2(hy2) / tuic / anytls
import yaml from "./js-yaml.mjs";

const SINGBOX_PROXY_TYPES = new Set([
  "vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "tuic", "anytls", "wireguard", "ssh", "shadowtls", "socks", "http", "naive",
]);

function b64decode(s) {
  s = s.trim().replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

const isB64 = (s) => /^[A-Za-z0-9+/=_\-\s]+$/.test(s) && s.replace(/\s/g, "").length >= 8;
const bool = (v) => v === "1" || v === "true";
const list = (v) => (v ? v.split(",").map((x) => x.trim()).filter(Boolean) : undefined);
const clean = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== "" && v !== null));

/** host:port（含 [v6]:port）与 URL 查询参数 */
function parseUrl(link) {
  const u = new URL(link.replace(/^[a-z0-9]+:\/\//i, "http://"));
  const q = Object.fromEntries(u.searchParams);
  return {
    user: decodeURIComponent(u.username), pass: decodeURIComponent(u.password),
    server: u.hostname.replace(/^\[|\]$/g, ""), port: parseInt(u.port || "443", 10), q,
    name: decodeURIComponent(u.hash.replace(/^#/, "")),
  };
}

/** vless / trojan 共用：tls、reality、传输层 */
function v2Common(q, p) {
  const sec = q.security;
  if (sec === "tls" || sec === "reality" || p.type === "trojan") {
    if (p.type !== "trojan") p.tls = true;
    const sni = q.sni || q.peer;
    if (p.type === "trojan") p.sni = sni; else p.servername = sni;
    if (q.fp) p["client-fingerprint"] = q.fp;
    if (q.alpn) p.alpn = list(q.alpn);
    if (bool(q.allowInsecure) || bool(q.insecure)) p["skip-cert-verify"] = true;
    if (sec === "reality") p["reality-opts"] = { "public-key": q.pbk, "short-id": q.sid ?? "" };
  }
  const net = q.type || "tcp";
  if (net === "ws" || net === "httpupgrade") {
    p.network = "ws";
    p["ws-opts"] = clean({ path: q.path || "/", headers: q.host ? { Host: q.host } : undefined,
      "v2ray-http-upgrade": net === "httpupgrade" || undefined });
  } else if (net === "grpc") {
    p.network = "grpc";
    p["grpc-opts"] = { "grpc-service-name": q.serviceName || q.path || "" };
  } else if (net !== "tcp") {
    p.network = net; // 不支持的传输层，convert 会跳过并提示
  }
  return p;
}

const PARSERS = {
  vless(link) {
    const { user, server, port, q, name } = parseUrl(link);
    return v2Common(q, clean({ name, type: "vless", server, port, uuid: user, flow: q.flow, udp: true }));
  },
  trojan(link) {
    const { user, server, port, q, name } = parseUrl(link);
    return v2Common(q, clean({ name, type: "trojan", server, port, password: user, udp: true }));
  },
  vmess(link) {
    const body = link.slice("vmess://".length).split("#")[0];
    const j = JSON.parse(b64decode(body));
    const p = clean({ name: j.ps, type: "vmess", server: j.add, port: parseInt(j.port, 10), uuid: j.id,
      alterId: parseInt(j.aid || 0, 10), cipher: j.scy || "auto", udp: true });
    if (j.tls === "tls") {
      p.tls = true;
      if (j.sni || j.host) p.servername = j.sni || j.host;
      if (j.fp) p["client-fingerprint"] = j.fp;
      if (j.alpn) p.alpn = list(j.alpn);
    }
    if (j.net === "ws" || j.net === "httpupgrade") {
      p.network = "ws";
      p["ws-opts"] = clean({ path: j.path || "/", headers: j.host ? { Host: j.host } : undefined,
        "v2ray-http-upgrade": j.net === "httpupgrade" || undefined });
    } else if (j.net === "grpc") {
      p.network = "grpc";
      p["grpc-opts"] = { "grpc-service-name": j.path || "" };
    } else if (j.net && j.net !== "tcp") p.network = j.net;
    return p;
  },
  ss(link) {
    let rest = link.slice("ss://".length);
    let name = "";
    const hash = rest.indexOf("#");
    if (hash >= 0) { name = decodeURIComponent(rest.slice(hash + 1)); rest = rest.slice(0, hash); }
    let query = "";
    const qi = rest.indexOf("?");
    if (qi >= 0) { query = rest.slice(qi + 1); rest = rest.slice(0, qi); }
    rest = rest.replace(/\/$/, "");
    let userinfo, hostport;
    if (rest.includes("@")) {
      [userinfo, hostport] = [rest.slice(0, rest.lastIndexOf("@")), rest.slice(rest.lastIndexOf("@") + 1)];
      userinfo = decodeURIComponent(userinfo);
      if (!userinfo.includes(":")) userinfo = b64decode(userinfo); // SIP002：base64(method:password)
    } else { // 老格式：整体 base64(method:password@host:port)
      const all = b64decode(rest);
      [userinfo, hostport] = [all.slice(0, all.lastIndexOf("@")), all.slice(all.lastIndexOf("@") + 1)];
    }
    const ci = userinfo.indexOf(":");
    const m = hostport.match(/^\[?([^\]]+?)\]?:(\d+)$/);
    if (!m) throw new Error("地址格式不对");
    const p = { name, type: "ss", server: m[1], port: parseInt(m[2], 10), cipher: userinfo.slice(0, ci), password: userinfo.slice(ci + 1), udp: true };
    const plugin = new URLSearchParams(query).get("plugin");
    if (plugin) {
      const [pn, ...opts] = plugin.split(";");
      const kv = Object.fromEntries(opts.map((x) => { const i = x.indexOf("="); return i < 0 ? [x, true] : [x.slice(0, i), x.slice(i + 1)]; }));
      if (pn === "obfs-local" || pn === "simple-obfs") { p.plugin = "obfs"; p["plugin-opts"] = clean({ mode: kv.obfs, host: kv["obfs-host"] }); }
      else if (pn === "v2ray-plugin") { p.plugin = "v2ray-plugin"; p["plugin-opts"] = clean({ mode: "websocket", host: kv.host, path: kv.path, tls: kv.tls === true || undefined }); }
      else p.plugin = pn;
    }
    return p;
  },
  hysteria2(link) {
    const { user, pass, server, port, q, name } = parseUrl(link);
    return clean({ name, type: "hysteria2", server, port, password: pass ? `${user}:${pass}` : user,
      sni: q.sni, "skip-cert-verify": bool(q.insecure) || undefined, alpn: list(q.alpn),
      obfs: q.obfs, "obfs-password": q["obfs-password"] });
  },
  tuic(link) {
    const { user, pass, server, port, q, name } = parseUrl(link);
    return clean({ name, type: "tuic", server, port, uuid: user, password: pass, sni: q.sni,
      "congestion-controller": q.congestion_control, "udp-relay-mode": q.udp_relay_mode, alpn: list(q.alpn),
      "skip-cert-verify": bool(q.allow_insecure) || bool(q.insecure) || undefined });
  },
  anytls(link) {
    const { user, server, port, q, name } = parseUrl(link);
    return clean({ name, type: "anytls", server, port, password: user, sni: q.sni,
      "skip-cert-verify": bool(q.insecure) || undefined, alpn: list(q.alpn) });
  },
};
PARSERS.hy2 = PARSERS.hysteria2;

/** 一个节点链接 → mihomo 节点；认不出的抛错。 */
export function parseLink(link) {
  const scheme = link.match(/^([a-z0-9]+):\/\//i)?.[1]?.toLowerCase();
  const fn = scheme && PARSERS[scheme];
  if (!fn) throw new Error(`不认识的链接类型：${scheme || link.slice(0, 20)}`);
  const p = fn(link.trim());
  if (!p.server || !p.port) throw new Error("缺少地址或端口");
  if (!p.name) p.name = `${p.type} ${p.server}:${p.port}`;
  return p;
}

function fromLines(text) {
  const proxies = [], errors = [];
  for (const line of text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)) {
    if (!/^[a-z0-9]+:\/\//i.test(line)) continue;
    try { proxies.push(parseLink(line)); } catch (e) { errors.push(`${line.slice(0, 40)}…：${e.message}`); }
  }
  return { proxies, errors };
}

/**
 * 订阅内容（或粘贴的文本）→ { proxies, format, errors }。
 * proxies 是 mihomo 格式；sing-box 订阅里的出站包成 { type: "_singbox", name, outbound }。
 */
export function parseSubscription(text) {
  text = String(text ?? "").replace(/^﻿/, "").trim();
  if (!text) return { proxies: [], format: "空", errors: ["内容是空的"] };
  // sing-box 或 Clash 的 JSON
  if (text.startsWith("{")) {
    try {
      const j = JSON.parse(text);
      if (Array.isArray(j.outbounds)) {
        const proxies = j.outbounds.filter((o) => SINGBOX_PROXY_TYPES.has(o.type) && o.tag)
          .map((o) => ({ type: "_singbox", name: o.tag, server: o.server, port: o.server_port, outbound: o }));
        return { proxies, format: "sing-box", errors: [] };
      }
      if (Array.isArray(j.proxies)) return { proxies: j.proxies, format: "Clash", errors: [] };
    } catch { /* 不是 JSON，往下试 */ }
  }
  // 节点链接（明文）
  if (/^[a-z0-9]+:\/\//im.test(text)) {
    const r = fromLines(text);
    return { ...r, format: "节点链接" };
  }
  // Clash / mihomo YAML；也认 server/setup.sh 输出的那段（nodes + entry_servers，带出 settings）
  if (/^\s*(proxies|nodes)\s*:/m.test(text)) {
    let doc;
    try { doc = yaml.load(text); } catch (e) { return { proxies: [], format: "Clash", errors: [`YAML 格式不对：${e.message}`] }; }
    const list = Array.isArray(doc?.proxies) ? doc.proxies : Array.isArray(doc?.nodes) ? doc.nodes : [];
    const settings = {};
    if (doc?.entry_servers && typeof doc.entry_servers === "object") settings.entry_servers = doc.entry_servers;
    if (doc?.entry_default) settings.entry_default = doc.entry_default;
    return { proxies: list, format: "Clash", errors: [], ...(Object.keys(settings).length ? { settings } : {}) };
  }
  // base64 包着的节点链接
  if (isB64(text)) {
    let decoded = "";
    try { decoded = b64decode(text); } catch { /* 不是 base64 */ }
    if (/^[a-z0-9]+:\/\//im.test(decoded)) return { ...fromLines(decoded), format: "节点链接（base64）" };
  }
  return { proxies: [], format: "未知", errors: ["认不出这是什么格式：支持 Clash / mihomo 配置、sing-box 配置、节点链接（可以 base64）"] };
}

/** subscription-userinfo 响应头 → { upload, download, total, expire }（字节、秒） */
export function parseUserinfo(h) {
  if (!h) return null;
  const o = {};
  for (const part of h.split(";")) {
    const [k, v] = part.split("=").map((x) => x?.trim());
    if (["upload", "download", "total", "expire"].includes(k) && /^\d+$/.test(v || "")) o[k] = Number(v);
  }
  return Object.keys(o).length ? o : null;
}

// 机场常把「剩余流量」「到期时间」「官网」写成节点名放进订阅：默认排除（每个订阅可以改）
export const DEFAULT_EXCLUDE = "剩余|到期|过期|官网|套餐|重置|网址|expire|traffic";

/**
 * 客户端的设置 → build() 用的节点列表：各订阅（启用的）+ 手动节点。
 * 订阅节点带上 _sub（订阅名），生成器据此给每个订阅建一个分组（订阅设了 group: false 就不建）；
 * 名字匹配 exclude（正则，默认 DEFAULT_EXCLUDE）的不要；重名的节点加上「 · 订阅名」区分。
 */
export function collectProxies(profile) {
  const out = [], seen = new Set();
  const add = (p, sub) => {
    let name = String(p.name ?? "").trim() || `${p.type} ${p.server}:${p.port}`;
    if (seen.has(name)) name = `${name} · ${sub || "手动"}`;
    for (let i = 2; seen.has(name); i++) name = `${name} ${i}`;
    seen.add(name);
    out.push({ ...p, name, ...(sub ? { _sub: sub } : {}) });
  };
  for (const s of profile.subscriptions || []) {
    if (s.enabled === false) continue;
    let ex = null;
    try { ex = (s.exclude ?? DEFAULT_EXCLUDE) ? new RegExp(s.exclude ?? DEFAULT_EXCLUDE, "i") : null; } catch { /* 写错的正则当没写 */ }
    for (const p of s.proxies || []) if (!ex || !ex.test(String(p.name ?? ""))) add(p, s.group === false ? null : s.name);
  }
  for (const p of profile.nodes || []) add(p, null);
  return out;
}
