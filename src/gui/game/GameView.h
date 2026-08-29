#pragma once
#include "common/String.h"
#include "gui/interface/Window.h"
#include "gui/interface/Fade.h"
#include "simulation/Sample.h"
#include "graphics/FindingElement.h"
#include "graphics/RendererFrame.h"
#include <ctime>
#include <deque>
#include <memory>
#include <vector>
#include <map>
#include <optional>
#include <thread>
#include <functional>
#include <mutex>
#include <condition_variable>

enum DrawMode
{
	DrawPoints, DrawLine, DrawRect, DrawFill
};

enum SelectMode
{
	SelectNone, SelectStamp, SelectCopy, SelectCut, PlaceSave
};

namespace ui
{
	class Button;
	class Slider;
	class Textbox;
}

class SplitButton;
class Simulation;
struct RenderableSimulation;

class MenuButton;
class Renderer;
struct RendererSettings;
class VideoBuffer;
class ToolButton;
class Tool;
class GameController;
class Brush;
class GameModel;
class GameView: public ui::Window
{
private:
	bool isMouseDown;
	bool skipDraw;
	bool zoomEnabled;
	bool zoomCursorFixed;
	bool mouseInZoom;
	// Dragging/resizing the on-screen zoom window itself (its decorative
	// frame, not its magnified content -- that's still MouseInZoom/
	// AdjustZoomCoords, untouched, so precision-drawing inside the zoomed
	// view keeps working exactly as before).
	bool zoomWindowDragging = false;
	bool zoomWindowResizing = false;
	ui::Point zoomWindowDragOffset = ui::Point(0, 0);
	ui::Point zoomWindowResizeAnchor = ui::Point(0, 0); // the corner NOT being dragged; stays fixed on screen
	enum class ZoomFrameHit { None, Move, ResizeTL, ResizeTR, ResizeBL, ResizeBR };
	ZoomFrameHit HitTestZoomWindowFrame(ui::Point mouse) const;
	bool drawSnap;
	// Wall-clock ms (SDL_GetTicks) of the last scroll-wheel notch, and how
	// many notches have landed in a row while the gap between them stayed
	// short -- lets a brisk flick of the wheel ramp the resize step up
	// instead of every notch being the same size regardless of how fast
	// they're coming in. Wall-clock rather than sim ticks deliberately --
	// sim tick rate can be capped/paused/vary, and this needs to track real
	// elapsed time between scroll events, not simulation progress. See
	// OnMouseWheel.
	unsigned int lastScrollTime = 0; // SDL_GetTicks() at the last wheel notch
	int scrollStreak = 0;
	bool shiftBehaviour;
	bool ctrlBehaviour;
	bool altBehaviour;
	// Held while dragging a Ctrl+drag region fill (Rect or Ellipse, see
	// ElementTool::DrawRect) to anchor it at its centre and grow outward in
	// both directions instead of anchoring at the drag's start corner --
	// RimWorld's Designator Shapes mod offers the same choice.
	bool centerAnchorBehaviour = false;
	bool showHud;
	bool showBrush;
	bool showDebug;
	int delayedActiveMenu;
	bool wallBrush;
	bool toolBrush;
	bool decoBrush;
	int toolIndex;
	int currentSaveType;
	int lastMenu;

	ui::Fade toolTipPresence{ ui::Fade::LinearProfile{ 120.f, 60.f }, 0, 0 };
	String toolTip;
	bool isToolTipFadingIn;
	ui::Point toolTipPosition;
	ui::Fade infoTipPresence{ ui::Fade::LinearProfile{ 60.f, 60.f }, 0, 0 };
	String infoTip;
	ui::Fade buttonTipShow{ ui::Fade::LinearProfile{ 120.f, 60.f }, 0, 0 };
	String buttonTip;
	bool isButtonTipFadingIn;
	ui::Fade introText{ ui::Fade::LinearProfile{ 60.f, 60.f }, 0, 2048 };
	String introTextMessage;

	bool doScreenshot;
	int screenshotIndex;
	time_t lastScreenshotTime;
	int recordingIndex;
	bool recording;
	int recordingFolder;

	ui::Point currentPoint, lastPoint;
	GameController * c;
	Renderer *ren = nullptr;
	RendererSettings *rendererSettings = nullptr;
	bool wantFrame = false;
	Simulation *sim = nullptr;
	Brush const *activeBrush;
	//UI Elements
	std::vector<ui::Button*> quickOptionButtons;

	std::vector<MenuButton*> menuButtons;
	std::vector<ui::Button*> subCategoryButtons;
	// The subcategory ladder is a hover-only popup, unlike the sticky
	// activeMenu tool row -- it must vanish the instant the mouse leaves it,
	// and while visible its screen rectangle must be excluded from sim
	// click/draw handling (it can extend above YRES, over the sim view).
	bool subCategoryLadderVisible = false;
	int subCategoryLadderMenuID = -1;
	ui::Point subCategoryLadderTopLeft = ui::Point(0, 0);
	ui::Point subCategoryLadderSize = ui::Point(0, 0);
	// Grace period (in ticks) before an unhovered ladder actually closes --
	// without this, the ladder sits diagonally adjacent to its menu button
	// (they only touch at one corner pixel) so any real mouse movement
	// between them crosses a frame where neither hit-test matches, and the
	// ladder was vanishing mid-transit. Reset to full on every hover, ticked
	// down by DecaySubCategoryLadderHover(), only actually hides at 0.
	int subCategoryLadderHideDelay = 0;
	bool PointInSubCategoryLadder(ui::Point p) const
	{
		return subCategoryLadderVisible &&
			p.X >= subCategoryLadderTopLeft.X && p.X < subCategoryLadderTopLeft.X + subCategoryLadderSize.X &&
			p.Y >= subCategoryLadderTopLeft.Y && p.Y < subCategoryLadderTopLeft.Y + subCategoryLadderSize.Y;
	}
	void UpdateSubCategoryLadderHover(ui::Point mouse);
	void DecaySubCategoryLadderHover();
	void RebuildSubCategoryLadder();

	// State picker: hovering an element's tool button pops a small chip list
	// of the physical states it doesn't already natively have (Powder/
	// Liquid/Gas/Solid, via GameController::SelectStateCarrierTool) --
	// same hover/grace-period/rebuild shape as the subcategory ladder above,
	// just anchored to a tool button instead of a menu button.
	std::vector<ui::Button*> stateLadderButtons;
	bool stateLadderVisible = false;
	ToolButton *stateLadderButton = nullptr;
	ui::Point stateLadderTopLeft = ui::Point(0, 0);
	ui::Point stateLadderSize = ui::Point(0, 0);
	int stateLadderHideDelay = 0;
	bool PointInStateLadder(ui::Point p) const
	{
		return stateLadderVisible &&
			p.X >= stateLadderTopLeft.X && p.X < stateLadderTopLeft.X + stateLadderSize.X &&
			p.Y >= stateLadderTopLeft.Y && p.Y < stateLadderTopLeft.Y + stateLadderSize.Y;
	}
	void UpdateStateLadderHover(ui::Point mouse);
	void DecayStateLadderHover();
	void RebuildStateLadder();

	// Favorites wheel: hold T to pop a radial "command wheel" (like
	// RimWorld's Dubs Mint Menus mod) of Drew's current favorited
	// elements, centered on the cursor -- click a slot to select it,
	// release T to close. Reuses the existing Favorite list (already
	// user-editable via the Shift+Ctrl-click toggle on any element button)
	// as the wheel's contents rather than building a separate
	// configuration UI, and the same click-to-pick/hold-to-show shape the
	// Z zoom tool already uses in this file, instead of a hover trigger.
	std::vector<ui::Button*> favoritesWheelButtons;
	bool favoritesWheelVisible = false;
	ui::Point favoritesWheelTopLeft = ui::Point(0, 0);
	ui::Point favoritesWheelSize = ui::Point(0, 0);
	bool PointInFavoritesWheel(ui::Point p) const
	{
		return favoritesWheelVisible &&
			p.X >= favoritesWheelTopLeft.X && p.X < favoritesWheelTopLeft.X + favoritesWheelSize.X &&
			p.Y >= favoritesWheelTopLeft.Y && p.Y < favoritesWheelTopLeft.Y + favoritesWheelSize.Y;
	}
	void OpenFavoritesWheel(ui::Point center);
	// Layer 1 (shown when favorites span more than one menu category): one
	// slot per category, click one to drill into layer 2.
	void OpenFavoritesCategoryRing(ui::Point center, const std::map<int, std::vector<Tool *>> &byCategory);
	// Layer 2 (or the only layer, if there's just one category): the actual
	// tool slots, plus a Back slot to return to layer 1 when it came from
	// a category (backToCategory >= 0).
	void OpenFavoritesLeafRing(ui::Point center, std::vector<Tool *> tools, int backToCategory);
	void SetFavoritesWheelBounds(ui::Point center, const std::vector<ui::Point> &positions, int itemSize);
	// Copy/Paste slots, always on the wheel's outermost ring -- see
	// GameView.cpp's AddFavoritesWheelCopyPasteSlots for why.
	void AddFavoritesWheelActionSlot(ui::Point position, int itemSize, String label, std::function<void()> action);
	void AddFavoritesWheelCopyPasteSlots(const std::vector<ui::Point> &positions, int firstIdx, int itemSize);
	void CloseFavoritesWheel();

	std::vector<ToolButton*> toolButtons;
	std::vector<ui::Component*> notificationComponents;
	std::deque<std::pair<String, int> > logEntries;
	ui::Button * scrollBar;
	ui::Button * searchButton;
	ui::Button * reloadButton;
	SplitButton * saveSimulationButton;
	bool saveSimulationButtonEnabled;
	bool saveReuploadAllowed;
	ui::Button * downVoteButton;
	ui::Button * upVoteButton;
	void ResetVoteButtons();
	ui::Button * tagSimulationButton;
	ui::Button * clearSimButton;
	SplitButton * loginButton;
	ui::Button * simulationOptionButton;
	ui::Button * displayModeButton;
	ui::Button * pauseButton;

	ui::Button * colourPicker;
	std::vector<ToolButton*> colourPresets;

	DrawMode drawMode;
	ui::Point drawPoint1;
	ui::Point drawPoint2;

	SelectMode selectMode;
	ui::Point selectPoint1;
	ui::Point selectPoint2;

	ui::Point currentMouse;
	ui::Point mousePosition;

	std::unique_ptr<VideoBuffer> placeSaveThumb;
	Mat2<int> placeSaveTransform = Mat2<int>::Identity;
	Vec2<int> placeSaveTranslate = Vec2<int>::Zero;
	void TranslateSave(Vec2<int> addToTranslate);
	void TransformSave(Mat2<int> mulToTransform);
	void ApplyTransformPlaceSave();

	SimulationSample sample;

	void updateToolButtonScroll();

	void SetSaveButtonTooltips();

	void enableShiftBehaviour();
	void disableShiftBehaviour();
	void enableCtrlBehaviour();
	void disableCtrlBehaviour();
	void enableAltBehaviour();
	void disableAltBehaviour();
	void UpdateDrawMode();
	void UpdateToolStrength();

	Vec2<int> PlaceSavePos() const;

	std::optional<FindingElement> FindingElementCandidate() const;
	enum RendererThreadState
	{
		rendererThreadAbsent,
		rendererThreadRunning,
		rendererThreadPaused,
		rendererThreadStopping,
	};
	RendererThreadState rendererThreadState = rendererThreadAbsent;
	std::thread rendererThread;
	std::mutex rendererThreadMx;
	std::condition_variable rendererThreadCv;
	bool rendererThreadOwnsRenderer = false;
	void StartRendererThread();
	void StopRendererThread();
	void RendererThread();
	void WaitForRendererThread();
	void DispatchRendererThread();
	std::unique_ptr<RenderableSimulation> rendererThreadSim;
	std::unique_ptr<RendererFrame> rendererThreadResult;
	RendererStats rendererStats;
	const RendererFrame *rendererFrame = nullptr;

	SimFpsLimit simFpsLimit = FpsLimitExplicit{ 60.f };
	void ApplySimFpsLimit();

public:
	GameView();
	~GameView();

	//Breaks MVC, but any other way is going to be more of a mess.
	ui::Point GetMousePosition();
	void SetSample(SimulationSample sample);
	void SetHudEnable(bool hudState);
	bool GetHudEnable();
	void SetBrushEnable(bool hudState);
	bool GetBrushEnable();
	void SetDebugHUD(bool mode);
	bool GetDebugHUD();
	bool GetPlacingSave();
	bool GetPlacingZoom();
	void SetActiveMenuDelayed(int activeMenu) { delayedActiveMenu = activeMenu; }
	bool CtrlBehaviour(){ return ctrlBehaviour; }
	bool ShiftBehaviour(){ return shiftBehaviour; }
	bool AltBehaviour(){ return altBehaviour; }
	SelectMode GetSelectMode() { return selectMode; }
	void BeginStampSelection();
	ByteString TakeScreenshot(int captureUI, int fileType);
	int Record(bool record);

	//all of these are only here for one debug lines
	bool GetMouseDown() { return isMouseDown; }
	bool GetDrawingLine() { return drawMode == DrawLine && isMouseDown && selectMode == SelectNone; }
	bool GetDrawSnap() { return drawSnap; }
	ui::Point GetLineStartCoords() { return drawPoint1; }
	ui::Point GetLineFinishCoords() { return currentMouse; }
	ui::Point GetCurrentMouse() { return currentMouse; }
	ui::Point lineSnapCoords(ui::Point point1, ui::Point point2);
	ui::Point rectSnapCoords(ui::Point point1, ui::Point point2);

	void AttachController(GameController * _c){ c = _c; }
	void NotifyRendererChanged(GameModel * sender);
	void NotifySimulationChanged(GameModel * sender);
	void NotifyPausedChanged(GameModel * sender);
	void NotifySaveChanged(GameModel * sender);
	void NotifyBrushChanged(GameModel * sender);
	void NotifyMenuListChanged(GameModel * sender);
	void NotifyActiveMenuToolListChanged(GameModel * sender);
	void NotifyActiveToolsChanged(GameModel * sender);
	void NotifyUserChanged(GameModel * sender);
	void NotifyZoomChanged(GameModel * sender);
	void NotifyColourSelectorVisibilityChanged(GameModel * sender);
	void NotifyColourSelectorColourChanged(GameModel * sender);
	void NotifyColourPresetsChanged(GameModel * sender);
	void NotifyColourActivePresetChanged(GameModel * sender);
	void NotifyPlaceSaveChanged(GameModel * sender);
	void NotifyTransformedPlaceSaveChanged(GameModel *sender);
	void NotifyNotificationsChanged(GameModel * sender);
	void NotifyLogChanged(GameModel * sender, String entry);
	void NotifyToolTipChanged(GameModel * sender);
	void NotifyInfoTipChanged(GameModel * sender);
	void NotifyQuickOptionsChanged(GameModel * sender);
	void NotifyLastToolChanged(GameModel * sender);


	void ToolTip(ui::Point senderPosition, String toolTip) override;

	void OnMouseMove(int x, int y, int dx, int dy) override;
	void OnMouseDown(int x, int y, unsigned button) override;
	void OnMouseUp(int x, int y, unsigned button) override;
	void OnMouseWheel(int x, int y, int d) override;
	void OnKeyPress(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt) override;
	void OnKeyRelease(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt) override;
	void OnTick() override;
	void OnSimTick() override;
	void OnDraw() override;
	void OnBlur() override;
	void OnFileDrop(ByteString filename) override;

	//Top-level handlers, for Lua interface
	void DoExit() override;
	void DoDraw() override;
	void DoMouseMove(int x, int y, int dx, int dy) override;
	void DoMouseDown(int x, int y, unsigned button) override;
	void DoMouseUp(int x, int y, unsigned button) override;
	void DoMouseWheel(int x, int y, int d) override;
	void DoTextInput(String text) override;
	void DoTextEditing(String text) override;
	void DoKeyPress(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt) override;
	void DoKeyRelease(int key, int scan, bool repeat, bool shift, bool ctrl, bool alt) override;

	class OptionListener;

	void SkipIntroText();
	pixel GetPixelUnderMouse() const;

	const RendererFrame &GetRendererFrame() const
	{
		return *rendererFrame;
	}
	// Call this before accessing Renderer "out of turn", e.g. from RenderView or GameModel. This *does not*
	// include OptionsModel or Lua setting functions because they only access the RendererSettings
	// in GameModel, or Lua drawing functions because they only access Renderer in eventTraitSimGraphics
	// and *SimDraw events, and the renderer thread gets paused anyway if there are handlers
	// installed for such events.
	void PauseRendererThread();

	void RenderSimulation(const RenderableSimulation &sim, bool handleEvents);
	void AfterSimDraw(const RenderableSimulation &sim);

	void SetSimFpsLimit(SimFpsLimit newSimFpsLimit);
	SimFpsLimit GetSimFpsLimit() const
	{
		return simFpsLimit;
	}
};
