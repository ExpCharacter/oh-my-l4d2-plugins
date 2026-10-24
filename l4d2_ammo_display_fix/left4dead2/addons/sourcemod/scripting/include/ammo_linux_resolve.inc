void ResolveLinux()
{
    g_BaselineAddr = RequiredSignature("EngineCreateBaseline");
    g_AdmissionAddr = RequiredSignature("EngineAdmission");
    g_AllocAddr = RequiredSignature("EngineAlloc");
    g_MessageAddr = RequiredSignature("EngineMessage");
    g_BitsAddr = RequiredSignature("EngineWriteBits");
    g_Layout.crc = RequiredSignature("EngineCrcGlobal");
    Address sv = RequiredSignature("EngineServerObject");
    g_Layout.cacheBits = sv + view_as<Address>(g_Conf.GetOffset("Server.CacheBits"));
    g_Layout.cacheOverflow = sv + view_as<Address>(g_Conf.GetOffset("Server.CacheOverflow"));
    g_Layout.cacheData = sv + view_as<Address>(g_Conf.GetOffset("Server.CacheData"));
    g_Layout.messageLengthOffset = g_Conf.GetOffset("SendTable.MessageLengthOffset");
    g_Layout.messageDataOffset = g_Conf.GetOffset("SendTable.MessageDataOffset");
    g_Layout.cacheBytes = g_Conf.GetOffset("SendTable.CacheBytes");
    g_Layout.scratchBytes = LINUX_SCRATCH_BYTES;
}
