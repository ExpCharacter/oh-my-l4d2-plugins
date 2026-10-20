/*
 * l4d2_team_airaccelerate
 * Copyright (C) 2026 ExpCharacter
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
// Written with ChatGPT 6.1 sol high + deepseek flash.
// 空中加速度：运行时玩家覆盖 > 特感种类 > 队伍 > 原生。
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define VERSION "1.10.7"
#define GAMEDATA "l4d2_team_airaccelerate"
#define GAMEDATA_FUNC "l4d2_team_airaccelerate::CGameMovement::AirAccelerate"
#define CVAR_PREFIX "l4d2_airaccelerate_"
#define CMD_NAME "sm_aa"
#define PARAM_PTHIS 1
#define PARAM_WISHSPEED 3
#define PARAM_ACCEL 4
#define SETTING_ENABLE 9
#define CAMPS_BOTH -1

public Plugin myinfo =
{
    name = "L4D2 Team Air Accelerate",
    author = "ExpCharacter",
    description = "Per-player, class and team air acceleration overrides",
    version = VERSION,
    url = ""
};

char g_sKeys[][12] = {
	"survivor", "infected", "smoker", "boomer", "hunter", "spitter", "jockey", "charger", "tank", "enable"
};
char g_sDescriptions[][96] = {
	"生还者空速，-1 = 服务器全局空速", "特感空速，-1 = 服务器全局空速",
	"smoker空速，-1 = 服务器全局空速", "boomer空速，-1 = 服务器全局空速",
	"hunter空速，-1 = 服务器全局空速", "spitter空速，-1 = 服务器全局空速",
	"jockey空速，-1 = 服务器全局空速", "charger空速，-1 = 服务器全局空速",
	"tank空速，-1 = 服务器全局空速", "总开关 0 = 关闭，1 = 开启"
};
int g_iConfigOrder[] = { SETTING_ENABLE, 0, 1, 3, 7, 4, 6, 2, 5, 8 };
char g_sConfigPath[PLATFORM_MAX_PATH];
bool g_bOrderNewConfig;
char g_sSources[][8] = { "native", "runtime", "class", "team" };
int g_iClassCvar[] = { -1, 2, 3, 4, 5, 6, 7, -1, 8 };
ConVar g_cvSettings[10], g_cvGlobalAirAccel;
bool g_bDebug; // 调试日志开关：不注册 ConVar，避免出现在自动生成的 cfg 里。
Handle g_hDetour;
int g_iPlayerOffset;
StringMap g_hRun[2]; // 0 = 生还者，1 = 特感
char g_sSteamId[MAXPLAYERS + 1][20];
bool g_bHasSteamId[MAXPLAYERS + 1], g_bSyncValid[MAXPLAYERS + 1], g_bResyncPending;
float g_fSyncValue[MAXPLAYERS + 1], g_fLogLast[MAXPLAYERS + 1];

// 文案集中编辑，副本见 texts/PLAYER_TEXT.txt。
#define TXT_USAGE "[SM] sm_aa <target> [value]"
#define TXT_GET "[SM] 当前 %s 的空速为%s"
#define TXT_GET_GLOBAL "[SM] 当前 %s 的空速为服务器全局空速"
#define TXT_GET_PLAYER "[SM] 当前 %N 的空速为%s（%s）"
#define TXT_GET_PLAYER_ALL "[SM] 当前 %N 的空速：生还者=%s，特感=%s"
#define TXT_PLAYER_INHERIT "服务器全局空速"
#define TXT_SET "[SM] 已将 %s 的空速设置为%s"
#define TXT_SET_GLOBAL "[SM] 已将 %s 的空速设置为服务器全局空速"
#define TXT_SET_PLAYER "[SM] 已将 %N 的空速设置为%s（%s）"
#define TXT_SET_PLAYER_GLOBAL "[SM] 已将 %N 的空速设置为服务器全局空速（%s）"
#define TXT_TOGGLE_GET_ON "[SM] %s目前开启"
#define TXT_TOGGLE_GET_OFF "[SM] %s目前关闭"
#define TXT_TOGGLE_SET_ON "[SM] %s已开启"
#define TXT_TOGGLE_SET_OFF "[SM] %s已关闭"
#define TXT_NAME_ENABLE "自定义空速"
#define TXT_NAME_DEBUG "调试日志"
#define TXT_CAMP_ALL "全阵营"
#define TXT_CAMP_SURVIVOR "生还者"
#define TXT_CAMP_INFECTED "特感"
#define TXT_CLEARED "[SM] 已清除所有自定义空速"
#define TXT_NO_ACCESS "[SM] 该功能仅管理员可用"
#define TXT_ERR_PARAM "[SM] 参数错误"
#define TXT_ERR_TARGET "[SM] 未知参数或未找到该玩家"
#define TXT_ERR_NEED_CAMP "[SM] 请在玩家名后输入阵营(all/survivor/infected)"

char g_sCampNames[3][] = { TXT_CAMP_ALL, TXT_CAMP_SURVIVOR, TXT_CAMP_INFECTED }; // 索引 = camp + 1

public void OnPluginStart() {
	char name[48];
	for (int i = 0; i < sizeof(g_cvSettings); i++) {
		bool toggle = i >= SETTING_ENABLE;
		Format(name, sizeof(name), "%s%s", CVAR_PREFIX, g_sKeys[i]);
		g_cvSettings[i] = CreateConVar(name, i == SETTING_ENABLE ? "1" : (toggle ? "0" : "-1"),
			g_sDescriptions[i], FCVAR_NONE, toggle, 0.0, toggle, 1.0);
		g_cvSettings[i].AddChangeHook(OnSettingChanged);
	}
	g_cvGlobalAirAccel = FindConVar("sv_airaccelerate");
	g_cvGlobalAirAccel.AddChangeHook(OnSettingChanged);
	Handle conf = LoadGameConfigFile(GAMEDATA);
	if (conf == null) SetFailState("无法加载 gamedata：%s", GAMEDATA);
	g_iPlayerOffset = GameConfGetOffset(conf, "CGameMovement::PlayerPointerOffset");
	g_hDetour = DHookCreateFromConf(conf, GAMEDATA_FUNC);
	delete conf;
	if (g_iPlayerOffset <= 0 || g_hDetour == null) SetFailState("gamedata 缺少有效偏移或签名。");
	for (int i = 0; i < 2; i++) g_hRun[i] = new StringMap();
	RegConsoleCmd(CMD_NAME, Cmd_AirAccel, "空速设置：sm_aa <target> [value]");
	Format(g_sConfigPath, sizeof(g_sConfigPath), "cfg/sourcemod/%s.cfg", GAMEDATA);
	g_bOrderNewConfig = !FileExists(g_sConfigPath);
	AutoExecConfig(true, GAMEDATA); // 保留 SourceMod 标准生成，仅对新文件调整顺序。
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) OnClientPostAdminCheck(i);
	}
	if (!DHookEnableDetour(g_hDetour, false, OnAirAccelerate)) SetFailState("启用 AirAccelerate detour 失败。");
}

public void OnMapStart() {
	g_bOrderNewConfig = !FileExists(g_sConfigPath);
}

public void OnConfigsExecuted() {
	if (g_bOrderNewConfig) {
		g_bOrderNewConfig = false;
		OrderNewConfig();
	}
	ResyncAllClients();
}

// SourceMod 按名称排序；保留原始文件头和各项说明，只重排本次新建的文件。
void OrderNewConfig() {
	File file = OpenFile(g_sConfigPath, "rt");
	if (file == null) return;
	char header[512], line[256], block[1024], blocks[10][1024], name[48];
	file.ReadLine(header, sizeof(header));
	file.ReadLine(line, sizeof(line));
	StrCat(header, sizeof(header), line);
	int count;
	while (file.ReadLine(line, sizeof(line))) {
		StrCat(block, sizeof(block), line);
		if (strncmp(line, CVAR_PREFIX, strlen(CVAR_PREFIX)) != 0) continue;
		for (int i = 0; i < sizeof(g_cvSettings); i++) {
			g_cvSettings[i].GetName(name, sizeof(name));
			int len = strlen(name);
			if (strncmp(line, name, len) != 0 || line[len] != ' ') continue;
			char description[96];
			g_cvSettings[i].GetDescription(description, sizeof(description));
			ReplaceString(block, sizeof(block), description, g_sDescriptions[i]);
			strcopy(blocks[i], sizeof(blocks[]), block);
			count++;
			break;
		}
		block[0] = '\0';
	}
	delete file;
	if (count != sizeof(g_cvSettings)) {
		LogError("新 cfg 条目不完整，保留 SourceMod 原始顺序：%s", g_sConfigPath);
		return;
	}
	file = OpenFile(g_sConfigPath, "wt");
	if (file == null) return;
	file.WriteString(header, false);
	for (int i = 0; i < sizeof(g_iConfigOrder); i++) file.WriteString(blocks[g_iConfigOrder[i]], false);
	file.WriteLine("");
	delete file;
}

public void OnPluginEnd() {
	char value[32];
	g_cvGlobalAirAccel.GetString(value, sizeof(value));
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && !IsFakeClient(i)) SendConVarValue(i, g_cvGlobalAirAccel, value);
	}
	DHookDisableDetour(g_hDetour, false, OnAirAccelerate);
	delete g_hDetour;
}

public MRESReturn OnAirAccelerate(Handle hParams) {
	if (!g_cvSettings[SETTING_ENABLE].BoolValue) return MRES_Ignored;
	int client = DHookGetParamObjectPtrVar(hParams, PARAM_PTHIS, g_iPlayerOffset, ObjectValueType_CBaseEntityPtr);
	if (client < 1 || client > MaxClients || !IsClientInGame(client)) return MRES_Ignored;
	float value;
	int layer;
	bool overridden = ResolveAirAccel(client, value, layer);
	if (g_bDebug && GetGameTime() - g_fLogLast[client] >= 1.0) {
		g_fLogLast[client] = GetGameTime();
		float input = view_as<float>(DHookGetParam(hParams, PARAM_ACCEL));
		LogMessage("[airaccel] userid=%d team=%d source=%s in=%.4f out=%.4f",
			GetClientUserId(client), GetClientTeam(client), g_sSources[layer], input, overridden ? value : input);
	}
	if (!overridden) return MRES_Ignored;
	DHookSetParam(hParams, PARAM_ACCEL, value);
	return MRES_ChangedHandled;
}

// 候选按优先级排列，-1 跳过，0 有效；服务端和客户端共用。
bool ResolveAirAccel(int client, float &value, int &layer) {
	layer = 0;
	int camp = GetClientTeam(client) - 2;
	if (camp < 0 || camp > 1 || !IsPlayerAlive(client)) return false;
	float values[3] = { -1.0, -1.0, -1.0 };
	if (g_bHasSteamId[client])
		g_hRun[camp].GetValue(g_sSteamId[client], values[0]);
	if (camp == 1) {
		int cls = GetEntProp(client, Prop_Send, "m_zombieClass");
		if (cls >= 0 && cls < sizeof(g_iClassCvar) && g_iClassCvar[cls] >= 0)
			values[1] = g_cvSettings[g_iClassCvar[cls]].FloatValue;
	}
	values[2] = g_cvSettings[camp].FloatValue;
	for (int i = 0; i < sizeof(values); i++) {
		if (!Usable(values[i])) continue;
		value = values[i];
		layer = i + 1;
		return true;
	}
	return false;
}

void SyncClientAirAccel(int client, bool force = false) {
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	float value = g_cvGlobalAirAccel.FloatValue, custom;
	int layer;
	if (g_cvSettings[SETTING_ENABLE].BoolValue && ResolveAirAccel(client, custom, layer)) value = custom;
	if (!force && g_bSyncValid[client] && g_fSyncValue[client] == value) return;
	char text[32];
	FloatToString(value, text, sizeof(text));
	g_bSyncValid[client] = SendConVarValue(client, g_cvGlobalAirAccel, text);
	if (g_bSyncValid[client]) g_fSyncValue[client] = value;
	else LogError("向 %L 发送 sv_airaccelerate=%s 失败。", client, text);
}

public void OnClientPostAdminCheck(int client) {
	g_bHasSteamId[client] = !IsFakeClient(client)
		&& GetClientAuthId(client, AuthId_SteamID64, g_sSteamId[client], sizeof(g_sSteamId[]), true);
	SyncClientAirAccel(client, true);
}

public void OnClientDisconnect(int client) {
	g_bHasSteamId[client] = false;
	g_bSyncValid[client] = false;
	g_fLogLast[client] = -1.0;
}

// 统一覆盖换队、种类、存活与接管变化；只有最终值变化才发送。
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3]) {
	SyncClientAirAccel(client);
	return Plugin_Continue;
}

public void OnSettingChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (g_bResyncPending) return;
	g_bResyncPending = true;
	RequestFrame(Frame_ResyncAll); // 在引擎广播之后同步。
}

public void Frame_ResyncAll(any data) {
	g_bResyncPending = false;
	ResyncAllClients();
}

void ResyncAllClients() {
	for (int i = 1; i <= MaxClients; i++) SyncClientAirAccel(i, true);
}

bool Usable(float v) { return v >= 0.0 && v < 1.0e30; }

bool ParseValue(const char[] raw, float &value) {
	char text[64];
	strcopy(text, sizeof(text), raw);
	TrimString(text);
	return text[0] && StringToFloatEx(text, value) == strlen(text) && (value == -1.0 || Usable(value));
}

int FindKey(const char[] key, int count = sizeof(g_sKeys)) {
	for (int i = 0; i < count; i++) {
		if (StrEqual(key, g_sKeys[i], false)) return i;
	}
	return -1;
}

public Action Cmd_AirAccel(int client, int args) {
	if (client && !CheckCommandAccess(client, CMD_NAME, ADMFLAG_CONFIG, true)) {
		ReplyToCommand(client, TXT_NO_ACCESS);
		return Plugin_Handled;
	}
	char parts[8][64];
	int np = ReassembleArgs(args, parts, sizeof(parts));
	if (np == 0) ReplyToCommand(client, TXT_USAGE);
	else if (np > 3) ReplyToCommand(client, TXT_ERR_PARAM);
	else if (np == 1 && StrEqual(parts[0], "clear", false)) {
		int count = g_hRun[0].Size + g_hRun[1].Size;
		for (int i = 0; i < 2; i++) g_hRun[i].Clear();
		for (int i = 0; i < SETTING_ENABLE; i++) g_cvSettings[i].SetFloat(-1.0);
		ResyncAllClients();
		ReplyToCommand(client, TXT_CLEARED);
		LogAction(client, -1, "清除所有自定义空速（玩家覆盖 %d 项，阵营及种类恢复继承）", count);
	}
	else if (np == 3) {
		// 第二项：all = 全阵营；否则必须是 survivor / infected。
		int camp = CAMPS_BOTH;
		if (!StrEqual(parts[1], "all", false)) {
			camp = FindKey(parts[1], 2);
			if (camp < 0) {
				ReplyToCommand(client, TXT_ERR_PARAM);
				return Plugin_Handled;
			}
		}
		float value;
		if (!ParseValue(parts[2], value)) {
			ReplyToCommand(client, TXT_ERR_PARAM);
			return Plugin_Handled;
		}
		SetPlayerValue(client, parts[0], camp, value);
	}
	else if (StrEqual(parts[0], "debug", false)) {
		if (np == 1) ReplyToCommand(client, g_bDebug ? TXT_TOGGLE_GET_ON : TXT_TOGGLE_GET_OFF, TXT_NAME_DEBUG);
		else if (np == 2 && (StrEqual(parts[1], "0") || StrEqual(parts[1], "1"))) {
			g_bDebug = StrEqual(parts[1], "1");
			ReplyToCommand(client, g_bDebug ? TXT_TOGGLE_SET_ON : TXT_TOGGLE_SET_OFF, TXT_NAME_DEBUG);
			LogAction(client, -1, "空速 debug = %s", parts[1]);
		}
		else ReplyToCommand(client, TXT_ERR_PARAM);
	}
	else {
		int key = FindKey(parts[0]);
		if (key < 0 && np == 2) {
			int camp = FindKey(parts[1], 2);
			if (camp >= 0 || StrEqual(parts[1], "all", false)) ShowPlayerValue(client, parts[0], camp);
			else ReplyToCommand(client, IsPlayerArg(client, parts[0]) ? TXT_ERR_NEED_CAMP : TXT_ERR_TARGET);
		}
		else if (key < 0) ReplyToCommand(client, IsPlayerArg(client, parts[0]) ? TXT_ERR_NEED_CAMP : TXT_ERR_TARGET);
		else if (np == 1) ShowValue(client, key, parts[0]);
		else SetValue(client, key, parts[0], parts[1]);
	}
	return Plugin_Handled;
}

void ShowValue(int client, int key, const char[] name) {
	if (key >= SETTING_ENABLE) {
		ReplyToCommand(client, g_cvSettings[key].BoolValue ? TXT_TOGGLE_GET_ON : TXT_TOGGLE_GET_OFF,
			key == SETTING_ENABLE ? TXT_NAME_ENABLE : TXT_NAME_DEBUG);
		return;
	}
	float value = g_cvSettings[key].FloatValue;
	if (value < 0.0) {
		ReplyToCommand(client, TXT_GET_GLOBAL, name);
		return;
	}
	char text[32];
	FormatValue(value, text, sizeof(text));
	ReplyToCommand(client, TXT_GET, name, text);
}

void SetValue(int client, int key, const char[] name, const char[] raw) {
	if (key >= SETTING_ENABLE) {
		if (!StrEqual(raw, "0") && !StrEqual(raw, "1")) {
			ReplyToCommand(client, TXT_ERR_PARAM);
			return;
		}
		bool on = StrEqual(raw, "1");
		g_cvSettings[key].SetInt(on ? 1 : 0);
		ReplyToCommand(client, on ? TXT_TOGGLE_SET_ON : TXT_TOGGLE_SET_OFF,
			key == SETTING_ENABLE ? TXT_NAME_ENABLE : TXT_NAME_DEBUG);
	}
	else {
		float value;
		if (!ParseValue(raw, value)) {
			ReplyToCommand(client, TXT_ERR_PARAM);
			return;
		}
		g_cvSettings[key].SetFloat(value);
		if (value < 0.0) ReplyToCommand(client, TXT_SET_GLOBAL, name);
		else {
			char text[32];
			FormatValue(value, text, sizeof(text));
			ReplyToCommand(client, TXT_SET, name, text);
		}
	}
	LogAction(client, -1, "空速 %s = %s", name, raw);
}

// 第一参数不是键时，判断它是否匹配到在线玩家（用于提示补阵营或提示未知参数）。
bool IsPlayerArg(int client, const char[] arg) {
	int targets[MAXPLAYERS];
	char name[MAX_TARGET_LENGTH];
	bool multilingual;
	return ProcessTargetString(arg, client, targets, MAXPLAYERS,
		COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS, name, sizeof(name), multilingual) > 0;
}

// 整数不带小数，小数去掉尾随零。
void FormatValue(float value, char[] text, int size) {
	Format(text, size, "%.6f", value);
	int len = strlen(text);
	while (len > 1 && text[len - 1] == '0') len--;
	if (len > 1 && text[len - 1] == '.') len--;
	text[len] = 0;
}

void ShowPlayerValue(int client, const char[] target, int camp) {
	int targets[MAXPLAYERS], count, player;
	char name[MAX_TARGET_LENGTH], values[2][96];
	bool multilingual;
	float value;
	count = ProcessTargetString(target, client, targets, MAXPLAYERS,
		COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS, name, sizeof(name), multilingual);
	if (count <= 0) {
		ReplyToCommand(client, TXT_ERR_TARGET);
		return;
	}
	for (int i = 0; i < count; i++) {
		player = targets[i];
		if (!g_bHasSteamId[player]) {
			ReplyToCommand(client, TXT_ERR_TARGET);
			continue;
		}
		for (int c = 0; c < 2; c++) {
			if (camp != CAMPS_BOTH && camp != c) continue;
			if (g_hRun[c].GetValue(g_sSteamId[player], value)) FormatValue(value, values[c], sizeof(values[]));
			else strcopy(values[c], sizeof(values[]), TXT_PLAYER_INHERIT);
		}
		if (camp == CAMPS_BOTH) ReplyToCommand(client, TXT_GET_PLAYER_ALL, player, values[0], values[1]);
		else ReplyToCommand(client, TXT_GET_PLAYER, player, values[camp], g_sCampNames[camp + 1]);
	}
}

void SetPlayerValue(int client, const char[] target, int camp, float value) {
	int targets[MAXPLAYERS];
	char name[MAX_TARGET_LENGTH];
	bool multilingual;
	int count = ProcessTargetString(target, client, targets, MAXPLAYERS,
		COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_BOTS, name, sizeof(name), multilingual);
	if (count <= 0) {
		ReplyToCommand(client, TXT_ERR_TARGET);
		return;
	}
	char text[32];
	FormatValue(value, text, sizeof(text));
	for (int i = 0; i < count; i++) {
		int player = targets[i];
		if (!g_bHasSteamId[player]) {
			ReplyToCommand(client, TXT_ERR_TARGET);
			continue;
		}
		for (int c = 0; c < 2; c++) {
			if (camp != CAMPS_BOTH && camp != c) continue;
			if (value < 0.0) g_hRun[c].Remove(g_sSteamId[player]);
			else g_hRun[c].SetValue(g_sSteamId[player], value);
		}
		SyncClientAirAccel(player, true);
		if (value < 0.0) ReplyToCommand(client, TXT_SET_PLAYER_GLOBAL, player, g_sCampNames[camp + 1]);
		else ReplyToCommand(client, TXT_SET_PLAYER, player, text, g_sCampNames[camp + 1]);
		LogAction(client, player, "空速阵营=%d 值=%.4f", camp, value);
	}
}

int ReassembleArgs(int args, char parts[][64], int maxParts) {
	int np = 0;
	bool prevWasByte = false;
	for (int i = 1; i <= args && np < maxParts; i++) {
		char part[64];
		GetCmdArg(i, part, sizeof(part));
		bool isByte = strlen(part) == 1 && (part[0] & 0x80) != 0;
		if (np > 0 && isByte && prevWasByte) StrCat(parts[np - 1], sizeof(parts[]), part);
		else {
			strcopy(parts[np], sizeof(parts[]), part);
			np++;
		}
		prevWasByte = isByte;
	}
	return np;
}


