package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"time"
)

// neu-v6-free apply <生成目录>：把命令行（node cli.js）生成的配置交给已安装的本地助手去检查、安装、重启 sing-box，
// 不用管理员。改了 config.yaml 才需要；在面板里改设置、切换分组、加「我的规则」都是立即生效的。
func cmdApply(args []string) {
	fs := flag.NewFlagSet("apply", flag.ExitOnError)
	parseFlags(fs, args)
	if fs.NArg() != 1 {
		die("用法：neu-v6-free apply <生成目录（里面有 config.json）>")
	}
	src, _ := filepath.Abs(fs.Arg(0))
	var c struct {
		Experimental struct {
			ClashAPI struct {
				Secret string `json:"secret"`
			} `json:"clash_api"`
		} `json:"experimental"`
	}
	if err := readJSON(filepath.Join(src, "config.json"), &c); err != nil {
		die("读不了 %s：%v", filepath.Join(src, "config.json"), err)
	}
	port := helperPort(Paths{Etc: src})
	code, res, err := postApply(port, c.Experimental.ClashAPI.Secret, src)
	// 助手刚升级：旧版助手不认识新增的文件，等新版起来再交一遍
	if err == nil && code == 200 && res["helper_updated"] == true {
		say("本地助手已升级，等它重启后再装一遍新增的文件……")
		waitHealth(port, 40*time.Second)
		code, res, err = postApply(port, c.Experimental.ClashAPI.Secret, src)
	}
	switch {
	case err != nil:
		die("连不上本地助手（127.0.0.1:%d）：还没安装就先运行安装程序；装过的话看 helper.log（%v）", port, err)
	case code == 200:
		say("已更新并重启 sing-box。")
		if res["server_fallback"] != nil {
			say("注意：当前网络连不上免流服务器，已自动改走「不用服务器」；能连上后会自动切回。")
		}
	default:
		die("更新失败：%v", res["error"])
	}
}

func postApply(port int, secret, src string) (int, obj, error) {
	req, _ := http.NewRequest("POST", fmt.Sprintf("http://127.0.0.1:%d/apply", port), bytes.NewReader(marshal(obj{"src": src})))
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 180 * time.Second, Transport: &http.Transport{Proxy: nil}}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var o obj
	json.Unmarshal(b, &o)
	if o == nil {
		o = obj{"error": fmt.Sprintf("HTTP %d", resp.StatusCode)}
	}
	return resp.StatusCode, o, nil
}

// 等本地助手（重新）起来；返回 /health 的内容，超时返回 nil
func waitHealth(port int, timeout time.Duration) obj {
	end := time.Now().Add(timeout)
	for time.Now().Before(end) {
		time.Sleep(time.Second)
		if h := health(port); h != nil {
			return h
		}
	}
	return nil
}

func health(port int) obj {
	resp, err := (&http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}).Get(fmt.Sprintf("http://127.0.0.1:%d/health", port))
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var o obj
	if json.NewDecoder(resp.Body).Decode(&o) != nil {
		return nil
	}
	return o
}
