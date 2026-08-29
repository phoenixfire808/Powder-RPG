#include "GameView.h"

#include <cmath>
#include <map>

#include "Brush.h"
#include "tool/DecorationTool.h"
#include "tool/PropertyTool.h"
#include "Favorite.h"
#include "Format.h"
#include "GameController.h"
#include "GameModel.h"
#include "IntroText.h"
#include "Menu.h"
#include "MenuButton.h"
#include "Misc.h"
#include "Notification.h"
#include "SubCategory.h"
#include "ToolButton.h"
#include "QuickOptions.h"
#include "PowderToySDL.h"

#include "client/SaveInfo.h"
#include "client/SaveFile.h"
#include "client/Client.h"
#include "client/GameSave.h"
#include "common/platform/Platform.h"
#include "graphics/Graphics.h"
#include "graphics/Renderer.h"
#include "graphics/VideoBuffer.h"
#include "gui/Style.h"
#include "simulation/ElementClasses.h"
#include "simulation/ElementDefs.h"
#include "simulation/SaveRenderer.h"
#include "simulation/SimulationData.h"
#include "simulation/Simulation.h"
#include "simulation/elements/PLNT.h"

#include "gui/dialogues/ConfirmPrompt.h"
#include "gui/dialogues/ErrorMessage.h"
#include "gui/dialogues/InformationMessage.h"
#include "gui/interface/Button.h"
#include "gui/interface/Colour.h"
#include "gui/interface/Engine.h"

#include "Config.h"
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <SDL.h>

class SplitButton : public ui::Button
{
	bool rightDown;
	bool leftDown;
	bool showSplit;
	int splitPosition;
	String toolTip2;

	struct SplitButtonAction
	{
		std::function<void ()> left, right;
	};
	SplitButtonAction actionCallback;

public:
	SplitButton(ui::Point position, ui::Point size, String buttonText, String toolTip, String toolTip2, int split) :
		Button(position, size, buttonText, toolTip),
		showSplit(true),
		splitPosition(split),
		toolTip2(toolTip2)
	{

	}
	virtual ~SplitButton() = default;

	void SetRightToolTip(String tooltip) { toolTip2 = tooltip; }
	bool GetShowSplit() { return showSplit; }
	void SetShowSplit(bool split) { showSplit = split; }
	inline SplitButtonAction const &GetSplitActionCallback() { return actionCallback; }
	inline void SetSplitActionCallback(SplitButtonAction const &action) { actionCallback = action; }
	void SetToolTip(int x, int y)
	{
		if(x >= splitPosition || !showSplit)
		{
			if(toolTip2.length()>0 && GetParentWindow())
			{
				GetParentWindow()->ToolTip(Position, toolTip2);
			}
		}
		else if(x < splitPosition)
		{
			if(toolTip.length()>0 && GetParentWindow())
			{
				GetParentWindow()->ToolTip(Position, toolTip);
			}
		}
	}
	void OnMouseClick(int x, int y, unsigned int button) override
	{
		if(isButtonDown)
		{
			if(leftDown)
				DoLeftAction();
			else if(rightDown)
				DoRightAction();
		}
		ui::Button::OnMouseClick(x, y, button);

	}
	void OnMouseHover(int x, int y) override
	{
		SetToolTip(x, y);
	}
	void OnMouseEnter(int x, int y) override
	{
		isMouseInside = true;
		if(!Enabled)
			return;
		SetToolTip(x, y);
	}
	void TextPosition(String ButtonText) override
	{
		ui::Button::TextPosition(ButtonText);
		textPosition.X += 3;
	}
	void SetToolTips(String newToolTip1, String newToolTip2)
	{
		toolTip = newToolTip1;
		toolTip2 = newToolTip2;
	}
	void OnMouseDown(int x, int y, unsigned int button) override
	{
		ui::Button::OnMouseDown(x, y, button);
		if (MouseDownInside)
		{
			rightDown = false;
			leftDown = false;
			if(x - Position.X >= splitPosition)
				rightDown = true;
			else if(x - Position.X < splitPosition)
				leftDown = true;
		}
	}
	void DoRightAction()
	{
		if(!Enabled)
			return;
		if (actionCallback.right)
			actionCallback.right();
	}
	void DoLeftAction()
	{
		if(!Enabled)
			return;
		if (actionCallback.left)
			actionCallback.left();
	}
	void Draw(const ui::Point& screenPos) override
	{
		ui::Button::Draw(screenPos);
		Graphics * g = GetGraphics();
		drawn = true;

		if(showSplit)
			g->DrawLine(screenPos + Vec2{ splitPosition, 1 }, screenPos + Vec2{ splitPosition, Size.Y-2 }, 0xB4B4B4_rgb);
	}
};


GameView::GameView():
	ui::Window(ui::Point(0, 0), ui::Point(WINDOWW, WINDOWH)),
	isMouseDown(false),
	skipDraw(false),
	zoomEnabled(false),
	zoomCursorFixed(false),
	mouseInZoom(false),
	drawSnap(false),
	shiftBehaviour(false),
	ctrlBehaviour(false),
	altBehaviour(false),
	showHud(true),
	showBrush(true),
	showDebug(false),
	delayedActiveMenu(-1),
	wallBrush(false),
	toolBrush(false),
	decoBrush(false),
	toolIndex(0),
	currentSaveType(0),
	lastMenu(-1),

	toolTip(""),
	isToolTipFadingIn(false),
	toolTipPosition(-1, -1),
	infoTip(""),
	buttonTip(""),
	isButtonTipFadingIn(false),
	introTextMessage(IntroText().FromUtf8()),

	doScreenshot(false),
	screenshotIndex(1),
	lastScreenshotTime(0),
	recordingIndex(0),
	recording(false),
	recordingFolder(0),
	currentPoint(ui::Point(0, 0)),
	lastPoint(ui::Point(0, 0)),
	activeBrush(nullptr),
	saveSimulationButtonEnabled(false),
	saveReuploadAllowed(true),
	drawMode(DrawPoints),
	drawPoint1(0, 0),
	drawPoint2(0, 0),
	selectMode(SelectNone),
	selectPoint1(0, 0),
	selectPoint2(0, 0),
	currentMouse(0, 0),
	mousePosition(0, 0)
{
	contributesToFps = true;

	int currentX = 1;
	//Set up UI

	scrollBar = new ui::Button(ui::Point(0,YRES+21), ui::Point(XRES, 2), "");
	scrollBar->Appearance.BorderHover = ui::Colour(200, 200, 200);
	scrollBar->Appearance.BorderActive = ui::Colour(200, 200, 200);
	scrollBar->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
	scrollBar->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
	AddComponent(scrollBar);

	searchButton = new ui::Button(ui::Point(currentX, Size.Y-16), ui::Point(17, 15), "", "Find & open a simulation. Hold Ctrl to load offline saves.");  //Open
	searchButton->SetIcon(IconOpen);
	currentX+=18;
	searchButton->SetTogglable(false);
	searchButton->SetActionCallback({ [this] {
		if (CtrlBehaviour())
			c->OpenLocalBrowse();
		else
			c->OpenSearch("");
	} });
	AddComponent(searchButton);

	reloadButton = new ui::Button(ui::Point(currentX, Size.Y-16), ui::Point(17, 15), "", "Reload the simulation");
	reloadButton->SetIcon(IconReload);
	reloadButton->Appearance.Margin.Left+=2;
	currentX+=18;
	reloadButton->SetActionCallback({ [this] { c->ReloadSim(); }, [this] { c->OpenSavePreview(); } });
	AddComponent(reloadButton);

	saveSimulationButton = new SplitButton(ui::Point(currentX, Size.Y-16), ui::Point(150, 15), "[untitled simulation]", "", "", 19);
	saveSimulationButton->Appearance.HorizontalAlign = ui::Appearance::AlignLeft;
	saveSimulationButton->SetIcon(IconSave);
	currentX+=151;
	saveSimulationButton->SetSplitActionCallback({
		[this] {
			if (CtrlBehaviour() || !Client::Ref().GetAuthUser())
				c->OpenLocalSaveWindow(true);
			else
				c->SaveAsCurrent();
		},
		[this] {
			if (CtrlBehaviour() || !Client::Ref().GetAuthUser())
				c->OpenLocalSaveWindow(false);
			else
				c->OpenSaveWindow();
		}
	});
	SetSaveButtonTooltips();
	AddComponent(saveSimulationButton);

	upVoteButton = new ui::Button(ui::Point(currentX, Size.Y-16), ui::Point(39, 15), "", "");
	upVoteButton->SetIcon(IconVoteUp);
	upVoteButton->Appearance.Margin.Top+=2;
	upVoteButton->Appearance.Margin.Left+=2;
	currentX+=38;
	AddComponent(upVoteButton);

	downVoteButton = new ui::Button(ui::Point(currentX, Size.Y-16), ui::Point(15, 15), "", "");
	downVoteButton->SetIcon(IconVoteDown);
	downVoteButton->Appearance.Margin.Bottom+=2;
	downVoteButton->Appearance.Margin.Left+=2;
	currentX+=16;
	AddComponent(downVoteButton);

	ResetVoteButtons();

	tagSimulationButton = new ui::Button(ui::Point(currentX, Size.Y-16), ui::Point(WINDOWW - 402, 15), "[no tags set]", "Add simulation tags");
	tagSimulationButton->Appearance.HorizontalAlign = ui::Appearance::AlignLeft;
	tagSimulationButton->SetIcon(IconTag);
	//currentX+=252;
	tagSimulationButton->SetActionCallback({ [this] { c->OpenTags(); } });
	AddComponent(tagSimulationButton);

	clearSimButton = new ui::Button(ui::Point(Size.X-159, Size.Y-16), ui::Point(17, 15), "", "Erase everything");
	clearSimButton->SetIcon(IconNew);
	clearSimButton->Appearance.Margin.Left+=2;
	clearSimButton->SetActionCallback({ [this] { c->ClearSim(); } });
	AddComponent(clearSimButton);

	loginButton = new SplitButton(ui::Point(Size.X-141, Size.Y-16), ui::Point(92, 15), "[sign in]", "Sign into simulation server", "Edit Profile", 19);
	loginButton->Appearance.HorizontalAlign = ui::Appearance::AlignLeft;
	loginButton->SetIcon(IconLogin);
	loginButton->SetSplitActionCallback({
		[this] { c->OpenLogin(); },
		[this] { c->OpenProfile(); }
	});
	AddComponent(loginButton);

	simulationOptionButton = new ui::Button(ui::Point(Size.X-48, Size.Y-16), ui::Point(15, 15), "", "Settings");
	simulationOptionButton->SetIcon(IconSimulationSettings);
	simulationOptionButton->Appearance.Margin.Left+=2;
	simulationOptionButton->SetActionCallback({ [this] { c->OpenOptions(); } });
	AddComponent(simulationOptionButton);

	displayModeButton = new ui::Button(ui::Point(Size.X-32, Size.Y-16), ui::Point(15, 15), "", "Renderer options");
	displayModeButton->SetIcon(IconRenderSettings);
	displayModeButton->Appearance.Margin.Left+=2;
	displayModeButton->SetActionCallback({ [this] { c->OpenRenderOptions(); } });
	AddComponent(displayModeButton);

	pauseButton = new ui::Button(ui::Point(Size.X-16, Size.Y-16), ui::Point(15, 15), "", "Pause/Resume the simulation");  //Pause
	pauseButton->SetIcon(IconPause);
	pauseButton->SetTogglable(true);
	pauseButton->SetActionCallback({ [this] { c->SetPaused(pauseButton->GetToggleState()); } });
	AddComponent(pauseButton);

	ui::Button * tempButton = new ui::Button(ui::Point(WINDOWW-16, WINDOWH-32), ui::Point(15, 15), 0xE065, "Search for elements");
	tempButton->Appearance.Margin = ui::Border(0, 2, 3, 2);
	tempButton->SetActionCallback({ [this] { c->OpenElementSearch(); } });
	AddComponent(tempButton);

	colourPicker = new ui::Button(ui::Point((XRES/2)-8, YRES+1), ui::Point(16, 16), "", "Pick Colour");
	colourPicker->SetActionCallback({ [this] { c->OpenColourPicker(); } });
}

GameView::~GameView()
{
	StopRendererThread();
	if(!colourPicker->GetParentWindow())
		delete colourPicker;

	for(std::vector<ToolButton*>::iterator iter = colourPresets.begin(), end = colourPresets.end(); iter != end; ++iter)
	{
		ToolButton * button = *iter;
		if(!button->GetParentWindow())
		{
			delete button;
		}

	}
}

class GameView::OptionListener: public QuickOptionListener
{
	ui::Button * button;
public:
	OptionListener(ui::Button * _button) { button = _button; }
	void OnValueChanged(QuickOption * option) override
	{
		switch(option->GetType())
		{
		case QuickOption::Toggle:
			button->SetTogglable(true);
			button->SetToggleState(option->GetToggle());
			break;
		default:
			break;
		}
	}
};

void GameView::NotifyQuickOptionsChanged(GameModel * sender)
{
	for (size_t i = 0; i < quickOptionButtons.size(); i++)
	{
		RemoveComponent(quickOptionButtons[i]);
		delete quickOptionButtons[i];
	}

	int currentY = 1;
	std::vector<QuickOption*> optionList = sender->GetQuickOptions();
	for(auto *option : optionList)
	{
		ui::Button * tempButton = new ui::Button(ui::Point(WINDOWW-16, currentY), ui::Point(15, 15), option->GetIcon(), option->GetDescription());
		//tempButton->Appearance.Margin = ui::Border(0, 2, 3, 2);
		tempButton->SetTogglable(true);
		tempButton->SetActionCallback({ [option] {
			option->Perform();
		} });
		option->AddListener(new OptionListener(tempButton));
		AddComponent(tempButton);

		quickOptionButtons.push_back(tempButton);
		currentY += 16;
	}
}

void GameView::NotifyMenuListChanged(GameModel * sender)
{
	int currentY = WINDOWH-48;//-(sender->GetMenuList().size()*16);
	for (size_t i = 0; i < menuButtons.size(); i++)
	{
		RemoveComponent(menuButtons[i]);
		delete menuButtons[i];
	}
	menuButtons.clear();
	for (size_t i = 0; i < toolButtons.size(); i++)
	{
		RemoveComponent(toolButtons[i]);
		delete toolButtons[i];
	}
	toolButtons.clear();
	std::vector<Menu*> menuList = sender->GetMenuList();
	for (int i = (int)menuList.size()-1; i >= 0; i--)
	{
		if (menuList[i]->GetVisible())
		{
			String tempString = "";
			tempString += menuList[i]->GetIcon();
			String description = menuList[i]->GetDescription();
			if (i == SC_FAVORITES && !Favorite::Ref().AnyFavorites())
				description += " (Use ctrl+shift+click to toggle the favorite status of an element)";
			auto *tempButton = new MenuButton(ui::Point(WINDOWW-16, currentY), ui::Point(15, 15), tempString, description);
			tempButton->Appearance.Margin = ui::Border(0, 2, 3, 2);
			tempButton->menuID = i;
			tempButton->needsClick = i == SC_DECO;
			tempButton->SetTogglable(true);
			auto mouseEnterCallback = [this, tempButton] {
				// don't immediately change the active menu, the actual set is done inside GameView::OnMouseMove
				// if we change it here it causes components to be removed, which causes the window to stop sending events
				// and then the previous menusection button never gets sent the OnMouseLeave event and is never unhighlighted
				if(!(tempButton->needsClick || c->GetMouseClickRequired()) && !GetMouseDown())
					SetActiveMenuDelayed(tempButton->menuID);
			};
			auto actionCallback = [this, tempButton, mouseEnterCallback] {
				if (tempButton->needsClick || c->GetMouseClickRequired())
					c->SetActiveMenu(tempButton->menuID);
				else
					mouseEnterCallback();
				// Opening the subcategory ladder is a click now, not a
				// hover -- see UpdateSubCategoryLadderHover, which only
				// keeps an already-open ladder alive, never opens one.
				if (GetSubCategories().count(tempButton->menuID) != 0)
				{
					subCategoryLadderVisible = true;
					subCategoryLadderMenuID = tempButton->menuID;
					RebuildSubCategoryLadder();
					subCategoryLadderHideDelay = 20;
				}
			};
			tempButton->SetActionCallback({ actionCallback, nullptr, mouseEnterCallback });
			currentY-=16;
			AddComponent(tempButton);
			menuButtons.push_back(tempButton);
		}
	}
}

void GameView::SetSample(SimulationSample sample)
{
	this->sample = sample;
}

void GameView::SetHudEnable(bool hudState)
{
	showHud = hudState;
	if (!showHud)
		introText = 0;
}

bool GameView::GetHudEnable()
{
	return showHud;
}

void GameView::SetBrushEnable(bool brushState)
{
	showBrush = brushState;
}

bool GameView::GetBrushEnable()
{
	return showBrush;
}

void GameView::SetDebugHUD(bool mode)
{
	showDebug = mode;
	rendererSettings->debugLines = showDebug;
}

bool GameView::GetDebugHUD()
{
	return showDebug;
}

ui::Point GameView::GetMousePosition()
{
	return currentMouse;
}

bool GameView::GetPlacingSave()
{
	return selectMode != SelectNone;
}

bool GameView::GetPlacingZoom()
{
	return zoomEnabled && !zoomCursorFixed;
}

void GameView::NotifyActiveToolsChanged(GameModel * sender)
{
	for (size_t i = 0; i < toolButtons.size(); i++)
	{
		auto *tool = toolButtons[i]->tool;
		// Primary
		if (sender->GetActiveTool(0) == tool)
			toolButtons[i]->SetSelectionState(0);
		// Secondary
		else if (sender->GetActiveTool(1) == tool)
			toolButtons[i]->SetSelectionState(1);
		// Tertiary
		else if (sender->GetActiveTool(2) == tool)
			toolButtons[i]->SetSelectionState(2);
		// Replace Mode
		else if (sender->GetActiveTool(3) == tool)
			toolButtons[i]->SetSelectionState(3);
		// Not selected at all
		else
			toolButtons[i]->SetSelectionState(-1);
	}

	decoBrush = sender->GetActiveTool(0)->Identifier.BeginsWith("DEFAULT_DECOR_");

	auto &settings = sender->GetRendererSettings();
	if (settings.findingElement)
	{
		settings.findingElement = FindingElementCandidate();
	}
}

void GameView::NotifyLastToolChanged(GameModel * sender)
{
	if (sender->GetLastTool())
	{
		wallBrush = sender->GetLastTool()->Blocky;
		toolBrush = sender->GetLastTool()->Identifier.BeginsWith("DEFAULT_TOOL_");
	}
}

void GameView::RebuildSubCategoryLadder()
{
	for (size_t i = 0; i < subCategoryButtons.size(); i++)
	{
		RemoveComponent(subCategoryButtons[i]);
		delete subCategoryButtons[i];
	}
	subCategoryButtons.clear();
	subCategoryLadderSize = ui::Point(0, 0);

	if (!subCategoryLadderVisible)
	{
		return;
	}
	auto subCatIt = GetSubCategories().find(subCategoryLadderMenuID);
	if (subCatIt == GetSubCategories().end())
	{
		return;
	}

	// Anchor the ladder to the active category's own button on the right
	// edge and stack upward from it, so it reads as "this button's list"
	// rather than competing with the tool-icon row for the same 40px of
	// permanently-reserved bottom-bar space (there isn't room for both).
	int anchorY = YRES - 16;
	for (auto *mb : menuButtons)
	{
		if (mb->menuID == subCategoryLadderMenuID)
		{
			anchorY = mb->Position.Y;
			break;
		}
	}
	constexpr int chipWidth = 140;
	constexpr int chipHeight = 17;
	int chipX = WINDOWW - 16 - chipWidth;
	int chipY = anchorY - chipHeight;
	// A band with nothing in it renders as a dead button -- clicking it just
	// shows an empty tool row, which reads as "the categorization is broken"
	// even when every band definition is correct, since custom elements come
	// and go (evicted, never restored, etc.) independent of these static
	// band lists. So count live tools per band and skip anything at zero.
	std::vector<Tool *> sectionTools;
	auto menuList = c->GetMenuList();
	if (subCategoryLadderMenuID >= 0 && subCategoryLadderMenuID < int(menuList.size()) && menuList[subCategoryLadderMenuID])
	{
		sectionTools = menuList[subCategoryLadderMenuID]->GetToolList();
	}
	std::vector<std::pair<int, const SubCategory *>> nonEmptyBands;
	for (size_t i = 0; i < subCatIt->second.size(); i++)
	{
		auto &band = subCatIt->second[i];
		bool hasTool = false;
		for (auto *tool : sectionTools)
		{
			if (tool->MenuSort >= band.sortMin && tool->MenuSort <= band.sortMax)
			{
				hasTool = true;
				break;
			}
		}
		if (hasTool)
		{
			nonEmptyBands.push_back({ int(i), &band });
		}
	}

	subCategoryLadderTopLeft = ui::Point(chipX, chipY - chipHeight * (int(nonEmptyBands.size()) - 1));
	subCategoryLadderSize = ui::Point(chipWidth, chipHeight * int(nonEmptyBands.size()));
	for (auto &entry : nonEmptyBands)
	{
		int subIndex = entry.first;
		auto &band = *entry.second;
		auto *chip = new ui::Button(ui::Point(chipX, chipY), ui::Point(chipWidth, chipHeight), band.label);
		chip->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		chip->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		chip->SetActionCallback({ [this, subIndex] {
			c->SetActiveSubCategory(subIndex);
		} });
		AddComponent(chip);
		subCategoryButtons.push_back(chip);
		chipY -= chipHeight;
	}
}

void GameView::UpdateSubCategoryLadderHover(ui::Point mouse)
{
	// Opening the ladder is a click now (see the menu button's
	// actionCallback), not a hover -- this function's only job once it's
	// open is to keep it alive while the mouse is over it or its anchor
	// button, so it doesn't vanish mid-transit between the two. It never
	// opens a ladder on its own.
	if (!subCategoryLadderVisible)
	{
		return;
	}
	bool overAnchorButton = false;
	for (auto *mb : menuButtons)
	{
		auto pos = mb->Position;
		auto size = mb->Size;
		if (mb->menuID == subCategoryLadderMenuID &&
			mouse.X >= pos.X && mouse.X < pos.X + size.X && mouse.Y >= pos.Y && mouse.Y < pos.Y + size.Y)
		{
			overAnchorButton = true;
			break;
		}
	}
	if (overAnchorButton || PointInSubCategoryLadder(mouse))
	{
		constexpr int kHoverGraceTicks = 20;
		subCategoryLadderHideDelay = kHoverGraceTicks;
	}
	// else: don't hide here -- DecaySubCategoryLadderHover() (driven by
	// OnTick) owns closing it, so a single frame with the mouse between the
	// button and the ladder doesn't dismiss it mid-transit.
}

void GameView::DecaySubCategoryLadderHover()
{
	if (!subCategoryLadderVisible || subCategoryLadderHideDelay <= 0)
	{
		return;
	}
	subCategoryLadderHideDelay--;
	if (subCategoryLadderHideDelay == 0)
	{
		subCategoryLadderVisible = false;
		subCategoryLadderMenuID = -1;
		RebuildSubCategoryLadder();
	}
}

void GameView::RebuildStateLadder()
{
	for (auto *btn : stateLadderButtons)
	{
		RemoveComponent(btn);
		delete btn;
	}
	stateLadderButtons.clear();
	stateLadderSize = ui::Point(0, 0);

	if (!stateLadderVisible || !stateLadderButton || !stateLadderButton->tool)
	{
		return;
	}
	Tool *sourceTool = stateLadderButton->tool;

	static const char *const carrierIdentifiers[] = {
		"DEFAULT_PT_PWCR", "DEFAULT_PT_LQCR", "DEFAULT_PT_GSCR", "DEFAULT_PT_SDCR",
	};
	std::vector<std::pair<ByteString, String>> available;
	for (auto *identifier : carrierIdentifiers)
	{
		String label = c->GetStateCarrierLabel(sourceTool, identifier);
		if (!label.empty())
		{
			available.push_back({ ByteString(identifier), label });
		}
	}
	if (available.empty())
	{
		return;
	}

	// Reverted back to a stacked list -- Drew tried the radial "command
	// wheel" layout and preferred the original list ("I liked how the
	// menus were for the elements before"). The actual command-wheel ask
	// turned out to be a bigger, separate feature (a customizable
	// shortcut/action wheel modeled on a specific RimWorld mod), not just
	// this picker's shape -- see TODO.md.
	constexpr int chipWidth = 90;
	constexpr int chipHeight = 17;
	int chipX = stateLadderButton->Position.X;
	int chipY = stateLadderButton->Position.Y - chipHeight;
	stateLadderTopLeft = ui::Point(chipX, chipY - chipHeight * (int(available.size()) - 1));
	stateLadderSize = ui::Point(chipWidth, chipHeight * int(available.size()));
	for (auto &entry : available)
	{
		ByteString identifier = entry.first;
		auto *chip = new ui::Button(ui::Point(chipX, chipY), ui::Point(chipWidth, chipHeight), entry.second);
		chip->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		chip->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		chip->SetActionCallback({ [this, identifier] {
			if (stateLadderButton && stateLadderButton->tool)
			{
				c->SelectStateCarrierTool(stateLadderButton->GetSelectionState(), stateLadderButton->tool, identifier);
			}
		} });
		AddComponent(chip);
		stateLadderButtons.push_back(chip);
		chipY -= chipHeight;
	}
}

// Ctrl+drag region fill (Rect or Ellipse, see ElementTool::DrawRect) anchors
// at the drag's start point by default (a corner), or at its centre when
// centerAnchorBehaviour is held (M), growing outward in both directions --
// same choice RimWorld's Designator Shapes mod offers its designators.
static void ComputeAnchoredRect(ui::Point anchor, ui::Point edge, bool centerAnchor, ui::Point &corner1, ui::Point &corner2)
{
	if (centerAnchor)
	{
		ui::Point delta = edge - anchor;
		corner1 = anchor - delta;
		corner2 = anchor + delta;
	}
	else
	{
		corner1 = anchor;
		corner2 = edge;
	}
}

// Full circle, not a semicircle -- this wheel opens wherever the cursor is,
// not pinned to a toolbar button at the screen edge, so there's no edge to
// avoid. Radius grows with item count so slots don't bunch together --
// circumference has to grow with the slot count or neighbouring icons start
// overlapping instead of just touching, same reason radial pickers like
// RimWorld's Mint wheel visibly get bigger as more gets assigned rather than
// shrinking the icons to fit a fixed ring.
static std::vector<ui::Point> ComputeWheelSlotPositions(ui::Point center, int n, int itemSize)
{
	constexpr int minRadius = 65;
	constexpr float spacingFactor = 1.15f; // a bit more than itemSize so icons don't touch edge-to-edge
	int radius = int(std::max(float(minRadius), n * itemSize * spacingFactor / (2.0f * 3.14159265f)));
	std::vector<ui::Point> positions(n, ui::Point(0, 0));
	for (int idx = 0; idx < n; idx++)
	{
		float angle = -1.57079633f + 2.0f * 3.14159265f * float(idx) / float(n); // start pointing up, go clockwise
		positions[idx] = ui::Point(
			center.X + int(radius * std::cos(angle)) - itemSize / 2,
			center.Y + int(radius * std::sin(angle)) - itemSize / 2
		);
	}
	return positions;
}

void GameView::SetFavoritesWheelBounds(ui::Point center, const std::vector<ui::Point> &positions, int itemSize)
{
	int minX = center.X, maxX = center.X, minY = center.Y, maxY = center.Y;
	for (auto &p : positions)
	{
		minX = std::min(minX, p.X);
		maxX = std::max(maxX, p.X + itemSize);
		minY = std::min(minY, p.Y);
		maxY = std::max(maxY, p.Y + itemSize);
	}
	favoritesWheelTopLeft = ui::Point(minX, minY);
	favoritesWheelSize = ui::Point(maxX - minX, maxY - minY);
}

void GameView::OpenFavoritesWheel(ui::Point center)
{
	CloseFavoritesWheel();

	auto favorites = Favorite::Ref().GetFavoritesList();
	std::vector<Tool *> tools;
	for (auto &identifier : favorites)
	{
		if (auto *tool = c->GetToolFromIdentifier(identifier))
		{
			tools.push_back(tool);
		}
	}
	if (tools.empty())
	{
		return;
	}

	// Layers: group favorites by the menu category their element already
	// belongs to, same idea as RimWorld's architect menu grouping
	// designators into named categories (Structure, Production, ...) that
	// each open their own list, rather than one long flat menu. Reuses the
	// category every tool already has instead of adding a separate
	// per-favorite category-assignment UI. If everything favorited happens
	// to share one category there's nothing to group, so skip straight to
	// the flat ring.
	std::map<int, std::vector<Tool *>> byCategory;
	for (auto *tool : tools)
	{
		byCategory[tool->MenuSection].push_back(tool);
	}

	if (byCategory.size() <= 1)
	{
		OpenFavoritesLeafRing(center, tools, -1);
	}
	else
	{
		OpenFavoritesCategoryRing(center, byCategory);
	}
}

// Copy/Paste live on the wheel's outermost ring (the category ring when
// there is one, otherwise the flat leaf ring) since they're global actions,
// not tied to any one material -- no reason to bury them inside a specific
// category's drilled-down list. Just replicates the existing Ctrl+C/Ctrl+V
// keyboard-shortcut state changes (GameView::OnKeyPress, SDL_SCANCODE_C/V)
// so the same click-and-drag-to-copy / click-to-place-paste flow runs
// afterward exactly as if the hotkey had been pressed.
void GameView::AddFavoritesWheelActionSlot(ui::Point position, int itemSize, String label, std::function<void()> action)
{
	auto *slot = new ui::Button(position, ui::Point(itemSize, itemSize), label);
	slot->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
	slot->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
	slot->SetActionCallback({ [this, action] {
		action();
		CloseFavoritesWheel();
	} });
	AddComponent(slot);
	favoritesWheelButtons.push_back(slot);
}

void GameView::AddFavoritesWheelCopyPasteSlots(const std::vector<ui::Point> &positions, int firstIdx, int itemSize)
{
	AddFavoritesWheelActionSlot(positions[firstIdx], itemSize, "Copy", [this] {
		selectMode = SelectCopy;
		selectPoint1 = selectPoint2 = ui::Point(-1, -1);
		isMouseDown = false;
		buttonTip = "\x0F\xEF\xEF\020Click-and-drag to specify an area to copy (right click = cancel)";
		buttonTipShow = 120;
	});
	AddFavoritesWheelActionSlot(positions[firstIdx + 1], itemSize, "Paste", [this] {
		if (c->LoadClipboard())
		{
			selectPoint1 = selectPoint2 = mousePosition;
			isMouseDown = false;
		}
	});
}

void GameView::OpenFavoritesCategoryRing(ui::Point center, const std::map<int, std::vector<Tool *>> &byCategory)
{
	auto &sd = SimulationData::CRef();
	constexpr int itemSize = 44;
	std::vector<int> categories;
	for (auto &pair : byCategory)
	{
		categories.push_back(pair.first);
	}
	int categoryCount = int(categories.size());
	int n = categoryCount + 2; // + Copy, Paste
	auto positions = ComputeWheelSlotPositions(center, n, itemSize);
	SetFavoritesWheelBounds(center, positions, itemSize);

	for (int idx = 0; idx < categoryCount; idx++)
	{
		int category = categories[idx];
		std::vector<Tool *> categoryTools = byCategory.at(category);
		String label = (category >= 0 && category < int(sd.msections.size())) ? sd.msections[category].name : String("?");
		auto *slot = new ui::Button(positions[idx], ui::Point(itemSize, itemSize), label);
		slot->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		slot->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		slot->Appearance.BackgroundInactive = categoryTools.front()->Colour.WithAlpha(0xFF);
		slot->SetActionCallback({ [this, center, categoryTools, category] {
			OpenFavoritesLeafRing(center, categoryTools, category);
		} });
		AddComponent(slot);
		favoritesWheelButtons.push_back(slot);
	}
	AddFavoritesWheelCopyPasteSlots(positions, categoryCount, itemSize);
	favoritesWheelVisible = true;
}

void GameView::OpenFavoritesLeafRing(ui::Point center, std::vector<Tool *> tools, int backToCategory)
{
	CloseFavoritesWheel();

	constexpr int itemSize = 44;
	bool hasBack = backToCategory >= 0;
	// Copy/Paste only belong on the outermost ring -- when this leaf ring is
	// a drilled-down category (hasBack) they're already one Back-click away,
	// no need to repeat them here.
	int n = int(tools.size()) + (hasBack ? 1 : 2);
	auto positions = ComputeWheelSlotPositions(center, n, itemSize);
	SetFavoritesWheelBounds(center, positions, itemSize);

	int idx = 0;
	if (hasBack)
	{
		// Drilled into a category -- one slot dedicated to backing out to
		// the category ring instead of picking a tool.
		auto *back = new ui::Button(positions[idx], ui::Point(itemSize, itemSize), "Back");
		back->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		back->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		back->SetActionCallback({ [this, center] { OpenFavoritesWheel(center); } });
		AddComponent(back);
		favoritesWheelButtons.push_back(back);
		idx++;
	}
	for (auto *tool : tools)
	{
		// ToolButton, not a plain Button -- picking up its existing
		// left/right/middle-click -> SetSelectionState(0/1/2) + DoAction
		// dispatch is what lets a wheel slot go to whichever tool slot
		// (primary/secondary/tertiary) matches the button you clicked it
		// with, the same as clicking a real toolbar button does, instead
		// of always landing on primary regardless of which button was used.
		auto *slot = new ToolButton(positions[idx], ui::Point(itemSize, itemSize), tool->Name, tool->Identifier, tool->Description);
		slot->tool = tool;
		slot->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		slot->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		slot->Appearance.BackgroundInactive = tool->Colour.WithAlpha(0xFF);
		slot->SetActionCallback({ [this, slot] {
			// Read everything off slot BEFORE CloseFavoritesWheel() deletes
			// it -- this callback is still on slot's own call stack.
			int slotIndex = slot->GetSelectionState();
			Tool *pickedTool = slot->tool;
			if (slotIndex < 0 || slotIndex > 2)
				slotIndex = 0;
			if (pickedTool)
			{
				c->SetActiveTool(slotIndex, pickedTool);
			}
			CloseFavoritesWheel();
		} });
		AddComponent(slot);
		favoritesWheelButtons.push_back(slot);
		idx++;
	}
	if (!hasBack)
	{
		AddFavoritesWheelCopyPasteSlots(positions, idx, itemSize);
	}
	favoritesWheelVisible = true;
}

void GameView::CloseFavoritesWheel()
{
	for (auto *btn : favoritesWheelButtons)
	{
		RemoveComponent(btn);
		delete btn;
	}
	favoritesWheelButtons.clear();
	favoritesWheelVisible = false;
	favoritesWheelSize = ui::Point(0, 0);
}

void GameView::UpdateStateLadderHover(ui::Point mouse)
{
	// Opening the ladder is a click now (see the tool button's
	// actionCallback), not a hover -- same shape as
	// UpdateSubCategoryLadderHover. Only keeps an already-open ladder alive
	// while the mouse is over it or its anchor button; never opens one.
	if (!stateLadderVisible || !stateLadderButton)
	{
		return;
	}
	auto pos = stateLadderButton->Position;
	auto size = stateLadderButton->Size;
	bool overAnchorButton = mouse.X >= pos.X && mouse.X < pos.X + size.X && mouse.Y >= pos.Y && mouse.Y < pos.Y + size.Y;
	if (overAnchorButton || PointInStateLadder(mouse))
	{
		constexpr int kHoverGraceTicks = 20;
		stateLadderHideDelay = kHoverGraceTicks;
	}
	// else: DecayStateLadderHover() (driven by OnTick) owns closing it.
}

void GameView::DecayStateLadderHover()
{
	if (!stateLadderVisible || stateLadderHideDelay <= 0)
	{
		return;
	}
	stateLadderHideDelay--;
	if (stateLadderHideDelay == 0)
	{
		stateLadderVisible = false;
		stateLadderButton = nullptr;
		RebuildStateLadder();
	}
}

void GameView::NotifyActiveMenuToolListChanged(GameModel * sender)
{
	for (size_t i = 0; i < menuButtons.size(); i++)
	{
		if (menuButtons[i]->menuID==sender->GetActiveMenu())
		{
			menuButtons[i]->SetToggleState(true);
		}
		else
		{
			menuButtons[i]->SetToggleState(false);
		}
	}
	for (size_t i = 0; i < toolButtons.size(); i++)
	{
		RemoveComponent(toolButtons[i]);
		delete toolButtons[i];
	}
	toolButtons.clear();
	// stateLadderButton points into the toolButtons vector just deleted --
	// drop the ladder too, or its hover check / chip callbacks read a
	// dangling ToolButton. Safe (unlike the subcategory ladder below) to
	// tear down unconditionally here: picking a state carrier goes through
	// SetActiveTool, not SetActiveSubCategory, so this notify never fires
	// from inside one of these chips' own callback.
	for (auto *btn : stateLadderButtons)
	{
		RemoveComponent(btn);
		delete btn;
	}
	stateLadderButtons.clear();
	stateLadderVisible = false;
	stateLadderButton = nullptr;
	stateLadderSize = ui::Point(0, 0);
	// Deliberately NOT calling RebuildSubCategoryLadder() here: this notify
	// also fires from inside a subcategory chip's own click callback (via
	// SetActiveSubCategory -> notifyActiveMenuToolListChanged), and rebuild
	// deletes/recreates every chip -- including the one whose callback is
	// still on the stack. The chip set never needs to change just because
	// the filtered tool list did; hover tracking (UpdateSubCategoryLadderHover)
	// already owns rebuilding the ladder for every case that actually needs it.

	std::vector<Tool*> toolList = sender->GetActiveMenuToolList();
	int currentX = 0;
	for (size_t i = 0; i < toolList.size(); i++)
	{
		auto *tool = toolList[i];
		auto tempTexture = tool->GetTexture(Vec2(26, 14));
		ToolButton * tempButton;

		//get decotool texture manually, since it changes depending on it's own color
		if (sender->GetActiveMenu() == SC_DECO)
			tempTexture = static_cast<DecorationTool *>(tool)->GetIcon(tool->ToolID, Vec2(26, 14));

		if (tempTexture)
			tempButton = new ToolButton(ui::Point(currentX, YRES+1), ui::Point(30, 18), "", tool->Identifier, tool->Description);
		else
			tempButton = new ToolButton(ui::Point(currentX, YRES+1), ui::Point(30, 18), tool->Name, tool->Identifier, tool->Description);

		tempButton->ClipRect = RectSized(Vec2(1, RES.Y + 1), Vec2(RES.X - 1, 18));

		//currentY -= 17;
		currentX -= 31;
		tempButton->tool = tool;
		tempButton->SetActionCallback({ [this, tempButton] {
			auto *tool = tempButton->tool;
			// Pick a different physical state for this element right at
			// selection time -- e.g. Alt-click a solid to get a powder
			// version of it -- instead of a separate tool/mode. Single
			// modifiers only, so they don't collide with the double-modifier
			// combos below (favorite toggle, force-decoration-slot).
			if (AltBehaviour() && !ShiftBehaviour() && !CtrlBehaviour())
			{
				c->SelectStateCarrierTool(tempButton->GetSelectionState(), tool, "DEFAULT_PT_PWCR");
				return;
			}
			if (ShiftBehaviour() && !AltBehaviour() && !CtrlBehaviour())
			{
				c->SelectStateCarrierTool(tempButton->GetSelectionState(), tool, "DEFAULT_PT_LQCR");
				return;
			}
			if (CtrlBehaviour() && !ShiftBehaviour() && !AltBehaviour())
			{
				c->SelectStateCarrierTool(tempButton->GetSelectionState(), tool, "DEFAULT_PT_GSCR");
				return;
			}
			if (ShiftBehaviour() && AltBehaviour() && !CtrlBehaviour())
			{
				c->SelectStateCarrierTool(tempButton->GetSelectionState(), tool, "DEFAULT_PT_SDCR");
				return;
			}
			if (ShiftBehaviour() && CtrlBehaviour() && !AltBehaviour())
			{
				if (tempButton->GetSelectionState() == 0)
				{
					if (Favorite::Ref().IsFavorite(tool->Identifier))
					{
						Favorite::Ref().RemoveFavorite(tool->Identifier);
					}
					else
					{
						Favorite::Ref().AddFavorite(tool->Identifier);
					}
					c->RebuildFavoritesMenu();
				}
				else if (tempButton->GetSelectionState() == 1)
				{
					auto identifier = tool->Identifier;
					if (Favorite::Ref().IsFavorite(identifier))
					{
						Favorite::Ref().RemoveFavorite(identifier);
						c->RebuildFavoritesMenu();
					}
					else if (identifier.BeginsWith("DEFAULT_PT_LIFECUST_"))
					{
						new ConfirmPrompt("Remove custom GOL type", "Are you sure you want to remove " + identifier.Substr(20).FromUtf8() + "?", { [this, identifier]() {
							c->RemoveCustomGol(identifier);
						} });
					}
				}
			}
			else
			{
				if (CtrlBehaviour() && AltBehaviour() && !ShiftBehaviour())
				{
					if (tool->Identifier.Contains("_PT_"))
					{
						tempButton->SetSelectionState(3);
					}
				}

				if (tempButton->GetSelectionState() >= 0 && tempButton->GetSelectionState() <= 3)
					c->SetActiveTool(tempButton->GetSelectionState(), tool);
				// Opening the state-picker ladder is a click now, not a
				// hover -- see UpdateStateLadderHover, which only keeps an
				// already-open ladder alive, never opens one. Drew wants it
				// on every plain element selection regardless of which
				// button did the selecting (left/right/middle all funnel
				// through this `else` branch when no modifier is held), so
				// unlike the subcategory ladder above, this one isn't gated
				// to a specific selection state.
				stateLadderVisible = true;
				stateLadderButton = tempButton;
				RebuildStateLadder();
				stateLadderHideDelay = 20;
			}
		} });

		tempButton->Appearance.SetTexture(std::move(tempTexture));

		tempButton->Appearance.BackgroundInactive = toolList[i]->Colour.WithAlpha(0xFF);

		if(sender->GetActiveTool(0) == toolList[i])
		{
			tempButton->SetSelectionState(0);	//Primary
		}
		else if(sender->GetActiveTool(1) == toolList[i])
		{
			tempButton->SetSelectionState(1);	//Secondary
		}
		else if(sender->GetActiveTool(2) == toolList[i])
		{
			tempButton->SetSelectionState(2);	//Tertiary
		}
		else if(sender->GetActiveTool(3) == toolList[i])
		{
			tempButton->SetSelectionState(3);	//Replace mode
		}

		tempButton->Appearance.HorizontalAlign = ui::Appearance::AlignCentre;
		tempButton->Appearance.VerticalAlign = ui::Appearance::AlignMiddle;
		AddComponent(tempButton);
		toolButtons.push_back(tempButton);
	}
	if (sender->GetActiveMenu() != SC_DECO)
		lastMenu = sender->GetActiveMenu();

	updateToolButtonScroll();
}

void GameView::NotifyColourSelectorVisibilityChanged(GameModel * sender)
{
	for(std::vector<ToolButton*>::iterator iter = colourPresets.begin(), end = colourPresets.end(); iter != end; ++iter)
	{
		ToolButton * button = *iter;
		RemoveComponent(button);
		button->SetParentWindow(nullptr);
	}

	RemoveComponent(colourPicker);
	colourPicker->SetParentWindow(nullptr);

	if(sender->GetColourSelectorVisibility())
	{
		for(std::vector<ToolButton*>::iterator iter = colourPresets.begin(), end = colourPresets.end(); iter != end; ++iter)
		{
			ToolButton * button = *iter;
			AddComponent(button);
		}
		AddComponent(colourPicker);
		c->SetActiveColourPreset(-1);
	}
}

void GameView::NotifyColourPresetsChanged(GameModel * sender)
{
	for (auto *button : colourPresets)
	{
		RemoveComponent(button);
		delete button;
	}
	colourPresets.clear();

	int currentX = 5;
	std::vector<ui::Colour> colours = sender->GetColourPresets();
	int i = 0;
	for(std::vector<ui::Colour>::iterator iter = colours.begin(), end = colours.end(); iter != end; ++iter)
	{
		ToolButton * tempButton = new ToolButton(ui::Point(currentX, YRES+1), ui::Point(30, 18), "", "", "Decoration Presets.");
		tempButton->Appearance.BackgroundInactive = *iter;
		tempButton->SetActionCallback({ [this, i, tempButton] {
			c->SetActiveColourPreset(i);
			c->SetColour(tempButton->Appearance.BackgroundInactive);
		} });

		currentX += 31;

		if(sender->GetColourSelectorVisibility())
			AddComponent(tempButton);
		colourPresets.push_back(tempButton);

		i++;
	}
	NotifyColourActivePresetChanged(sender);
}

void GameView::NotifyColourActivePresetChanged(GameModel * sender)
{
	for (size_t i = 0; i < colourPresets.size(); i++)
	{
		if (sender->GetActiveColourPreset() == i)
		{
			colourPresets[i]->SetSelectionState(0);	//Primary
		}
		else
		{
			colourPresets[i]->SetSelectionState(-1);
		}
	}
}

void GameView::NotifyColourSelectorColourChanged(GameModel * sender)
{
	colourPicker->Appearance.BackgroundInactive = sender->GetColourSelectorColour();
	colourPicker->Appearance.BackgroundHover = sender->GetColourSelectorColour();
	NotifyActiveMenuToolListChanged(sender);
}

void GameView::NotifyRendererChanged(GameModel * sender)
{
	ren = sender->GetRenderer();
	rendererFrame = &ren->GetVideo();
	rendererSettings = &sender->GetRendererSettings();
}

void GameView::NotifySimulationChanged(GameModel * sender)
{
	sim = sender->GetSimulation();
}
void GameView::NotifyUserChanged(GameModel * sender)
{
	auto user = sender->GetUser();
	if (!user)
	{
		loginButton->SetText("[sign in]");
		loginButton->SetShowSplit(false);
		loginButton->SetRightToolTip("Sign in to simulation server");
	}
	else
	{
		loginButton->SetText(user->Username.FromUtf8());
		loginButton->SetShowSplit(true);
		loginButton->SetRightToolTip("Edit profile");
	}
	// saveSimulationButtonEnabled = sender->GetUser().ID;
	saveSimulationButtonEnabled = true;
	NotifySaveChanged(sender);
}


void GameView::NotifyPausedChanged(GameModel * sender)
{
	pauseButton->SetToggleState(sender->GetPaused());
	ApplySimFpsLimit();
}

void GameView::NotifyToolTipChanged(GameModel * sender)
{
	toolTip = sender->GetToolTip();
}

void GameView::NotifyInfoTipChanged(GameModel * sender)
{
	infoTip = sender->GetInfoTip();
	infoTipPresence = 120;
}

void GameView::ResetVoteButtons()
{
	upVoteButton->SetToolTip("Like this save");
	downVoteButton->SetToolTip("Dislike this save");
	upVoteButton->Appearance.BackgroundPulse = false;
	downVoteButton->Appearance.BackgroundPulse = false;
}

void GameView::NotifySaveChanged(GameModel * sender)
{
	saveReuploadAllowed = true;
	ResetVoteButtons();
	if (sender->GetSave())
	{
		if (introText > 50)
			introText = 50;

		auto user = sender->GetUser();
		saveSimulationButton->SetText(sender->GetSave()->GetName());
		if (user && sender->GetSave()->GetUserName() == user->Username)
			saveSimulationButton->SetShowSplit(true);
		else
			saveSimulationButton->SetShowSplit(false);
		reloadButton->Enabled = true;
		upVoteButton->Enabled = sender->GetSave()->GetID() && user && user->Username != sender->GetSave()->GetUserName();

		auto upVoteButtonColor = [this](bool active) {
			if(active)
			{
				upVoteButton->Appearance.BackgroundHover = (ui::Colour(20, 128, 30, 255));
				upVoteButton->Appearance.BackgroundInactive = (ui::Colour(0, 108, 10, 255));
				upVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 108, 10, 255));
			}
			else
			{
				upVoteButton->Appearance.BackgroundHover = (ui::Colour(20, 20, 20));
				upVoteButton->Appearance.BackgroundInactive = (ui::Colour(0, 0, 0));
				upVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
			}
		};
		auto upvoted = sender->GetSave()->GetID() && user && sender->GetSave()->GetVote() == 1;
		upVoteButtonColor(upvoted);

		downVoteButton->Enabled = upVoteButton->Enabled;
		auto downVoteButtonColor = [this](bool active) {
			if (active)
			{
				downVoteButton->Appearance.BackgroundHover = (ui::Colour(128, 20, 30, 255));
				downVoteButton->Appearance.BackgroundInactive = (ui::Colour(108, 0, 10, 255));
				downVoteButton->Appearance.BackgroundDisabled = (ui::Colour(108, 0, 10, 255));
			}
			else
			{
				downVoteButton->Appearance.BackgroundHover = (ui::Colour(20, 20, 20));
				downVoteButton->Appearance.BackgroundInactive = (ui::Colour(0, 0, 0));
				downVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
			}
		};
		auto downvoted = sender->GetSave()->GetID() && user && sender->GetSave()->GetVote() == -1;
		downVoteButtonColor(downvoted);

		if (user)
		{
			upVoteButton->Appearance.BorderDisabled = upVoteButton->Appearance.BorderInactive;
			downVoteButton->Appearance.BorderDisabled = downVoteButton->Appearance.BorderInactive;
		}
		else
		{
			upVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100);
			downVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100);
		}

		upVoteButton->SetActionCallback({ [this, upVoteButtonColor, upvoted] {
			upVoteButtonColor(true);
			upVoteButton->SetToolTip("Saving vote...");
			upVoteButton->Appearance.BackgroundPulse = true;
			c->Vote(upvoted ? 0 : 1);
		} });
		downVoteButton->SetActionCallback({ [this, downVoteButtonColor, downvoted] {
			downVoteButtonColor(true);
			downVoteButton->SetToolTip("Saving vote...");
			downVoteButton->Appearance.BackgroundPulse = true;
			c->Vote(downvoted ? 0 : -1);
		} });

		tagSimulationButton->Enabled = sender->GetSave()->GetID();
		if (sender->GetSave()->GetID())
		{
			StringBuilder tagsStream;
			std::list<ByteString> tags = sender->GetSave()->GetTags();
			if (tags.size())
			{
				for (std::list<ByteString>::const_iterator iter = tags.begin(), begin = tags.begin(), end = tags.end(); iter != end; iter++)
				{
					if (iter != begin)
						tagsStream << " ";
					tagsStream << iter->FromUtf8();
				}
				tagSimulationButton->SetText(tagsStream.Build());
			}
			else
			{
				tagSimulationButton->SetText("[no tags set]");
			}
		}
		else
		{
			tagSimulationButton->SetText("[no tags set]");
		}
		currentSaveType = 1;
		int saveID = sender->GetSave()->GetID();
		if (saveID == 404 || saveID == 2157797)
			saveReuploadAllowed = false;
	}
	else if (sender->GetSaveFile())
	{
		if (ctrlBehaviour)
			saveSimulationButton->SetShowSplit(true);
		else
			saveSimulationButton->SetShowSplit(false);
		saveSimulationButton->SetText(sender->GetSaveFile()->GetDisplayName());
		reloadButton->Enabled = true;
		upVoteButton->Enabled = false;
		upVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
		upVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100);
		downVoteButton->Enabled = false;
		downVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
		downVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100);
		tagSimulationButton->Enabled = false;
		tagSimulationButton->SetText("[no tags set]");
		currentSaveType = 2;
	}
	else
	{
		saveSimulationButton->SetShowSplit(false);
		saveSimulationButton->SetText("[untitled simulation]");
		reloadButton->Enabled = false;
		upVoteButton->Enabled = false;
		upVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
		upVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100),
		downVoteButton->Enabled = false;
		downVoteButton->Appearance.BackgroundDisabled = (ui::Colour(0, 0, 0));
		downVoteButton->Appearance.BorderDisabled = ui::Colour(100, 100, 100),
		tagSimulationButton->Enabled = false;
		tagSimulationButton->SetText("[no tags set]");
		currentSaveType = 0;
	}
	saveSimulationButton->Enabled = (saveSimulationButtonEnabled && saveReuploadAllowed) || ctrlBehaviour;
	SetSaveButtonTooltips();
}

void GameView::NotifyBrushChanged(GameModel * sender)
{
	activeBrush = &sender->GetBrush();
}

ByteString GameView::TakeScreenshot(int captureUI, int fileType)
{
	std::unique_ptr<VideoBuffer> screenshot;
	if (captureUI)
	{
		screenshot = std::make_unique<VideoBuffer>(ui::Engine::Ref().g->DumpFrame());
	}
	else
	{
		screenshot = std::make_unique<VideoBuffer>(rendererFrame->data(), RES, WINDOW.X);
	}

	ByteString filename;
	{
		// Optional suffix to distinguish screenshots taken at the exact same time
		ByteString suffix = "";
		time_t screenshotTime = time(nullptr);
		if (screenshotTime == lastScreenshotTime)
		{
			screenshotIndex++;
			suffix = ByteString::Build(" (", screenshotIndex, ")");
		}
		else
		{
			screenshotIndex = 1;
		}
		lastScreenshotTime = screenshotTime;
		std::string date = format::UnixtimeToDate(screenshotTime, "%Y-%m-%d %H.%M.%S");
		filename = ByteString::Build("screenshot ", date, suffix);
	}

	if (fileType == 1)
	{
		filename += ".bmp";
		// We should be able to simply use SDL_PIXELFORMAT_XRGB8888 here with a bit depth of 32 to convert RGBA data to RGB data,
		// and save the resulting surface directly. However, ubuntu-18.04 ships SDL2 so old that it doesn't have
		// SDL_PIXELFORMAT_XRGB8888, so we first create an RGBA surface and then convert it.
		auto *rgbaSurface = SDL_CreateRGBSurfaceWithFormatFrom(screenshot->Data(), screenshot->Size().X, screenshot->Size().Y, 32, screenshot->Size().X * sizeof(pixel), SDL_PIXELFORMAT_ARGB8888);
		auto *rgbSurface = SDL_ConvertSurfaceFormat(rgbaSurface, SDL_PIXELFORMAT_RGB888, 0);
		if (!rgbSurface || SDL_SaveBMP(rgbSurface, filename.c_str()))
		{
			std::cerr << "SDL_SaveBMP failed: " << SDL_GetError() << std::endl;
			filename = "";
		}
		SDL_FreeSurface(rgbSurface);
		SDL_FreeSurface(rgbaSurface);
	}
	else if (fileType == 2)
	{
		filename += ".ppm";
		if (!Platform::WriteFile(screenshot->ToPPM(), filename))
		{
			filename = "";
		}
	}
	else
	{
		filename += ".png";
		if (auto data = screenshot->ToPNG())
		{
			if (!Platform::WriteFile(*data, filename))
				filename = "";
		}
		else
			filename = "";
	}

	return filename;
}

int GameView::Record(bool record)
{
	if (!record)
	{
		recording = false;
		recordingFolder = 0;
	}
	else if (!recording)
	{
		time_t startTime = time(nullptr);
		recordingFolder = startTime;
		Platform::MakeDirectory("recordings");
		Platform::MakeDirectory(ByteString::Build("recordings", PATH_SEP_CHAR, recordingFolder));
		recording = true;
		recordingIndex = 0;
	}
	return recordingFolder;
}

void GameView::updateToolButtonScroll()
{
	if (toolButtons.size())
	{
		int x = currentMouse.X;
		int y = currentMouse.Y;

		int offsetDelta = 0;

		int newInitialX = WINDOWW - 56;
		int totalWidth = (toolButtons[0]->Size.X + 1) * toolButtons.size();
		int scrollSize = (int)(((float)(XRES - BARSIZE))/((float)totalWidth) * ((float)XRES - BARSIZE));

		if (scrollSize > XRES - 1)
			scrollSize = XRES - 1;
		
		if (totalWidth > XRES - 15)
		{			
			int mouseX = x;

			float overflow = 0;
			float mouseLocation = 0;

			if (mouseX > XRES)
				mouseX = XRES;

			// if (mouseX < 15) // makes scrolling a little nicer at edges but apparently if you put hundreds of elements in a menu it makes the end not show ...
			// 	mouseX = 15;

			scrollBar->Visible = true;

			scrollBar->Position.X = (int)(((float)mouseX / (float)XRES) * (float)(XRES - scrollSize)) + 1;

			overflow = (float)(totalWidth - (XRES - BARSIZE));
			mouseLocation = (float)(XRES - 3)/(float)((XRES - 2) - mouseX); // mouseLocation adjusted slightly in case you have 200 elements in one menu

			newInitialX += (int)(overflow/mouseLocation);
		}
		else
		{
			scrollBar->Visible = false;
		}

		scrollBar->Size.X = scrollSize - 1;

		offsetDelta = toolButtons[0]->Position.X - newInitialX;

		for (auto *button : toolButtons)
		{
			button->Position.X -= offsetDelta;
		}

		// Ensure that mouseLeave events are make their way to the buttons should they move from underneath the mouse pointer
		if (toolButtons[0]->Position.Y < y && toolButtons[0]->Position.Y + toolButtons[0]->Size.Y > y)
		{
			for (auto *button : toolButtons)
			{
				auto inside = button->Position.X < x && button->Position.X + button->Size.X > x;
				if (inside && !button->MouseInside)
				{
					button->MouseInside = true;
					button->OnMouseEnter(x, y);
				}
				if (!inside && button->MouseInside)
				{
					button->MouseInside = false;
					button->OnMouseLeave(x, y);
				}
			}
		}
	}
}

// Hit-tests the zoom window's decorative frame (the few pixels around its
// magnified content, drawn by Graphics::RenderZoom but never previously
// claimed by any interaction) so it can be dragged/resized like a normal
// window without touching a single pixel of the interior, which stays
// exactly as before: MouseInZoom/AdjustZoomCoords draw precisely into the
// magnified view.
GameView::ZoomFrameHit GameView::HitTestZoomWindowFrame(ui::Point mouse) const
{
	if (!zoomEnabled || !zoomCursorFixed)
		return ZoomFrameHit::None; // only draggable once placed -- while still following the cursor, dragging makes no sense
	ui::Point pos = c->GetZoomWindowPosition();
	ui::Point size = c->GetZoomWindowSize();
	// The visible decorative border is only a couple px, but the grabbable
	// zone needs to be much more forgiving than that or it's practically
	// impossible to actually land a click on it -- straddles the border
	// (frameMargin px outside AND frameMargin px inside it) rather than
	// only the outside, so there's a real target to aim for either way.
	constexpr int frameMargin = 10;
	constexpr int cornerSize = 16;
	ui::Point outerTL = pos - ui::Point(frameMargin, frameMargin);
	ui::Point outerBR = pos + size + ui::Point(frameMargin, frameMargin);
	if (mouse.X < outerTL.X || mouse.Y < outerTL.Y || mouse.X >= outerBR.X || mouse.Y >= outerBR.Y)
		return ZoomFrameHit::None;
	ui::Point innerTL = pos + ui::Point(frameMargin, frameMargin);
	ui::Point innerBR = pos + size - ui::Point(frameMargin, frameMargin);
	bool trueInterior = mouse.X >= innerTL.X && mouse.Y >= innerTL.Y && mouse.X < innerBR.X && mouse.Y < innerBR.Y;
	if (trueInterior)
		return ZoomFrameHit::None;
	bool nearLeft = mouse.X < outerTL.X + cornerSize;
	bool nearRight = mouse.X >= outerBR.X - cornerSize;
	bool nearTop = mouse.Y < outerTL.Y + cornerSize;
	bool nearBottom = mouse.Y >= outerBR.Y - cornerSize;
	if (nearLeft && nearTop) return ZoomFrameHit::ResizeTL;
	if (nearRight && nearTop) return ZoomFrameHit::ResizeTR;
	if (nearLeft && nearBottom) return ZoomFrameHit::ResizeBL;
	if (nearRight && nearBottom) return ZoomFrameHit::ResizeBR;
	return ZoomFrameHit::Move;
}

void GameView::OnMouseMove(int x, int y, int dx, int dy)
{
	currentMouse = ui::Point(x, y);
	if (zoomWindowDragging)
	{
		ui::Point size = c->GetZoomWindowSize();
		ui::Point newPos = ui::Point(x, y) - zoomWindowDragOffset;
		newPos.X = std::clamp(newPos.X, 0, XRES - size.X);
		newPos.Y = std::clamp(newPos.Y, 0, YRES - size.Y);
		c->SetZoomWindowPosition(newPos);
		return;
	}
	if (zoomWindowResizing)
	{
		int maxSide = std::min(XRES, YRES);
		int rawSide = std::max(std::abs(x - zoomWindowResizeAnchor.X), std::abs(y - zoomWindowResizeAnchor.Y));
		int zoomSize = c->GetZoomSize();
		int newFactor = std::clamp((rawSide + zoomSize / 2) / zoomSize, 1, std::max(1, maxSide / zoomSize));
		int side = zoomSize * newFactor;
		ui::Point newPos(0, 0);
		newPos.X = (zoomWindowResizeAnchor.X <= x) ? zoomWindowResizeAnchor.X : zoomWindowResizeAnchor.X - side;
		newPos.Y = (zoomWindowResizeAnchor.Y <= y) ? zoomWindowResizeAnchor.Y : zoomWindowResizeAnchor.Y - side;
		newPos.X = std::clamp(newPos.X, 0, XRES - side);
		newPos.Y = std::clamp(newPos.Y, 0, YRES - side);
		c->SetZoomFactor(newFactor);
		c->SetZoomWindowPosition(newPos);
		return;
	}
	bool newMouseInZoom = c->MouseInZoom(ui::Point(x, y));
	mousePosition = c->PointTranslate(ui::Point(x, y));
	currentMouse = ui::Point(x, y);
	UpdateSubCategoryLadderHover(currentMouse);
	UpdateStateLadderHover(currentMouse);
	if (selectMode != SelectNone)
	{
		if (selectMode == PlaceSave)
			selectPoint1 = c->PointTranslate(ui::Point(x, y));
		if (selectPoint1.X != -1)
			selectPoint2 = c->PointTranslate(ui::Point(x, y));
	}
	else if (isMouseDown)
	{
		if (newMouseInZoom == mouseInZoom)
		{
			if (drawMode == DrawPoints)
			{
				currentPoint = mousePosition;
				c->DrawPoints(toolIndex, lastPoint, currentPoint, true);
				lastPoint = currentPoint;
				skipDraw = true;
			}
			else if (drawMode == DrawFill)
			{
				c->DrawFill(toolIndex, mousePosition);
				skipDraw = true;
			}
		}
		else if (drawMode == DrawPoints || drawMode == DrawFill)
		{
			isMouseDown = false;
			drawMode = DrawPoints;
			c->MouseUp(x, y, 0, GameController::mouseUpDrawEnd);
		}
	}
	mouseInZoom = newMouseInZoom;

	// set active menu (delayed)
	if (delayedActiveMenu != -1)
	{
		c->SetActiveMenu(delayedActiveMenu);
		delayedActiveMenu = -1;
	}

	updateToolButtonScroll();
}

void GameView::OnMouseDown(int x, int y, unsigned button)
{
	currentMouse = ui::Point(x, y);
	if (PointInSubCategoryLadder(currentMouse))
	{
		// The ladder can extend up over the sim viewport (Y < YRES), which
		// the check just below wouldn't otherwise exclude -- without this,
		// clicking a ladder entry also paints/erases in the sim underneath
		// it. The Button component itself still gets this same click
		// through the normal component dispatch and handles the actual
		// subcategory selection; this only blocks GameView's own
		// background sim-interaction path for that click.
		return;
	}
	if (PointInStateLadder(currentMouse))
	{
		// Same reasoning as the subcategory-ladder guard just above -- the
		// state ladder also extends up over the sim viewport.
		return;
	}
	if (PointInFavoritesWheel(currentMouse))
	{
		// Same reasoning again -- the favorites wheel is centered on the
		// cursor wherever that happens to be, so it's even more likely to
		// sit over the sim viewport than the anchored ladders above.
		return;
	}
	if (button == SDL_BUTTON_LEFT)
	{
		auto hit = HitTestZoomWindowFrame(currentMouse);
		if (hit == ZoomFrameHit::Move)
		{
			zoomWindowDragging = true;
			zoomWindowDragOffset = currentMouse - c->GetZoomWindowPosition();
			return;
		}
		if (hit != ZoomFrameHit::None)
		{
			zoomWindowResizing = true;
			ui::Point pos = c->GetZoomWindowPosition();
			ui::Point size = c->GetZoomWindowSize();
			// anchor = whichever corner is opposite the one under the mouse -- it stays put on screen while the dragged corner follows the mouse
			zoomWindowResizeAnchor.X = (hit == ZoomFrameHit::ResizeTL || hit == ZoomFrameHit::ResizeBL) ? pos.X + size.X : pos.X;
			zoomWindowResizeAnchor.Y = (hit == ZoomFrameHit::ResizeTL || hit == ZoomFrameHit::ResizeTR) ? pos.Y + size.Y : pos.Y;
			return;
		}
	}
	if (altBehaviour && !shiftBehaviour && !ctrlBehaviour)
		button = SDL_BUTTON_MIDDLE;
	if  (!(zoomEnabled && !zoomCursorFixed))
	{
		if (selectMode != SelectNone)
		{
			isMouseDown = true;
			if (button == SDL_BUTTON_LEFT && selectPoint1.X == -1)
			{
				selectPoint1 = c->PointTranslate(currentMouse);
				selectPoint2 = selectPoint1;
			}
			return;
		}
		if (currentMouse.X >= 0 && currentMouse.X < XRES && currentMouse.Y >= 0 && currentMouse.Y < YRES)
		{
			// update tool index, set new "last" tool so GameView can detect certain tools properly
			if (button == SDL_BUTTON_LEFT)
				toolIndex = 0;
			else if (button == SDL_BUTTON_RIGHT)
				toolIndex = 1;
			else if (button == SDL_BUTTON_MIDDLE)
				toolIndex = 2;
			else
				return;
			Tool *lastTool = c->GetActiveTool(toolIndex);
			c->SetLastTool(lastTool);
			decoBrush = lastTool->Identifier.BeginsWith("DEFAULT_DECOR_");

			UpdateDrawMode();

			isMouseDown = true;
			c->HistorySnapshot();
			if (drawMode == DrawRect || drawMode == DrawLine)
			{
				drawPoint1 = c->PointTranslate(currentMouse);
			}
			else if (drawMode == DrawPoints)
			{
				lastPoint = currentPoint = c->PointTranslate(currentMouse);
				c->DrawPoints(toolIndex, lastPoint, currentPoint, false);
			}
			else if (drawMode == DrawFill)
			{
				c->DrawFill(toolIndex, c->PointTranslate(currentMouse));
			}
		}
	}
}

Vec2<int> GameView::PlaceSavePos() const
{
	auto [ trQuoX, trRemX ] = floorDiv(placeSaveTranslate.X, CELL);
	auto [ trQuoY, trRemY ] = floorDiv(placeSaveTranslate.Y, CELL);
	auto usefulSize = placeSaveThumb->Size();
	if (trRemX) usefulSize.X -= CELL;
	if (trRemY) usefulSize.Y -= CELL;
	auto cursorCell = (usefulSize - Vec2{ CELL, CELL }) / 2 - Vec2{ trQuoX, trQuoY } * CELL; // stamp coordinates
	auto unaligned = selectPoint2 - cursorCell;
	auto quoX = floorDiv(unaligned.X, CELL).first;
	auto quoY = floorDiv(unaligned.Y, CELL).first;
	return { quoX, quoY };
}

void GameView::OnMouseUp(int x, int y, unsigned button)
{
	currentMouse = ui::Point(x, y);
	if (zoomWindowDragging || zoomWindowResizing)
	{
		zoomWindowDragging = false;
		zoomWindowResizing = false;
		c->CommitZoomWindowPlacement();
		return;
	}
	if (zoomEnabled && !zoomCursorFixed)
	{
		zoomCursorFixed = true;
		c->SetZoomWindowVisible(true);
		drawMode = DrawPoints;
		isMouseDown = false;
	}
	else if (isMouseDown)
	{
		isMouseDown = false;
		if (selectMode != SelectNone)
		{
			if (button == SDL_BUTTON_LEFT && selectPoint1.X != -1 && selectPoint1.Y != -1 && selectPoint2.X != -1 && selectPoint2.Y != -1)
			{
				if (selectMode == PlaceSave)
				{
					if (placeSaveThumb && y <= WINDOWH-BARSIZE)
					{
						c->PlaceSave(PlaceSavePos());
					}
				}
				else
				{
					int x2 = (selectPoint1.X>selectPoint2.X) ? selectPoint1.X : selectPoint2.X;
					int y2 = (selectPoint1.Y>selectPoint2.Y) ? selectPoint1.Y : selectPoint2.Y;
					int x1 = (selectPoint2.X<selectPoint1.X) ? selectPoint2.X : selectPoint1.X;
					int y1 = (selectPoint2.Y<selectPoint1.Y) ? selectPoint2.Y : selectPoint1.Y;
					if (selectMode ==SelectCopy)
						c->CopyRegion(ui::Point(x1, y1), ui::Point(x2, y2));
					else if (selectMode == SelectCut)
						c->CutRegion(ui::Point(x1, y1), ui::Point(x2, y2));
					else if (selectMode == SelectStamp)
						c->StampRegion(ui::Point(x1, y1), ui::Point(x2, y2));
				}
			}
			selectMode = SelectNone;
			return;
		}

		ui::Point finalDrawPoint2 = c->PointTranslate(currentMouse);
		if (drawMode == DrawRect || drawMode == DrawLine)
		{
			drawPoint2 = finalDrawPoint2;
			// drawPoint1 was already run through PointTranslate once, when the
			// drag started (OnMouseDown) -- translating it again here was
			// feeding an already-real simulation coordinate back through the
			// zoom-window remap (GameModel::AdjustZoomCoords), which only
			// no-ops when that coordinate _doesn't_ also happen to fall inside
			// the on-screen zoom box. When it does (drawing inside the zoomed
			// area, which is exactly when precise placement matters most),
			// the anchor point silently got zoom-remapped a second time,
			// throwing the whole shape off. Same bug, and same fix, at every
			// other drawPoint1/initialDrawPoint use in this file.
			if (drawSnap && drawMode == DrawLine)
			{
				finalDrawPoint2 = lineSnapCoords(drawPoint1, drawPoint2);
			}
			if (drawSnap && drawMode == DrawRect)
			{
				finalDrawPoint2 = rectSnapCoords(drawPoint1, drawPoint2);
			}

			if (drawMode == DrawRect)
			{
				ui::Point corner1(0, 0), corner2(0, 0);
				ComputeAnchoredRect(drawPoint1, finalDrawPoint2, centerAnchorBehaviour, corner1, corner2);
				c->DrawRect(toolIndex, corner1, corner2);
			}
			if (drawMode == DrawLine)
			{
				c->DrawLine(toolIndex, drawPoint1, finalDrawPoint2);
			}
		}
		else if (drawMode == DrawPoints)
		{
			// draw final line
			c->DrawPoints(toolIndex, lastPoint, finalDrawPoint2, true);
			// plop tool stuff (like STKM)
			c->ToolClick(toolIndex, finalDrawPoint2);
		}
		else if (drawMode == DrawFill)
		{
			c->DrawFill(toolIndex, finalDrawPoint2);
		}
	}
	// this shouldn't happen, but do this just in case
	else if (selectMode != SelectNone && button != SDL_BUTTON_LEFT)
		selectMode = SelectNone;

	// update the drawing mode for the next line
	// since ctrl/shift state may have changed since we started drawing
	UpdateDrawMode();
}

void GameView::ToolTip(ui::Point senderPosition, String toolTip)
{
	// buttom button tooltips
	if (senderPosition.Y > Size.Y-17)
	{
		if (selectMode == PlaceSave || selectMode == SelectNone)
		{
			buttonTip = toolTip;
			isButtonTipFadingIn = true;
		}
	}
	// quickoption and menu tooltips
	else if(senderPosition.X > Size.X-BARSIZE)// < Size.Y-(quickOptionButtons.size()+1)*16)
	{
		this->toolTip = toolTip;
		toolTipPosition = ui::Point(Size.X-27-(Graphics::TextSize(toolTip).X - 1), senderPosition.Y+3);
		if(toolTipPosition.Y+10 > Size.Y-MENUSIZE)
			toolTipPosition = ui::Point(Size.X-27-(Graphics::TextSize(toolTip).X - 1), Size.Y-MENUSIZE-10);
		isToolTipFadingIn = true;
	}
	// element tooltips
	else
	{
		this->toolTip = toolTip;
		toolTipPosition = ui::Point(Size.X-27-(Graphics::TextSize(toolTip).X - 1), Size.Y-MENUSIZE-10);
		isToolTipFadingIn = true;
	}
}

void GameView::OnMouseWheel(int x, int y, int d)
{
	if (!d)
		return;
	if (selectMode != SelectNone)
	{
		return;
	}
	if (zoomEnabled && !zoomCursorFixed)
	{
		c->AdjustZoomSize(d);
	}
	else
	{
		// Flat +/-1 per notch by default, regardless of current brush size --
		// fine control has to stay available even when the brush is already
		// big, or there's no way to nudge a large brush by one pixel. Only
		// ramps up once you've been scrolling continuously for a while
		// (rampStartStreak notches in a row with no pause), so a deliberate
		// scroll or two for precision work never gets sped up, but holding
		// the wheel down to cover a lot of ground doesn't take forever.
		// Wall-clock gap between notches, not sim ticks -- sim tick rate can
		// be capped or vary, and this needs to track real elapsed time.
		Uint32 now = SDL_GetTicks();
		constexpr Uint32 quickScrollMs = 200;
		constexpr int rampStartStreak = 12;
		if (now - lastScrollTime <= quickScrollMs)
			scrollStreak = std::min(scrollStreak + 1, 60);
		else
			scrollStreak = 0;
		lastScrollTime = now;
		int accel = scrollStreak > rampStartStreak ? 1 + (scrollStreak - rampStartStreak) / 4 : 1;

		c->AdjustBrushSize(d * accel, false, ctrlBehaviour, shiftBehaviour);
	}
}

void GameView::BeginStampSelection()
{
	selectMode = SelectStamp;
	selectPoint1 = selectPoint2 = ui::Point(-1, -1);
	isMouseDown = false;
	buttonTip = "\x0F\xEF\xEF\020Click-and-drag to specify an area to create a stamp (right click = cancel)";
	buttonTipShow = 120;
}

void GameView::OnKeyPress(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt)
{
	if (introText > 50)
	{
		introText = 50;
	}

	if (selectMode != SelectNone)
	{
		if (selectMode == PlaceSave)
		{
			switch (key)
			{
			case SDLK_RIGHT:
				TranslateSave({  1,  0 });
				return;
			case SDLK_LEFT:
				TranslateSave({ -1,  0 });
				return;
			case SDLK_UP:
				TranslateSave({  0, -1 });
				return;
			case SDLK_DOWN:
				TranslateSave({  0,  1 });
				return;
			}
			if (scan == SDL_SCANCODE_R && !repeat)
			{
				if (ctrl && shift)
				{
					//Vertical flip
					TransformSave(Mat2<int>::MirrorY);
				}
				else if (!ctrl && shift)
				{
					//Horizontal flip
					TransformSave(Mat2<int>::MirrorX);
				}
				else
				{
					//Rotate 90deg
					TransformSave(Mat2<int>::CCW);
				}
				return;
			}
		}
	}

	if (repeat)
		return;
	bool didKeyShortcut = true;
	switch(scan)
	{
	case SDL_SCANCODE_GRAVE:
		c->ShowConsole();
		break;
	case SDL_SCANCODE_SPACE: //Space
		c->SetPaused();
		break;
	case SDL_SCANCODE_Z:
		if (selectMode != SelectNone && isMouseDown)
			break;
		if (ctrl && !isMouseDown)
		{
			if (shift)
				c->HistoryForward();
			else
				c->HistoryRestore();
		}
		else
		{
			isMouseDown = false;
			zoomCursorFixed = false;
			c->SetZoomEnabled(true);
			// Don't show the (possibly huge, if previously resized) window
			// tracking the cursor around the screen before it's placed --
			// wait for the click below to fix it in place.
			c->SetZoomWindowVisible(false);
		}
		break;
	case SDL_SCANCODE_T:
		// Toggle, not hold-to-show -- press once to open, press again (or
		// pick something, which already closes it) to close. Release no
		// longer does anything (see OnKeyRelease).
		if (!repeat)
		{
			if (favoritesWheelVisible)
				CloseFavoritesWheel();
			else
				OpenFavoritesWheel(currentMouse);
		}
		break;
	case SDL_SCANCODE_M:
		centerAnchorBehaviour = true;
		break;
	case SDL_SCANCODE_P:
	case SDL_SCANCODE_F2:
		if (ctrl)
		{
			if (shift)
				c->SetActiveTool(1, "DEFAULT_UI_PROPERTY");
			else
				c->SetActiveTool(0, "DEFAULT_UI_PROPERTY");
		}
		else
			doScreenshot = true;
		break;
	case SDL_SCANCODE_F3:
		SetDebugHUD(!GetDebugHUD());
		break;
	case SDL_SCANCODE_F5:
		c->ReloadSim();
		break;
	case SDL_SCANCODE_R:
		if (ctrl)
			c->ReloadSim();
		else if (shift)
			c->AdjustBrushRotation(-1);
		else
			c->AdjustBrushRotation(1);
		break;
	case SDL_SCANCODE_E:
		if (ctrl)
			c->SetEdgeMode(c->GetEdgeMode() + 1);
		else
			c->OpenElementSearch();
		break;
	case SDL_SCANCODE_F:
		if (ctrl)
		{
			auto findingElementCandidate = FindingElementCandidate();
			if (rendererSettings->findingElement == findingElementCandidate)
			{
				rendererSettings->findingElement = std::nullopt;
			}
			else
			{
				rendererSettings->findingElement = findingElementCandidate;
			}
		}
		else
			c->FrameStep();
		break;
	case SDL_SCANCODE_G:
		if (ctrl)
			c->ShowGravityGrid();
		else if(shift)
			c->AdjustGridSize(-1);
		else
			c->AdjustGridSize(1);
		break;
	case SDL_SCANCODE_F1:
		if(!introText)
			introText = 8047;
		else
			introText = 0;
		break;
	case SDL_SCANCODE_F11:
		ui::Engine::Ref().SetFullscreen(!ui::Engine::Ref().GetFullscreen());
		break;
	case SDL_SCANCODE_H:
		if(ctrl)
		{
			if(!introText)
				introText = 8047;
			else
				introText = 0;
		}
		else
			showHud = !showHud;
		break;
	case SDL_SCANCODE_B:
		if(ctrl)
			c->SetDecoration();
		else
			if (colourPicker->GetParentWindow())
				c->SetActiveMenu(lastMenu);
			else
			{
				c->SetDecoration(true);
				c->SetPaused(true);
				c->SetActiveMenu(SC_DECO);
			}
		break;
	case SDL_SCANCODE_Y:
		if (ctrl)
		{
			c->HistoryForward();
		}
		else
		{
			c->SwitchAir();
		}
		break;
	case SDL_SCANCODE_ESCAPE:
	case SDL_SCANCODE_Q:
		if (ALLOW_QUIT)
		{
			ui::Engine::Ref().ConfirmExit();
		}
		break;
	case SDL_SCANCODE_U:
		if (ctrl)
			c->ResetAHeat();
		else
			c->ToggleAHeat();
		break;
	case SDL_SCANCODE_N:
		c->ToggleNewtonianGravity();
		break;
	case SDL_SCANCODE_EQUALS:
		if(ctrl)
			c->ResetSpark();
		else
			c->ResetAir();
		break;
	case SDL_SCANCODE_C:
		if(ctrl)
		{
			selectMode = SelectCopy;
			selectPoint1 = selectPoint2 = ui::Point(-1, -1);
			isMouseDown = false;
			buttonTip = "\x0F\xEF\xEF\020Click-and-drag to specify an area to copy (right click = cancel)";
			buttonTipShow = 120;
		}
		break;
	case SDL_SCANCODE_X:
		if(ctrl)
		{
			selectMode = SelectCut;
			selectPoint1 = selectPoint2 = ui::Point(-1, -1);
			isMouseDown = false;
			buttonTip = "\x0F\xEF\xEF\020Click-and-drag to specify an area to copy then cut (right click = cancel)";
			buttonTipShow = 120;
		}
		break;
	case SDL_SCANCODE_V:
		if (ctrl)
		{
			if (c->LoadClipboard())
			{
				selectPoint1 = selectPoint2 = mousePosition;
				isMouseDown = false;
			}
		}
		break;
	case SDL_SCANCODE_L:
	{
		auto &stampIDs = Client::Ref().GetStamps();
		if (stampIDs.size())
		{
			auto saveFile = Client::Ref().GetStamp(stampIDs[0]);
			if (!saveFile || !saveFile->GetGameSave())
				break;
			c->LoadStamp(saveFile->TakeGameSave());
			selectPoint1 = selectPoint2 = mousePosition;
			isMouseDown = false;
			break;
		}
	}
	case SDL_SCANCODE_K:
		selectMode = SelectNone;
		selectPoint1 = selectPoint2 = ui::Point(-1, -1);
		c->OpenStamps();
		break;
	case SDL_SCANCODE_RIGHTBRACKET:
		if(zoomEnabled && !zoomCursorFixed)
			c->AdjustZoomSize(1, !alt);
		else
			c->AdjustBrushSize(1, !alt, ctrlBehaviour, shiftBehaviour);
		break;
	case SDL_SCANCODE_LEFTBRACKET:
		if(zoomEnabled && !zoomCursorFixed)
			c->AdjustZoomSize(-1, !alt);
		else
			c->AdjustBrushSize(-1, !alt, ctrlBehaviour, shiftBehaviour);
		break;
	case SDL_SCANCODE_I:
		if(ctrl)
			c->Install();
		else
			c->InvertAirSim();
		break;
	case SDL_SCANCODE_SEMICOLON:
		if (ctrl)
			c->SetReplaceModeFlags(c->GetReplaceModeFlags()^SPECIFIC_DELETE);
		else
			c->SetReplaceModeFlags(c->GetReplaceModeFlags()^REPLACE_MODE);
		break;
	default:
		didKeyShortcut = false;
	}
	if (!didKeyShortcut)
	{
		switch (key)
		{
		case SDLK_AC_BACK:
			if (ALLOW_QUIT)
			{
				ui::Engine::Ref().ConfirmExit();
			}
			break;
		case SDLK_TAB: //Tab
			c->ChangeBrush();
			break;
		case SDLK_INSERT:
			if (ctrl)
				c->SetReplaceModeFlags(c->GetReplaceModeFlags()^SPECIFIC_DELETE);
			else
				c->SetReplaceModeFlags(c->GetReplaceModeFlags()^REPLACE_MODE);
			break;
		case SDLK_DELETE:
			c->SetReplaceModeFlags(c->GetReplaceModeFlags()^SPECIFIC_DELETE);
			break;
		}
	}

	if (shift && showDebug && key == '1')
	{
		c->LoadRenderPreset(10);
	}
	else if (shift && key == '6')
	{
		c->LoadRenderPreset(11);
	}
	else if (shift && key == '0')
	{
		c->LoadRenderPreset(12);
	}
	else if (shift && key == '7')
	{
		c->LoadRenderPreset(13);
	}
	else if (key >= '0' && key <= '9')
	{
		c->LoadRenderPreset(key-'0');
	}
}

void GameView::OnKeyRelease(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt)
{
	if (repeat)
		return;
	if (scan == SDL_SCANCODE_Z)
	{
		if (!zoomCursorFixed && !alt)
			c->SetZoomEnabled(false);
		return;
	}
	if (scan == SDL_SCANCODE_M)
	{
		centerAnchorBehaviour = false;
		return;
	}
}

void GameView::OnBlur()
{
	disableAltBehaviour();
	disableCtrlBehaviour();
	disableShiftBehaviour();
	isMouseDown = false;
	drawMode = DrawPoints;
	c->Blur();
}

void GameView::OnFileDrop(ByteString filename)
{
	if (!(filename.EndsWith(".cps") || filename.EndsWith(".stm")))
	{
		new ErrorMessage("Error loading save", "Dropped file is not a TPT save file (.cps or .stm format)");
		return;
	}


	if (filename.EndsWith(".stm"))
	{
		auto saveFile = Client::Ref().GetStamp(filename);
		if (!saveFile || !saveFile->GetGameSave())
		{
			new ErrorMessage("Error loading stamp", "Dropped stamp could not be loaded: " + saveFile->GetError());
			return;
		}
		c->LoadStamp(saveFile->TakeGameSave());
	}
	else
	{
		auto saveFile = Client::Ref().LoadSaveFile(filename);
		if (!saveFile)
			return;
		if (saveFile->GetError().length())
		{
			new ErrorMessage("Error loading save", "Dropped save file could not be loaded: " + saveFile->GetError());
			return;
		}
		c->LoadSaveFile(std::move(saveFile));
	}

	// hide the info text if it's not already hidden
	SkipIntroText();
}

void GameView::SkipIntroText()
{
	introText = 0;
}

void GameView::OnTick()
{
	// Re-check hover every tick, not just on mouse movement -- a mouse that
	// is stationary over the ladder/button never fires OnMouseMove, so
	// without this the hide countdown (started by the last real movement)
	// kept expiring under a perfectly still pointer.
	UpdateSubCategoryLadderHover(currentMouse);
	DecaySubCategoryLadderHover();
	UpdateStateLadderHover(currentMouse);
	DecayStateLadderHover();
	if (selectMode == PlaceSave && !placeSaveThumb)
		selectMode = SelectNone;
	if (zoomEnabled && !zoomCursorFixed)
		c->SetZoomPosition(currentMouse);

	if (skipDraw)
	{
		skipDraw = false;
	}
	else if (selectMode == SelectNone && isMouseDown)
	{
		if (drawMode == DrawPoints)
		{
			c->DrawPoints(toolIndex, lastPoint, currentPoint, true);
			lastPoint = currentPoint;
		}
		else if (drawMode == DrawFill)
		{
			c->DrawFill(toolIndex, c->PointTranslate(currentMouse));
		}
		else if (drawMode == DrawLine)
		{
			ui::Point drawPoint2 = currentMouse;
			if (altBehaviour)
				drawPoint2 = lineSnapCoords(drawPoint1, currentMouse);
			c->ToolDrag(toolIndex, drawPoint1, c->PointTranslate(drawPoint2));
		}
	}

	int foundSignID = c->GetSignAt(mousePosition.X, mousePosition.Y);
	if (foundSignID != -1)
	{
		String str = c->GetSignText(foundSignID);
		auto si = c->GetSignSplit(foundSignID);

		StringBuilder tooltip;
		switch (si.second)
		{
		case sign::Type::Save:
			tooltip << "Go to save ID:" << str.Substr(3, si.first - 3);
			break;
		case sign::Type::Thread:
			tooltip << "Open forum thread " << str.Substr(3, si.first - 3) << " in browser";
			break;
		case sign::Type::Search:
			tooltip << "Search for " << str.Substr(3, si.first - 3);
			break;
		default: break;
		}

		if (tooltip.Size())
		{
			ToolTip(ui::Point(0, Size.Y), tooltip.Build());
		}
	}

	if (isButtonTipFadingIn || (selectMode != PlaceSave && selectMode != SelectNone))
	{
		isButtonTipFadingIn = false;
		buttonTipShow.SetTarget(120);
	}
	else
	{
		buttonTipShow.SetTarget(0);
	}
	if (isToolTipFadingIn)
	{
		isToolTipFadingIn = false;
		toolTipPresence.SetTarget(120);
	}
	else
	{
		toolTipPresence.SetTarget(0);
	}
}

void GameView::OnSimTick()
{
	c->Update();
	wantFrame = true;
}

void GameView::DoMouseMove(int x, int y, int dx, int dy)
{
	if(c->MouseMove(x, y, dx, dy))
		Window::DoMouseMove(x, y, dx, dy);
}

void GameView::DoMouseDown(int x, int y, unsigned button)
{
	if(introText > 50)
		introText = 50;
	if(c->MouseDown(x, y, button))
		Window::DoMouseDown(x, y, button);
}

void GameView::DoMouseUp(int x, int y, unsigned button)
{
	if(c->MouseUp(x, y, button, GameController::mouseUpNormal))
		Window::DoMouseUp(x, y, button);
}

void GameView::DoMouseWheel(int x, int y, int d)
{
	if(c->MouseWheel(x, y, d))
		Window::DoMouseWheel(x, y, d);
}

void GameView::DoTextInput(String text)
{
	if (c->TextInput(text))
		Window::DoTextInput(text);
}

void GameView::DoTextEditing(String text)
{
	if (c->TextEditing(text))
		Window::DoTextEditing(text);
}

void GameView::DoKeyPress(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt)
{
	if (shift && !shiftBehaviour)
		enableShiftBehaviour();
	if (ctrl && !ctrlBehaviour)
		enableCtrlBehaviour();
	if (alt && !altBehaviour)
		enableAltBehaviour();
	if (c->KeyPress(key, scan, repeat, shift, ctrl, alt))
		Window::DoKeyPress(key, scan, repeat, shift, ctrl, alt);
}

void GameView::DoKeyRelease(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt)
{
	if (!shift && shiftBehaviour)
		disableShiftBehaviour();
	if (!ctrl && ctrlBehaviour)
		disableCtrlBehaviour();
	if (!alt && altBehaviour)
		disableAltBehaviour();
	if (c->KeyRelease(key, scan, repeat, shift, ctrl, alt))
		Window::DoKeyRelease(key, scan, repeat, shift, ctrl, alt);
}

void GameView::DoExit()
{
	Window::DoExit();
	c->Exit();
}

void GameView::DoDraw()
{
	Window::DoDraw();
	constexpr std::array<int, 9> fadeout = { { // * Gamma-corrected.
		255, 195, 145, 103, 69, 42, 23, 10, 3
	} };
	auto *g = GetGraphics();
	for (auto x = 0; x < int(fadeout.size()); ++x)
	{
		g->BlendLine({ x, YRES + 1 }, { x, YRES + 18 }, 0x000000_rgb .WithAlpha(fadeout[x]));
		g->BlendLine({ XRES - x, YRES + 1 }, { XRES - x, YRES + 18 }, 0x000000_rgb .WithAlpha(fadeout[x]));
	}

	c->Tick();
	{
		auto rect = g->Size().OriginRect();
		g->SwapClipRect(rect);  // reset any nonsense cliprect Lua left configured
	}
}

void GameView::NotifyNotificationsChanged(GameModel * sender)
{
	for (auto *notificationComponent : notificationComponents)
	{
		RemoveComponent(notificationComponent);
		delete notificationComponent;
	}
	notificationComponents.clear();

	std::vector<Notification*> notifications = sender->GetNotifications();

	int currentY = YRES-23;
	for (auto *notification : notifications)
	{
		int width = Graphics::TextSize(notification->Message).X + 7;
		ui::Button * tempButton = new ui::Button(ui::Point(XRES-width-22, currentY), ui::Point(width, 15), notification->Message);
		tempButton->SetActionCallback({ [notification] {
			notification->Action();
		} });
		tempButton->Appearance.BorderInactive = style::Colour::WarningTitle;
		tempButton->Appearance.TextInactive = style::Colour::WarningTitle;
		tempButton->Appearance.BorderHover = ui::Colour(255, 175, 0);
		tempButton->Appearance.TextHover = ui::Colour(255, 175, 0);
		AddComponent(tempButton);
		notificationComponents.push_back(tempButton);

		tempButton = new ui::Button(ui::Point(XRES-20, currentY), ui::Point(15, 15), 0xE02A);
		//tempButton->SetIcon(IconClose);
		auto closeNotification = [this, notification] {
			c->RemoveNotification(notification);
		};
		tempButton->SetActionCallback({ closeNotification, closeNotification });
		tempButton->Appearance.Margin.Left -= 1;
		tempButton->Appearance.Margin.Top -= 1;
		tempButton->Appearance.BorderInactive = style::Colour::WarningTitle;
		tempButton->Appearance.TextInactive = style::Colour::WarningTitle;
		tempButton->Appearance.BorderHover = ui::Colour(255, 175, 0);
		tempButton->Appearance.TextHover = ui::Colour(255, 175, 0);
		AddComponent(tempButton);
		notificationComponents.push_back(tempButton);

		currentY -= 17;
	}
}

void GameView::NotifyZoomChanged(GameModel * sender)
{
	zoomEnabled = sender->GetZoomEnabled();
}

void GameView::NotifyLogChanged(GameModel * sender, String entry)
{
	logEntries.push_front(std::pair<String, int>(entry, 600));
	if (logEntries.size() > 20)
		logEntries.pop_back();
}

void GameView::NotifyPlaceSaveChanged(GameModel * sender)
{
	placeSaveTransform = Mat2<int>::Identity;
	placeSaveTranslate = Vec2<int>::Zero;
	ApplyTransformPlaceSave();
}

void GameView::TranslateSave(Vec2<int> addToTranslate)
{
	placeSaveTranslate += addToTranslate;
	ApplyTransformPlaceSave();
}

void GameView::TransformSave(Mat2<int> mulToTransform)
{
	placeSaveTranslate = Vec2<int>::Zero; // reset offset
	placeSaveTransform = mulToTransform * placeSaveTransform;
	ApplyTransformPlaceSave();
}

void GameView::ApplyTransformPlaceSave()
{
	auto remX = floorDiv(placeSaveTranslate.X, CELL).second;
	auto remY = floorDiv(placeSaveTranslate.Y, CELL).second;
	c->TransformPlaceSave(placeSaveTransform, { remX, remY });
}

void GameView::NotifyTransformedPlaceSaveChanged(GameModel *sender)
{
	if (sender->GetTransformedPlaceSave())
	{
		placeSaveThumb = SaveRenderer::Ref().Render(sender->GetTransformedPlaceSave(), true, sender->GetRendererSettings());
		selectMode = PlaceSave;
		selectPoint2 = mousePosition;
	}
	else
	{
		placeSaveThumb.reset();
		selectMode = SelectNone;
	}
}

void GameView::enableShiftBehaviour()
{
	if (!shiftBehaviour)
	{
		shiftBehaviour = true;
		if (!isMouseDown || selectMode != SelectNone)
			UpdateDrawMode();
		UpdateToolStrength();
	}
}

void GameView::disableShiftBehaviour()
{
	if (shiftBehaviour)
	{
		shiftBehaviour = false;
		if (!isMouseDown || selectMode != SelectNone)
			UpdateDrawMode();
		UpdateToolStrength();
	}
}

void GameView::enableAltBehaviour()
{
	if (!altBehaviour)
	{
		altBehaviour = true;
		drawSnap = true;
	}
}

void GameView::disableAltBehaviour()
{
	if (altBehaviour)
	{
		altBehaviour = false;
		drawSnap = false;
	}
}

void GameView::enableCtrlBehaviour()
{
	if (!ctrlBehaviour)
	{
		ctrlBehaviour = true;
		if (!isMouseDown || selectMode != SelectNone)
			UpdateDrawMode();
		UpdateToolStrength();

		//Show HDD save & load buttons
		saveSimulationButton->Appearance.BackgroundInactive = saveSimulationButton->Appearance.BackgroundHover = ui::Colour(255, 255, 255);
		saveSimulationButton->Appearance.TextInactive = saveSimulationButton->Appearance.TextHover = ui::Colour(0, 0, 0);

		saveSimulationButton->Enabled = true;
		SetSaveButtonTooltips();

		searchButton->Appearance.BackgroundInactive = searchButton->Appearance.BackgroundHover = ui::Colour(255, 255, 255);
		searchButton->Appearance.TextInactive = searchButton->Appearance.TextHover = ui::Colour(0, 0, 0);

		searchButton->SetToolTip("Open a simulation from your hard drive.");
		if (currentSaveType == 2)
			saveSimulationButton->SetShowSplit(true);
	}
}

void GameView::disableCtrlBehaviour()
{
	if (ctrlBehaviour)
	{
		ctrlBehaviour = false;
		if (!isMouseDown || selectMode != SelectNone)
			UpdateDrawMode();
		UpdateToolStrength();

		//Hide HDD save & load buttons
		saveSimulationButton->Appearance.BackgroundInactive = ui::Colour(0, 0, 0);
		saveSimulationButton->Appearance.BackgroundHover = ui::Colour(20, 20, 20);
		saveSimulationButton->Appearance.TextInactive = saveSimulationButton->Appearance.TextHover = ui::Colour(255, 255, 255);
		saveSimulationButton->Enabled = saveSimulationButtonEnabled && saveReuploadAllowed;
		SetSaveButtonTooltips();
		searchButton->Appearance.BackgroundInactive = ui::Colour(0, 0, 0);
		searchButton->Appearance.BackgroundHover = ui::Colour(20, 20, 20);
		searchButton->Appearance.TextInactive = searchButton->Appearance.TextHover = ui::Colour(255, 255, 255);
		searchButton->SetToolTip("Find & open a simulation. Hold Ctrl to load offline saves.");
		if (currentSaveType == 2)
			saveSimulationButton->SetShowSplit(false);
	}
}

void GameView::UpdateDrawMode()
{
	if (ctrlBehaviour && shiftBehaviour)
	{
		if (toolBrush)
			drawMode = DrawPoints;
		else
			drawMode = DrawFill;
	}
	else if (ctrlBehaviour)
		drawMode = DrawRect;
	else if (shiftBehaviour)
		drawMode = DrawLine;
	else
		drawMode = DrawPoints;
	// TODO: have tools decide on draw mode
	if (c->GetLastTool() && c->GetLastTool()->Identifier == "DEFAULT_UI_SAMPLE")
	{
		drawMode = DrawPoints;
	}
}

void GameView::UpdateToolStrength()
{
	if (shiftBehaviour)
		c->SetToolStrength(10.0f);
	else if (ctrlBehaviour)
		c->SetToolStrength(.1f);
	else
		c->SetToolStrength(1.0f);
}

void GameView::SetSaveButtonTooltips()
{
	if (!Client::Ref().GetAuthUser())
		saveSimulationButton->SetToolTips("Overwrite the open simulation on your hard drive.", "Save the simulation to your hard drive. Login to save online.");
	else if (ctrlBehaviour)
		saveSimulationButton->SetToolTips("Overwrite the open simulation on your hard drive.", "Save the simulation to your hard drive.");
	else if (saveSimulationButton->GetShowSplit())
		saveSimulationButton->SetToolTips("Re-upload the current simulation", "Modify simulation properties");
	else
		saveSimulationButton->SetToolTips("Re-upload the current simulation", "Upload a new simulation. Hold Ctrl to save offline.");
}

void GameView::RenderSimulation(const RenderableSimulation &sim, bool handleEvents)
{
	ren->sim = &sim;
	ren->Clear();
	ren->RenderBackground();
	if (handleEvents)
	{
		c->BeforeSimDraw();
	}
	{
		// we may write graphicscache here
		auto &sd = SimulationData::Ref();
		std::unique_lock lk(sd.elementGraphicsMx);
		ren->RenderSimulation();
	}
	ren->sim = nullptr;
}

void GameView::AfterSimDraw(const RenderableSimulation &sim)
{
	ren->sim = &sim;
	c->AfterSimDraw();
	ren->sim = nullptr;
}

void GameView::OnDraw()
{
	Graphics * g = GetGraphics();

	auto threadedRenderingAllowed = c->ThreadedRenderingAllowed();
	if (wantFrame)
	{
		wantFrame = false;
		if (threadedRenderingAllowed)
		{
			StartRendererThread();
			WaitForRendererThread();
			AfterSimDraw(*sim);
			rendererStats = ren->GetStats();
			*rendererThreadResult = ren->GetVideo();
			rendererFrame = rendererThreadResult.get();
			DispatchRendererThread();
		}
		else
		{
			PauseRendererThread();
			ren->ApplySettings(*rendererSettings);
			RenderSimulation(*sim, true);
			AfterSimDraw(*sim);
			rendererStats = ren->GetStats();
			rendererFrame = &ren->GetVideo();
		}
	}

	std::copy_n(rendererFrame->data(), rendererFrame->Size().X * rendererFrame->Size().Y, g->Data());

	if (showBrush && selectMode == SelectNone && (!zoomEnabled || zoomCursorFixed) && activeBrush && (isMouseDown || (currentMouse.X >= 0 && currentMouse.X < XRES && currentMouse.Y >= 0 && currentMouse.Y < YRES)))
	{
		ui::Point finalCurrentMouse = c->PointTranslate(currentMouse);
		ui::Point initialDrawPoint = drawPoint1;

		if (wallBrush)
		{
			finalCurrentMouse = c->NormaliseBlockCoord(finalCurrentMouse);
			initialDrawPoint = c->NormaliseBlockCoord(initialDrawPoint);
		}

		if (drawMode == DrawRect && isMouseDown)
		{
			if (drawSnap)
			{
				finalCurrentMouse = rectSnapCoords(initialDrawPoint, finalCurrentMouse);
			}
			if (wallBrush)
			{
				if (finalCurrentMouse.X > initialDrawPoint.X)
					finalCurrentMouse.X += CELL-1;
				else
					initialDrawPoint.X += CELL-1;

				if (finalCurrentMouse.Y > initialDrawPoint.Y)
					finalCurrentMouse.Y += CELL-1;
				else
					initialDrawPoint.Y += CELL-1;
			}
			ui::Point rectCorner1(0, 0), rectCorner2(0, 0);
			ComputeAnchoredRect(initialDrawPoint, finalCurrentMouse, centerAnchorBehaviour, rectCorner1, rectCorner2);
			activeBrush->RenderRect(g, rectCorner1, rectCorner2);
		}
		else if (drawMode == DrawLine && isMouseDown)
		{
			if (drawSnap)
			{
				finalCurrentMouse = lineSnapCoords(initialDrawPoint, finalCurrentMouse);
			}
			activeBrush->RenderLine(g, initialDrawPoint, finalCurrentMouse);
		}
		else if (drawMode == DrawFill)// || altBehaviour)
		{
			if (!decoBrush)
				activeBrush->RenderFill(g, finalCurrentMouse);
		}
		if (drawMode == DrawPoints || drawMode==DrawLine || (drawMode == DrawRect && !isMouseDown))
		{
			if (wallBrush)
			{
				ui::Point finalBrushRadius = c->NormaliseBlockCoord(activeBrush->GetRadius());
				auto topLeft     = finalCurrentMouse - finalBrushRadius;
				auto bottomRight = finalCurrentMouse + finalBrushRadius + Vec2{ CELL - 1, CELL - 1 };
				g->XorLine({     topLeft.X,     topLeft.Y     }, { bottomRight.X,     topLeft.Y     });
				g->XorLine({     topLeft.X, bottomRight.Y     }, { bottomRight.X, bottomRight.Y     });
				g->XorLine({     topLeft.X,     topLeft.Y + 1 }, {     topLeft.X, bottomRight.Y - 1 }); // offset by 1 so the corners don't get xor'd twice
				g->XorLine({ bottomRight.X,     topLeft.Y + 1 }, { bottomRight.X, bottomRight.Y - 1 }); // offset by 1 so the corners don't get xor'd twice
			}
			else
			{
				activeBrush->RenderPoint(g, finalCurrentMouse);
			}
		}
	}

	if(selectMode!=SelectNone)
	{
		if(selectMode==PlaceSave)
		{
			if(placeSaveThumb && selectPoint2.X!=-1)
			{
				auto rect = RectSized(PlaceSavePos() * CELL, placeSaveThumb->Size());
				g->BlendImage(placeSaveThumb->Data(), 0x80, rect);
				g->XorDottedRect(rect);
			}
		}
		else
		{
			if(selectPoint1.X==-1)
			{
				g->BlendFilledRect(RectSized(Vec2{ 0, 0 }, Vec2{ XRES, YRES }), 0x000000_rgb .WithAlpha(100));
			}
			else
			{
				int x2 = (selectPoint1.X>selectPoint2.X)?selectPoint1.X:selectPoint2.X;
				int y2 = (selectPoint1.Y>selectPoint2.Y)?selectPoint1.Y:selectPoint2.Y;
				int x1 = (selectPoint2.X<selectPoint1.X)?selectPoint2.X:selectPoint1.X;
				int y1 = (selectPoint2.Y<selectPoint1.Y)?selectPoint2.Y:selectPoint1.Y;

				if(x2>XRES-1)
					x2 = XRES-1;
				if(y2>YRES-1)
					y2 = YRES-1;

				g->BlendFilledRect(RectSized(Vec2{ 0, 0 }, Vec2{ XRES, y1 }), 0x000000_rgb .WithAlpha(100));
				g->BlendFilledRect(RectSized(Vec2{ 0, y2+1 }, Vec2{ XRES, YRES-y2-1 }), 0x000000_rgb .WithAlpha(100));

				g->BlendFilledRect(RectSized(Vec2{ 0, y1 }, Vec2{ x1, (y2-y1)+1 }), 0x000000_rgb .WithAlpha(100));
				g->BlendFilledRect(RectSized(Vec2{ x2+1, y1 }, Vec2{ XRES-x2-1, (y2-y1)+1 }), 0x000000_rgb .WithAlpha(100));

				g->XorDottedRect(RectBetween(Vec2{ x1, y1 }, Vec2{ x2, y2 }));
			}
		}
	}

	g->RenderZoom();

	// Diagnostic overlay for the zoom-window feature, which has repeatedly
	// been reported broken without anyone (including several fix attempts)
	// being able to see WHY -- shows the live state driving both rendering
	// and hit-testing so a report can come back with actual numbers instead
	// of "it doesn't work". Deliberately left in the shipped build; remove
	// once zoom has been solid for a while and this stops earning its keep.
	if (zoomEnabled)
	{
		auto hit = HitTestZoomWindowFrame(currentMouse);
		String hitName = "None";
		switch (hit)
		{
		case ZoomFrameHit::Move: hitName = "Move"; break;
		case ZoomFrameHit::ResizeTL: hitName = "ResizeTL"; break;
		case ZoomFrameHit::ResizeTR: hitName = "ResizeTR"; break;
		case ZoomFrameHit::ResizeBL: hitName = "ResizeBL"; break;
		case ZoomFrameHit::ResizeBR: hitName = "ResizeBR"; break;
		default: break;
		}
		auto winPos = c->GetZoomWindowPosition();
		auto winSize = c->GetZoomWindowSize();
		StringBuilder zoomDebug;
		zoomDebug << "ZOOM enabled=" << (zoomEnabled ? "1" : "0")
			<< " placed=" << (zoomCursorFixed ? "1" : "0")
			<< " visible=" << (g->zoomWindowVisible ? "1" : "0")
			<< " dragging=" << (zoomWindowDragging ? "1" : "0")
			<< " resizing=" << (zoomWindowResizing ? "1" : "0");
		g->BlendText({ 4, 100 }, zoomDebug.Build(), 0x00FF00_rgb .WithAlpha(255));
		StringBuilder zoomDebug2;
		zoomDebug2 << "mouse=(" << currentMouse.X << "," << currentMouse.Y << ")"
			<< " hit=" << hitName
			<< " winPos=(" << winPos.X << "," << winPos.Y << ")"
			<< " winSize=(" << winSize.X << "," << winSize.Y << ")";
		g->BlendText({ 4, 112 }, zoomDebug2.Build(), 0x00FF00_rgb .WithAlpha(255));
	}

	if (doScreenshot)
	{
		doScreenshot = false;
		TakeScreenshot(0, 0);
	}

	if(recording)
	{
		std::vector<char> data = VideoBuffer(*rendererFrame).ToPPM();

		ByteString filename = ByteString::Build("recordings", PATH_SEP_CHAR, recordingFolder, PATH_SEP_CHAR, "frame_", Format::Width(recordingIndex++, 6), ".ppm");

		Platform::WriteFile(data, filename);
	}

	if (logEntries.size())
	{
		int startX = 20;
		int startY = YRES-20;
		std::deque<std::pair<String, int> >::iterator iter;
		for(iter = logEntries.begin(); iter != logEntries.end(); iter++)
		{
			String message = (*iter).first;
			int alpha = std::min((*iter).second, 255);
			if (alpha <= 0) //erase this and everything older
			{
				logEntries.erase(iter, logEntries.end());
				break;
			}
			startY -= 14;
			g->BlendFilledRect(RectSized(Vec2{ startX-3, startY-3 }, Vec2{ Graphics::TextSize(message).X + 5, 14 }), 0x000000_rgb .WithAlpha(std::min(100, alpha)));
			g->BlendText({ startX, startY }, message, 0xFFFFFF_rgb .WithAlpha(alpha));
			(*iter).second -= 3;
		}
	}

	if (recording)
	{
		String sampleInfo = String::Build("#", screenshotIndex, " ", String(0xE00E), " REC");

		int textWidth = Graphics::TextSize(sampleInfo).X - 1;
		g->BlendFilledRect(RectSized(Vec2{ XRES-20-textWidth, 12 }, Vec2{ textWidth+8, 15 }), 0x000000_rgb .WithAlpha(127));
		g->BlendText({ XRES-16-textWidth, 16 }, sampleInfo, 0xFF3214_rgb .WithAlpha(255));
	}
	else if(showHud)
	{
		//Draw info about simulation under cursor
		int wavelengthGfx = 0;
		int alpha = 255-introText*5;
		if (toolTipPosition.Y < 120)
			alpha -= toolTipPresence*3;
		if (alpha < 0)
			alpha = 0;
		StringBuilder sampleInfo;
		sampleInfo << Format::Precision(2);

		int type = sample.particle.type;
		if (type)
		{
			int ctype = sample.particle.ctype;

			if (type == PT_PHOT || type == PT_BIZR || type == PT_BIZRG || type == PT_BIZRS || type == PT_FILT || type == PT_BRAY || type == PT_C5)
				wavelengthGfx = (ctype&0x3FFFFFFF);

			if (showDebug)
			{
				if (type == PT_LAVA && c->IsValidElement(ctype))
				{
					sampleInfo << "Molten " << c->ElementResolve(ctype, 0);
				}
				else if ((type == PT_PIPE || type == PT_PPIP) && c->IsValidElement(ctype))
				{
					if (ctype == PT_LAVA && c->IsValidElement(sample.particle.tmp4))
					{
						sampleInfo << c->ElementResolve(type, 0) << " with molten " << c->ElementResolve(sample.particle.tmp4, -1);
					}
					else
					{
						sampleInfo << c->ElementResolve(type, 0) << " with " << c->ElementResolve(ctype, sample.particle.tmp4);
					}
				}
				else if (type == PT_LIFE)
				{
					sampleInfo << c->ElementResolve(type, ctype);
				}
				else if (type == PT_FILT)
				{
					sampleInfo << c->ElementResolve(type, ctype);
					String filtModes[] = {"set colour", "AND", "OR", "AND-NOT", "red shift", "blue shift", "no effect", "XOR", "NOT", "old QRTZ scattering", "variable red shift", "variable blue shift"};
					if (sample.particle.tmp>=0 && sample.particle.tmp<=11)
						sampleInfo << " (" << filtModes[sample.particle.tmp] << ")";
					else
						sampleInfo << " (unknown mode)";
				}
				else if (type == PT_SEED || (type == PT_PLNT && ctype))
				{
					sampleInfo << c->ElementResolve(type, ctype);

					auto water = (ctype >> PLNT_LIFE) & 0xFF;
					auto colour = (ctype >> PLNT_COLOUR) & 0x3F;
					auto dir = (ctype >> PLNT_DIR) & 7;
					auto active = ctype & 1;

					static const std::array<String, 8> directions = {"N", "NW", "W", "SW", "S", "SE", "E", "NE"};
					static const std::array<std::array<String, 4>, 3> colours = {{
						{{"cc", "cC", "Cc", "CC"}}, {{"mm", "mM", "Mm", "MM"}}, {{"yy", "yY", "Yy", "YY"}} }};
					auto cyan = (colour >> 4) & 3;
					auto magenta = (colour >> 2) & 3;
					auto yellow = colour & 3;

					sampleInfo << " (" << water << " " <<
						colours[0][cyan] << colours[1][magenta] << colours[2][yellow] << " " << directions[dir] << " " << active << ")";
				}
				else
				{
					sampleInfo << c->ElementResolve(type, ctype);
					if (wavelengthGfx || type == PT_EMBR || type == PT_PRTI || type == PT_PRTO)
					{
						// Do nothing, ctype is meaningless for these elements
					}
					// Some elements store extra LIFE info in upper bits of ctype, instead of tmp/tmp2
					else if (type == PT_CRAY || type == PT_DRAY || type == PT_CONV || type == PT_LDTC)
						sampleInfo << " (" << c->ElementResolve(TYP(ctype), ID(ctype)) << ")";
					else if (type == PT_CLNE || type == PT_BCLN || type == PT_PCLN || type == PT_PBCN || type == PT_DTEC)
						sampleInfo << " (" << c->ElementResolve(ctype, sample.particle.tmp) << ")";
					else if (c->IsValidElement(ctype) && type != PT_GLOW && type != PT_WIRE && type != PT_SOAP && type != PT_LITH)
						sampleInfo << " (" << c->ElementResolve(ctype, 0) << ")";
					else if (ctype)
						sampleInfo << " (" << ctype << ")";
				}
				sampleInfo << ", Temp: ";
				format::RenderTemperature(sampleInfo, sample.particle.temp, c->GetTemperatureScale());
				sampleInfo << ", Life: " << sample.particle.life;
				if (sample.particle.type != PT_RFRG && sample.particle.type != PT_RFGL && sample.particle.type != PT_LIFE)
				{
					if (sample.particle.type == PT_CONV)
					{
						String elemName = c->ElementResolve(
							TYP(sample.particle.tmp),
							ID(sample.particle.tmp));
						if (elemName == "")
							sampleInfo << ", Tmp: " << sample.particle.tmp;
						else
							sampleInfo << ", Tmp: " << elemName;
					}
					else
						sampleInfo << ", Tmp: " << sample.particle.tmp;
				}

				// only elements that use .tmp2 show it in the debug HUD
				if (type == PT_CRAY || type == PT_DRAY || type == PT_EXOT || type == PT_LIGH || type == PT_SOAP || type == PT_TRON
						|| type == PT_VIBR || type == PT_VIRS || type == PT_WARP || type == PT_LCRY || type == PT_CBNW || type == PT_TSNS
						|| type == PT_DTEC || type == PT_LSNS || type == PT_PSTN || type == PT_LDTC || type == PT_VSNS || type == PT_LITH
						|| type == PT_CONV || type == PT_ETRD)
					sampleInfo << ", Tmp2: " << sample.particle.tmp2;

				sampleInfo << ", Pressure: " << sample.AirPressure;
			}
			else
			{
				sampleInfo << c->BasicParticleInfo(sample.particle);
				sampleInfo << ", Temp: ";
				format::RenderTemperature(sampleInfo, sample.particle.temp, c->GetTemperatureScale());
				sampleInfo << ", Pressure: " << sample.AirPressure;
			}
		}
		else if (sample.WallType)
		{
			sampleInfo << c->WallName(sample.WallType);
			sampleInfo << ", Pressure: " << sample.AirPressure;
		}
		else if (sample.isMouseInSim)
		{
			sampleInfo << "Empty, Pressure: " << sample.AirPressure;
		}
		else
		{
			sampleInfo << "Empty";
		}

		int textWidth = Graphics::TextSize(sampleInfo.Build()).X - 1;
		g->BlendFilledRect(RectSized(Vec2{ XRES-20-textWidth, 12 }, Vec2{ textWidth+8, 15 }), 0x000000_rgb .WithAlpha(int(alpha*0.5f)));
		g->BlendText({ XRES-16-textWidth, 16 }, sampleInfo.Build(), 0xFFFFFF_rgb .WithAlpha(int(alpha*0.75f)));

		if (wavelengthGfx)
		{
			int i, cr, cg, cb, j, h = 3, x = XRES-19-textWidth, y = 10;
			int tmp;
			g->BlendFilledRect(RectSized(Vec2{ x, y }, Vec2{ 30, h }), 0x404040_rgb .WithAlpha(alpha));
			for (i = 0; i < 30; i++)
			{
				if ((wavelengthGfx >> i)&1)
				{
					// Need a spread of wavelengths to get a smooth spectrum, 5 bits seems to work reasonably well
					if (i>2) tmp = 0x1F << (i-2);
					else tmp = 0x1F >> (2-i);

					cg = 0;
					cb = 0;
					cr = 0;

					for (j=0; j<12; j++)
					{
						cr += (tmp >> (j+18)) & 1;
						cb += (tmp >> j) & 1;
					}
					for (j=0; j<13; j++)
						cg += (tmp >> (j+9)) & 1;

					tmp = 624/(cr+cg+cb+1);
					cr *= tmp;
					cg *= tmp;
					cb *= tmp;
					for (j=0; j<h; j++)
						g->BlendPixel({ x+29-i, y+j }, RGBA(cr>255?255:cr, cg>255?255:cg, cb>255?255:cb, alpha));
				}
			}
		}

		if (showDebug)
		{
			StringBuilder sampleInfo;
			sampleInfo << Format::Precision(2);

			if (type)
				sampleInfo << "#" << sample.ParticleID << ", ";

			sampleInfo << "X:" << sample.PositionX << " Y:" << sample.PositionY;

			auto gravtot = std::abs(sample.GravityVelocityX) +
			               std::abs(sample.GravityVelocityY);
			if (gravtot)
				sampleInfo << ", GX: " << sample.GravityVelocityX << " GY: " << sample.GravityVelocityY;

			if (c->GetAHeatEnable() && sample.isMouseInSim)
			{
				sampleInfo << ", AHeat: ";
				format::RenderTemperature(sampleInfo, sample.AirTemperature, c->GetTemperatureScale());
			}

			auto textWidth = Graphics::TextSize(sampleInfo.Build()).X - 1;
			g->BlendFilledRect(RectSized(Vec2{ XRES-20-textWidth, 27 }, Vec2{ textWidth+8, 14 }), 0x000000_rgb .WithAlpha(int(alpha*0.5f)));
			g->BlendText({ XRES-16-textWidth, 30 }, sampleInfo.Build(), 0xFFFFFF_rgb .WithAlpha(int(alpha*0.75f)));
		}
	}

	if(showHud && introText < 51)
	{
		//FPS and some version info
		StringBuilder fpsInfo;
		fpsInfo << Format::Precision(2) << "FPS: " << ui::Engine::Ref().GetFps();

		if (showDebug)
		{
			if (rendererSettings->findingElement)
				fpsInfo << " Parts: " << rendererStats.foundParticles << "/" << sample.NumParts;
			else
				fpsInfo << " Parts: " << sample.NumParts;
		}
		if ((std::holds_alternative<HdispLimitAuto>(rendererSettings->wantHdispLimitMin) ||
		     std::holds_alternative<HdispLimitAuto>(rendererSettings->wantHdispLimitMax)) && rendererStats.hdispLimitValid)
		{
			fpsInfo << " [TEMP L:";
			format::RenderTemperature(fpsInfo, rendererStats.hdispLimitMin, c->GetTemperatureScale());
			fpsInfo << " H:";
			format::RenderTemperature(fpsInfo, rendererStats.hdispLimitMax, c->GetTemperatureScale());
			fpsInfo << "]";
		}
		if (c->GetReplaceModeFlags()&REPLACE_MODE)
			fpsInfo << " [REPLACE MODE]";
		if (c->GetReplaceModeFlags()&SPECIFIC_DELETE)
			fpsInfo << " [SPECIFIC DELETE]";
		if (rendererSettings->gridSize)
			fpsInfo << " [GRID: " << rendererSettings->gridSize << "]";
		if (rendererSettings->findingElement)
			fpsInfo << " [FIND]";
		if (c->GetDebugFlags() & DEBUG_SIMHUD)
		{
			fpsInfo << "\nSimulation";
			fpsInfo << "\n  FPS cap: ";
			if (std::holds_alternative<FpsLimitNone>(simFpsLimit))
			{
				fpsInfo << "none";
			}
			else
			{
				fpsInfo << std::get<FpsLimitExplicit>(simFpsLimit).value;
			}
		}
		if (c->GetDebugFlags() & DEBUG_RENHUD)
		{
			fpsInfo << "\nRendering";
			fpsInfo << "\n  Draw cap: ";
			auto drawLimit = ui::Engine::Ref().GetDrawingFrequencyLimit();
			if (std::holds_alternative<DrawLimitDisplay>(drawLimit))
			{
				fpsInfo << "display";
			}
			else
			{
				fpsInfo << std::get<DrawLimitExplicit>(drawLimit).value;
			}
			fpsInfo << ", effective: ";
			if (auto drawCap = ui::Engine::Ref().GetEffectiveDrawCap())
			{
				fpsInfo << *drawCap;
			}
			else
			{
				fpsInfo << "none";
			}
			fpsInfo << "\n  SRT: ";
			if (!c->GetThreadedRendering())
			{
				fpsInfo << "disabled";
			}
			else if (threadedRenderingAllowed)
			{
				fpsInfo << "enabled";
			}
			else
			{
				fpsInfo << "hindered";
			}
			fpsInfo << "\n  Refresh rate: ";
			auto refreshRate = ui::Engine::Ref().GetRefreshRate();
			fpsInfo << std::visit([](auto &refreshRate) {
				return refreshRate.value;
			}, refreshRate);
			if (std::holds_alternative<RefreshRateDefault>(refreshRate))
			{
				fpsInfo << " (default)";
			}
		}
		if (auto *frameTime = c->GetFrameTime())
		{
			for (auto &span : frameTime->GetLastSpans())
			{
				fpsInfo << "\n";
				for (int i = 0; i < span.level; ++i)
				{
					fpsInfo << " ";
				}
				fpsInfo << ByteString(span.name).FromUtf8() << ": " << Format::Precision(2) << (span.duration / 1000.0) << "us";
			}
		}

		auto textSize = Graphics::TextSize(fpsInfo.Build());
		int textWidth = textSize.X - 1;
		int alpha = 255-introText*5;
		g->BlendFilledRect(RectSized(Vec2{ 12, 12 }, Vec2{ textWidth+8, textSize.Y + 5 }), 0x000000_rgb .WithAlpha(int(alpha*0.5)));
		g->BlendText({ 16, 16 }, fpsInfo.Build(), 0x20D8FF_rgb .WithAlpha(int(alpha*0.75)));
	}

	//Tooltips
	if(infoTipPresence)
	{
		int infoTipAlpha = (infoTipPresence>50?50:int(infoTipPresence))*5;
		g->BlendTextOutline({ (XRES - (Graphics::TextSize(infoTip).X - 1)) / 2, YRES / 2 - 2 }, infoTip, 0xFFFFFF_rgb .WithAlpha(infoTipAlpha));
	}

	if(toolTipPresence && toolTipPosition.X!=-1 && toolTipPosition.Y!=-1 && toolTip.length())
	{
		if (toolTipPosition.Y == Size.Y-MENUSIZE-10)
			g->BlendTextOutline(toolTipPosition, toolTip, 0xFFFFFF_rgb .WithAlpha(toolTipPresence>51?255:toolTipPresence*5));
		else
			g->BlendText(toolTipPosition, toolTip, 0xFFFFFF_rgb .WithAlpha(toolTipPresence>51?255:toolTipPresence*5));
	}

	if(buttonTipShow > 0)
	{
		g->BlendText({ 16, Size.Y-MENUSIZE-24 }, buttonTip, 0xFFFFFF_rgb .WithAlpha(buttonTipShow>51?255:buttonTipShow*5));
	}

	//Introduction text
	if(introText && showHud)
	{
		g->BlendFilledRect(RectSized(Vec2{ 0, 0 }, WINDOW), 0x000000_rgb .WithAlpha(introText>51?102:introText*2));
		g->BlendText({ 16, 16 }, introTextMessage, 0xFFFFFF_rgb .WithAlpha(introText>51?255:introText*5));
	}
}

ui::Point GameView::lineSnapCoords(ui::Point point1, ui::Point point2)
{
	ui::Point diff = point2 - point1;
	if(abs(diff.X / 2) > abs(diff.Y)) // vertical
		return point1 + ui::Point(diff.X, 0);
	if(abs(diff.X) < abs(diff.Y / 2)) // horizontal
		return point1 + ui::Point(0, diff.Y);
	if(diff.X * diff.Y > 0) // NW-SE
		return point1 + ui::Point((diff.X + diff.Y)/2, (diff.X + diff.Y)/2);
	// SW-NE
	return point1 + ui::Point((diff.X - diff.Y)/2, (diff.Y - diff.X)/2);
}

ui::Point GameView::rectSnapCoords(ui::Point point1, ui::Point point2)
{
	ui::Point diff = point2 - point1;
	if(diff.X * diff.Y > 0) // NW-SE
		return point1 + ui::Point((diff.X + diff.Y)/2, (diff.X + diff.Y)/2);
	// SW-NE
	return point1 + ui::Point((diff.X - diff.Y)/2, (diff.Y - diff.X)/2);
}

std::optional<FindingElement> GameView::FindingElementCandidate() const
{
	Tool *active = c->GetActiveTool(0);
	auto &properties = Particle::GetProperties();
	if (active->Identifier.Contains("_PT_"))
	{
		return FindingElement{ properties[FIELD_TYPE], active->ToolID };
	}
	else if (active->Identifier == "DEFAULT_UI_PROPERTY")
	{
		auto configuration = static_cast<PropertyTool *>(active)->GetConfiguration();
		if (configuration)
		{
			return FindingElement{ properties[configuration->changeProperty.propertyIndex], configuration->changeProperty.propertyValue };
		}
	}
	return std::nullopt;
}

pixel GameView::GetPixelUnderMouse() const
{
	auto point = c->PointTranslate(currentMouse);
	if (!rendererFrame->Size().OriginRect().Contains(point))
	{
		return 0;
	}
	return (*rendererFrame)[point];
}

void GameView::RendererThread()
{
	while (true)
	{
		{
			std::unique_lock lk(rendererThreadMx);
			rendererThreadOwnsRenderer = false;
			rendererThreadCv.notify_one();
			rendererThreadCv.wait(lk, [this]() {
				return rendererThreadState == rendererThreadStopping || rendererThreadOwnsRenderer;
			});
			if (rendererThreadState == rendererThreadStopping)
			{
				break;
			}
		}
		RenderSimulation(*rendererThreadSim, false);
	}
}

void GameView::StartRendererThread()
{
	bool start = false;
	bool notify = false;
	{
		std::lock_guard lk(rendererThreadMx);
		if (rendererThreadState == rendererThreadAbsent)
		{
			rendererThreadSim = std::make_unique<RenderableSimulation>();
			rendererThreadResult = std::make_unique<RendererFrame>();
			rendererThreadState = rendererThreadRunning;
			start = true;
		}
		else if (rendererThreadState == rendererThreadPaused)
		{
			rendererThreadState = rendererThreadRunning;
			notify = true;
		}
	}
	if (start)
	{
		rendererThread = std::thread([this]() {
			RendererThread();
		});
		notify = true;
	}
	if (notify)
	{
		DispatchRendererThread();
	}
}

void GameView::StopRendererThread()
{
	bool join = false;
	{
		std::lock_guard lk(rendererThreadMx);
		if (rendererThreadState != rendererThreadAbsent)
		{
			rendererThreadState = rendererThreadStopping;
			join = true;
		}
	}
	if (join)
	{
		rendererThreadCv.notify_one();
		rendererThread.join();
	}
}

void GameView::PauseRendererThread()
{
	std::unique_lock lk(rendererThreadMx);
	if (rendererThreadState == rendererThreadRunning)
	{
		rendererThreadState = rendererThreadPaused;
		rendererThreadCv.notify_one();
		rendererThreadCv.wait(lk, [this]() {
			return !rendererThreadOwnsRenderer;
		});
	}
}

void GameView::DispatchRendererThread()
{
	ren->ApplySettings(*rendererSettings);
	*rendererThreadSim = *sim;
	rendererThreadSim->useLuaCallbacks = false;
	rendererThreadOwnsRenderer = true;
	{
		std::lock_guard lk(rendererThreadMx);
		rendererThreadOwnsRenderer = true;
	}
	rendererThreadCv.notify_one();
}

void GameView::WaitForRendererThread()
{
	std::unique_lock lk(rendererThreadMx);
	rendererThreadCv.wait(lk, [this]() {
		return !rendererThreadOwnsRenderer;
	});
}

void GameView::ApplySimFpsLimit()
{
	if (std::holds_alternative<FpsLimitNone>(simFpsLimit))
	{
		if (c->GetPaused())
		{
			SetFpsLimit(FpsLimitFollowDraw{});
		}
		else
		{
			SetFpsLimit(FpsLimitNone{});
		}
	}
	else
	{
		SetFpsLimit(std::get<FpsLimitExplicit>(simFpsLimit));
	}
}

void GameView::SetSimFpsLimit(SimFpsLimit newSimFpsLimit)
{
	simFpsLimit = newSimFpsLimit;
	ApplySimFpsLimit();
}
