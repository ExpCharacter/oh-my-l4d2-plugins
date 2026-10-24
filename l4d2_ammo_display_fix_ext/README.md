English | [简体中文](README.zh-cn.md)

# l4d2_ammo_display_fix_ext

Lets the client HUD correctly display ammo counts above 1023, up to 65535.

## Special Thanks

The [sendtable](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable) extension was developed by **Crimson-DawnLight**.

The original version contained large amounts of code for modifying the network bit width of ammo data and handling the lengthened SendTable data. Thanks to him for making these features into a C++ extension — they are now called through native interfaces, greatly slimming down the code.

## Installation

Merge the `left4dead2` folder directly into your game root directory, or place the files at the following locations individually:

| File                                     | Location                              |
| ---------------------------------------- | ------------------------------------- |
| `sendtable.ext.dll` / `sendtable.ext.so` | `addons/sourcemod/extensions/`        |
| `sendtable.inc`                          | `addons/sourcemod/scripting/include/` |
| `l4d2_ammo_display_fix_ext.smx`               | `addons/sourcemod/plugins/`           |

## Important

- Only supports SourceMod **1.12**; **1.13 and above are not supported**.
- **Hot-load compatible**: when manually loaded while the server is running, it only takes effect after a map change, to prevent modifying the **SendTable** mid-game from causing a data format mismatch between client and server, which would crash clients. It is still recommended to load it at server startup rather than hot-loading.
