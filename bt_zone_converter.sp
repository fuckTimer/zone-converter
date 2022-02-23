/*
	TODO
		default value for prespeed
		default value for maxvelocity
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <fuckZones>
#include <ripext>

ArrayList g_aZones = null;
ArrayList g_aMaps = null;
Database g_dDB = null;
char g_sPrefix[16];
StringMap g_smTiers = null;

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
	int MaxVelocity;
}

public void OnPluginStart()
{
	RegAdminCmd("sm_importzones", Command_ImportZones, ADMFLAG_ROOT);
	RegAdminCmd("sm_genmaptiers", Command_GenMaptiers, ADMFLAG_ROOT);
}

public void OnMapStart()
{
	delete g_aMaps;
	delete g_aZones;
}

public Action Command_ImportZones(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_importzones <database> [table prefix]");
		return Plugin_Handled;
	}

	char sDatabase[24];
	GetCmdArg(1, sDatabase, sizeof(sDatabase));

	if (!SQL_CheckConfig(sDatabase))
	{
		SetFailState("Can not find the \"%s\" database entry in your databases.cfg...", sDatabase);
		return Plugin_Handled;
	}

	GetCmdArg(2, g_sPrefix, sizeof(g_sPrefix));

	PrintToServer("Connecting to database...");

	Database.Connect(OnConnect, sDatabase);

	return Plugin_Handled;
}

public Action Command_GenMaptiers(int client, int args)
{
	if (g_smTiers == null)
	{
		SetFailState("Stringmap is null");
		return;
	}

	JSONObject jObj = new JSONObject();
	
	StringMapSnapshot snap = g_smTiers.Snapshot();

	for (int i = 0; i < snap.Length; i++)
	{
		char sMap[64];
		int iTier = 0;
		snap.GetKey(i, sMap, sizeof(sMap));
		g_smTiers.GetValue(sMap, iTier);
		jObj.SetInt(sMap, iTier);
	}

	char sFile[PLATFORM_MAX_PATH + 1];
	BuildPath(Path_SM, sFile, sizeof(sFile), "data/maptiers.json");
	jObj.ToFile(sFile);

	delete jObj;
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

	char sQuery[512];
	db.Format(sQuery, sizeof(sQuery), "SELECT map, track, type, data, corner1_x, corner1_y, corner1_z, corner2_x, corner2_y, corner2_z, destination_x, destination_y, destination_z, id FROM %smapzones ORDER BY map ASC, track ASC, type ASC, data ASC;",
	g_sPrefix);
	db.Query(sql_GetZones, sQuery);
}

public void sql_GetZones(Database db, DBResultSet results, const char[] error, any data)
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
			char sMap[MAX_NAME_LENGTH];
			results.FetchString(0, sMap, sizeof(sMap));
			int iTrack = results.FetchInt(1);
			int iType = results.FetchInt(2);
			int iData = results.FetchInt(3);
			int iId = results.FetchInt(13);

			float fPointA[3], fPointB[3], fDestination[3];
			fPointA[0] = results.FetchFloat(4);
			fPointA[1] = results.FetchFloat(5);
			fPointA[2] = results.FetchFloat(6);
			fPointB[0] = results.FetchFloat(7);
			fPointB[1] = results.FetchFloat(8);
			fPointB[2] = results.FetchFloat(9);
			fDestination[0] = results.FetchFloat(10);
			fDestination[1] = results.FetchFloat(11);
			fDestination[2] = results.FetchFloat(12);


			char sName[MAX_ZONE_NAME_LENGTH];
			bool bBonus = false;
			
			if (iTrack > 0)
			{
				bBonus = true;
			}

			char sBuffer[12];
			if (bBonus)
			{
				FormatEx(sBuffer, sizeof(sBuffer), "_bonus%d", iTrack);
			}

			if (iType == 0)
			{
				FormatEx(sName, sizeof(sName), "%s%d_start", bBonus ? "bonus" : "main", iTrack);
			}
			else if (iType == 1)
			{
				FormatEx(sName, sizeof(sName), "%s%d_end", bBonus ? "bonus" : "main", iTrack);
			}
			else if (iType == 2 || iType == 4)
			{
				FormatEx(sName, sizeof(sName), "slay%d%s", iData, sBuffer);
			}
			else if (iType == 7)
			{
				FormatEx(sName, sizeof(sName), "teleport%d%s", iData, sBuffer);
			}
			else if (iType == 12)
			{
				FormatEx(sName, sizeof(sName), "stage%d%s", iData, sBuffer);
			}

			if (strlen(sName) > 2)
			{
				PrepareZone(sName, sMap, iId, iType, iData, iTrack, fPointA, fPointB);
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
	else
	{
		PrintToServer("No zones found.");
	}
}

void PrepareZone(const char[] name, const char[] map, int id, int type, int typeid, int group, float pointA[3], float pointB[3])
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
	
	smKeys.SetString("Start", type == 0 ? "1" : "0");
	smKeys.SetString("End", type == 1 ? "1" : "0");

	IntToString(typeid, sBuffer, sizeof(sBuffer));
	smKeys.SetString("Stage", type == 12 ? sBuffer : "0");

	IntToString(typeid, sBuffer, sizeof(sBuffer));
	smKeys.SetString("Checkpoint", "0");

	smKeys.SetString("PreSpeed", "0"); // TODO
	smKeys.SetString("MaxVelocity", "0"); // TODO

	smKeys.SetString("Misc", "0");
	smKeys.SetString("Speed", "0");
	smKeys.SetString("TeleToStart", type == 7 ? "1" : "0");
	smKeys.SetString("Validator", "0");
	smKeys.SetString("Checker", "0");
	smKeys.SetString("Stop", "0");

	eImportZone data;
	strcopy(data.Name, MAX_ZONE_NAME_LENGTH, name);
	data.Type = bTrigger ? ZONE_TYPE_TRIGGER : ZONE_TYPE_BOX;
	data.Start = pointA;
	data.End = pointB;
	data.Origin = view_as<float>({0.0, 0.0, 0.0});
	strcopy(data.OriginName, MAX_ZONE_NAME_LENGTH, data.Name);
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
	g_smTiers = new StringMap();
	char sMap[64];
	for (int i = 0; i < g_aMaps.Length; ++i)
	{
		g_aMaps.GetString(i, sMap, sizeof(sMap));

		PrintToServer("Loading tier for map %s...", sMap);

		DataPack pack = new DataPack();
		pack.WriteString(sMap);

		char sQuery[256];
		g_dDB.Format(sQuery, sizeof(sQuery), "SELECT tier FROM %smaptiers WHERE map = \"%s\"", g_sPrefix, sMap);
		g_dDB.Query(SQL_GetMapTier, sQuery, pack);
	}

	delete g_aMaps;
}

public void SQL_GetMapTier(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (db == null || strlen(error) > 0)
	{
		LogError("(SQL_GetMapTier) Query failed: %s", error);
		delete pack;
		return;
	}

	char sMap[32];
	pack.Reset();
	pack.ReadString(sMap, sizeof(sMap));
	delete pack;

	if (results.HasResults && results.FetchRow())
	{
		int iTier = results.FetchInt(0);

		if (iTier < 1)
		{
			return;
		}

		g_smTiers.SetValue(sMap, iTier);

		LoopZonesAndCreate(sMap, iTier);
		PrintToServer("Tier loaded for map %s (Tier: %d)", sMap, iTier);

		return;
	}
	
	LoopZonesAndCreate(sMap, 0);
	LogError("Tier not loaded for map %s (Tier: 0)", sMap);
}

void LoopZonesAndCreate(const char[] map, int tier)
{
	char sPath[PLATFORM_MAX_PATH + 1];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/zones/Tier%d/", tier);

	if (!DirExists(sPath))
    {
        CreateDirectory(sPath, FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_EXEC);
    }

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
			data.MaxVelocity = 10000;
			AddZone(kv, data);
		}
	}

	kv.ExportToFile(sFile);
	delete kv;
}

void AddZone(KeyValues kv, eImportZone data)
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
				if (StrContains(data.Name, "main", false) != -1 && StrContains(data.Name, "start", false) != -1)
				{
					kv.SetNum("tier", data.Tier);
					kv.SetNum("maxvelocity", data.MaxVelocity);
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
