#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <fuckZones>

StringMap g_smZones = null;
ArrayList g_aMaps = null;

public void OnPluginStart()
{
	RegAdminCmd("sm_importzones", Command_ImportZones, ADMFLAG_ROOT);
}

public Action Command_ImportZones(int client, int args)
{
	if (!SQL_CheckConfig("surftimer"))
	{
		SetFailState("Can not find the \"surftimer\" database entry in your databases.cfg...");
		return;
	}

	PrintToServer("Connecting to database...");

	Database.Connect(OnConnect, "surftimer");
}

public void OnConnect(Database db, const char[] error, any data)
{
	if (db == null || strlen(error))
	{
		SetFailState("Unable to connect to database... Error: %s", error);
		return;
	}

	PrintToServer("Connected to database...");

	char sIdent[8];
	db.Driver.GetIdentifier(sIdent, sizeof(sIdent));

	if (!StrEqual(sIdent, "mysql", false))
	{
		SetFailState("Your database driver is not \"mysql\"...");
		return;
	}

	PrintToServer("Loading zones...");

	char sQuery[156];
	db.Format(sQuery, sizeof(sQuery), "SELECT mapname, zoneid, zonetype, zonetypeid, zonegroup, pointa_x, pointa_y, pointa_z, pointb_x, pointb_y, pointb_z, hookname FROM ck_zones;");
	db.Query(sql_GetZones, sQuery);
}

public void sql_GetZones(Database db, DBResultSet results, const char[] error, int userid)
{
	if (db == null || strlen(error) > 0)
	{
		LogError("(sql_GetZones) Query failed: %s", error);
		return;
	}

	PrintToServer("Zones loaded...");

	if (results.HasResults)
	{
		PrintToServer("Found %d zone entries...", results.RowCount);
		PrintToServer("Preparing zone data...", results.RowCount);

		delete g_smZones;
		delete g_aMaps;

		g_smZones = new StringMap();
		g_aMaps = new ArrayList(ByteCountToCells(64));

		int count = 1;
		while (results.FetchRow())
		{
			char sMap[32], sHookName[32];

			int iZoneID;
			int iZoneType;
			int iZoneTypeID;
			int iZoneGroup;

			float fPointA[3], fPointB[3];
			
			results.FetchString(0, sMap, sizeof(sMap));
			results.FetchString(11, sHookName, sizeof(sHookName));

			iZoneID = results.FetchInt(1); if (iZoneID) {} // Workaround
			iZoneType = results.FetchInt(2);
			iZoneTypeID = results.FetchInt(3); if (iZoneTypeID) {} // Workaround
			iZoneGroup = results.FetchInt(4);

			fPointA[0] = results.FetchFloat(5);
			fPointA[1] = results.FetchFloat(6);
			fPointA[2] = results.FetchFloat(7);

			fPointB[0] = results.FetchFloat(8);
			fPointB[1] = results.FetchFloat(9);
			fPointB[2] = results.FetchFloat(10);

			char sName[MAX_ZONE_NAME_LENGTH];
			bool bBonus = false;

			if (iZoneGroup > 0) // Bonus Zones
			{
				FormatEx(sName, sizeof(sName), "bonus%d_%s", iZoneGroup, iZoneType == 1 ? "start" : "end");
				bBonus = true;
			}
			else
			{
				if (iZoneType == 0)
				{
					FormatEx(sName, sizeof(sName), "stop%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 1)
				{
					FormatEx(sName, sizeof(sName), "main%d_start", iZoneGroup);
				}
				else if (iZoneType == 2)
				{
					FormatEx(sName, sizeof(sName), "main%d_end", iZoneGroup);
				}
				else if (iZoneType == 3)
				{
					FormatEx(sName, sizeof(sName), "stage%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 4)
				{
					FormatEx(sName, sizeof(sName), "checkpoint%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 5)
				{
					FormatEx(sName, sizeof(sName), "speed%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 6)
				{
					FormatEx(sName, sizeof(sName), "teletostart%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 7)
				{
					FormatEx(sName, sizeof(sName), "validator%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 8)
				{
					FormatEx(sName, sizeof(sName), "checker%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 9)
				{
					FormatEx(sName, sizeof(sName), "antijump%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 10)
				{
					FormatEx(sName, sizeof(sName), "antiduck%d", iZoneTypeID + 2);
				}
				else if (iZoneType == 11)
				{
					FormatEx(sName, sizeof(sName), "maxspeed%d", iZoneTypeID + 2);
				}
			}

			if (strlen(sName) > 2)
			{
				PrepareZone(sName, sMap, iZoneType, iZoneTypeID + 2, iZoneGroup, bBonus, fPointA, fPointB, sHookName, count);
				count++;
			}
		}

		PrintToServer("Zone data prepared...");
		PrintToServer("Creating zone files...");
		IterateMaps();
		PrintToServer("Zone files created.");
	}
}

void PrepareZone(const char[] name, const char[] map, int type, int typeid, int group, bool bonus, float[3] pointA, float[3] pointB, const char[] hookname, int count)
{
	bool bTrigger = false;

	if (fuckZones_IsPositionNull(pointA) || fuckZones_IsPositionNull(pointB))
	{
		bTrigger = true;
	}

	int iColor[4];

	if (type == 1)
	{
		iColor = {0, 255, 255, 255};
	}
	else
	{
		iColor = {255, 0, 255, 255};
	}

	char sColor[16];
	fuckZones_GetColorNameByCode(iColor, sColor, sizeof(sColor));

	// PrintToServer("%d, Color: %s (%d %d %d %d)", success, sColor, iColor[0], iColor[1], iColor[2], iColor[3]);

	StringMap smKeys = new StringMap();

	char sBuffer[12];

	IntToString(group, sBuffer, sizeof(sBuffer));
	smKeys.SetString("Bonus", sBuffer);
	
	smKeys.SetString("Start", type == 1 ? "1" : "0");
	smKeys.SetString("End", type == 2 ? "1" : "0");

	IntToString(typeid, sBuffer, sizeof(sBuffer));
	smKeys.SetString("Stage", type == 3 ? sBuffer : "0");

	IntToString(typeid, sBuffer, sizeof(sBuffer));
	smKeys.SetString("Checkpoint", type == 4 ? sBuffer : "0");

	smKeys.SetString("Misc", !bonus && (type == 0 || type > 4) ? "1" : "0");
	smKeys.SetString("Speed", type == 5 ? "1" : "0");
	smKeys.SetString("TeleToStart", type == 6 ? "1" : "0");
	smKeys.SetString("Validator", type == 7 ? "1" : "0");
	smKeys.SetString("Checker", type == 8 ? "1" : "0");
	smKeys.SetString("Stop", type == 0 ? "1" : "0");

	eCreateZone data;
	strcopy(data.Name, MAX_ZONE_NAME_LENGTH, name);
	data.Type = bTrigger ? ZONE_TYPE_TRIGGER : ZONE_TYPE_BOX;
	data.Start = pointA;
	data.End = pointB;
	data.Origin = view_as<float>({0.0, 0.0, 0.0});
	
	if (strlen(hookname) < 1 || StrEqual(hookname, "none", false))
	{
		strcopy(data.OriginName, MAX_ZONE_NAME_LENGTH, data.Name);
	}
	else
	{
		strcopy(data.OriginName, MAX_ZONE_NAME_LENGTH, hookname);
	}

	data.Teleport = view_as<float>({0.0, 0.0, 0.0});
	data.Radius = 10.0;
	strcopy(data.Color, sizeof(sColor), sColor);
	data.iColors = iColor;
	data.PointsData = null;
	data.PointsHeight = 10.0;
	data.Effects = smKeys;
	data.Display = FindConVar("fuckZones_default_display").IntValue;
	data.SetName = false;
	data.Show = false;
	data.Trigger = -1;

	char sKey[64];
	FormatEx(sKey, sizeof(sKey), "%s%d", map, count);
	g_smZones.SetArray(sKey, data, sizeof(data));

	if (g_aMaps.FindString(map) == -1)
	{
		g_aMaps.PushString(map);
	}
}

void IterateMaps()
{
	char sMap[64];
	for (int i = 0; i < g_aMaps.Length; ++i)
	{
		g_aMaps.GetString(i, sMap, sizeof(sMap));
		LoopZonesAndCreate(sMap);
	}

	delete g_smZones;
	delete g_aMaps;
}

void LoopZonesAndCreate(const char[] map)
{
	char sPath[PLATFORM_MAX_PATH + 1];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/zones/");

	char sFile[PLATFORM_MAX_PATH + 1];
	FormatEx(sFile, sizeof(sFile), "%s%s.zon", sPath, map);

	KeyValues kv;

	kv = new KeyValues("zones");

	if (!FileExists(sFile))
	{
		kv.ExportToFile(sFile);
		delete kv;
	}
	
	kv = new KeyValues("zones");
	kv.ImportFromFile(sFile);

	StringMapSnapshot snap = g_smZones.Snapshot();

	eCreateZone data;
	char sKey[64];

	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, sKey, sizeof(sKey));

		if (StrContains(sKey, map, false) != -1)
		{
			g_smZones.GetArray(sKey, data, sizeof(data));
			AddZone(kv, data);
		}
	}

	kv.ExportToFile(sFile);
	delete kv;
	delete snap;
}

bool AddZone(KeyValues kv, eCreateZone data)
{
	if (kv.JumpToKey(data.Name, true))
	{
		char sColor[64];
		FormatEx(sColor, sizeof(sColor), "%i %i %i %i", data.iColors[0], data.iColors[1], data.iColors[2], data.iColors[3]);

		char sDisplay[12];
		fuckZones_GetDisplayNameByType(data.Display, sDisplay, sizeof(sDisplay));

		kv.SetString("type", data.Type == ZONE_TYPE_BOX ? "Box" : "Trigger");
		kv.SetString("color", sColor);
		kv.SetString("display", sDisplay);
		kv.SetVector("start", data.Start);
		kv.SetVector("end", data.End);
		kv.SetVector("origin", data.Origin);
		kv.SetString("origin_name", data.OriginName);
		kv.SetFloat("radius", data.Radius);

		if (kv.JumpToKey("effects", true))
		{
			if (kv.JumpToKey("fuckTimer", true))
			{
				StringMapSnapshot snap = data.Effects.Snapshot();

				char sKey[MAX_KEY_NAME_LENGTH], sValue[MAX_KEY_VALUE_LENGTH];

				for (int i = 0; i < snap.Length; i++)
				{
					snap.GetKey(i, sKey, sizeof(sKey));
					if (data.Effects.GetString(sKey, sValue, sizeof(sValue)))
					{
						kv.SetString(sKey, sValue);
					}
				}

				delete snap;
			}
			kv.GoBack();
		}
		kv.GoBack();
	}
	kv.GoBack();
}
