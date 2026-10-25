#!/usr/bin/env node
// 命令行生成器。用法：
//   node cli.js -c config.yaml [-c more.yaml ...] [-p mac,windows,android,ios] [-o out] [--sub-file sub.yaml] [--no-tun]
//   node cli.js --package [-o dist]   发布包：起步配置（模式一、没有节点、面板密钥安装时随机生成）+ 安装脚本；
//                                     出 zip（自动更新用）、mac 的 .pkg 和 windows 的 setup.exe（自带 sing-box）、SHA256SUMS
// 多个 -c 依次合并（后面的覆盖前面的同名项），方便把「可以入库的设置」和「含密钥的设置」分开放。
// 输出 <out>/<平台>/config.json；mac/windows 另带 panel/（面板）和 rules/（本地规则集与「我的规则」空文件），
// mac/windows 另带本地助手兼安装程序 neu-v6-free（helper/，Go 写的，不依赖任何东西），windows 另带 install.bat / update.bat / uninstall.bat。
// mac/windows 还带 profile.json：这些设置的副本，装好后面板里的「订阅与节点」「设置」接着用（含密钥，权限 600）。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "./lib/js-yaml.mjs";
import { PLATFORMS, build, rsTag, ruleSetRefs, ruleSetUrl, DEFAULTS } from "./lib/build.js";

// 面板在浏览器里生成配置要用的模块，随面板一起装（panel/lib/）
const PANEL_LIB = ["js-yaml.mjs", "groups.js", "convert.js", "subscription.js", "build.js"];

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const VERSION = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;
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
  // 发布包：面板密钥留占位符，第一次安装时换成随机的（neu-v6-free install）
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
    // 本地助手兼安装程序一起放进去：安装用它，更新时助手顺便升级自己
    if (platform === "mac" || platform === "windows") {
      const bin = helperBinary(platform, a.out);
      if (bin) {
        const dest = path.join(dir, platform === "windows" ? "neu-v6-free.exe" : "neu-v6-free");
        fs.copyFileSync(bin, dest);
        fs.chmodSync(dest, 0o755);
      }
      for (const f of ["helper.py", "install.sh", "uninstall.sh", "helper-service.sh", "install.ps1", "update.ps1", "uninstall.ps1", "helper.ps1"]) {
        fs.rmSync(path.join(dir, f), { force: true });  // 以前的版本生成的
      }
    }
    // 版本号：装到安装目录，本地助手据此判断 GitHub 上有没有新版本
    if (platform === "mac" || platform === "windows") fs.writeFileSync(path.join(dir, "VERSION"), VERSION + "\n");
    if (platform === "windows") {
      // 双击用的小脚本；发布包不带 update.bat（起步配置不用「更新」，订阅在面板里加）
      for (const f of ["install.bat", "uninstall.bat", ...(a.package ? [] : ["update.bat"])]) {
        fs.copyFileSync(path.join(ROOT, "windows", f), path.join(dir, f));
      }
    }
    if (a.package) await packageExtras(platform, dir, a.out);
    const groups = config.outbounds.filter((o) => o.type === "selector").length;
    console.log(`已生成 ${cfgPath}（${mode === "tunnel" ? "模式二·自带服务器" : "模式一·v6 优先直连"}，${config.outbounds.length} 个出站、${groups} 个分组）`);
  }
}

// 安装程序里自带的 sing-box：固定用测试过的版本（新的大版本常常改配置格式）。
// 本地助手（helper/install.go 的 singBoxVersionPinned）找不到 sing-box 时下载的也是这个版本，改的时候两处一起改
const SINGBOX_VERSION = "1.13.21";

/** 下载 sing-box 官方发布到缓存目录（<out>/.cache），返回解压出的可执行文件路径 */
async function singBox(out, target) {
  const cache = path.join(out, ".cache", `sing-box-${SINGBOX_VERSION}-${target}`);
  const exe = path.join(cache, target.startsWith("windows") ? "sing-box.exe" : "sing-box");
  if (fs.existsSync(exe)) return exe;
  fs.mkdirSync(cache, { recursive: true });
  const name = `sing-box-${SINGBOX_VERSION}-${target}.${target.startsWith("windows") ? "zip" : "tar.gz"}`;
  const url = `https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${name}`;
  console.log(`下载 ${name}……`);
  const r = await fetch(url, { signal: AbortSignal.timeout(600000) });
  if (!r.ok) throw new Error(`下载 sing-box 失败 ${r.status}: ${url}`);
  const archive = path.join(cache, name);
  fs.writeFileSync(archive, Buffer.from(await r.arrayBuffer()));
  execFileSync("tar", ["-xf", archive, "-C", cache, "--strip-components", "1"]);  // bsdtar 也能解 zip
  if (!fs.existsSync(exe)) throw new Error(`${name} 里没有找到 sing-box`);
  return exe;
}

async function singBoxLicense(out) {
  const f = path.join(out, ".cache", `sing-box-${SINGBOX_VERSION}-LICENSE.txt`);
  if (!fs.existsSync(f)) {
    fs.mkdirSync(path.dirname(f), { recursive: true });
    const r = await fetch(`https://raw.githubusercontent.com/SagerNet/sing-box/v${SINGBOX_VERSION}/LICENSE`, { signal: AbortSignal.timeout(60000) });
    if (!r.ok) throw new Error(`下载 sing-box 许可证失败 ${r.status}`);
    // GPL 要求随程序附上许可证全文：sing-box 仓库里的 LICENSE 只是声明，再附 GPLv3 全文（licenses/GPL-3.0.txt，取自 SPDX）
    const gpl = fs.readFileSync(path.join(ROOT, "licenses", "GPL-3.0.txt"), "utf8");
    fs.writeFileSync(f, `本安装程序自带 sing-box ${SINGBOX_VERSION}（https://github.com/SagerNet/sing-box），以 GPLv3 发布，源代码见上面的网址。\n\n`
      + await r.text() + "\n\n" + "=".repeat(70) + "\n\n" + gpl);
  }
  return f;
}

/** SHA256SUMS：和安装包一起上传到 Release；本地助手自动更新时据此校验下载的包 */
function addSum(out, file) {
  const sums = path.join(out, "SHA256SUMS");
  const hash = createHash("sha256").update(fs.readFileSync(path.join(out, file))).digest("hex");
  const lines = (fs.existsSync(sums) ? fs.readFileSync(sums, "utf8").split("\n") : []).filter((l) => l && !l.endsWith(`  ${file}`));
  fs.writeFileSync(sums, [...lines, `${hash}  ${file}`].join("\n") + "\n");
}

const APP_NAME = "校园网 v6 免流.app";

/**
 * 本地助手兼安装程序（helper/，Go）：mac 是 arm64 + x86_64 通用二进制，windows 是 x64（ARM64 的 Windows 能模拟运行 x64）。
 * 有 go 就在本机编（几秒钟）；没有就按当前提交下载 GitHub Actions 编好的（.github/workflows/windows-app.yml）。
 * 都拿不到时返回 null：生成目录里不带它，已经装好的可以用安装目录里的 neu-v6-free apply 更新。
 */
const helperBuilt = {};
function helperBinary(platform, out) {
  if (platform in helperBuilt) return helperBuilt[platform];
  const cache = path.join(out, ".cache");
  fs.mkdirSync(cache, { recursive: true });
  const name = platform === "windows" ? "neu-v6-free-windows-amd64.exe" : "neu-v6-free-mac";
  let result = null;
  try {
    execFileSync("go", ["version"], { stdio: "ignore" });
    const build = (goos, goarch, o) => execFileSync("go", ["build", "-trimpath", "-ldflags", `-s -w -X main.version=${VERSION}`, "-o", path.resolve(o), "./helper"],
      { cwd: ROOT, env: { ...process.env, GOOS: goos, GOARCH: goarch, CGO_ENABLED: "0" }, stdio: ["ignore", "inherit", "inherit"] });
    if (platform === "windows") build("windows", "amd64", path.join(cache, name));
    else {
      build("darwin", "arm64", path.join(cache, "neu-v6-free-darwin-arm64"));
      build("darwin", "amd64", path.join(cache, "neu-v6-free-darwin-amd64"));
      execFileSync("lipo", ["-create", path.join(cache, "neu-v6-free-darwin-arm64"), path.join(cache, "neu-v6-free-darwin-amd64"), "-output", path.join(cache, name)]);
    }
    result = path.join(cache, name);
  } catch (e) {
    if (e.code !== "ENOENT") throw e;  // go 报编译错误时直接停下
    const dir = ciArtifact("neu-v6-free-helper", out);
    if (dir && platform === "windows") result = path.join(dir, "neu-v6-free-windows-amd64.exe");
    if (dir && platform === "mac") {
      try {
        execFileSync("lipo", ["-create", path.join(dir, "neu-v6-free-darwin-arm64"), path.join(dir, "neu-v6-free-darwin-amd64"), "-output", path.join(cache, name)]);
        result = path.join(cache, name);
      } catch { result = null; }
    }
    if (!result || !fs.existsSync(result)) {
      console.error("提示：没有 go（https://go.dev/dl/），也拿不到 GitHub Actions 编好的本地助手：生成目录里不带 neu-v6-free");
      result = null;
    }
  }
  helperBuilt[platform] = result;
  return result;
}

/** 按当前提交下载 GitHub Actions 的编译产物（要装 gh 并登录）；返回解压到的目录，拿不到返回 null */
function ciArtifact(artifact, out) {
  const git = (...a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8" }).trim();
  let sha;
  try { sha = git("rev-parse", "HEAD"); } catch { return null; }
  const dir = path.join(out, ".cache", `${artifact}-${sha.slice(0, 12)}`);
  if (fs.existsSync(dir) && fs.readdirSync(dir).length) return dir;
  const gh = (...a) => execFileSync("gh", ["-R", "Concrise/neu-v6-free", ...a], { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  try {
    const run = JSON.parse(gh("run", "list", "--workflow", "windows-app.yml", "--commit", sha, "--status", "success", "--limit", "1", "--json", "databaseId"))[0];
    if (!run) {
      console.error(`提示：GitHub Actions 上还没有提交 ${sha.slice(0, 7)} 的编译结果（先推送，等「Windows App」跑完）`);
      return null;
    }
    fs.rmSync(dir, { recursive: true, force: true });
    gh("run", "download", String(run.databaseId), "-n", artifact, "-D", dir);
    return dir;
  } catch (e) {
    console.error(`提示：下载 GitHub Actions 的 ${artifact} 失败（${String(e.stderr || e.message).trim()}）`);
    return null;
  }
}

/**
 * Mac 的 App（mac/app/main.swift：窗口里是面板 + 菜单栏图标）。arm64 和 x86_64 各编一次合成通用二进制，
 * 图标由 make-icon.swift 现画。放进安装包目录：neu-v6-free install 和一键更新都从这里装到 /Applications。
 * 没有 swiftc（xcode-select --install）就跳过，安装后改用浏览器打开面板。
 */
function macApp(dir, out) {
  try { execFileSync("swiftc", ["--version"], { stdio: "ignore" }); } catch {
    console.error("提示：没有 swiftc（xcode-select --install），安装包里不带 App，装完用浏览器打开面板");
    return;
  }
  const work = tmpDir(out, ".mac-app");
  const app = path.join(dir, APP_NAME, "Contents");
  fs.mkdirSync(path.join(app, "MacOS"), { recursive: true });
  fs.mkdirSync(path.join(app, "Resources"), { recursive: true });
  const src = path.join(ROOT, "mac/app/main.swift");
  const bins = ["arm64", "x86_64"].map((arch) => {
    const o = path.join(work, arch);
    // 新版命令行工具编 x86_64 时会警告缺兼容库（macOS 13 起用不到），只在失败时显示输出
    try { execFileSync("swiftc", ["-O", "-target", `${arch}-apple-macos13`, src, "-o", o], { stdio: "pipe" }); } catch (e) {
      process.stderr.write(e.stderr || "");
      throw e;
    }
    return o;
  });
  execFileSync("lipo", ["-create", ...bins, "-output", path.join(app, "MacOS/neu-v6-free")]);
  execFileSync("swift", [path.join(ROOT, "mac/app/make-icon.swift"), path.join(work, "AppIcon.iconset")]);
  execFileSync("iconutil", ["-c", "icns", path.join(work, "AppIcon.iconset"), "-o", path.join(app, "Resources/AppIcon.icns")]);
  fs.writeFileSync(path.join(app, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>校园网 v6 免流</string>
  <key>CFBundleDisplayName</key><string>校园网 v6 免流</string>
  <key>CFBundleIdentifier</key><string>io.github.concrise.neu-v6-free.app</string>
  <key>CFBundleExecutable</key><string>neu-v6-free</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT · https://github.com/Concrise/neu-v6-free</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
`);
  execFileSync("xattr", ["-cr", path.join(dir, APP_NAME)]);
  execFileSync("codesign", ["--force", "--sign", "-", path.join(dir, APP_NAME)], { stdio: "pipe" });  // 自签（ad-hoc），Apple 芯片要求至少有签名
  fs.rmSync(work, { recursive: true, force: true });
}

/**
 * Windows 的 App（windows/app：窗口 + 托盘图标）在 GitHub Actions 上编译（.github/workflows/windows-app.yml）。
 * 打包时按当前提交下载那次编译的产物（要装 gh 并登录），放进安装包的 app 目录；也可以用环境变量 NEU_WINDOWS_APP
 * 指定已经编好的目录。拿不到就跳过，安装后改用浏览器打开面板。
 */
function winApp(dir, out) {
  let src = process.env.NEU_WINDOWS_APP;
  if (!src) {
    const git = (...a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8" }).trim();
    try {
      if (git("status", "--porcelain", "--", "windows/app", "package.json")) {
        console.error("提示：windows/app 或 package.json 有没提交的改动；安装包里的 Windows App 是按当前提交编译的");
      }
    } catch { /* 不是 git 仓库 */ }
    src = ciArtifact("neu-v6-free-windows-app", out);
    if (!src) return console.error("提示：安装包里不带 Windows App");
  }
  fs.cpSync(src, path.join(dir, "app"), { recursive: true });
  console.log(`Windows App：${src}`);
}

const tmpDir = (out, name) => { const d = path.join(out, name); fs.rmSync(d, { recursive: true, force: true }); fs.mkdirSync(d, { recursive: true }); return d; };

/**
 * 发布包。每个平台出两样：
 *   zip：程序文件（不含 sing-box），本地助手自动更新用，也可以解压后手动安装
 *   安装程序：mac 的 .pkg、windows 的 setup.exe，自带 sing-box，第一次安装用
 */
async function packageExtras(platform, dir, out) {
  if (platform === "android" || platform === "ios") return;
  if (platform === "windows") winApp(dir, out);
  if (!fs.existsSync(path.join(dir, platform === "windows" ? "neu-v6-free.exe" : "neu-v6-free"))) {
    throw new Error("发布包里必须有本地助手 neu-v6-free：装 go（https://go.dev/dl/），或推送后等 GitHub Actions 编好再打包");
  }
  if (platform === "mac") {
    const cmd = (what, run) => `#!/bin/bash\n# 双击运行：${what}（会要求输入开机密码）\ncd "$(dirname "$0")" && sudo ${run}\necho; read -n 1 -s -r -p "按任意键关闭"\n`;
    fs.writeFileSync(path.join(dir, "安装.command"), cmd("安装或升级", "./neu-v6-free install"), { mode: 0o755 });
    fs.writeFileSync(path.join(dir, "卸载.command"), cmd("卸载（保留订阅、设置和我的规则）", "/usr/local/libexec/neu-v6-free/neu-v6-free uninstall"), { mode: 0o755 });
    macApp(dir, out);
  }
  const base = `neu-v6-free-${VERSION}-${platform === "mac" ? "macos" : platform}`;
  fs.rmSync(path.join(out, `${base}.zip`), { force: true });
  execFileSync("zip", ["-qr", "-X", `${base}.zip`, path.basename(dir)], { cwd: out });
  addSum(out, `${base}.zip`);
  console.log(`已打包 ${path.join(out, base + ".zip")}`);
  const license = await singBoxLicense(out);

  if (platform === "mac") {
    // .pkg：文件装到 /usr/local/libexec/neu-v6-free/package，postinstall 以 root 运行 neu-v6-free install（App 也由它装到 /Applications）
    const root = tmpDir(out, ".pkg-root");
    const pkgDir = path.join(root, "usr/local/libexec/neu-v6-free/package");
    fs.mkdirSync(path.dirname(pkgDir), { recursive: true });
    fs.cpSync(dir, pkgDir, { recursive: true });
    for (const f of ["安装.command", "卸载.command"]) fs.rmSync(path.join(pkgDir, f), { force: true });
    const sb = path.join(pkgDir, "sing-box");  // arm64 + x86_64 合成一个通用二进制
    execFileSync("lipo", ["-create", await singBox(out, "darwin-arm64"), await singBox(out, "darwin-amd64"), "-output", sb]);
    fs.chmodSync(sb, 0o755);
    fs.copyFileSync(license, path.join(pkgDir, "sing-box-LICENSE.txt"));
    execFileSync("xattr", ["-cr", root]);
    const scripts = tmpDir(out, ".pkg-scripts");
    fs.copyFileSync(path.join(ROOT, "mac/pkg/postinstall"), path.join(scripts, "postinstall"));
    fs.chmodSync(path.join(scripts, "postinstall"), 0o755);
    const comp = tmpDir(out, ".pkg-comp");
    // 包里的 App 只是安装材料（neu-v6-free install 再装到 /Applications）：pkgbuild 默认把 .app 当成「可搬移」的，
    // 别处有同 ID 的 App 时会装到那里去，所以写明不可搬移
    const plist = path.join(comp, "components.plist");
    const hasApp = fs.existsSync(path.join(pkgDir, APP_NAME));
    fs.writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array>${hasApp ? `<dict>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><false/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
  <key>RootRelativeBundlePath</key><string>usr/local/libexec/neu-v6-free/package/${APP_NAME}</string>
</dict>` : ""}</array></plist>
`);
    execFileSync("pkgbuild", ["--quiet", "--root", root, "--component-plist", plist, "--scripts", scripts, "--identifier", "io.github.concrise.neu-v6-free",
      "--version", VERSION, "--install-location", "/", "--ownership", "recommended", path.join(comp, "neu-v6-free-core.pkg")],
      // 不要把扩展属性打成 ._ 文件放进包里（会被装到规则目录、面板目录）
      { stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, COPYFILE_DISABLE: "1" } });
    fs.rmSync(plist);
    const res = tmpDir(out, ".pkg-res");
    for (const f of ["welcome.html", "conclusion.html"]) fs.copyFileSync(path.join(ROOT, "mac/pkg", f), path.join(res, f));
    const dist = path.join(res, "distribution.xml");
    fs.writeFileSync(dist, fs.readFileSync(path.join(ROOT, "mac/pkg/distribution.xml"), "utf8").replaceAll("__VERSION__", VERSION));
    execFileSync("productbuild", ["--quiet", "--distribution", dist, "--resources", res, "--package-path", comp, path.join(out, `${base}.pkg`)]);
    for (const d of [".pkg-root", ".pkg-scripts", ".pkg-comp", ".pkg-res"]) fs.rmSync(path.join(out, d), { recursive: true, force: true });
    addSum(out, `${base}.pkg`);
    console.log(`已打包 ${path.join(out, base + ".pkg")}`);
  }

  if (platform === "windows") {
    // setup.exe：用 NSIS（brew install makensis）编译；自带 x64 和 ARM64 两个 sing-box
    try { execFileSync("makensis", ["-VERSION"], { stdio: "ignore" }); } catch {
      console.error("提示：没有 makensis（brew install makensis），跳过 Windows 安装程序，只出 zip");
      return;
    }
    const stage = tmpDir(out, ".setup-windows");
    fs.cpSync(dir, stage, { recursive: true });
    fs.copyFileSync(await singBox(out, "windows-amd64"), path.join(stage, "sing-box.exe"));
    fs.copyFileSync(await singBox(out, "windows-arm64"), path.join(stage, "sing-box-arm64.exe"));
    fs.copyFileSync(license, path.join(stage, "sing-box-LICENSE.txt"));
    const exe = `${base}-setup.exe`;
    execFileSync("makensis", ["-V2", "-INPUTCHARSET", "UTF8", `-DVERSION=${VERSION}`, `-DSRC=${path.resolve(stage)}`, `-DOUTFILE=${path.resolve(out, exe)}`,
      path.join(ROOT, "windows/installer.nsi")], { env: { ...process.env, LC_ALL: "en_US.UTF-8" } });  // 没有 UTF-8 locale 时 makensis 读不了中文
    fs.rmSync(stage, { recursive: true, force: true });
    addSum(out, exe);
    console.log(`已打包 ${path.join(out, exe)}`);
  }
}

main().catch((e) => { console.error(`错误：${e.message}`); process.exit(1); });
