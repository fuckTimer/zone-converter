#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <fuckZones>
#include <ripext>

ArrayList g_aZones = null;
ArrayList g_aMaps = null;
Database g_dDB = null;
StringMap g_smTiers = null;
StringMap g_smMapper = null;
StringMap g_smCheckpoints = null;
StringMap g_smStages = null;
StringMap g_smBonus = null;

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
	RegAdminCmd("sm_gendetails", Command_GenDetails, ADMFLAG_ROOT);
}

public void OnMapStart()
{
	delete g_aMaps;
	delete g_aZones;
}

public Action Command_GenDetails(int client, int args)
{
	JSONArray jaDetails = new JSONArray();
	
	StringMapSnapshot snap = g_smTiers.Snapshot();

	for (int i = 0; i < snap.Length; i++)
	{
		JSONObject jObj = new JSONObject();

		char sMap[64];
		snap.GetKey(i, sMap, sizeof(sMap));
		jObj.SetString("name", sMap);

		int iBuffer = 0;
		g_smTiers.GetValue(sMap, iBuffer);
		jObj.SetInt("tier", iBuffer);

		char sMapper[256];
		g_smMapper.GetString(sMap, sMapper, sizeof(sMapper));
		jObj.SetString("mapper", sMapper);

		iBuffer = 0;
		g_smCheckpoints.GetValue(sMap, iBuffer);
		jObj.SetInt("checkpoints", iBuffer);

		iBuffer = 0;
		g_smStages.GetValue(sMap, iBuffer);
		jObj.SetInt("stages", iBuffer);

		iBuffer = 0;
		g_smBonus.GetValue(sMap, iBuffer);
		jObj.SetInt("bonus", iBuffer);

		jaDetails.Push(jObj);
	}

	delete snap;

	char sFile[PLATFORM_MAX_PATH + 1];
	BuildPath(Path_SM, sFile, sizeof(sFile), "data/mapdetails.json");
	jaDetails.ToFile(sFile, 0x1F);
	return Plugin_Handled;
}

public Action Command_ImportZones(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_importzones <database> [map] [0-zonename/1-hookname] [prespeed 0/1]");
		return Plugin_Handled;
	}

	char sDatabase[24];
	GetCmdArg(1, sDatabase, sizeof(sDatabase));

	if (!SQL_CheckConfig(sDatabase))
	{
		SetFailState("Can not find the \"%s\" database entry in your databases.cfg...", sDatabase);
		return Plugin_Handled;
	}

	char sMap[MAX_NAME_LENGTH];
	GetCmdArg(2, sMap, sizeof(sMap));

	char sBuffer[4];
	GetCmdArg(3, sBuffer, sizeof(sBuffer));
	bool bZoneColumn = view_as<bool>(StringToInt(sBuffer));

	GetCmdArg(4, sBuffer, sizeof(sBuffer));
	bool bPrespeed = view_as<bool>(StringToInt(sBuffer));

	PrintToServer("Connecting to database...");

	DataPack pack = new DataPack();
	pack.WriteString(sMap);
	pack.WriteCell(bZoneColumn);
	pack.WriteCell(bPrespeed);
	Database.Connect(OnConnect, sDatabase, pack);

	return Plugin_Handled;
}

public void OnConnect(Database db, const char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);

	if (db == null || strlen(error))
	{
		delete pack; 
		SetFailState("Unable to connect to database... Error: %s", error);
		return;
	}

	pack.Reset();

	char sMap[MAX_NAME_LENGTH];
	pack.ReadString(sMap, sizeof(sMap));
	bool bZoneColumn = view_as<bool>(pack.ReadCell());
	bool bPrespeed = view_as<bool>(pack.ReadCell());
	delete pack;

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
	db.Format(sQuery, sizeof(sQuery), "SELECT mapname, zoneid, zonetype, zonetypeid, zonegroup, pointa_x, pointa_y, pointa_z, pointb_x, pointb_y, pointb_z, %s%s FROM ck_zones WHERE mapname LIKE \"%%%s%%\" AND mapname NOT LIKE \"surf_atoz\" ORDER BY mapname ASC, zonegroup ASC, zonetype ASC, zonetypeID ASC;",
	bZoneColumn ? "hookname" : "zonename", bPrespeed ? ", prespeed" : "", sMap);
	db.Query(sql_GetZones, sQuery, bPrespeed);
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
			char sMap[64], sHookName[64];

			int iZoneID;
			int iZoneType;
			int iZoneTypeID;
			int iZoneGroup;
			int iPreSpeed = -1;

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

			if (results.FieldCount > 12)
			{
				iPreSpeed = results.FetchInt(12);
			}

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
				PrepareZone(sName, sMap, iZoneID, iZoneType, iZoneTypeID + 2, iZoneGroup, bBonus, fPointA, fPointB, sHookName, iPreSpeed);
			}
		}

		PrintToServer("Zone data prepared...");
		PrintToServer("Sort array...");
		SortArray();
		PrintToServer("Array sorted...");
		PrintToServer("Creating zone files...");
		IterateMaps(data);
		GetMapCheckpoints();
		GetMapStages();
		GetMapBonus();
		PrintToServer("Zone files created.");
	}
	else
	{
		PrintToServer("No zones found.");
	}
}

void PrepareZone(const char[] name, const char[] map, int id, int type, int typeid, int group, bool bonus, float pointA[3], float pointB[3], const char[] hookname, int prespeed)
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

	IntToString(prespeed, sBuffer, sizeof(sBuffer));
	smKeys.SetString("PreSpeed", sBuffer);

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

void IterateMaps(bool prespeed)
{
	g_smTiers = new StringMap();
	g_smMapper = new StringMap();
	g_smCheckpoints = new StringMap();
	g_smStages = new StringMap();
	g_smBonus = new StringMap();

	char sMap[64];
	for (int i = 0; i < g_aMaps.Length; ++i)
	{
		g_aMaps.GetString(i, sMap, sizeof(sMap));

		PrintToServer("Loading tier for map %s...", sMap);

		DataPack pack = new DataPack();
		pack.WriteString(sMap);

		char sQuery[256];
		g_dDB.Format(sQuery, sizeof(sQuery), "SELECT tier, mapper%s FROM ck_maptier WHERE mapname = \"%s\"", prespeed ? ", maxvelocity" : "", sMap);
		g_dDB.Query(SQL_GetMapTier, sQuery, pack);
	}

	delete g_aMaps;
}

public void SQL_GetMapTier(Database db, DBResultSet results, const char[] error, any pack)
{
	if (db == null || strlen(error) > 0)
	{
		LogError("(SQL_GetMapTier) Query failed: %s", error);
		return;
	}

	char sMap[32];
	view_as<DataPack>(pack).Reset();
	view_as<DataPack>(pack).ReadString(sMap, sizeof(sMap));
	delete view_as<DataPack>(pack);

	if (results.HasResults && results.FetchRow())
	{
		int iTier = results.FetchInt(0);

		char sMapper[256];
		results.FetchString(1, sMapper, sizeof(sMapper));

		int iMaxVelocity = -1;
		if (results.FieldCount > 2)
		{
			iMaxVelocity = results.FetchInt(2);
		}

		g_smTiers.SetValue(sMap, iTier);
		g_smMapper.SetString(sMap, sMapper);

		LoopZonesAndCreate(sMap, iTier, iMaxVelocity);
		PrintToServer("Tier loaded for map %s (Tier: %d, MaxVelocity: %d)", sMap, iTier, iMaxVelocity);

		return;
	}
	else
	{
		LoopZonesAndCreate(sMap, 0, 3500);
		LogMessage("Tier not loaded for map %s (Tier: 0)", sMap);
	}
}

void LoopZonesAndCreate(const char[] map, int tier, int maxvelocity)
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

		if (StrEqual(data.Map, map, false))
		{
			data.Tier = tier;
			data.MaxVelocity = maxvelocity;
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

void GetMapCheckpoints()
{
	char sQuery[256];
	g_dDB.Format(sQuery, sizeof(sQuery), "SELECT mapname, COUNT(mapname) AS amount FROM ck_zones WHERE zonetype = 4 GROUP BY mapname");
	g_dDB.Query(SQL_GetMapInfos, sQuery, 0);
}

void GetMapStages()
{
	char sQuery[256];
	g_dDB.Format(sQuery, sizeof(sQuery), "SELECT mapname, COUNT(mapname) AS amount FROM ck_zones WHERE zonetype = 3 GROUP BY mapname");
	g_dDB.Query(SQL_GetMapInfos, sQuery, 1);
}

void GetMapBonus()
{
	char sQuery[256];
	g_dDB.Format(sQuery, sizeof(sQuery), "SELECT mapname, COUNT(mapname) AS amount FROM ck_zones WHERE zonegroup > 0 GROUP BY mapname");
	g_dDB.Query(SQL_GetMapInfos, sQuery, 2);
}


public void SQL_GetMapInfos(Database db, DBResultSet results, const char[] error, int type)
{
	if (db == null || strlen(error) > 0)
	{
		LogError("(SQL_GetMapInfos) Query failed: %s", error);
		return;
	}

	if (results.HasResults)
	{
		while (results.FetchRow())
		{
			char sMap[64];
			results.FetchString(0, sMap, sizeof(sMap));
			int iAmount = results.FetchInt(1);

			if (type == 0)
			{
				g_smCheckpoints.SetValue(sMap, iAmount);
			}
			else if (type == 1)
			{
				g_smStages.SetValue(sMap, iAmount);
			}
			else if (type == 2)
			{
				g_smBonus.SetValue(sMap, iAmount);
			}
		}
	}
}
