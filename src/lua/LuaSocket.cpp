#include "LuaScriptInterface.h"
#include "Misc.h"
#include "json/json.h"
#include <sstream>

// ---------------------------------------------------------------------------
// json.parse(str) -> table, json.stringify(table) -> str
//
// Rebuilt from scratch (the original implementation was lost from this file's
// uncommitted history -- see git history/session notes). Pure data
// conversion only, no networking. luaToJsonValue is depth-limited so a
// cyclic or excessively nested Lua table can never overflow the C stack --
// that recursion-safety issue is what caused tonight's crash in the
// original, and is deliberately not reintroduced here.
// ---------------------------------------------------------------------------

static void PushJsonValue(lua_State *L, const Json::Value &v)
{
	switch (v.type())
	{
	case Json::nullValue:
		lua_pushnil(L);
		break;
	case Json::booleanValue:
		lua_pushboolean(L, v.asBool());
		break;
	case Json::intValue:
	case Json::uintValue:
	case Json::realValue:
		lua_pushnumber(L, v.asDouble());
		break;
	case Json::stringValue:
	{
		auto s = v.asString();
		lua_pushlstring(L, s.data(), s.size());
		break;
	}
	case Json::arrayValue:
	{
		lua_newtable(L);
		int idx = 1;
		for (auto &item : v)
		{
			PushJsonValue(L, item);
			lua_rawseti(L, -2, idx++);
		}
		break;
	}
	case Json::objectValue:
	{
		lua_newtable(L);
		for (auto it = v.begin(); it != v.end(); ++it)
		{
			auto key = it.key().asString();
			lua_pushlstring(L, key.data(), key.size());
			PushJsonValue(L, *it);
			lua_settable(L, -3);
		}
		break;
	}
	}
}

static constexpr int kMaxJsonDepth = 64;

static Json::Value LuaToJsonValue(lua_State *L, int idx, int depth = 0)
{
	if (depth > kMaxJsonDepth)
	{
		return Json::Value("<max json depth exceeded>");
	}
	switch (lua_type(L, idx))
	{
	case LUA_TNIL:
		return Json::nullValue;
	case LUA_TBOOLEAN:
		return Json::Value((bool)lua_toboolean(L, idx));
	case LUA_TNUMBER:
		return Json::Value((double)lua_tonumber(L, idx));
	case LUA_TSTRING:
	{
		size_t len = 0;
		const char *str = lua_tolstring(L, idx, &len);
		return Json::Value(std::string(str, len));
	}
	case LUA_TTABLE:
	{
		// Treat as an array if every key seen while peeking is a small
		// positive integer; otherwise treat as an object. This is a
		// heuristic (a table can legitimately mix both), same trade-off the
		// original implementation made.
		bool isArray = true;
		lua_pushnil(L);
		if (lua_next(L, idx) != 0)
		{
			if (lua_type(L, -2) != LUA_TNUMBER)
			{
				isArray = false;
			}
			else
			{
				double k = lua_tonumber(L, -2);
				if (k > 1000 || k < 1)
				{
					isArray = false;
				}
			}
			lua_pop(L, 2);
		}
		if (isArray)
		{
			Json::Value arr(Json::arrayValue);
			for (lua_pushnil(L); lua_next(L, idx); lua_pop(L, 1))
			{
				if (lua_type(L, -1) != LUA_TNIL)
				{
					arr.append(LuaToJsonValue(L, lua_gettop(L), depth + 1));
				}
			}
			return arr;
		}
		else
		{
			Json::Value obj(Json::objectValue);
			for (lua_pushnil(L); lua_next(L, idx); lua_pop(L, 1))
			{
				if (lua_type(L, -2) == LUA_TSTRING)
				{
					size_t klen = 0;
					const char *k = lua_tolstring(L, -2, &klen);
					obj[std::string(k, klen)] = LuaToJsonValue(L, lua_gettop(L), depth + 1);
				}
			}
			return obj;
		}
	}
	default:
		return Json::nullValue;
	}
}

static int LuaJsonParse(lua_State *L)
{
	size_t len = 0;
	const char *str = luaL_checklstring(L, 1, &len);
	Json::Value root;
	Json::CharReaderBuilder builder;
	std::string errs;
	std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
	if (!reader->parse(str, str + len, &root, &errs))
	{
		lua_pushnil(L);
		lua_pushstring(L, errs.c_str());
		return 2;
	}
	PushJsonValue(L, root);
	return 1;
}

static int LuaJsonStringify(lua_State *L)
{
	Json::Value root = LuaToJsonValue(L, 1);
	Json::StreamWriterBuilder builder;
	builder["indentation"] = "";
	std::string out = Json::writeString(builder, root);
	lua_pushlstring(L, out.data(), out.size());
	return 1;
}

static void OpenJson(lua_State *L)
{
	static const luaL_Reg reg[] = {
		{ "parse", LuaJsonParse },
		{ "stringify", LuaJsonStringify },
		{ nullptr, nullptr }
	};
	lua_newtable(L);
	luaL_register(L, nullptr, reg);
	lua_setglobal(L, "json");
}

int LuaSocket::GetTime(lua_State *L)
{
	lua_pushnumber(L, LuaSocket::Now());
	return 1;
}

int LuaSocket::Sleep(lua_State *L)
{
	GetLSI()->AssertInterfaceEvent();
	LuaSocket::Timeout(luaL_checknumber(L, 1));
	return 0;
}

void LuaSocket::Open(lua_State *L)
{
	static const luaL_Reg reg[] = {
		{ "sleep", LuaSocket::Sleep },
		{ "getTime", LuaSocket::GetTime },
		{ nullptr, nullptr }
	};
	lua_newtable(L);
	luaL_register(L, nullptr, reg);
	lua_setglobal(L, "socket");
	OpenTCP(L);
	OpenJson(L);
	OpenNetTable(L);
}

// Process()'s real implementation -- the net.listen HTTP accept/serve loop
// polled once per Simulation tick -- lives in LuaSocketNet.cpp now.
