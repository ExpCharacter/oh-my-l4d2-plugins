#if defined _l4d2_tactical_reload_included
    #endinput
#endif
#define _l4d2_tactical_reload_included

// 本插件内部使用的可选 Info Editor 接口，不是本插件对外提供的 API。
// native/forward 名称须与 Info Editor 一致；可选性由主插件标记和检查。

/** 设置 OnGetWeaponsInfo 提供的武器 KeyValues；本插件仅用于 clip_size。 */
native void InfoEditor_SetString(int pThis, const char[] keyname, const char[] value, bool create = false);

/** 武器数据解析回调，由 Info Editor 提供。 */
forward void OnGetWeaponsInfo(int pThis, const char[] classname);
