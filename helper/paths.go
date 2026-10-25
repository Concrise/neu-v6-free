package main

import "path/filepath"

// Paths：安装后各样东西放在哪里。mac 分三个目录（程序、配置、状态），windows 都在 C:\neu-v6-free 里
type Paths struct {
	Bin   string // 程序：neu-v6-free、sing-box
	Etc   string // 配置：config.json、profile.json、panel\、rules\、VERSION、panel-secret
	Var   string // 状态：traffic.json、safe-mode.json、server-fallback.json、日志
	Data  string // sing-box 的工作目录（-D，缓存文件在这里）
	Label string // 服务名：mac 是 launchd 的 Label，windows 是服务名
}

func (p Paths) Config() string   { return filepath.Join(p.Etc, "config.json") }
func (p Paths) Profile() string  { return filepath.Join(p.Etc, "profile.json") }
func (p Paths) Version() string  { return filepath.Join(p.Etc, "VERSION") }
func (p Paths) Secret() string   { return filepath.Join(p.Etc, "panel-secret") }
func (p Paths) Panel() string    { return filepath.Join(p.Etc, "panel") }
func (p Paths) Rules() string    { return filepath.Join(p.Etc, "rules") }
func (p Paths) SingBox() string  { return filepath.Join(p.Bin, singBoxName) }
func (p Paths) Self() string     { return filepath.Join(p.Bin, selfName) }
func (p Paths) SafeFile() string { return filepath.Join(p.Var, "safe-mode.json") }
func (p Paths) Fallback() string { return filepath.Join(p.Var, "server-fallback.json") }
func (p Paths) Traffic() string  { return filepath.Join(p.Var, "traffic.json") }
func (p Paths) HelperLog() string {
	return filepath.Join(p.Var, "helper.log")
}
func (p Paths) SingBoxLog() string { return filepath.Join(p.Var, "sing-box.log") }
