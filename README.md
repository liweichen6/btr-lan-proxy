# btr-lan-proxy

English | [中文](README.zh.md)

The [Bilibili thread ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) as a small service on your home network. It removes the every-few-seconds buffering in a Bilibili player you cannot modify, such as the official TV app (云视听小电视), by fetching each video over many CDN connections at once.

The player stays as it is. Your router sends the player's video requests to this proxy, and the proxy answers them.

## How it works

```
TV app ──HTTP :80──▶ router ──redirect──▶ btr-lan-proxy ──many HTTPS ranges──▶ Bilibili CDN
```

1. The official TV app fetches video and audio over plain HTTP on port 80, one connection per track. That single connection is what stalls.
2. Two NAT rules on the router redirect the TV's port-80 traffic to the proxy.
3. The proxy reads the `Host` header and path of each request. For a Bilibili media file it starts a thread ripper session, which downloads the file in pieces over many connections and CDN mirrors, and streams the bytes back in order.
4. Any other port-80 request from the TV is passed on to the host it was meant for, unchanged.

A DNS override does not work for this: the app's player looks up CDN hosts through its own HTTP-based DNS, not the system's.

## What it does not do

- **HTTPS traffic** is not touched. If the proxy is down or a request fails, the app falls back to HTTPS on its own and plays as it did before, with the buffering.
- **Dolby Vision and ad skipping** are not added. The proxy only changes how bytes are downloaded.
- **Live streams** and non-media requests are relayed as they are.

## What was tested

| | Status |
| :--- | :--- |
| 云视听小电视 1.8.9 on an Android TV, UniFi gateway, proxy on macOS (arm64), `--region overseas` | Tested: HDR and SDR videos, seeks, several videos in a row |
| Linux x64 and arm64 binaries | Build; not run |
| Docker image, Synology, Windows, systemd unit, launchd agent, CI workflow | Written; not run yet |
| `--region mainland` | Not tested with the TV app |
| OpenWrt / iptables rules | Standard form; not run |

## Install

Pick one. The proxy needs a machine that is on whenever the TV is in use, and an address that does not change (give it a fixed IP on the router).

The examples use port `8080`. The port is free to choose: the router rule translates the TV's port 80 to it, so the proxy does not need port 80 or administrator rights.

### Docker (Linux, Synology, any NAS with containers)

```bash
git clone https://github.com/liweichen6/btr-lan-proxy.git
```

```bash
cd btr-lan-proxy && docker compose up -d --build
```

Edit `docker-compose.yml` first to set `BTR_REGION` (`overseas` outside mainland China, `mainland` inside).

On Synology: open **Container Manager → Project → Create**, point it at the folder holding this repository, and use the `docker-compose.yml` in it. DSM itself uses ports 80 and 443, which is one reason the proxy listens on another port.

### Binary (Linux, macOS, Windows)

With the [Dart SDK](https://dart.dev/get-dart) 3.8 or newer:

```bash
dart pub get
```

```bash
dart compile exe bin/btr_lan_proxy.dart -o btr-lan-proxy
```

```bash
./btr-lan-proxy --port 8080 --region overseas
```

On Windows the output is `btr-lan-proxy.exe`. From macOS or Linux you can also cross-compile for Linux with `--target-os linux --target-arch x64` (or `arm64`).

The repository's GitHub workflow also builds these binaries and a multi-architecture container image.

### Run it at startup

- **Linux (systemd)**: [deploy/btr-lan-proxy.service](deploy/btr-lan-proxy.service). The install commands are at the top of the file.
- **macOS (launchd)**: [deploy/com.btr-lan-proxy.plist](deploy/com.btr-lan-proxy.plist). A sleeping Mac serves nothing, so keep it awake while the TV is in use.
- **Windows**: create a Task Scheduler task that runs `btr-lan-proxy.exe --port 8080 --region overseas` at startup, "whether the user is logged on or not", and allow the program through Windows Firewall for private networks when asked.

### Check that it runs

Open `http://<proxy address>:8080/` in a browser on the LAN. It answers `btr-lan-proxy 0.1.0 is running, 0 media requests in progress.`

## Router rules

Two rules are needed. In the examples the TV is `192.168.1.50`, the proxy machine is `192.168.1.10`, and the proxy listens on `8080`.

1. **Redirect**: TCP from the TV to any address on port 80 goes to the proxy.
2. **Return path**: traffic from the TV to the proxy leaves the router with the router's own address as its source. Without this, the proxy answers the TV directly and the TV drops the reply, because it expects it from the CDN's address. This rule is needed whenever the TV and the proxy are on the same network.

Give the TV a fixed IP too, so the rules keep matching.

### UniFi

Network 9.4 and later: **Settings → Policy Table → Create New Policy → NAT**. Network 9.3: **Settings → Policy Engine → NAT → Create New**.

| Field | Rule 1 | Rule 2 |
| :--- | :--- | :--- |
| Type | Dest. NAT | Masquerade |
| Interface | the TV's LAN network | the same LAN network |
| Translated IP Address | `192.168.1.10` | – |
| Translated Port | `8080` | – |
| Protocol | TCP | TCP |
| Source | IP `192.168.1.50`, any port | IP `192.168.1.50`, any port |
| Destination | Any, port `80` | IP `192.168.1.10`, port `8080` |

### OpenWrt and other iptables routers

```
iptables -t nat -A PREROUTING -i br-lan -s 192.168.1.50 -p tcp --dport 80 -j DNAT --to-destination 192.168.1.10:8080
iptables -t nat -A POSTROUTING -o br-lan -s 192.168.1.50 -d 192.168.1.10 -p tcp --dport 8080 -j MASQUERADE
```

### Turning it off

Pause or delete the two rules. While the rules are on and the proxy is not running, the TV's plain-HTTP requests fail; the Bilibili app then falls back to HTTPS, but other apps on the TV that use plain HTTP will not load.

## Options

Every option also has an environment variable, for containers. Arguments win over the environment.

| Option | Environment | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `--port <n>` | `BTR_PORT` | `8080` | Port to listen on |
| `--bind <address>` | `BTR_BIND` | `0.0.0.0` | Address to listen on |
| `--region <name>` | `BTR_REGION` | `mainland` | CDN nodes to use: `mainland` or `overseas` |
| `--concurrency <n>` | `BTR_CONCURRENCY` | `16` | Parallel CDN connections per player, 1–128 |
| `--debug` | `BTR_DEBUG=1` | off | See below |
| `--dump-failed-urls <file>` | – | off | With `--debug`: save the full address of each failed request |

## Log and debugging

By default the proxy logs one line when it starts, one for each media request it finished, and one for each that failed:

```
2026-11-13T16:20:01.123 listening on 0.0.0.0:8080, region overseas, 16 connections
2026-11-13T16:21:40.456 served upos-sz-mirrorcosov.bilivideo.com 1505589879_hr1-1-30125.m4s bytes=47467555-: 312.83 MiB in 119.1 s, 22.0 Mbit/s
```

The speed is the rate the player read at, which a full player buffer limits. The log names the file and never the address's query, which holds your account's signed tokens.

`--debug` adds:

- a line for every request as it arrives, media or relayed, and for every connection the player closes;
- when a media request fails, three direct requests to the CDN for the same file (HTTPS with the player's Referer, HTTPS with the web Referer, and plain HTTP), with the status of each.

`--dump-failed-urls <file>` also appends each failed request's full address to a file, to reproduce a failure by hand. Those addresses work for about two hours and carry account tokens: delete the file afterwards and do not share it.

### If it does not work

| What you see | Likely cause |
| :--- | :--- |
| No `served` lines while a video plays | The router rules do not match (wrong TV address, wrong interface), or the app already fell back to HTTPS for this video. Start another video. |
| The status page works from a computer, but nothing arrives from the TV | Rule 1 is missing or on the wrong network. |
| Requests arrive (`--debug`), the video never starts | Rule 2 is missing. |
| `failed … the thread ripper answered "HTTP/1.1 502"` | The CDN refused the downloads. Run with `--debug` and read the probe lines. |
| Works, then stops after the machine sleeps | Keep the machine awake, or move the proxy to one that stays on. |

## Security

- Run it on a trusted home network only, and never expose its port to the internet.
- It relays non-media requests only to public internet addresses, never to this machine or to other devices on the LAN.
- Media requests are fetched only from Bilibili's CDN hosts, over HTTPS.
- It stores nothing. Signed addresses are kept in memory while a video plays.

## How the code is organized

- `bin/btr_lan_proxy.dart`: the command.
- `lib/src/server.dart`: the proxy.
- `lib/src/thread_ripper/`: the thread ripper download core, copied unchanged from [PiliPlus-LemonTeaV](https://github.com/liweichen6/PiliPlus-LemonTeaV) (`lib/services/thread_ripper`); `ORIGIN` records the commit. Update it with `tool/sync_ripper.sh /path/to/PiliPlus`. Its own tests live in that repository.
- `test/proxy_test.dart`: the proxy's tests, against a stand-in CDN on loopback. Run them with `dart test`.

## Credits and license

- The download method is [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) (MIT; [notice](licenses/bilibili-thread-ripper.txt)).
- The Dart port of its download core comes from the PiliPlus forks, which are GPL-3.0.

This project is licensed under [GPL-3.0](LICENSE).

It is not affiliated with Bilibili. It changes nothing in the app and reads nothing but the requests your own router sends it; use it with your own account, on your own network.
