// Linux addresses come from SourceMod gamedata; offsets match both audited builds.
#define LINUX_SV_CACHE_BITS_OFFSET 0x248
#define LINUX_SV_CACHE_OVERFLOW_OFFSET 0x24C
#define LINUX_SV_CACHE_DATA_OFFSET 0x254
#define LINUX_MESSAGE_LENGTH_OFFSET 0x84
#define LINUX_MESSAGE_DATA_OFFSET 0x78

void ResolveLinux()
{
    g_BaselineAddr = RequiredAddress("EngineCreateBaselineAddr");
    g_AdmissionAddr = RequiredAddress("EngineAdmissionAddr");
    g_AllocAddr = RequiredAddress("EngineAllocAddr");
    g_MessageAddr = RequiredAddress("EngineMessageAddr");
    g_BitsAddr = RequiredAddress("EngineWriteBitsAddr");
    g_Layout.crc = RequiredAddress("EngineCrcGlobalAddr");
    Address sv = RequiredAddress("EngineServerObjectAddr");
    g_Layout.cacheBits = sv + view_as<Address>(LINUX_SV_CACHE_BITS_OFFSET);
    g_Layout.cacheOverflow = sv + view_as<Address>(LINUX_SV_CACHE_OVERFLOW_OFFSET);
    g_Layout.cacheData = sv + view_as<Address>(LINUX_SV_CACHE_DATA_OFFSET);
    g_Layout.messageLengthOffset = LINUX_MESSAGE_LENGTH_OFFSET;
    g_Layout.messageDataOffset = LINUX_MESSAGE_DATA_OFFSET;
    g_Layout.scratchBytes = LINUX_SCRATCH_BYTES;
}
