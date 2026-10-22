/*
 * l4d2_ammo_digits_native
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

// Startup-only native ammo transport candidate. Requires client acceptance testing.
// Written with ChatGPT 6.1 sol high + deepseek flash.
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "0.4.1"
#define SCRATCH_BYTES 8192
#define LINUX_SCRATCH_BYTES 16384
#define WIRE_MAX_BITS 65535
#define LINUX_TEMP_BIT 65536

// Native entry points are resolved once from gamedata; the engine and server
// images are never located through a compile-time RVA or module anchor.

GameData g_Conf;
Handle g_Alloc, g_Free, g_WriteInfos;
Handle g_WriteMessage, g_WriteUnsigned, g_WriteBits;
StringMap g_PaddingNames;
Address g_Scratch, g_AmmoProps;
int g_TableCount, g_MaxBits, g_Expanded, g_Failures;
int g_Cut, g_SavedLength, g_SplitCount;
bool g_Patched, g_PreHook, g_PostHook;
bool g_MessagePreHook, g_MessagePostHook;
bool g_IsLinux;
int g_PatchApplied;
int g_OriginalBits[32];
bool g_Late;

// Shared native addresses, filled once by ResolvePlatform before any consumer.
Address g_ServerFactoryAddr, g_WriteInfosAddr, g_AllocAddr;
Address g_BaselineAddr, g_AdmissionAddr, g_MessageAddr, g_BitsAddr;

// Field addresses (not their current values) plus the protocol offsets and
// scratch capacity that differ per platform.
enum struct PlatformLayout
{
    Address cacheBits;
    Address cacheData;
    Address cacheOverflow;
    Address crc;
    int messageLengthOffset;
    int messageDataOffset;
    int scratchBytes;
    int tableBufferBytes;
    int cacheBytes;
}
PlatformLayout g_Layout;

#include "include/ammo_guard.inc"

public Plugin myinfo =
{
    name = "L4D2 Ammo Digits Native Candidate",
    author = "ExpCharacter",
    description = "Native ammo with framed full-table transport",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int maxlength)
{
    g_Late = late;
    // Confogl reloads plugins per mode (unload_all + shared_plugins.cfg) on both
    // platforms.  A late load is safe only when the cache was already built with
    // the widened schema; the signon guard verifies that cache and faults
    // otherwise, so no startup-only rejection is needed here.
    return APLRes_Success;
}

Handle StaticCallAddr(Address address, bool argument, bool result)
{
    if (address == Address_Null) SetFailState("Missing address for static call");
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetAddress(address);
    if (argument) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    if (result) PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle call = EndPrepSDKCall();
    if (call == null) SetFailState("Could not prepare static call");
    return call;
}

void ReadString(Address address, char[] value, int maxlength)
{
    if (TryReadString(address, value, maxlength)) return;
    if (!g_Patched) SetFailState("Unreadable or unterminated schema string");
    LatchFault("Unreadable or unterminated schema string");
}

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2) SetFailState("L4D2 only");
    g_PluginId = view_as<int>(GetMyHandle());
    g_Conf = new GameData("l4d2_ammo_digits_native");
    if (g_Conf == null) SetFailState("Missing gamedata");
    g_IsLinux = (g_Conf.GetOffset("Linux32") == 1);
    if (!g_IsLinux && g_Conf.GetOffset("Windows32") != 1) SetFailState("Unsupported platform");
    ResolvePlatform();
    g_SendTables = FindConVar("sv_sendtables");
    if (g_SendTables == null) SetFailState("Missing sv_sendtables; no protocol changes made");
    if (g_IsLinux)
    {
        // default_bzalloc(opaque, items, size) tail-calls malloc; the block lives for the process.
        StartPrepSDKCall(SDKCall_Static);
        PrepSDKCall_SetAddress(g_AllocAddr);
        for (int i = 0; i < 3; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_Alloc = EndPrepSDKCall();
        if (g_Alloc == null) SetFailState("Could not prepare malloc wrapper");
        g_Scratch = view_as<Address>(SDKCall(g_Alloc, 0, g_Layout.scratchBytes, 1));
    }
    else
    {
        g_Alloc = StaticCallAddr(g_AllocAddr, false, true);
        g_Free = StaticCallAddr(g_FreeAddr, true, false);
        // Reuse the engine's network scratch allocator; capacity comes from gamedata.
        // The wider storage is paired with framing below; storage alone is insufficient.
        g_Scratch = view_as<Address>(SDKCall(g_Alloc));
    }
    if (g_Scratch == Address_Null) SetFailState("Scratch allocation failed");
    InitMemoryChecks();
    if (!MemorySpan(g_Scratch, g_IsLinux ? LINUX_SCRATCH_BYTES : SCRATCH_BYTES + 64, true))
        SetFailState("Scratch allocation is not a writable mapped range");
    ResolveLiveSchema();
    char name[64], expected[8];
    if (!MemorySpan(g_AmmoProps, 32 * g_Prop.size, true)) SetFailState("Ammo properties outside writable memory");
    for (int i = 0; i < 32; i++)
    {
        Address prop = g_AmmoProps + view_as<Address>(i * g_Prop.size);
        ReadString(view_as<Address>(LoadFromAddress(prop + view_as<Address>(g_Prop.name), NumberType_Int32)), name, sizeof(name));
        FormatEx(expected, sizeof(expected), "%03d", i);
        if (!StrEqual(name, expected) || LoadFromAddress(prop + view_as<Address>(g_Prop.type), NumberType_Int32) != 0
            || (LoadFromAddress(prop + view_as<Address>(g_Prop.bits), NumberType_Int32) != 10
                && LoadFromAddress(prop + view_as<Address>(g_Prop.bits), NumberType_Int32) != 16)
            || !(LoadFromAddress(prop + view_as<Address>(g_Prop.flags), NumberType_Int32) & 1))
            SetFailState("Unexpected ammo element %d", i);
        g_OriginalBits[i] = LoadFromAddress(prop + view_as<Address>(g_Prop.bits), NumberType_Int32);
    }
    g_WriteInfos = DHookCreateDetour(g_WriteInfosAddr, CallConv_CDECL, ReturnType_Bool, ThisPointer_Ignore);
    if (g_WriteInfos == null) SetFailState("Could not create WriteInfos detour");
    DHookAddParam(g_WriteInfos, HookParamType_Int);
    DHookAddParam(g_WriteInfos, HookParamType_Int);
    g_PreHook = DHookEnableDetour(g_WriteInfos, false, BeforeWriteInfos);
    g_PostHook = DHookEnableDetour(g_WriteInfos, true, AfterWriteInfos);
    if (!g_PreHook || !g_PostHook) SetFailState("Could not enable WriteInfos hooks");
    if (g_IsLinux)
    {
        // GCC passes this as the first stack argument; declaring it explicitly avoids
        // DHooks reading ECX (MSVC thiscall) and handing us a garbage pointer.
        g_WriteMessage = DHookCreateDetour(g_MessageAddr, CallConv_CDECL, ReturnType_Bool, ThisPointer_Ignore);
        if (g_WriteMessage == null) SetFailState("Could not create message framing detour");
        DHookAddParam(g_WriteMessage, HookParamType_Int); // this
        DHookAddParam(g_WriteMessage, HookParamType_Int); // output
        g_MessagePreHook = DHookEnableDetour(g_WriteMessage, false, LinuxBeforeWriteMessage);
        g_MessagePostHook = DHookEnableDetour(g_WriteMessage, true, LinuxAfterWriteMessage);
    }
    else
    {
        g_WriteMessage = DHookCreateDetour(g_MessageAddr, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
        if (g_WriteMessage == null) SetFailState("Could not create message framing detour");
        DHookAddParam(g_WriteMessage, HookParamType_Int);
        g_MessagePreHook = DHookEnableDetour(g_WriteMessage, false, BeforeWriteMessage);
        g_MessagePostHook = DHookEnableDetour(g_WriteMessage, true, AfterWriteMessage);
    }
    if (!g_MessagePreHook || !g_MessagePostHook) SetFailState("Could not enable message framing hooks");
    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetAddress(g_BitsAddr);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
    g_WriteBits = EndPrepSDKCall();
    if (g_WriteBits == null) SetFailState("Missing native bit writer");
    if (!g_IsLinux)
    {
        StartPrepSDKCall(SDKCall_Raw);
        PrepSDKCall_SetAddress(g_UnsignedAddr);
        for (int i = 0; i < 3; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        g_WriteUnsigned = EndPrepSDKCall();
        if (g_WriteUnsigned == null) SetFailState("Missing native unsigned writer");
    }
    g_PaddingNames = new StringMap();
    InstallLifecycleHooks();
    for (int i = 0; i < 32; i++)
    {
        StoreToAddress(g_AmmoProps + view_as<Address>(i * g_Prop.size + g_Prop.bits), 16, NumberType_Int32);
        g_PatchApplied++;
        if (LoadFromAddress(g_AmmoProps + view_as<Address>(i * g_Prop.size + g_Prop.bits), NumberType_Int32) != 16)
            SetFailState("Ammo installation readback failed at element %d", i);
    }
    g_Patched = true;
    g_SendTables.AddChangeHook(GuardSendTablesChanged);
    g_SendTables.BoolValue = true;
    RegServerCmd("sm_ammodigits_status", Cmd_Status);
    RegServerCmd("sm_ammodigits_dump", Cmd_Dump);
    LogMessage("CANDIDATE: 32 ammo elements changed to 16 bits; scratch and message framing enabled (platform=%s)",
        g_IsLinux ? "linux" : "windows");
}

public void OnMapStart()
{
    // Map epoch and cache generation are independent: a new map may reuse a
    // valid cache, and a real rebuild invalidates publication separately.
    g_MapEpoch++;
    g_ConfigsSeen = false;
    g_PendingLogged = false;
}

public void OnConfigsExecuted()
{
    g_ConfigsObservations++;
    if (!g_ConfigsSeen)
    {
        g_ConfigsSeen = true;
        LogMessage("Ammo lifecycle: configs observed plugin=%d map_epoch=%d generation=%d cache_validated=%d fault=%d",
            g_PluginId, g_MapEpoch, g_Generation, g_CacheReady ? 1 : 0, g_Faulted ? 1 : 0);
    }
    if (g_Faulted) return;
    if (g_IsLinux)
    {
        // One publish opportunity among several; it needs no Confogl, extra cfg
        // or a warm-up connection.  A pending cache is left for the signon path.
        PublishMarkerOnce("configs");
        return;
    }
    // The stock CRC does not cover nested ammo fields; force full-table delivery.
    int crc = LoadFromAddress(g_Layout.crc, NumberType_Int32);
    StoreToAddress(g_Layout.crc, 0x5EEDBEEF, NumberType_Int32);
    g_SendTables.BoolValue = true;
    LogMessage("Root-table CRC=%08x; full-table marker=5EEDBEEF", crc);
}

public MRESReturn BeforeWriteInfos(Handle result, Handle params)
{
    if (!g_CacheBuilding) return MRES_Ignored;
    Address buffer = view_as<Address>(DHookGetParam(params, 2));
    Address table = view_as<Address>(DHookGetParam(params, 1));
    if (g_Faulted || g_InfosOwned || g_InfosPending || !MemorySpan(buffer, g_Buffer.readSize, true) || !MemorySpan(table, g_Table.readSize)
        || LoadFromAddress(buffer + view_as<Address>(g_Buffer.bytes), NumberType_Int32) != g_Layout.tableBufferBytes
        || LoadFromAddress(buffer + view_as<Address>(g_Buffer.bits), NumberType_Int32) != g_Layout.tableBufferBytes * 8
        || LoadFromAddress(buffer + view_as<Address>(g_Buffer.overflow), NumberType_Int8)
        || LoadFromAddress(buffer + view_as<Address>(g_Buffer.cursor), NumberType_Int32) != 0)
    {
        LatchFault("Unexpected/nested cache table writer");
        DHookSetReturn(result, false); return MRES_Supercede;
    }
    g_InfosBuffer = buffer; g_InfosTable = table; g_InfosOwned = true; g_InfosBits = 0; g_Cut = 0;
    StoreToAddress(buffer + view_as<Address>(g_Buffer.data), view_as<int>(g_Scratch), NumberType_Int32);
    StoreToAddress(buffer + view_as<Address>(g_Buffer.bytes), g_Layout.scratchBytes, NumberType_Int32);
    StoreToAddress(buffer + view_as<Address>(g_Buffer.bits), WIRE_MAX_BITS, NumberType_Int32);
    g_Expanded++;
    return MRES_Ignored;
}

public MRESReturn AfterWriteInfos(Handle result, Handle params)
{
    if (!g_CacheBuilding || !g_InfosOwned) return MRES_Ignored;
    Address buffer = view_as<Address>(DHookGetParam(params, 2));
    Address table = view_as<Address>(DHookGetParam(params, 1));
    if (buffer != g_InfosBuffer || table != g_InfosTable)
    { LatchFault("WriteInfos pre/post ownership mismatch"); return MRES_Ignored; }
    g_InfosOwned = false;
    int bits = LoadFromAddress(buffer + view_as<Address>(g_Buffer.cursor), NumberType_Int32);
    g_Cut = 0;
    g_TableCount++;
    if (bits > g_MaxBits) g_MaxBits = bits;
    if (g_Faulted || !DHookGetReturn(result) || LoadFromAddress(buffer + view_as<Address>(g_Buffer.overflow), NumberType_Int8)
        || bits <= 0 || bits > WIRE_MAX_BITS
        || view_as<Address>(LoadFromAddress(buffer + view_as<Address>(g_Buffer.data), NumberType_Int32)) != g_Scratch)
    {
        LatchFault("Table serialization failed or scratch ownership changed");
        DHookSetReturn(result, false); return MRES_Override;
    }
    g_InfosBits = bits;
    g_InfosPending = true;
    char tableName[128];
    ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(g_Table.name), NumberType_Int32)), tableName, sizeof(tableName));
    int used;
    if (g_UsedPadding.GetValue(tableName, used)) LatchFault("Real table collides with a framing padding name");
    g_RealTableNames.SetValue(tableName, 1);
    if (bits > 32767)
    {
        g_Cut = FindCut(table, bits);
        if (!g_Cut) LatchFault("No safe integer bounds available for framing");
        else
        {
            int tag;
            if (!g_PaddingNames.GetValue(tableName, tag))
            {
                tag = 33 + g_PaddingNames.Size;
                if (tag > 126) LatchFault("Padding name capacity exceeded");
                else g_PaddingNames.SetValue(tableName, tag);
            }
            char padding[2]; padding[0] = view_as<char>(tag); padding[1] = '\0';
            if (g_RealTableNames.GetValue(padding, used)) LatchFault("Framing padding collides with a real table");
            g_UsedPadding.SetValue(padding, 1);
            if (!g_Faulted)
            {
                int cursor = g_Cut;
                SetBits(cursor, 9, 6); SetBits(cursor, 0, 1); SetBits(cursor, bits - g_Cut - 23, 16);
                SetBits(cursor, tag, 8); SetBits(cursor, 0, 8); SetBits(cursor, 0, 10);
            }
        }
    }
    if (g_Faulted) { DHookSetReturn(result, false); return MRES_Override; }
    return MRES_Ignored;
}

void SetBits(int &position, int value, int count)
{
    int capacity = g_Layout.scratchBytes * 8;
    if (g_Faulted) return;
    if (position < 0 || count < 0 || count > 32 || position > capacity || count > capacity - position)
    { LatchFault("Scratch bit-write outside capacity"); return; }
    for (int i = 0; i < count; i++)
    {
        Address address = g_Scratch + view_as<Address>(position / 8);
        int bit = position % 8, byte = LoadFromAddress(address, NumberType_Int8);
        byte = (byte & ~(1 << bit)) | (((value >>> i) & 1) << bit);
        StoreToAddress(address, byte, NumberType_Int8);
        position++;
    }
}

int FindCut(Address table, int length)
{
    if (!MemorySpan(table, g_Table.readSize)) return 0;
    char name[256]; ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(g_Table.name), NumberType_Int32)), name, sizeof(name));
    if (g_Faulted) return 0;
    int position = (strlen(name) + 1) * 8 + 10, best, bestDistance = 0x7FFFFFFF;
    Address properties = view_as<Address>(LoadFromAddress(table + view_as<Address>(g_Table.props), NumberType_Int32));
    int count = LoadFromAddress(table + view_as<Address>(g_Table.count), NumberType_Int32);
    if (count < 0 || count > 4096 || (count && !MemorySpan(properties, count * g_Prop.size))) return 0;
    for (int i = 0; i < count; i++)
    {
        Address prop = properties + view_as<Address>(i * g_Prop.size);
        int type = LoadFromAddress(prop + view_as<Address>(g_Prop.type), NumberType_Int32);
        int flags = LoadFromAddress(prop + view_as<Address>(g_Prop.flags), NumberType_Int32);
        if (type < 0 || type > 6) return 0;
        ReadString(view_as<Address>(LoadFromAddress(prop + view_as<Address>(g_Prop.name), NumberType_Int32)), name, sizeof(name));
        position += 5 + (strlen(name) + 1) * 8 + 19 + 8;
        if (g_Faulted || position > length) return 0;
        if (type == 0 && !(flags & 0x40) && position <= 32767 && length - position - 23 > 0 && length - position - 23 <= 32767)
        {
            int distance = position * 2 - length;
            if (distance < 0) distance = -distance;
            if (distance < bestDistance) { best = position; bestDistance = distance; }
        }
        if (type == 6 || (flags & 0x40))
        {
            Address text;
            if (!PropertyReferenceAddress(prop, type, text)) return 0;
            ReadString(text, name, sizeof(name)); position += (strlen(name) + 1) * 8;
        }
        else position += type == 5 ? 10 : 70;
    }
    return !g_Faulted && position == length ? best : 0;
}

public MRESReturn BeforeWriteMessage(Address message, Handle result, Handle params)
{
    return MessageBefore(message, view_as<Address>(DHookGetParam(params, 1)), result);
}

public MRESReturn LinuxBeforeWriteMessage(Handle result, Handle params)
{
    return MessageBefore(view_as<Address>(DHookGetParam(params, 1)), view_as<Address>(DHookGetParam(params, 2)), result);
}

MRESReturn MessageBefore(Address message, Address output, Handle result)
{
    if (!g_CacheBuilding) return MRES_Ignored;
    int lengthOffset = g_Layout.messageLengthOffset;
    int dataOffset = g_Layout.messageDataOffset;
    if (g_Faulted || g_Message != Address_Null || !MemorySpan(message, lengthOffset + 4, true) || !MemorySpan(output, g_Buffer.readSize, true))
    { LatchFault("Invalid/nested SendTable message context"); DHookSetReturn(result, false); return MRES_Supercede; }
    int bits = LoadFromAddress(message + view_as<Address>(lengthOffset), NumberType_Int32);
    int cursor = LoadFromAddress(output + view_as<Address>(g_Buffer.cursor), NumberType_Int32);
    int capacity = LoadFromAddress(output + view_as<Address>(g_Buffer.bits), NumberType_Int32);
    int bytes = LoadFromAddress(output + view_as<Address>(g_Buffer.bytes), NumberType_Int32);
    Address outputData = view_as<Address>(LoadFromAddress(output + view_as<Address>(g_Buffer.data), NumberType_Int32));
    Address data = view_as<Address>(LoadFromAddress(message + view_as<Address>(dataOffset), NumberType_Int32));
    if (bits < 0 || bits > WIRE_MAX_BITS || (bits && (!g_InfosPending || bits != g_InfosBits || data != g_Scratch))
        || bytes <= 0 || bytes > g_Layout.cacheBytes || capacity <= 0 || capacity > bytes * 8
        || !MemorySpan(outputData, bytes, true)
        || cursor < 0 || capacity < cursor || bits + 23 > capacity - cursor
        || LoadFromAddress(output + view_as<Address>(g_Buffer.overflow), NumberType_Int8))
    { LatchFault("SendTable payload/output does not match validated serialization"); DHookSetReturn(result, false); return MRES_Supercede; }
    g_Message = message; g_MessageOutput = output; g_MessageBits = bits; g_MessageStart = cursor;
    if (bits) g_InfosPending = false;
    if (bits <= 32767) return MRES_Ignored;
    if (g_Cut <= 0 || g_Cut > 32767 || bits - g_Cut - 23 <= 0 || bits - g_Cut - 23 > 32767)
    {
        LatchFault("Unframed overlong SendTable"); DHookSetReturn(result, false); return MRES_Supercede;
    }
    g_SavedLength = bits;
    StoreToAddress(message + view_as<Address>(lengthOffset), g_Cut, NumberType_Int32);
    return MRES_Ignored;
}

public MRESReturn AfterWriteMessage(Address message, Handle result, Handle params)
{
    return MessageAfter(message, view_as<Address>(DHookGetParam(params, 1)), result);
}

public MRESReturn LinuxAfterWriteMessage(Handle result, Handle params)
{
    return MessageAfter(view_as<Address>(DHookGetParam(params, 1)),
                        view_as<Address>(DHookGetParam(params, 2)), result);
}

MRESReturn MessageAfter(Address message, Address output, Handle result)
{
    if (message != g_Message || g_Message == Address_Null) return MRES_Ignored;
    int bits = g_MessageBits, framed = g_SavedLength;
    g_SavedLength = 0; g_Message = Address_Null;
    int lengthOffset = g_Layout.messageLengthOffset;
    if (framed) StoreToAddress(message + view_as<Address>(lengthOffset), bits, NumberType_Int32);
    if (g_Faulted || output != g_MessageOutput || !DHookGetReturn(result) || LoadFromAddress(output + view_as<Address>(g_Buffer.overflow), NumberType_Int8))
    { LatchFault("Original message writer failed; no tail appended"); DHookSetReturn(result, false); return MRES_Override; }
    if (!framed)
    {
        if (LoadFromAddress(output + view_as<Address>(g_Buffer.cursor), NumberType_Int32) != g_MessageStart + bits + 23)
        { LatchFault("Short message output length mismatch"); DHookSetReturn(result, false); return MRES_Override; }
        if (bits) g_GenerationMessages++;
        return MRES_Ignored;
    }
    int position = g_Cut, remaining = bits - position;
    if (position % 8)
    {
        int prefix = 8 - position % 8;
        int byte = LoadFromAddress(g_Scratch + view_as<Address>(position / 8), NumberType_Int8);
        if (g_IsLinux)
        {
            // bf_write::WriteBits always reads from bit 0, so stage the shifted byte at the scratch tail.
            int temp = LINUX_TEMP_BIT;
            SetBits(temp, byte >>> (position % 8), prefix);
            if (g_Faulted || !SDKCall(g_WriteBits, output, g_Scratch + view_as<Address>(LINUX_TEMP_BIT / 8), prefix))
            { LatchFault("Framing prefix write failed"); DHookSetReturn(result, false); return MRES_Override; }
        }
        else
        {
            SDKCall(g_WriteUnsigned, output, byte >>> (position % 8), prefix, 1);
        }
        if (LoadFromAddress(output + view_as<Address>(g_Buffer.overflow), NumberType_Int8))
        { LatchFault("Framing prefix overflow"); DHookSetReturn(result, false); return MRES_Override; }
        position += prefix; remaining -= prefix;
    }
    bool okay = SDKCall(g_WriteBits, output, g_Scratch + view_as<Address>(position / 8), remaining);
    if (!okay || LoadFromAddress(output + view_as<Address>(g_Buffer.overflow), NumberType_Int8))
    { LatchFault("Framing tail write failed"); DHookSetReturn(result, false); return MRES_Override; }
    g_SplitCount++;
    if (LoadFromAddress(output + view_as<Address>(g_Buffer.cursor), NumberType_Int32) != g_MessageStart + bits + 23)
    { LatchFault("Framed message output length mismatch"); DHookSetReturn(result, false); return MRES_Override; }
    g_GenerationMessages++;
    return MRES_Ignored;
}

public Action Cmd_Status(int args)
{
    int bits = LoadFromAddress(g_Layout.cacheBits, NumberType_Int32);
    int overflow = LoadFromAddress(g_Layout.cacheOverflow, NumberType_Int8);
    int crc = LoadFromAddress(g_Layout.crc, NumberType_Int32);
    PrintToServer("[ammo-native-candidate] tables=%d expanded=%d split=%d maxbits=%d failures=%d cachebits=%d overflow=%d crc=%08x",
        g_TableCount, g_Expanded, g_SplitCount, g_MaxBits, g_Failures, bits, overflow, crc);
    PrintToServer("[ammo-guard] generation=%d building=%d ready=%d fault=%d digest=%08x reason=%s", g_Generation, g_CacheBuilding, g_CacheReady, g_Faulted, g_CacheDigest, g_FaultReason);
    if (g_IsLinux)
        PrintToServer("[ammo-lifecycle] plugin=%d map_epoch=%d configs_seen=%d configs_observed=%d cache_validated=%d marker_published=%d published_epoch=%d published_generation=%d publish_writes=%d",
            g_PluginId, g_MapEpoch, g_ConfigsSeen ? 1 : 0, g_ConfigsObservations, g_CacheReady ? 1 : 0,
            g_MarkerPublished ? 1 : 0, g_PublishedEpoch, g_PublishedGeneration, g_PublishWrites);
    return Plugin_Handled;
}

public Action Cmd_Dump(int args)
{
    int bits; Address data;
    int rawBits = LoadFromAddress(g_Layout.cacheBits, NumberType_Int32);
    if (!CacheValid(bits, data) || data == Address_Null || bits != rawBits || bits <= 0 || bits > g_Layout.cacheBytes * 8)
    { PrintToServer("[ammo-repair] no valid cache"); return Plugin_Handled; }
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/ammo_digits_sendtables.bin");
    File file = OpenFile(path, "wb");
    if (file == null) { PrintToServer("[ammo-repair] dump open failed"); return Plugin_Handled; }
    for (int i = 0; i < (bits + 7) / 8; i++) file.WriteInt8(LoadFromAddress(data + view_as<Address>(i), NumberType_Int8));
    delete file;
    PrintToServer("[ammo-repair] dumped %d bits", bits);
    return Plugin_Handled;
}

public void OnPluginEnd()
{
    g_Closing = true;
    RemoveLifecycleHooks();
    if (g_PreHook) DHookDisableDetour(g_WriteInfos, false, BeforeWriteInfos);
    if (g_PostHook) DHookDisableDetour(g_WriteInfos, true, AfterWriteInfos);
    if (g_IsLinux)
    {
        if (g_MessagePreHook) DHookDisableDetour(g_WriteMessage, false, LinuxBeforeWriteMessage);
        if (g_MessagePostHook) DHookDisableDetour(g_WriteMessage, true, LinuxAfterWriteMessage);
    }
    else
    {
        if (g_MessagePreHook) DHookDisableDetour(g_WriteMessage, false, BeforeWriteMessage);
        if (g_MessagePostHook) DHookDisableDetour(g_WriteMessage, true, AfterWriteMessage);
    }
    if (!g_Patched && g_PatchApplied && g_AmmoProps != Address_Null)
    {
        for (int i = 0; i < g_PatchApplied; i++) StoreToAddress(g_AmmoProps + view_as<Address>(i * g_Prop.size + g_Prop.bits), g_OriginalBits[i], NumberType_Int32);
    }
    // Existing unload policy retained: lifetime ownership fixes are deferred by the user.
    if (!g_IsLinux && g_Scratch != Address_Null && g_Free != null) SDKCall(g_Free, g_Scratch);
    if (g_Patched) LogMessage("Network tables remain widened until process exit; restart without this experiment to restore stock protocol");
}

public void GuardSendTablesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_Patched && !g_Closing && !convar.BoolValue) LatchFault("sv_sendtables disabled after installation");
}

