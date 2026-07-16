# 参与贡献

感谢参与 `luci-app-ModemATSD` 的维护。这个项目面向特定路由器和蜂窝模组，修改应优先保证可回退、可验证，并避免影响设备的蜂窝网络连接。

## 分支与提交

- `main` 只保留已经验证、能够进入固件构建的稳定版本。
- 新功能使用 `feature/<name>` 分支。
- 问题修复使用 `fix/<name>` 分支。
- 一个提交尽量只解决一个问题，提交信息建议使用：

```text
feat(modem): add ...
fix(sms): repair ...
fix(traffic): correct ...
docs: update ...
```

## 开发流程

```sh
git switch main
git pull --ff-only
git switch -c fix/example

# 修改并测试
python3 -m unittest tests/test_sms_pdu_AK68.py

git add .
git commit -m "fix(modem): describe the change"
git push -u origin fix/example
```

然后在 GitHub 创建 Pull Request。PR 中请说明：

- 使用的设备和模组型号；
- 问题现象和复现方式；
- 修改内容及兼容性影响；
- 已完成的测试；
- 是否会重启 AT 服务、网络接口或模组。

## 安全与隐私

禁止提交：

- 真实手机号、短信内容和验证码；
- PushPlus Token、登录凭据或 API 密钥；
- 路由器配置备份；
- IMEI、ICCID、IMSI 等设备或 SIM 标识；
- 未确认授权的第三方二进制文件。

测试应使用明显的合成数据。发布日志和截图也需要先完成脱敏。

## 硬件相关修改

修改以下目录时需要格外谨慎：

- `root/etc/init.d/`
- `root/usr/share/modem-AK68/`
- GPIO、LED、SIM 卡槽和网口相关脚本
- AT 指令及模组初始化流程

如果无法在全部设备上验证，请在 PR 中明确已测试和未测试的型号，不要假设不同硬件行为完全一致。

## 与固件仓库协作

本仓库是插件源码的唯一维护入口。ImmortalWrt 固件仓库通过 Git Submodule 固定使用某个提交。

插件 PR 合并后，再到固件仓库更新 Submodule 指针：

```sh
git submodule update --remote --merge package/luci-app-ModemATSD
git add package/luci-app-ModemATSD
git commit -m "luci-app-ModemATSD: update revision"
```

不要在固件仓库和独立仓库中分别维护两份不同的插件源码。
