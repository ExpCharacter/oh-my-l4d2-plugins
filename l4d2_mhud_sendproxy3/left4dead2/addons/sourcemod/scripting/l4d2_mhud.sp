/*
 * l4d2_mhud
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
// EMS movement HUD using Crimson SendProxy 3.4.1 queued per-recipient overrides.
// https://github.com/Crimson-DawnLight/L4D2MutiMod/releases/tag/sendproxy-v3.4.2
// 来源说明：按键与速度显示参考／复刻 Sikarii 的 MovementHUD (MHUD)。
// Original project by Sikarii: https://github.com/Sikarii/movementhud

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <sendproxy>

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =
{
    name = "L4D2 Movement HUD (SendProxy 3)",
    author = "ExpCharacter",
    description = "Per-player movement HUD using EMS and SendProxy 3.4.1",
    version = PLUGIN_VERSION,
    url = "https://github.com/ExpCharacter/oh-my-l4d2-plugins"
};

#define HUD_SLOTS 9
#define HUD_DETAILS 7
#define HUD_MOUSE 8
#define HUD_MOUSE_SLOT 14
#define KEY_COUNT 6
#define HUD_TEXT 96
#define MOUSE_HOLD 0.10
#define MOVE_RATE 0.20
#define SPEED_WIDTH 0.24
#define SPEED_HEIGHT 0.12
#define KEY_WIDTH 0.04
#define KEY_HEIGHT 0.045
#define KEY_ROW_STEP 0.027
#define HUD_FLAG_NOBG (1 << 6)
#define HUD_FLAG_ALIGN_CENTER (1 << 9)
#define HUD_FLAG_TEXT (1 << 13)
#define HUD_FLAG_NOTVISIBLE (1 << 14)
#define HUD_BASE_FLAGS (HUD_FLAG_NOBG | HUD_FLAG_ALIGN_CENTER | HUD_FLAG_TEXT)
#define OPT_ENABLED (1 << 0)
#define OPT_DECIMAL (1 << 1)
#define OPT_TAKEOFF (1 << 2)
#define OPT_MOUSE (1 << 3)
#define OPT_BLANKS (1 << 4)
#define OPT_SPECTATE (1 << 6)
#define DEFAULT_OPTIONS (OPT_SPECTATE)
#define ADJUST_BLOCK (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_ATTACK | IN_ATTACK2 | IN_JUMP | IN_DUCK | IN_SPEED | IN_USE | IN_RELOAD)

enum
{
    MOVE_NONE,
    MOVE_NUMBER,
    MOVE_KEYS
};

static const char KEY_LABELS[][] = {"C", "W", "J", "A", "S", "D"};
static const int KEY_BUTTONS[] = {IN_DUCK, IN_FORWARD, IN_JUMP, IN_MOVELEFT, IN_BACK, IN_MOVERIGHT};
int g_Options[MAXPLAYERS + 1], g_Spacing[MAXPLAYERS + 1];
float g_NumberX[MAXPLAYERS + 1], g_NumberY[MAXPLAYERS + 1];
float g_KeysX[MAXPLAYERS + 1], g_KeysY[MAXPLAYERS + 1];
bool g_PrefsDirty[MAXPLAYERS + 1];
Cookie g_Prefs;
ConVar g_Refresh, g_Announce;
bool g_Ready, g_Conflict, g_MouseConflict;
int g_ProxyRef = INVALID_ENT_REFERENCE;

enum
{
    FIELD_FLAGS,
    FIELD_TEXT,
    FIELD_X,
    FIELD_Y,
    FIELD_WIDTH,
    FIELD_HEIGHT,
    HUD_FIELDS
};

static const char HUD_PROPS[][] = {"m_iScriptedHUDFlags", "m_szScriptedHUDStringSet", "m_fScriptedHUDPosX",
                                   "m_fScriptedHUDPosY",  "m_fScriptedHUDWidth",      "m_fScriptedHUDHeight"};
int g_Offsets[HUD_SLOTS][HUD_FIELDS], g_ModeOffset;
Address g_GameRulesPtr;
Handle g_InitTimer;
float g_NextConflictCheck, g_NextHud;
int g_Buttons[MAXPLAYERS + 1], g_Mouse[MAXPLAYERS + 1];
float g_MouseUntil[MAXPLAYERS + 1];
float g_Speed[MAXPLAYERS + 1], g_TakeoffSpeed[MAXPLAYERS + 1];
bool g_HaveTakeoff[MAXPLAYERS + 1], g_MotionSeen[MAXPLAYERS + 1], g_WasGround[MAXPLAYERS + 1];
MoveType g_LastMove[MAXPLAYERS + 1];
bool g_Visible[MAXPLAYERS + 1];
char g_Text[MAXPLAYERS + 1][HUD_SLOTS][HUD_TEXT];
int g_MoveTarget[MAXPLAYERS + 1], g_LastButtons[MAXPLAYERS + 1];
MoveType g_OldMove[MAXPLAYERS + 1];
float g_LockedAngles[MAXPLAYERS + 1][3];
bool g_SuppressAttack[MAXPLAYERS + 1];

public void OnPluginStart()
{
    GameData proxyData = new GameData("sendproxy");
    g_GameRulesPtr = proxyData.GetAddress("g_ppGameRules");
    delete proxyData;
    InitOffsets();
    CreateConVar("l4d2_mhud_version", PLUGIN_VERSION, "Movement HUD version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_Refresh = CreateConVar("l4d2_mhud_refresh_hz", "0", "HUD text rebuild limit in Hz; 0 = every server tick",
                             FCVAR_NONE, true, 0.0, true, 1000.0);
    g_Announce = CreateConVar("l4d2_mhud_announce", "1", "玩家进服后提示 !mhud 命令", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Prefs = new Cookie("l4d2_mhud_ems_v2", "Movement HUD layout and options", CookieAccess_Private);
    RegConsoleCmd("sm_mhud", Cmd_Menu, "Movement HUD 设置");
    RegConsoleCmd("sm_mhud_reset", Cmd_Reset, "恢复Movement HUD 默认布局");
    HookEvent("player_spawn", Event_ResetMotion);
    HookEvent("player_death", Event_ResetMotion);
    HookEvent("player_team", Event_ResetMotion);
    HookEvent("player_hurt", Event_CancelMove);
    AutoExecConfig(true, "l4d2_mhud");
    for (int client = 1; client <= MaxClients; client++)
    {
        ResetPrefs(client);
        ResetMotion(client);
        if (IsClientInGame(client) && AreClientCookiesCached(client))
            OnClientCookiesCached(client);
    }
}

public void OnMapStart()
{
    g_NextConflictCheck = 0.0;
    g_Conflict = false;
    for (int client = 1; client <= MaxClients; client++)
        ResetMotion(client);
    delete g_InitTimer;
    g_InitTimer = CreateTimer(0.25, Timer_Init, _, TIMER_REPEAT);
}

public Action Timer_Init(Handle timer)
{
    int proxy = FindEntityByClassname(-1, "terror_gamerules");
    if (proxy == -1)
        return Plugin_Continue;
    g_ProxyRef = EntIndexToEntRef(proxy);
    g_Ready = true;
    CheckConflict();
    g_InitTimer = null;
    return Plugin_Stop;
}

public void OnMapEnd()
{
    delete g_InitTimer;
    StopProxies();
    for (int client = 1; client <= MaxClients; client++)
        CancelMove(client, true);
}

public void OnPluginEnd()
{
    delete g_InitTimer;
    StopProxies();
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientInGame(client))
        {
            CancelMove(client, true);
            SavePrefs(client);
        }
}

public void OnClientPutInServer(int client)
{
    ResetPrefs(client);
    ResetMotion(client);
    g_MoveTarget[client] = MOVE_NONE;
    g_SuppressAttack[client] = false;
    if (AreClientCookiesCached(client))
        OnClientCookiesCached(client);
}

public void OnClientDisconnect(int client)
{
    SavePrefs(client);
    CancelMove(client, false);
    ResetMotion(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (g_Announce.BoolValue && !IsFakeClient(client))
        CreateTimer(35.0, Timer_Announce, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Announce(Handle timer, any data)
{
    int client = GetClientOfUserId(data);
    if (client && IsClientInGame(client) && !IsFakeClient(client))
        // 设置指令播报颜色
        PrintToChat(client, "\x01\x0B\x01\x03输入 \x04!mhud\x03 开关速度与按键显示");
    return Plugin_Stop;
}

void ResetPrefs(int client)
{
    g_Options[client] = DEFAULT_OPTIONS;
    g_Spacing[client] = 3;
    g_NumberX[client] = 0.5;
    g_NumberY[client] = 0.66;
    g_KeysX[client] = 0.5;
    g_KeysY[client] = 0.80;
    g_PrefsDirty[client] = false;
}

void ResetMotion(int client)
{
    g_Buttons[client] = 0;
    g_Mouse[client] = 0;
    g_MouseUntil[client] = 0.0;
    g_Speed[client] = 0.0;
    g_TakeoffSpeed[client] = 0.0;
    g_HaveTakeoff[client] = false;
    g_MotionSeen[client] = false;
    g_Visible[client] = false;
    for (int slot = 0; slot < HUD_SLOTS; slot++)
        g_Text[client][slot][0] = '\0';
}

void EncodePrefs(int client, char[] value, int maxlength)
{
    FormatEx(value, maxlength, "2|%d|%d|%.4f|%.4f|%.4f|%.4f", g_Options[client], g_Spacing[client], g_NumberX[client],
             g_NumberY[client], g_KeysX[client], g_KeysY[client]);
}

bool DecodePrefs(int client, const char[] value)
{
    char parts[7][24];
    if (ExplodeString(value, "|", parts, sizeof(parts), sizeof(parts[])) != sizeof(parts) || !StrEqual(parts[0], "2"))
        return false;
    int options, spacing;
    float nx, ny, kx, ky;
    if (!StringToIntEx(parts[1], options) || !StringToIntEx(parts[2], spacing) || !StringToFloatEx(parts[3], nx) ||
        !StringToFloatEx(parts[4], ny) || !StringToFloatEx(parts[5], kx) || !StringToFloatEx(parts[6], ky))
        return false;
    if (spacing < 1 || spacing > 5 || !FiniteCoordinate(nx) || !FiniteCoordinate(ny) || !FiniteCoordinate(kx) ||
        !FiniteCoordinate(ky))
        return false;
    // Keep saved layouts when clearing retired option bits.
    g_Options[client] = options & (OPT_ENABLED | OPT_DECIMAL | OPT_TAKEOFF | OPT_MOUSE | OPT_BLANKS | OPT_SPECTATE);
    if (options != g_Options[client])
        g_PrefsDirty[client] = true;
    g_Spacing[client] = spacing;
    g_NumberX[client] = nx;
    g_NumberY[client] = ny;
    g_KeysX[client] = kx;
    g_KeysY[client] = ky;
    return true;
}

public void OnClientCookiesCached(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return;
    if (g_PrefsDirty[client])
    {
        SavePrefs(client);
        return;
    }
    char value[100];
    g_Prefs.Get(client, value, sizeof(value));
    if (value[0] && DecodePrefs(client, value))
        SavePrefs(client);
}

void SavePrefs(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client) || !g_PrefsDirty[client] || !AreClientCookiesCached(client))
        return;
    char value[100];
    EncodePrefs(client, value, sizeof(value));
    g_Prefs.Set(client, value);
    g_PrefsDirty[client] = false;
}

bool FiniteCoordinate(float value)
{
    // Reject NaN/infinity while allowing layouts across the screen edges.
    return (view_as<int>(value) & 0x7F800000) != 0x7F800000;
}

float KeyStep(int client)
{
    return 0.010 + 0.004 * float(g_Spacing[client]);
}

public void Event_ResetMotion(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client)
        return;
    CancelMove(client, true);
    ResetMotion(client);
}

public void Event_CancelMove(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client)
        CancelMove(client, true);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (g_SuppressAttack[client])
    {
        if (!(buttons & IN_ATTACK))
            g_SuppressAttack[client] = false;
        else
            buttons &= ~IN_ATTACK;
    }
    if (!g_MoveTarget[client])
        return Plugin_Continue;
    int pressed = buttons;
    bool confirm = (pressed & IN_ATTACK) && !(g_LastButtons[client] & IN_ATTACK);
    g_LastButtons[client] = pressed;
    float dx, dy, step = MOVE_RATE * GetTickInterval();
    if (pressed & IN_FORWARD)
        dy -= step;
    if (pressed & IN_BACK)
        dy += step;
    if (pressed & IN_MOVELEFT)
        dx -= step;
    if (pressed & IN_MOVERIGHT)
        dx += step;
    if (g_MoveTarget[client] == MOVE_NUMBER)
    {
        g_NumberX[client] += dx;
        g_NumberY[client] += dy;
    }
    else
    {
        g_KeysX[client] += dx;
        g_KeysY[client] += dy;
    }
    buttons &= ~ADJUST_BLOCK;
    impulse = 0;
    weapon = 0;
    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    angles = g_LockedAngles[client];
    if (confirm)
    {
        CancelMove(client, true);
        g_SuppressAttack[client] = true;
        RequestFrame(Frame_Menu, GetClientSerial(client));
    }
    return Plugin_Changed;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon,
                        int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client) || g_MoveTarget[client])
        return;
    float now = GetGameTime(), velocity[3];
    // Show the current processed buttons; released keys must not linger.
    g_Buttons[client] = buttons;
    if (mouse[0])
    {
        g_Mouse[client] = mouse[0] < 0 ? -1 : 1;
        g_MouseUntil[client] = now + MOUSE_HOLD;
    }
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
    g_Speed[client] = SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
    bool ground = (GetEntityFlags(client) & FL_ONGROUND) != 0;
    MoveType move = GetEntityMoveType(client);
    if (ground)
        g_HaveTakeoff[client] = false;
    else if (g_MotionSeen[client] && move != MOVETYPE_LADDER &&
             (g_WasGround[client] || g_LastMove[client] == MOVETYPE_LADDER))
    {
        g_HaveTakeoff[client] = true;
        g_TakeoffSpeed[client] = g_Speed[client];
    }
    g_WasGround[client] = ground;
    g_LastMove[client] = move;
    g_MotionSeen[client] = true;
}

int HudTarget(int client)
{
    if (IsPlayerAlive(client) || g_MoveTarget[client])
        return client;
    if (!(g_Options[client] & OPT_SPECTATE))
        return 0;
    int mode = GetEntProp(client, Prop_Send, "m_iObserverMode");
    if (mode != 4 && mode != 5)
        return 0;
    int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
    return target > 0 && target <= MaxClients && IsClientInGame(target) && IsPlayerAlive(target) ? target : 0;
}

void BuildClientHud(int client)
{
    int target = HudTarget(client);
    g_Visible[client] = (g_Options[client] & OPT_ENABLED) != 0 && target != 0 &&
                        !(GetEntProp(client, Prop_Send, "m_iHideHUD") & (1 << 2));
    for (int slot = 0; slot < HUD_SLOTS; slot++)
        g_Text[client][slot][0] = '\0';
    if (!g_Visible[client])
        return;
    FormatEx(g_Text[client][0], HUD_TEXT, g_Options[client] & OPT_DECIMAL ? "%.2f" : "%.0f", g_Speed[target]);
    if ((g_Options[client] & OPT_TAKEOFF) && g_HaveTakeoff[target])
    {
        FormatEx(g_Text[client][HUD_DETAILS], HUD_TEXT,
                 g_Options[client] & OPT_DECIMAL ? "\n\n    (%.2f)    " : "\n\n    (%.0f)    ", g_TakeoffSpeed[target]);
    }
    float now = GetGameTime();
    // The direction line sits below the key block, centered on it; an idle
    // mouse leaves the slot empty so nothing is drawn.
    if ((g_Options[client] & OPT_MOUSE) && now < g_MouseUntil[target])
        FormatEx(g_Text[client][HUD_MOUSE], HUD_TEXT, "    %s    ", g_Mouse[target] < 0 ? "←" : "→");
    // Primary speed is always one line. Auxiliary blocks keep the same center
    // and use an odd line count to place their last line one/two font rows below.
    // Symmetric spaces make the visible row wider than a blank newline's glyph
    // metrics without moving the visible text's horizontal center.
    bool preview = g_MoveTarget[client] != MOVE_NONE;
    for (int key = 0; key < KEY_COUNT; key++)
    {
        int slot = key + 1;
        if (preview || (g_Buttons[target] & KEY_BUTTONS[key]))
            strcopy(g_Text[client][slot], HUD_TEXT, KEY_LABELS[key]);
        else if (g_Options[client] & OPT_BLANKS)
            strcopy(g_Text[client][slot], HUD_TEXT, "_");
    }
}

bool SlotOccupied(int slot)
{
    if (GameRules_GetProp("m_iScriptedHUDFlags", _, slot) & HUD_FLAG_NOTVISIBLE)
        return false;
    char value[128];
    GameRules_GetPropString("m_szScriptedHUDStringSet", value, sizeof(value), slot);
    return value[0] || GameRules_GetProp("m_iScriptedHUDInts", _, slot) ||
           GameRules_GetPropFloat("m_fScriptedHUDFloats", slot) != 0.0;
}

void RequestHudRefresh()
{
    g_NextHud = 0.0;
}

void CheckConflict()
{
    bool conflict;
    for (int slot = 0; slot < HUD_MOUSE; slot++)
        if (SlotOccupied(slot))
        {
            conflict = true;
            break;
        }
    if (conflict != g_Conflict)
        LogMessage("EMS slots 0-7 %s",
                   conflict ? "occupied; movement HUD yields to map/other plugin" : "available; movement HUD resumed");
    g_MouseConflict = SlotOccupied(HUD_MOUSE_SLOT);
    // StartMove already refuses new edits while occupied, so only the idle to
    // occupied transition needs to interrupt edits already in progress.
    if (conflict && !g_Conflict)
        for (int client = 1; client <= MaxClients; client++)
            CancelMove(client, true);
    g_Conflict = conflict;
}

public void OnGameFrame()
{
    if (!g_Ready)
        return;
    float now = GetGameTime();
    if (now >= g_NextConflictCheck)
    {
        CheckConflict();
        g_NextConflictCheck = now + 0.5;
    }
    float hz = g_Refresh.FloatValue;
    if (hz > 0.0 && now < g_NextHud)
        return;
    // Refresh every server game frame by default, or at the configured Hz limit.
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            BuildClientHud(client);
        }
    g_NextHud = hz > 0.0 ? now + 1.0 / hz : 0.0;
}

public void OnSendProxyPre()
{
    if (!g_Ready || g_Conflict)
        return;
    // AddChangeCell writes a whole cell. Preserve the bytes next to this bool.
    Address rules = view_as<Address>(LoadFromAddress(g_GameRulesPtr, NumberType_Int32));
    int modeWord = LoadFromAddress(rules + view_as<Address>(g_ModeOffset), NumberType_Int32);
    modeWord = (modeWord & ~0xFF) | 1;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (g_Visible[client])
            SendProxy.AddChangeCell(client, g_ProxyRef, g_ModeOffset, modeWord);
        // Overrides expire every tick; submit the cached HUD even between rebuilds.
        for (int slot = 0; slot < HUD_SLOTS; slot++)
        {
            if (slot == HUD_MOUSE && (g_MouseConflict || !(g_Options[client] & OPT_MOUSE)))
                continue;
            int flags = HUD_BASE_FLAGS;
            if (!g_Text[client][slot][0])
                flags |= HUD_FLAG_NOTVISIBLE;
            SendProxy.AddChangeCell(client, g_ProxyRef, g_Offsets[slot][FIELD_FLAGS], flags);
            SendProxy.AddChangeString(client, g_ProxyRef, g_Offsets[slot][FIELD_TEXT], g_Text[client][slot], HUD_TEXT);
            SendProxy.AddChangeFloat(client, g_ProxyRef, g_Offsets[slot][FIELD_X], HudPosX(client, slot));
            SendProxy.AddChangeFloat(client, g_ProxyRef, g_Offsets[slot][FIELD_Y], HudPosY(client, slot));
            SendProxy.AddChangeFloat(client, g_ProxyRef, g_Offsets[slot][FIELD_WIDTH], HudWidth(slot));
            float height =
                slot == HUD_MOUSE
                    ? KEY_HEIGHT
                    : (slot == 0 || slot >= HUD_DETAILS ? SPEED_HEIGHT * float(2 * HudRow(slot) + 1) : KEY_HEIGHT);
            SendProxy.AddChangeFloat(client, g_ProxyRef, g_Offsets[slot][FIELD_HEIGHT], height);
        }
    }
}

float HudPosX(int client, int slot)
{
    if (slot == HUD_MOUSE)
        return g_KeysX[client] - HudWidth(slot) * 0.5;
    if (slot == 0 || slot >= HUD_DETAILS)
        return g_NumberX[client] - HudWidth(slot) * 0.5;
    int col = (slot - 1) % 3;
    return g_KeysX[client] + float(col - 1) * KeyStep(client) - KEY_WIDTH * 0.5;
}

float HudPosY(int client, int slot)
{
    if (slot == HUD_MOUSE)
        return g_KeysY[client] + 2 * KEY_ROW_STEP;
    if (slot == 0 || slot >= HUD_DETAILS)
        return g_NumberY[client] - float(HudRow(slot)) * SPEED_HEIGHT;
    return g_KeysY[client] + float((slot - 1) / 3) * KEY_ROW_STEP;
}

int HudRow(int slot)
{
    return slot == HUD_DETAILS ? 1 : 0;
}

float HudWidth(int slot)
{
    if (slot == 0 || slot >= HUD_DETAILS)
        return SPEED_WIDTH * 3.0;
    return KEY_WIDTH;
}

void InitOffsets()
{
    GameData layout = new GameData("l4d2_mhud_sendproxy3");
    int scalarStride = layout.GetOffset("HUDScalarStride");
    int stringStride = layout.GetOffset("HUDStringStride");
    delete layout;
    g_ModeOffset = FindSendPropInfo("CTerrorGameRulesProxy", "m_bChallengeModeActive");
    for (int field = 0; field < HUD_FIELDS; field++)
    {
        int base = FindSendPropInfo("CTerrorGameRulesProxy", HUD_PROPS[field]);
        int stride = field == FIELD_TEXT ? stringStride : scalarStride;
        for (int slot = 0; slot < HUD_SLOTS; slot++)
            g_Offsets[slot][field] = base + (slot == HUD_MOUSE ? HUD_MOUSE_SLOT : slot) * stride;
    }
}

void StopProxies()
{
    g_Ready = false;
    g_ProxyRef = INVALID_ENT_REFERENCE;
}

public Action Cmd_Menu(int client, int args)
{
    if (!client)
        return Plugin_Handled;
    CancelMove(client, true);
    ShowMenu(client);
    return Plugin_Handled;
}

public Action Cmd_Reset(int client, int args)
{
    if (!client)
        return Plugin_Handled;
    CancelMove(client, false);
    ResetPrefs(client);
    g_PrefsDirty[client] = true;
    SavePrefs(client);
    RequestHudRefresh();
    ReplyToCommand(client, "[MHUD] 已恢复默认布局和设置。");
    ShowMenu(client);
    return Plugin_Handled;
}

void ShowMenu(int client)
{
    Menu menu = new Menu(Menu_Settings);
    menu.SetTitle(g_Conflict ? "Movement HUD（槽位被占用，暂停显示）" : "Movement HUD");
    menu.AddItem("toggle", g_Options[client] & OPT_ENABLED ? "HUD：开启" : "HUD：关闭");
    menu.AddItem("number", "调整速度位置");
    menu.AddItem("keys", "调整按键位置");
    char line[64];
    FormatEx(line, sizeof(line), "按键间距：%d", g_Spacing[client]);
    menu.AddItem("spacing", line);
    menu.AddItem("decimal", g_Options[client] & OPT_DECIMAL ? "速度小数：显示" : "速度小数：隐藏");
    menu.AddItem("takeoff", g_Options[client] & OPT_TAKEOFF ? "起跳速度：显示" : "起跳速度：隐藏");
    menu.AddItem("blanks", g_Options[client] & OPT_BLANKS ? "未按下：下划线" : "未按下：隐藏");
    menu.AddItem("mouse", g_Options[client] & OPT_MOUSE ? "鼠标方向：显示" : "鼠标方向：隐藏");
    menu.AddItem("spectate", g_Options[client] & OPT_SPECTATE ? "观战时：跟随目标" : "观战时：隐藏");
    menu.AddItem("reset", "恢复默认设置");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_Settings(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(item, info, sizeof(info));
        if (StrEqual(info, "number") || StrEqual(info, "keys"))
        {
            StartMove(client, StrEqual(info, "number") ? MOVE_NUMBER : MOVE_KEYS);
            return 0;
        }
        if (StrEqual(info, "reset"))
        {
            Cmd_Reset(client, 0);
            return 0;
        }
        if (StrEqual(info, "spacing"))
        {
            g_Spacing[client] = g_Spacing[client] % 5 + 1;
        }
        else if (StrEqual(info, "toggle"))
            g_Options[client] ^= OPT_ENABLED;
        else if (StrEqual(info, "decimal"))
            g_Options[client] ^= OPT_DECIMAL;
        else if (StrEqual(info, "takeoff"))
            g_Options[client] ^= OPT_TAKEOFF;
        else if (StrEqual(info, "blanks"))
            g_Options[client] ^= OPT_BLANKS;
        else if (StrEqual(info, "mouse"))
            g_Options[client] ^= OPT_MOUSE;
        else if (StrEqual(info, "spectate"))
            g_Options[client] ^= OPT_SPECTATE;
        g_PrefsDirty[client] = true;
        SavePrefs(client);
        BuildClientHud(client);
        RequestHudRefresh();
        ShowMenu(client);
    }
    return 0;
}

void StartMove(int client, int target)
{
    if (!g_Ready || g_Conflict)
    {
        PrintToChat(client, "[MHUD] 当前 HUD 不可用，暂时无法调整位置。");
        return;
    }
    g_MoveTarget[client] = target;
    g_Options[client] |= OPT_ENABLED;
    g_OldMove[client] = GetEntityMoveType(client);
    SetEntityMoveType(client, MOVETYPE_NONE);
    float stopped[3];
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, stopped);
    GetClientEyeAngles(client, g_LockedAngles[client]);
    g_LastButtons[client] = IN_ATTACK;
    g_SuppressAttack[client] = false;
    BuildClientHud(client);
    RequestHudRefresh();
    PrintToChat(client, "[MHUD] WASD 调整%s，鼠标左键保存；!mhud 返回菜单。",
                target == MOVE_NUMBER ? "速度位置" : "按键位置");
}

void CancelMove(int client, bool save)
{
    if (!g_MoveTarget[client])
        return;
    g_MoveTarget[client] = MOVE_NONE;
    if (IsClientInGame(client) && GetEntityMoveType(client) == MOVETYPE_NONE)
        SetEntityMoveType(client, g_OldMove[client]);
    if (save)
    {
        g_PrefsDirty[client] = true;
        SavePrefs(client);
    }
}

public void Frame_Menu(any serial)
{
    int client = GetClientFromSerial(serial);
    if (client && IsClientInGame(client))
        ShowMenu(client);
}
