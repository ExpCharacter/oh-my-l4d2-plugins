// Exact-build admission and validated cache publication for the transport core.
#include "ammo_guard_builds.inc"

Address g_ServerBase, g_QueryStorage;
Handle g_VirtualQuery, g_BaselineHook, g_AdmissionHook, g_HLTVHook;
ConVar g_SendTables;
bool g_GuardVerified, g_Faulted, g_CacheBuilding, g_CacheReady, g_Closing;
bool g_BaselinePre, g_BaselinePost, g_AdmissionPre, g_HLTVPre;
int g_Generation, g_GenerationStart, g_CacheBits, g_CacheDigest;
int g_GenerationMessages;
int g_MapEpoch, g_ConfigsObservations, g_PublishWrites, g_PluginId;
int g_PublishedEpoch = -1, g_PublishedGeneration = -1;
bool g_ConfigsSeen, g_MarkerPublished, g_PendingLogged;
bool g_InfosPending;
Address g_MessageOutput;
int g_MessageBits, g_MessageStart;
StringMap g_RealTableNames, g_UsedPadding;
StringMap g_SchemaByName, g_ClassTables, g_ClassNodes, g_RootTables;
int g_ExpectedTables, g_ExpectedClasses;
char g_FaultReason[192];
Address g_InfosBuffer, g_InfosTable, g_Message;
bool g_InfosOwned;
int g_InfosBits;
int g_Regions[2048][4], g_RegionCount;
int g_CRC32[256];

bool UnsignedLE(int a, int b) { return (a ^ 0x80000000) <= (b ^ 0x80000000); }

int GuardHex(char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

bool ParseHex32(const char[] text, int &value)
{
    int length = strlen(text); value = 0;
    if (!length || length > 8) return false;
    // Preserve all 32 address bits without signed decimal conversion semantics.
    for (int i = 0; i < length; i++)
    {
        int digit = GuardHex(text[i]);
        if (digit < 0) return false;
        value = (value << 4) | digit;
    }
    return true;
}

void InitCRC32()
{
    for (int i = 0; i < 256; i++)
    {
        int v = i;
        for (int j = 0; j < 8; j++) v = (v >>> 1) ^ ((v & 1) ? 0xEDB88320 : 0);
        g_CRC32[i] = v;
    }
}

#include "ammo_linux_resolve.inc"

void VerifyModuleFile(const char[] relative, int expectedSize, int expectedCRC)
{
    char path[PLATFORM_MAX_PATH];
    if (relative[0] == '/') FormatEx(path, sizeof(path), "file://%s", relative);
    else BuildPath(Path_SM, path, sizeof(path), "%s", relative);
    if (FileSize(path) != expectedSize)
        SetFailState("Unsupported binary size: %s (no memory changes made)", path);
    File file = OpenFile(path, "rb");
    if (file == null) SetFailState("Cannot verify binary: %s", path);
    int buffer[1024], count, total, crc = -1;
    while ((count = file.Read(buffer, sizeof(buffer), 1)) > 0)
    {
        total += count;
        for (int i = 0; i < count; i++) crc = (crc >>> 8) ^ g_CRC32[(crc ^ buffer[i]) & 255];
    }
    delete file;
    crc ^= -1;
    if (total != expectedSize || crc != expectedCRC)
        SetFailState("Unsupported binary fingerprint: %s crc=%08x expected=%08x; request matching gamedata, not a guessed base", path, crc, expectedCRC);
}

bool ModuleSpan(Address address, int bytes, bool code, bool writable = false)
{
    if (address == Address_Null || bytes <= 0) return false;
    if (g_IsLinux) return MemorySpan(address, bytes, writable);
    for (int i = 0; i < sizeof(WindowsSegments); i++)
    {
        int offset = view_as<int>(address) - view_as<int>(WindowsSegments[i][0] ? g_ServerBase : g_EngineBase) - WindowsSegments[i][1];
        if (WindowsSegments[i][3] && (!code || WindowsSegments[i][5]) && (!writable || WindowsSegments[i][4])
            && offset >= 0 && offset <= WindowsSegments[i][2] && bytes <= WindowsSegments[i][2] - offset) return true;
    }
    return false;
}

bool EntryMatches(Address address, const char[] pattern)
{
    int length = strlen(pattern);
    if (length % 2 || !ModuleSpan(address, length / 2, true)) return false;
    for (int i = 0; i < length; i += 2)
    {
        if (pattern[i] == '?' && pattern[i + 1] == '?') continue;
        int hi = GuardHex(pattern[i]), lo = GuardHex(pattern[i + 1]);
        if (hi < 0 || lo < 0 || LoadFromAddress(address + view_as<Address>(i / 2), NumberType_Int8) != ((hi << 4) | lo)) return false;
    }
    return true;
}

void RequireEntry(Address address, const char[] pattern, const char[] name)
{
    if (!EntryMatches(address, pattern)) SetFailState("Unsupported/hooked function entry: %s; refusing all protocol writes", name);
}

void VerifyBuild(Address ctor, Address infos)
{
    InitCRC32();
    // Resolve the actual loaded images from independent exported module anchors.
    // Never treat an absolute address recorded on another machine as a base.
    Address engineAnchor = g_Conf.GetMemSig("EngineModuleAnchor");
    Address serverAnchor = g_Conf.GetMemSig("ServerModuleAnchor");
    if (engineAnchor == Address_Null || serverAnchor == Address_Null) SetFailState("Missing loaded-module anchors");
    if (g_IsLinux)
    {
        VerifyBuildLinux(serverAnchor);
        g_GuardVerified = true;
        return;
    }
    // Windows path is intentionally unchanged in this round.
    g_EngineBase = engineAnchor - view_as<Address>(WINDOWS_ENGINE_ANCHOR);
    g_ServerBase = serverAnchor - view_as<Address>(WINDOWS_SERVER_ANCHOR);
    VerifyModuleFile("../../../bin/engine.dll", WINDOWS_ENGINE_FILE_SIZE, WINDOWS_ENGINE_FILE_CRC);
    VerifyModuleFile("../../bin/server.dll", WINDOWS_SERVER_FILE_SIZE, WINDOWS_SERVER_FILE_CRC);
    if (infos != g_EngineBase + view_as<Address>(WINDOWS_INFOS_RVA)
        || ctor != g_ServerBase + view_as<Address>(WINDOWS_CTOR_RVA))
        SetFailState("Module anchor/RVA disagreement: engine=%08x server=%08x infos=%08x ctor=%08x; no patch applied", g_EngineBase, g_ServerBase, infos, ctor);
    RequireEntry(ctor, WINDOWS_CTOR_ENTRY, "SendPropInt");
    RequireEntry(g_ServerBase + view_as<Address>(WINDOWS_CLASSES_RVA), WINDOWS_CLASSES_ENTRY, "GetAllServerClasses");
    RequireEntry(infos, WINDOWS_INFOS_ENTRY, "WriteInfos");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_BASELINE_RVA), WINDOWS_BASELINE_ENTRY, "CreateBaseline");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_TABLES_RVA), WINDOWS_TABLES_ENTRY, "WriteSendTables");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_ADMISSION_RVA), WINDOWS_ADMISSION_ENTRY, "signon gate");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_CRC_RVA), WINDOWS_CRC_ENTRY, "CRC");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_ALLOC_RVA), WINDOWS_ALLOC_ENTRY, "allocator");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_MESSAGE_RVA), WINDOWS_MESSAGE_ENTRY, "message writer");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_BITS_RVA), WINDOWS_BITS_ENTRY, "bit writer");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_HLTV_RVA), WINDOWS_HLTV_ENTRY, "HLTV signon gate");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_FREE_RVA), WINDOWS_FREE_ENTRY, "free");
    RequireEntry(g_EngineBase + view_as<Address>(WINDOWS_UNSIGNED_RVA), WINDOWS_UNSIGNED_ENTRY, "unsigned writer");
    int fields[] = {WIN_CRC_DELTA, WIN_CACHE_DATA_DELTA, WIN_CACHE_BITS_DELTA, WIN_CACHE_OVERFLOW_DELTA};
    for (int i = 0; i < sizeof(fields); i++)
        if (!ModuleSpan(g_EngineBase + view_as<Address>(fields[i]), i == 3 ? 1 : 4, false, true))
            SetFailState("Global field outside verified writable image segment");
    g_GuardVerified = true;
    LogMessage("Build verified; loaded engine=%08x server=%08x (independent anchors, relocation-aware)", g_EngineBase, g_ServerBase);
}

bool RefreshRegions()
{
    g_RegionCount = 0;
    File file = OpenFile("file:///proc/self/maps", "r");
    if (file == null) return false;
    char line[512], range[32], permissions[8], parts[2][16];
    while (file.ReadLine(line, sizeof(line)))
    {
        int end = FindCharInString(line, ' ');
        if (end < 0 || end >= sizeof(range)) continue;
        strcopy(range, end + 1, line);
        int pos = end;
        while (line[pos] == ' ') pos++;
        strcopy(permissions, sizeof(permissions), line[pos]);
        if (ExplodeString(range, "-", parts, sizeof(parts), sizeof(parts[])) != 2
            || strlen(parts[0]) > 8 || strlen(parts[1]) > 8) { delete file; return false; }
        if (g_RegionCount >= sizeof(g_Regions)) { delete file; return false; }
        if (!ParseHex32(parts[0], g_Regions[g_RegionCount][0]) || !ParseHex32(parts[1], g_Regions[g_RegionCount][1]))
        { delete file; return false; }
        g_Regions[g_RegionCount][2] = permissions[0] == 'r';
        g_Regions[g_RegionCount][3] = permissions[1] == 'w';
        g_RegionCount++;
    }
    delete file;
    return g_RegionCount > 0;
}

void InitMemoryChecks()
{
    if (g_IsLinux)
    {
        if (!RefreshRegions()
            || !MemorySpan(g_LinuxCrcGlobal, 4, true) || !MemorySpan(g_LinuxCacheBits, 4, true)
            || !MemorySpan(g_LinuxCacheOverflow, 1, true) || !MemorySpan(g_LinuxCacheData, 4, true))
            SetFailState("Linux cache/CRC globals are not writable");
        return;
    }
    // On Win32, SDKCall_Raw uses thiscall: stack arguments and callee cleanup
    // match stdcall. The dummy ECX receiver is ignored by these Win32 APIs.
    Address getModule = view_as<Address>(LoadFromAddress(g_EngineBase + view_as<Address>(WIN_IAT_GETMODULEHANDLEA), NumberType_Int32));
    StartPrepSDKCall(SDKCall_Raw); PrepSDKCall_SetAddress(getModule);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle moduleCall = EndPrepSDKCall();
    if (moduleCall == null) SetFailState("Cannot prepare module identity check");
    Address actualEngine = view_as<Address>(SDKCall(moduleCall, g_EngineBase, "engine.dll"));
    Address kernel = view_as<Address>(SDKCall(moduleCall, g_EngineBase, "kernel32.dll"));
    delete moduleCall;
    if (actualEngine != g_EngineBase || kernel == Address_Null)
        SetFailState("OS module identity differs from signature anchors");
    Address getProc = view_as<Address>(LoadFromAddress(g_EngineBase + view_as<Address>(WIN_IAT_GETPROCADDRESS), NumberType_Int32));
    StartPrepSDKCall(SDKCall_Raw); PrepSDKCall_SetAddress(getProc);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle procCall = EndPrepSDKCall();
    if (procCall == null) SetFailState("Cannot prepare memory-query lookup");
    Address query = view_as<Address>(SDKCall(procCall, g_EngineBase, kernel, "VirtualQuery"));
    delete procCall;
    if (query == Address_Null) SetFailState("VirtualQuery unavailable");
    StartPrepSDKCall(SDKCall_Raw); PrepSDKCall_SetAddress(query);
    for (int i = 0; i < 3; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_VirtualQuery = EndPrepSDKCall();
    g_QueryStorage = g_Scratch + view_as<Address>(SCRATCH_BYTES + 16);
    if (g_VirtualQuery == null) SetFailState("Cannot prepare memory range query");
    // The game and Metamod can both be named server.dll; identify it by address.
    if (SDKCall(g_VirtualQuery, g_EngineBase, g_ServerBase + view_as<Address>(WINDOWS_SERVER_ANCHOR), g_QueryStorage, 28) != 28
        || view_as<Address>(LoadFromAddress(g_QueryStorage + view_as<Address>(4), NumberType_Int32)) != g_ServerBase)
        SetFailState("Server export is outside its expected loaded image");
}

bool MemorySpan(Address address, int bytes, bool writable = false)
{
    int begin = view_as<int>(address);
    if (address == Address_Null || bytes <= 0 || !UnsignedLE(begin, begin + bytes - 1)) return false;
    if (g_IsLinux)
    {
        for (int attempt = 0; attempt < 2; attempt++)
        {
            int cursor = begin, remaining = bytes;
            for (int i = 0; i < g_RegionCount && remaining > 0; i++)
            {
                if (!UnsignedLE(g_Regions[i][0], cursor) || !UnsignedLE(cursor + 1, g_Regions[i][1])) continue;
                if (!g_Regions[i][2] || (writable && !g_Regions[i][3])) return false;
                int available = g_Regions[i][1] - cursor;
                if (available >= remaining) return true;
                cursor += available; remaining -= available;
            }
            if (!RefreshRegions()) return false;
        }
        return false;
    }
    if (g_VirtualQuery == null) return false;
    int cursor = begin, remaining = bytes;
    while (remaining > 0)
    {
        if (SDKCall(g_VirtualQuery, g_EngineBase, cursor, g_QueryStorage, 28) != 28) return false;
        int region = LoadFromAddress(g_QueryStorage, NumberType_Int32);
        int size = LoadFromAddress(g_QueryStorage + view_as<Address>(12), NumberType_Int32);
        int state = LoadFromAddress(g_QueryStorage + view_as<Address>(16), NumberType_Int32);
        int protection = LoadFromAddress(g_QueryStorage + view_as<Address>(20), NumberType_Int32);
        int access = protection & 255;
        if (state != 0x1000 || (protection & 0x100) || !(access & 0xEE)
            || (writable && !(access & 0xCC)) || size <= 0) return false;
        int offset = cursor - region;
        if (offset < 0 || offset >= size) return false;
        int available = size - offset;
        if (available >= remaining) return true;
        cursor += available; remaining -= available;
    }
    return true;
}

void LatchFault(const char[] reason)
{
    g_Failures++;
    g_CacheReady = false;
    if (g_Faulted) return;
    g_Faulted = true;
    strcopy(g_FaultReason, sizeof(g_FaultReason), reason);
    LogError("Transport FAULTED plugin=%d map_epoch=%d generation=%d published=%d: %s. New signon blocked; process restart required",
        g_PluginId, g_MapEpoch, g_Generation, g_MarkerPublished ? 1 : 0, reason);
}

bool TryReadString(Address address, char[] value, int maxlength)
{
    value[0] = '\0';
    for (int i = 0; i < maxlength; i++)
    {
        if (!MemorySpan(address + view_as<Address>(i), 1)) return false;
        int byte = LoadFromAddress(address + view_as<Address>(i), NumberType_Int8);
        if (!byte) { value[i] = '\0'; return true; }
        if (i == maxlength - 1) { value[i] = '\0'; return false; }
        value[i] = view_as<char>(byte);
    }
    return false;
}

void WalkSchema(Address table, int depth, StringMap visited)
{
    if (depth > 32 || !MemorySpan(table, 12)) SetFailState("Unreadable/deep SendTable hierarchy");
    char key[16], name[128]; int unused;
    FormatEx(key, sizeof(key), "%08x", table);
    if (visited.GetValue(key, unused)) return;
    visited.SetValue(key, 1);
    if (++g_ExpectedTables > 2048) SetFailState("Too many SendTables");
    ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(8), NumberType_Int32)), name, sizeof(name));
    int other;
    if (g_SchemaByName.GetValue(name, other) && other != view_as<int>(table)) SetFailState("Ambiguous SendTable name: %s", name);
    g_SchemaByName.SetValue(name, view_as<int>(table));
    int count = LoadFromAddress(table + view_as<Address>(4), NumberType_Int32);
    Address props = view_as<Address>(LoadFromAddress(table, NumberType_Int32));
    if (count < 0 || count > 1023 || (count && !MemorySpan(props, count * 84))) SetFailState("Invalid SendTable properties: %s", name);
    if (StrEqual(name, "m_iAmmo"))
    {
        if (count != 32) SetFailState("Unexpected m_iAmmo element count");
        g_AmmoProps = props;
    }
    for (int i = 0; i < count; i++)
    {
        Address prop = props + view_as<Address>(i * 84);
        int type = LoadFromAddress(prop + view_as<Address>(8), NumberType_Int32);
        if (type < 0 || type > 6) SetFailState("Unknown SendProp type");
        if (type == 6) WalkSchema(view_as<Address>(LoadFromAddress(prop + view_as<Address>(72), NumberType_Int32)), depth + 1, visited);
    }
}

void ResolveLiveSchema()
{
    // Obtain the server interface from its actual loaded factory. Slot 10 is
    // GetAllServerClasses in ServerGameDLL005 on both reviewed x86 builds.
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetAddress(g_IsLinux ? g_ServerFactory : g_ServerBase + view_as<Address>(WINDOWS_SERVER_ANCHOR));
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle factory = EndPrepSDKCall();
    if (factory == null) SetFailState("Cannot prepare server interface factory");
    Address serverInterface = view_as<Address>(SDKCall(factory, "ServerGameDLL005", 0)); delete factory;
    if (!MemorySpan(serverInterface, 4)) SetFailState("ServerGameDLL005 interface unavailable");
    Address vtable = view_as<Address>(LoadFromAddress(serverInterface, NumberType_Int32));
    if (!ModuleSpan(vtable, 44, false) || !MemorySpan(vtable, 44)) SetFailState("Invalid server interface vtable");
    Address getter = view_as<Address>(LoadFromAddress(vtable + view_as<Address>(40), NumberType_Int32));
    if (getter != (g_IsLinux ? g_LinuxClasses : g_ServerBase + view_as<Address>(WINDOWS_CLASSES_RVA)))
        SetFailState("GetAllServerClasses vtable entry differs from the verified function");
    StartPrepSDKCall(SDKCall_Raw); PrepSDKCall_SetAddress(getter);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    Handle getClasses = EndPrepSDKCall();
    if (getClasses == null) SetFailState("Cannot prepare GetAllServerClasses");
    Address node = view_as<Address>(SDKCall(getClasses, serverInterface)); delete getClasses;
    g_SchemaByName = new StringMap(); g_ClassTables = new StringMap();
    g_ClassNodes = new StringMap(); g_RootTables = new StringMap();
    StringMap visited = new StringMap();
    while (node != Address_Null)
    {
        if (++g_ExpectedClasses > 1024 || !MemorySpan(node, 16)) SetFailState("Invalid/cyclic ServerClass list");
        char className[128], tableName[128];
        ReadString(view_as<Address>(LoadFromAddress(node, NumberType_Int32)), className, sizeof(className));
        Address table = view_as<Address>(LoadFromAddress(node + view_as<Address>(4), NumberType_Int32));
        WalkSchema(table, 0, visited);
        ReadString(view_as<Address>(LoadFromAddress(table + view_as<Address>(8), NumberType_Int32)), tableName, sizeof(tableName));
        if (g_ClassTables.ContainsKey(className)) SetFailState("Duplicate ServerClass name");
        g_ClassTables.SetString(className, tableName);
        g_ClassNodes.SetValue(className, view_as<int>(node)); g_RootTables.SetValue(tableName, 1);
        node = view_as<Address>(LoadFromAddress(node + view_as<Address>(8), NumberType_Int32));
    }
    delete visited;
    if (!g_ExpectedClasses || g_AmmoProps == Address_Null) SetFailState("m_iAmmo absent from live registered schema");
    LogMessage("Live schema resolved: classes=%d tables=%d ammo=%08x; no fixed ammo-parent RVA", g_ExpectedClasses, g_ExpectedTables, g_AmmoProps);
}

bool CacheState(int &bits, Address &data)
{
    Address bitsAddress = g_IsLinux ? g_LinuxCacheBits : g_EngineBase + view_as<Address>(WIN_CACHE_BITS_DELTA);
    Address dataAddress = g_IsLinux ? g_LinuxCacheData : g_EngineBase + view_as<Address>(WIN_CACHE_DATA_DELTA);
    Address overflowAddress = g_IsLinux ? g_LinuxCacheOverflow : g_EngineBase + view_as<Address>(WIN_CACHE_OVERFLOW_DELTA);
    bits = LoadFromAddress(bitsAddress, NumberType_Int32);
    data = view_as<Address>(LoadFromAddress(dataAddress, NumberType_Int32));
    int overflow = LoadFromAddress(overflowAddress, NumberType_Int8);
    return !overflow && bits > 0 && bits <= 228000 * 8 && MemorySpan(data, (bits + 7) / 8);
}

int CacheDigest(Address data, int bits)
{
    int crc = -1;
    for (int i = 0; i < (bits + 7) / 8; i++)
        crc = (crc >>> 8) ^ g_CRC32[(crc ^ LoadFromAddress(data + view_as<Address>(i), NumberType_Int8)) & 255];
    return crc ^ -1;
}

bool WireRead(Address data, int bits, int &position, int count, int &value)
{
    value = 0;
    if (count < 0 || count > 32 || position < 0 || position > bits || count > bits - position) return false;
    for (int i = 0; i < count; i++)
    {
        int at = position + i;
        value |= ((LoadFromAddress(data + view_as<Address>(at / 8), NumberType_Int8) >>> (at % 8)) & 1) << i;
    }
    position += count; return true;
}

bool WireString(Address data, int bits, int &position, char[] value, int maxlength)
{
    for (int i = 0; i < maxlength; i++)
    {
        int byte;
        if (!WireRead(data, bits, position, 8, byte)) return false;
        value[i] = view_as<char>(byte);
        if (!byte) return true;
    }
    value[maxlength - 1] = '\0'; return false;
}

bool ParseExistingCache(Address data, int bits)
{
    StringMap seen = new StringMap(), classes = new StringMap(), ids = new StringMap();
    bool okay = ParseCacheBody(data, bits, seen, classes, ids);
    delete seen; delete classes; delete ids;
    return okay;
}

bool ParseCacheBody(Address data, int bits, StringMap seen, StringMap classes, StringMap ids)
{
    int pos, tables, pendingEnd; bool ammoSeen;
    char name[128], propName[128], actual[128], childName[128];
    while (pos < bits)
    {
        int kind, value;
        if (!WireRead(data, bits, pos, 6, kind)) return false;
        if (kind == 10)
        {
            int count, local;
            if (pendingEnd || tables != g_ExpectedTables || !ammoSeen
                || !WireRead(data, bits, pos, 16, count) || count != g_ExpectedClasses
                || !WireRead(data, bits, pos, 1, local) || local) return false;
            int classBits, remaining = count;
            while (remaining) { classBits++; remaining >>>= 1; }
            for (int i = 0; i < count; i++)
            {
                int id, classNode; char key[16];
                if (!WireRead(data, bits, pos, classBits, id) || id < 0 || id >= count
                    || !WireString(data, bits, pos, name, sizeof(name))
                    || !WireString(data, bits, pos, childName, sizeof(childName))
                    || !g_ClassTables.GetString(name, actual, sizeof(actual)) || !StrEqual(actual, childName)
                    || classes.ContainsKey(name) || !g_ClassNodes.GetValue(name, classNode)
                    || !MemorySpan(view_as<Address>(classNode), 16)
                    || id != LoadFromAddress(view_as<Address>(classNode) + view_as<Address>(12), NumberType_Int32)) return false;
                FormatEx(key, sizeof(key), "%d", id);
                if (ids.ContainsKey(key)) return false;
                ids.SetValue(key, 1); classes.SetValue(name, 1);
            }
            return pos <= bits && bits - pos < 8;
        }
        int decoder, length, count;
        if (kind != 9 || !WireRead(data, bits, pos, 1, decoder) || !WireRead(data, bits, pos, 16, length)
            || length <= 0 || length > 32767 || length > bits - pos) return false;
        int start = pos, declaredEnd = start + length;
        if (!WireString(data, bits, pos, name, sizeof(name)) || !WireRead(data, bits, pos, 10, count)) return false;
        int address;
        if (!g_SchemaByName.GetValue(name, address))
        {
            // A padding table is legal only as the exact tail of the preceding
            // overlong real table; it is never accepted as a free-standing table.
            if (!pendingEnd || decoder || count || strlen(name) != 1 || name[0] < 33 || name[0] > 126
                || declaredEnd != pendingEnd || pos > declaredEnd) return false;
            pendingEnd = 0; pos = declaredEnd; continue;
        }
        if (pendingEnd || seen.ContainsKey(name) || view_as<bool>(decoder) != g_RootTables.ContainsKey(name)) return false;
        seen.SetValue(name, 1); tables++;
        Address table = view_as<Address>(address);
        if (!MemorySpan(table, 12) || LoadFromAddress(table + view_as<Address>(4), NumberType_Int32) != count) return false;
        Address props = view_as<Address>(LoadFromAddress(table, NumberType_Int32));
        if (count && !MemorySpan(props, count * 84)) return false;
        bool ammo = StrEqual(name, "m_iAmmo");
        if (ammo && count != 32) return false;
        for (int i = 0; i < count; i++)
        {
            int type, flags;
            Address prop = props + view_as<Address>(i * 84);
            if (!WireRead(data, bits, pos, 5, type) || !WireString(data, bits, pos, propName, sizeof(propName))
                || !WireRead(data, bits, pos, 19, flags) || !WireRead(data, bits, pos, 8, value)
                || type != LoadFromAddress(prop + view_as<Address>(8), NumberType_Int32)
                || flags != (LoadFromAddress(prop + view_as<Address>(60), NumberType_Int32) & 0x7FFFF)
                || value != LoadFromAddress(prop + view_as<Address>(56), NumberType_Int8)
                || !TryReadString(view_as<Address>(LoadFromAddress(prop + view_as<Address>(48), NumberType_Int32)), actual, sizeof(actual))
                || !StrEqual(propName, actual)) return false;
            if (type == 6 || (flags & 0x40))
            {
                Address text;
                if (type == 6)
                {
                    Address child = view_as<Address>(LoadFromAddress(prop + view_as<Address>(72), NumberType_Int32));
                    if (!MemorySpan(child, 12)) return false;
                    text = view_as<Address>(LoadFromAddress(child + view_as<Address>(8), NumberType_Int32));
                }
                else text = view_as<Address>(LoadFromAddress(prop + view_as<Address>(40), NumberType_Int32));
                if (!WireString(data, bits, pos, childName, sizeof(childName))
                    || !TryReadString(text, actual, sizeof(actual)) || !StrEqual(actual, childName)) return false;
            }
            else if (type == 5)
            {
                if (!WireRead(data, bits, pos, 10, value)
                    || value != LoadFromAddress(prop + view_as<Address>(32), NumberType_Int32)) return false;
            }
            else
            {
                bool framingBounds = type == 0 && pos == declaredEnd;
                if (!WireRead(data, bits, pos, 32, value)
                    || (!framingBounds && value != LoadFromAddress(prop + view_as<Address>(16), NumberType_Int32))
                    || !WireRead(data, bits, pos, 32, value)
                    || (!framingBounds && value != LoadFromAddress(prop + view_as<Address>(20), NumberType_Int32))
                    || !WireRead(data, bits, pos, 6, value)
                    || value != (LoadFromAddress(prop + view_as<Address>(12), NumberType_Int32) & 63)) return false;
                if (ammo && (type || !(flags & 1) || value != 16)) return false;
            }
        }
        if (ammo) ammoSeen = true;
        if (pos == declaredEnd) continue;
        if (pos < declaredEnd || pos - start <= 32767 || pos - start > WIRE_MAX_BITS) return false;
        pendingEnd = pos; pos = declaredEnd;
    }
    return false;
}

// Read-only validation used by status/dump.  It never writes the CRC marker
// and never clears a fault.
bool CacheValid(int &bits, Address &data)
{
    if (!g_CacheReady || g_Faulted || g_CacheBuilding || g_SendTables == null) return false;
    if (!g_SendTables.BoolValue) return false;
    if (!CacheState(bits, data) || bits != g_CacheBits || CacheDigest(data, bits) != g_CacheDigest) return false;
    if (!MemorySpan(g_AmmoProps, 32 * 84)) return false;
    for (int i = 0; i < 32; i++)
        if (LoadFromAddress(g_AmmoProps + view_as<Address>(i * 84 + 12), NumberType_Int32) != 16) return false;
    return true;
}

// Concept 1: cache/schema verification.  It never requires or writes the CRC
// marker, and a cache that is still being generated is "pending", not a fault.
bool ValidateCacheAndSchema()
{
    if (!g_GuardVerified || g_Closing || g_Faulted || g_CacheBuilding) return false;
    if (g_Late && !g_CacheReady && !g_Generation)
    {
        int existingBits; Address existingData;
        if (!CacheState(existingBits, existingData) || !ParseExistingCache(existingData, existingBits))
        {
            LatchFault("Existing cache does not match the registered widened schema");
            return false;
        }
        g_CacheBits = existingBits; g_CacheDigest = CacheDigest(existingData, existingBits); g_CacheReady = true;
        LogMessage("Existing full cache verified for signon: bits=%d digest=%08x", g_CacheBits, g_CacheDigest);
    }
    if (!g_CacheReady) return false;
    int bits; Address data;
    if (!CacheValid(bits, data))
    {
        if (g_SendTables == null || !g_SendTables.BoolValue)
        { LatchFault("sv_sendtables disabled after installation"); return false; }
        LatchFault("Published cache changed outside a validated generation");
        return false;
    }
    return true;
}

// Concept 2: publish the marker at most once per controlled cycle.  A cycle is
// (map epoch, cache generation).  An already-correct marker is adopted, never
// rewritten; a marker that changes after publication is drift, not a hint to
// rewrite.  The cache and schema are always verified first.
bool PublishMarkerOnce(const char[] trigger)
{
    if (!ValidateCacheAndSchema()) return false;
    int crc = LoadFromAddress(g_LinuxCrcGlobal, NumberType_Int32);
    if (g_MarkerPublished && g_PublishedEpoch == g_MapEpoch && g_PublishedGeneration == g_Generation)
    {
        if (crc != 0x5EEDBEEF)
        { LatchFault("SendTable CRC drift after publication"); return false; }
        return true;
    }
    if (g_Faulted) return false;
    if (crc == 0x5EEDBEEF)
    {
        LogMessage("Ammo lifecycle: marker adopted plugin=%d map_epoch=%d generation=%d trigger=%s configs_seen=%d cache_digest=%08x",
            g_PluginId, g_MapEpoch, g_Generation, trigger, g_ConfigsSeen ? 1 : 0, g_CacheDigest);
    }
    else
    {
        StoreToAddress(g_LinuxCrcGlobal, 0x5EEDBEEF, NumberType_Int32);
        if (LoadFromAddress(g_LinuxCrcGlobal, NumberType_Int32) != 0x5EEDBEEF)
        { LatchFault("CRC marker readback failed"); return false; }
        g_PublishWrites++;
        LogMessage("Ammo lifecycle: marker published plugin=%d map_epoch=%d generation=%d trigger=%s previous=%08x configs_seen=%d cache_digest=%08x",
            g_PluginId, g_MapEpoch, g_Generation, trigger, crc, g_ConfigsSeen ? 1 : 0, g_CacheDigest);
    }
    g_SendTables.BoolValue = true;
    g_MarkerPublished = true;
    g_PublishedEpoch = g_MapEpoch;
    g_PublishedGeneration = g_Generation;
    return true;
}

// Lightweight publication check, used only after full cache/schema validation
// and successful publication in this same synchronous EnsureLinuxReady call.
// Within a published cycle a changed CRC is drift; this never repairs it.
bool PublishedMarkerReady()
{
    if (!g_MarkerPublished || g_PublishedEpoch != g_MapEpoch || g_PublishedGeneration != g_Generation)
        return false;
    if (LoadFromAddress(g_LinuxCrcGlobal, NumberType_Int32) != 0x5EEDBEEF)
    { LatchFault("SendTable CRC drift after publication"); return false; }
    return true;
}

bool EnsureLinuxReady(const char[] trigger)
{
    if (g_Faulted || g_Closing) return false;
    if (!PublishMarkerOnce(trigger)) return false;
    return PublishedMarkerReady();
}

// Windows admission is unchanged: one cache validation plus the marker that
// OnConfigsExecuted writes.  A late instance (the Neri variant allows Confogl
// unload_all/per-mode reload) reuses the cache the startup instance widened.
bool ReadyForSignonWindows()
{
    if (g_Late && !g_CacheReady && !g_Generation)
    {
        int existingBits; Address existingData;
        if (!CacheState(existingBits, existingData) || !ParseExistingCache(existingData, existingBits))
            LatchFault("Existing cache does not match the registered widened schema");
        else
        {
            g_CacheBits = existingBits; g_CacheDigest = CacheDigest(existingData, existingBits);
            g_CacheReady = true;
            LogMessage("Existing full cache verified for signon: bits=%d digest=%08x", g_CacheBits, g_CacheDigest);
        }
    }
    if (g_Closing || g_Faulted || !g_CacheReady || g_CacheBuilding || !g_SendTables.BoolValue) return false;
    int bits; Address data;
    if (!CacheState(bits, data) || bits != g_CacheBits || CacheDigest(data, bits) != g_CacheDigest)
    { LatchFault("Published cache changed outside a validated generation"); return false; }
    int crc = LoadFromAddress(g_EngineBase + view_as<Address>(WIN_CRC_DELTA), NumberType_Int32);
    if (crc != 0x5EEDBEEF) { LatchFault("SendTable CRC drift"); return false; }
    if (!MemorySpan(g_AmmoProps, 32 * 84)) { LatchFault("Ammo schema mapping lost"); return false; }
    for (int i = 0; i < 32; i++)
        if (LoadFromAddress(g_AmmoProps + view_as<Address>(i * 84 + 12), NumberType_Int32) != 16)
        { LatchFault("Ammo schema drift"); return false; }
    return true;
}

MRESReturn AdmissionDecision(Handle result)
{
    if (g_IsLinux)
    {
        if (EnsureLinuxReady("signon")) return MRES_Ignored;
        if (!g_Faulted && !g_CacheReady && !g_PendingLogged)
        {
            g_PendingLogged = true;
            LogMessage("Ammo lifecycle: signon pending plugin=%d map_epoch=%d generation=%d cache_validated=0 configs_seen=%d",
                g_PluginId, g_MapEpoch, g_Generation, g_ConfigsSeen ? 1 : 0);
        }
    }
    else if (ReadyForSignonWindows()) return MRES_Ignored;
    DHookSetReturn(result, false); return MRES_Supercede;
}

public MRESReturn GuardAdmission(Address client, Handle result)
{
    return AdmissionDecision(result);
}

public MRESReturn GuardLinuxAdmission(Handle result, Handle params)
{
    return AdmissionDecision(result);
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
    if (!g_IsLinux)
    {
        if (ReadyForSignonWindows()) return true;
        strcopy(rejectmsg, maxlen, "Ammo network tables are not ready. Server maintenance/restart required.");
        return false;
    }
    if (g_Faulted || g_Closing)
    {
        strcopy(rejectmsg, maxlen, "Ammo network tables are faulted. Server maintenance/restart required.");
        return false;
    }
    // The cache generation is independent of client connections, so a pending
    // state here cannot starve itself.  Publication is attempted now; the
    // native SendServerInfo gate remains the authority for actual signon.
    if (EnsureLinuxReady("connect")) return true;
    if (g_Faulted)
    {
        strcopy(rejectmsg, maxlen, "Ammo network tables are faulted. Server maintenance/restart required.");
        return false;
    }
    return true;
}

// A real cache rebuild invalidates the previous publication evidence, but it
// does not reset the fault and does not write the CRC here.
public MRESReturn GuardBaselineBefore()
{
    if (g_CacheBuilding) { LatchFault("Nested baseline build"); return MRES_Supercede; }
    g_CacheBuilding = true; g_CacheReady = false; g_MarkerPublished = false; g_Generation++;
    g_GenerationStart = g_TableCount; g_InfosBuffer = Address_Null; g_Message = Address_Null; g_Cut = 0;
    g_GenerationMessages = 0; g_InfosPending = false; g_InfosOwned = false;
    if (g_RealTableNames != null) delete g_RealTableNames;
    if (g_UsedPadding != null) delete g_UsedPadding;
    g_RealTableNames = new StringMap(); g_UsedPadding = new StringMap();
    if (g_IsLinux && !RefreshRegions()) LatchFault("Cannot refresh memory map");
    // After a fault, the table writers are suppressed and native signon stays
    // blocked, but entity baseline creation must still run for existing clients.
    return MRES_Ignored;
}

// A real cache generation rebuild invalidates the previous publication evidence.
public MRESReturn GuardBaselineAfter()
{
    if (!g_CacheBuilding) return MRES_Ignored;
    g_CacheBuilding = false;
    Address data; int bits;
    if (g_Faulted) return MRES_Ignored;
    if (g_TableCount - g_GenerationStart != g_ExpectedTables || g_GenerationMessages != g_ExpectedTables
        || g_InfosOwned || g_InfosPending || g_Message != Address_Null || g_SavedLength || !CacheState(bits, data))
    { LatchFault("Incomplete or invalid full-table cache generation"); return MRES_Ignored; }
    if (!ParseExistingCache(data, bits))
    { LatchFault("Generated full cache failed schema/framing validation"); return MRES_Ignored; }
    g_CacheBits = bits; g_CacheDigest = CacheDigest(data, bits); g_CacheReady = true;
    LogMessage("Cache generation %d validated: tables=%d bits=%d digest=%08x",
        g_Generation, g_TableCount - g_GenerationStart, bits, g_CacheDigest);
    // Windows has no connect-time publish path: the HLTV/signon gate can run
    // before OnConfigsExecuted.  Enforce the marker as soon as the generation
    // is fully validated, matching the deployed 3.3.1 behaviour.
    if (!g_IsLinux)
    {
        StoreToAddress(g_EngineBase + view_as<Address>(WIN_CRC_DELTA), 0x5EEDBEEF, NumberType_Int32);
        g_SendTables.BoolValue = true;
        LogMessage("Full-table marker enforced at cache generation %d", g_Generation);
    }
    return MRES_Ignored;
}


void InstallLifecycleHooks()
{
    Address baselineAddress = g_IsLinux ? g_LinuxBaseline : g_EngineBase + view_as<Address>(WINDOWS_BASELINE_RVA);
    Address admissionAddress = g_IsLinux ? g_LinuxAdmission : g_EngineBase + view_as<Address>(WINDOWS_ADMISSION_RVA);
    g_BaselineHook = DHookCreateDetour(baselineAddress, CallConv_CDECL, ReturnType_Void, ThisPointer_Ignore);
    if (g_BaselineHook == null) SetFailState("Cannot create cache lifecycle detour");
    g_BaselinePre = DHookEnableDetour(g_BaselineHook, false, GuardBaselineBefore);
    g_BaselinePost = DHookEnableDetour(g_BaselineHook, true, GuardBaselineAfter);
    g_AdmissionHook = DHookCreateDetour(admissionAddress,
        g_IsLinux ? CallConv_CDECL : CallConv_THISCALL, ReturnType_Bool, g_IsLinux ? ThisPointer_Ignore : ThisPointer_Address);
    if (g_AdmissionHook == null) SetFailState("Cannot create native signon gate");
    if (g_IsLinux) DHookAddParam(g_AdmissionHook, HookParamType_Int);
    if (g_IsLinux) g_AdmissionPre = DHookEnableDetour(g_AdmissionHook, false, GuardLinuxAdmission);
    else g_AdmissionPre = DHookEnableDetour(g_AdmissionHook, false, GuardAdmission);
    if (!g_IsLinux)
    {
        g_HLTVHook = DHookCreateDetour(g_EngineBase + view_as<Address>(WINDOWS_HLTV_RVA), CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address);
        if (g_HLTVHook == null) SetFailState("Cannot create HLTV signon gate");
        g_HLTVPre = DHookEnableDetour(g_HLTVHook, false, GuardAdmission);
    }
    if (!g_BaselinePre || !g_BaselinePost || !g_AdmissionPre || (!g_IsLinux && !g_HLTVPre)) SetFailState("Lifecycle hook installation incomplete");
}

void RemoveLifecycleHooks()
{
    if (g_BaselinePre) DHookDisableDetour(g_BaselineHook, false, GuardBaselineBefore);
    if (g_BaselinePost) DHookDisableDetour(g_BaselineHook, true, GuardBaselineAfter);
    if (g_AdmissionPre)
    {
        if (g_IsLinux) DHookDisableDetour(g_AdmissionHook, false, GuardLinuxAdmission);
        else DHookDisableDetour(g_AdmissionHook, false, GuardAdmission);
    }
    if (g_HLTVPre) DHookDisableDetour(g_HLTVHook, false, GuardAdmission);
}

