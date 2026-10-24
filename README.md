English | [简体中文](README.zh-cn.md)

# Oh My L4D2Plugins

> **Disclaimer: This project is 100% AI slop. Don't use it if that bothers you.**

Each plugin is a complete, deployable directory — just merge its `left4dead2` folder into your game root directory.

| Plugin                                                 | Purpose                                                                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| [l4d2_ammo_display_fix](l4d2_ammo_display_fix)         | Lets the client HUD ammo counter display values above 1023 without truncation.                                                  |
| [l4d2_ammo_display_fix_ext](l4d2_ammo_display_fix_ext) | Uses the [sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) extension to let the client HUD ammo counter display values above 1023 without truncation. |
| [l4d2_csgo_ladders](l4d2_csgo_ladders)                 | Recreates CS:GO ladder climbing feel and speed on L4D2.                                                                         |
| [l4d2_team_airaccelerate](l4d2_team_airaccelerate)     | Independently set air acceleration (`sm_aa`) per player, per special infected class, and per team.                              |
| [l4d2_mhud](l4d2_mhud)                                 | A recreation of Sikarii's MovementHUD — uses the EMS HUD to show pressed keys and air speed on each player's own screen.                      |
| [l4d2_tactical_reload](l4d2_tactical_reload)           | Reloading before the magazine is empty gives you one extra round once full (tactical reload).                                    |

The [sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) extension used by `l4d2_ammo_display_fix_ext` was developed by [Crimson-DawnLight](https://github.com/Crimson-DawnLight) — thanks to him for turning the original plugin's code for modifying network bit widths and variable-length SendTables into a C++ extension.
