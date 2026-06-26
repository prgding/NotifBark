# NotifBark

把 **macOS 通知**（默认只转 Claude 桌面版）实时转发到手机 **[Bark](https://github.com/Finb/Bark)** 的菜单栏小程序。

macOS 没有公开 API 实时监听通知，本工具的做法是：轮询系统通知数据库 → 解析出新通知 → 按白名单过滤 → 用 Bark 的 HTTP 接口推到手机。一个菜单栏图标即可看状态、开关、跳转授权。

## 特性

- 🔔 菜单栏图标：状态（转发中 / 暂停 / 无权限）、上次转发、一键开关、发送测试、直达「完全磁盘访问」设置
- 🎯 按 app 过滤（bundle id 白名单），默认只转 `com.anthropic.claudefordesktop`
- 🔒 **单一用途**：只读系统通知数据库这一个文件，对其**零写入、零加锁**（拷贝到临时目录再读）
- 🪪 **自签名**：用一张本地自签名证书签名，TCC 按证书身份认 app，**重新编译不会让完全磁盘访问授权失效**，无需反复授权
- 🚀 开机自启（LaunchAgent）

## 要求

- macOS 13+（在 macOS 26 上开发）
- Xcode 命令行工具（`swiftc`、`codesign`）

## 安装

```bash
git clone https://github.com/prgding/NotifBark.git
cd NotifBark

# 1) 创建自签名代码签名证书（只需一次）
./setup-cert.sh

# 2) 编译、签名、安装、设为开机自启
./build.sh

# 3) 配置 Bark key
mkdir -p ~/.notif2bark
cp config.example.json ~/.notif2bark/config.json
# 编辑 ~/.notif2bark/config.json，把 YOUR_KEY 换成你的 Bark key

# 4) 授予完全磁盘访问
#    菜单栏 NotifBark 图标 → 「打开『完全磁盘访问』设置」
#    把 ~/Applications/NotifBark.app 加进列表并打开
```

授权后菜单栏图标会从 ⚠️ 变成 🔔，点「发送测试推送」验证手机能收到即可。

## 配置 `~/.notif2bark/config.json`

```json
{
  "barkUrl": "https://api.day.app/YOUR_KEY",
  "whitelist": ["com.anthropic.claudefordesktop"],
  "pollSeconds": 3
}
```

- `barkUrl`：你的 Bark 推送地址（官方服务器或自建）
- `whitelist`：要转发的 app bundle id 列表；**留空 `[]` 表示转发全部 app**
  - 查某个 app 的 bundle id：`osascript -e 'id of app "应用名"'`，例如微信是 `com.tencent.xinWeChat`
- `pollSeconds`：轮询间隔秒数

改完配置后从菜单栏退出再重新打开（或重启服务）生效。

## 为什么需要「完全磁盘访问」

系统通知数据库位于受 TCC 保护的目录，读取它需要完全磁盘访问。本工具把权限**只授给 NotifBark 这一个单一用途的 app**——它的代码只会打开通知数据库这一个文件，无法被指使去读别的文件，把权限的影响面降到最小。

## 实现要点（踩坑记录）

- 通知库是 **WAL 模式**且被系统持续写入，最新通知在 `-wal` 里。直接只读打开会读到「冻结快照」漏掉新通知；用 `immutable=1` 又会忽略 WAL。解法：把 `db` + `db-wal` 拷到临时目录再打开副本读，既看得到最新数据，又不碰原库。
- 通知的 **bundle id 在 plist 顶层 `app` 字段**；标题/正文在 `req` 的 `titl`/`body`/`subt`。
- TCC 授权按程序的**代码签名 DR** 记。`swiftc` 默认 ad-hoc 签名的哈希每次编译都变，所以会反复要求重新授权；改用稳定的自签名证书后，DR 只跟 bundle id + 证书绑定，重编译不再失效。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.dings.notifbark
rm -f ~/Library/LaunchAgents/com.dings.notifbark.plist
rm -rf ~/Applications/NotifBark.app ~/.notif2bark
# 再到 系统设置 → 隐私与安全性 → 完全磁盘访问 删掉 NotifBark 条目
```

## License

MIT
