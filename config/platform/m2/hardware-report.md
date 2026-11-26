# M2 硬件验收报告格式（doctor 消费契约）

`verify-hardware.sh --session-report` 在桌面会话里跑完全套硬件检查后，把结果
原子写入桌面用户的状态目录；`scripts/doctor` 读**最后一个非空行**给出三态结论。
本文件是生产者与消费者之间唯一的格式约定。

## 位置与写法定

| 项 | 值 |
|---|---|
| 生产者 | `config/platform/m2/verify-hardware.sh --session-report`（Umbriel 会话自启） |
| 身份 | 桌面用户 `ordo`（root 经 doas 跑 doctor 时按 `/home/*/.local/state` 定位） |
| 路径 | `${XDG_STATE_HOME:-$HOME/.local/state}/ordo/m2-hardware.log` |
| 权限 | `0600`；临时文件写完后 `mv` 原子替换，失败与超时也会落盘 |

## 内容

UTF-8 文本。前面是自由诊断（日期、内核、渲染器、NetworkManager/BlueZ 输出、
逐项 `通过/待验/异常`），**最后一个非空行**固定为：

```
exit=<0|1|2>
```

- `exit=0`：所有检查通过；
- `exit=1`：至少一项物理检查失败；
- `exit=2`：至少一项无法判定（缺工具、读不到日志等）—— **2 不等于通过**。

## 读取规则（doctor 三态）

1. 平台不是 `m2` / `m2-native`：不做这项检查（也不计 skip）。
2. 找不到报告、不可读、为空、最后一个非空行不匹配 `^exit=[012]$`：
   `skip`（最终 exit 2），提示「尚无 M2 硬件验收报告」，不得打勾。
3. `exit=0` → `ok`；`exit=1` → `bad`；`exit=2` → `skip`（最终 exit 2）。
4. 报告按用户隔离：doctor 以 root 运行时若定位不到桌面用户的报告，必须 `skip`
   （exit 2），不得把「读不到」当通过，也不得回退到 `/root` 的同名文件假装检查过。

消费者实现在 `scripts/doctor` 的「M2 硬件自检报告」段；`tests/m2_hardware_report.py`
既跑真实生产者输出，也直接执行 doctor 的这段判据（0/1/2 三态）。
