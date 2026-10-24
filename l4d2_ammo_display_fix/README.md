English | [简体中文](README.zh-cn.md)

# l4d2_ammo_display_fix

Breaks through the vanilla limit so the client HUD ammo counter can display values above 1023.

## Important

- Tested on: **SourceMod 1.11.6964** and **1.12.7210** — works fine; **1.13** and above are untested.
- **Hot-load compatible**: when manually loaded while the server is running, it only takes effect after a map change, to prevent modifying the **SendTable** mid-game from causing a data format mismatch between client and server, which would crash clients. It is still recommended to load it at server startup rather than hot-loading.
