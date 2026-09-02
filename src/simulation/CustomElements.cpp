#include "CustomElements.h"
#include "ElementCommon.h"
#include "SimulationData.h"
#include "common/platform/Platform.h"
#include <json/json.h>
#include <cstdio>
#include <map>
#include <memory>
#include <stdexcept>

// Mirrors PHYSICS / PROP_BITS / FIELDS in D:\powder-toy\bridge_src\10_registry.lua.
struct Physics { unsigned int type; float adv, drag, airLoss, loss, coll, grav, diff, hot; int fall, weight, heat, hard; };
static const std::map<std::string, Physics> physics = {
	{ "PART",   { TYPE_PART,   0.7f, 0.02f, 0.96f, 0.80f,  0.0f,  0.1f, 0.00f, 0.0f, 1,  85,  70, 30 } },
	{ "LIQUID", { TYPE_LIQUID, 0.6f, 0.01f, 0.98f, 0.95f,  0.0f,  0.1f, 0.00f, 0.0f, 2,  30,  29, 20 } },
	{ "SOLID",  { TYPE_SOLID,  0.0f, 0.00f, 0.90f, 0.00f,  0.0f,  0.0f, 0.00f, 0.0f, 0, 100, 100, 30 } },
	{ "GAS",    { TYPE_GAS,    1.0f, 0.01f, 0.99f, 0.30f, -0.1f,  0.0f, 0.75f, 0.0f, 0,   1,  42,  1 } },
	{ "ENERGY", { TYPE_ENERGY, 0.0f, 0.00f, 1.00f, 1.00f, -0.99f, 0.0f, 0.00f, 0.0f, 0,  -1, 251,  0 } },
};

static const std::map<std::string, unsigned int> propBits = {
	{ "PROP_CONDUCTS", PROP_CONDUCTS }, { "PROP_PHOTPASS", PROP_PHOTPASS }, { "PROP_NEUTPENETRATE", PROP_NEUTPENETRATE },
	{ "PROP_NEUTABSORB", PROP_NEUTABSORB }, { "PROP_NEUTPASS", PROP_NEUTPASS }, { "PROP_DEADLY", PROP_DEADLY },
	{ "PROP_HOT_GLOW", PROP_HOT_GLOW }, { "PROP_LIFE", PROP_LIFE }, { "PROP_RADIOACTIVE", PROP_RADIOACTIVE },
	{ "PROP_LIFE_DEC", PROP_LIFE_DEC }, { "PROP_LIFE_KILL", PROP_LIFE_KILL }, { "PROP_LIFE_KILL_DEC", PROP_LIFE_KILL_DEC },
	{ "PROP_SPARKSETTLE", PROP_SPARKSETTLE }, { "PROP_NOAMBHEAT", PROP_NOAMBHEAT }, { "PROP_NOCTYPEDRAW", PROP_NOCTYPEDRAW },
};

static int transition(const SimulationData &sd, const Json::Value &v)
{
	if (v.isNumeric())
		return v.asInt();
	if (!v.isString())
		return NT;
	auto up = ByteString(v.asString()).ToUpper();
	if (up == "NT" || up == "NONE_TRANSITION")
		return NT;
	int id = sd.GetParticleType(up);
	return id < 0 ? NT : id;
}

int LoadCustomElements(ByteString path)
{
	std::vector<char> data;
	if (!Platform::ReadFile(data, path))
		throw std::runtime_error("cannot read " + path);
	Json::Value root;
	std::string errs;
	Json::CharReaderBuilder builder;
	std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
	if (!reader->parse(data.data(), data.data() + data.size(), &root, &errs) || !root.isArray())
		throw std::runtime_error("bad custom element JSON: " + errs);

	auto &sd = SimulationData::Ref();
	auto &elements = sd.elements;
	int count = 0;
	for (auto &e : root)
	{
		auto name = ByteString(e["name"].asString()).ToUpper();
		if (name.empty() || name.Contains("_"))
			throw std::runtime_error("custom element with missing or invalid name");
		if (sd.GetParticleType(name) != -1)
		{
			fprintf(stderr, "custom element %s already exists, skipped\n", name.c_str());
			continue;
		}
		int id = -1;
		for (int i = 255; i >= 0 && id == -1; i--)
			if (!elements[i].Enabled)
				id = i;
		for (int i = PT_NUM - 1; i >= 255 && id == -1; i--)
			if (!elements[i].Enabled)
				id = i;
		if (id == -1)
			throw std::runtime_error("no free element slot for " + name);

		auto type = e.get("type", "SOLID").asString();
		auto ph = physics.count(type) ? physics.at(type) : physics.at("SOLID");
		Element &el = elements[id];
		el = Element();
		el.Enabled = true;
		el.Identifier = ByteString(e.get("group", "PBX").asString()).ToUpper() + "_PT_" + name;
		el.Name = name.FromUtf8();
		el.MenuVisible = 1;
		el.Description = ("PBX custom element " + name).FromUtf8();
		el.Advection = ph.adv; el.AirDrag = ph.drag; el.AirLoss = ph.airLoss; el.Loss = ph.loss;
		el.Collision = ph.coll; el.Gravity = ph.grav; el.Diffusion = ph.diff; el.HotAir = ph.hot;
		el.Falldown = ph.fall; el.Weight = ph.weight; el.HeatConduct = ph.heat; el.Hardness = ph.hard;
		unsigned int bits = ph.type;
		for (auto &p : e["properties"])
		{
			auto it = propBits.find(p.asString());
			if (it != propBits.end())
				bits |= it->second;
		}
		// Mirrors 10_registry.lua: a `conductor` kind reverts from SPRK with life=4 and only
		// re-conducts at life==0, so it needs LIFE_DEC or it conducts exactly once.
		if (e.isMember("behavior") && e["behavior"].get("kind", "").asString() == "conductor")
			bits |= PROP_LIFE_DEC;
		el.Properties = bits;
		if (e.isMember("description")) el.Description = ByteString(e["description"].asString()).FromUtf8();
		if (e.isMember("colour")) el.Colour = RGB::Unpack(e["colour"].asInt());
		if (e.isMember("menuSection")) el.MenuSection = e["menuSection"].asInt();
		if (e.isMember("temperature")) el.DefaultProperties.temp = e["temperature"].asFloat();
		if (e.isMember("highTemperature")) el.HighTemperature = e["highTemperature"].asFloat();
		if (e.isMember("highTemperatureTransition")) el.HighTemperatureTransition = transition(sd, e["highTemperatureTransition"]);
		if (e.isMember("lowTemperature")) el.LowTemperature = e["lowTemperature"].asFloat();
		if (e.isMember("lowTemperatureTransition")) el.LowTemperatureTransition = transition(sd, e["lowTemperatureTransition"]);
		if (e.isMember("hardness")) el.Hardness = e["hardness"].asInt();
		if (e.isMember("weight")) el.Weight = e["weight"].asInt();
		if (e.isMember("gravity")) el.Gravity = e["gravity"].asFloat();
		if (e.isMember("diffusion")) el.Diffusion = e["diffusion"].asFloat();
		if (e.isMember("flammable")) el.Flammable = e["flammable"].asInt();
		if (e.isMember("explosive")) el.Explosive = e["explosive"].asInt();
		if (e.isMember("heatConduct")) el.HeatConduct = e["heatConduct"].asInt();
		count++;
	}
	sd.init_can_move();
	return count;
}
