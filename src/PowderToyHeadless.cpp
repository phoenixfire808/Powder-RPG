// Headless blueprint evaluator (knowledge/HUB.md section 2). Replays the compiled
// primitive list through the same Simulation:: calls the Lua bridge makes, runs N
// frames on the GameModel per-frame path, and prints one JSON line of probes/hashes.
#include "Config.h"
#include "Misc.h"
#include "client/GameSave.h"
#include "common/String.h"
#include "common/platform/Platform.h"
#include "simulation/Air.h"
#include "simulation/CustomElements.h"
#include "simulation/ElementClasses.h"
#include "simulation/Simulation.h"
#include "simulation/SimulationData.h"
#include "simulation/Snapshot.h"
#include <json/json.h>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <vector>

// LuaScriptInterface.cpp int32_truncate: how partProperty coerces numbers into int fields.
static int32_t int32_truncate(double n)
{
	if (n >= 0x1p31)
		n -= 0x1p32;
	return int32_t(n);
}

static Json::Value readJson(const ByteString &path)
{
	std::vector<char> data;
	if (!Platform::ReadFile(data, path))
		throw std::runtime_error("cannot read " + path);
	Json::Value root;
	std::string errs;
	Json::CharReaderBuilder builder;
	std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
	if (!reader->parse(data.data(), data.data() + data.size(), &root, &errs))
		throw std::runtime_error(path + ": " + errs);
	return root;
}

static int elementId(const SimulationData &sd, const Json::Value &v)
{
	if (v.isNumeric())
		return v.asInt();
	int id = sd.GetParticleType(ByteString(v.asString()).ToUpper());
	if (id < 0)
		throw std::runtime_error("unknown element " + v.asString());
	return id;
}

static int wallId(const SimulationData &sd, const Json::Value &v)
{
	if (v.isNumeric())
		return v.asInt();
	auto name = ByteString(v.asString()).ToUpper();
	for (size_t i = 0; i < sd.wtypes.size(); i++)
		if (sd.wtypes[i].identifier == name || sd.wtypes[i].identifier == "DEFAULT_WL_" + name)
			return int(i);
	throw std::runtime_error("unknown wall " + v.asString());
}

static int num(const Json::Value &p, const char *key)
{
	if (!p.isMember(key) || !p[key].isNumeric())
		throw std::runtime_error(ByteString("primitive missing numeric field ") + key);
	return p[key].asInt();
}

// Same order and same calls as _LUA_SET (powder_ext/blueprint_tools.py) via sim.partProperty.
static void setPrim(Simulation *sim, const SimulationData &sd, const Json::Value &p)
{
	int x1 = num(p, "x1"), y1 = num(p, "y1"), x2 = num(p, "x2"), y2 = num(p, "y2");
	int filter = p.isMember("element") && !p["element"].isNull() ? elementId(sd, p["element"]) : -1;
	auto &properties = Particle::GetProperties();
	struct Op { StructProperty prop; float value; };
	std::vector<Op> ops;
	for (auto const &key : p["props"].getMemberNames())
	{
		ByteString name = key;
		for (auto &alias : Particle::GetPropertyAliases())
			if (name == alias.from)
				name = alias.to;
		auto it = std::find_if(properties.begin(), properties.end(), [&](StructProperty const &sp) { return sp.Name == name; });
		if (it == properties.end())
			throw std::runtime_error("unknown particle property " + key);
		auto &v = p["props"][key];
		float value = v.isNumeric() ? v.asFloat() : float(elementId(sd, v)); // ctype/type given as a name
		ops.push_back({ *it, value });
	}
	for (int i = 0; i < sim->parts.active; i++)
	{
		auto &part = sim->parts[i];
		if (!part.type || part.x < x1 || part.x > x2 || part.y < y1 || part.y > y2 || (filter >= 0 && part.type != filter))
			continue;
		for (auto &op : ops)
		{
			if (op.prop.Name == "type")
			{
				sim->part_change_type(i, int(part.x + 0.5f), int(part.y + 0.5f), int(op.value));
				continue;
			}
			auto addr = reinterpret_cast<unsigned char *>(&sim->parts[i]) + op.prop.Offset;
			switch (op.prop.Type)
			{
			case StructProperty::TransitionType:
			case StructProperty::ParticleType:
			case StructProperty::Integer:  *reinterpret_cast<int *>(addr) = int32_truncate(op.value); break;
			case StructProperty::UInteger: *reinterpret_cast<unsigned int *>(addr) = int32_truncate(op.value); break;
			case StructProperty::Float:    *reinterpret_cast<float *>(addr) = op.value; break;
			case StructProperty::UChar:    *reinterpret_cast<unsigned char *>(addr) = int32_truncate(op.value); break;
			default: throw std::runtime_error("unsupported property " + op.prop.Name);
			}
		}
	}
}

// bridge_base.lua loadStamp: GameSave from stamps/<name>.stm, nudge by the CELL remainder, Load at block coords.
static void loadSave(Simulation *sim, const ByteString &path, int x, int y)
{
	std::vector<char> data;
	if (!Platform::ReadFile(data, path))
		throw std::runtime_error("cannot read " + path);
	GameSave save(data, false);
	auto [quoX, remX] = floorDiv(x, CELL);
	auto [quoY, remY] = floorDiv(y, CELL);
	if (remX || remY)
		save.Transform(Mat2<int>::Identity, { remX, remY });
	sim->Load(&save, true, { quoX, quoY });
}

static void runPrim(Simulation *sim, const SimulationData &sd, const Json::Value &p, const ByteString &stampsDir)
{
	auto kind = p["kind"].asString();
	if (kind == "box")
		sim->CreateBox(-1, num(p, "x1"), num(p, "y1"), num(p, "x2"), num(p, "y2"), elementId(sd, p["element"]), 0);
	else if (kind == "line")
		sim->CreateLine(num(p, "x1"), num(p, "y1"), num(p, "x2"), num(p, "y2"), elementId(sd, p["element"]));
	else if (kind == "circle") // bridge placeElement ignores method/radius: a circle is one pixel at (cx,cy)
		sim->CreateBox(-1, num(p, "cx"), num(p, "cy"), num(p, "cx"), num(p, "cy"), elementId(sd, p["element"]), 0);
	else if (kind == "wall_box")
		sim->CreateWallBox(num(p, "x1"), num(p, "y1"), num(p, "x2"), num(p, "y2"), wallId(sd, p["wall"]));
	else if (kind == "set")
		setPrim(sim, sd, p);
	else if (kind == "stamp")
	{
		ByteString name = p["name"].asString();
		ByteString path = name;
		for (auto dir : { stampsDir, ByteString("../build/") + STAMPS_DIR }) // live game runs with cwd build/
			if (!Platform::FileExists(path))
				path = dir + "/" + name + ".stm";
		loadSave(sim, path, num(p, "x"), num(p, "y"));
	}
	else if (kind == "step")
		return;
	else
		throw std::runtime_error("unknown primitive kind " + kind);
}

struct Probe
{
	ByteString name;
	int x1, y1, x2, y2, element;
	int countBefore = 0;
	long long sprkPulses = 0;
};

// _COUNT_LUA in powder_ext/build_tools.py: parts by index, float position compare.
static bool inProbe(const Particle &part, const Probe &pr)
{
	return part.type && part.x >= pr.x1 && part.x <= pr.x2 && part.y >= pr.y1 && part.y <= pr.y2 && (pr.element < 0 || part.type == pr.element);
}

static int countProbe(Simulation *sim, const Probe &pr)
{
	int n = 0;
	for (int i = 0; i < sim->parts.active; i++)
		n += inProbe(sim->parts[i], pr);
	return n;
}

static Json::Value measure(Simulation *sim, const Probe &pr)
{
	int n = 0, lifeSum = 0;
	double tsum = 0;
	float tmax = -1e9f, pmin = 1e9f, pmax = -1e9f;
	for (int i = 0; i < sim->parts.active; i++)
	{
		auto &part = sim->parts[i];
		if (!inProbe(part, pr))
			continue;
		n++;
		tsum += part.temp;
		if (part.temp > tmax) tmax = part.temp;
		lifeSum += part.life;
	}
	for (int cx = pr.x1 / CELL; cx <= pr.x2 / CELL; cx++)
		for (int cy = pr.y1 / CELL; cy <= pr.y2 / CELL; cy++)
		{
			float pv = sim->pv[cy][cx];
			if (pv > pmax) pmax = pv;
			if (pv < pmin) pmin = pv;
		}
	Json::Value j;
	j["count"] = n;
	j["count_before"] = pr.countBefore;
	j["tavg_c"] = n ? tsum / n - 273.15 : 0.0;
	j["tmax_c"] = n ? tmax - 273.15f : 0.0f;
	j["life_sum"] = lifeSum;
	j["pmin"] = pmin;
	j["pmax"] = pmax;
	j["sprk_pulses"] = Json::Int64(pr.sprkPulses);
	return j;
}

static void clampRect(int &x1, int &y1, int &x2, int &y2)
{
	x1 = std::max(0, std::min(XRES - 1, x1)); x2 = std::max(0, std::min(XRES - 1, x2));
	y1 = std::max(0, std::min(YRES - 1, y1)); y2 = std::max(0, std::min(YRES - 1, y2));
	if (x1 > x2) std::swap(x1, x2);
	if (y1 > y2) std::swap(y1, y2);
}

static Json::Value hashParts(const Snapshot &snap)
{
	Json::Value j;
	for (auto &[name, hash] : snap.HashParts())
		j[name] = hash;
	j["FrameCount"] = Json::UInt64(snap.FrameCount);
	return j;
}

static int run(int argc, char *argv[])
{
	std::map<ByteString, ByteString> opt;
	for (int i = 1; i + 1 < argc; i += 2)
	{
		ByteString key = argv[i];
		if (!key.BeginsWith("--"))
			throw std::runtime_error("unexpected argument " + key);
		opt[key.Substr(2)] = argv[i + 1];
	}
	if (!opt.count("prims") || !opt.count("frames"))
		throw std::runtime_error("usage: powder_headless --prims prims.json --frames N [--seed a,b,c,d] [--load scene.stm] [--probes probes.json] [--sample-every K] [--dump dump.json] [--dump-air air.json] [--air-mode M] [--aheat 0|1] [--gravity-mode M] [--edge-mode M] [--custom pbx-custom-elements.json] [--stamps DIR]");
	int frames = opt["frames"].ToNumber<int>();
	int sampleEvery = opt.count("sample-every") ? opt["sample-every"].ToNumber<int>() : 0;
	if (frames < 0 || sampleEvery < 0)
		throw std::runtime_error("frames and sample-every must be >= 0");
	std::vector<unsigned long long> seed = { 1, 2, 3, 4 };
	if (opt.count("seed"))
	{
		if (sscanf(opt["seed"].c_str(), "%llu,%llu,%llu,%llu", &seed[0], &seed[1], &seed[2], &seed[3]) != 4)
			throw std::runtime_error("--seed needs four comma separated integers");
	}

	auto sdPtr = std::make_unique<SimulationData>(); // too large for the stack (can_move is PT_NUM^2)
	auto &sd = *sdPtr;
	if (opt.count("custom"))
		LoadCustomElements(opt["custom"]);
	auto sim = Simulation::Factory();
	sim->ensureDeterminism = true;
	sim->air->airMode = opt.count("air-mode") ? opt["air-mode"].ToNumber<int>() : AIR_ON;
	sim->aheat_enable = opt.count("aheat") ? opt["aheat"].ToNumber<int>() : 0;
	if (opt.count("gravity-mode"))
		sim->gravityMode = opt["gravity-mode"].ToNumber<int>();
	if (opt.count("edge-mode")) // 0 void (GameModel default), 1 solid, 2 loop
		sim->SetEdgeMode(opt["edge-mode"].ToNumber<int>());
	// GameModel::ClearSimulation order: modes first, then clear_sim (which resets ensureDeterminism).
	sim->clear_sim();
	sim->ensureDeterminism = true;
	// GameController::Tick runs Element_STKM_set_element(PT_DUST) on both unspawned stickmen every frame, even paused; stickmen is hashed.
	sim->player.elem = sim->player2.elem = PT_DUST;

	// RNG::RNG() seeds from time(nullptr) and create_part draws from it (dcolour), so seed before placement too.
	sim->rng.state({ seed[0] | (seed[1] << 32), seed[2] | (seed[3] << 32) });
	if (opt.count("load"))
		loadSave(sim.get(), opt["load"], 0, 0);

	auto prims = readJson(opt["prims"]);
	if (prims.isObject())
		prims = prims["primitives"];
	if (!prims.isArray())
		throw std::runtime_error("--prims must be an array or {\"primitives\":[...]}");
	ByteString stampsDir = opt.count("stamps") ? opt["stamps"] : ByteString(STAMPS_DIR);
	for (auto &p : prims)
		runPrim(sim.get(), sd, p, stampsDir);

	std::vector<Probe> probes;
	if (opt.count("probes"))
	{
		for (auto &j : readJson(opt["probes"]))
		{
			auto &r = j["region"];
			Probe pr{ j["name"].asString(), num(r, "x1"), num(r, "y1"), num(r, "x2"), num(r, "y2"), -1 };
			clampRect(pr.x1, pr.y1, pr.x2, pr.y2);
			if (j.isMember("element") && !j["element"].isNull())
				pr.element = elementId(sd, j["element"]);
			pr.countBefore = countProbe(sim.get(), pr);
			probes.push_back(pr);
		}
	}

	// sim.randomSeed semantics (LuaSimulation.cpp): applied after the build, before the first hash.
	sim->rng.state({ seed[0] | (seed[1] << 32), seed[2] | (seed[3] << 32) });
	Json::Value out;
	out["hash_before"] = sim->CreateSnapshot()->Hash();

	std::vector<unsigned char> wasSprk(NPART, 0);
	for (int i = 0; i < sim->parts.active; i++)
		wasSprk[i] = sim->parts[i].type == PT_SPRK;
	Json::Value hashes(Json::arrayValue);
	auto t0 = std::chrono::steady_clock::now();
	for (int f = 1; f <= frames; f++)
	{
		sim->BeforeSim(true);
		sim->UpdateParticles(0, NPART);
		sim->AfterSim();
		if (!probes.empty())
		{
			for (int i = 0; i < sim->parts.active; i++)
			{
				auto &part = sim->parts[i];
				bool now = part.type == PT_SPRK;
				if (now && !wasSprk[i])
					for (auto &pr : probes)
						if (part.x >= pr.x1 && part.x <= pr.x2 && part.y >= pr.y1 && part.y <= pr.y2 && (pr.element < 0 || pr.element == PT_SPRK || part.ctype == pr.element))
							pr.sprkPulses++;
				wasSprk[i] = now;
			}
		}
		if (sampleEvery && f % sampleEvery == 0)
		{
			Json::Value h;
			h["frame"] = f;
			h["hash"] = sim->CreateSnapshot()->Hash();
			hashes.append(h);
		}
	}
	auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

	out["ok"] = true;
	out["frames"] = frames;
	Json::Value seedJ(Json::arrayValue);
	for (auto s : seed)
		seedJ.append(Json::UInt64(s));
	out["seed"] = seedJ;
	auto finalSnap = sim->CreateSnapshot();
	out["hash"] = finalSnap->Hash();
	out["hash_parts"] = hashParts(*finalSnap);
	out["hashes"] = hashes;
	Json::Value probesJ(Json::objectValue);
	for (auto &pr : probes)
		probesJ[pr.name] = measure(sim.get(), pr);
	out["probes"] = probesJ;
	Json::Value counts(Json::objectValue);
	int particles = 0;
	std::vector<int> byType(PT_NUM, 0);
	for (int i = 0; i < sim->parts.active; i++)
		if (sim->parts[i].type)
		{
			byType[sim->parts[i].type]++;
			particles++;
		}
	for (int t = 1; t < PT_NUM; t++)
		if (byType[t])
			counts[sd.elements[t].Name.ToUtf8()] = byType[t];
	out["element_count"] = counts;
	out["particles"] = particles;
	out["ms"] = ms;

	if (opt.count("dump"))
	{
		Json::Value dump(Json::arrayValue);
		for (int i = 0; i < sim->parts.active; i++)
		{
			auto &part = sim->parts[i];
			if (!part.type)
				continue;
			Json::Value j;
			j["x"] = part.x; j["y"] = part.y;
			j["type"] = sd.elements[part.type].Name.ToUtf8();
			j["temp"] = part.temp; j["ctype"] = part.ctype; j["tmp"] = part.tmp; j["tmp2"] = part.tmp2; j["life"] = part.life;
			dump.append(j);
		}
		Json::StreamWriterBuilder w;
		w["indentation"] = "";
		auto text = Json::writeString(w, dump);
		if (!Platform::WriteFile(std::vector<char>(text.begin(), text.end()), opt["dump"]))
			throw std::runtime_error("cannot write " + opt["dump"]);
	}

	if (opt.count("dump-air")) // CELL grid, row-major [y*XCELLS+x], matches sim.pressure/velocityX/velocityY/ambientHeat(x,y)
	{
		Json::Value air;
		air["xcells"] = XCELLS; air["ycells"] = YCELLS; air["frameCount"] = Json::UInt64(sim->frameCount);
		auto plane = [](float (&g)[YCELLS][XCELLS]) { Json::Value a(Json::arrayValue); for (int y = 0; y < YCELLS; y++) for (int x = 0; x < XCELLS; x++) a.append(g[y][x]); return a; };
		air["pressure"] = plane(sim->pv); air["velocityX"] = plane(sim->vx); air["velocityY"] = plane(sim->vy); air["ambientHeat"] = plane(sim->hv);
		Json::StreamWriterBuilder aw;
		aw["indentation"] = "";
		auto text = Json::writeString(aw, air);
		if (!Platform::WriteFile(std::vector<char>(text.begin(), text.end()), opt["dump-air"]))
			throw std::runtime_error("cannot write " + opt["dump-air"]);
	}

	Json::StreamWriterBuilder w;
	w["indentation"] = "";
	std::cout << Json::writeString(w, out) << std::endl;
	return 0;
}

int main(int argc, char *argv[])
{
	try
	{
		return run(argc, argv);
	}
	catch (std::exception &e)
	{
		Json::Value out;
		out["ok"] = false;
		out["error"] = e.what();
		Json::StreamWriterBuilder w;
		w["indentation"] = "";
		std::cout << Json::writeString(w, out) << std::endl;
		return 1;
	}
}
