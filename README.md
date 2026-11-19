# Jezail Console（Windows 设备管理端）

局域网内 jezail 设备的统一管理工具：自动发现、状态监控、一键打开 Web UI / 终端 / 投屏 / Refrida。

配套关系：`../jezail`（Android 端，负责暴露 HTTP API + UDP 发现响应）。

## 功能

- **自动发现**：UDP 广播 `JEZAIL_DISCOVER_V1` → 8090 端口，设备回包即入库；支持手动添加 IP:端口
- **网段扫描**：可配置网段（如 `192.168.1.0/24`）+ 端口列表，并发探测 `TCP connect → GET /api/status → GET /api/device`，可随时取消
- **设备清单**：在线状态、root 状态、认证状态、型号/版本/上次在线时间，支持搜索过滤、别名备注、删除、清理离线；广播/扫描/手动三入口合并去重——扫描与手动命中后会向该主机单播再问一次稳定 id（`HTTP /api/device` 里没有 id，只有 UDP 回包有），能对上即按 id 合并；同 endpoint、无 id 的历史重复在启动与健康轮询时自动折叠
- **单机操作**：详情抽屉可单机重探、复制 `IP:端口`、查看最近错误；带 PIN 认证的设备会被标记 `auth`（`GET /api/device` 401 即判定位受保护设备，仍记为在线）
- **健康轮询**：默认 30 秒检查一次（可配），掉线标灰
- **快捷入口**：一键用系统浏览器打开 Web UI、终端、投屏、Refrida、Swagger（应用内 WebView 方案因构建机只有 VS 2019、不满足 WebView2 插件的 C++23 要求而回退，见代码历史；若升级到 VS 2022 生成工具可再做）
- **本地持久化**：已知设备 + 设置存本机（shared_preferences），无服务端

暂不做：批量操作、告警推送、用户鉴权 token 保险柜（当前按“内网裸连、无认证”设计，需要时再加）。

## 发现协议（v1）

- 探测方 → UDP 广播（255.255.255.255 + 各网卡 /24 广播地址），端口 **8090**，载荷 ASCII：`JEZAIL_DISCOVER_V1`
- 设备 → 向探测源 IP 单播回 JSON（UTF-8）：

```json
{
  "type": "jezail-hello", "v": 1,
  "id": "<ANDROID_ID，稳定去重>",
  "name": "<用户设备名>", "manufacturer": "Allwinner", "model": "R107INCH",
  "android": "10", "sdk": 29,
  "http": 8080, "auth": false, "root": true,
  "app": "2.0.0", "api": 1
}
```

Android 端实现见 `../jezail/app/src/main/java/com/azzahid/jezail/core/api/DiscoveryResponder.kt`，
随 HTTP 服务启停（服务开则广播响应，关则停止）。

## 构建与运行

前置：Flutter stable + Visual Studio（含“使用 C++ 的桌面开发”工作负载）。

```powershell
cd Code\jezail_console
flutter pub get
flutter analyze        # 应无 issue
flutter test           # 单元 + Widget 测试（含真实 UDP/HTTP 回环测试）
flutter run -d windows # 直接运行
flutter build windows --release   # 产出 build\windows\x64\runner\Release\
```

首次运行 Windows 防火墙会弹允许网络提示，允许即可（UDP 回包需要入站）。

## 目录结构

```
lib/
  main.dart                 # 入口 + 深色主题
  models/device.dart        # 设备模型（发现 JSON <-> 本地 JSON）
  services/
    discovery_service.dart  # UDP 广播发现 + probeHost + 网段扫描
    device_store.dart       # shared_preferences 持久化
    health_service.dart     # 定时轮询（ChangeNotifier）
    app_links.dart          # url_launcher 打开各 Web 页面
  pages/
    home_page.dart          # 设备列表/搜索/发现/手动添加/详情抽屉
    settings_page.dart      # 网段、端口、轮询间隔
test/
  discovery_service_test.dart  # UDP 协议 + 扫描 + 探测（含回环真机逻辑）
  probe_timing_test.dart       # 超时行为回归（2s TCP 超时）
  home_page_test.dart          # 列表渲染/搜索/手动添加流程
```

## 注意事项

- 同一网段内工作；跨网段/不同 VLAN 请用“手动添加”或配置网段扫描（广播包过不了路由器）。
- 局域网使用默认无认证；如设备开了 PIN 认证，管理端暂不支持自动配对（规划中）。
- 扫描是并发 TCP+HTTP 探测，大网段请分段扫，避免打满弱 AP。
