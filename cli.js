#!/usr/bin/env node
// 命令行生成器。用法：
//   node cli.js -c config.yaml [-c more.yaml ...] [-p mac,windows,android,ios] [-o out] [--sub-file sub.yaml] [--no-tun]
//   node cli.js --package [-o dist]   发布包：起步配置（模式一、没有节点、面板密钥安装时随机生成）+ 安装脚本，打成 zip
// 多个 -c 依次合并（后面的覆盖前面的同名项），方便把「可以入库的设置」和「含密钥的设置」分开放。
// 输出 <out>/<平台>/config.json；mac/windows 另带 panel/（面板）和 rules/（本地规则集与「我的规则」空文件），
// mac 另带 helper.py，windows 另带 install.ps1 / update.ps1 / uninstall.ps1 / helper.ps1。
// mac/windows 还带 profile.json：这些设置的副本，装好后面板里的「订阅与节点」「设置」接着用（含密钥，权限 600）。
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "./lib/js-yaml.mjs";
import { PLATFORMS, build, rsTag, ruleSetRefs, ruleSetUrl, DEFAULTS } from "./lib/build.js";

// 面板在浏览器里生成配置要用的模块，随面板一起装（panel/lib/）
const PANEL_LIB = ["js-yaml.mjs", "groups.js", "convert.js", "subscription.js", "build.js"];

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const EMPTY_RULE_SET = JSON.stringify({ version: 2, rules: [] }) + "\n";

function parseArgs(argv) {
  const a = { configs: [], platforms: ["mac"], out: "out", subFile: null, tun: true, package: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => argv[++i];
    if (k === "-c" || k === "--config") a.configs.push(v());
    else if (k === "-p" || k === "--platform") { const p = v(); a.platforms = p === "all" ? PLATFORMS : p.split(","); }
    else if (k === "-o" || k === "--out") a.out = v();
    else if (k === "--sub-file") a.subFile = v();
    else if (k === "--no-tun") a.tun = false;
    else if (k === "--package") { a.package = true; a.platforms = ["mac", "windows"]; }
    else if (k === "-h" || k === "--help") { console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 5).join("\n")); process.exit(0); }
    else throw new Error(`未知参数 ${k}`);
  }
  if (!a.configs.length && !a.package) a.configs.push("config.yaml");
  return a;
}

async function fetchText(url, ua = "clash.meta") {
  const r = await fetch(url, { headers: { "User-Agent": ua }, signal: AbortSignal.timeout(30000) });
  if (!r.ok) throw new Error(`下载失败 ${r.status}: ${url}`);
  return r.text();
}

/** 规则集下载到 dest；某个失败时保留旧文件，没有旧文件则报错。 */
async function downloadRuleSets(base, dest, settings) {
  fs.mkdirSync(dest, { recursive: true });
  for (const ref of ruleSetRefs("mac", settings)) {
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
  // 发布包：面板密钥留占位符，安装脚本第一次安装时换成随机的（mac/install.sh、windows/install.ps1）
  if (a.package) settings.clash_api_secret = "__NEU_SECRET__";

  const proxies = [];
  let subProxies = null;
  if (a.subFile || settings.subscription_url) {
    const sub = yaml.load(a.subFile ? fs.readFileSync(a.subFile, "utf8") : await fetchText(settings.subscription_url));
    subProxies = sub?.proxies || [];
    proxies.push(...subProxies);
  }
  proxies.push(...(settings.nodes || []));
  // 面板客户端用的设置：订阅不单独成组、不排除节点，生成结果和命令行一样
  const { subscription_url, nodes, ...rest } = settings;
  if (a.package) delete rest.clash_api_secret; // 面板生成配置时总用安装后的密钥
  const profile = {
    version: 1, settings: rest, nodes: nodes || [], pending: false,
    subscriptions: subProxies ? [{ id: "cli", name: "订阅", url: subscription_url || "", enabled: true, group: false, exclude: "",
      format: "Clash", proxies: subProxies, updated: new Date().toISOString() }] : [],
  };

  for (const platform of a.platforms) {
    const { config, panel, warnings, mode } = build(settings, proxies, platform);
    if (platform === a.platforms[0]) warnings.forEach((w) => console.error(`提示：${w}`)); // 各平台相同，只打印一次
    const dir = path.join(a.out, a.package ? `neu-v6-free-${platform}` : platform);
    fs.mkdirSync(dir, { recursive: true });
    const cfgPath = path.join(dir, "config.json");
    fs.writeFileSync(cfgPath, JSON.stringify(config, null, 2));
    fs.chmodSync(cfgPath, 0o600);
    if (platform === "mac" || platform === "windows") {
      const pd = path.join(dir, "panel");
      fs.mkdirSync(pd, { recursive: true });
      fs.copyFileSync(path.join(ROOT, "panel", "index.html"), path.join(pd, "index.html"));
      fs.writeFileSync(path.join(pd, "groups.json"), JSON.stringify(panel, null, 1));
      fs.mkdirSync(path.join(pd, "lib"), { recursive: true });
      for (const f of PANEL_LIB) fs.copyFileSync(path.join(ROOT, "lib", f), path.join(pd, "lib", f));
      const pf = path.join(dir, "profile.json");
      fs.writeFileSync(pf, JSON.stringify(profile));
      fs.chmodSync(pf, 0o600);
    }
    if (platform === "mac" || platform === "windows") {
      await downloadRuleSets(settings.rule_set_base || DEFAULTS.rule_set_base, path.join(dir, "rules"), settings);
    }
    // 「我的规则」的空文件：安装 / 更新脚本只补缺的，不会覆盖已经加过的规则
    const userSets = config.route.rule_set.filter((r) => r.tag.startsWith("user-"));
    if (userSets.length) {
      const rd = path.join(dir, "rules");
      fs.mkdirSync(rd, { recursive: true });
      for (const r of userSets) fs.writeFileSync(path.join(rd, `${r.tag}.json`), EMPTY_RULE_SET);
    }
    // 本地助手（以及 windows 的安装 / 更新 / 卸载脚本）一起放进去：更新时助手顺便升级自己
    if (platform === "mac") fs.copyFileSync(path.join(ROOT, "mac", "helper.py"), path.join(dir, "helper.py"));
    if (platform === "windows") {
      for (const f of fs.readdirSync(path.join(ROOT, "windows"))) fs.copyFileSync(path.join(ROOT, "windows", f), path.join(dir, f));
    }
    if (a.package) packageExtras(platform, dir, a.out);
    const groups = config.outbounds.filter((o) => o.type === "selector").length;
    console.log(`已生成 ${cfgPath}（${mode === "tunnel" ? "模式二·自带服务器" : "模式一·v6 优先直连"}，${config.outbounds.length} 个出站、${groups} 个分组）`);
  }
}

/** 发布包：mac 加上安装 / 卸载脚本和双击用的 .command；打成 zip（文件名带版本号） */
function packageExtras(platform, dir, out) {
  if (platform === "mac") {
    for (const f of ["install.sh", "uninstall.sh", "helper-service.sh"]) {
      fs.copyFileSync(path.join(ROOT, "mac", f), path.join(dir, f));
      fs.chmodSync(path.join(dir, f), 0o755);
    }
    const cmd = (script, what) => `#!/bin/bash\n# 双击运行：${what}（会要求输入开机密码）\ncd "$(dirname "$0")" && sudo ./${script}\necho; read -n 1 -s -r -p "按任意键关闭"\n`;
    fs.writeFileSync(path.join(dir, "安装.command"), cmd("install.sh", "安装或升级"), { mode: 0o755 });
    fs.writeFileSync(path.join(dir, "卸载.command"), cmd("uninstall.sh", "卸载（保留订阅、设置和我的规则）"), { mode: 0o755 });
  }
  if (platform === "android" || platform === "ios") return;
  const version = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;
  const zip = `neu-v6-free-${version}-${platform === "mac" ? "macos" : platform}.zip`;
  fs.rmSync(path.join(out, zip), { force: true });
  execFileSync("zip", ["-qr", "-X", zip, path.basename(dir)], { cwd: out });
  console.log(`已打包 ${path.join(out, zip)}`);
}

main().catch((e) => { console.error(`错误：${e.message}`); process.exit(1); });
