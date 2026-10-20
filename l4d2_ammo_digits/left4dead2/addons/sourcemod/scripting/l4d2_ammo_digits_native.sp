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

#define PLUGIN_VERSION "3.2.0"
#define SCRATCH_BYTES 8192
#define LINUX_SCRATCH_BYTES 16384
#define WIRE_MAX_BITS 65535
#define LINUX_TEMP_BIT 65536

// Windows anchors (verified build 2.2.4.3 / 10097).
#define WIN_SERVERPARENT_DELTA 0x7FF124
#define WIN_SENDTABLES_DELTA 0x1191F0
#define WIN_CRC_DELTA 0x694D04
#define WIN_CACHE_DATA_DELTA 0x64579C
#define WIN_CACHE_BITS_DELTA 0x6457A8
#define WIN_CACHE_OVERFLOW_DELTA 0x6457AC
#define WIN_MESSAGE_LENGTH_OFFSET 140
#define WIN_MESSAGE_DATA_OFFSET 128

// Linux anchors (engine_srv.so BuildID b1524391..., server_srv.so BuildID c9b0cd3d...).
#define LINUX_SENDPROPINT 0x57FD90
#define LINUX_SERVERPARENT_DELTA 0xFDF2DC
#define LINUX_WRITEINFOS 0x145C70
#define LINUX_SENDTABLECRC_FUNC 0x146520
#define LINUX_CRC_DELTA 0x38F6D8
#define LINUX_CACHE_DATA_DELTA 0x3A81B4
#define LINUX_CACHE_BITS_DELTA 0x3A81A8
#define LINUX_CACHE_OVERFLOW_DELTA 0x3A81AC
#define LINUX_WRITEMESSAGE_DELTA 0x988F0
#define LINUX_WRITEBITS_DELTA 0x2313C0
#define LINUX_ALLOC_DELTA 0x27E100
#define LINUX_MESSAGE_LENGTH_OFFSET 0x84
#define LINUX_MESSAGE_DATA_OFFSET 0x78

GameData g_Conf;
Handle g_Alloc, g_Free, g_CalculateCRC, g_WriteInfos;
Handle g_WriteMessage, g_WriteUnsigned, g_WriteBits;
StringMap g_PaddingNames;
Address g_Scratch, g_AmmoProps, g_EngineBase;
int g_TableCount, g_MaxBits, g_Expanded, g_Failures;
int g_Cut, g_SavedLength, g_SplitCount;
bool g_Patched, g_PreHook, g_PostHook;
bool g_MessagePreHook, g_MessagePostHook;
bool g_IsLinux;

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
    if (late)
    {
        // Linux confogl reloads plugins per mode (unload_all + shared_plugins.cfg).
        // A late load is safe only when the startup instance already widened the tables.
        GameData conf = new GameData("l4d2_ammo_digits_native");
        bool linux = (conf != null && conf.GetOffset("Linux32") == 1);
        if (conf != null) delete conf;
        if (!linux)
        {
            strcopy(error, maxlength, "Startup only: network tables cannot be changed by hot loading.");
            return APLRes_SilentFailure;
        }
    }
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

Handle StaticCall(const char[] name, bool argument, bool result)
{
    Address address = g_Conf.GetAddress(name);
    if (address == Address_Null) SetFailState("Missing address: %s", name);
    return StaticCallAddr(address, argument, result);
}

void ReadString(Address address, char[] value, int maxlength)
{
    if (address == Address_Null) SetFailState("Null string pointer");
    for (int i = 0; i < maxlength - 1; i++)
    {
        value[i] = view_as<char>(LoadFromAddress(address + view_as<Address>(i), NumberType_Int8));
        if (!value[i]) return;
    }
    value[maxlength - 1] = '\0';
}

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2) SetFailState("L4D2 only");
    g_Conf = new GameData("l4d2_ammo_digits_native");
    if (g_Conf == null) SetFailState("Missing gamedata");
    g_IsLinux = (g_Conf.GetOffset("Linux32") == 1);
    if (!g_IsLinux && g_Conf.GetOffset("Windows32") != 1) SetFailState("Unsupported platform");

    Address ctor = g_Conf.GetAddress("SendPropIntCtorAddr");
    Address writeInfos = g_Conf.GetAddress("WriteInfos");
    if (ctor == Address_Null || writeInfos == Address_Null) SetFailState("Required signatures missing");
    Address parent;
    if (g_IsLinux)
    {
        Address serverBase = ctor - view_as<Address>(LINUX_SENDPROPINT);
        g_EngineBase = writeInfos - view_as<Address>(LINUX_WRITEINFOS);
        parent = serverBase + view_as<Address>(LINUX_SERVERPARENT_DELTA);
    }
    else
    {
        Address sendTables = g_Conf.GetAddress("EngineSendTablesAddr");
        if (sendTables == Address_Null) SetFailState("Required engine signatures missing");
        Address serverBase = ctor - view_as<Address>(0xA7B10);
        g_EngineBase = sendTables - view_as<Address>(WIN_SENDTABLES_DELTA);
        parent = serverBase + view_as<Address>(WIN_SERVERPARENT_DELTA);
    }
    if (LoadFromAddress(parent + view_as<Address>(8), NumberType_Int32) != 6) SetFailState("Ammo parent is not a datatable");
    Address table = view_as<Address>(LoadFromAddress(parent + view_as<Address>(0x48), NumberType_Int32));
    if (table == Address_Null || LoadFromAddress(table + view_as<Address>(4), NumberType_Int32) != 32)
        SetFailState("Unexpected ammo datatable");
    char name[64], expected[8];
    ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(8), NumberType_Int32)), name, sizeof(name));
    if (!StrEqual(name, "m_iAmmo")) SetFailState("Unexpected table: %s", name);
    g_AmmoProps = view_as<Address>(LoadFromAddress(table, NumberType_Int32));
    if (g_AmmoProps == Address_Null) SetFailState("Missing ammo properties");
    for (int i = 0; i < 32; i++)
    {
        Address prop = g_AmmoProps + view_as<Address>(i * 0x54);
        ReadString(view_as<Address>(LoadFromAddress(prop + view_as<Address>(0x30), NumberType_Int32)), name, sizeof(name));
        FormatEx(expected, sizeof(expected), "%03d", i);
        int bits = LoadFromAddress(prop + view_as<Address>(12), NumberType_Int32);
        if (!StrEqual(name, expected) || LoadFromAddress(prop + view_as<Address>(8), NumberType_Int32) != 0
            || (bits != 10 && bits != 16))
            SetFailState("Unexpected ammo element %d", i);
    }
    if (g_IsLinux)
    {
        // default_bzalloc(opaque, items, size) tail-calls malloc; the block lives for the process.
        StartPrepSDKCall(SDKCall_Static);
        PrepSDKCall_SetAddress(g_EngineBase + view_as<Address>(LINUX_ALLOC_DELTA));
        for (int i = 0; i < 3; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_Alloc = EndPrepSDKCall();
        if (g_Alloc == null) SetFailState("Could not prepare malloc wrapper");
        g_Scratch = view_as<Address>(SDKCall(g_Alloc, 0, LINUX_SCRATCH_BYTES, 1));
        g_CalculateCRC = StaticCallAddr(g_EngineBase + view_as<Address>(LINUX_SENDTABLECRC_FUNC), false, true);
    }
    else
    {
        g_Alloc = StaticCall("AllocScratch", false, true);
        g_Free = StaticCall("FreeScratch", true, false);
        g_CalculateCRC = StaticCall("EngineSendTableCrcAddr", false, true);
        // Reuse the engine's own network scratch allocator; its block is 228000 bytes.
        // The wider storage is paired with framing below; storage alone is insufficient.
        g_Scratch = view_as<Address>(SDKCall(g_Alloc));
    }
    if (g_Scratch == Address_Null) SetFailState("Scratch allocation failed");
    Address writer = g_Conf.GetAddress("WriteInfos");
    if (writer == Address_Null) SetFailState("Missing SendTable_WriteInfos");
    g_WriteInfos = DHookCreateDetour(writer, CallConv_CDECL, ReturnType_Bool, ThisPointer_Ignore);
    if (g_WriteInfos == null) SetFailState("Could not create WriteInfos detour");
    DHookAddParam(g_WriteInfos, HookParamType_Int);
    DHookAddParam(g_WriteInfos, HookParamType_Int);
    g_PreHook = DHookEnableDetour(g_WriteInfos, false, BeforeWriteInfos);
    g_PostHook = DHookEnableDetour(g_WriteInfos, true, AfterWriteInfos);
    if (!g_PreHook || !g_PostHook) SetFailState("Could not enable WriteInfos hooks");
    Address writeMessage = g_IsLinux
        ? g_EngineBase + view_as<Address>(LINUX_WRITEMESSAGE_DELTA)
        : g_Conf.GetAddress("WriteMessage");
    if (writeMessage == Address_Null) SetFailState("Missing SVC_SendTable writer");
    if (g_IsLinux)
    {
        // GCC passes this as the first stack argument; declaring it explicitly avoids
        // DHooks reading ECX (MSVC thiscall) and handing us a garbage pointer.
        g_WriteMessage = DHookCreateDetour(writeMessage, CallConv_CDECL, ReturnType_Bool, ThisPointer_Ignore);
        if (g_WriteMessage == null) SetFailState("Could not create message framing detour");
        DHookAddParam(g_WriteMessage, HookParamType_Int); // this
        DHookAddParam(g_WriteMessage, HookParamType_Int); // output
        g_MessagePreHook = DHookEnableDetour(g_WriteMessage, false, LinuxBeforeWriteMessage);
        g_MessagePostHook = DHookEnableDetour(g_WriteMessage, true, LinuxAfterWriteMessage);
    }
    else
    {
        g_WriteMessage = DHookCreateDetour(writeMessage, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
        if (g_WriteMessage == null) SetFailState("Could not create message framing detour");
        DHookAddParam(g_WriteMessage, HookParamType_Int);
        g_MessagePreHook = DHookEnableDetour(g_WriteMessage, false, BeforeWriteMessage);
        g_MessagePostHook = DHookEnableDetour(g_WriteMessage, true, AfterWriteMessage);
    }
    if (!g_MessagePreHook || !g_MessagePostHook) SetFailState("Could not enable message framing hooks");
    Address writeBits = g_IsLinux
        ? g_EngineBase + view_as<Address>(LINUX_WRITEBITS_DELTA)
        : g_Conf.GetAddress("WriteBits");
    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetAddress(writeBits);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
    g_WriteBits = EndPrepSDKCall();
    if (g_WriteBits == null) SetFailState("Missing native bit writer");
    if (!g_IsLinux)
    {
        StartPrepSDKCall(SDKCall_Raw);
        PrepSDKCall_SetAddress(g_Conf.GetAddress("WriteUnsigned"));
        for (int i = 0; i < 3; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        g_WriteUnsigned = EndPrepSDKCall();
        if (g_WriteUnsigned == null) SetFailState("Missing native unsigned writer");
    }
    g_PaddingNames = new StringMap();
    for (int i = 0; i < 32; i++)
        StoreToAddress(g_AmmoProps + view_as<Address>(i * 0x54 + 12), 16, NumberType_Int32);
    g_Patched = true;
    FindConVar("sv_sendtables").BoolValue = true;
    RegServerCmd("sm_ammodigits_status", Cmd_Status);
    RegServerCmd("sm_ammodigits_dump", Cmd_Dump);
    LogMessage("CANDIDATE: 32 ammo elements changed to 16 bits; scratch and message framing enabled (platform=%s)",
        g_IsLinux ? "linux" : "windows");
}

public void OnConfigsExecuted()
{
    int crc = SDKCall(g_CalculateCRC);
    // The stock CRC does not cover nested ammo fields; force full-table delivery.
    int crcOffset = g_IsLinux ? LINUX_CRC_DELTA : WIN_CRC_DELTA;
    StoreToAddress(g_EngineBase + view_as<Address>(crcOffset), 0x5EEDBEEF, NumberType_Int32);
    FindConVar("sv_sendtables").BoolValue = true;
    LogMessage("Root-table CRC=%08x; full-table marker=5EEDBEEF", crc);
}

public MRESReturn BeforeWriteInfos(Handle result, Handle params)
{
    Address buffer = view_as<Address>(DHookGetParam(params, 2));
    if (buffer == Address_Null || g_Scratch == Address_Null) return MRES_Ignored;
    // Only replace the empty 4096-byte per-table temporary writers.
    if (LoadFromAddress(buffer + view_as<Address>(4), NumberType_Int32) == 4096
        && LoadFromAddress(buffer + view_as<Address>(12), NumberType_Int32) == 0)
    {
        StoreToAddress(buffer, view_as<int>(g_Scratch), NumberType_Int32);
        StoreToAddress(buffer + view_as<Address>(4), g_IsLinux ? LINUX_SCRATCH_BYTES : SCRATCH_BYTES, NumberType_Int32);
        StoreToAddress(buffer + view_as<Address>(8), WIRE_MAX_BITS, NumberType_Int32);
        g_Expanded++;
    }
    return MRES_Ignored;
}

public MRESReturn AfterWriteInfos(Handle result, Handle params)
{
    Address buffer = view_as<Address>(DHookGetParam(params, 2));
    if (buffer == Address_Null) return MRES_Ignored;
    int bits = LoadFromAddress(buffer + view_as<Address>(12), NumberType_Int32);
    g_Cut = 0;
    g_TableCount++;
    if (bits > g_MaxBits) g_MaxBits = bits;
    if (!DHookGetReturn(result) || LoadFromAddress(buffer + view_as<Address>(16), NumberType_Int8) || bits > WIRE_MAX_BITS)
    {
        g_Failures++;
        LogError("Table serialization failed: bits=%d", bits);
    }
    else if (bits > 32767)
    {
        Address table = view_as<Address>(DHookGetParam(params, 1));
        g_Cut = FindCut(table, bits);
        if (!g_Cut) { g_Failures++; LogError("No safe integer bounds available for framing"); }
        else
        {
            char name[128]; ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(8), NumberType_Int32)), name, sizeof(name));
            int tag;
            if (!g_PaddingNames.GetValue(name, tag))
            {
                tag = 33 + g_PaddingNames.Size;
                if (tag > 126) SetFailState("Too many framing tables");
                g_PaddingNames.SetValue(name, tag);
            }
            int cursor = g_Cut;
            SetBits(cursor, 9, 6); SetBits(cursor, 0, 1); SetBits(cursor, bits - g_Cut - 23, 16);
            SetBits(cursor, tag, 8); SetBits(cursor, 0, 8); SetBits(cursor, 0, 10);
        }
    }
    return MRES_Ignored;
}

void SetBits(int &position, int value, int count)
{
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
    char name[256]; ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(8), NumberType_Int32)), name, sizeof(name));
    int position = (strlen(name) + 1) * 8 + 10, best, bestDistance = 0x7FFFFFFF;
    Address properties = view_as<Address>(LoadFromAddress(table, NumberType_Int32));
    int count = LoadFromAddress(table + view_as<Address>(4), NumberType_Int32);
    for (int i = 0; i < count; i++)
    {
        Address prop = properties + view_as<Address>(i * 84);
        int type = LoadFromAddress(prop + view_as<Address>(8), NumberType_Int32);
        int flags = LoadFromAddress(prop + view_as<Address>(60), NumberType_Int32);
        ReadString(view_as<Address>(LoadFromAddress(prop + view_as<Address>(48), NumberType_Int32)), name, sizeof(name));
        position += 5 + (strlen(name) + 1) * 8 + 19 + 8;
        if (type == 0 && !(flags & 0x40) && position <= 32767 && length - position - 23 > 0 && length - position - 23 <= 32767)
        {
            int distance = position * 2 - length;
            if (distance < 0) distance = -distance;
            if (distance < bestDistance) { best = position; bestDistance = distance; }
        }
        if (type == 6 || (flags & 0x40))
        {
            Address text;
            if (type == 6)
            {
                Address child = view_as<Address>(LoadFromAddress(prop + view_as<Address>(72), NumberType_Int32));
                text = view_as<Address>(LoadFromAddress(child + view_as<Address>(8), NumberType_Int32));
            }
            else text = view_as<Address>(LoadFromAddress(prop + view_as<Address>(40), NumberType_Int32));
            ReadString(text, name, sizeof(name)); position += (strlen(name) + 1) * 8;
        }
        else position += type == 5 ? 10 : 70;
    }
    return position == length ? best : 0;
}

public MRESReturn BeforeWriteMessage(Address message, Handle result, Handle params)
{
    return MessageBefore(message);
}

public MRESReturn LinuxBeforeWriteMessage(Handle result, Handle params)
{
    return MessageBefore(view_as<Address>(DHookGetParam(params, 1)));
}

MRESReturn MessageBefore(Address message)
{
    g_SavedLength = 0;
    int lengthOffset = g_IsLinux ? LINUX_MESSAGE_LENGTH_OFFSET : WIN_MESSAGE_LENGTH_OFFSET;
    int dataOffset = g_IsLinux ? LINUX_MESSAGE_DATA_OFFSET : WIN_MESSAGE_DATA_OFFSET;
    int bits = LoadFromAddress(message + view_as<Address>(lengthOffset), NumberType_Int32);
    if (bits <= 32767) return MRES_Ignored;
    if (!g_Cut || view_as<Address>(LoadFromAddress(message + view_as<Address>(dataOffset), NumberType_Int32)) != g_Scratch)
    {
        g_Failures++; LogError("Unframed overlong SendTable"); return MRES_Ignored;
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
    if (!g_SavedLength) return MRES_Ignored;
    int bits = g_SavedLength; g_SavedLength = 0;
    int lengthOffset = g_IsLinux ? LINUX_MESSAGE_LENGTH_OFFSET : WIN_MESSAGE_LENGTH_OFFSET;
    StoreToAddress(message + view_as<Address>(lengthOffset), bits, NumberType_Int32);
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
            SDKCall(g_WriteBits, output, g_Scratch + view_as<Address>(LINUX_TEMP_BIT / 8), prefix);
        }
        else
        {
            SDKCall(g_WriteUnsigned, output, byte >>> (position % 8), prefix, 1);
        }
        position += prefix; remaining -= prefix;
    }
    bool okay = SDKCall(g_WriteBits, output, g_Scratch + view_as<Address>(position / 8), remaining);
    g_SplitCount++;
    if (!okay) { g_Failures++; DHookSetReturn(result, false); return MRES_Override; }
    return MRES_Ignored;
}

public Action Cmd_Status(int args)
{
    int bitsOffset = g_IsLinux ? LINUX_CACHE_BITS_DELTA : WIN_CACHE_BITS_DELTA;
    int overflowOffset = g_IsLinux ? LINUX_CACHE_OVERFLOW_DELTA : WIN_CACHE_OVERFLOW_DELTA;
    int crcOffset = g_IsLinux ? LINUX_CRC_DELTA : WIN_CRC_DELTA;
    int bits = LoadFromAddress(g_EngineBase + view_as<Address>(bitsOffset), NumberType_Int32);
    int overflow = LoadFromAddress(g_EngineBase + view_as<Address>(overflowOffset), NumberType_Int8);
    int crc = LoadFromAddress(g_EngineBase + view_as<Address>(crcOffset), NumberType_Int32);
    PrintToServer("[ammo-native-candidate] tables=%d expanded=%d split=%d maxbits=%d failures=%d cachebits=%d overflow=%d crc=%08x",
        g_TableCount, g_Expanded, g_SplitCount, g_MaxBits, g_Failures, bits, overflow, crc);
    return Plugin_Handled;
}

public Action Cmd_Dump(int args)
{
    int dataOffset = g_IsLinux ? LINUX_CACHE_DATA_DELTA : WIN_CACHE_DATA_DELTA;
    int bitsOffset = g_IsLinux ? LINUX_CACHE_BITS_DELTA : WIN_CACHE_BITS_DELTA;
    Address data = view_as<Address>(LoadFromAddress(g_EngineBase + view_as<Address>(dataOffset), NumberType_Int32));
    int bits = LoadFromAddress(g_EngineBase + view_as<Address>(bitsOffset), NumberType_Int32);
    if (data == Address_Null || bits <= 0 || bits > 228000 * 8) { PrintToServer("[ammo-repair] no valid cache"); return Plugin_Handled; }
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
    // Linux intentionally leaks the process-lifetime scratch block and leaves the widened
    // tables and fixed CRC in place: both are process-level patches that only a restart clears.
    if (!g_IsLinux && g_Scratch != Address_Null && g_Free != null) SDKCall(g_Free, g_Scratch);
    if (g_Patched) LogMessage("Network tables remain widened until process exit; restart without this experiment to restore stock protocol");
}
