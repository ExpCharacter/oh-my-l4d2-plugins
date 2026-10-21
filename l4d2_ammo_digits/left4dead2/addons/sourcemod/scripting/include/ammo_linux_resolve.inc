// Linux addresses come from SourceMod gamedata; offsets match both audited builds.
#define LINUX_SV_CACHE_BITS_OFFSET 0x248
#define LINUX_SV_CACHE_OVERFLOW_OFFSET 0x24C
#define LINUX_SV_CACHE_DATA_OFFSET 0x254
#define LINUX_MESSAGE_LENGTH_OFFSET 0x84
#define LINUX_MESSAGE_DATA_OFFSET 0x78

Address g_ServerFactory, g_LinuxClasses, g_LinuxBaseline, g_LinuxAdmission;
Address g_LinuxAlloc, g_LinuxMessage, g_LinuxBits, g_LinuxCrcGlobal;
Address g_LinuxCacheBits, g_LinuxCacheOverflow, g_LinuxCacheData;

Address LinuxRequireAddress(const char[] key)
{
    Address address = g_Conf.GetAddress(key);
    if (address == Address_Null) SetFailState("Missing Linux symbol: %s", key);
    return address;
}

void VerifyBuildLinux(Address serverFactory)
{
    g_ServerFactory = serverFactory;
    g_LinuxClasses = LinuxRequireAddress("ServerClassesAddr");
    g_LinuxBaseline = LinuxRequireAddress("EngineCreateBaselineAddr");
    g_LinuxAdmission = LinuxRequireAddress("EngineAdmissionAddr");
    g_LinuxAlloc = LinuxRequireAddress("EngineAllocAddr");
    g_LinuxMessage = LinuxRequireAddress("EngineMessageAddr");
    g_LinuxBits = LinuxRequireAddress("EngineWriteBitsAddr");
    g_LinuxCrcGlobal = LinuxRequireAddress("EngineCrcGlobalAddr");
    Address sv = LinuxRequireAddress("EngineServerObjectAddr");
    g_LinuxCacheBits = sv + view_as<Address>(LINUX_SV_CACHE_BITS_OFFSET);
    g_LinuxCacheOverflow = sv + view_as<Address>(LINUX_SV_CACHE_OVERFLOW_OFFSET);
    g_LinuxCacheData = sv + view_as<Address>(LINUX_SV_CACHE_DATA_OFFSET);
}
