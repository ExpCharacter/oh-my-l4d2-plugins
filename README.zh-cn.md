[English](README.md) | 简体中文

# Oh My L4D2Plugins

> **声明：本项目百分百 AI slop，介意勿用。**

各插件均为完整可部署目录，直接把其中的 `left4dead2` 文件夹覆盖到游戏根目录即可。

| 插件                                                           | 用途                                                                                                                                        |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| [l4d2_ammo_bit_widener](l4d2_ammo_bit_widener)               | 让客户端 HUD 备弹超过 1023、弹匣超过 255 时正常显示而不被截断。                                                                                                   |
| [l4d2_ammo_bit_widener_ext](l4d2_ammo_bit_widener_ext)       | 使用 [sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) 扩展让客户端 HUD 备弹超过 1023、弹匣超过 255 时正常显示而不被截断。 |
| [l4d2_csgo_ladders](l4d2_csgo_ladders)                       | 在 L4D2 上复刻 CS:GO 的梯子攀爬手感与速度。                                                                                                              |
| [l4d2_team_airaccelerate](l4d2_team_airaccelerate)           | 按玩家、特感种类、队伍三层独立设置空速（`sm_aa`）。                                                                                                             |
| [l4d2_mhud](l4d2_mhud)                                       | 复刻自 Sikarii 的 MovementHUD，用 EMS HUD 在各自玩家屏幕上显示对应按键与空速。                                                                                    |
| [l4d2_mhud_sendproxy3](l4d2_mhud_sendproxy3)                 | `l4d2_mhud` 的 SendProxy 3 版本。                                                                                                             |
| [l4d2_colorcorrection_control](l4d2_colorcorrection_control) | 使用 [sendproxy](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendproxy) 扩展让玩家通过 `!cc` 独立开关地图自带的色彩修正滤镜。            |
| [l4d2_tactical_reload](l4d2_tactical_reload)                 | 弹匣没打空就换弹时，装满后可多一发（战术换弹）。                                                                                                                  |

`l4d2_ammo_bit_widener_ext` 使用的 [sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) 扩展由 [Crimson-DawnLight](https://github.com/Crimson-DawnLight) 开发，感谢他将原始插件中处理网络位宽与变长 SendTable 的代码做成 C++ 扩展