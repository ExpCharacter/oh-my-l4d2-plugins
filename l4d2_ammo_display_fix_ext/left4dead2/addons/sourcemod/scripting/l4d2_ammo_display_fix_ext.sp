/*
 * l4d2_ammo_display_fix_ext
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
//
// Widens m_iAmmo through the sendtable extension by Crimson-DawnLight:
//   https://github.com/Crimson-DawnLight/L4D2MutiMod (extensions/sendtable, v1.0.0)
// The extension is a separate binary; this plugin only calls its natives and
// does not embed or modify its code. Schema patching, buffer growth, framing
// and the CRC marker all live inside the extension.
// Requires SourceMod 1.12; the extension refuses SM 1.11 (IPlayerManager).
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sendtable>

#define PLUGIN_VERSION "1.0.2"

#define AMMO_CLASS        "CTerrorPlayer"
#define AMMO_TABLE        "m_iAmmo"
#define AMMO_BITS_VANILLA 10
#define AMMO_BITS_TARGET  16

bool g_WaitForMap;

public Plugin myinfo =
{
	name = "L4D2 Ammo Display Fix (SendTable extension)",
	author = "ExpCharacter",
	description = "Widen m_iAmmo to 16 bits through sendtable.ext",
	version = PLUGIN_VERSION,
	url = "https://github.com/ExpCharacter/oh-my-l4d2-plugins"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int maxlength)
{
	g_WaitForMap = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	RegServerCmd("sm_ammodisplay_ext_status", Cmd_Status);

	if (g_WaitForMap)
	{
		LogMessage("Late load: waiting for the next map initialization before widening %s", AMMO_TABLE);
		return;
	}

	ApplyAmmoBits();
}

public void OnMapInit(const char[] mapName)
{
	// Unlike OnMapStart, this is not replayed when a plugin is hot-loaded.
	if (!g_WaitForMap) return;
	g_WaitForMap = false;
	ApplyAmmoBits();
}

void ApplyAmmoBits()
{
	// Confogl can reload this plugin while the table is already widened.
	int bits = SendTable.GetBits(AMMO_CLASS, AMMO_TABLE);
	if (bits == -1)
		SetFailState("%s.%s not found; the send table layout changed", AMMO_CLASS, AMMO_TABLE);

	if (bits == AMMO_BITS_TARGET)
	{
		LogMessage("%s already %d bits; no change needed", AMMO_TABLE, bits);
		return;
	}

	if (bits != AMMO_BITS_VANILLA)
		SetFailState("%s is %d bits, expected %d (vanilla) or %d (widened)",
			AMMO_TABLE, bits, AMMO_BITS_VANILLA, AMMO_BITS_TARGET);

	// expectedBits guards against a game update changing the vanilla width:
	// the call fails instead of widening an already different schema.
	if (!SendTable.SetElementBits(AMMO_CLASS, AMMO_TABLE, AMMO_BITS_TARGET, AMMO_BITS_VANILLA))
		SetFailState("%s widen failed: class/prop missing or expectedBits mismatch", AMMO_TABLE);

	LogMessage("%s widened to %d bits through sendtable.ext", AMMO_TABLE, AMMO_BITS_TARGET);
}

public Action Cmd_Status(int args)
{
	#pragma unused args
	int bits = SendTable.GetBits(AMMO_CLASS, AMMO_TABLE);
	PrintToServer("[ammodisplay-ext] %s bits=%d expected=%d waiting_for_map=%d", AMMO_TABLE, bits, AMMO_BITS_TARGET, g_WaitForMap);
	return Plugin_Handled;
}
