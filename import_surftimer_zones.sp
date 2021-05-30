#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <fuckZones>

ArrayList g_aZones = null;
ArrayList g_aMaps = null;
Database g_dDB = null;

enum struct eImportZone
{
	char Name[MAX_ZONE_NAME_LENGTH];
	int Type;
	float Start[3];
	float End[3];
	float Origin[3];
	char OriginName[32];
	float Teleport[3];
	float Radius;
	char Color[64];
	int iColors[4];
	ArrayList PointsData;
	float PointsHeight;
	StringMap Effects;
	int Display;
	bool SetName;
	bool Show;
	int ID;
	char Map[32];
	int Tier;
	int MaxSpeed;
}

public void OnPluginStart()
{
	RegAdminCmd("sm_importzones", Command_ImportZones, ADMFLAG_ROOT);
}

public void OnMapStart()
{
	delete g_aMaps;
	delete g_aZones;
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

	g_dDB = db;

	char sIdent[8];
	db.Driver.GetIdentifier(sIdent, sizeof(sIdent));

	if (!StrEqual(sIdent, "mysql", false))
	{
		SetFailState("Your database driver is not \"mysql\"...");
		return;
	}

	PrintToServer("Loading zones...");

	char sQuery[256];
	db.Format(sQuery, sizeof(sQuery), "SELECT mapname, zoneid, zonetype, zonetypeid, zonegroup, pointa_x, pointa_y, pointa_z, pointb_x, pointb_y, pointb_z, hookname, prespeed FROM ck_zones ORDER BY mapname ASC, zonegroup ASC, zonetype ASC, zonetypeID ASC;");
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

		delete g_aZones;
		delete g_aMaps;

		g_aZones = new ArrayList(sizeof(eImportZone));
		g_aMaps = new ArrayList(ByteCountToCells(64));

		while (results.FetchRow())
		{
			char sMap[32], sHookName[32];

			int iZoneID;
			int iZoneType;
			int iZoneTypeID;
			int iZoneGroup;
			int iMaxSpeed;

			float fPointA[3], fPointB[3];
			
			results.FetchString(0, sMap, sizeof(sMap));
			results.FetchString(11, sHookName, sizeof(sHookName));

			iZoneID = results.FetchInt(1);
			iZoneType = results.FetchInt(2);
			iZoneTypeID = results.FetchInt(3);
			iZoneGroup = results.FetchInt(4);

			fPointA[0] = results.FetchFloat(5);
			fPointA[1] = results.FetchFloat(6);
			fPointA[2] = results.FetchFloat(7);

			fPointB[0] = results.FetchFloat(8);
			fPointB[1] = results.FetchFloat(9);
			fPointB[2] = results.FetchFloat(10);

			iMaxSpeed = results.FetchInt(12);

			char sName[MAX_ZONE_NAME_LENGTH];
			bool bBonus = false;

			if (iZoneGroup > 0)
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
				PrepareZone(sName, sMap, iZoneID, iZoneType, iZoneTypeID + 2, iZoneGroup, bBonus, fPointA, fPointB, sHookName, iMaxSpeed);
			}
		}

		PrintToServer("Zone data prepared...");
		PrintToServer("Sort array...");
		SortArray();
		PrintToServer("Array sorted...");
		PrintToServer("Creating zone files...");
		IterateMaps();
		PrintToServer("Zone files created.");
	}
}

void PrepareZone(const char[] name, const char[] map, int id, int type, int typeid, int group, bool bonus, float[3] pointA, float[3] pointB, const char[] hookname, int maxspeed)
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

	eImportZone data;
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
	data.ID = id;
	data.MaxSpeed = maxspeed;
	strcopy(data.Map, sizeof(eImportZone::Map), map);

	g_aZones.PushArray(data, sizeof(data));

	if (g_aMaps.FindString(map) == -1)
	{
		g_aMaps.PushString(map);
	}
}

void SortArray()
{
	SortADTArrayCustom(g_aZones, Sorting);
}

public int Sorting(int i, int j, Handle array, Handle hndl)
{
    eImportZone zone1;
    eImportZone zone2;

    g_aZones.GetArray(i, zone1);
    g_aZones.GetArray(j, zone2);

    return strcmp(zone1.Name, zone2.Name);
}

void IterateMaps()
{
	char sMap[64];
	for (int i = 0; i < g_aMaps.Length; ++i)
	{
		g_aMaps.GetString(i, sMap, sizeof(sMap));

		PrintToServer("Loading tier for map %s...", sMap);

		DataPack pack = new DataPack();
		pack.WriteString(sMap);

		char sQuery[256];
		g_dDB.Format(sQuery, sizeof(sQuery), "SELECT tier FROM ck_maptier WHERE mapname = \"%s\"", sMap);
		g_dDB.Query(SQL_GetMapTier, sQuery, pack);
	}

	delete g_aMaps;
}

public void SQL_GetMapTier(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (db == null || strlen(error) > 0)
	{
		LogError("(SQL_GetMapTier) Query failed: %s", error);
		return;
	}

	char sMap[32];
	pack.Reset();
	pack.ReadString(sMap, sizeof(sMap));
	delete pack;

	if (results.HasResults && results.FetchRow())
	{
		int iTier = results.FetchInt(0);

		LoopZonesAndCreate(sMap, iTier);
		PrintToServer("Tier loaded for map %s (Tier: %d)", sMap, iTier);

		return;
	}
	else
	{
		LoopZonesAndCreate(sMap, 0);
		PrintToServer("Tier not loaded for map %s (Tier: 0)", sMap);
	}
}

void LoopZonesAndCreate(const char[] map, int tier)
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

	eImportZone data;

	for (int i = 0; i < g_aZones.Length; i++)
	{
		g_aZones.GetArray(i, data, sizeof(data));

		if (StrContains(data.Map, map, false) != -1)
		{
			data.Tier = tier;
			AddZone(kv, data);
		}
	}

	kv.ExportToFile(sFile);
	delete kv;
}

bool AddZone(KeyValues kv, eImportZone data)
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
		kv.SetNum("maxspeed", data.MaxSpeed);
		kv.SetFloat("radius", data.Radius);

		if (kv.JumpToKey("effects", true))
		{
			if (kv.JumpToKey("fuckTimer", true))
			{
				if (StrContains(data.Name, "main", false) != -1 && StrContains(data.Name, "start", false) != -1)
				{
					kv.SetNum("tier", data.Tier);
				}

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
