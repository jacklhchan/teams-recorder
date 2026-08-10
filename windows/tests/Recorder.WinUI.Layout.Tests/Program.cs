using System.Xml.Linq;

var fixtureRoot = Path.Combine(AppContext.BaseDirectory, "Fixtures");
var page = XDocument.Load(Path.Combine(fixtureRoot, "MainPage.xaml"));
var codeBehind = File.ReadAllText(Path.Combine(fixtureRoot, "MainPage.xaml.cs"));
var windowCodeBehind = File.ReadAllText(Path.Combine(fixtureRoot, "MainWindow.xaml.cs"));
var viewModelCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecordingViewModel.cs"));
var overlay = XDocument.Load(Path.Combine(fixtureRoot, "RecordingOverlayWindow.xaml"));
var overlayCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecordingOverlayWindow.xaml.cs"));
var controlAdapterCode = File.ReadAllText(Path.Combine(fixtureRoot, "RecorderControlLifecycleOwnerAdapter.cs"));
var xaml = (XNamespace)"http://schemas.microsoft.com/winfx/2006/xaml/presentation";
var x = (XNamespace)"http://schemas.microsoft.com/winfx/2006/xaml";

var tests = new (string Name, Action Run)[]
{
    ("shell exposes exactly three stable workspace routes", WorkspaceRoutesAreStable),
    ("record is the default workspace", RecordIsDefault),
    ("primary recording state and actions stay above the record scroller", PrimaryControlsStayAboveTheFold),
    ("main window enforces the 860 by 680 minimum", MainWindowEnforcesMinimumSize),
    ("existing view-model command surface remains wired", ExistingCommandsRemainWired),
    ("recordings and settings own their existing controls", ControlsAreRoutedToTheirWorkspace),
    ("automation identifiers are unique and stable", AutomationIdentifiersAreUnique),
    ("English and Traditional Chinese resources stay in sync", LocaleResourcesStayInSync),
    ("Teams runtime uses local monitoring and retires WebSocket construction", TeamsRuntimeUsesLocalMonitoring),
    ("recording overlay owns a safe dynamic Teams video toggle", OverlayVideoToggleIsSafe),
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
    SequenceEqual(new[] { "Record", "Recordings", "Settings" }, routes, "Unexpected workspace route order.");
}

void RecordIsDefault()
{
    Equal("Visible", SingleByName("RecordWorkspace").Attribute("Visibility")?.Value ?? "Visible", "Record must be visible by default.");
    Equal("Collapsed", SingleByName("RecordingsWorkspace").Attribute("Visibility")?.Value, "Recordings must start collapsed.");
    Equal("Collapsed", SingleByName("SettingsWorkspace").Attribute("Visibility")?.Value, "Settings must start collapsed.");
    Contains("WorkspaceNavigation.SelectedItem = RecordNavigationItem;", codeBehind, "Code-behind must select Record after XAML initialization.");
}

void PrimaryControlsStayAboveTheFold()
{
    var criticalControls = new[]
    {
        "RecordingStatusText",
        "ElapsedText",
        "StartRecordingButton",
        "StopRecordingButton",
        "OutputWaveform",
        "InputWaveform",
    };

    foreach (var automationId in criticalControls)
    {
        var control = SingleByAutomationId(automationId);
        if (control.Ancestors(xaml + "ScrollViewer").Any())
        {
            throw new InvalidOperationException($"{automationId} must remain outside the configuration ScrollViewer.");
        }

        if (!control.AncestorsAndSelf().Any(element => element.Attribute(x + "Name")?.Value == "RecordWorkspace"))
        {
            throw new InvalidOperationException($"{automationId} must belong to RecordWorkspace.");
        }
    }
}

void MainWindowEnforcesMinimumSize()
{
    Contains("presenter.PreferredMinimumWidth = 860;", windowCodeBehind, "Main window minimum width changed.");
    Contains("presenter.PreferredMinimumHeight = 680;", windowCodeBehind, "Main window minimum height changed.");
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
        "RefreshProcessCatalogCommand",
        "RefreshTeamsWindowsCommand",
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

    var values = page.Descendants().Attributes().Select(attribute => attribute.Value).ToArray();
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
    Contains("StartRecorderControlRuntime();", viewModelCode,
        "Application initialization must start the local control runtime.");
    Contains("await StopRecorderControlRuntimeAsync();", viewModelCode,
        "Application shutdown must stop the local control runtime.");
    Contains("RunRecordingLifecycleActionAsync", viewModelCode,
        "UI and pipe actions must share a lifecycle gate.");
    Contains("DispatcherQueue", controlAdapterCode,
        "The pipe owner adapter must marshal work to the WinUI dispatcher.");
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
    AssertInsideWorkspace("RecordingLibraryList", "RecordingsWorkspace");
    AssertInsideWorkspace("PlaybackSlider", "RecordingsWorkspace");
    AssertInsideWorkspace("StartTranscriptionButton", "RecordingsWorkspace");
    AssertInsideWorkspace("EnableLocalTeamsHeuristicCheckBox", "SettingsWorkspace");
    AssertInsideWorkspace("OpenAiApiKeyPasswordBox", "SettingsWorkspace");
    AssertInsideWorkspace("SaveDiagnosticsButton", "SettingsWorkspace");
}

void AutomationIdentifiersAreUnique()
{
    var identifiers = page
        .Descendants()
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

    foreach (var required in new[] { "WorkspaceNavigation", "NavigationRecord", "NavigationRecordings", "NavigationSettings" })
    {
        _ = SingleByAutomationId(required);
    }
}

void LocaleResourcesStayInSync()
{
    var traditionalChinese = ReadResourceKeys(Path.Combine(fixtureRoot, "zh-Hant", "Resources.resw"));
    var english = ReadResourceKeys(Path.Combine(fixtureRoot, "en-US", "Resources.resw"));
    SequenceEqual(traditionalChinese, english, "Locale resource keys differ.");

    var uids = page.Descendants()
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

void AssertInsideWorkspace(string automationId, string workspaceName)
{
    var element = SingleByAutomationId(automationId);
    if (!element.AncestorsAndSelf().Any(ancestor => ancestor.Attribute(x + "Name")?.Value == workspaceName))
    {
        throw new InvalidOperationException($"{automationId} is not inside {workspaceName}.");
    }
}

XElement SingleByName(string name) =>
    page.Descendants().Single(element => element.Attribute(x + "Name")?.Value == name);

XElement SingleByAutomationId(string automationId) =>
    page.Descendants().Single(element => element.Attribute("AutomationProperties.AutomationId")?.Value == automationId);

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
