using System.Xml.Linq;

var fixtureRoot = Path.Combine(AppContext.BaseDirectory, "Fixtures");
var page = XDocument.Load(Path.Combine(fixtureRoot, "MainPage.xaml"));
var codeBehind = File.ReadAllText(Path.Combine(fixtureRoot, "MainPage.xaml.cs"));
var appCodeBehind = File.ReadAllText(Path.Combine(fixtureRoot, "App.xaml.cs"));
var mainWindow = XDocument.Load(Path.Combine(fixtureRoot, "MainWindow.xaml"));
var windowCodeBehind = File.ReadAllText(Path.Combine(fixtureRoot, "MainWindow.xaml.cs"));
var viewModelCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecordingViewModel.cs"));
var overlay = XDocument.Load(Path.Combine(fixtureRoot, "RecordingOverlayWindow.xaml"));
var overlayCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecordingOverlayWindow.xaml.cs"));
var overlayPresentationCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecordingOverlayPresentation.cs"));
var controlAdapterCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecorderControlLifecycleOwnerAdapter.cs"));
var recordingLibraryCode = File.ReadAllText(Path.Combine(fixtureRoot, "Views", "RecordingLibraryView.xaml.cs"));
var xaml = (XNamespace)"http://schemas.microsoft.com/winfx/2006/xaml/presentation";
var x = (XNamespace)"http://schemas.microsoft.com/winfx/2006/xaml";

var tests = new (string Name, Action Run)[]
{
    ("shell exposes exactly four stable workspace routes", WorkspaceRoutesAreStable),
    ("record is the default workspace", RecordIsDefault),
    ("primary recording state and actions stay above the record scroller", PrimaryControlsStayAboveTheFold),
    ("source, device, and screen controls occupy three explicit rows", SourceDeviceGridHasRows),
    ("main window is DPI-aware and enforces the dashboard minimum", MainWindowEnforcesMinimumSize),
    ("second launch redirects to the one primary window", AppEnforcesSingleInstance),
    ("existing view-model command surface remains wired", ExistingCommandsRemainWired),
    ("each workspace owns its controls", ControlsAreRoutedToTheirWorkspace),
    ("automation identifiers are unique and stable", AutomationIdentifiersAreUnique),
    ("English and Traditional Chinese resources stay in sync", LocaleResourcesStayInSync),
    ("custom theme resources resolve at runtime", CustomThemeResourcesResolve),
    ("audio-only MP4 uses the audio playback stage", AudioOnlyMp4UsesAudioStage),
    ("macOS parity surfaces remain wired", MacParitySurfacesRemainWired),
    ("Teams runtime uses local monitoring and retires WebSocket construction", TeamsRuntimeUsesLocalMonitoring),
    ("recording overlay owns a safe dynamic Teams video toggle", OverlayVideoToggleIsSafe),
    ("Teams window capture refreshes an exact target at the start boundary", TeamsWindowTargetRefreshIsBounded),
    ("recording overlay supports active countdown and finalizing states", OverlayStatesAreComplete),
    ("recording overlay scales for DPI and remains user-resizable", OverlayIsDpiAwareAndResizable),
    ("pipe control joins the UI lifecycle and stops before finalization", ControlRuntimeLifecycleIsBounded),
    ("pipe status remains a bounded privacy-safe projection", ControlStatusIsPrivate),
};

var failures = 0;
foreach (var (name, run) in tests)
{
    try
    {
        run();
        Console.WriteLine($"PASS {name}");
    }
    catch (Exception error)
    {
        failures++;
        Console.Error.WriteLine($"FAIL {name}: {error.Message}");
    }
}

return failures == 0 ? 0 : 1;

void WorkspaceRoutesAreStable()
{
    var navigation = SingleByName("WorkspaceNavigation");
    Equal(xaml + "NavigationView", navigation.Name, "WorkspaceNavigation must be a NavigationView.");

    var routes = navigation
        .Descendants(xaml + "NavigationViewItem")
        .Select(item => item.Attribute("Tag")?.Value)
        .ToArray();
    SequenceEqual(new[] { "Record", "Recordings", "AI", "Settings" }, routes, "Unexpected workspace route order.");
}

void RecordIsDefault()
{
    Equal("Visible", SingleByName("RecordWorkspace").Attribute("Visibility")?.Value ?? "Visible", "Record must be visible by default.");
    Equal("Collapsed", SingleByName("RecordingsWorkspace").Attribute("Visibility")?.Value, "Recordings must start collapsed.");
    Equal("Collapsed", SingleByName("AiWorkspace").Attribute("Visibility")?.Value, "AI must start collapsed.");
    Equal("Collapsed", SingleByName("SettingsWorkspace").Attribute("Visibility")?.Value, "Settings must start collapsed.");
    Contains("WorkspaceNavigation.SelectedItem = RecordNavigationItem;", codeBehind, "Code-behind must select Record after XAML initialization.");
}

void MacParitySurfacesRemainWired()
{
    var ai = WorkspaceDocument("AiWorkspaceView.xaml");
    var settings = WorkspaceDocument("RecorderSettingsView.xaml");
    foreach (var automationId in new[]
    {
        "AiImportAudioButton",
        "AiTranscriptEditor",
        "AiMeetingSummaryEditor",
        "AiSuggestedTitleEditor",
    }) AssertDocumentContains(ai, automationId);
    foreach (var automationId in new[]
    {
        "SettingsAiProviderKindComboBox",
        "SettingsHktGroupIdTextBox",
        "SettingsHktResolvedUrlTextBox",
        "SettingsMeetingIntelligencePromptTextBox",
        "SettingsFollowTeamsMuteCheckBox",
    }) AssertDocumentContains(settings, automationId);
    Contains("StartAutomaticAsync(providerProcessingAllowed: true)", viewModelCode,
        "A confirmed ASR request must wire automatic Meeting Intelligence.");
    Contains("CompleteTestPlaybackAsync", viewModelCode,
        "The ten-second test must auto-play its published recording.");
    Contains("RecordingStorageDecision.AudioOnly", viewModelCode,
        "Live low-storage monitoring must retain audio while disabling video.");
    Contains("WindowsInputMuteMonitor", viewModelCode,
        "The selected Windows input endpoint must contribute hardware mute state.");
    Contains("WindowsTeamsMuteFollowProbe", viewModelCode,
        "The opt-in read-only Teams mute observer must remain wired.");
    Contains("recorderMicrophoneMute.SetTeamsMuted", viewModelCode,
        "Teams observation must gate only Recorder's microphone contribution.");
    Contains("ProbeTeamsRenderEndpoints", viewModelCode,
        "A hidden Teams toolbar during an active audio session must fail closed rather than look like call exit.");
    Contains("CaptureOpenAiProviderDraft", viewModelCode,
        "Switching provider must preserve independent unsaved drafts.");
    Contains("OpenAiApiKeyReplacement", settings.ToString(),
        "Provider-specific replacement keys must remain bound to their draft.");
}

void PrimaryControlsStayAboveTheFold()
{
    var dashboard = WorkspaceDocument("RecordDashboardView.xaml");
    AssertDocumentContains(dashboard, "StatusText");
    AssertDocumentContains(dashboard, "ElapsedText");
    AssertDocumentContains(dashboard, "OutputWaveformBars");
    AssertDocumentContains(dashboard, "InputWaveformBars");
    AssertDocumentContains(dashboard, "StartCommand");
    AssertDocumentContains(dashboard, "StopCommand");
}

void SourceDeviceGridHasRows()
{
    var dashboard = WorkspaceDocument("RecordDashboardView.xaml");
    var grid = dashboard.Descendants(xaml + "Grid").Single(element =>
        element.Attribute(x + "Name")?.Value == "SourceDeviceGrid");
    var rows = grid.Element(xaml + "Grid.RowDefinitions")?.Elements(xaml + "RowDefinition").Count() ?? 0;
    Equal(3, rows, "Source, device, and screen controls require three real rows to prevent overlap.");
}

void MainWindowEnforcesMinimumSize()
{
    Equal(0, mainWindow.Descendants(xaml + "TitleBar").Count(),
        "The system title bar and a client TitleBar must not render the app title twice.");
    DoesNotContain("ExtendsContentIntoTitleBar", windowCodeBehind,
        "Navigation content must begin below the standard Windows title bar.");
    Equal(0, page.Descendants(xaml + "NavigationView.PaneHeader").Count(),
        "The localized PaneTitle and a custom pane header must not render the brand twice.");
    Contains("WorkAreaWidthRatio = 0.90", windowCodeBehind, "Main window must use most of the available width.");
    Contains("WorkAreaHeightRatio = 0.88", windowCodeBehind, "Main window must use most of the available height.");
    Contains("MinimumLogicalWidth = 960", windowCodeBehind, "Main window minimum width changed.");
    Contains("MinimumLogicalHeight = 700", windowCodeBehind, "Main window minimum height changed.");
    Contains("RasterizationScale", windowCodeBehind, "Main window size must account for Windows display scaling.");
    Contains("DisplayArea.GetFromWindowId", windowCodeBehind, "Main window must stay inside the working area.");
    Contains("Activated += OnFirstActivated", windowCodeBehind, "DPI sizing must wait until XamlRoot has a real scale.");
}

void AppEnforcesSingleInstance()
{
    Contains("AppInstance.FindOrRegisterForKey", appCodeBehind,
        "Startup must register one stable Windows App SDK instance key.");
    Contains("RedirectActivationToAsync", appCodeBehind,
        "A secondary process must redirect activation instead of creating another recorder.");
    Contains("if (!mainInstance.IsCurrent)", appCodeBehind,
        "Only the process that owns the registered key may create the main window.");
    Contains("main.ShowAndActivate", appCodeBehind,
        "Redirected activation must restore the existing tray window.");
    Contains("internal void ShowAndActivate()", windowCodeBehind,
        "The primary window must expose a dispatcher-safe restore action.");
}

void ExistingCommandsRemainWired()
{
    var expectedCommands = new[]
    {
        "StartCommand",
        "StopCommand",
        "StartTestCommand",
        "SaveDiagnosticsCommand",
        "OpenDiagnosticsFolderCommand",
        "RefreshDevicesCommand",
        "RefreshLibraryCommand",
        "PlayCommand",
        "PauseCommand",
        "StopPlaybackCommand",
        "SaveLibraryMetadataCommand",
        "OpenLibraryFolderCommand",
        "RequestRecycleLibraryCommand",
        "ConfirmRecycleLibraryCommand",
        "CancelRecycleLibraryCommand",
        "EnableTeamsAutomaticRecordingCommand",
        "DisableTeamsAutomaticRecordingCommand",
        "ToggleLocalMicrophoneMuteCommand",
        "TestOpenAiProviderConnectionCommand",
    };

    var values = AllWorkspaceDocuments().SelectMany(document => document.Descendants().Attributes()).Select(attribute => attribute.Value).ToArray();
    foreach (var command in expectedCommands)
    {
        if (!values.Contains($"{{Binding {command}}}", StringComparer.Ordinal))
        {
            throw new InvalidOperationException($"The existing {command} binding was lost.");
        }
    }
}

void TeamsRuntimeUsesLocalMonitoring()
{
    var start = viewModelCode.IndexOf("private async Task InitializeLocalTeamsAutomationAsync()", StringComparison.Ordinal);
    var end = viewModelCode.IndexOf("private async Task DisposeLocalTeamsAutomationAsync()", start + 1, StringComparison.Ordinal);
    if (start < 0 || end <= start)
    {
        throw new InvalidOperationException("The local Teams automation startup boundary is missing.");
    }
    var runtimeStartup = viewModelCode[start..end];

    DoesNotContain("new TeamsThirdPartyApiClient", runtimeStartup,
        "The retired Teams WebSocket client must not be constructed by WinUI.");
    DoesNotContain("new TeamsMuteSyncCoordinator", runtimeStartup,
        "The retired Teams mute coordinator must not be constructed by WinUI.");
    Contains("new TeamsLocalHeuristicAutoStartHost", runtimeStartup,
        "WinUI must create the local WASAPI Teams heuristic host.");
    Contains("RevokeLocalTeamsAutomationConsentAsync", viewModelCode,
        "Withdrawing local monitoring consent must disable the automatic recorder.");
    DoesNotContain("new TeamsLocalMeetingMonitor", runtimeStartup,
        "The disabled UI Automation meeting monitor must not drive the product runtime.");
    DoesNotContain("new TeamsLocalIntegrationCoordinator", runtimeStartup,
        "The retired Teams mute integration must not drive the product runtime.");
    Contains("ClearRetiredTeamsPairingCredentialAsync", viewModelCode,
        "Startup must clear the retired pairing credential without reading it.");
    var pageText = page.ToString(SaveOptions.DisableFormatting);
    DoesNotContain("Teams 配對成功", pageText,
        "Settings must not instruct users to complete the retired pairing flow.");
    DoesNotContain("已配對的真實 Teams 會議", pageText,
        "Teams preview guidance must describe local meeting-surface validation.");
}

void OverlayVideoToggleIsSafe()
{
    var toggle = overlay.Descendants(xaml + "ToggleSwitch").Single(element =>
        element.Attribute("AutomationProperties.AutomationId")?.Value == "TeamsWindowCaptureToggle");
    Equal("OnTeamsWindowCaptureToggleToggled", toggle.Attribute("Toggled")?.Value,
        "The overlay toggle must route through its guarded handler.");
    Contains("isApplyingPresentation", overlayCode,
        "Programmatic overlay refresh must not trigger a native video transition.");
    Contains("TeamsWindowCaptureToggleRequested", codeBehind,
        "The page must subscribe to the overlay video request.");
    Contains("SetTeamsWindowCaptureDuringRecordingAsync", viewModelCode,
        "The overlay must use the recording-lifecycle dynamic video API.");
    Contains("videoToggleRequestGate.WaitAsync(0)", viewModelCode,
        "Repeated overlay clicks must be coalesced before waiting for the lifecycle gate.");
    Contains("DisableVideoTargetAsync", viewModelCode,
        "Disabling pixels must keep the existing audio/MP4 session alive.");
}

void ControlRuntimeLifecycleIsBounded()
{
    Contains("new RecorderControlServerRuntime", viewModelCode,
        "Application startup must create the local control runtime.");
    var constructorStart = viewModelCode.IndexOf("public RecordingViewModel()", StringComparison.Ordinal);
    var initializationStart = viewModelCode.IndexOf("public async Task InitializeAsync()", StringComparison.Ordinal);
    var controlStart = viewModelCode.IndexOf("StartRecorderControlRuntime();", constructorStart, StringComparison.Ordinal);
    if (constructorStart < 0 || initializationStart < 0 || controlStart < constructorStart || controlStart > initializationStart)
    {
        throw new InvalidOperationException("The local control runtime must start before asynchronous initialization.");
    }
    Contains("AppRunning: !isShuttingDown", viewModelCode,
        "Status must report the live process during bounded initialization.");
    Contains("WaitAsync(TeamsPlaybackEndpointProbeTimeout)", viewModelCode,
        "The advisory Teams endpoint probe must not block recorder readiness indefinitely.");
    Contains("teamsPlaybackEndpointProbeTask ??=", viewModelCode,
        "A timed-out advisory probe must be reused rather than leaking repeated blocked workers.");
    Contains("await RecoverAtStartupAsync();", viewModelCode,
        "Safety-critical evidence recovery must complete before recorder readiness.");
    Contains("_ = RefreshLibraryAfterInitializationAsync();", viewModelCode,
        "Decode-validated library projection must load without blocking recorder readiness.");
    Contains("StopRecorderControlInBackgroundAsync", viewModelCode,
        "A pipe Stop must queue durable finalization without holding the request open past its deadline.");
    Contains("recorderControlStopTask is { IsCompleted: false }", viewModelCode,
        "Status must remain available and report the asynchronous stop operation.");
    Contains("await StopRecorderControlRuntimeAsync();", viewModelCode,
        "Application shutdown must stop the local control runtime.");
    Contains("RunRecordingLifecycleActionAsync", viewModelCode,
        "UI and pipe actions must share a lifecycle gate.");
    Contains("DispatcherQueue", controlAdapterCode,
        "The pipe owner adapter must marshal work to the WinUI dispatcher.");
    Contains("return lifecycle.GetRecorderControlStatusAsync(cancellationToken);", controlAdapterCode,
        "Read-only status must bypass a busy UI dispatcher during initialization.");
    Contains("requestGate", controlAdapterCode,
        "The pipe owner adapter must serialize dispatched requests.");

    var stopPipe = viewModelCode.IndexOf("await StopRecorderControlRuntimeAsync();", StringComparison.Ordinal);
    var finalize = viewModelCode.IndexOf("FinalizeForRecoveryAsync", StringComparison.Ordinal);
    if (stopPipe < 0 || finalize < 0 || stopPipe > finalize)
    {
        throw new InvalidOperationException("The pipe must stop before recorder finalization begins.");
    }
}

void ControlStatusIsPrivate()
{
    var statusStart = viewModelCode.IndexOf("GetRecorderControlStatusAsync", StringComparison.Ordinal);
    var statusEnd = viewModelCode.IndexOf("StartRecorderControlAsync", statusStart, StringComparison.Ordinal);
    if (statusStart < 0 || statusEnd < statusStart)
    {
        throw new InvalidOperationException("The control status projection is missing.");
    }

    var status = viewModelCode[statusStart..statusEnd].ToLowerInvariant();
    foreach (var forbidden in new[] { "errorText", "path", "pid", "hwnd", "folder", "processid" })
    {
        DoesNotContain(forbidden, status, $"Control status must not expose '{forbidden}'.");
    }
}

void ControlsAreRoutedToTheirWorkspace()
{
    var record = WorkspaceDocument("RecordDashboardView.xaml");
    foreach (var required in new[] { "RefreshTeamsWindowsCommand", "TeamsCaptureWindows", "SelectedVideoCaptureWindow", "ScreenCaptureTargetSelector", "ScreenCaptureRefreshButton" })
        AssertDocumentContains(record, required);

    var recordings = WorkspaceDocument("RecordingLibraryView.xaml");
    foreach (var binding in new[] { "PlayCommand", "PauseCommand", "StopPlaybackCommand", "SkipBackward15Command", "SkipForward15Command", "PlaybackPositionSeconds, Mode=TwoWay", "PlaybackVolume, Mode=TwoWay", "SelectedPlaybackRate, Mode=TwoWay", "IsVideoPlaybackStageVisible", "IsAudioPlaybackStageVisible", "PlaybackPlayButton", "PlaybackPauseButton", "PlaybackStopButton", "LibraryLoadingText" })
        AssertDocumentContains(recordings, binding);
    _ = recordings.Descendants().Single(element => element.Name.LocalName == "MediaPlayerElement");
    Contains("PlaybackVideoStage.SetMediaPlayer(player)", recordingLibraryCode,
        "Audio and video playback must use the in-app shared media player.");
    Contains("verifiedVideoCapturePipeline: true", viewModelCode,
        "The production Windows shell must opt into its bundled exact-window WGC pipeline.");

    var ai = WorkspaceDocument("AiWorkspaceView.xaml");
    foreach (var required in new[] { "CanStartOpenAiTranscription", "CanGenerateOpenAiSummary", "OnStartTranscriptionClick", "OnGenerateSummaryClick" })
        AssertDocumentContains(ai, required);

    var settings = WorkspaceDocument("RecorderSettingsView.xaml");
    foreach (var required in new[] { "SettingsEnableLocalTeamsHeuristicCheckBox", "SettingsOpenAiApiKeyPasswordBox", "SettingsSaveDiagnosticsButton" })
        AssertDocumentContains(settings, required);
}

void AutomationIdentifiersAreUnique()
{
    var identifiers = AllWorkspaceDocuments()
        .SelectMany(document => document.Descendants())
        .Select(element => element.Attribute("AutomationProperties.AutomationId")?.Value)
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Cast<string>()
        .ToArray();
    var duplicates = identifiers
        .GroupBy(value => value, StringComparer.Ordinal)
        .Where(group => group.Count() > 1)
        .Select(group => group.Key)
        .ToArray();

    if (duplicates.Length > 0)
    {
        throw new InvalidOperationException($"Duplicate AutomationIds: {string.Join(", ", duplicates)}");
    }

    foreach (var required in new[] { "WorkspaceNavigation", "NavigationRecord", "NavigationRecordings", "NavigationAI", "NavigationSettings" })
    {
        _ = SingleByAutomationId(required);
    }
}

void LocaleResourcesStayInSync()
{
    var traditionalChinese = ReadResourceKeys(Path.Combine(fixtureRoot, "zh-Hant", "Resources.resw"));
    var english = ReadResourceKeys(Path.Combine(fixtureRoot, "en-US", "Resources.resw"));
    SequenceEqual(traditionalChinese, english, "Locale resource keys differ.");

    var uids = AllWorkspaceDocuments().SelectMany(document => document.Descendants())
        .Select(element => element.Attribute(x + "Uid")?.Value)
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Cast<string>();
    foreach (var uid in uids)
    {
        if (!traditionalChinese.Any(key => key.StartsWith(uid + ".", StringComparison.Ordinal)))
        {
            throw new InvalidOperationException($"No localized property exists for x:Uid '{uid}'.");
        }
    }
}

void CustomThemeResourcesResolve()
{
    var design = XDocument.Load(Path.Combine(fixtureRoot, "Styles", "RecorderDesign.xaml"));
    var defined = design.Descendants()
        .Select(element => element.Attribute(x + "Key")?.Value)
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Cast<string>()
        .ToHashSet(StringComparer.Ordinal);

    foreach (var value in AllWorkspaceDocuments()
        .SelectMany(document => document.Descendants().Attributes())
        .Select(attribute => attribute.Value))
    {
        const string marker = "{ThemeResource Recorder";
        var start = value.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0)
        {
            continue;
        }

        var keyStart = start + "{ThemeResource ".Length;
        var keyEnd = value.IndexOf('}', keyStart);
        var key = keyEnd > keyStart ? value[keyStart..keyEnd] : string.Empty;
        if (!defined.Contains(key))
        {
            throw new InvalidOperationException($"Theme resource '{key}' is referenced but not defined.");
        }
    }
}

void AudioOnlyMp4UsesAudioStage()
{
    Contains("public bool IsVideo => string.Equals(MediaKind, \"video\"", viewModelCode,
        "Playback stage must follow canonical mediaKind metadata.");
    DoesNotContain("Path.GetExtension(MediaPath)", viewModelCode,
        "An AAC-only MP4 must not be misclassified as video by its extension.");
}

void OverlayStatesAreComplete()
{
    foreach (var mode in new[] { "Countdown", "Recording", "Finalizing" })
    {
        Contains(mode, overlayPresentationCode, $"Overlay state contract must include {mode}.");
    }

    foreach (var automationId in new[]
    {
        "ElapsedText", "SystemWaveform", "MicrophoneWaveform",
        "RecorderMicrophoneMuteButton", "TeamsWindowCaptureToggle", "StatusDetailText",
        "RecordingOverlayLifecycleActionButton",
    })
    {
        _ = SingleByAutomationIdOrName(overlay, automationId);
    }

    Contains("RecorderMicrophoneMuteToggleRequested", overlayPresentationCode, "Overlay microphone mute must be recorder-local.");
    Contains("SystemAudioLevelPercent", overlayPresentationCode, "Overlay must carry the measured system-audio level.");
    Contains("MicrophoneLevelPercent", overlayPresentationCode, "Overlay must carry the measured microphone level.");
    Contains("IsVirtualMicrophoneReady", overlayPresentationCode, "Overlay must expose virtual-microphone readiness.");
    Contains("presentation.MicrophoneLevelPercent", overlayCode, "Overlay waveform must use the measured microphone level.");
    Contains("Recorder 與虛擬麥克風", overlayCode, "The mute control must describe both affected microphone paths.");
    DoesNotContain("WaveformValue(", overlayCode, "Overlay must not render a synthetic fixed waveform.");
    DoesNotContain("TeamsMute", overlayCode, "Overlay must not synchronize Teams mute.");
    Contains("IsAlwaysOnTop = true", overlayCode, "Overlay must stay on top.");
    Contains("WsExNoActivate", overlayCode, "Overlay must not activate.");
    Contains("SwpNoActivate", overlayCode, "Overlay must show without activation.");
    Contains("SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false)", overlayCode, "Overlay needs a resize border without exposing a close title bar.");
    Contains("args.Cancel = true", overlayCode, "Overlay close must be rejected until controlled shutdown.");
    Contains("ActionButton.IsEnabled = !isFinalizing", overlayCode, "Finalizing must lock the overlay action.");
    Contains("ActionButton.Content = isRecording ? \"停止錄音\"", overlayCode,
        "The active overlay must expose an explicit stop-recording action.");
    Contains("presentation.Mode == RecordingOverlayMode.Recording", overlayCode,
        "The lifecycle action must route by state rather than localized button text.");
    Contains("TeamsWindowCaptureToggle.IsEnabled = isRecording", overlayCode, "Capture toggle must be editable only while active.");
}

void TeamsWindowTargetRefreshIsBounded()
{
    var toggleStart = viewModelCode.IndexOf("SetTeamsWindowCaptureDuringRecordingAsync", StringComparison.Ordinal);
    var toggleEnd = viewModelCode.IndexOf("public bool IsTeamsAutomaticRecordingCountdownVisible", toggleStart, StringComparison.Ordinal);
    if (toggleStart < 0 || toggleEnd < toggleStart)
        throw new InvalidOperationException("The dynamic Teams capture action is missing.");
    var toggle = viewModelCode[toggleStart..toggleEnd];
    Contains("await RefreshTeamsWindowsCoreAsync();", toggle,
        "Turning on capture during a recording must refresh a newly-created Teams meeting window first.");
    Contains("SetVideoTargetAsync(selected)", toggle,
        "The refreshed target must still receive lifecycle exact-identity validation.");

    var start = viewModelCode.IndexOf("private async Task<RecordingCoordinatorSnapshot> StartRecordingAsync", StringComparison.Ordinal);
    var resolve = viewModelCode.IndexOf("private VideoCaptureTarget? SelectedVideoTargetOrNull", start, StringComparison.Ordinal);
    if (start < 0 || resolve < start)
        throw new InvalidOperationException("The recording start path is missing.");
    var recordingStart = viewModelCode[start..resolve];
    var refresh = recordingStart.IndexOf("await RefreshTeamsWindowsCoreAsync();", StringComparison.Ordinal);
    var target = recordingStart.IndexOf("SelectedVideoTargetOrNull()", StringComparison.Ordinal);
    if (refresh < 0 || target < refresh)
        throw new InvalidOperationException("Recording start must refresh Teams windows before resolving the exact capture target.");

    Contains("RetainOrSelectCurrent(previous, targets)", viewModelCode,
        "A stale selected HWND must be replaced only from the admitted current Teams catalog.");
}

void OverlayIsDpiAwareAndResizable()
{
    Contains("GetDpiForWindow", overlayCode, "Overlay physical pixels must be scaled from WinUI DIPs at the active monitor DPI.");
    Contains("ScaleForDpi", overlayCode, "Overlay sizing needs one tested DPI conversion policy.");
    Contains("MinimumWidthDips", overlayCode, "Overlay must enforce a readable minimum width.");
    Contains("MinimumHeightDips", overlayCode, "Overlay must enforce a readable minimum height.");
    Contains("presenter.IsResizable = true", overlayCode, "Users must be able to enlarge the floating controller.");
    DoesNotContain("AppWindow.Resize(new SizeInt32(448, 276))", overlayCode, "A fixed physical-pixel size clips the overlay above 100% display scaling.");
}

XElement SingleByName(string name) =>
    page.Descendants().Single(element => element.Attribute(x + "Name")?.Value == name);

XElement SingleByAutomationId(string automationId) =>
    page.Descendants().Single(element => element.Attribute("AutomationProperties.AutomationId")?.Value == automationId);

XElement SingleByAutomationIdOrName(XDocument document, string identifier) =>
    document.Descendants().Single(element =>
        element.Attribute("AutomationProperties.AutomationId")?.Value == identifier ||
        element.Attribute(x + "Name")?.Value == identifier);

XDocument WorkspaceDocument(string fileName) =>
    XDocument.Load(Path.Combine(fixtureRoot, "Views", fileName));

IEnumerable<XDocument> AllWorkspaceDocuments()
{
    yield return page;
    foreach (var path in Directory.EnumerateFiles(Path.Combine(fixtureRoot, "Views"), "*.xaml", SearchOption.AllDirectories))
    {
        yield return XDocument.Load(path);
    }
}

static void AssertDocumentContains(XDocument document, string expected)
{
    if (!document.ToString(SaveOptions.DisableFormatting).Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"The view must contain {expected}.");
    }
}

static string[] ReadResourceKeys(string path) =>
    XDocument.Load(path)
        .Descendants("data")
        .Select(element => element.Attribute("name")?.Value)
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Cast<string>()
        .Order(StringComparer.Ordinal)
        .ToArray();

static void Equal<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{message} Expected '{expected}', got '{actual}'.");
    }
}

static void SequenceEqual<T>(IEnumerable<T> expected, IEnumerable<T> actual, string message)
{
    if (!expected.SequenceEqual(actual))
    {
        throw new InvalidOperationException(message);
    }
}

static void Contains(string expected, string actual, string message)
{
    if (!actual.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(message);
    }
}

static void DoesNotContain(string unexpected, string actual, string message)
{
    if (actual.Contains(unexpected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(message);
    }
}
