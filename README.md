# Clash Verge 老 CPU / 虚拟机 内核崩溃修复

> 界面能打开、但内核永远"未运行"、没有端口监听、代理用不了？
> 如果你用的是老电脑、QEMU/KVM 虚拟机、云桌面/VDI，大概率是这个问题。

## 症状

- Clash Verge 主界面可以正常打开，配置和订阅都在
- 但内核一直起不来：进程列表里没有 `verge-mihomo`，`127.0.0.1:7897` 没有任何监听
- 系统代理开不了，或者开了也没网
- Windows 事件日志里能看到：

```
错误应用程序名称: verge-mihomo.exe
异常代码: 0xc0000005
事件名称: BEX64
```

- 直接运行内核也会立刻退出，连版本号都打印不出来：

```powershell
& "C:\Program Files\Clash Verge\verge-mihomo.exe" -v
# 什么都不输出，退出码 -1073741819 (0xC0000005)
```

## 原因

Clash Verge 自带的内核 `verge-mihomo.exe` 是按**较新的 x86-64 指令集**编译的。
在缺少 SSE4.2 / POPCNT / AVX 等指令的 CPU 上（老笔记本、QEMU/KVM 虚拟机、部分云桌面），
内核一启动就触发非法指令 / 访问违例，直接崩溃。

修复思路很简单：换成 mihomo 官方的 **amd64-compatible** 构建（按 x86-64 基线指令集编译），
这个构建就是为老 CPU 准备的。

## 怎么用

### 方式一：双击（推荐）

1. 下载本仓库（绿色 `Code` → `Download ZIP`），解压
2. 双击 `fix.bat`
3. 弹出 UAC 时点"是"（脚本需要管理员权限才能替换 `Program Files` 里的文件）
4. 看到 `修复完成` 后，脚本会自动重启 Clash Verge

### 方式二：命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-core.ps1
```

可选参数：

```powershell
# 指定版本
.\fix-core.ps1 -CoreVersion v1.19.34

# Clash Verge 装在非默认目录
.\fix-core.ps1 -ClashVergeDir "D:\Apps\Clash Verge"

# 完全离线：用本地已下载好的 compatible 内核（.exe 或 .zip 都行）
.\fix-core.ps1 -SourceFile D:\mihomo-windows-amd64-compatible.exe
```

## 脚本做了什么

1. 从 MetaCubeX/mihomo Releases 下载 `mihomo-windows-amd64-compatible-<版本>.zip`
   （GitHub 直连失败会自动切 `ghfast.top`、`ghproxy.net` 镜像）
2. 关闭正在运行的 Clash Verge
3. 备份原内核为 `verge-mihomo.exe.orig-broken`（只备份一次，不会覆盖你之前的备份）
4. 替换 `C:\Program Files\Clash Verge\verge-mihomo.exe`
5. **实际执行一次 `-v` 校验**：如果新内核还是跑不起来，自动回滚并报错
6. 重启 Clash Verge，并检查 `verge-mihomo` 进程是否真的起来了

日志写在 `C:\ProgramData\ClashVergeOldCpuFix\fix.log`，出问题可以直接看。

## 回滚

```powershell
# 管理员 PowerShell
Copy-Item "C:\Program Files\Clash Verge\verge-mihomo.exe.orig-broken" `
          "C:\Program Files\Clash Verge\verge-mihomo.exe" -Force
```

## 注意事项

- **每次升级 Clash Verge 后都要重跑一次**，安装包会把内核覆盖回不兼容的版本。
  建议在「设置 → 常规」里关掉自动更新，避免某次更新后突然又不能用了。
- 本仓库**不包含**内核二进制（58MB），脚本按需下载；需要离线分发时请放到 Releases 里，
  不要直接 `git add` 进仓库。
- 用到的兼容构建来自 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)（GPL-3.0）。
- TUN 模式在 VDI/虚拟机上经常和虚拟网卡冲突，建议用系统代理模式。

## 已验证环境

| 项目 | 值 |
| --- | --- |
| 系统 | Windows 10 专业版 19045 |
| 环境 | 深信服 VDI（QEMU/KVM，模拟 Intel Core 2 Duo T7700） |
| Clash Verge | 2.5.8 / 2.5.10 |
| 内核 | mihomo v1.19.34 `windows-amd64-compatible`（go1.26.11） |

## 许可

脚本部分 MIT。内核二进制版权归 MetaCubeX/mihomo 所有，遵循 GPL-3.0。
