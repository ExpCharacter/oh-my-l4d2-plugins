#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <l4d2_tactical_reload>
#define PLUGIN_VERSION  "1.5.0"
#define CFG_FILE        "l4d2_tactical_reload_weapons.cfg"
#define AMMO_PILE       "weapon_ammo_spawn"
#define POLL_INTERVAL   0.05
#define SESSION_TIMEOUT 20.0
#define BUMP_TIMEOUT    8.0
#define PRESS_WINDOW    2.0
#define INCAP_MULTIPLY  1.25
#define MODE_NATIVE     0
#define MODE_CHAMBER    1
#define MODE_CSGO       2

enum struct WeaponCfg
{
	int enabled;
	int bonus;
	int reloadMs;
	int clipSize;
	int infinite;
	int shellFed;
}

enum struct AttrState
{
	int baseClip;
	int calcClip;
	int raisedClip;
	int users;
}

enum struct Session
{
	int ref;
	int clipBefore;
	int reserveBefore;
	int maxClip;
	int copies;
	int bonus;
	int limit;
	int shotsStart;
	int deliverShots;
	int chamberShots;
	int holdValue;
	int holdShots;
	bool tactical;
	bool infinite;
	bool shellFed;
	bool hold;
	bool started;
	float start;
}

ConVar g_cvEnable, g_cvFullClip, g_cvMode, g_cvDebug;
bool g_enable, g_fullClip, g_debug;
int g_mode;
StringMap g_cfg, g_attr;
Session g_sess[MAXPLAYERS + 1];
int g_shots[MAXPLAYERS + 1], g_gen[MAXPLAYERS + 1], g_pileReserve[MAXPLAYERS + 1];
bool g_attack[MAXPLAYERS + 1], g_reloadKey[MAXPLAYERS + 1], g_pressAttack[MAXPLAYERS + 1];
float g_pressTime[MAXPLAYERS + 1], g_bumpTime[MAXPLAYERS + 1];
char g_bumpClass[MAXPLAYERS + 1][64];
bool g_pollLive, g_late;

public Plugin myinfo =
{
	name = "L4D2 Tactical Reload", author = "ExpCharacter",
	description = "战术换弹：弹匣未打空时换弹，装填完成后每把枪 +1", version = PLUGIN_VERSION, url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("InfoEditor_SetString");
	if (GetEngineVersion() != Engine_Left4Dead2) { strcopy(error, err_max, "本插件仅支持 Left 4 Dead 2。"); return APLRes_SilentFailure; }
	g_late = late; return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_tactical_reload_enable", "1", "0=关闭, 1=开启", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvFullClip = CreateConVar("l4d2_tactical_reload_full_clip_reload", "1", "1=满弹匣按 R 也执行战术换弹, 0=保持原版", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMode = CreateConVar("l4d2_tactical_reload_mode", "1", "0=原生, 1=膛内留一发, 2=csgo 观感", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cvDebug = CreateConVar("l4d2_tactical_reload_debug", "0", "1=输出调试日志", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_tactical_reload");
	g_cvEnable.AddChangeHook(OnCvarChanged); g_cvFullClip.AddChangeHook(OnCvarChanged); g_cvMode.AddChangeHook(OnCvarChanged); g_cvDebug.AddChangeHook(OnCvarChanged);
	GetCvars();
	g_cfg = new StringMap(); g_attr = new StringMap();
	LoadConfig();
	AddCommandListener(Cmd_Reload, "+reload");
	HookEvent("weapon_reload", Event_WeaponReload, EventHookMode_Post); HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart);
	RegAdminCmd("sm_tactical_reload_reload", Cmd_ReloadConfig, ADMFLAG_CONFIG, "重新读取武器配置");
	if (g_late) { LateLoadWeapons(); HookPiles(); ApplyAllClips(); }
	StartPoll();
}

public void OnMapStart() { LoadConfig(); StartPoll(); HookPiles(); }
public void OnConfigsExecuted() { ApplyAllClips(); }
public void OnPluginEnd() { for (int client = 1; client <= MaxClients; client++) ReleaseAttr(client); }
public void OnMapEnd() { for (int client = 1; client <= MaxClients; client++) ResetClient(client); g_pollLive = false; }
public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars(); if (!g_enable) for (int client = 1; client <= MaxClients; client++) ResetClient(client);
}
void GetCvars() { g_enable = g_cvEnable.BoolValue; g_fullClip = g_cvFullClip.BoolValue; g_mode = g_cvMode.IntValue; g_debug = g_cvDebug.BoolValue; }
void Dbg(const char[] fmt, any...)
{
	if (!g_debug) return;
	char buffer[512]; VFormat(buffer, sizeof buffer, fmt, 2); LogMessage("%s", buffer);
}

void CfgPath(char[] path, int maxlen) { BuildPath(Path_SM, path, maxlen, "data/%s", CFG_FILE); }

void AddDefaultWeapon(KeyValues kv, const char[] name, int enabled, int bonus, float reloadTime)
{
	kv.JumpToKey(name, true);
	kv.SetNum("enabled", enabled); kv.SetNum("bonus", bonus);
	kv.SetFloat("reload_time", reloadTime);
	kv.GoBack();
}

bool CreateDefaultConfig(const char[] path)
{
	KeyValues kv = new KeyValues("Weapons");
	AddDefaultWeapon(kv, "weapon_pistol", 1, 1, 1.2);
	AddDefaultWeapon(kv, "weapon_pistol_dual", 1, 1, 1.75);
	AddDefaultWeapon(kv, "weapon_pistol_magnum", 1, 1, 1.18);
	AddDefaultWeapon(kv, "weapon_smg_mp5", 1, 1, 1.7);
	AddDefaultWeapon(kv, "weapon_smg", 1, 0, 1.04);
	AddDefaultWeapon(kv, "weapon_smg_silenced", 1, 0, 1.05);
	AddDefaultWeapon(kv, "weapon_rifle", 1, 1, 1.2);
	AddDefaultWeapon(kv, "weapon_rifle_ak47", 1, 1, 1.2);
	AddDefaultWeapon(kv, "weapon_rifle_desert", 1, 1, 1.8);
	AddDefaultWeapon(kv, "weapon_rifle_sg552", 1, 1, 1.6);
	AddDefaultWeapon(kv, "weapon_hunting_rifle", 1, 1, 2.6);
	AddDefaultWeapon(kv, "weapon_sniper_military", 1, 1, 1.8);
	AddDefaultWeapon(kv, "weapon_sniper_awp", 1, 1, 2.0);
	AddDefaultWeapon(kv, "weapon_sniper_scout", 1, 1, 1.45);
	AddDefaultWeapon(kv, "weapon_pumpshotgun", 1, 1, 0.0);
	AddDefaultWeapon(kv, "weapon_shotgun_chrome", 1, 1, 0.0);
	AddDefaultWeapon(kv, "weapon_shotgun_spas", 1, 1, 0.0);
	AddDefaultWeapon(kv, "weapon_autoshotgun", 1, 1, 0.0);
	AddDefaultWeapon(kv, "weapon_rifle_m60", 0, 0, 1.2);
	AddDefaultWeapon(kv, "weapon_grenade_launcher", 1, 0, 2.5);
	bool saved = kv.ExportToFile(path);
	delete kv;
	if (!saved) LogError("默认武器配置生成失败：%s", path);
	return saved;
}

bool LoadConfig()
{
	char path[PLATFORM_MAX_PATH]; CfgPath(path, sizeof path);
	if (!FileExists(path) && !CreateDefaultConfig(path)) return false;
	KeyValues kv = new KeyValues("Weapons");
	if (!kv.ImportFromFile(path)) { LogError("武器配置读取失败：%s", path); delete kv; return false; }
	StringMap cfg = new StringMap(); char key[64];
	if (kv.GotoFirstSubKey(false))
	{
		do
		{
			kv.GetSectionName(key, sizeof key);
			WeaponCfg w;
			w.enabled = kv.GetNum("enabled", 1); w.bonus = kv.GetNum("bonus", 1);
			w.reloadMs = RoundToNearest(kv.GetFloat("reload_time", 0.0) * 1000.0);
			w.clipSize = kv.GetNum("clip_size", 0); w.infinite = kv.GetNum("infinite_reserve", -1);
			w.shellFed = kv.GetNum("shell_fed", -1);
			cfg.SetArray(key, w, sizeof w);
		}
		while (kv.GotoNextKey(false));
	}
	delete kv;
	delete g_cfg;
	g_cfg = cfg;
	ApplyAllClips();
	return true;
}

public Action Cmd_ReloadConfig(int client, int args)
{
	ReplyToCommand(client, "[l4d2_tactical_reload] 武器配置%s。", LoadConfig() ? "已重新加载" : "加载失败");
	return Plugin_Handled;
}

bool GetClassCfg(const char[] className, WeaponCfg w)
{
	char dual[80]; FormatEx(dual, sizeof dual, "%s_dual", className);
	if (g_cfg.GetArray(dual, w, sizeof w)) return true;
	return g_cfg.GetArray(className, w, sizeof w);
}
bool IsEnabled(const char[] className, bool dual)
{
	WeaponCfg w; char key[80]; strcopy(key, sizeof key, className);
	if (dual) FormatEx(key, sizeof key, "%s_dual", className);
	if (g_cfg.GetArray(key, w, sizeof w)) return w.enabled != 0;
	return dual && g_cfg.GetArray(className, w, sizeof w) && w.enabled != 0;
}
int GetBonus(const char[] className)
{
	WeaponCfg w; return GetClassCfg(className, w) && w.bonus != 0 ? 1 : 0;
}
bool IsInfinite(const char[] className)
{
	WeaponCfg w;
	if (GetClassCfg(className, w) && w.infinite >= 0) return w.infinite != 0;
	return L4D2_GetIntWeaponAttribute(className, L4D2IWA_WeaponType) == view_as<int>(WEAPONTYPE_PISTOL);
}
bool IsShellFed(const char[] className)
{
	WeaponCfg w;
	if (GetClassCfg(className, w) && w.shellFed >= 0) return w.shellFed != 0;
	return L4D2_GetIntWeaponAttribute(className, L4D2IWA_WeaponType) == view_as<int>(WEAPONTYPE_SHOTGUN);
}
float ReloadSeconds(const char[] className, int weapon, int client)
{
	char key[80]; strcopy(key, sizeof key, className);
	if (IsDual(weapon)) FormatEx(key, sizeof key, "%s_dual", className);
	WeaponCfg w;
	if (!g_cfg.GetArray(key, w, sizeof w) || w.reloadMs <= 0) return 0.0;
	float seconds = w.reloadMs / 1000.0;
	if (L4D2_GetIntWeaponAttribute(className, L4D2IWA_WeaponType) == view_as<int>(WEAPONTYPE_PISTOL)
		&& GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0) seconds *= INCAP_MULTIPLY;
	return seconds;
}

int GetConfiguredClip(const char[] className)
{
	WeaponCfg w;
	if (g_cfg.GetArray(className, w, sizeof w) && w.clipSize > 0) return w.clipSize;
	char dual[80]; FormatEx(dual, sizeof dual, "%s_dual", className);
	if (g_cfg.GetArray(dual, w, sizeof w)) return w.clipSize;
	return 0;
}
void ApplyClip(const char[] className)
{
	int configured = GetConfiguredClip(className);
	if (configured <= 0 || !L4D_HasMapStarted() || !L4D2_IsValidWeapon(className)) return;
	AttrState a;
	if (g_attr.GetArray(className, a, sizeof a) && a.users > 0) return;
	if (L4D2_GetIntWeaponAttribute(className, L4D2IWA_ClipSize) != configured) L4D2_SetIntWeaponAttribute(className, L4D2IWA_ClipSize, configured);
}
void ApplyAllClips()
{
	StringMapSnapshot snap = g_cfg.Snapshot(); char key[64];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof key);
		int len = strlen(key);
		if (len <= 5 || strcmp(key[len - 5], "_dual") != 0) ApplyClip(key);
	}
	delete snap;
}
public void OnGetWeaponsInfo(int pThis, const char[] className)
{
	int configured = GetConfiguredClip(className);
	if (configured <= 0 || GetFeatureStatus(FeatureType_Native, "InfoEditor_SetString") != FeatureStatus_Available) return;
	char value[16]; IntToString(configured, value, sizeof value); InfoEditor_SetString(pThis, "clip_size", value);
}
int ClipSize(const char[] className)
{
	AttrState a; if (g_attr.GetArray(className, a, sizeof a) && a.users > 0) return a.calcClip;
	return L4D2_GetIntWeaponAttribute(className, L4D2IWA_ClipSize);
}
void BumpAttr(int client, const char[] className, int baseClip)
{
	int bonus = GetBonus(className);
	if (bonus <= 0) return;
	if (g_bumpClass[client][0] != 0 && StrEqual(g_bumpClass[client], className)) { g_bumpTime[client] = GetGameTime(); return; }
	if (g_bumpClass[client][0] != 0) ReleaseAttr(client);
	AttrState a;
	if (!g_attr.GetArray(className, a, sizeof a)) { a.baseClip = 0; a.calcClip = 0; a.raisedClip = 0; a.users = 0; }
	if (a.users == 0)
	{
		a.baseClip = L4D2_GetIntWeaponAttribute(className, L4D2IWA_ClipSize); a.calcClip = baseClip;
		a.raisedClip = baseClip + bonus; L4D2_SetIntWeaponAttribute(className, L4D2IWA_ClipSize, a.raisedClip);
	}
	a.users++; g_attr.SetArray(className, a, sizeof a);
	strcopy(g_bumpClass[client], sizeof g_bumpClass[], className); g_bumpTime[client] = GetGameTime();
	Dbg("%N 抬高弹容：%s %d -> %d（%d 人）", client, className, a.baseClip, a.raisedClip, a.users);
}
void ReleaseAttr(int client)
{
	if (g_bumpClass[client][0] == 0) return;
	char className[64]; strcopy(className, sizeof className, g_bumpClass[client]); g_bumpClass[client][0] = 0;
	AttrState a;
	if (!g_attr.GetArray(className, a, sizeof a) || a.users <= 0) return;
	if (--a.users > 0) { g_attr.SetArray(className, a, sizeof a); return; }
	L4D2_SetIntWeaponAttribute(className, L4D2IWA_ClipSize, a.baseClip); g_attr.Remove(className); ApplyClip(className);
}

bool IsAlive(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client);
}
bool IsDual(int weapon)
{
	return HasEntProp(weapon, Prop_Send, "m_isDualWielding") && GetEntProp(weapon, Prop_Send, "m_isDualWielding") != 0;
}
bool IsTracked(int weapon)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon)) return false;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	return IsEnabled(className, IsDual(weapon));
}
int ActiveWeapon(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"); return IsTracked(weapon) ? weapon : -1;
}
int GetWeaponClip(int weapon) { return GetEntProp(weapon, Prop_Send, "m_iClip1"); }
void SetWeaponClip(int weapon, int clip) { SetEntProp(weapon, Prop_Send, "m_iClip1", clip); }
int LoadRounds(int client, int weapon, int want, bool free, bool strict, bool setClip)
{
	if (want <= 0) return 0;
	if (!free)
	{
		int reserve = L4D_GetReserveAmmo(client, weapon);
		if (reserve < want) { if (strict) return 0; want = reserve; }
		if (want <= 0) return 0;
		L4D_SetReserveAmmo(client, weapon, reserve - want);
	}
	SetWeaponClip(weapon, setClip ? want : GetWeaponClip(weapon) + want);
	return want;
}
int ShotsSince(int client, int mark)
{
	if (mark < 0) return 0;
	int diff = g_shots[client] - mark; return diff > 0 ? diff : 0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, AMMO_PILE)) { HookPile(entity); return; }
	if (classname[0] == 'w' && strncmp(classname, "weapon_", 7) == 0) RequestFrame(Frame_HookWeapon, EntIndexToEntRef(entity));
}
public void Frame_HookWeapon(int ref)
{
	int weapon = EntRefToEntIndex(ref);
	if (weapon == INVALID_ENT_REFERENCE) return;
	if (HasEntProp(weapon, Prop_Send, "m_bInReload")) SDKHook(weapon, SDKHook_Reload, OnReloadPre);
}
void LateLoadWeapons()
{
	int entity = INVALID_ENT_REFERENCE;
	while ((entity = FindEntityByClassname(entity, "weapon_*")) != INVALID_ENT_REFERENCE)
		if (HasEntProp(entity, Prop_Send, "m_bInReload")) SDKHook(entity, SDKHook_Reload, OnReloadPre);
}

public Action OnReloadPre(int weapon)
{
	if (!g_enable) return Plugin_Continue;
	int client = GetEntPropEnt(weapon, Prop_Data, "m_hOwnerEntity");
	if (!IsAlive(client) || !IsTracked(weapon)) return Plugin_Continue;
	if (ShouldBlock(client, weapon)) { g_pressTime[client] = 0.0; return Plugin_Handled; }
	if (g_sess[client].ref == EntIndexToEntRef(weapon)) return Plugin_Continue;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	int maxClip = ClipSize(className);
	if (maxClip <= 0) return Plugin_Continue;
	int copies = IsDual(weapon) ? 2 : 1; int clip = GetWeaponClip(weapon);
	int full = maxClip * copies; bool press = g_pressTime[client] > 0.0 && GetGameTime() - g_pressTime[client] <= PRESS_WINDOW;
	bool tactical = clip > 0 && (clip != full || (press && !g_pressAttack[client]));
	g_pressTime[client] = 0.0;
	g_sess[client].ref = EntIndexToEntRef(weapon); g_sess[client].clipBefore = clip; g_sess[client].maxClip = maxClip;
	g_sess[client].copies = copies; g_sess[client].bonus = GetBonus(className); g_sess[client].limit = (maxClip + g_sess[client].bonus) * copies;
	g_sess[client].shotsStart = g_shots[client]; g_sess[client].deliverShots = -1; g_sess[client].chamberShots = -1;
	g_sess[client].holdValue = 0; g_sess[client].holdShots = g_shots[client]; g_sess[client].tactical = tactical;
	g_sess[client].infinite = IsInfinite(className); g_sess[client].shellFed = IsShellFed(className); g_sess[client].hold = false; g_sess[client].started = false;
	g_sess[client].start = GetGameTime(); g_sess[client].reserveBefore = g_sess[client].infinite ? -1 : L4D_GetReserveAmmo(client, weapon);
	if (tactical) BumpAttr(client, className, maxClip);
	Dbg("%N 起手：%s 弹匣=%d/%d 战术=%d", client, className, clip, full, tactical);
	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
	int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	g_attack[client] = (buttons & IN_ATTACK) != 0; bool down = (buttons & IN_RELOAD) != 0;
	if (down && !g_reloadKey[client])
	{
		g_pressTime[client] = GetGameTime(); g_pressAttack[client] = g_attack[client]; TryFullPress(client);
	}
	if (down && ShouldBlock(client, weapon)) { buttons &= ~IN_RELOAD; g_pressTime[client] = 0.0; }
	g_reloadKey[client] = down;
	return Plugin_Continue;
}
public Action Cmd_Reload(int client, const char[] command, int argc)
{
	if (client < 1 || client > MaxClients) return Plugin_Continue;
	if (ShouldBlock(client, -1)) return Plugin_Handled;
	if (g_pressTime[client] == 0.0) { g_pressTime[client] = GetGameTime(); g_pressAttack[client] = g_attack[client]; }
	TryFullPress(client);
	return Plugin_Continue;
}
bool IsFiring(int client)
{
	if (g_pressTime[client] > 0.0 && GetGameTime() - g_pressTime[client] <= PRESS_WINDOW) return g_pressAttack[client];
	return g_attack[client];
}
void TryFullPress(int client)
{
	if (!g_enable || !g_fullClip || !IsAlive(client)) return;
	int weapon = ActiveWeapon(client);
	if (weapon == -1) return;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	int maxClip = ClipSize(className);
	if (GetBonus(className) <= 0 || maxClip <= 0) return;
	int full = maxClip * (IsDual(weapon) ? 2 : 1);
	if (GetWeaponClip(weapon) != full) return;
	if (GetEntProp(weapon, Prop_Send, "m_bInReload") != 0 || IsFiring(client)) return;
	BumpAttr(client, className, maxClip);
}
bool ShouldBlock(int client, int weapon)
{
	if (!g_enable || !IsAlive(client)) return false;
	if (weapon <= MaxClients) weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!IsTracked(weapon)) return false;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	int bonus = GetBonus(className); int maxClip = ClipSize(className);
	if (bonus <= 0 || maxClip <= 0) return false;
	return GetWeaponClip(weapon) >= (maxClip + bonus) * (IsDual(weapon) ? 2 : 1);
}

void StartPoll()
{
	if (g_pollLive) return;
	CreateTimer(POLL_INTERVAL, Timer_Poll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE); g_pollLive = true;
}
public Action Timer_Poll(Handle timer)
{
	if (!g_enable) return Plugin_Continue;
	for (int client = 1; client <= MaxClients; client++) PollClient(client);
	return Plugin_Continue;
}
void PollClient(int client)
{
	if (!IsAlive(client)) { ResetClient(client); return; }
	if (g_sess[client].ref == INVALID_ENT_REFERENCE)
	{
		if (g_bumpClass[client][0] != 0 && GetGameTime() - g_bumpTime[client] > BUMP_TIMEOUT) ReleaseAttr(client);
		return;
	}
	int weapon = EntRefToEntIndex(g_sess[client].ref);
	if (weapon == INVALID_ENT_REFERENCE || GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon) { EndSession(client, false); return; }
	if (GetEntProp(weapon, Prop_Send, "m_bInReload") == 0)
	{
		if (g_sess[client].started || GetGameTime() - g_sess[client].start > 1.0) EndSession(client, g_sess[client].started);
		return;
	}
	g_sess[client].started = true;
	MaintainDisplay(client, weapon);
	if (g_sess[client].tactical && g_sess[client].deliverShots < 0 && GetWeaponClip(weapon) >= g_sess[client].limit)
		g_sess[client].deliverShots = g_shots[client];
	MaintainHold(client, weapon);
	if (GetGameTime() - g_sess[client].start > SESSION_TIMEOUT) EndSession(client, false);
}
void MaintainDisplay(int client, int weapon)
{
	if (g_sess[client].clipBefore <= 0 || g_sess[client].hold || g_mode == MODE_NATIVE) return;
	int clip = GetWeaponClip(weapon); int display;
	if (g_mode == MODE_CHAMBER)
	{
		if (g_sess[client].bonus <= 0 || g_sess[client].shellFed) return;
		display = g_sess[client].copies - ShotsSince(client, g_sess[client].chamberShots);
		if (g_sess[client].infinite) { if (clip != display) SetWeaponClip(weapon, display); }
		else
		{
			if (clip != 0 || display <= 0) return;
			if (LoadRounds(client, weapon, display, false, true, true) <= 0) return;
		}
		g_sess[client].chamberShots = g_shots[client]; return;
	}
	display = g_sess[client].clipBefore - ShotsSince(client, g_sess[client].shotsStart);
	if (display > clip) LoadRounds(client, weapon, display - clip, g_sess[client].infinite, true, false);
}
void MaintainHold(int client, int weapon)
{
	if (!g_sess[client].hold) return;
	int spent = ShotsSince(client, g_sess[client].holdShots);
	if (spent > 0)
	{
		g_sess[client].holdValue = g_sess[client].holdValue > spent ? g_sess[client].holdValue - spent : 0;
		g_sess[client].holdShots = g_shots[client];
	}
	if (GetWeaponClip(weapon) != g_sess[client].holdValue) SetWeaponClip(weapon, g_sess[client].holdValue);
}
void EndSession(int client, bool settle)
{
	ReleaseAttr(client);
	if (settle)
	{
		int weapon = EntRefToEntIndex(g_sess[client].ref); int clip = GetWeaponClip(weapon);
		int full = g_sess[client].maxClip * g_sess[client].copies;
		if (g_sess[client].tactical && clip >= full)
		{
			int cap = g_sess[client].limit - ShotsSince(client, g_sess[client].deliverShots); int add = cap - clip;
			if (add > g_sess[client].bonus * g_sess[client].copies) add = g_sess[client].bonus * g_sess[client].copies;
			if (add > 0) { LoadRounds(client, weapon, add, g_sess[client].infinite, false, false); clip = GetWeaponClip(weapon); }
			if (!g_sess[client].infinite && g_sess[client].reserveBefore >= 0)
			{
				int charged = g_sess[client].reserveBefore - L4D_GetReserveAmmo(client, weapon);
				int expected = clip - g_sess[client].clipBefore + ShotsSince(client, g_sess[client].shotsStart);
				if (charged > expected) L4D_SetReserveAmmo(client, weapon, g_sess[client].reserveBefore - expected);
			}
		}
	}
	ClearSession(client);
}
void ClearSession(int client)
{
	g_sess[client].ref = INVALID_ENT_REFERENCE; g_sess[client].tactical = false; g_sess[client].hold = false;
	g_sess[client].deliverShots = -1; g_sess[client].chamberShots = -1;
}
void ResetClient(int client)
{
	ReleaseAttr(client); ClearSession(client);
	g_pressTime[client] = 0.0; g_pressAttack[client] = false; g_attack[client] = false; g_reloadKey[client] = false;
}

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_enable || g_mode != MODE_CSGO) return;
	int client = GetClientOfUserId(event.GetInt("userid")); if (!IsAlive(client)) return;
	int weapon = ActiveWeapon(client); if (weapon == -1) return;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	float seconds = ReloadSeconds(className, weapon, client);
	if (seconds <= 0.0) return;
	g_gen[client]++;
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client)); dp.WriteCell(EntIndexToEntRef(weapon)); dp.WriteCell(g_gen[client]);
	CreateTimer(seconds, Timer_Refill, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}
public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients) return;
	g_shots[client]++;
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (g_sess[client].tactical && weapon > MaxClients && EntIndexToEntRef(weapon) == g_sess[client].ref
		&& GetWeaponClip(weapon) >= g_sess[client].limit
		&& (g_sess[client].deliverShots < 0 || g_sess[client].deliverShots > g_shots[client] - 1))
		g_sess[client].deliverShots = g_shots[client] - 1;
}
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int client = 1; client <= MaxClients; client++) { g_gen[client]++; g_sess[client].hold = false; }
}
public Action Timer_Refill(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell()); int ref = dp.ReadCell(); int gen = dp.ReadCell();
	if (!g_enable || g_mode != MODE_CSGO || !IsAlive(client) || g_gen[client] != gen) return Plugin_Continue;
	int weapon = EntRefToEntIndex(ref);
	if (g_sess[client].ref != ref || weapon == INVALID_ENT_REFERENCE || GetEntProp(weapon, Prop_Send, "m_bInReload") == 0) return Plugin_Continue;
	int target = g_sess[client].tactical ? g_sess[client].limit : g_sess[client].maxClip * g_sess[client].copies;
	int clip = GetWeaponClip(weapon);
	if (clip >= target) return Plugin_Continue;
	int achieved = clip + LoadRounds(client, weapon, target - clip, g_sess[client].infinite, false, false);
	g_sess[client].hold = true; g_sess[client].holdValue = achieved; g_sess[client].holdShots = g_shots[client];
	Dbg("%N 定时回填：弹匣 %d -> %d", client, clip, achieved);
	return Plugin_Continue;
}

void HookPile(int entity)
{
	SDKHook(entity, SDKHook_Use, OnPileUse); SDKHook(entity, SDKHook_UsePost, OnPileUsePost);
}
void HookPiles()
{
	int entity = INVALID_ENT_REFERENCE;
	while ((entity = FindEntityByClassname(entity, AMMO_PILE)) != INVALID_ENT_REFERENCE) HookPile(entity);
}
public Action OnPileUse(int entity, int activator, int caller, UseType type, float value)
{
	if (IsAlive(activator)) { int weapon = ActiveWeapon(activator); g_pileReserve[activator] = weapon == -1 ? -1 : L4D_GetReserveAmmo(activator, weapon); }
	return Plugin_Continue;
}
public void OnPileUsePost(int entity, int activator, int caller, UseType type, float value)
{
	if (!g_enable || !IsAlive(activator) || g_sess[activator].tactical) return;
	int weapon = ActiveWeapon(activator);
	if (weapon == -1 || GetEntProp(weapon, Prop_Send, "m_bInReload") != 0) return;
	char className[64]; GetEntityClassname(weapon, className, sizeof className);
	int maxClip = ClipSize(className); int bonus = GetBonus(className); int copies = IsDual(weapon) ? 2 : 1;
	if (maxClip <= 0 || bonus <= 0 || IsInfinite(className)) return;
	int extra = GetWeaponClip(weapon) - maxClip * copies;
	if (extra <= 0 || extra > bonus * copies) return;
	int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"); if (ammoType < 0) return;
	int capMax = AmmoDef.MaxCarry(ammoType); int reserve = L4D_GetReserveAmmo(activator, weapon);
	if (capMax <= 0 || reserve >= capMax || capMax - reserve > extra) return;
	bool nativePickup = reserve > g_pileReserve[activator];
	if (GivePlayerAmmo(activator, capMax - reserve, ammoType, nativePickup) <= 0) return;
	if (!nativePickup) { Event pickup = CreateEvent("ammo_pickup"); pickup.SetInt("userid", GetClientUserId(activator)); pickup.Fire(); }
	Dbg("%N 弹药堆补齐：%s 后备 %d -> %d", activator, className, reserve, capMax);
}
