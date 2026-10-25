; Windows 安装程序（setup.exe）。由 cli.js --package 用 makensis 编译：
;   makensis -DVERSION=<版本> -DSRC=<安装包目录> -DOUTFILE=<输出> windows/installer.nsi
; 它把安装包目录（脚本、面板、规则集、自带的 sing-box）解压到临时目录，运行 install.ps1 完成真正的安装
; （装到 C:\neu-v6-free、注册开机任务、自检，不通自动撤回），再在「设置 → 应用」里登记卸载。
Unicode true
!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh

!define APPNAME "校园网 v6 免流"
!define REGKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\neu-v6-free"
!define TARGET "C:\neu-v6-free"   ; 和生成配置时的 windows_panel_dir / windows_rules_dir 一致
!define UNINSTALLER "uninstall-neu-v6-free.exe"

Name "${APPNAME} ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel admin
InstallDir "${TARGET}"
ShowInstDetails show
ShowUninstDetails show
BrandingText "neu-v6-free ${VERSION}"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "安装 ${APPNAME} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "让能走 IPv6 的流量都走 IPv6（校园网不计费），并带一个网页面板：管理订阅和节点、切换线路、按网站改规则。$\r$\n$\r$\n\
安装前请先退出其他代理软件（Clash Verge、FlClash、v2rayN……，托盘图标右键退出），包括它们的 TUN 模式。$\r$\n$\r$\n\
• 装到 C:\neu-v6-free，开机自动运行，自带 sing-box 内核。$\r$\n\
• 装完会自检能不能上网，不通就自动撤回，电脑恢复原样。$\r$\n\
• 通过后自动打开「${APPNAME}」：窗口里是面板，右下角托盘有 v6 图标。$\r$\n\
• 以后的新版本在面板「设置」里一键更新。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "装好了"
!define MUI_FINISHPAGE_TEXT "「${APPNAME}」应该已经打开了（窗口里是面板），右下角托盘里有 v6 图标；以后从开始菜单或桌面打开。$\r$\n$\r$\n\
现在已经在省流：有 IPv6 的国内网站走 v6 免费。有机场订阅或自己的服务器，到面板「订阅与节点」里加，改完点「应用」。$\r$\n$\r$\n\
万一上不了网：会自动暂停；也可以在托盘图标的菜单里暂停。关掉窗口、退出 App 都不影响免流。卸载：设置 → 应用 →「${APPNAME}」。"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "FileDescription" "${APPNAME} 安装程序"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_SIMPCHINESE} "LegalCopyright" "MIT（自带的 sing-box 为 GPLv3）"

Function .onInit
  ${If} ${RunningX64}
    SetRegView 64
  ${EndIf}
FunctionEnd

Function un.onInit
  ${If} ${RunningX64}
    SetRegView 64
  ${EndIf}
FunctionEnd

Section "Install"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\pkg"
  File /r "${SRC}/*"
  DetailPrint "正在安装并自检能不能上网（最多一两分钟）……"
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\pkg\install.ps1" -NoPause'
  Pop $0
  SetOutPath "$TEMP"  ; 离开解压目录，安装程序退出时才能删掉它
  ${If} $0 != 0
    MessageBox MB_ICONSTOP|MB_OK "安装没有完成，网络已经恢复原样。$\r$\n$\r$\n原因见安装窗口里的详细信息（常见：别的代理软件还开着、端口被占用、不在校园网）。处理后重新运行安装程序即可。"
    Abort "安装没有完成"
  ${EndIf}
  ; 卸载信息：设置 → 应用、控制面板「程序和功能」里都能看到
  WriteUninstaller "${TARGET}\${UNINSTALLER}"
  WriteRegStr HKLM "${REGKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${REGKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${REGKEY}" "Publisher" "Concrise"
  WriteRegStr HKLM "${REGKEY}" "URLInfoAbout" "https://github.com/Concrise/neu-v6-free"
  WriteRegStr HKLM "${REGKEY}" "InstallLocation" "${TARGET}"
  WriteRegStr HKLM "${REGKEY}" "UninstallString" '"${TARGET}\${UNINSTALLER}"'
  WriteRegStr HKLM "${REGKEY}" "DisplayIcon" "${TARGET}\app\neu-v6-free.exe"
  WriteRegDWORD HKLM "${REGKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${REGKEY}" "NoRepair" 1
  ; 开始菜单、桌面的入口由 install.ps1 建（指向 C:\neu-v6-free\app\neu-v6-free.exe），zip 手动安装时也有
SectionEnd

Section "Uninstall"
  MessageBox MB_YESNO|MB_ICONQUESTION "同时删除订阅、设置、「我的规则」和流量统计吗？$\r$\n$\r$\n选「否」会保留它们，重新安装后接着用。" IDYES purge
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "${TARGET}\uninstall.ps1" -NoPause'
  Goto done
  purge:
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "${TARGET}\uninstall.ps1" -NoPause -Purge'
  done:
  Pop $0
  DeleteRegKey HKLM "${REGKEY}"
  SetShellVarContext all
  Delete "$SMPROGRAMS\${APPNAME}.url"  ; 1.1.0 及以前的开始菜单入口；新的 .lnk 由 uninstall.ps1 删
  Delete "${TARGET}\${UNINSTALLER}"
  RMDir "${TARGET}"  ; 空了才删（保留了订阅和规则时目录还在）
SectionEnd
