# btr-lan-proxy

[English](README.md) | 中文

把 [Bilibili 线程撕裂者](https://github.com/MrTangLuyao/Bilibili-thread-ripper)做成家庭网络里的一个小服务。对于无法修改的 B 站播放器（例如官方电视端「云视听小电视」），它通过同时使用多条 CDN 连接下载视频，解决每隔几秒就缓冲一次的问题。

播放器本身不做任何改动：路由器把播放器的视频请求转给这个代理，由代理来应答。

## 工作原理

```
电视 App ──HTTP :80──▶ 路由器 ──重定向──▶ btr-lan-proxy ──多条 HTTPS 分段请求──▶ B 站 CDN
```

1. 官方电视 App 用明文 HTTP（80 端口）拉取视频和音频，每条轨道只有一条连接。卡顿就出在这一条连接上。
2. 路由器上的两条 NAT 规则把电视的 80 端口流量重定向到代理。
3. 代理读取每个请求的 `Host` 头和路径。如果是 B 站媒体文件，就启动一个线程撕裂者会话，通过多条连接和多个 CDN 镜像分块下载，再按顺序把字节流回给播放器。
4. 电视发出的其他 80 端口请求原样转发给原本的目标主机。

用 DNS 劫持做不到这一点：App 的播放器通过自带的 HTTP DNS 解析 CDN 域名，不走系统 DNS。

## 它不做什么

- **不碰 HTTPS 流量**。代理没在运行或某个请求失败时，App 会自己回退到 HTTPS，照旧播放，也照旧缓冲。
- **不增加杜比视界，也不跳过广告片段**。代理只改变字节的下载方式。
- **直播**和非媒体请求原样转发。

## 测试情况

| | 状态 |
| :--- | :--- |
| 云视听小电视 1.8.9（Android TV）、UniFi 网关、代理运行在 macOS（arm64）、`--region overseas` | 已测试：HDR 和 SDR 视频、拖动进度、连续播放多个视频 |
| Linux x64 和 arm64 可执行文件 | 能编译；未运行 |
| Docker 镜像、群晖、Windows、systemd 单元、launchd 配置、CI 工作流 | 已编写；尚未运行 |
| `--region mainland` | 未在电视 App 上测试 |
| OpenWrt / iptables 规则 | 标准写法；未运行 |

## 安装

任选一种方式。代理所在的机器需要在看电视时保持开机，并且地址固定（在路由器上给它分配固定 IP）。

示例使用 `8080` 端口。端口可以随意选：路由器规则会把电视的 80 端口转换成它，所以代理不需要占用 80 端口，也不需要管理员权限。

### Docker（Linux、群晖及其他支持容器的 NAS）

```bash
git clone https://github.com/liweichen6/btr-lan-proxy.git
```

```bash
cd btr-lan-proxy && docker compose up -d --build
```

启动前先编辑 `docker-compose.yml`，设置 `BTR_REGION`（中国大陆以外用 `overseas`，大陆用 `mainland`）。

群晖：打开 **Container Manager → 项目 → 新增**，路径选择本仓库所在的文件夹，使用其中的 `docker-compose.yml`。DSM 自身占用 80 和 443 端口，这也是代理默认监听其他端口的原因之一。

### 可执行文件（Linux、macOS、Windows）

需要 [Dart SDK](https://dart.dev/get-dart) 3.8 或更高版本：

```bash
dart pub get
```

```bash
dart compile exe bin/btr_lan_proxy.dart -o btr-lan-proxy
```

```bash
./btr-lan-proxy --port 8080 --region overseas
```

在 Windows 上输出文件是 `btr-lan-proxy.exe`。在 macOS 或 Linux 上也可以用 `--target-os linux --target-arch x64`（或 `arm64`）交叉编译 Linux 版本。

仓库的 GitHub 工作流也会构建这些可执行文件和多架构容器镜像。

### 开机自启

- **Linux（systemd）**：[deploy/btr-lan-proxy.service](deploy/btr-lan-proxy.service)，安装命令写在文件开头。
- **macOS（launchd）**：[deploy/com.btr-lan-proxy.plist](deploy/com.btr-lan-proxy.plist)。Mac 睡眠时无法提供服务，看电视时要让它保持唤醒。
- **Windows**：在「任务计划程序」里新建任务，开机时运行 `btr-lan-proxy.exe --port 8080 --region overseas`，选择「不管用户是否登录都要运行」；Windows 防火墙询问时，允许它在专用网络上通信。

### 确认它在运行

在局域网内用浏览器打开 `http://<代理地址>:8080/`，会看到 `btr-lan-proxy 0.1.0 is running, 0 media requests in progress.`

## 路由器规则

需要两条规则。示例中电视是 `192.168.1.50`，代理所在机器是 `192.168.1.10`，代理监听 `8080`。

1. **重定向**：电视发往任意地址 80 端口的 TCP 流量转给代理。
2. **回程**：电视发往代理的流量离开路由器时，源地址改成路由器自己的地址。否则代理会直接回复电视，而电视期待的是来自 CDN 地址的回复，会把它丢弃。只要电视和代理在同一个网段，就需要这条规则。

也给电视分配固定 IP，规则才能一直匹配。

### UniFi

Network 9.4 及以上：**Settings → Policy Table → Create New Policy → NAT**。Network 9.3：**Settings → Policy Engine → NAT → Create New**。

| 字段 | 规则 1 | 规则 2 |
| :--- | :--- | :--- |
| Type | Dest. NAT | Masquerade |
| Interface | 电视所在的 LAN 网络 | 同一个 LAN 网络 |
| Translated IP Address | `192.168.1.10` | – |
| Translated Port | `8080` | – |
| Protocol | TCP | TCP |
| Source | IP `192.168.1.50`，任意端口 | IP `192.168.1.50`，任意端口 |
| Destination | Any，端口 `80` | IP `192.168.1.10`，端口 `8080` |

### OpenWrt 及其他使用 iptables 的路由器

```
iptables -t nat -A PREROUTING -i br-lan -s 192.168.1.50 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:8080
iptables -t nat -A POSTROUTING -o br-lan -s 192.168.1.50 -d 192.168.1.10 -p tcp --dport 8080 -j MASQUERADE
```

### 停用

暂停或删除这两条规则。规则开着而代理没在运行时，电视的明文 HTTP 请求会失败；B 站 App 会回退到 HTTPS，但电视上其他使用明文 HTTP 的应用会无法加载。

## 选项

每个选项都有对应的环境变量，方便容器使用。命令行参数优先于环境变量。

| 选项 | 环境变量 | 默认值 | 含义 |
| :--- | :--- | :--- | :--- |
| `--port <n>` | `BTR_PORT` | `8080` | 监听端口 |
| `--bind <地址>` | `BTR_BIND` | `0.0.0.0` | 监听地址 |
| `--region <名称>` | `BTR_REGION` | `mainland` | 使用的 CDN 节点：`mainland` 或 `overseas` |
| `--concurrency <n>` | `BTR_CONCURRENCY` | `16` | 每个播放器的并行 CDN 连接数，1–128 |
| `--debug` | `BTR_DEBUG=1` | 关 | 见下文 |
| `--dump-failed-urls <文件>` | – | 关 | 与 `--debug` 同用：保存每个失败请求的完整地址 |

## 日志与调试

默认情况下，代理只在启动时、每个媒体请求完成时、每个媒体请求失败时各写一行日志：

```
2026-11-13T16:20:01.123 listening on 0.0.0.0:8080, region overseas, 16 connections
2026-11-13T16:21:40.456 served upos-sz-mirrorcosov.bilivideo.com 1505589879_hr1-1-30125.m4s bytes=47467555-: 312.83 MiB in 119.1 s, 22.0 Mbit/s
```

这里的速度是播放器读取数据的速度，播放器缓冲区满了就会被限制。日志只记录文件名，不记录地址里的查询参数，因为其中有你账号的签名令牌。

`--debug` 会额外记录：

- 每个到达的请求（媒体或转发）各一行，以及播放器关闭的每条连接；
- 媒体请求失败时，对同一文件直接向 CDN 发三个请求（HTTPS 带播放器的 Referer、HTTPS 带网页端 Referer、明文 HTTP），并记录各自的状态码。

`--dump-failed-urls <文件>` 还会把每个失败请求的完整地址追加到文件里，便于手动复现。这些地址大约两小时内有效，并带有账号令牌：用完请删除该文件，不要分享。

### 不工作时

| 现象 | 可能原因 |
| :--- | :--- |
| 播放视频时没有 `served` 行 | 路由器规则没有匹配（电视地址或接口不对），或者 App 对这个视频已经回退到 HTTPS。换一个视频再试。 |
| 用电脑能打开状态页，但电视的请求到不了 | 缺少规则 1，或规则设在了错误的网络上。 |
| 请求到了（`--debug` 可见），但视频一直不开始 | 缺少规则 2。 |
| `failed … the thread ripper answered "HTTP/1.1 502"` | CDN 拒绝了下载。加 `--debug` 运行，查看 probe 行。 |
| 机器睡眠后失效 | 让机器保持唤醒，或把代理移到一直开机的机器上。 |

## 安全

- 只在可信的家庭网络里运行，不要把它的端口暴露到公网。
- 非媒体请求只会转发到公网地址，不会转发到本机或局域网内的其他设备。
- 媒体请求只会通过 HTTPS 从 B 站的 CDN 主机获取。
- 它不保存任何数据。签名地址只在视频播放期间保存在内存里。

## 代码结构

- `bin/btr_lan_proxy.dart`：命令入口。
- `lib/src/server.dart`：代理本体。
- `lib/src/thread_ripper/`：线程撕裂者下载核心，原样复制自 [PiliPlus-LemonTeaV](https://github.com/liweichen6/PiliPlus-LemonTeaV)（`lib/services/thread_ripper`）；`ORIGIN` 记录了对应的提交。用 `tool/sync_ripper.sh /path/to/PiliPlus` 更新。它自己的测试在那个仓库里。
- `test/proxy_test.dart`：代理的测试，使用本机回环地址上的模拟 CDN。运行 `dart test`。

## 致谢与许可

- 下载方法来自 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)（MIT；[声明](licenses/bilibili-thread-ripper.txt)）。
- 其下载核心的 Dart 移植来自 PiliPlus 的各个 fork，采用 GPL-3.0。

本项目采用 [GPL-3.0](LICENSE) 许可。

本项目与 Bilibili 无关。它不修改 App，只读取你自己的路由器转给它的请求；请在自己的网络里、用自己的账号使用。
