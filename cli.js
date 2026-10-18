#!/usr/bin/env node
// 命令行生成器。用法：
//   node cli.js -c config.yaml [-c more.yaml ...] [-p mac,windows,android,ios] [-o out] [--sub-file sub.yaml] [--no-tun]
// 多个 -c 依次合并（后面的覆盖前面的同名项），方便把「可以入库的设置」和「含密钥的设置」分开放。
// 输出 <out>/<平台>/config.json；mac/windows 另带 panel/（面板），mac 另带 rules/（本地规则集）。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "./lib/js-yaml.mjs";
import { PLATFORMS, build, rsTag, ruleSetRefs, ruleSetUrl, DEFAULTS } from "./lib/build.js";

const ROOT = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const a = { configs: [], platforms: ["mac"], out: "out", subFile: null, tun: true };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => argv[++i];
    if (k === "-c" || k === "--config") a.configs.push(v());
    else if (k === "-p" || k === "--platform") { const p = v(); a.platforms = p === "all" ? PLATFORMS : p.split(","); }
    else if (k === "-o" || k === "--out") a.out = v();
    else if (k === "--sub-file") a.subFile = v();
    else if (k === "--no-tun") a.tun = false;
    else if (k === "-h" || k === "--help") { console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 5).join("\n")); process.exit(0); }
    else throw new Error(`未知参数 ${k}`);
  }
  if (!a.configs.length) a.configs.push("config.yaml");
  return a;
}

async function fetchText(url, ua = "clash.meta") {
  const r = await fetch(url, { headers: { "User-Agent": ua }, signal: AbortSignal.timeout(30000) });
  if (!r.ok) throw new Error(`下载失败 ${r.status}: ${url}`);
  return r.text();
}

/** 规则集下载到 dest；某个失败时保留旧文件，没有旧文件则报错。 */
async function downloadRuleSets(base, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const ref of ruleSetRefs()) {
    const target = path.join(dest, `${rsTag(ref)}.srs`);
    try {
      const r = await fetch(ruleSetUrl(base, ref), { signal: AbortSignal.timeout(60000) });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const buf = Buffer.from(await r.arrayBuffer());
      if (!buf.length) throw new Error("空文件");
      fs.writeFileSync(`${target}.tmp`, buf);
      fs.renameSync(`${target}.tmp`, target);
    } catch (e) {
      if (!fs.existsSync(target)) throw new Error(`规则集下载失败且无旧文件: ${ref}（${e.message}）`);
      console.error(`规则集 ${ref} 下载失败，沿用旧文件（${e.message}）`);
    }
  }
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const settings = {};
  for (const c of a.configs) Object.assign(settings, yaml.load(fs.readFileSync(c, "utf8")) || {});
  if (!a.tun) settings.tun = false;

  const proxies = [];
  if (a.subFile || settings.subscription_url) {
    const sub = yaml.load(a.subFile ? fs.readFileSync(a.subFile, "utf8") : await fetchText(settings.subscription_url));
    proxies.push(...(sub?.proxies || []));
  }
  proxies.push(...(settings.nodes || []));

  for (const platform of a.platforms) {
    const { config, panel, warnings, mode } = build(settings, proxies, platform);
    if (platform === a.platforms[0]) warnings.forEach((w) => console.error(`提示：${w}`)); // 各平台相同，只打印一次
    const dir = path.join(a.out, platform);
    fs.mkdirSync(dir, { recursive: true });
    const cfgPath = path.join(dir, "config.json");
    fs.writeFileSync(cfgPath, JSON.stringify(config, null, 2));
    fs.chmodSync(cfgPath, 0o600);
    if (platform === "mac" || platform === "windows") {
      const pd = path.join(dir, "panel");
      fs.mkdirSync(pd, { recursive: true });
      fs.copyFileSync(path.join(ROOT, "panel", "index.html"), path.join(pd, "index.html"));
      fs.writeFileSync(path.join(pd, "groups.json"), JSON.stringify(panel, null, 1));
    }
    if (platform === "mac") await downloadRuleSets(settings.rule_set_base || DEFAULTS.rule_set_base, path.join(dir, "rules"));
    const groups = config.outbounds.filter((o) => o.type === "selector").length;
    console.log(`已生成 ${cfgPath}（${mode === "tunnel" ? "模式二·自带服务器" : "模式一·v6 优先直连"}，${config.outbounds.length} 个出站、${groups} 个分组）`);
  }
}

main().catch((e) => { console.error(`错误：${e.message}`); process.exit(1); });
