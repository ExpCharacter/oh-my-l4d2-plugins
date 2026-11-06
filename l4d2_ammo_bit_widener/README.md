English | [简体中文](README.zh-cn.md)

# l4d2_ammo_bit_widener

Breaks through the vanilla limits so the client HUD can display reserve ammo above 1023 and clip ammo above 255 (up to 65535).

## Important

- Tested on: **SourceMod 1.11.6964** and **1.12.7210** — works fine; **1.13** and above are untested.
- **Hot-load compatible**: when manually loaded while the server is running, it only takes effect after a map change, to prevent modifying the **SendTable** mid-game from causing a data format mismatch between client and server, which would crash clients. It is still recommended to load it at server startup rather than hot-loading.
