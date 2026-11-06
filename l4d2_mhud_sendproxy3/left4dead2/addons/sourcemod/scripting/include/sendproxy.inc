#if defined _SENDPROXYMANAGER_INC_
	#endinput
#endif
#define _SENDPROXYMANAGER_INC_

#define SENDPROXY_LIB "sendproxy3"

enum SendPropType
{
	Prop_Int,
	Prop_Float,
	Prop_String,
	Prop_EHandle,
	Prop_Max
};

methodmap EHandle {
	public EHandle(int entRef) {
		int hndl = entRef & ~(1<<31);	
		return view_as<EHandle>(hndl);
	}
};

/**
 * Queue an entity property override, applied while the server packs entities
 * for that client.
 *
 * @note Every native below returns false without queueing anything when client
 *       is outside 1 .. MaxClients, or when entRef does not resolve to a live
 *       entity on the server.
 * @note AddChangeString also returns false when str does not fit in maxLen
 *       bytes including the terminator. It is never silently truncated.
 */
methodmap SendProxy {
	public static native bool AddChangeCell(int client, int entRef, int offset, int value);
	public static native bool AddChangeFloat(int client, int entRef, int offset, float value);
	public static native bool AddChangeEHandle(int client, int entRef, int offset, EHandle value);
	public static native bool AddChangeString(int client, int entRef, int offset, const char[] str, int maxLen);
}

/**
 * Called before entity properties are packed for network transmission.
 * Plugins can use this forward to queue property modifications
 * by calling SendProxy.AddChangeCell() etc.
 *
 * @note This forward is executed every frame on the main thread and
 * should not be used for computationally expensive operations.
 * It is recommended to use SDKHook_PreThink or similar per-client hooks
 * instead of this global forward for most use cases.
 */
forward void OnSendProxyPre();

public __ext_sendproxymanager_SetNTVOptional()
{
#if !defined REQUIRE_EXTENSIONS
    MarkNativeAsOptional("SendProxy.AddChangeCell");
	MarkNativeAsOptional("SendProxy.AddChangeFloat");
	MarkNativeAsOptional("SendProxy.AddChangeEHandle");
	MarkNativeAsOptional("SendProxy.AddChangeString");
#endif  
}

public Extension __ext_sendproxymanager = 
{
	name = "SendProxy Manager",
	file = "sendproxy.ext",
#if defined AUTOLOAD_EXTENSIONS
	autoload = 1,
#else
	autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};