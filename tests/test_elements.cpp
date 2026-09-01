// Catch2 tests against the engine's REAL element table.
//
// SimulationData's constructor runs GetElements(), which calls every
// Element::Element_XXXX() in src/simulation/elements/. So these tests assert on the
// same data the running simulation uses - not on a fixture or a copy of it.
//
// Two facts are pinned here because both have already cost this fork real bugs:
//   1. A solid used as terrain with Falldown == 1 makes the world fall through itself.
//   2. WOOD -> SAWD on impact. This fork narrowed the vanilla rule to exclude gases
//      (Simulation.cpp, "RPG fork change"); if the property bits that rule reads ever
//      move, trees start shedding sawdust again.

#include <catch2/catch_test_macros.hpp>

#include <stdexcept>

// ElementClasses.h is what expands the ELEMENT_NUMBERS X-macro into the PT_* constants.
#include "simulation/ElementClasses.h"
#include "simulation/SimulationData.h"

// ------------------------------------------------------- terrain must not fall

SCENARIO("solid elements do not fall, so terrain cannot collapse through the world", "[elements][bdd]")
{
	GIVEN("the element table the simulation actually loads")
	{
		SimulationData sd;

		REQUIRE(sd.elements[PT_WOOD].Enabled == 1);

		WHEN("every enabled solid is inspected")
		{
			THEN("none of them has Falldown set")
			{
				for (int t = 1; t < PT_NUM; ++t)
				{
					const Element &e = sd.elements[t];
					if (!e.Enabled || !(e.Properties & TYPE_SOLID))
					{
						continue;
					}
					INFO("element " << t << " (" << e.Name.ToUtf8() << ") is TYPE_SOLID with Falldown=" << int(e.Falldown));
					REQUIRE(e.Falldown == 0);
				}
			}
		}

		WHEN("wood is inspected specifically")
		{
			const Element &wood = sd.elements[PT_WOOD];

			THEN("it is a static solid")
			{
				REQUIRE((wood.Properties & TYPE_SOLID) != 0);
				REQUIRE(wood.Falldown == 0);
				REQUIRE(wood.Gravity == 0.0f);
			}
		}
	}
}

// ------------------------------------------------- the WOOD -> SAWD impact rule

SCENARIO("the WOOD to SAWD impact rule reads the property bits it depends on", "[elements][bdd]")
{
	GIVEN("the real element table")
	{
		SimulationData sd;

		WHEN("sawdust is compared against the wood it comes from")
		{
			THEN("sawdust is a powder and wood is not")
			{
				// If SAWD ever stopped being a powder the conversion would produce
				// static debris welded into the trunk.
				REQUIRE((sd.elements[PT_SAWD].Properties & TYPE_PART) != 0);
				REQUIRE(sd.elements[PT_SAWD].Falldown == 1);
				REQUIRE(sd.elements[PT_WOOD].Falldown == 0);
			}

			THEN("settled sawdust cannot be displaced by other powders")
			{
				// SimulationData::init_can_move, "SAWD cannot be displaced by other powders".
				for (int t = 1; t < PT_NUM; ++t)
				{
					const Element &e = sd.elements[t];
					if (!e.Enabled || !(e.Properties & TYPE_PART))
					{
						continue;
					}
					INFO("powder " << t << " (" << e.Name.ToUtf8() << ") vs SAWD");
					REQUIRE(sd.can_move[t][PT_SAWD] == 0);
				}
			}
		}

		WHEN("the gases that sit in this fork's forests are inspected")
		{
			THEN("they carry TYPE_GAS, which is the bit the fork's guard excludes on")
			{
				// Simulation.cpp: vel > 5 && !(Properties & TYPE_GAS). The oxygen the
				// comment there calls "OXYG" is element PT_O2; its own Diffusion jitter
				// alone reaches ~5, which is what used to abrade trees into sawdust.
				REQUIRE((sd.elements[PT_O2].Properties & TYPE_GAS) != 0);
				REQUIRE(sd.elements[PT_O2].Diffusion > 0.0f);
			}
		}
	}
}

// --------------------------------------------------- bounds on the element array

TEST_CASE("element-array access is bounds-guarded at the engine's own accessors", "[elements][throws]")
{
	SimulationData sd;

	// elements[parts[i].type] with a corrupt type is the classic out-of-bounds crash
	// in this engine. IsElement is the guarded accessor callers are supposed to use:
	// it must reject out-of-range types without throwing or reading past the array.
	REQUIRE(sd.IsElement(PT_WOOD));
	REQUIRE_FALSE(sd.IsElement(PT_NUM));
	REQUIRE_FALSE(sd.IsElement(-1));
	REQUIRE_FALSE(sd.IsElement(0));
	REQUIRE(sd.IsElementOrNone(0));

	// And the underlying array really is only PT_NUM long, so an unguarded index one
	// past the end is genuinely out of bounds rather than harmlessly in slack space.
	REQUIRE(sd.elements.size() == size_t(PT_NUM));
	REQUIRE_NOTHROW(sd.elements.at(PT_NUM - 1));
	REQUIRE_THROWS_AS(sd.elements.at(PT_NUM), std::out_of_range);
}
