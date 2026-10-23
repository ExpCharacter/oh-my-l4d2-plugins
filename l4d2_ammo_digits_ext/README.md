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
- **热加载兼容：**运行中手动加载要等换图才生效，防止中途修改**SendTable**导致客户端与服务器的数据格式不一致，进而引发客户端崩溃。仍建议跟随服务器启动，不要热加载。
