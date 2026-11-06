void ResolveWindows()
{
    g_BaselineAddr = RequiredSignature("EngineCreateBaseline");
    g_AdmissionAddr = RequiredSignature("EngineAdmission");
    g_HltvAddr = RequiredSignature("EngineHltv");
    g_MessageAddr = RequiredSignature("EngineMessage");
    g_BitsAddr = RequiredSignature("EngineWriteBits");
    g_UnsignedAddr = RequiredSignature("EngineWriteUnsigned");
    g_Layout.crc = RequiredAddress("EngineCrcGlobal");
    // One bf_write instance holds the send-table buffer, its bit count and its
    // overflow flag; both samples expose the same bf_write field offsets.
    Address buffer = RequiredAddress("EngineTableBuffer");
    g_Layout.cacheData = buffer + view_as<Address>(g_Buffer.data);
    g_Layout.cacheBits = buffer + view_as<Address>(g_Buffer.cursor);
    g_Layout.cacheOverflow = buffer + view_as<Address>(g_Buffer.overflow);
    g_Layout.messageLengthOffset = view_as<int>(RequiredAddress("SendTable.MessageLengthOffset"));
    g_Layout.messageDataOffset = view_as<int>(RequiredAddress("SendTable.MessageDataOffset"));
    g_Layout.cacheBytes = view_as<int>(RequiredAddress("EngineCacheBytes"));
    g_Layout.scratchBytes = SCRATCH_BYTES;
    // The scratch allocator and its release are the pair CreateBaseline uses
    // around the send-table cache write.
    g_AllocAddr = CallTarget(RequiredSignature("EngineScratchAllocCall"));
    g_FreeAddr = CallTarget(RequiredAddress("EngineScratchFreeCall"));
}
