# luci-app-zmodem-AK68

## 2.9-r17

- 使用 Python PDU 解码器替换旧的闭源解码程序，正确解析 UCS2、GSM 7-bit 和短信时间。
- 自动合并长短信分段，不再显示 `Reference number`、`SMS segment` 或错误的 `x0A` 发件人。
- 修复短信转发偶发空内容、空发件人和异常时间的问题。
- 短信删除改为受限的 POST 操作，不再执行页面传入的 shell 命令。

### RM520N网络AT的OpenWRT控制
### 适用于鲲鹏C8-660/668/650/AK68设备 RM520N-CN模组
### By Manper 20241102
