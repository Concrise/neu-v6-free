// 「校园网 v6 免流」的 Windows 外壳：一个窗口（里面是本机面板 http://127.0.0.1:9090/ui，用 WebView2 显示）+ 托盘图标
// （运行状态、暂停 / 重新启用、今天的流量）。真正干活的是 sing-box 和本地助手（以 SYSTEM 运行的 Windows 服务），
// 这个程序只是界面：退出它不影响免流。和 mac/app/main.swift 做的事一样。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace NeuV6Free
{
    static class Program
    {
        public const string Name = "校园网 v6 免流";
        public const string Panel = "http://127.0.0.1:9090/ui/";
        public const string Helper = "http://127.0.0.1:9091/";
        // 安装目录 = exe 所在目录（app）的上一级，默认 C:\neu-v6-free
        public static readonly string Dir = Path.GetDirectoryName(Path.GetDirectoryName(Application.ExecutablePath));
        // 窗口位置、WebView2 的数据（面板记住的密钥等）放在用户自己的目录：安装目录普通用户写不了
        public static readonly string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "neu-v6-free");

        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);

        [STAThread]
        static void Main(string[] args)
        {
            using var mutex = new Mutex(true, @"Local\neu-v6-free-app", out bool first);
            var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\neu-v6-free-app-show");
            if (!first)
            {
                // 已经开着一个：让它把窗口拿出来（允许它抢到前台），自己退出
                AllowSetForegroundWindow(-1);
                show.Set();
                return;
            }
            Directory.CreateDirectory(Data);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new App(show, args.Contains("--background")));
        }

        /// <summary>本地助手写的面板密钥（只有管理员、SYSTEM 和登录的用户能读）。读不到就让面板自己要密钥</summary>
        public static string Secret()
        {
            try
            {
                var s = File.ReadAllText(Path.Combine(Dir, "panel-secret")).Trim();
                return s.Length > 0 ? s : null;
            }
            catch { return null; }
        }

        public static void OpenExternal(string url)
        {
            if (Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https"))
                try { Process.Start(new ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true }); } catch { }
        }
    }

    static class Json
    {
        static readonly JavaScriptSerializer js = new JavaScriptSerializer { MaxJsonLength = 16 << 20 };
        public static Dictionary<string, object> Parse(string s)
        {
            if (s == null) return null;
            try { return js.DeserializeObject(s) as Dictionary<string, object>; } catch { return null; }
        }
        public static object Get(this Dictionary<string, object> d, string k) => d != null && d.TryGetValue(k, out var v) ? v : null;
        public static double Num(object o) { try { return o == null ? 0 : Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return 0; } }
        public static string Str(string s) => js.Serialize(s);
    }

    /// <summary>助手 /health 的结果</summary>
    class Status
    {
        public bool Helper, SingBox;
        public string SafeReason;  // 不为空 = 已暂停（安全模式）
        public string Fallback;  // 连不上免流服务器时，原来选的入口
        public string Version = "";
        public string Latest;  // 有新版本时的版本号
        public bool Running => Helper && SingBox && SafeReason == null;

        public static Status From(Dictionary<string, object> h)
        {
            var s = new Status { Helper = true, SingBox = h.Get("singbox") as bool? ?? false, Version = h.Get("version") as string ?? "" };
            if (h.Get("safe_mode") is Dictionary<string, object> sm) s.SafeReason = sm.Get("reason") as string ?? "已暂停";
            if (h.Get("server_fallback") is Dictionary<string, object> fb) s.Fallback = fb.Get("previous") as string ?? "";
            if (h.Get("update") is Dictionary<string, object> u && u.Get("available") as bool? == true) s.Latest = u.Get("latest") as string;
            return s;
        }
    }

    class App : ApplicationContext
    {
        enum Look { On, Paused, Problem }

        readonly NotifyIcon tray = new NotifyIcon();
        readonly Control ui = new Control();  // 后台线程回到界面线程用
        readonly HttpClient http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(5) };
        readonly HttpClient slow = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(120) };
        readonly Dictionary<Look, Icon> icons = new Dictionary<Look, Icon>();
        readonly string version = Application.ProductVersion;
        PanelForm form;
        public Status Status = new Status();
        public bool Polled;  // 第一次状态检查回来之前窗口先空着，免得闪一下出错页
        Dictionary<string, object> today;
        string busy;  // 正在暂停 / 重新启用时显示在菜单第一行
        bool polling;

        public App(EventWaitHandle show, bool background)
        {
            _ = ui.Handle;
            foreach (Look l in Enum.GetValues(typeof(Look))) icons[l] = MakeIcon(l);
            tray.Icon = icons[Look.Problem];
            tray.Text = Program.Name;
            tray.ContextMenuStrip = new ContextMenuStrip();
            tray.ContextMenuStrip.Items.Add("…");  // 没有菜单项时不会弹出；打开前现做
            tray.ContextMenuStrip.Opening += (s, e) => { BuildMenu(tray.ContextMenuStrip); e.Cancel = false; };
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };
            tray.BalloonTipClicked += (s, e) => ShowWindow();
            tray.Visible = true;
            new Thread(() => { while (true) { show.WaitOne(); ui.BeginInvoke((Action)ShowWindow); } }) { IsBackground = true }.Start();

            FirstRunAutostart();
            var timer = new System.Windows.Forms.Timer { Interval = 4000 };
            timer.Tick += (s, e) => Poll();
            timer.Start();
            Poll();
            // 开机自动启动时只放托盘图标；用户自己打开时直接给窗口
            if (!background) ShowWindow();
        }

        // ---------- 状态 ----------

        async Task<string> GetText(string path)
        {
            try
            {
                using var r = await http.GetAsync(Program.Helper + path);
                return r.IsSuccessStatusCode ? await r.Content.ReadAsStringAsync() : null;
            }
            catch { return null; }
        }

        async void Poll()
        {
            if (polling) return;
            polling = true;
            try
            {
                var h = Json.Parse(await GetText("health"));
                // 重新启用时助手要十几秒确认能上网，这期间它顾不上回应 /health（一次只处理一个请求）：
                // 保持原来的状态，别把图标变成出问题、把窗口换成出错页
                if (h == null && busy != null) return;
                Status = h == null ? new Status() : Status.From(h);
                Polled = true;
                tray.Icon = icons[Status.Running ? Look.On : Status.SafeReason != null ? Look.Paused : Look.Problem];
                var tip = Program.Name + "：" + StatusLine();
                tray.Text = tip.Length > 63 ? tip.Substring(0, 62) + "…" : tip;
                // 面板由 sing-box 提供：sing-box 起来 / 停掉时，窗口跟着换成面板 / 状态页
                if (form != null && !form.IsDisposed && form.Visible && form.Wanted(Status) != form.Current) form.ShowPage(Status);
                var t = Json.Parse(await GetText("traffic"));
                today = (t.Get("days") as Dictionary<string, object>).Get(DateTime.Now.ToString("yyyy-MM-dd")) as Dictionary<string, object>;
                RelaunchIfUpdated();
            }
            finally { polling = false; }
        }

        /// <summary>一键更新换掉了磁盘上的程序（助手把运行中的旧 exe 改名后放新的）：重新打开自己，用上新版</summary>
        void RelaunchIfUpdated()
        {
            string onDisk;
            try { onDisk = FileVersionInfo.GetVersionInfo(Application.ExecutablePath).ProductVersion; } catch { return; }
            if (string.IsNullOrEmpty(onDisk) || onDisk == version) return;
            var bg = form != null && !form.IsDisposed && form.Visible ? "" : " --background";
            Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping -n 3 127.0.0.1 >nul & start \"\" \"{Application.ExecutablePath}\"{bg}")
            { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });
            Quit();
        }

        string StatusLine()
        {
            var st = Status;
            if (busy != null) return busy;
            if (!st.Helper) return "本地助手没有响应（服务没装好，或正在重启）";
            if (st.SafeReason != null) return "已暂停：" + st.SafeReason;
            if (!st.SingBox) return "sing-box 没有运行";
            return "● 正在免流";
        }

        /// <summary>托盘图标：圆角方块里写「v6」。蓝绿 = 正在免流，灰 = 已暂停，橙色感叹号 = 出问题</summary>
        static Icon MakeIcon(Look look)
        {
            int s = Math.Max(16, SystemInformation.SmallIconSize.Width) * 2;  // 画大一倍再交给系统缩小，边缘更平滑
            using var bmp = new Bitmap(s, s);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                var r = new RectangleF(s * 0.03f, s * 0.03f, s * 0.94f, s * 0.94f);
                using var path = Rounded(r, s * 0.22f);
                using Brush fill = look switch
                {
                    Look.On => new LinearGradientBrush(r, Color.FromArgb(33, 107, 242), Color.FromArgb(13, 189, 158), 45f),
                    Look.Paused => new SolidBrush(Color.FromArgb(138, 143, 152)),
                    _ => new SolidBrush(Color.FromArgb(217, 119, 6)),
                };
                g.FillPath(fill, path);
                using var font = new Font("Segoe UI", s * (look == Look.Problem ? 0.62f : 0.5f), FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(look == Look.Problem ? "!" : "v6", font, Brushes.White, new RectangleF(0, s * 0.02f, s, s), fmt);
            }
            using var small = new Bitmap(bmp, s / 2, s / 2);
            return Icon.FromHandle(small.GetHicon());
        }

        static GraphicsPath Rounded(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static string Bytes(double n)
        {
            string[] u = { "B", "KB", "MB", "GB", "TB" };
            int i = 0;
            while (n >= 1000 && i < u.Length - 1) { n /= 1000; i++; }
            return (i == 0 ? n.ToString("0") : n.ToString(n < 10 ? "0.0" : "0")) + " " + u[i];
        }

        // ---------- 托盘菜单 ----------

        void BuildMenu(ContextMenuStrip m)
        {
            m.Items.Clear();
            var st = Status;
            Info(m, StatusLine());
            if (st.Running && st.Fallback != null) Info(m, "连不上免流服务器，暂时走「不用服务器」，能连上后自动切回");
            if (st.Helper && today != null)
            {
                var server = (today.Get("server") as Dictionary<string, object>)?.Values.Sum(Json.Num) ?? 0;
                Info(m, $"今天：v6 {Bytes(Json.Num(today.Get("v6")))} · 服务器 {Bytes(server)} · v4（计费）{Bytes(Json.Num(today.Get("v4")))}");
            }
            m.Items.Add(new ToolStripSeparator());
            var open = Add(m, "打开面板", ShowWindow);
            open.Font = new Font(open.Font, FontStyle.Bold);
            var pause = Add(m, st.Running ? "暂停（回到普通网络）" : "重新启用", TogglePause);
            pause.Enabled = st.Helper && busy == null && (st.Running || st.SafeReason != null || !st.SingBox);
            if (st.Latest != null) Add(m, $"有新版本 {st.Latest}，去更新…", OpenUpdate);
            m.Items.Add(new ToolStripSeparator());
            var auto = Add(m, "开机时自动打开", () => SetAutostart(!AutostartOn()));
            auto.Checked = AutostartOn();
            Info(m, "版本 " + (st.Version == "" ? version : st.Version));
            Add(m, "退出（免流照常运行）", Quit);
        }

        static void Info(ContextMenuStrip m, string text) => m.Items.Add(new ToolStripMenuItem(text) { Enabled = false });

        static ToolStripMenuItem Add(ContextMenuStrip m, string text, Action act)
        {
            var i = new ToolStripMenuItem(text);
            i.Click += (s, e) => act();
            m.Items.Add(i);
            return i;
        }

        public void ShowWindow()
        {
            if (form == null || form.IsDisposed) form = new PanelForm(this);
            form.Show();
            if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
            form.Activate();
            if (Polled && form.Current == PanelForm.Page.None) form.ShowPage(Status);
        }

        void OpenUpdate()
        {
            ShowWindow();
            if (form.Current == PanelForm.Page.Panel) form.Navigate(Program.Panel + "#settings");
        }

        /// <summary>第一次关窗口时提示一下：程序还在托盘里</summary>
        public void HintTray()
        {
            using var k = Registry.CurrentUser.CreateSubKey(@"Software\neu-v6-free");
            if (k.GetValue("TrayHintShown") != null) return;
            k.SetValue("TrayHintShown", 1);
            tray.ShowBalloonTip(5000, Program.Name, "还在右下角的托盘里运行（可能要点 ^ 展开）。免流和窗口开不开无关。", ToolTipIcon.Info);
        }

        void Quit()
        {
            tray.Visible = false;
            if (form != null && !form.IsDisposed) form.Dispose();
            ExitThread();
        }

        async void TogglePause()
        {
            var secret = Program.Secret();
            if (secret == null)
            {
                MessageBox.Show("读不到面板密钥（没装好，或者不是安装时登录的账户）。可以在面板里暂停 / 重新启用。", Program.Name);
                return;
            }
            bool pausing = Status.Running;
            if (pausing && MessageBox.Show("sing-box 会停下，电脑回到普通网络（v4 计费）。之后在托盘图标的菜单里点「重新启用」。",
                    "暂停免流？", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            busy = pausing ? "正在暂停……" : "正在重新启用……（要十几秒确认能上网）";
            tray.Text = busy;
            try
            {
                var req = new HttpRequestMessage(HttpMethod.Post, Program.Helper + (pausing ? "pause" : "resume")) { Content = new StringContent("") };
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
                using var r = await slow.SendAsync(req);
                if (!r.IsSuccessStatusCode)
                {
                    var err = Json.Parse(await r.Content.ReadAsStringAsync()).Get("error") as string;
                    MessageBox.Show(err ?? $"错误 {(int)r.StatusCode}", pausing ? "暂停失败" : "重新启用失败");
                }
            }
            catch (Exception e) { MessageBox.Show(e.Message, pausing ? "暂停失败" : "重新启用失败"); }
            finally
            {
                busy = null;
                Poll();
            }
        }

        // ---------- 开机自动打开（当前用户的「启动」项）----------

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        static bool AutostartOn()
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue("neu-v6-free") != null;
        }

        static void SetAutostart(bool on)
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue("neu-v6-free", $"\"{Application.ExecutablePath}\" --background");
            else k.DeleteValue("neu-v6-free", false);
        }

        /// <summary>第一次打开时默认开机自动打开，这样重启后托盘图标还在</summary>
        static void FirstRunAutostart()
        {
            using var k = Registry.CurrentUser.CreateSubKey(@"Software\neu-v6-free");
            if (k.GetValue("AutostartSet") != null) return;
            SetAutostart(true);
            k.SetValue("AutostartSet", 1);
        }
    }

    class PanelForm : Form
    {
        public enum Page { None, Panel, Status, Error }
        public Page Current = Page.None;  // 窗口里现在是什么
        readonly App app;
        readonly WebView2 web = new WebView2 { Dock = DockStyle.Fill };
        bool ready;
        Status pending;
        static readonly string BoundsFile = Path.Combine(Program.Data, "window.txt");

        const string ErrorPage = @"<!doctype html><meta charset=""utf-8""><style>
:root{color-scheme:light dark}
body{font:15px/1.7 ""Segoe UI"",""Microsoft YaHei"",sans-serif;max-width:560px;margin:80px auto;padding:0 20px;color:#1c2027}
@media (prefers-color-scheme: dark){body{color:#e6e8ec;background:#1c1e22}}
code{font:13px Consolas,monospace}</style>
<h2>本地服务没有响应</h2>
<p>sing-box 和本地助手都连不上，可能正在重启，或者没装好。这个窗口会自动重试。</p>
<p>一直这样的话：重新运行安装程序；或者重启电脑（本地助手开机自动运行）。</p>";

        public PanelForm(App app)
        {
            this.app = app;
            Text = Program.Name;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            // 不用 WinForms 的自动缩放（保存的窗口位置是实际像素，再缩放一次会越开越大）：默认大小按屏幕缩放比例算
            AutoScaleMode = AutoScaleMode.None;
            float k = DeviceDpi / 96f;
            MinimumSize = new Size((int)(720 * k), (int)(480 * k));
            Size = new Size((int)(1180 * k), (int)(800 * k));
            StartPosition = FormStartPosition.CenterScreen;
            LoadBounds();
            Controls.Add(web);
            SystemEvents.UserPreferenceChanged += ThemeChanged;
            Init();
        }

        // ---------- 深色模式 ----------
        // 页面自己按 prefers-color-scheme 换颜色（WebView2 跟着系统）；窗口的底色、边框也跟着

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        /// <summary>「设置 → 个性化 → 颜色 → 选择默认应用模式」选了深色</summary>
        static bool SystemDark()
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
            }
            catch { return false; }
        }

        void ApplyTheme()
        {
            bool dark = SystemDark();
            int on = dark ? 1 : 0;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE（Windows 11 上边框跟着变深）；更早的 Windows 10 用 19，没有也没关系
            if (DwmSetWindowAttribute(Handle, 20, ref on, sizeof(int)) != 0) DwmSetWindowAttribute(Handle, 19, ref on, sizeof(int));
            // 页面加载出来之前的底色，免得深色模式下先白一下
            BackColor = dark ? Color.FromArgb(17, 19, 24) : Color.FromArgb(244, 245, 247);
            web.DefaultBackgroundColor = BackColor;
        }

        // ---------- 窗口顶部 ----------
        // 不用 Windows 画的标题栏（Windows 10 上是白的一条，跟页面不搭）：页面一直铺到窗口顶端，
        // 由 TitleBarScript 在页面最上面画一条同色的，带最小化、最大化、关闭。左右下的边框还是系统的，能拖动改大小。
        // 拖动：WebView2 支持 app-region: drag 时由它交给 Windows（贴边分屏、双击最大化都是系统的）；
        // 不支持的旧运行时，页面在按下时发 tb:drag，这里当成在标题栏上按下

        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, IntPtr lp);
        [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
        [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0083 && m.WParam != IntPtr.Zero)  // WM_NCCALCSIZE：系统照常算出边框，只把标题栏那一截还给页面
            {
                int top = Marshal.PtrToStructure<RECT>(m.LParam).Top;
                base.WndProc(ref m);
                var r = Marshal.PtrToStructure<RECT>(m.LParam);
                r.Top = top;
                if (IsZoomed(Handle))
                {
                    // 最大化时窗口四周超出屏幕一圈（边框宽度）：顶上也让出这一圈，不然最上面一截看不见
                    uint dpi = GetDpiForWindow(Handle);
                    r.Top += GetSystemMetricsForDpi(33, dpi) + GetSystemMetricsForDpi(92, dpi);  // SM_CYFRAME + SM_CXPADDEDBORDER
                }
                Marshal.StructureToPtr(r, m.LParam, false);
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        /// <summary>按下鼠标交给 Windows，当成按在标题栏（2）或上边框（12）上</summary>
        void SystemDrag(int hit)
        {
            ReleaseCapture();
            SendMessage(Handle, 0x00A1, (IntPtr)hit, IntPtr.Zero);  // WM_NCLBUTTONDOWN
        }

        void PostMaximized()
        {
            if (ready) web.CoreWebView2.PostWebMessageAsString(WindowState == FormWindowState.Maximized ? "tb:max:1" : "tb:max:0");
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            PostMaximized();
        }

        // 每个页面（面板、助手状态页、出错页）加载时都画一遍顶栏：颜色取页面自己的，深色浅色自动一致
        const string TitleBarScript = @"(() => {
  if (window.top !== window) return;
  const H = 32;
  const post = (m) => { try { window.chrome.webview.postMessage(m); } catch (e) {} };
  const css = `
html.tb body { padding-top: ${H}px !important; box-sizing: border-box; }
html.tb .app { min-height: calc(100vh - ${H}px) !important; }
@media (min-width: 861px) { html.tb nav { top: ${H}px !important; height: calc(100vh - ${H}px) !important; } }
#tb { position: fixed; top: 0; left: 0; right: 0; height: ${H}px; z-index: 2147483000; display: flex; justify-content: flex-end;
  app-region: drag; -webkit-app-region: drag; user-select: none; -webkit-user-select: none; }
#tb button { app-region: no-drag; -webkit-app-region: no-drag; width: 46px; height: ${H}px; border: 0; margin: 0; padding: 0;
  background: transparent; color: inherit; font: 10px 'Segoe MDL2 Assets', 'Segoe Fluent Icons'; cursor: default; outline: none; }
#tb button:hover { background: rgba(128, 128, 128, .2); }
#tb button.x:hover { background: #c42b1c; color: #fff; }`;
  let bar, maxBtn, maxed = false, queued = false;
  const paint = () => {
    queued = false;
    if (!bar) return;
    const body = getComputedStyle(document.body);
    let bg = body.backgroundColor;
    if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') bg = getComputedStyle(document.documentElement).backgroundColor;
    if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') bg = 'Canvas';
    let fill = bg;
    const nav = document.querySelector('.app:not(.bare) > nav');
    if (nav && nav.offsetHeight > innerHeight / 2) {
      const n = getComputedStyle(nav), w = nav.offsetWidth;
      fill = `linear-gradient(to right, ${n.backgroundColor} ${w - 1}px, ${n.borderRightColor} ${w - 1}px ${w}px, ${bg} ${w}px)`;
    } else if (nav) fill = getComputedStyle(nav).backgroundColor;
    bar.style.background = fill;
    bar.style.color = body.color;
  };
  const later = () => { if (!queued) { queued = true; requestAnimationFrame(paint); } };
  const init = () => {
    if (document.getElementById('tb') || !document.body) return;
    document.documentElement.classList.add('tb');
    const st = document.createElement('style');
    st.textContent = css;
    (document.head || document.documentElement).append(st);
    bar = document.createElement('div');
    bar.id = 'tb';
    for (const [glyph, title, msg, cls] of [['', '最小化', 'tb:min', ''], ['', '最大化', 'tb:max', 'm'], ['', '关闭', 'tb:close', 'x']]) {
      const b = document.createElement('button');
      b.textContent = glyph; b.title = title; b.className = cls; b.tabIndex = -1;
      b.setAttribute('aria-label', title);
      b.onclick = () => post(msg);
      bar.append(b);
      if (cls === 'm') maxBtn = b;
    }
    bar.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || e.target.closest('button')) return;
      e.preventDefault();
      if (e.detail === 2) post('tb:max');
      else if (e.clientY <= 4 && !maxed) post('tb:top');
      else post('tb:drag');
    });
    document.body.append(bar);
    paint();
    new MutationObserver(later).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
    addEventListener('resize', later);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', later);
    post('tb:hello');
  };
  try {
    window.chrome.webview.addEventListener('message', (e) => {
      if (typeof e.data !== 'string' || !e.data.startsWith('tb:max:')) return;
      maxed = e.data === 'tb:max:1';
      if (maxBtn) { maxBtn.textContent = maxed ? '' : ''; maxBtn.title = maxed ? '还原' : '最大化'; maxBtn.setAttribute('aria-label', maxBtn.title); }
    });
  } catch (e) {}
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();";

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyTheme();
            SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0037);  // SWP_FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER|NOACTIVATE：按上面的 WM_NCCALCSIZE 重算一次
        }

        void ThemeChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (e.Category == UserPreferenceCategory.General && IsHandleCreated) BeginInvoke((Action)ApplyTheme);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) SystemEvents.UserPreferenceChanged -= ThemeChanged;  // 静态事件：不退订窗口就一直不会被回收
            base.Dispose(disposing);
        }

        async void Init()
        {
            try
            {
                var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Program.Data, "WebView2"));
                await web.EnsureCoreWebView2Async(env);
            }
            catch (WebView2RuntimeNotFoundException)
            {
                var r = MessageBox.Show("这台电脑缺少 Microsoft Edge WebView2 运行时（显示面板要用）。\n\n" +
                    "「是」：打开微软的下载页，装好后重新打开本程序。\n「否」：先用浏览器打开面板。",
                    Program.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                Program.OpenExternal(r == DialogResult.Yes ? "https://go.microsoft.com/fwlink/p/?LinkId=2124703" : Program.Panel);
                Hide();
                return;
            }
            catch (Exception e)
            {
                MessageBox.Show("面板窗口打不开：" + e.Message, Program.Name);
                return;
            }
            var core = web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            // 顶栏：页面里 app-region: drag 的地方当成标题栏（WebView2 运行时 123 起支持；不支持时页面发 tb:drag）
            try { core.Settings.IsNonClientRegionSupportEnabled = true; } catch { }
            await core.AddScriptToExecuteOnDocumentCreatedAsync(TitleBarScript);
            core.WebMessageReceived += (s, e) =>
            {
                string msg;
                try { msg = e.TryGetWebMessageAsString(); } catch { return; }
                switch (msg)
                {
                    case "tb:min": WindowState = FormWindowState.Minimized; break;
                    case "tb:max": WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; break;
                    case "tb:close": Close(); break;
                    case "tb:drag": SystemDrag(2); break;   // HTCAPTION
                    case "tb:top": if (WindowState == FormWindowState.Normal) SystemDrag(12); break;  // HTTOP：从上边缘拉大
                    case "tb:hello": PostMaximized(); break;
                }
            };
            // 面板（9090）和助手状态页（9091）各自从 localStorage 取密钥：每次都填文件里的，等于自动登录。
            // 不能只在没存时填：重新安装后密钥换了，存着的旧密钥会让面板先要密钥
            var secret = Program.Secret();
            if (secret != null)
                await core.AddScriptToExecuteOnDocumentCreatedAsync(
                    "if (location.hostname === '127.0.0.1' && ['9090', '9091'].includes(location.port)) {" +
                    $" try {{ localStorage.setItem('neu-secret', {Json.Str(secret)}); }} catch (e) {{}} }}");
            // 本机页面在窗口里开，别的网址（GitHub 等）交给默认浏览器
            core.NewWindowRequested += (s, e) => { e.Handled = true; Program.OpenExternal(e.Uri); };
            core.NavigationStarting += (s, e) =>
            {
                if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var u)) return;
                bool isWeb = u.Scheme == "http" || u.Scheme == "https";
                if (isWeb && u.Host != "127.0.0.1" && u.Host != "localhost") { e.Cancel = true; Program.OpenExternal(e.Uri); }
            };
            // 面板打不开（sing-box 刚停）：先显示出错页，下一轮状态检查再换成该显示的页面
            core.NavigationCompleted += (s, e) =>
            {
                if (!e.IsSuccess && e.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled && Current != Page.Error)
                {
                    Current = Page.Error;
                    core.NavigateToString(ErrorPage);
                }
            };
            ready = true;
            if (pending != null) ShowPage(pending);
        }

        public Page Wanted(Status st) => st.Helper && st.SingBox ? Page.Panel : st.Helper ? Page.Status : Page.Error;

        /// <summary>sing-box 在运行就开面板，否则开助手的状态页（能看原因、重新启用）；助手也不在就给出错页</summary>
        public void ShowPage(Status st)
        {
            if (!ready) { pending = st; return; }
            pending = null;
            Current = Wanted(st);
            if (Current == Page.Panel) web.CoreWebView2.Navigate(Program.Panel);
            else if (Current == Page.Status) web.CoreWebView2.Navigate(Program.Helper);
            else web.CoreWebView2.NavigateToString(ErrorPage);
        }

        public void Navigate(string url) { if (ready) web.CoreWebView2.Navigate(url); }

        // 关窗口 = 藏到托盘（退出在托盘菜单里）
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveBounds();
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                app.HintTray();
            }
            base.OnFormClosing(e);
        }

        void LoadBounds()
        {
            try
            {
                var v = File.ReadAllText(BoundsFile).Split(',').Select(int.Parse).ToArray();
                var r = new Rectangle(v[0], v[1], v[2], v[3]);
                if (!Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(r))) return;  // 原来的显示器拔掉了
                StartPosition = FormStartPosition.Manual;
                Bounds = r;
                if (v[4] == 1) WindowState = FormWindowState.Maximized;
            }
            catch { }
        }

        void SaveBounds()
        {
            try
            {
                var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
                File.WriteAllText(BoundsFile, $"{r.X},{r.Y},{r.Width},{r.Height},{(WindowState == FormWindowState.Maximized ? 1 : 0)}");
            }
            catch { }
        }
    }
}
