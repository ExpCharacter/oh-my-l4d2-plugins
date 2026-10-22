/*
 * l4d2_ammo_digits_ext
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

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
	name = "L4D2 Ammo Digits (SendTable extension)",
	author = "ExpCharacter",
	description = "Widen m_iAmmo to 16 bits through sendtable.ext",
	version = PLUGIN_VERSION,
	url = "https://github.com/ExpCharacter/oh-my-l4d2-plugins"
};

public void OnPluginStart()
{
	RegServerCmd("sm_ammodigits_ext_status", Cmd_Status);

	// Confogl unloads and reloads plugins per mode. The first load widens the
	// schema; later loads must accept the already widened state, because
	// expectedBits=10 would fail once the width is 16.
	int bits = SendTable.GetBits("CTerrorPlayer", "m_iAmmo");
	if (bits == 16)
	{
		LogMessage("m_iAmmo already 16 bits; patch from an earlier load is still active");
		return;
	}
	if (bits != 10)
		SetFailState("m_iAmmo unexpected width %d (expected 10 or 16)", bits);

	// expectedBits guards against a game update changing the vanilla width:
	// the call fails instead of widening an already different schema.
	if (!SendTable.SetElementBits("CTerrorPlayer", "m_iAmmo", 16, 10))
		SetFailState("m_iAmmo widen failed: class/prop missing or expectedBits mismatch");

	LogMessage("m_iAmmo widened to 16 bits through sendtable.ext");
}

public Action Cmd_Status(int args)
{
	#pragma unused args
	int bits = SendTable.GetBits("CTerrorPlayer", "m_iAmmo");
	PrintToServer("[ammo-ext] m_iAmmo bits=%d expected=16", bits);
	return Plugin_Handled;
}
