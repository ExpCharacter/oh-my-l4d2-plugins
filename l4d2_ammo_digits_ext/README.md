# l4d2_ammo_digits_ext

让客户端 HUD 正常显示超过 1023 的弹药数，最高支持 65535。

## 特别感谢

[sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) 扩展由 **Crimson-DawnLight** 开发。

原始版本大量代码处理修改弹药数据的网络位宽和处理变长后的SendTable数据。感谢他把这些功能做成 C++ 扩展，现在通过native接口调用，大幅精简了代码。

## 安装

把 `left4dead2` 文件夹直接合并到游戏根目录，或者单独将文件放在以下位置：

| 文件                                       | 位置                                    |
| ---------------------------------------- | ------------------------------------- |
| `sendtable.ext.dll` / `sendtable.ext.so` | `addons/sourcemod/extensions/`        |
| `sendtable.inc`                          | `addons/sourcemod/scripting/include/` |
| `l4d2_ammo_digits_ext.smx`               | `addons/sourcemod/plugins/`           |

## 重要

- 仅支持 SourceMod **1.12**，不支持 **1.13 及以上版本**。
- 无法热加载，必须重启服务器。
