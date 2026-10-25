package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// userError：说给用户听的错误（HTTP 400，面板原样显示）
type userError struct{ msg string }

func (e *userError) Error() string { return e.msg }

func bad(format string, a ...any) error { return &userError{fmt.Sprintf(format, a...)} }

func isUserError(err error) bool {
	_, ok := err.(*userError)
	return ok
}

// 日志：mac 由 launchd 把标准输出写进 helper.log；windows 的服务没有标准输出，run 时改成写文件
var (
	logMu  sync.Mutex
	logOut io.Writer = os.Stdout
)

func logf(format string, a ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Fprintf(logOut, "%s %s\n", stamp(), fmt.Sprintf(format, a...))
}

// 和以前的助手一样的时间格式（2026-10-25T12:00:00），面板按这个格式显示
func stamp() string { return time.Now().Format("2006-01-02T15:04:05") }

// JSON：不转义 < > &、中文原样输出（和以前的助手一致，面板和 sing-box 都能读）
func marshal(v any) []byte {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return bytes.TrimRight(b.Bytes(), "\n")
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// 先写临时文件再改名：别的程序（sing-box、面板）不会读到写了一半的文件
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil { // WriteFile 只在新建时用 mode
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func copyFile(src, dst string, mode os.FileMode) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := writeAtomic(dst, b, mode); err != nil {
		return err
	}
	ownRoot(dst)
	return nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func sameFile(a, b string) bool {
	x, err1 := os.ReadFile(a)
	y, err2 := os.ReadFile(b)
	return err1 == nil && err2 == nil && bytes.Equal(x, y)
}

// map 里取值的小工具：sing-box 配置按通用 JSON 读，字段多且可选
type obj = map[string]any

func getObj(m obj, k string) obj {
	if v, ok := m[k].(map[string]any); ok {
		return v
	}
	return nil
}

func getStr(m obj, k string) string {
	s, _ := m[k].(string)
	return s
}

func getList(m obj, k string) []any {
	l, _ := m[k].([]any)
	return l
}

func getNum(m obj, k string) float64 {
	switch v := m[k].(type) {
	case float64:
		return v
	case json.Number:
		f, _ := v.Float64()
		return f
	}
	return 0
}
