// neu-v6-free：本地助手和安装程序，macOS 和 Windows 共用一份代码，编出来是一个不依赖任何东西的可执行文件。
//
//	neu-v6-free run        本地助手（系统服务，root / SYSTEM）：运行并看护 sing-box、断网保护、我的规则、
//	                       流量统计、面板的客户端功能（订阅、设置、安装配置）、自动更新。只监听 127.0.0.1
//	neu-v6-free install    安装或升级（要管理员）：装文件、注册服务、自检，不通就撤回
//	neu-v6-free uninstall  卸载（--purge 连订阅、设置、我的规则、流量统计一起删）
//	neu-v6-free apply 目录  把命令行（node cli.js）生成的配置交给已安装的本地助手（不用管理员）
//
// 以前的版本 macOS 用 Python（helper.py）、Windows 用 PowerShell（helper.ps1）各写一份，
// 新 Mac 上没有 Python（要装开发者工具），PowerShell 5.1 又有不少限制，所以合成了这一份。
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// 编译时用 -ldflags "-X main.version=1.2.0" 写入
var version = "dev"

func usage() {
	fmt.Fprint(os.Stderr, `用法：neu-v6-free <命令> [参数]
  run         运行本地助手（系统服务调用）
  install     安装或升级（要管理员）
  uninstall   卸载（--purge 连数据一起删）
  apply <目录>  把命令行生成的配置交给本地助手安装
  version     版本号
`)
	os.Exit(2)
}

func main() {
	setupConsole()
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "run":
		cmdRun(args)
	case "install":
		cmdInstall(args)
	case "uninstall":
		cmdUninstall(args)
	case "apply":
		cmdApply(args)
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		if !platformCommand(cmd, args) {
			usage()
		}
	}
}

// 各命令共用的参数：安装目录的名字（mac：/usr/local/*/<name>）和服务名
type common struct {
	name, label string
	port        int
}

func (c *common) register(fs *flag.FlagSet) {
	fs.StringVar(&c.name, "name", "neu-v6-free", "安装目录名（mac：/usr/local/libexec|etc|var/<name>）")
	fs.StringVar(&c.label, "label", "", "服务名（默认：mac local.<name>，windows neu-v6-free）")
	fs.IntVar(&c.port, "port", 0, "本地助手端口（默认读面板 groups.json 的 traffic_port，再默认 9091）")
}

func (c *common) paths() Paths {
	p := defaultPaths(c.name)
	if c.label != "" {
		p.Label = c.label
	}
	return p
}

// 解析参数；出错时直接退出
func parseFlags(fs *flag.FlagSet, args []string) {
	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		os.Exit(2)
	}
}

func die(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if !strings.HasSuffix(msg, "\n") {
		msg += "\n"
	}
	writeOut(os.Stderr, msg)
	os.Exit(1)
}
