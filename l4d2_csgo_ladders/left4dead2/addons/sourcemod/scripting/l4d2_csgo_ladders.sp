/*
 * l4d2_csgo_ladders
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
#include <dhooks>

#define PROTOTYPE_VERSION "1.0"
#define GAMEDATA "l4d2_csgo_ladders"
#define DETOUR_NAME "CGameMovement::LadderMove"

// Button masks are supplied by the installed SourceMod includes.

ConVar g_cvEnabled;
ConVar g_cvDebug;
ConVar g_cvSpeed;
ConVar g_cvCsgoScale;
ConVar g_cvCsgoDuckSpeed;
ConVar g_cvSurvivors;
ConVar g_cvInfected;
Handle g_hDetour;
int g_PlayerOffset;
int g_MoveDataOffset;
int g_ViewForwardOffset;
int g_ViewRightOffset;
int g_ButtonsOffset;
int g_VelocityOffset;
int g_Applied;
int g_LastReport;

public Plugin myinfo =
{
    name = "L4D2 CSGO Ladders",
    author = "ExpCharacter",
    description = "CS:GO ladder movement for survivors and special infected; ghost infected excluded.",
    version = PROTOTYPE_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("l4d2_csgoladder_enabled", "0", "Master switch. 0 = plugin does nothing (native ladder movement).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("l4d2_csgoladder_debug", "0", "Default-off debug logging, rate limited.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSpeed = CreateConVar("l4d2_csgoladder_speed", "200.0", "Per-input ladder speed from the recorded baseline (CS:GO: 200.0).", FCVAR_NOTIFY, true, 0.0);
    g_cvCsgoScale = CreateConVar("l4d2_csgoladder_scale", "0.78", "CS:GO sv_ladder_scale_speed equivalent: multiplies the mapped ladder velocity vector. 0 = no scaling (raw per-key value). L4D2 has no such ConVar.", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvCsgoDuckSpeed = CreateConVar("l4d2_csgoladder_duck_speed", "68.0", "CS:GO per-key ladder value while IN_DUCK or IN_SPEED is held (CS:GO: 68.0, otherwise 200.0).", FCVAR_NOTIFY, true, 0.0, true, 200.0);
    g_cvSurvivors = CreateConVar("l4d2_csgoladder_survivors", "1", "Apply to survivors (team 2).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvInfected = CreateConVar("l4d2_csgoladder_infected", "1", "Apply to special infected (team 3). Ghost-mode infected are always excluded.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    RegAdminCmd("l4d2_csgoladder_status", Command_Status, ADMFLAG_ROOT, "Show the switches and the applied-change count");

    Handle gameData = LoadGameConfigFile(GAMEDATA);
    if (gameData == null)
        SetFailState("Gamedata \"%s\" missing; refusing to run with partial hooks.", GAMEDATA);
    g_PlayerOffset = GameConfGetOffset(gameData, "CGameMovement.Player");
    g_MoveDataOffset = GameConfGetOffset(gameData, "CGameMovement.MoveData");
    g_ViewForwardOffset = GameConfGetOffset(gameData, "CGameMovement.ViewForward");
    g_ViewRightOffset = GameConfGetOffset(gameData, "CGameMovement.ViewRight");
    g_ButtonsOffset = GameConfGetOffset(gameData, "CMoveData.Buttons");
    g_VelocityOffset = GameConfGetOffset(gameData, "CMoveData.Velocity");
    g_hDetour = DHookCreateFromConf(gameData, DETOUR_NAME);
    delete gameData;
    if (g_hDetour == null)
        SetFailState("Signature \"%s\" not found; refusing to run with partial hooks.", DETOUR_NAME);
    if (!DHookEnableDetour(g_hDetour, true, OnLadderMovePost))
        SetFailState("Failed to enable post detour for \"%s\".", DETOUR_NAME);

    g_Applied = 0;
    g_LastReport = 0;

    // Must come after every CreateConVar above: the auto-created file is filled from the
    // registered ConVar set, so anything missing here never reaches the cfg.
    AutoExecConfig(true, "l4d2_csgo_ladders");
}

public void OnPluginEnd()
{
    if (g_hDetour != null)
        DHookDisableDetour(g_hDetour, true, OnLadderMovePost);
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "version=%s enabled=%d survivors=%d infected=%d debug=%d applied=%d",
        PROTOTYPE_VERSION, g_cvEnabled.IntValue, g_cvSurvivors.IntValue,
        g_cvInfected.IntValue, g_cvDebug.IntValue, g_Applied);
    ReplyToCommand(client, "speed=%.3f per-key (airborne ladder frames only)", g_cvSpeed.FloatValue);
    ReplyToCommand(client, "csgo_scale=%.3f duck_speed=%.3f (CS:GO sv_ladder_scale_speed and duck/walk per-key value)",
        g_cvCsgoScale.FloatValue, g_cvCsgoDuckSpeed.FloatValue);
    return Plugin_Handled;
}

public MRESReturn OnLadderMovePost(Address pThis, Handle hReturn)
{
    // Read-only decision inputs first; every guard failure leaves the native result untouched.
    if (!g_cvEnabled.BoolValue || pThis == Address_Null)
        return MRES_Ignored;

    // The native function returns true only when it actually took over ladder movement.
    if (DHookGetReturn(hReturn) != 1)
        return MRES_Ignored;

    Address player = ReadAddress(pThis, g_PlayerOffset);
    Address mv = ReadAddress(pThis, g_MoveDataOffset);
    if (player == Address_Null || mv == Address_Null)
        return MRES_Ignored;

    int client = ResolveClient(player);
    if (client == 0 || !IsPlayerAlive(client))
        return MRES_Ignored;
    int team = GetClientTeam(client);
    if (team == 2)
    {
        if (!g_cvSurvivors.BoolValue)
            return MRES_Ignored;
    }
    else if (team == 3)
    {
        if (!g_cvInfected.BoolValue)
            return MRES_Ignored;
        // Ghost mode already runs the engine's own 200 per-key value on both sides, so it
        // stays native; the switch above only ever covers the spawned states.
        if (HasEntProp(client, Prop_Send, "m_isGhost") && GetEntProp(client, Prop_Send, "m_isGhost") != 0)
            return MRES_Ignored;
    }
    else
    {
        return MRES_Ignored;
    }
    if (view_as<int>(GetEntityMoveType(client)) != 9)
        return MRES_Ignored;
    if (IsPlayerInSpecialState(client))
        return MRES_Ignored;

    int buttons = ReadInt(mv, g_ButtonsOffset);
    int fwd = ((buttons & IN_FORWARD) ? 1 : 0) - ((buttons & IN_BACK) ? 1 : 0);
    int side = ((buttons & IN_MOVERIGHT) ? 1 : 0) - ((buttons & IN_MOVELEFT) ? 1 : 0);
    // Keep jump handling (including a held jump) and floor push-off native.
    // GetEntityFlags uses SourceMod's translated FL_ONGROUND mask.
    if ((buttons & IN_JUMP) != 0 || (GetEntityFlags(client) & FL_ONGROUND) != 0)
        return MRES_Ignored;
    if (fwd == 0 && side == 0)
        return MRES_Ignored;

    float viewForward[3], right[3], normal[3], mapped[3];
    for (int i = 0; i < 3; i++)
    {
        viewForward[i] = ReadFloat(pThis, g_ViewForwardOffset + i * 4);
        right[i] = ReadFloat(pThis, g_ViewRightOffset + i * 4);
    }
    if (!HasEntProp(client, Prop_Send, "m_vecLadderNormal"))
        return MRES_Ignored;
    GetEntPropVector(client, Prop_Send, "m_vecLadderNormal", normal);
    // CS:GO picks the per-key scalar for the frame first (68 while IN_DUCK or
    // IN_SPEED is held, 200 otherwise) and only then scales the built vector.
    float perKey = ((buttons & (IN_DUCK | IN_SPEED)) != 0)
        ? g_cvCsgoDuckSpeed.FloatValue : g_cvSpeed.FloatValue;
    if (!MapGhostLadderInput(viewForward, right, normal, fwd, side, perKey, mapped))
        return MRES_Ignored;
    float ladderScale = g_cvCsgoScale.FloatValue;
    if (ladderScale > 0.0)
    {
        for (int i = 0; i < 3; i++)
            mapped[i] *= ladderScale;
    }

    // A nonzero native normal component can be a floor/base-velocity term.
    // This first prototype leaves such frames alone (0.01 is a numeric guard,
    // not a movement parameter). No position or movetype writes.
    float nativeNormal = 0.0;
    for (int i = 0; i < 3; i++)
        nativeNormal += ReadFloat(mv, g_VelocityOffset + i * 4) * normal[i];
    if (!IsFiniteFloat(nativeNormal) || FloatAbs(nativeNormal) > 0.01)
        return MRES_Ignored;
    for (int i = 0; i < 3; i++)
        WriteFloat(mv, g_VelocityOffset + i * 4, mapped[i]);
    g_Applied++;
    if (g_cvDebug.BoolValue && GetGameTickCount() - g_LastReport >= 50)
    {
        g_LastReport = GetGameTickCount();
        LogMessage("ladder mapping: userid=%d buttons=%d per_key=%.3f scale=%.3f velocity=(%.3f %.3f %.3f)",
            GetClientUserId(client), buttons, perKey, ladderScale, mapped[0], mapped[1], mapped[2]);
    }
    return MRES_Ignored;
}

int ResolveClient(Address player)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;
        if (GetEntityAddress(client) == player)
            return client;
    }
    return 0;
}

// Replays the ordinary native ladder mapping observed in the ghost hook CSV.
// wish = speed * (fwd * viewForward + side * right)
// perp = normalize(worldUp cross N); up = N cross perp
// result = wish - dot(wish,N) * N - dot(wish,N) * up
// L4D2 disassembly: 0x100fc0d3..0x100fc25a. No CS:GO scaling/damping.
bool MapGhostLadderInput(const float viewForward[3], const float right[3], const float normal[3],
    int fwd, int side, float speed, float output[3])
{
    if (!IsFiniteFloat(speed) || speed <= 0.0)
        return false;
    for (int i = 0; i < 3; i++)
        if (!IsFiniteFloat(viewForward[i]) || !IsFiniteFloat(right[i]) || !IsFiniteFloat(normal[i]))
            return false;
    // Numerical validation of the engine vectors, not gameplay thresholds.
    if (FloatAbs(GetVectorLength(viewForward, true) - 1.0) > 0.01
        || FloatAbs(GetVectorLength(right, true) - 1.0) > 0.01
        || FloatAbs(GetVectorLength(normal, true) - 1.0) > 0.01
        || FloatAbs(GetVectorDotProduct(viewForward, right)) > 0.01)
        return false;

    float worldUp[3] = {0.0, 0.0, 1.0};
    float perp[3], up[3], wish[3];
    GetVectorCrossProduct(worldUp, normal, perp);
    if (NormalizeVector(perp, perp) <= 0.000001)
        return false;
    GetVectorCrossProduct(normal, perp, up);
    for (int i = 0; i < 3; i++)
        wish[i] = speed * (float(fwd) * viewForward[i] + float(side) * right[i]);
    float into = GetVectorDotProduct(wish, normal);
    for (int i = 0; i < 3; i++)
    {
        output[i] = wish[i] - into * normal[i] - into * up[i];
        if (!IsFiniteFloat(output[i]))
            return false;
    }
    return true;
}

bool IsFiniteFloat(float value)
{
    return (view_as<int>(value) & 0x7F800000) != 0x7F800000;
}

// Special states stay with the native engine; the prototype must not add movement there.
bool IsPlayerInSpecialState(int client)
{
    if (HasEntProp(client, Prop_Send, "m_isIncapacitated") && GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0)
        return true;
    if (HasEntProp(client, Prop_Send, "m_isHangingFromLedge") && GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0)
        return true;
    static const char props[5][32] = {"m_tongueOwner", "m_pounceAttacker", "m_jockeyAttacker", "m_carryAttacker", "m_pummelAttacker"};
    for (int i = 0; i < 5; i++)
        if (HasEntProp(client, Prop_Send, props[i]) && GetEntPropEnt(client, Prop_Send, props[i]) > 0)
            return true;
    return false;
}

Address ReadAddress(Address base, int offset)
{
    return view_as<Address>(LoadFromAddress(base + view_as<Address>(offset), NumberType_Int32));
}

int ReadInt(Address base, int offset)
{
    return LoadFromAddress(base + view_as<Address>(offset), NumberType_Int32);
}

float ReadFloat(Address base, int offset)
{
    return view_as<float>(LoadFromAddress(base + view_as<Address>(offset), NumberType_Int32));
}

void WriteFloat(Address base, int offset, float value)
{
    StoreToAddress(base + view_as<Address>(offset), view_as<int>(value), NumberType_Int32);
}
