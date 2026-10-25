// mihomo（Clash Meta）节点 → sing-box outbound。浏览器与 Node 共用，不依赖任何运行时 API。
// 节点链接（vless:// 等）和 sing-box 订阅先由 subscription.js 转成 mihomo 格式，再走这里。

function tlsBlock(p, { sniKey = "servername", reality = false } = {}) {
  const tls = { enabled: true };
  const sni = p[sniKey] || p.sni || p.servername;
  if (sni) tls.server_name = sni;
  if (p["skip-cert-verify"]) tls.insecure = true;
  if (p.alpn) tls.alpn = [].concat(p.alpn);
  if (p["client-fingerprint"]) tls.utls = { enabled: true, fingerprint: p["client-fingerprint"] };
  if (reality) {
    const ro = p["reality-opts"];
    tls.reality = { enabled: true, public_key: ro["public-key"], short_id: ro["short-id"] ?? "" };
    delete tls.insecure;
  }
  return tls;
}

/** 传输层：ws / http-upgrade / grpc；tcp（或没写）返回 null。不支持的返回 false。 */
function transport(p) {
  const n = p.network;
  if (!n || n === "tcp") return null;
  if (n === "ws") {
    const wo = p["ws-opts"] || {};
    const t = { type: wo["v2ray-http-upgrade"] ? "httpupgrade" : "ws", path: wo.path ?? "/" };
    if (t.type === "ws" && wo.headers) t.headers = wo.headers;
    if (t.type === "httpupgrade" && wo.headers?.Host) t.host = wo.headers.Host;
    if (t.type === "ws" && wo["max-early-data"]) {
      t.max_early_data = wo["max-early-data"];
      t.early_data_header_name = wo["early-data-header-name"] || "Sec-WebSocket-Protocol";
    }
    return t;
  }
  if (n === "grpc") return { type: "grpc", service_name: p["grpc-opts"]?.["grpc-service-name"] ?? "" };
  return false;
}

function ssPlugin(o, p) {
  if (!p.plugin) return true;
  const po = p["plugin-opts"] || {};
  if (p.plugin === "obfs") {
    o.plugin = "obfs-local";
    o.plugin_opts = [`obfs=${po.mode || "http"}`, po.host && `obfs-host=${po.host}`].filter(Boolean).join(";");
    return true;
  }
  if (p.plugin === "v2ray-plugin") {
    o.plugin = "v2ray-plugin";
    o.plugin_opts = ["mode=websocket", po.tls && "tls", po.host && `host=${po.host}`, po.path && `path=${po.path}`].filter(Boolean).join(";");
    return true;
  }
  return false;
}

/** 不支持的类型（或不支持的传输层、插件）返回 null。 */
export function convert(p) {
  const t = p.type;
  if (t === "_singbox") return { ...JSON.parse(JSON.stringify(p.outbound)), tag: p.name }; // sing-box 订阅里的出站，原样用
  const o = { type: t, tag: p.name, server: p.server, server_port: parseInt(p.port, 10) };
  const tr = transport(p);
  if (tr === false) return null;
  if (t === "vless") {
    o.uuid = p.uuid;
    if (p.flow) o.flow = p.flow;
    if (p.tls) o.tls = tlsBlock(p, { reality: "reality-opts" in p });
    o.packet_encoding = "xudp";
  } else if (t === "vmess") {
    Object.assign(o, { uuid: p.uuid, security: p.cipher ?? "auto", alter_id: parseInt(p.alterId ?? 0, 10) });
    if (p.tls) o.tls = tlsBlock(p);
  } else if (t === "trojan") {
    o.password = p.password;
    o.tls = tlsBlock(p, { sniKey: "sni", reality: "reality-opts" in p });
  } else if (t === "ss") {
    Object.assign(o, { type: "shadowsocks", method: p.cipher, password: p.password });
    if (!ssPlugin(o, p)) return null;
    if (p["udp-over-tcp"]) o.udp_over_tcp = true;
  } else if (t === "hysteria2") {
    o.password = p.password;
    o.tls = tlsBlock(p, { sniKey: "sni" });
    if (p.obfs) o.obfs = { type: p.obfs, password: p["obfs-password"] ?? "" };
  } else if (t === "tuic") {
    Object.assign(o, {
      uuid: p.uuid, password: p.password,
      congestion_control: p["congestion-controller"] ?? "bbr",
      udp_relay_mode: p["udp-relay-mode"] ?? "native",
    });
    o.tls = tlsBlock(p, { sniKey: "sni" });
  } else if (t === "anytls") {
    o.password = p.password;
    o.tls = tlsBlock(p, { sniKey: "sni" });
  } else {
    return null;
  }
  if (tr) {
    if (!["vless", "vmess", "trojan"].includes(t)) return null;
    o.transport = tr;
  }
  return o;
}
