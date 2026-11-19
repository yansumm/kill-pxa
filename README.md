# kill-pxa

如果对你有帮助，欢迎star，如果有问题欢迎提issue与pr

想让个人电脑同时访问内网与外网（Google、GPT、Claude），本来只有两条路：要么在个人电脑上安装 PXA 这类占几个 G 存储、狂吃内存 CPU、还会截屏录屏造成过度隐私暴露的 `strange software` 进 **Office 网络** 再开“魔法”；要么连 **Guest 网络** 走多个 VPN，但 Guest 网络又把“魔法”给限制死了。

这个 skill 提供第三条路：**无需路由器！** 只要你有一台已经接入 **Office 网络** 并部署好“魔法”（Clash/mihomo）的主机，个人电脑就能安心留在 Guest 网络，通过官方 VPN + 常驻 SSH 端口转发把那台主机的出口借过来，做成本地客户端里可一键切换的 profile——个人电脑从此免装 `strange software`。

- 怎么配、要满足什么前提：[SKILL.md](SKILL.md)
- 不通了先看这里：[references/troubleshooting.md](references/troubleshooting.md)
- 想让流量从别的国家出去：[references/egress-selection.md](references/egress-selection.md)

### 使用必读：

1. 本skill可以做到的：

   1. 让你的个人电脑无需安装 `strange software` 即可连接内网与外网
2. 本 skill 无法做到的：

   1. 不包含内网穿透等违反规定的方法，你在内网的流量仍然走公司官方的VPN，仍然受到严格的安全管理
   2. 不使用违反规定的方法让你访问外网，你的所有流量仍然受到公司监督，请不要访问奇奇怪怪的内容
3. 你需要的：

   1. 一台在 Office 网络下的电脑作为中继，该主机应该同时支持访问内网和外网，并且愿意或已经安装 `strange software`

### 快捷安装

快速安装，让你的 agent 帮你设置：

```bash
npx skills add yansumm/kill-pxa --skill kill-pxa -g -y
```

这条命令会把 skill 安装到当前用户的 agent 环境；想只装到当前项目时去掉 `-g`。需要 Node.js 22.20 或更高版本。

### 更多
- 在windows上卸载pxa可能用到的工具：
   - https://geekuninstaller.com/
   - https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns
   - https://learn.microsoft.com/en-us/sysinternals/downloads/pendmoves
