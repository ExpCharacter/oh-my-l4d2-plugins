/*
 * l4d2_colorcorrection_control
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

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <sendproxy>

#define VERSION "1.0"

public Plugin myinfo =
{
    name = "L4D2 Color Correction Control",
    author = "ExpCharacter",
    description = "Players toggle map color correction with !cc",
    version = VERSION,
    url = "https://github.com/ExpCharacter/oh-my-l4d2-plugins"
};

#define MAX_CC_ENTS 32

// Override m_flMaxWeight per recipient so client-simulated map filters fade out.
// Overriding m_flCurWeight alone does not control client-side simulation.
// Analysis and earlier experiments are documented in the development notes.

ConVar g_cvEnable;
ConVar g_cvAnnounce;
StringMap g_Preferences; // Survives map changes; cleared when the plugin unloads.

int g_ccCount;
int g_ccRef[MAX_CC_ENTS];

bool g_Disable[MAXPLAYERS + 1];

int g_offMaxCC; // SendProp offset of CColorCorrection::m_flMaxWeight.

public void OnPluginStart()
{
    CreateConVar("l4d2_colorcorrection_control_version", VERSION, "CC toggle version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvEnable = CreateConVar("l4d2_colorcorrection_control_enable", "1", "Enable the plugin.", FCVAR_NONE, true, 0.0,
                              true, 1.0);
    g_cvAnnounce = CreateConVar("l4d2_colorcorrection_control_announce", "1", "Show the !cc hint after a player joins.",
                                FCVAR_NONE, true, 0.0, true, 1.0);
    RegConsoleCmd("sm_cc", Cmd_ToggleCC, "切换地图色彩修正");
    g_Preferences = new StringMap();
    HookEvent("round_start", Event_RoundStart);
    AutoExecConfig(true, "l4d2_colorcorrection_control");

    g_offMaxCC = FindSendPropInfo("CColorCorrection", "m_flMaxWeight");
    if (g_offMaxCC < 0)
        SetFailState("CColorCorrection::m_flMaxWeight offset not found.");
}

public Action Timer_LateScan(Handle timer)
{
    ScanAndCollect();
    return Plugin_Stop;
}

public void OnMapStart()
{
    // Map entities may already exist when OnMapStart runs.
    ScanAndCollect();
    CreateTimer(0.5, Timer_LateScan, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients)
        return;
    if (strcmp(classname, "color_correction"))
        return;
    // Wait for creation to finish; an entity reference guards against index reuse.
    RequestFrame(Frame_AddCcEntity, EntIndexToEntRef(entity));
}

public void Frame_AddCcEntity(any ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity != INVALID_ENT_REFERENCE)
        AddCcEntity(entity);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Scan every round after the game has recreated its entities.
    RequestFrame(Frame_RoundScan);
}

public void Frame_RoundScan(any data)
{
    ScanAndCollect();
}

void ScanAndCollect()
{
    // Rebuild the list to discard references to destroyed entities.
    g_ccCount = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "color_correction")) != -1)
        AddCcEntity(ent);
}

void AddCcEntity(int entity)
{
    if (!IsValidEntity(entity))
        return;
    int ref = EntIndexToEntRef(entity);
    for (int i = 0; i < g_ccCount; i++)
        if (g_ccRef[i] == ref)
            return;
    if (g_ccCount >= MAX_CC_ENTS)
        return;

    g_ccRef[g_ccCount++] = ref;
}

// Mark unchanged weights for transmission so a toggle reaches the client.
void MarkMaxDirty()
{
    for (int i = 0; i < g_ccCount; i++)
    {
        int ent = EntRefToEntIndex(g_ccRef[i]);
        if (ent == INVALID_ENT_REFERENCE)
            continue;
        ChangeEdictState(ent, g_offMaxCC);
    }
}

// Queue a zero weight for players who disabled map filters.
// SendProxy clears the queue after packing, so submit overrides each frame.
public void OnSendProxyPre()
{
    if (!g_cvEnable.BoolValue || g_ccCount == 0)
        return;
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!g_Disable[c] || !IsClientInGame(c) || IsFakeClient(c))
            continue;
        // AddChangeFloat drops stale entity references without queueing anything.
        for (int i = 0; i < g_ccCount; i++)
            SendProxy.AddChangeFloat(c, g_ccRef[i], g_offMaxCC, 0.0);
    }
}

public void OnClientPostAdminCheck(int client)
{
    LoadPref(client);

    if (g_cvAnnounce.BoolValue && !IsFakeClient(client))
        CreateTimer(25.0, Timer_Announce, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    g_Disable[client] = false;
}

public Action Timer_Announce(Handle timer, any data)
{
    int client = GetClientOfUserId(view_as<int>(data));
    if (client && IsClientInGame(client) && !IsFakeClient(client))
        // Match advertisement colors: light green text and green command names.
        PrintToChat(client, "\x01\x0B\x01\x03输入 \x04!cc\x03 可开关地图自带的色彩修正滤镜");
    return Plugin_Stop;
}

void LoadPref(int client)
{
    char auth[32];
    GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
    int disabled;
    g_Preferences.GetValue(auth, disabled);
    g_Disable[client] = (disabled != 0);
}

public Action Cmd_ToggleCC(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[CC] 该命令仅限游戏内玩家使用。");
        return Plugin_Handled;
    }
    if (!g_cvEnable.BoolValue)
        return Plugin_Handled;

    ScanAndCollect();
    g_Disable[client] = !g_Disable[client];
    char auth[32];
    GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
    g_Preferences.SetValue(auth, g_Disable[client]);
    // Resend the weight: disabled players receive zero; enabled players receive
    // the original value and the client applies its configured fade.
    MarkMaxDirty();

    if (g_Disable[client])
        PrintToChat(client, "\x01\x0B\x01\x03[\x04CC\x03] 地图色彩修正已\x04关闭\x03（黑白视野不受影响）");
    else
        PrintToChat(client, "\x01\x0B\x01\x03[\x04CC\x03] 地图色彩修正已\x04开启\x03");
    return Plugin_Handled;
}
