// mihomo（Clash Meta）节点 → sing-box outbound。浏览器与 Node 共用，不依赖任何运行时 API。

function tlsBlock(p, { sniKey = "servername", reality = false } = {}) {
  const tls = { enabled: true };
  const sni = p[sniKey] || p.sni || p.servername;
  if (sni) tls.server_name = sni;
  if (p["skip-cert-verify"]) tls.insecure = true;
  if (p.alpn) tls.alpn = p.alpn;
  if (p["client-fingerprint"]) tls.utls = { enabled: true, fingerprint: p["client-fingerprint"] };
  if (reality) {
    const ro = p["reality-opts"];
    tls.reality = { enabled: true, public_key: ro["public-key"], short_id: ro["short-id"] ?? "" };
    delete tls.insecure;
  }
  return tls;
}

function wsTransport(p) {
  const wo = p["ws-opts"] || {};
  const t = { type: "ws", path: wo.path ?? "/" };
  if (wo.headers) t.headers = wo.headers;
  return t;
}

/** 不支持的类型返回 null。 */
export function convert(p) {
  const t = p.type;
  const o = { type: t, tag: p.name, server: p.server, server_port: parseInt(p.port, 10) };
  if (t === "vless") {
    o.uuid = p.uuid;
    if (p.flow) o.flow = p.flow;
    if (p.tls) o.tls = tlsBlock(p, { reality: "reality-opts" in p });
    if (p.network === "ws") o.transport = wsTransport(p);
    o.packet_encoding = "xudp";
  } else if (t === "vmess") {
    Object.assign(o, { uuid: p.uuid, security: p.cipher ?? "auto", alter_id: parseInt(p.alterId ?? 0, 10) });
    if (p.tls) o.tls = tlsBlock(p);
    if (p.network === "ws") o.transport = wsTransport(p);
  } else if (t === "hysteria2") {
    o.password = p.password;
    o.tls = tlsBlock(p, { sniKey: "sni" });
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
  return o;
}
