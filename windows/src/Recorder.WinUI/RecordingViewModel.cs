using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Control;
using TeamsRecorder.Windows.Application.Diagnostics;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Settings;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;
using TeamsRecorder.Windows.Application.VirtualMic;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.ApplicationModel.DataTransfer;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Keeps device choice, native recording lifecycle, session publication, and
/// local playback at the WinUI edge. The coordinator remains the single owner
/// of native start/stop serialization.
/// </summary>
public sealed class RecordingViewModel : INotifyPropertyChanged, IRecordingOverlayStateSource, IRecorderControlViewModelLifecycle
{
    private const int WaveformBarCount = 48;
    private static readonly TimeSpan TeamsPlaybackEndpointProbeTimeout = TimeSpan.FromSeconds(2);
    private static readonly Brush HealthyHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.ForestGreen);
    private static readonly Brush WarningHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.DarkOrange);
    private static readonly Brush RecoveredHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.Goldenrod);
    private static readonly Brush NeutralHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.Gray);
    private readonly DispatcherQueue dispatcherQueue;
    private readonly DispatcherQueueTimer telemetryTimer;
    private readonly DispatcherQueueTimer playbackTimer;
    private readonly DispatcherQueueTimer teamsLocalHeuristicTimer;
    private readonly DispatcherQueueTimer inputMuteTimer;
    private readonly DispatcherQueueTimer teamsMuteFollowTimer;
    // RecordingLifecycleService keeps native capture, the temporary session plan,
    // and final publication in the Application layer.  This VM only maps that
    // state to WinUI properties and commands.
    private RecordingLifecycleService? recordingLifecycle;
    private NativeRecorderBridge? nativeRecorderBridge;
    private VirtualMicPublisherRuntime? virtualMicPublisher;
    private readonly IProcessCatalog processCatalog = new ProcessCatalog();
    private readonly IVideoCaptureTargetCatalog videoTargetCatalog = new WindowsVideoCaptureTargetCatalog();
    private RecordingLibraryService? libraryService;
    private string? libraryServiceRoot;
    private readonly IRecorderAppSettingsStore appSettingsStore = new JsonRecorderAppSettingsStore();
    private readonly SemaphoreSlim appSettingsWriteGate = new(1, 1);
    // UI actions, automatic-recording callbacks, and local control-pipe
    // requests all acquire this same gate before changing recorder lifecycle.
    // RecordingLifecycleService remains the durable/native serialization owner.
    private readonly SemaphoreSlim recordingLifecycleActionGate = new(1, 1);
    private readonly SemaphoreSlim videoToggleRequestGate = new(1, 1);
    private RecorderAppSettings? pendingAppSettings;
    private string? pendingSelectedApplicationExecutable;
    private bool restoreTeamsAutomaticRecordingAfterInitialization;
    // AI provider settings are deliberately application-layer services. The view model
    // owns no persisted API key: the repository keeps it separately in per-user DPAPI.
    private OpenAICompatibleProviderRepository? openAiProviderRepository;
    private OpenAICompatibleAsrHttpTransport? openAiAsrTransport;
    private OpenAICompatibleProviderConnectionClient? openAiProviderConnectionClient;
    private RecordingSessionAsrJobCoordinator? transcriptionCoordinator;
    private OpenAICompatibleMeetingIntelligenceClient? meetingIntelligenceClient;
    private MeetingIntelligenceSessionCoordinator? meetingIntelligenceCoordinator;
    private long aiWorkspaceLoadGeneration;
    private string transcriptText = string.Empty;
    private string meetingIntelligenceSummary = string.Empty;
    private string meetingIntelligenceSuggestedTitle = string.Empty;
    private string meetingIntelligenceStatus = "請選取有逐字稿的錄音。";
    private bool hasLoadedTranscript;
    private RecordingCoordinatorSnapshot snapshot = RecordingCoordinatorSnapshot.Initial;
    private MediaPlayer? mediaPlayer;
    private EndpointChoice? selectedRenderEndpoint;
    private EndpointChoice? selectedMicrophoneEndpoint;
    private CaptureSourceChoice? selectedCaptureSource;
    private ProcessSelectionChoice? selectedProcess;
    private VideoCaptureWindowChoice? selectedVideoCaptureWindow;
    private bool isSharedContentCaptureEnabled;
    private bool isTeamsWindowCaptureEnabled;
    private bool isTeamsWindowCaptureToggleInProgress;
    private string? teamsWindowCaptureStatus;
    private LibraryRecording? selectedLibraryItem;
    private readonly List<LibraryRecording> allLibraryItems = [];
    private RecordingLibrarySessionIdentity? pendingRecycleIdentity;
    private string? pendingRecycleDisplayName;
    private long librarySelectionGeneration;
    private string? loadedPlaybackPath;
    private string outputFolder;
    private string nextOutputPath = "開始錄製後會建立 crash-safe MP4 工作階段。";
    private string lastResultText = "尚未完成新的錄製工作階段。";
    private string statusText = "正在準備錄音元件…";
    private string? errorText;
    private DateTimeOffset? recordingStartedAt;
    private TimeSpan elapsed;
    private StorageCapacityStatus? storageCapacity;
    private bool storageCanStart;
    private bool isBusy;
    private bool isLibraryLoading;
    private bool isInitialized;
    private bool isInitializing;
    private bool isRecorderAvailable;
    private bool isShuttingDown;
    private bool isTelemetryRefreshInProgress;
    private bool isLowStorageStopInProgress;
    private bool isLowStorageVideoDowngradeInProgress;
    private DateTimeOffset nextStorageCapacityCheckUtc;
    private bool isFaultFinalizationInProgress;
    private bool isUpdatingPlaybackPosition;
    private double playbackProgress;
    private double playbackPositionSeconds;
    private double playbackDurationSeconds;
    private double playbackVolume = 1d;
    private double selectedPlaybackRate = 1d;
    private string playbackText = "請從錄音庫選取有效的 MP4 或舊版 M4A 檔案。";
    private string librarySearchText = string.Empty;
    private bool libraryFavoritesOnly;
    private string libraryTitle = string.Empty;
    private string libraryTagsText = string.Empty;
    private bool isLibraryFavorite;
    private bool isRecycleConfirmationVisible;
    private readonly InputMuteCoordinator recorderMicrophoneMute = new();
    private readonly WindowsInputMuteMonitor inputMuteMonitor = new();
    private bool isInputMuteRefreshInProgress;
    private string? monitoredInputEndpointId;
    private readonly ITeamsMuteFollowProbe teamsMuteFollowProbe = new WindowsTeamsMuteFollowProbe();
    private bool isTeamsMuteFollowRefreshInProgress;
    private bool isFollowTeamsMuteEnabled;
    private int teamsMuteFollowRevision;
    private TeamsMuteFollowObservation teamsMuteFollowObservation = TeamsMuteFollowObservation.NotInCall;
    private TeamsAutomaticRecordingController? teamsAutomaticRecorder;
    private TeamsLocalHeuristicAutoStartHost? teamsLocalHeuristicHost;
    private TeamsLocalMeetingSnapshot? teamsLocalHeuristicSnapshot;
    private bool isLocalHeuristicAutoStartEnabled;
    private int localTeamsAutomationConsentRevision;
    private RecorderControlLifecycleOwnerAdapter? recorderControlOwner;
    private RecorderControlServerRuntime? recorderControlRuntime;
    private Task? recorderControlStopTask;
    private TeamsAutoMeetingSnapshot teamsAutomaticSnapshot = TeamsAutoMeetingSnapshot.Initial;
    private bool isTeamsAutomaticRecordingOperationInProgress;
    private WindowsGlobalHotKeyRegistrar? globalHotKeyRegistrar;
    private GlobalMuteHotKeyService? globalMuteHotKey;
    private string processCatalogStatusText = "選擇「指定應用程式」後，按一下重新整理以列出可選程序。";
    private string globalMuteHotKeyStatus = "正在準備 Ctrl+Alt+M 全域麥克風靜音快捷鍵。";
    private readonly string diagnosticsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Teams Recorder",
        "Diagnostics");
    private string diagnosticsExportStatusText = "診斷報告會儲存在本機的 Teams Recorder\\Diagnostics 資料夾。";
    private string virtualMicrophoneStatusText = "虛擬麥克風預覽尚未初始化。";
    private string openAiApiBaseUrl = "https://api.openai.com/v1";
    private AIProviderKindChoice selectedOpenAiProviderKind = AIProviderKindChoice.OpenAICompatible;
    private string openAiHktGroupId = string.Empty;
    private string openAiAsrModel = "gpt-4o-transcribe";
    private string openAiLlmModel = "gpt-5.6-terra";
    private string openAiLanguage = "zh";
    private string openAiPrompt = "";
    private string openAiMeetingIntelligencePrompt = "";
    private string openAiApiKeyReplacement = "";
    private readonly Dictionary<AIProviderKind, AiProviderEditorDraft> openAiProviderDrafts = new()
    {
        [AIProviderKind.OpenAICompatible] = AiProviderEditorDraft.GenericDefault,
        [AIProviderKind.HktGenAI] = AiProviderEditorDraft.HktDefault,
    };
    private readonly Dictionary<AIProviderKind, bool> openAiProviderApiKeyPresence = new()
    {
        [AIProviderKind.OpenAICompatible] = false,
        [AIProviderKind.HktGenAI] = false,
    };
    private bool isApplyingOpenAiProviderDraft;
    private bool isOpenAiProviderInitialized;
    private bool hasOpenAiApiKey;
    private bool isTestingOpenAiProvider;
    private string openAiProviderIntegrationStatus = "正在準備本機 OpenAI 相容 API 設定。";
    // Endpoint IDs stay in memory only. They are used solely to compare the
    // active Windows Teams audio session with the current loopback choice.
    private TeamsPlaybackEndpointObservation teamsPlaybackEndpointObservation = TeamsPlaybackEndpointObservation.Unknown;
    private Task<NativeTeamsRenderEndpointProbeResult>? teamsPlaybackEndpointProbeTask;
    private string? windowsConsoleDefaultRenderEndpointId;
    private long? pendingTestPlaybackGeneration;

    public RecordingViewModel()
    {
        dispatcherQueue = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Teams Recorder 必須在 WinUI 執行緒上建立。");
        telemetryTimer = dispatcherQueue.CreateTimer();
        // The native bridge publishes compact level envelopes, so a 10 Hz UI
        // refresh gives a useful live waveform without moving raw PCM across
        // the C ABI or blocking the audio mixer.
        telemetryTimer.Interval = TimeSpan.FromMilliseconds(100);
        telemetryTimer.Tick += OnTelemetryTimerTick;
        playbackTimer = dispatcherQueue.CreateTimer();
        playbackTimer.Interval = TimeSpan.FromMilliseconds(250);
        playbackTimer.Tick += (_, _) => UpdatePlaybackPosition();
        teamsLocalHeuristicTimer = dispatcherQueue.CreateTimer();
        teamsLocalHeuristicTimer.Interval = TimeSpan.FromSeconds(2);
        teamsLocalHeuristicTimer.Tick += OnTeamsLocalHeuristicTimerTick;
        inputMuteTimer = dispatcherQueue.CreateTimer();
        inputMuteTimer.Interval = TimeSpan.FromMilliseconds(500);
        inputMuteTimer.Tick += OnInputMuteTimerTick;
        teamsMuteFollowTimer = dispatcherQueue.CreateTimer();
        teamsMuteFollowTimer.Interval = TimeSpan.FromMilliseconds(500);
        teamsMuteFollowTimer.Tick += OnTeamsMuteFollowTimerTick;

        outputFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Teams Recorder",
            "Sessions");

        StartCommand = new AsyncRelayCommand(StartAsync, () => CanStart);
        StopCommand = new AsyncRelayCommand(StopAsync, () => CanStop);
        StartTestCommand = new AsyncRelayCommand(StartTestAsync, () => CanStart);
        SaveDiagnosticsCommand = new AsyncRelayCommand(SaveDiagnosticsAsync, () => CanSaveDiagnostics);
        OpenDiagnosticsFolderCommand = new AsyncRelayCommand(OpenDiagnosticsFolderAsync, () => CanOpenDiagnosticsFolder);
        RefreshDevicesCommand = new AsyncRelayCommand(RefreshEndpointsAsync, () => CanRefreshDevices);
        RefreshProcessCatalogCommand = new AsyncRelayCommand(RefreshProcessCatalogAsync, () => CanRefreshProcessCatalog);
        RefreshTeamsWindowsCommand = new AsyncRelayCommand(RefreshTeamsWindowsAsync, () => CanRefreshTeamsWindows);
        RefreshLibraryCommand = new AsyncRelayCommand(RefreshLibraryAsync, () => CanRefreshLibrary);
        PlayCommand = new AsyncRelayCommand(PlayAsync, () => CanPlay);
        PauseCommand = new AsyncRelayCommand(PauseAsync, () => CanPause);
        StopPlaybackCommand = new AsyncRelayCommand(StopPlaybackAsync, () => mediaPlayer is not null);
        SkipBackward15Command = new AsyncRelayCommand(() => SkipPlaybackAsync(-15), () => CanSeek);
        SkipForward15Command = new AsyncRelayCommand(() => SkipPlaybackAsync(15), () => CanSeek);
        SaveLibraryMetadataCommand = new AsyncRelayCommand(SaveLibraryMetadataAsync, () => CanManageLibrary);
        OpenLibraryFolderCommand = new AsyncRelayCommand(OpenLibraryFolderAsync, () => CanManageLibrary);
        RequestRecycleLibraryCommand = new AsyncRelayCommand(RequestRecycleLibraryAsync, () => CanManageLibrary);
        ConfirmRecycleLibraryCommand = new AsyncRelayCommand(ConfirmRecycleLibraryAsync, () => CanConfirmRecycle);
        CancelRecycleLibraryCommand = new AsyncRelayCommand(CancelRecycleLibraryAsync, () => IsRecycleConfirmationVisible);
        EnableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(EnableTeamsAutomaticRecordingAsync, () => CanEnableTeamsAutomaticRecording);
        DisableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(DisableTeamsAutomaticRecordingAsync, () => CanDisableTeamsAutomaticRecording);
        CancelTeamsAutomaticRecordingStartCommand = new AsyncRelayCommand(CancelTeamsAutomaticRecordingStartAsync, () => CanCancelTeamsAutomaticRecordingStart);
        StopRecordingFromOverlayCommand = new AsyncRelayCommand(StopRecordingFromOverlayAsync, () => CanStopRecordingFromOverlay);
        ToggleLocalMicrophoneMuteCommand = new AsyncRelayCommand(ToggleLocalMicrophoneMuteAsync, () => !isShuttingDown);
        TestOpenAiProviderConnectionCommand = new AsyncRelayCommand(TestOpenAiProviderConnectionAsync, () => CanTestOpenAiProvider);
        recorderMicrophoneMute.Changed += OnInputMuteChanged;
        CaptureSources.Add(CaptureSourceChoice.SystemAudio);
        CaptureSources.Add(CaptureSourceChoice.SelectedApplication);
        selectedCaptureSource = CaptureSourceChoice.Default;
        ResetWaveforms();
        // Keep local diagnostics/control reachable while slower endpoint,
        // recovery, library, and Teams-local initialization is still running.
        // Mutating requests remain fail-closed until isInitialized and the
        // recording lifecycle are ready.
        StartRecorderControlRuntime();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// Raised on the WinUI thread whenever the compact recording-window state changes.
    /// A presenter can subscribe instead of deriving state from unrelated VM properties.
    /// </summary>
    public event EventHandler<RecordingOverlayState>? RecordingOverlayStateChanged;

    public ObservableCollection<EndpointChoice> RenderEndpoints { get; } = [];

    public ObservableCollection<EndpointChoice> CaptureEndpoints { get; } = [];

    public ObservableCollection<CaptureSourceChoice> CaptureSources { get; } = [];

    public ObservableCollection<ProcessSelectionChoice> ProcessCatalog { get; } = [];

    public ObservableCollection<VideoCaptureWindowChoice> TeamsCaptureWindows { get; } = [];

    public ObservableCollection<LibraryRecording> LibraryItems { get; } = [];

    public IReadOnlyList<PlaybackRateChoice> PlaybackRateChoices { get; } =
    [
        new(0.5, "0.5×"),
        new(1, "1×"),
        new(1.25, "1.25×"),
        new(1.5, "1.5×"),
        new(2, "2×"),
    ];

    /// <summary>Model IDs discovered by the explicitly requested provider connection test.</summary>
    public ObservableCollection<string> OpenAiDiscoveredModels { get; } = [];

    public IReadOnlyList<AIProviderKindChoice> OpenAiProviderKinds { get; } =
        [AIProviderKindChoice.HktGenAI, AIProviderKindChoice.OpenAICompatible];

    public IReadOnlyList<string> OpenAiLanguages { get; } = ["yue", "en", "zh"];

    /// <summary>Recent post-normalization Teams/system output peaks, oldest first.</summary>
    public ObservableCollection<WaveformBar> OutputWaveformBars { get; } = [];

    /// <summary>Recent post-normalization microphone peaks, oldest first.</summary>
    public ObservableCollection<WaveformBar> InputWaveformBars { get; } = [];

    public AsyncRelayCommand StartCommand { get; }

    public AsyncRelayCommand StopCommand { get; }

    public AsyncRelayCommand StartTestCommand { get; }

    /// <summary>Exports redacted local diagnostics without copying audio or recording media.</summary>
    public AsyncRelayCommand SaveDiagnosticsCommand { get; }

    /// <summary>Opens the local folder only after a diagnostic report exists there.</summary>
    public AsyncRelayCommand OpenDiagnosticsFolderCommand { get; }

    public AsyncRelayCommand RefreshDevicesCommand { get; }

    public AsyncRelayCommand RefreshProcessCatalogCommand { get; }

    public AsyncRelayCommand RefreshTeamsWindowsCommand { get; }

    public AsyncRelayCommand RefreshLibraryCommand { get; }

    public AsyncRelayCommand PlayCommand { get; }

    public AsyncRelayCommand PauseCommand { get; }

    public AsyncRelayCommand StopPlaybackCommand { get; }

    public AsyncRelayCommand SkipBackward15Command { get; }

    public AsyncRelayCommand SkipForward15Command { get; }

    public AsyncRelayCommand SaveLibraryMetadataCommand { get; }

    public AsyncRelayCommand OpenLibraryFolderCommand { get; }

    public AsyncRelayCommand RequestRecycleLibraryCommand { get; }

    public AsyncRelayCommand ConfirmRecycleLibraryCommand { get; }

    public AsyncRelayCommand CancelRecycleLibraryCommand { get; }

    public AsyncRelayCommand EnableTeamsAutomaticRecordingCommand { get; }

    public AsyncRelayCommand DisableTeamsAutomaticRecordingCommand { get; }

    /// <summary>Cancel the pending Teams-only automatic start without disabling the opt-in.</summary>
    public AsyncRelayCommand CancelTeamsAutomaticRecordingStartCommand { get; }

    /// <summary>Stop the active capture from the compact recording window.</summary>
    public AsyncRelayCommand StopRecordingFromOverlayCommand { get; }

    public AsyncRelayCommand ToggleLocalMicrophoneMuteCommand { get; }

    public AsyncRelayCommand TestOpenAiProviderConnectionCommand { get; }

    public bool IsRecordingMicrophoneMuted => recorderMicrophoneMute.IsMuted;

    public string RecordingMicrophoneMuteText => SelectedMicrophoneEndpoint?.EndpointId is null
        ? "未選取錄音麥克風；靜音設定會在下一次選取麥克風後套用。"
        : recorderMicrophoneMute.IsTeamsMuted
            ? teamsMuteFollowObservation.State == TeamsMuteFollowState.Muted
                ? "Teams 目前為靜音；Recorder 已停止混入實體麥克風，系統輸出錄音不受影響。"
                : "暫時無法確認 Teams 靜音；Recorder 依隱私保護停止混入實體麥克風。"
        : recorderMicrophoneMute.IsInputMuted
            ? "Windows 輸入裝置目前為靜音；錄音與虛擬麥克風都保持靜音。"
        : IsRecordingMicrophoneMuted
            ? "錄音中的麥克風已靜音；系統輸出錄音不受影響。"
            : "錄音中的麥克風未靜音。";

    public string GlobalMuteHotKeyStatus => globalMuteHotKeyStatus;

    /// <summary>
    /// Explicit opt-in for a read-only Teams UI Automation observation. It
    /// changes only Recorder's physical-microphone contribution and never
    /// invokes, clicks, or writes a Teams control.
    /// </summary>
    public bool IsFollowTeamsMuteEnabled
    {
        get => isFollowTeamsMuteEnabled;
        set
        {
            if (!SetProperty(ref isFollowTeamsMuteEnabled, value))
            {
                return;
            }

            Interlocked.Increment(ref teamsMuteFollowRevision);
            if (value)
            {
                // Do not leak microphone audio between opt-in and the first
                // verified observation.
                teamsMuteFollowObservation = new(TeamsMuteFollowState.Unavailable);
                recorderMicrophoneMute.SetTeamsMuted(true);
                if (isInitialized && !isShuttingDown)
                {
                    teamsMuteFollowTimer.Start();
                }
            }
            else
            {
                teamsMuteFollowTimer.Stop();
                teamsMuteFollowObservation = TeamsMuteFollowObservation.NotInCall;
                recorderMicrophoneMute.SetTeamsMuted(false);
            }

            OnPropertyChanged(nameof(TeamsMuteFollowStatusText));
            OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
            PersistAppSettingsInBackground();
            NotifyRecordingOverlayStateChanged();
        }
    }

    public string TeamsMuteFollowStatusText => !IsFollowTeamsMuteEnabled
        ? "未啟用。Recorder 麥克風只受本機按鈕、Ctrl+Alt+M 與 Windows 輸入裝置狀態控制。"
        : teamsMuteFollowObservation.State switch
        {
            TeamsMuteFollowState.NotInCall => "未找到 Teams 通話麥克風按鈕；Recorder 不套用 Teams 靜音。",
            TeamsMuteFollowState.Muted => "Teams 已靜音；Recorder 已停止混入實體麥克風。",
            TeamsMuteFollowState.Unmuted => "Teams 未靜音；Recorder 可混入已選取的實體麥克風。",
            _ => "暫時無法確認 Teams 靜音；基於隱私，Recorder 暫停混入實體麥克風。",
        };

    /// <summary>Explicit opt-in for bounded local Teams render-session detection.</summary>
    public bool IsLocalHeuristicAutoStartEnabled
    {
        get => isLocalHeuristicAutoStartEnabled;
        set
        {
            if (SetProperty(ref isLocalHeuristicAutoStartEnabled, value))
            {
                var consentRevision = Interlocked.Increment(ref localTeamsAutomationConsentRevision);
                if (value)
                {
                    teamsLocalHeuristicTimer.Start();
                }
                else
                {
                    teamsLocalHeuristicTimer.Stop();
                    _ = RevokeLocalTeamsAutomationConsentAsync(consentRevision);
                }
                OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
                PersistAppSettingsInBackground();
                UpdateCommandStates();
            }
        }
    }

    public bool IsTeamsAutomaticRecordingEnabled => teamsAutomaticSnapshot.IsEnabled;

    public bool CanEnableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        !IsTeamsAutomaticRecordingEnabled &&
        teamsAutomaticRecorder is not null && IsLocalHeuristicAutoStartEnabled;

    public bool CanDisableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        IsTeamsAutomaticRecordingEnabled;

    /// <summary>
    /// State intended for the compact recording window. It is visible for any active capture
    /// (manual, test, or Teams automatic), plus the Teams-only start countdown.
    /// </summary>
    public RecordingOverlayState RecordingOverlayState => new(
        IsVisible: snapshot.State is RecordingCoordinatorState.Recording or RecordingCoordinatorState.Stopping ||
            isFaultFinalizationInProgress || IsTeamsAutomaticRecordingCountdownVisible,
        IsRecording: snapshot.State == RecordingCoordinatorState.Recording,
        IsTeamsAutomaticStartCountdown: IsTeamsAutomaticRecordingCountdownVisible,
        CountdownSeconds: TeamsAutomaticRecordingCountdownSeconds,
        CanCancelAutomaticStart: CanCancelTeamsAutomaticRecordingStart,
        CanStopRecording: CanStopRecordingFromOverlay,
        CanToggleTeamsWindowCapture: CanToggleTeamsWindowCapture,
        IsTeamsWindowCaptureEnabled: isTeamsWindowCaptureEnabled,
        TeamsWindowCaptureStatus: teamsWindowCaptureStatus,
        IsFinalizing: snapshot.State == RecordingCoordinatorState.Stopping || isFaultFinalizationInProgress,
        Elapsed: recordingStartedAt is { } startedAt ? DateTimeOffset.Now - startedAt : elapsed,
        SystemAudioStatus: !IsPrimaryCaptureAvailable
            ? RecordingOverlayInputStatus.Disconnected
            : snapshot.Stats.PrimaryLevelRms > 0.0001f
                ? RecordingOverlayInputStatus.Signal
                : RecordingOverlayInputStatus.Quiet,
        MicrophoneStatus: SelectedMicrophoneEndpoint switch
        {
            null or { EndpointId: null } or { IsAvailable: false } => RecordingOverlayInputStatus.Disconnected,
            _ when IsRecordingMicrophoneMuted => RecordingOverlayInputStatus.Muted,
            _ when snapshot.Stats.MicrophoneLevelRms > 0.0001f => RecordingOverlayInputStatus.Signal,
            _ => RecordingOverlayInputStatus.Quiet,
        },
        IsRecorderMicrophoneMuted: IsRecordingMicrophoneMuted,
        SystemAudioLevelPercent: AudioLevelPercent(snapshot.Stats.PrimaryLevelRms),
        MicrophoneLevelPercent: IsRecordingMicrophoneMuted
            ? 0
            : AudioLevelPercent(snapshot.Stats.MicrophoneLevelRms),
        IsVirtualMicrophoneReady: virtualMicPublisher?.State == VirtualMicPublisherRuntimeState.Ready,
        VirtualMicrophoneStatus: VirtualMicrophoneStatusText);

    public bool CanToggleTeamsWindowCapture =>
        snapshot.State == RecordingCoordinatorState.Recording &&
        !isTeamsWindowCaptureToggleInProgress &&
        (isTeamsWindowCaptureEnabled ||
            storageCapacity?.Decision is not RecordingStorageDecision.AudioOnly and
                not RecordingStorageDecision.Stop &&
            SelectedVideoCaptureWindow is not null);

    public async Task SetTeamsWindowCaptureDuringRecordingAsync(bool enabled)
    {
        if (!await videoToggleRequestGate.WaitAsync(0))
        {
            return;
        }

        isTeamsWindowCaptureToggleInProgress = true;
        teamsWindowCaptureStatus = enabled ? "正在啟用 Teams 畫面…" : "正在停止 Teams 畫面…";
        NotifyRecordingOverlayStateChanged();
        await recordingLifecycleActionGate.WaitAsync();
        try
        {
            if (snapshot.State != RecordingCoordinatorState.Recording)
            {
                return;
            }

            if (enabled &&
                storageCapacity?.Decision is RecordingStorageDecision.AudioOnly or RecordingStorageDecision.Stop)
            {
                teamsWindowCaptureStatus = "可用空間不足 1 GiB；音訊繼續錄製，但畫面錄製暫時不可啟用。";
                return;
            }

            NativeOperationResult result;
            if (enabled)
            {
                var selected = SelectedVideoCaptureWindow?.Target;
                var current = selected is null
                    ? null
                    : VideoCaptureTargetSelection.Resolve(selected, videoTargetCatalog.ListTargets());
                if (current is null)
                {
                    result = NativeOperationResult.Failure(
                        NativeRecorderResult.CaptureError,
                        "所選 Teams 視窗已無法使用；請在主視窗重新整理並選擇視窗。");
                }
                else
                {
                    result = await GetRecordingLifecycle().SetVideoTargetAsync(current);
                }
            }
            else
            {
                result = await GetRecordingLifecycle().DisableVideoTargetAsync();
            }

            if (result.IsSuccess)
            {
                isTeamsWindowCaptureEnabled = enabled;
                teamsWindowCaptureStatus = enabled
                    ? "Teams 畫面錄製中；關閉時同一 MP4 會寫入隱私黑畫面，音訊不會中斷。"
                    : "Teams 畫面已停止；音訊繼續錄製，影片時間線保持黑畫面。";
            }
            else
            {
                teamsWindowCaptureStatus = result.Error ?? "無法更新 Teams 畫面錄製狀態。";
                ErrorText = teamsWindowCaptureStatus;
            }
        }
        catch (Exception exception)
        {
            teamsWindowCaptureStatus = exception.Message;
            ErrorText = exception.Message;
        }
        finally
        {
            isTeamsWindowCaptureToggleInProgress = false;
            NotifyRecordingOverlayStateChanged();
            recordingLifecycleActionGate.Release();
            videoToggleRequestGate.Release();
        }
    }

    public bool IsTeamsAutomaticRecordingCountdownVisible => teamsAutomaticSnapshot.State is TeamsAutoMeetingState.StartCountdown;

    public int? TeamsAutomaticRecordingCountdownSeconds => teamsAutomaticSnapshot.State is
        TeamsAutoMeetingState.StartCountdown(var seconds) ? seconds : null;

    public bool CanCancelTeamsAutomaticRecordingStart =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        teamsAutomaticSnapshot.State is TeamsAutoMeetingState.StartCountdown;

    public bool CanStopRecordingFromOverlay =>
        snapshot.State == RecordingCoordinatorState.Recording &&
        CanStop;

    /// <summary>Source label consumed by the compact-window presenter for an active capture.</summary>
    public RecordingOverlayRecordingKind? ActiveRecordingOverlayKind =>
        snapshot.State != RecordingCoordinatorState.Recording ? null :
        recordingLifecycle?.ActiveSessionKind switch
        {
            RecordingSessionKind.Meeting => RecordingOverlayRecordingKind.TeamsAutomatic,
            RecordingSessionKind.Test => RecordingOverlayRecordingKind.Test,
            RecordingSessionKind.Manual => RecordingOverlayRecordingKind.Manual,
            _ => snapshot.IsTestRecording ? RecordingOverlayRecordingKind.Test : RecordingOverlayRecordingKind.Manual,
        };

    public string TeamsLocalAutomaticRecordingStatusText => !IsLocalHeuristicAutoStartEnabled
        ? "本機 Teams 自動錄音推測已停用；不會監看 Teams 播放工作階段。"
        : !IsTeamsAutomaticRecordingEnabled
            ? "本機偵測已獲同意；按「啟用自動錄音」後才會提出開始或停止。"
            : teamsAutomaticSnapshot.State switch
            {
                TeamsAutoMeetingState.WaitingForMeeting => teamsLocalHeuristicSnapshot?.Detail ?? "正在等待 Teams 播放工作階段。",
                TeamsAutoMeetingState.StartCountdown(var seconds) => $"偵測到可能的 Teams 會議；{seconds} 秒後開始錄音。",
                TeamsAutoMeetingState.Starting => "正在建立 crash-safe MP4 工作階段。",
                TeamsAutoMeetingState.AutomaticRecording => "自動錄音進行中；會議沉默不會令錄音停止。",
                TeamsAutoMeetingState.StopCountdown(var seconds) => $"已持續確認 Teams 會議控制消失；{seconds} 秒後停止自動錄音。",
                TeamsAutoMeetingState.Stopping => "正在停止並保存自動錄音。",
                TeamsAutoMeetingState.SuppressedUntilMeetingEnd => "本次會議已由使用者停止；重新偵測會議前不會再開始。",
                TeamsAutoMeetingState.StartBlocked(var reason) => $"自動錄音未開始：{reason}",
                TeamsAutoMeetingState.StartFailed(var reason) => $"自動錄音失敗：{reason}",
                _ => teamsLocalHeuristicSnapshot?.Detail ?? "本機 Teams 自動錄音狀態未知。",
            };

    public string TeamsAutomaticRecordingStatusText => TeamsLocalAutomaticRecordingStatusText;

    public EndpointChoice? SelectedRenderEndpoint
    {
        get => selectedRenderEndpoint;
        set
        {
            if (SetProperty(ref selectedRenderEndpoint, value))
            {
                OnPropertyChanged(nameof(SelectedRenderDescription));
                OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
                OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
                NotifyLiveAudioHealthChanged();
                UpdateCommandStates();
                PersistAppSettingsInBackground();
            }
        }
    }

    public EndpointChoice? SelectedMicrophoneEndpoint
    {
        get => selectedMicrophoneEndpoint;
        set
        {
            if (SetProperty(ref selectedMicrophoneEndpoint, value))
            {
                OnPropertyChanged(nameof(SelectedMicrophoneDescription));
                OnPropertyChanged(nameof(MicrophoneHealthText));
                OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
                NotifyLiveAudioHealthChanged();
                UpdateCommandStates();
                PersistAppSettingsInBackground();
            }
        }
    }

    public CaptureSourceChoice? SelectedCaptureSource
    {
        get => selectedCaptureSource;
        set
        {
            if (SetProperty(
                ref selectedCaptureSource,
                CaptureSourceChoice.ResolveSelection(value, selectedCaptureSource)))
            {
                OnPropertyChanged(nameof(SelectedCaptureSourceDescription));
                OnPropertyChanged(nameof(RenderEndpointSelectionVisibility));
                OnPropertyChanged(nameof(SelectedApplicationPanelVisibility));
                OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
                OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
                NotifyLiveAudioHealthChanged();
                UpdateCommandStates();
                PersistAppSettingsInBackground();
            }
        }
    }

    public ProcessSelectionChoice? SelectedProcess
    {
        get => selectedProcess;
        set
        {
            if (SetProperty(ref selectedProcess, value))
            {
                OnPropertyChanged(nameof(SelectedCaptureSourceDescription));
                UpdateCommandStates();
                PersistAppSettingsInBackground();
            }
        }
    }

    public bool IsSharedContentCaptureEnabled
    {
        get => isSharedContentCaptureEnabled;
        set
        {
            if (SetProperty(ref isSharedContentCaptureEnabled, value))
            {
                UpdateCommandStates();
            }
        }
    }

    public VideoCaptureWindowChoice? SelectedVideoCaptureWindow
    {
        get => selectedVideoCaptureWindow;
        set
        {
            if (SetProperty(ref selectedVideoCaptureWindow, value))
            {
                UpdateCommandStates();
                NotifyRecordingOverlayStateChanged();
            }
        }
    }

    public Visibility RenderEndpointSelectionVisibility =>
        SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
            ? Visibility.Collapsed
            : Visibility.Visible;

    public Visibility SelectedApplicationPanelVisibility =>
        SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
            ? Visibility.Visible
            : Visibility.Collapsed;

    public string SelectedCaptureSourceDescription => SelectedCaptureSource?.Kind switch
    {
        CaptureSourceKind.SelectedApplication when SelectedProcess is null =>
            "請選擇一個可用的應用程式或背景程序；程序不可用時會拒絕錄音，不會改錄系統音訊。",
        CaptureSourceKind.SelectedApplication =>
            $"只會錄製 {SelectedProcess!.DisplayName} 及其子處理程序；程序身分失效時會停止此來源，絕不回退至系統音訊。",
        _ => "建議來源：錄製系統 loopback 與所選輸出裝置，可靠包含 Teams 參與者音訊。",
    };

    public string ProcessCatalogStatusText
    {
        get => processCatalogStatusText;
        private set => SetProperty(ref processCatalogStatusText, value);
    }

    public LibraryRecording? SelectedLibraryItem
    {
        get => selectedLibraryItem;
        set
        {
            if (SetProperty(ref selectedLibraryItem, value))
            {
                librarySelectionGeneration++;
                PlaybackText = value is null
                    ? "請從錄音庫選取有效的 MP4 或舊版 M4A 檔案。"
                    : $"已選取：{value.DisplayName}";
                LibraryTitle = value?.Title ?? string.Empty;
                LibraryTagsText = value is null ? string.Empty : string.Join(", ", value.Tags);
                IsLibraryFavorite = value?.IsFavorite ?? false;
                pendingRecycleIdentity = null;
                pendingRecycleDisplayName = null;
                IsRecycleConfirmationVisible = false;
                ResetPlaybackForSelectionChange(value);
                OnPropertyChanged(nameof(SelectedLibraryDetails));
                OnPropertyChanged(nameof(IsVideoPlaybackStageVisible));
                OnPropertyChanged(nameof(IsAudioPlaybackStageVisible));
                OnPropertyChanged(nameof(PlaybackStageAccessibleName));
                OnPropertyChanged(nameof(PlaybackMediaKindText));
                OnPropertyChanged(nameof(PlaybackRecoveryText));
                OnPropertyChanged(nameof(PlaybackAiChipText));
                var aiGeneration = Interlocked.Increment(ref aiWorkspaceLoadGeneration);
                _ = LoadAiWorkspaceAsync(value, aiGeneration);
                UpdateCommandStates();
            }
        }
    }

    /// <summary>Local search covers title, tags, source, and the bounded canonical transcript.</summary>
    public string LibrarySearchText
    {
        get => librarySearchText;
        set
        {
            if (SetProperty(ref librarySearchText, value ?? string.Empty))
            {
                ApplyLibraryQuery();
            }
        }
    }

    public bool LibraryFavoritesOnly
    {
        get => libraryFavoritesOnly;
        set
        {
            if (SetProperty(ref libraryFavoritesOnly, value))
            {
                ApplyLibraryQuery();
            }
        }
    }

    public string LibraryTitle
    {
        get => libraryTitle;
        set => SetProperty(ref libraryTitle, value ?? string.Empty);
    }

    /// <summary>Comma, semicolon, and line-break separated tags in the editing surface.</summary>
    public string LibraryTagsText
    {
        get => libraryTagsText;
        set => SetProperty(ref libraryTagsText, value ?? string.Empty);
    }

    public bool IsLibraryFavorite
    {
        get => isLibraryFavorite;
        set => SetProperty(ref isLibraryFavorite, value);
    }

    public bool IsRecycleConfirmationVisible
    {
        get => isRecycleConfirmationVisible;
        private set
        {
            if (SetProperty(ref isRecycleConfirmationVisible, value))
            {
                OnPropertyChanged(nameof(RecycleConfirmationText));
                UpdateCommandStates();
            }
        }
    }

    public string RecycleConfirmationText => IsRecycleConfirmationVisible && SelectedLibraryItem is { } item
        ? $"確認將「{pendingRecycleDisplayName ?? item.DisplayName}」移至資源回收桶？此操作不會立即永久刪除檔案。"
        : string.Empty;

    public string SelectedLibraryDetails => SelectedLibraryItem is { } item
        ? $"{item.MediaKindText} · {item.KindText} · {item.MediaBytes / 1024d / 1024d:0.0} MiB" +
          (item.HasRecoverableBackup ? " · 偵測到可復原備份" : string.Empty) +
          (item.RecoveryChipText is { } recovery ? $" · {recovery}" : string.Empty)
        : "選取一個工作階段後即可編輯名稱、標籤與最愛狀態。";

    public string OutputFolder
    {
        get => outputFolder;
        set
        {
            var requestedFolder = value ?? string.Empty;
            if (string.Equals(outputFolder, requestedFolder, StringComparison.Ordinal))
            {
                return;
            }

            // Validate and swap the application service first. If an active
            // session rejects the change, the binding remains on its old value.
            if (recordingLifecycle is not null)
            {
                recordingLifecycle.SetStorageRoot(requestedFolder);
            }

            SetProperty(ref outputFolder, requestedFolder);
            ResetSessionStorage();
            allLibraryItems.Clear();
            LibraryItems.Clear();
            SelectedLibraryItem = null;
            RefreshStorageReadiness();
            OnPropertyChanged(nameof(NextOutputPath));
            OnPropertyChanged(nameof(LibrarySummaryText));
            PersistAppSettingsInBackground();
        }
    }

    public string NextOutputPath
    {
        get => nextOutputPath;
        private set => SetProperty(ref nextOutputPath, value);
    }

    public string StatusText
    {
        get => statusText;
        private set => SetProperty(ref statusText, value);
    }

    public string? ErrorText
    {
        get => errorText;
        private set
        {
            if (SetProperty(ref errorText, value))
            {
                OnPropertyChanged(nameof(HasError));
                OnPropertyChanged(nameof(ReadinessText));
            }
        }
    }

    public bool HasError => !string.IsNullOrWhiteSpace(ErrorText);

    public string DiagnosticsExportStatusText
    {
        get => diagnosticsExportStatusText;
        private set => SetProperty(ref diagnosticsExportStatusText, value);
    }

    public string VirtualMicrophoneStatusText
    {
        get => virtualMicrophoneStatusText;
        private set
        {
            if (SetProperty(ref virtualMicrophoneStatusText, value))
            {
                NotifyRecordingOverlayStateChanged();
            }
        }
    }

    /// <summary>
    /// OpenAI-compatible provider fields. The public profile is stored locally;
    /// a key entered in the password box is written only to the Windows DPAPI store.
    /// </summary>
    public string OpenAiApiBaseUrl
    {
        get => openAiApiBaseUrl;
        set => SetProperty(ref openAiApiBaseUrl, value ?? string.Empty);
    }

    public string OpenAiAsrModel
    {
        get => openAiAsrModel;
        set => SetProperty(ref openAiAsrModel, value ?? string.Empty);
    }

    public string OpenAiLlmModel
    {
        get => openAiLlmModel;
        set => SetProperty(ref openAiLlmModel, value ?? string.Empty);
    }

    public string OpenAiLanguage
    {
        get => openAiLanguage;
        set => SetProperty(ref openAiLanguage, value ?? string.Empty);
    }

    public string OpenAiPrompt
    {
        get => openAiPrompt;
        set => SetProperty(ref openAiPrompt, value ?? string.Empty);
    }

    public AIProviderKindChoice SelectedOpenAiProviderKind
    {
        get => selectedOpenAiProviderKind;
        set
        {
            var next = value ?? AIProviderKindChoice.OpenAICompatible;
            if (selectedOpenAiProviderKind.Kind == next.Kind) return;
            if (!isApplyingOpenAiProviderDraft) CaptureOpenAiProviderDraft(selectedOpenAiProviderKind.Kind);
            if (SetProperty(ref selectedOpenAiProviderKind, next))
            {
                ApplyOpenAiProviderDraft(next.Kind);
                hasOpenAiApiKey = openAiProviderApiKeyPresence.GetValueOrDefault(next.Kind);
                OnPropertyChanged(nameof(IsHktOpenAiProvider));
                OnPropertyChanged(nameof(HktOpenAiProviderVisibility));
                OnPropertyChanged(nameof(GenericOpenAiProviderVisibility));
                OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
                OnPropertyChanged(nameof(CanRemoveOpenAiApiKey));
            }
        }
    }

    public bool IsHktOpenAiProvider => SelectedOpenAiProviderKind.Kind == AIProviderKind.HktGenAI;

    public Visibility HktOpenAiProviderVisibility => IsHktOpenAiProvider ? Visibility.Visible : Visibility.Collapsed;

    public Visibility GenericOpenAiProviderVisibility => IsHktOpenAiProvider ? Visibility.Collapsed : Visibility.Visible;

    public string OpenAiHktGroupId
    {
        get => openAiHktGroupId;
        set
        {
            if (SetProperty(ref openAiHktGroupId, value ?? string.Empty))
                OnPropertyChanged(nameof(OpenAiResolvedHktUrl));
        }
    }

    public string OpenAiResolvedHktUrl =>
        OpenAICompatibleProviderProfile.HktBaseUrlPrefix + OpenAiHktGroupId.Trim() + "/openai";

    public string OpenAiMeetingIntelligencePrompt
    {
        get => openAiMeetingIntelligencePrompt;
        set => SetProperty(ref openAiMeetingIntelligencePrompt, value ?? string.Empty);
    }

    /// <summary>Ephemeral per-provider replacement; it is never persisted until Save.</summary>
    public string OpenAiApiKeyReplacement
    {
        get => openAiApiKeyReplacement;
        set => SetProperty(ref openAiApiKeyReplacement, value ?? string.Empty);
    }

    /// <summary>Settings are available only after the local DPAPI-backed repository is ready.</summary>
    public bool IsOpenAiProviderAvailable => isOpenAiProviderInitialized && !isShuttingDown;

    public bool CanSaveOpenAiProvider => IsOpenAiProviderAvailable && !IsBusy;

    /// <summary>Tests only the configured provider endpoint; it never starts an upload.</summary>
    public bool CanTestOpenAiProvider => IsOpenAiProviderAvailable && !IsBusy && !IsTestingOpenAiProvider;

    public bool CanRemoveOpenAiApiKey => IsOpenAiProviderAvailable && !IsBusy && hasOpenAiApiKey;

    /// <summary>The key itself is never returned to the view, only whether DPAPI has one.</summary>
    public string OpenAiApiKeyFieldLabel => hasOpenAiApiKey ? "API Key（已儲存）" : "API Key（選填）";

    public bool IsTestingOpenAiProvider
    {
        get => isTestingOpenAiProvider;
        private set => SetProperty(ref isTestingOpenAiProvider, value);
    }

    public bool CanStartOpenAiTranscription =>
        IsOpenAiProviderAvailable && !IsBusy && SelectedLibraryItem is { IsManaged: true, IsPlayable: true };

    public bool CanImportAudioForTranscription =>
        !IsBusy && !isShuttingDown && !string.IsNullOrWhiteSpace(OutputFolder);

    public bool CanGenerateOpenAiSummary =>
        CanStartOpenAiTranscription && hasLoadedTranscript && !string.IsNullOrWhiteSpace(TranscriptText);

    public bool CanCancelMeetingIntelligence =>
        meetingIntelligenceCoordinator?.Snapshot.State is
            MeetingIntelligenceSessionState.Checking or MeetingIntelligenceSessionState.Generating;

    public bool CanSaveTranscript =>
        SelectedLibraryItem is { IsManaged: true } && hasLoadedTranscript && !IsBusy;

    public bool CanSaveMeetingIntelligence =>
        meetingIntelligenceCoordinator?.Snapshot.State is
            MeetingIntelligenceSessionState.Ready or MeetingIntelligenceSessionState.Stale &&
        !IsBusy;

    public string TranscriptText
    {
        get => transcriptText;
        set => SetProperty(ref transcriptText, value ?? string.Empty);
    }

    public string MeetingIntelligenceSummary
    {
        get => meetingIntelligenceSummary;
        set => SetProperty(ref meetingIntelligenceSummary, value ?? string.Empty);
    }

    public string MeetingIntelligenceSuggestedTitle
    {
        get => meetingIntelligenceSuggestedTitle;
        set => SetProperty(ref meetingIntelligenceSuggestedTitle, value ?? string.Empty);
    }

    public string MeetingIntelligenceStatus
    {
        get => meetingIntelligenceStatus;
        private set => SetProperty(ref meetingIntelligenceStatus, value ?? string.Empty);
    }

    public string OpenAiProviderIntegrationStatus
    {
        get => openAiProviderIntegrationStatus;
        private set => SetProperty(ref openAiProviderIntegrationStatus, value);
    }

    public bool CanSaveDiagnostics => !isShuttingDown && recordingLifecycle is not null;

    public bool CanOpenDiagnosticsFolder => !isShuttingDown && Directory.Exists(diagnosticsDirectory);

    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (SetProperty(ref isBusy, value))
            {
                UpdateCommandStates();
            }
        }
    }

    /// <summary>Setup remains editable when capacity blocks Start, so users can choose another volume.</summary>
    public bool IsDeviceSelectionEnabled => IsSetupEditable;

    public bool IsTeamsWindowSelectionEnabled =>
        IsSetupEditable ||
        snapshot.State == RecordingCoordinatorState.Recording && !isTeamsWindowCaptureToggleInProgress;

    public string ReadinessText => isRecorderAvailable
        ? "原生音訊 bridge 已載入；開始前請確認輸出裝置、選用的麥克風與儲存空間。"
        : $"尚未可用：{ErrorText ?? "請依錯誤訊息修正 native bridge 或裝置設定。"}";

    public string SelectedRenderDescription => SelectedRenderEndpoint switch
    {
        null => "正在讀取 Windows 輸出裝置…",
        { IsAvailable: false } => "原先選取的輸出裝置已中斷；請重新選取或重新整理裝置。",
        { EndpointId: null } => "使用 Windows 預設輸出裝置。",
        _ => $"指定輸出：{SelectedRenderEndpoint.DisplayName}",
    };

    /// <summary>
    /// A prompt to manually align the system-loopback endpoint with Teams.
    /// Teams' public API does not expose its speaker selection, so this is
    /// advisory only and never changes Teams or blocks a recording.
    /// </summary>
    public string? TeamsPlaybackEndpointWarning =>
        TeamsPlaybackEndpointAdvice.GetWarning(
            SelectedCaptureSource?.Kind,
            SelectedRenderEndpoint,
            windowsConsoleDefaultRenderEndpointId,
            teamsPlaybackEndpointObservation);

    public bool HasTeamsPlaybackEndpointWarning => !string.IsNullOrWhiteSpace(TeamsPlaybackEndpointWarning);

    public string SelectedMicrophoneDescription => SelectedMicrophoneEndpoint switch
    {
        null => "正在讀取 Windows 麥克風…",
        { IsAvailable: false } => "原先選取的麥克風已中斷；請重新選取或重新整理裝置。",
        { EndpointId: null } => "不錄製麥克風。",
        _ => $"已選取：{SelectedMicrophoneEndpoint.DisplayName}",
    };

    public string ElapsedText => elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture);

    public double PeakPercent => Math.Clamp(snapshot.Stats.Peak * 100d, 0d, 100d);

    public string PeakText => $"{PeakPercent:0.0}% / {(PeakPercent >= 99 ? "可能剪裁" : "未偵測剪裁")}";

    public double OutputLevelPercent => Math.Clamp(snapshot.Stats.PrimaryLevelRms * 100d, 0d, 100d);

    public string OutputLevelText => $"{OutputLevelPercent:0.0}%";

    public double InputLevelPercent => Math.Clamp(snapshot.Stats.MicrophoneLevelRms * 100d, 0d, 100d);

    public string InputLevelText => SelectedMicrophoneEndpoint?.EndpointId is null
        ? "未啟用"
        : $"{InputLevelPercent:0.0}%";

    private LiveAudioHealthAssessment LiveAudioHealth => LiveAudioHealthAdvisor.Assess(
        snapshot.Stats,
        isCaptureActive: snapshot.State == RecordingCoordinatorState.Recording,
        primaryTitle: PrimaryCaptureLabel,
        primaryAvailable: IsPrimaryCaptureAvailable,
        microphoneIncluded: SelectedMicrophoneEndpoint?.EndpointId is not null,
        microphoneAvailable: SelectedMicrophoneEndpoint is not { IsAvailable: false },
        microphoneMuted: IsRecordingMicrophoneMuted);

    public string PrimaryHealthTitle => LiveAudioHealth.Primary.Title;

    public string PrimaryHealthDetail => LiveAudioHealth.Primary.Detail;

    public string PrimaryHealthGlyph => HealthGlyph(LiveAudioHealth.Primary.Status);

    public Brush PrimaryHealthBrush => HealthBrush(LiveAudioHealth.Primary.Status);

    public string MicrophoneHealthTitle => LiveAudioHealth.Microphone.Title;

    public string MicrophoneHealthDetail => LiveAudioHealth.Microphone.Detail;

    public string MicrophoneHealthGlyph => HealthGlyph(LiveAudioHealth.Microphone.Status);

    public Brush MicrophoneHealthBrush => HealthBrush(LiveAudioHealth.Microphone.Status);

    public string AudioHealthSummaryText => LiveAudioHealth.Summary;

    public string AggregateHealthText =>
        $"彙總：{snapshot.Stats.Packets:N0} 音訊封包、{snapshot.Stats.Discontinuities:N0} 次中斷；" +
        (snapshot.Stats.Packets == 0
            ? "尚未偵測到訊號"
            : snapshot.Stats.SilentPackets == snapshot.Stats.Packets
                ? "無訊號（皆為靜音）"
                : "偵測到訊號");

    private string PrimaryCaptureLabel => SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
        ? $"指定應用程式：{SelectedProcess?.DisplayName ?? "已選程序"}"
        : "系統音訊";

    private bool IsPrimaryCaptureAvailable => SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
        ? SelectedProcess is { IsAvailable: true }
        : SelectedRenderEndpoint is not { IsAvailable: false };

    public string RenderHealthText => snapshot.Stats.SourceSampleRate == 0
        ? $"{PrimaryCaptureLabel}：等待第一個音訊封包。"
        : $"{PrimaryCaptureLabel}：bridge 輸出 48 kHz stereo；來源格式 {snapshot.Stats.SourceSampleRate:N0} Hz / {snapshot.Stats.SourceChannels} 聲道。";

    public string MicrophoneHealthText => SelectedMicrophoneEndpoint switch
    {
        { IsAvailable: false } => "麥克風：裝置中斷，已封鎖開始錄製。",
        { EndpointId: null } => "麥克風：未選取（不錄製）。",
        _ when snapshot.Stats.MicrophoneTimeline.SourceDisconnects > 0 =>
            $"麥克風：錄音期間中斷 {snapshot.Stats.MicrophoneTimeline.SourceDisconnects:N0} 次；Teams 主音訊會繼續，缺失區段已保留為靜音。",
        _ => "麥克風：已選取並會納入 mixed 錄音。",
    };

    public string StorageReadinessText => storageCapacity switch
    {
        null => "正在驗證儲存空間。",
        { Decision: RecordingStorageDecision.Stop } => "儲存位置不可用或可用空間少於 256 MiB；開始錄製已封鎖。",
        { Decision: RecordingStorageDecision.AudioOnly } =>
            $"可用 {FormatBytes(storageCapacity.AvailableBytes)}；目前只允許音訊工作階段。",
        { Decision: RecordingStorageDecision.Warn } =>
            $"可用 {FormatBytes(storageCapacity.AvailableBytes)}；低於 5 GiB，建議先清理空間。",
        _ => $"儲存空間可用：{FormatBytes(storageCapacity.AvailableBytes)}。",
    };

    public string ResultText => lastResultText;

    public string LibrarySummaryText => IsLibraryLoading
        ? "正在掃描錄音庫…"
        : LibraryItems.Count == allLibraryItems.Count
            ? $"{LibraryItems.Count} 個可播放工作階段 · {LibraryItems.Count(item => item.IsFavorite)} 個最愛"
            : $"顯示 {LibraryItems.Count} / {allLibraryItems.Count} 個工作階段 · {LibraryItems.Count(item => item.IsFavorite)} 個最愛";

    public bool IsLibraryLoading
    {
        get => isLibraryLoading;
        private set
        {
            if (SetProperty(ref isLibraryLoading, value))
            {
                OnPropertyChanged(nameof(LibraryLoadingText));
                OnPropertyChanged(nameof(LibrarySummaryText));
                UpdateCommandStates();
            }
        }
    }

    public string LibraryLoadingText => IsLibraryLoading
        ? "錄音較多時可能需要數十秒；完成前播放會暫時停用。"
        : string.Empty;

    public string PlaybackText
    {
        get => playbackText;
        private set => SetProperty(ref playbackText, value);
    }

    public double PlaybackProgress
    {
        get => playbackProgress;
        set
        {
            var clamped = Math.Clamp(value, 0d, 1d);
            if (SetProperty(ref playbackProgress, clamped) && !isUpdatingPlaybackPosition)
            {
                SeekPlaybackByProgress(clamped);
            }
        }
    }

    /// <summary>The shared player is intentionally exposed only to the playback stage.</summary>
    public MediaPlayer? PlaybackMediaPlayer => mediaPlayer;

    public Visibility IsVideoPlaybackStageVisible => SelectedLibraryItem is { IsVideo: true }
        ? Visibility.Visible
        : Visibility.Collapsed;

    public Visibility IsAudioPlaybackStageVisible => SelectedLibraryItem is { IsVideo: true }
        ? Visibility.Collapsed
        : Visibility.Visible;

    public string PlaybackStageAccessibleName => SelectedLibraryItem is { IsVideo: true }
        ? "影片錄音播放畫面"
        : "純音訊錄音播放畫面";

    public string PlaybackMediaKindText => SelectedLibraryItem?.MediaKindText ?? "選取錄音後顯示媒體類型";

    public string PlaybackRecoveryText => SelectedLibraryItem?.RecoveryChipText ?? string.Empty;

    public string PlaybackAiChipText => SelectedLibraryItem?.AiChipText ?? string.Empty;

    public double PlaybackPositionSeconds
    {
        get => playbackPositionSeconds;
        set
        {
            var clamped = Math.Clamp(value, 0d, Math.Max(0d, PlaybackDurationSeconds));
            if (SetProperty(ref playbackPositionSeconds, clamped) && !isUpdatingPlaybackPosition)
            {
                SeekPlaybackToSeconds(clamped);
            }
        }
    }

    public double PlaybackDurationSeconds
    {
        get => playbackDurationSeconds;
        private set
        {
            if (SetProperty(ref playbackDurationSeconds, Math.Max(0d, value)))
            {
                OnPropertyChanged(nameof(PlaybackElapsedText));
                OnPropertyChanged(nameof(PlaybackRemainingText));
                OnPropertyChanged(nameof(PlaybackDurationText));
                OnPropertyChanged(nameof(PlaybackTimeReadout));
            }
        }
    }

    public string PlaybackElapsedText => FormatPlaybackTime(PlaybackPositionSeconds, PlaybackDurationSeconds >= 3600d);

    public string PlaybackRemainingText => "-" + FormatPlaybackTime(
        Math.Max(0d, PlaybackDurationSeconds - PlaybackPositionSeconds),
        PlaybackDurationSeconds >= 3600d);

    public string PlaybackDurationText => FormatPlaybackTime(PlaybackDurationSeconds, PlaybackDurationSeconds >= 3600d);

    public string PlaybackTimeReadout => $"{PlaybackElapsedText} / {PlaybackDurationText}";

    public double PlaybackVolume
    {
        get => playbackVolume;
        set
        {
            var clamped = Math.Clamp(value, 0d, 1d);
            if (SetProperty(ref playbackVolume, clamped) && mediaPlayer is not null)
            {
                mediaPlayer.Volume = clamped;
            }
        }
    }

    public double SelectedPlaybackRate
    {
        get => selectedPlaybackRate;
        set
        {
            var supported = PlaybackRateChoices.Any(choice => Math.Abs(choice.Rate - value) < 0.001d)
                ? value
                : 1d;
            if (SetProperty(ref selectedPlaybackRate, supported) && mediaPlayer is not null)
            {
                mediaPlayer.PlaybackSession.PlaybackRate = supported;
            }
        }
    }

    public bool CanSeek =>
        mediaPlayer is not null &&
        mediaPlayer.PlaybackSession.NaturalDuration > TimeSpan.Zero &&
        SelectedLibraryItem is { IsPlayable: true } &&
        !isShuttingDown;

    public void InitializePlayer()
    {
        mediaPlayer = new MediaPlayer();
        mediaPlayer.Volume = PlaybackVolume;
        mediaPlayer.PlaybackSession.PlaybackRate = SelectedPlaybackRate;
        OnPropertyChanged(nameof(PlaybackMediaPlayer));
        mediaPlayer.MediaOpened += (_, _) => dispatcherQueue.TryEnqueue(() =>
        {
            if (loadedPlaybackPath is null)
            {
                return;
            }

            PlaybackText = "可播放。";
            PlaybackDurationSeconds = Math.Max(0d, mediaPlayer.PlaybackSession.NaturalDuration.TotalSeconds);
            SetPlaybackPositionSeconds(mediaPlayer.PlaybackSession.Position.TotalSeconds);
            playbackTimer.Start();
            UpdateCommandStates();
        });
        mediaPlayer.MediaFailed += (_, args) => dispatcherQueue.TryEnqueue(() =>
        {
            playbackTimer.Stop();
            PlaybackText = $"無法播放：{args.ErrorMessage}";
            ClearPlaybackTimeline();
            UpdateCommandStates();
        });
        mediaPlayer.PlaybackSession.PlaybackStateChanged += (_, _) =>
            dispatcherQueue.TryEnqueue(UpdateCommandStates);
    }

    private async Task InitializeOpenAiProviderAsync()
    {
        openAiProviderRepository = new OpenAICompatibleProviderRepository(
            new JsonOpenAICompatibleProviderProfileStore(),
            new WindowsDpapiOpenAICompatibleApiKeyStore());
        openAiAsrTransport = new OpenAICompatibleAsrHttpTransport();
        openAiProviderConnectionClient = new OpenAICompatibleProviderConnectionClient();
        transcriptionCoordinator = RecordingSessionAsrJobCoordinator.CreateOpenAiCompatible(
            openAiProviderRepository,
            new OpenAICompatibleAsrClient(openAiAsrTransport));

        try
        {
            foreach (var kind in new[] { AIProviderKind.OpenAICompatible, AIProviderKind.HktGenAI })
            {
                var saved = await openAiProviderRepository.LoadProfileAsync(kind);
                if (saved is not null) openAiProviderDrafts[kind] = AiProviderEditorDraft.FromProfile(saved);
                openAiProviderApiKeyPresence[kind] = await openAiProviderRepository.HasApiKeyAsync(kind);
            }

            var profile = await openAiProviderRepository.LoadProfileAsync();
            var activeKind = profile?.ProviderKind ?? AIProviderKind.OpenAICompatible;
            isApplyingOpenAiProviderDraft = true;
            try
            {
                SelectedOpenAiProviderKind = AIProviderKindChoice.From(activeKind);
                ApplyOpenAiProviderDraft(activeKind);
            }
            finally { isApplyingOpenAiProviderDraft = false; }
            hasOpenAiApiKey = openAiProviderApiKeyPresence.GetValueOrDefault(activeKind);
            if (profile is not null)
            {
                OpenAiProviderIntegrationStatus = "已載入本機 AI 供應商設定。開始 ASR／Meeting Intelligence 前仍會要求確認。";
            }
            else
            {
                OpenAiProviderIntegrationStatus = "尚未儲存 AI 供應商設定。可輸入 OpenAI 相容 API 設定後儲存。";
            }
        }
        catch (Exception)
        {
            // A corrupted old profile must not block local recording. Keep the editor
            // available so the user can replace it; do not display a possibly sensitive URL.
            hasOpenAiApiKey = false;
            OpenAiProviderIntegrationStatus = "無法讀取先前的 AI 設定；請重新輸入並儲存。";
        }
        finally
        {
            isOpenAiProviderInitialized = true;
            OnPropertyChanged(nameof(IsOpenAiProviderAvailable));
            OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
            UpdateCommandStates();
        }
    }

    /// <summary>
    /// Saves only the public provider profile plus an optional replacement API key. An empty
    /// password-box value deliberately preserves an existing key rather than clearing it.
    /// </summary>
    public Task SaveOpenAiProviderSettingsAsync(string? replacementApiKey) => RunOperationAsync(async () =>
    {
        var providers = openAiProviderRepository
            ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。");
        var profile = CreateOpenAiProviderProfileFromEditor();
        await providers.SaveAsync(profile, replacementApiKey);
        OpenAiApiBaseUrl = profile.BaseUrl;
        OpenAiAsrModel = profile.AsrModel;
        OpenAiLlmModel = profile.LlmModel;
        OpenAiLanguage = profile.Language;
        OpenAiPrompt = profile.Prompt;
        OpenAiMeetingIntelligencePrompt = profile.MeetingIntelligencePrompt;
        OpenAiApiKeyReplacement = string.Empty;
        openAiProviderDrafts[profile.ProviderKind] = AiProviderEditorDraft.FromProfile(profile);
        openAiProviderApiKeyPresence[profile.ProviderKind] = await providers.HasApiKeyAsync(profile.ProviderKind);
        hasOpenAiApiKey = openAiProviderApiKeyPresence[profile.ProviderKind];
        OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
        OpenAiProviderIntegrationStatus = string.IsNullOrWhiteSpace(replacementApiKey)
            ? "已儲存 AI 供應商設定；既有 API 金鑰保持不變。"
            : "已儲存 AI 供應商設定與目前 Windows 使用者的加密 API 金鑰。";
    });

    public Task ClearOpenAiApiKeyAsync() => RunOperationAsync(async () =>
    {
        var providers = openAiProviderRepository
            ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。");
        var kind = SelectedOpenAiProviderKind.Kind;
        await providers.ClearApiKeyAsync(kind);
        openAiProviderApiKeyPresence[kind] = false;
        hasOpenAiApiKey = false;
        OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
        OpenAiProviderIntegrationStatus = "已移除目前 Windows 使用者的本機 API 金鑰；供應商設定仍保留。";
    });

    /// <summary>
    /// Mirrors macOS' lightweight <c>GET /models</c> test. Draft values are used
    /// directly, so users can verify a provider before saving a profile.
    /// </summary>
    public Task TestOpenAiProviderConnectionAsync() => RunOperationAsync(async () =>
    {
        var providers = openAiProviderRepository
            ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。");
        var connection = openAiProviderConnectionClient
            ?? throw new InvalidOperationException("AI 供應商連線檢查尚未準備完成。");
        var profile = CreateOpenAiProviderProfileFromEditor();

        IsTestingOpenAiProvider = true;
        try
        {
            var snapshot = await providers.SnapshotAsync(profile);
            var report = await connection.TestConnectionAsync(snapshot.Profile, snapshot.ApiKey);
            OpenAiDiscoveredModels.Clear();
            foreach (var model in report.Models)
            {
                OpenAiDiscoveredModels.Add(model);
            }

            OpenAiProviderIntegrationStatus = report.SupportsModelDiscovery
                ? report.Models.Count == 0
                    ? "已連線；此供應商沒有回傳可選模型，可手動輸入模型名稱。"
                    : $"已連線；已找到 {report.Models.Count} 個模型，可從 ASR 或 LLM 清單選擇。"
                : "已連線；此供應商未提供模型清單，請手動輸入模型名稱。";
        }
        catch
        {
            OpenAiProviderIntegrationStatus = "無法連線至 AI 供應商。請檢查 Base URL、API Key 與網路後再試。";
            throw;
        }
        finally
        {
            IsTestingOpenAiProvider = false;
        }
    });

    /// <summary>Starts a user-confirmed ASR job for one completed, managed recording.</summary>
    public Task StartOpenAiTranscriptionAsync() => RunOperationAsync(async () =>
    {
        var coordinator = transcriptionCoordinator
            ?? throw new InvalidOperationException("AI 逐字稿服務尚未準備完成。");
        var plan = await GetSelectedManagedSessionPlanAsync();
        var job = await coordinator.StartAsync(plan, explicitlyOptedIn: true);
        OpenAiProviderIntegrationStatus = "正在準備完整、可解碼的音訊分段並產生逐字稿。";
        try
        {
            await job.Completion;
            OpenAiProviderIntegrationStatus = "逐字稿已完成並安全儲存在此錄音工作階段。";
            await RefreshLibraryCoreAsync();
            if (SelectedLibraryItem is { } selected)
            {
                var generation = Interlocked.Increment(ref aiWorkspaceLoadGeneration);
                await LoadAiWorkspaceAsync(selected, generation);
                if (meetingIntelligenceCoordinator is { } intelligence)
                {
                    OpenAiProviderIntegrationStatus = "逐字稿已完成；正在自動產生摘要及建議標題。";
                    var intelligenceJob = await intelligence.StartAutomaticAsync(providerProcessingAllowed: true);
                    await intelligenceJob.Completion;
                    ApplyMeetingIntelligenceSnapshot(intelligence.Snapshot);
                    OpenAiProviderIntegrationStatus = intelligence.Snapshot.State == MeetingIntelligenceSessionState.Ready
                        ? "逐字稿、摘要及建議標題已完成。"
                        : intelligence.Snapshot.StatusMessage;
                    await RefreshLibraryCoreAsync();
                }
            }
        }
        catch
        {
            OpenAiProviderIntegrationStatus = "逐字稿未完成；已保留可檢查的本機工作階段狀態。";
            throw;
        }
    });

    /// <summary>Generates or regenerates bounded meeting intelligence from the canonical transcript.</summary>
    public Task GenerateOpenAiSummaryAsync() => RunOperationAsync(async () =>
    {
        var coordinator = meetingIntelligenceCoordinator
            ?? throw new InvalidOperationException("請先選取有逐字稿的受管理錄音。");
        var intent = coordinator.Snapshot.State is MeetingIntelligenceSessionState.Ready or
            MeetingIntelligenceSessionState.Stale
            ? MeetingIntelligenceGenerationIntent.Regenerate
            : MeetingIntelligenceGenerationIntent.Generate;
        OpenAiProviderIntegrationStatus = "正在傳送已完成逐字稿以產生摘要及建議標題。音訊不會再次上傳。";
        try
        {
            var job = await coordinator.GenerateAsync(intent);
            await job.Completion;
            ApplyMeetingIntelligenceSnapshot(coordinator.Snapshot);
            OpenAiProviderIntegrationStatus = "摘要及建議標題已完成並安全儲存在此錄音工作階段。";
            await RefreshLibraryCoreAsync();
        }
        catch (OperationCanceledException)
        {
            OpenAiProviderIntegrationStatus = "Meeting Intelligence 已取消。";
        }
        catch
        {
            OpenAiProviderIntegrationStatus = "摘要未完成；已保留可檢查的本機工作階段狀態。";
            throw;
        }
    });

    /// <summary>
    /// Mirrors macOS manual transcription import. The source remains untouched;
    /// the library receives an owned copy which can be played and transcribed.
    /// </summary>
    public Task ImportAudioForTranscriptionAsync(string sourcePath) => RunOperationAsync(async () =>
    {
        var library = GetLibraryService();
        var imported = await Task.Run(() => library.ImportAudioForTranscriptionAsync(sourcePath));
        LibrarySearchText = string.Empty;
        LibraryFavoritesOnly = false;
        await RefreshLibraryCoreAsync();
        var item = allLibraryItems.FirstOrDefault(candidate =>
            PathEquals(candidate.SessionPath, imported.Session.FolderPath));
        if (item is not null)
        {
            ApplyLibraryQuery(item.Identity);
            SelectedLibraryItem = LibraryItems.FirstOrDefault(candidate => candidate.Identity == item.Identity) ?? item;
        }
        StatusText = $"已匯入「{imported.DisplayName}」；可在 AI 工作區開始轉錄。";
    });

    private OpenAICompatibleProviderProfile CreateOpenAiProviderProfileFromEditor() =>
        SelectedOpenAiProviderKind.Kind == AIProviderKind.HktGenAI
            ? OpenAICompatibleProviderProfile.HktValidated(
                OpenAiHktGroupId,
                OpenAiAsrModel,
                OpenAiLlmModel,
                OpenAiLanguage,
                OpenAiPrompt,
                OpenAiMeetingIntelligencePrompt)
            : OpenAICompatibleProviderProfile.Validated(
                OpenAiApiBaseUrl,
                OpenAiAsrModel,
                OpenAiLlmModel,
                OpenAiLanguage,
                OpenAiPrompt,
                OpenAiMeetingIntelligencePrompt);

    private void CaptureOpenAiProviderDraft(AIProviderKind kind) =>
        openAiProviderDrafts[kind] = new AiProviderEditorDraft(
            OpenAiApiBaseUrl,
            OpenAiHktGroupId,
            OpenAiAsrModel,
            OpenAiLlmModel,
            OpenAiLanguage,
            OpenAiPrompt,
            OpenAiMeetingIntelligencePrompt,
            OpenAiApiKeyReplacement);

    private void ApplyOpenAiProviderDraft(AIProviderKind kind)
    {
        if (!openAiProviderDrafts.TryGetValue(kind, out var draft))
            draft = kind == AIProviderKind.HktGenAI
                ? AiProviderEditorDraft.HktDefault
                : AiProviderEditorDraft.GenericDefault;
        var wasApplying = isApplyingOpenAiProviderDraft;
        isApplyingOpenAiProviderDraft = true;
        try
        {
            OpenAiApiBaseUrl = draft.BaseUrl;
            OpenAiHktGroupId = draft.GroupId;
            OpenAiAsrModel = draft.AsrModel;
            OpenAiLlmModel = draft.LlmModel;
            OpenAiLanguage = draft.Language;
            OpenAiPrompt = draft.Prompt;
            OpenAiMeetingIntelligencePrompt = draft.MeetingIntelligencePrompt;
            OpenAiApiKeyReplacement = draft.ApiKeyReplacement;
        }
        finally { isApplyingOpenAiProviderDraft = wasApplying; }
    }

    public async Task CancelMeetingIntelligenceAsync()
    {
        if (meetingIntelligenceCoordinator is not { } coordinator)
        {
            return;
        }
        await coordinator.CancelAsync();
        ApplyMeetingIntelligenceSnapshot(coordinator.Snapshot);
    }

    public Task SaveTranscriptAsync() => RunOperationAsync(async () =>
    {
        var plan = await GetSelectedManagedSessionPlanAsync();
        await new TranscriptionArtifactPublisher().SaveEditedTranscriptAsync(plan, TranscriptText);
        hasLoadedTranscript = true;
        if (meetingIntelligenceCoordinator is { } coordinator)
        {
            await coordinator.NotifyTranscriptSavedAsync();
            ApplyMeetingIntelligenceSnapshot(coordinator.Snapshot);
        }
        MeetingIntelligenceStatus = "逐字稿已儲存；既有摘要已依新的逐字稿版本標示為需要重新產生。";
        await RefreshLibraryCoreAsync();
    });

    public Task CopyTranscriptAsync() => RunOperationAsync(() =>
    {
        var package = new DataPackage();
        package.SetText(TranscriptText);
        Clipboard.SetContent(package);
        MeetingIntelligenceStatus = "逐字稿已複製到剪貼簿。";
        return Task.CompletedTask;
    });

    public Task ExportTranscriptAsync() => RunOperationAsync(async () =>
    {
        var item = SelectedLibraryItem
            ?? throw new InvalidOperationException("請先選取錄音。");
        var exportFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "Teams Recorder Exports");
        Directory.CreateDirectory(exportFolder);
        var invalid = Path.GetInvalidFileNameChars();
        var safeName = new string(item.DisplayName.Select(character => invalid.Contains(character) ? '_' : character).ToArray()).Trim();
        if (safeName.Length == 0) safeName = "transcript";
        var stamp = DateTimeOffset.Now.ToString("yyyyMMdd-HHmmssfff", CultureInfo.InvariantCulture);
        var path = Path.Combine(exportFolder, $"{safeName}-{stamp}.txt");
        if (File.Exists(path))
            path = Path.Combine(exportFolder, $"{safeName}-{stamp}-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(path, TranscriptText, new System.Text.UTF8Encoding(false));
        MeetingIntelligenceStatus = $"逐字稿已匯出：{path}";
    });

    public Task SaveMeetingIntelligenceEditsAsync() => RunOperationAsync(async () =>
    {
        var plan = await GetSelectedManagedSessionPlanAsync();
        var publisher = new MeetingIntelligenceArtifactPublisher();
        var artifact = await publisher.LoadArtifactAsync(plan)
            ?? throw new InvalidOperationException("尚未產生可編輯的 Meeting Intelligence。");
        var edited = artifact with
        {
            SchemaVersion = MeetingIntelligenceArtifact.CurrentSchemaVersion,
            Summary = MeetingIntelligenceOutputValidator.ValidateSummary(MeetingIntelligenceSummary),
            SuggestedTitle = MeetingIntelligenceOutputValidator.ValidateTitle(MeetingIntelligenceSuggestedTitle),
            ContentOrigin = MeetingIntelligenceContentOrigin.Edited,
            EditedAt = DateTimeOffset.UtcNow,
        };
        await publisher.PublishAsync(plan, edited);
        if (meetingIntelligenceCoordinator is { } coordinator)
        {
            await coordinator.InitializeAsync();
            ApplyMeetingIntelligenceSnapshot(coordinator.Snapshot);
        }
        MeetingIntelligenceStatus = "摘要及建議標題已儲存。";
    });

    public Task ApplySuggestedTitleAsync() => RunOperationAsync(async () =>
    {
        if (string.IsNullOrWhiteSpace(MeetingIntelligenceSuggestedTitle))
            throw new InvalidOperationException("沒有可套用的建議標題。");
        var target = CaptureLibraryActionTarget(requireManaged: true);
        await ResolveCanonicalLibraryActionAsync(target);
        await Task.Run(async () => await GetLibraryService().UpdateMetadataAsync(
            target.Identity,
            MeetingIntelligenceSuggestedTitle,
            LibraryTagsText.Split([',', ';', '\r', '\n'],
                StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
            IsLibraryFavorite));
        await RefreshLibraryCoreAsync();
        MeetingIntelligenceStatus = "已套用建議標題。";
    });

    private async Task<RecordingSessionPlan> GetSelectedManagedSessionPlanAsync()
    {
        var target = CaptureLibraryActionTarget(requireManaged: true);
        var item = await ResolveCanonicalLibraryActionAsync(target);
        return CreateManagedSessionPlan(item);
    }

    private static RecordingSessionPlan CreateManagedSessionPlan(LibraryRecording item)
    {
        var folder = Path.GetFullPath(item.SessionPath);
        var provisionalPlan = new RecordingSessionPlan(
            item.Kind,
            folder,
            Path.Combine(folder, RecordingSessionLayout.FinalVideoFileName),
            Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName),
            Path.Combine(folder, RecordingSessionLayout.MetadataFileName),
            new StorageCapacityStatus(null, RecordingStorageDecision.Normal));
        ResolvedRecordingSessionMedia media;
        try
        {
            media = RecordingSessionAsrMediaResolver.Resolve(provisionalPlan);
        }
        catch (IOException)
        {
            throw new IOException("選取的項目不是可供 AI 處理的受管理錄音工作階段。");
        }

        return provisionalPlan with { FinalAudioPath = media.Path };
    }

    private async Task LoadAiWorkspaceAsync(LibraryRecording? item, long generation)
    {
        if (generation != aiWorkspaceLoadGeneration || isShuttingDown) return;

        DisposeMeetingIntelligenceCoordinator();
        hasLoadedTranscript = false;
        TranscriptText = string.Empty;
        MeetingIntelligenceSummary = string.Empty;
        MeetingIntelligenceSuggestedTitle = string.Empty;
        MeetingIntelligenceStatus = item is null
            ? "請選取有逐字稿的錄音。"
            : "正在載入逐字稿與 Meeting Intelligence…";
        NotifyAiWorkspaceStateChanged();
        if (item is not { IsManaged: true }) return;

        try
        {
            var plan = CreateManagedSessionPlan(item);
            var transcript = await new MeetingIntelligenceCanonicalTranscriptReader().ReadAsync(plan);
            var client = new OpenAICompatibleMeetingIntelligenceClient();
            var coordinator = new MeetingIntelligenceSessionCoordinator(
                plan,
                cancellationToken => (openAiProviderRepository
                    ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。"))
                    .SnapshotAsync(cancellationToken: cancellationToken),
                new OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
                    openAiProviderConnectionClient
                        ?? throw new InvalidOperationException("AI 供應商連線服務尚未準備完成。")),
                new MeetingIntelligencePipeline(client),
                titlePublisher: new WindowsMeetingIntelligenceTitlePublisher(GetLibraryService()));
            var intelligence = await coordinator.InitializeAsync();
            if (generation != aiWorkspaceLoadGeneration ||
                SelectedLibraryItem?.Identity != item.Identity || isShuttingDown)
            {
                coordinator.Dispose();
                client.Dispose();
                return;
            }

            meetingIntelligenceClient = client;
            meetingIntelligenceCoordinator = coordinator;
            coordinator.SnapshotChanged += OnMeetingIntelligenceSnapshotChanged;
            TranscriptText = transcript.Text;
            hasLoadedTranscript = true;
            ApplyMeetingIntelligenceSnapshot(intelligence);
        }
        catch (FileNotFoundException)
        {
            MeetingIntelligenceStatus = "此錄音尚未建立逐字稿。";
        }
        catch (IOException exception)
        {
            MeetingIntelligenceStatus = $"無法載入逐字稿：{exception.Message}";
        }
        catch (Exception exception)
        {
            MeetingIntelligenceStatus = $"無法準備 AI 工作區：{exception.Message}";
        }
        finally
        {
            NotifyAiWorkspaceStateChanged();
        }
    }

    private void OnMeetingIntelligenceSnapshotChanged(object? sender, MeetingIntelligenceSessionSnapshot changed)
    {
        if (!ReferenceEquals(sender, meetingIntelligenceCoordinator) || isShuttingDown) return;
        if (dispatcherQueue.HasThreadAccess) ApplyMeetingIntelligenceSnapshot(changed);
        else _ = dispatcherQueue.TryEnqueue(() =>
        {
            if (ReferenceEquals(sender, meetingIntelligenceCoordinator))
                ApplyMeetingIntelligenceSnapshot(changed);
        });
    }

    private void ApplyMeetingIntelligenceSnapshot(MeetingIntelligenceSessionSnapshot changed)
    {
        MeetingIntelligenceStatus = changed.StatusMessage;
        MeetingIntelligenceSummary = changed.Summary ?? string.Empty;
        MeetingIntelligenceSuggestedTitle = changed.SuggestedTitle ?? string.Empty;
        NotifyAiWorkspaceStateChanged();
    }

    private void DisposeMeetingIntelligenceCoordinator()
    {
        if (meetingIntelligenceCoordinator is { } coordinator)
        {
            coordinator.SnapshotChanged -= OnMeetingIntelligenceSnapshotChanged;
            coordinator.Dispose();
        }
        meetingIntelligenceCoordinator = null;
        meetingIntelligenceClient?.Dispose();
        meetingIntelligenceClient = null;
    }

    private void NotifyAiWorkspaceStateChanged()
    {
        OnPropertyChanged(nameof(CanStartOpenAiTranscription));
        OnPropertyChanged(nameof(CanImportAudioForTranscription));
        OnPropertyChanged(nameof(CanGenerateOpenAiSummary));
        OnPropertyChanged(nameof(CanCancelMeetingIntelligence));
        OnPropertyChanged(nameof(CanSaveTranscript));
        OnPropertyChanged(nameof(CanSaveMeetingIntelligence));
    }

    private async Task RestoreAppSettingsAsync()
    {
        try
        {
            pendingAppSettings = await appSettingsStore.LoadAsync();
            pendingSelectedApplicationExecutable = pendingAppSettings?.SelectedApplicationExecutable;
            restoreTeamsAutomaticRecordingAfterInitialization = pendingAppSettings?.LocalTeamsHeuristicAutoStartEnabled == true;
            if (!string.IsNullOrWhiteSpace(pendingAppSettings?.OutputFolder))
            {
                // This occurs before the native lifecycle is constructed, so the restored
                // folder becomes the lifecycle's initial storage root.
                OutputFolder = pendingAppSettings.OutputFolder;
            }
        }
        catch (Exception)
        {
            // Do not fail local recording because a non-secret preference file is stale.
            // Its detailed content (including the user's local folder) is intentionally
            // not surfaced in the UI or diagnostic status.
            pendingAppSettings = null;
            pendingSelectedApplicationExecutable = null;
            restoreTeamsAutomaticRecordingAfterInitialization = false;
            StatusText = "無法還原先前的應用程式設定；將使用安全預設值。";
        }
    }

    private void ApplyPendingAppSettingsAfterEndpointRefresh()
    {
        var saved = pendingAppSettings;
        pendingAppSettings = null;
        if (saved is null)
        {
            return;
        }

        SelectedRenderEndpoint = SelectSavedEndpoint(RenderEndpoints, saved.RenderEndpointId, EndpointChoice.SystemDefault, "已中斷的已儲存輸出裝置");
        if (!saved.RecordMicrophone)
        {
            SelectedMicrophoneEndpoint = EndpointChoice.NoMicrophone;
        }
        else if (saved.MicrophoneEndpointId is not null)
        {
            SelectedMicrophoneEndpoint = SelectSavedEndpoint(CaptureEndpoints, saved.MicrophoneEndpointId, EndpointChoice.NoMicrophone, "已中斷的已儲存麥克風");
        }
        // When a microphone was enabled but had no stable endpoint id, retain the
        // current communication/default selection chosen during endpoint refresh.

        SelectedCaptureSource = CaptureSources.FirstOrDefault(source =>
            source.Kind == (saved.CaptureSource == RecorderPersistedCaptureSource.SelectedApplication
                ? CaptureSourceKind.SelectedApplication
                : CaptureSourceKind.SystemAudio));
        if (saved.CaptureSource == RecorderPersistedCaptureSource.SelectedApplication)
        {
            // Only a sanitized executable basename may be restored. PID, process start
            // time, path, command line and window title are deliberately never saved.
            SelectedProcess = null;
            ProcessCatalogStatusText = pendingSelectedApplicationExecutable is null
                ? "已還原「指定應用程式」模式；請選取目前正在執行的應用程式。"
                : $"正在尋找已儲存的應用程式 {pendingSelectedApplicationExecutable}。";
        }
        IsFollowTeamsMuteEnabled = saved.FollowTeamsMuteEnabled;
        StatusText = "已還原本機錄音設定。";
    }

    private static EndpointChoice SelectSavedEndpoint(
        ObservableCollection<EndpointChoice> choices,
        string? endpointId,
        EndpointChoice defaultChoice,
        string unavailableLabel)
    {
        if (endpointId is null)
        {
            return defaultChoice;
        }
        var matching = choices.FirstOrDefault(choice => string.Equals(choice.EndpointId, endpointId, StringComparison.Ordinal));
        if (matching is not null)
        {
            return matching;
        }
        var unavailable = new EndpointChoice(endpointId, unavailableLabel, EndpointDefaultRole.None, IsAvailable: false);
        choices.Add(unavailable);
        return unavailable;
    }

    private RecorderAppSettings CaptureAppSettings() => new()
    {
        OutputFolder = OutputFolder,
        RenderEndpointId = SelectedRenderEndpoint?.EndpointId,
        RecordMicrophone = SelectedMicrophoneEndpoint is not null &&
            !ReferenceEquals(SelectedMicrophoneEndpoint, EndpointChoice.NoMicrophone),
        MicrophoneEndpointId = SelectedMicrophoneEndpoint?.EndpointId,
        CaptureSource = SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
            ? RecorderPersistedCaptureSource.SelectedApplication
            : RecorderPersistedCaptureSource.SystemLoopback,
        SelectedApplicationExecutable = SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication
            ? SelectedProcess?.ProcessName
            : null,
        TeamsMuteSyncEnabled = false,
        TeamsAutomaticRecordingEnabled = IsLocalHeuristicAutoStartEnabled,
        LocalTeamsHeuristicAutoStartEnabled = IsLocalHeuristicAutoStartEnabled,
        FollowTeamsMuteEnabled = IsFollowTeamsMuteEnabled,
    };

    private void PersistAppSettingsInBackground()
    {
        if (!isInitialized || isShuttingDown)
        {
            return;
        }
        _ = PersistAppSettingsSilentlyAsync();
    }

    private async Task PersistAppSettingsSilentlyAsync()
    {
        try { await PersistAppSettingsAsync(); }
        catch (Exception) { /* A later change or orderly shutdown will retry; recording remains local. */ }
    }

    private async Task PersistAppSettingsAsync()
    {
        await appSettingsWriteGate.WaitAsync();
        try
        {
            await appSettingsStore.SaveAsync(CaptureAppSettings());
        }
        finally
        {
            appSettingsWriteGate.Release();
        }
    }

    /// <summary>
    /// The former Teams WebSocket pairing credential is no longer consumed by
    /// Windows.  Remove it best-effort at startup so a stale secret cannot be
    /// silently retained merely because the app is now using local monitoring.
    /// Failure is intentionally non-fatal and never displayed with a path or
    /// DPAPI diagnostic.
    /// </summary>
    private static Task ClearRetiredTeamsPairingCredentialAsync()
    {
        try
        {
            var retiredPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TeamsRecorder",
                "teams-pairing-token.bin");
            File.Delete(retiredPath);
        }
        catch (Exception)
        {
            // Local recording and the new no-credential Teams integration are
            // still safe if an old store cannot be cleaned in this process.
        }

        return Task.CompletedTask;
    }

    private void StartRecorderControlRuntime()
    {
        if (isShuttingDown || recorderControlRuntime is not null)
        {
            return;
        }

        try
        {
            recorderControlOwner = new RecorderControlLifecycleOwnerAdapter(dispatcherQueue, this);
            recorderControlRuntime = new RecorderControlServerRuntime(recorderControlOwner);
            recorderControlRuntime.Start();
        }
        catch (Exception)
        {
            // The named pipe is an optional local-control surface.  Keep the
            // recorder usable rather than leaking a transport exception or
            // failing application startup.
            recorderControlRuntime?.Dispose();
            recorderControlRuntime = null;
            recorderControlOwner?.Dispose();
            recorderControlOwner = null;
            ErrorText = "本機錄音控制服務無法啟動；錄音功能仍可在此視窗使用。";
        }
    }

    private async Task StopRecorderControlRuntimeAsync()
    {
        var runtime = recorderControlRuntime;
        recorderControlRuntime = null;
        recorderControlOwner = null;

        if (runtime is not null)
        {
            try
            {
                await runtime.StopAsync();
            }
            catch (Exception)
            {
                // Shutdown still has to reach durable recorder finalization.
            }
            finally
            {
                runtime.Dispose();
            }
        }

        // Do not dispose the adapter gate here: StopAsync closes the listener
        // but an already-dispatched UI callback may still be unwinding.  The
        // adapter becomes unreachable after that callback completes.
    }

    public async Task InitializeAsync()
    {
        if (isInitialized || isInitializing)
        {
            return;
        }

        isInitializing = true;
        IsBusy = true;
        try
        {
            StatusText = "正在還原本機錄音設定…";
            await RestoreAppSettingsAsync();
            await ClearRetiredTeamsPairingCredentialAsync();
            StatusText = "正在初始化 AI 與播放服務…";
            await InitializeOpenAiProviderAsync();
            StatusText = "正在載入原生錄音 bridge…";
            nativeRecorderBridge = new NativeRecorderBridge();
            recordingLifecycle = new RecordingLifecycleService(
                nativeRecorderBridge,
                OutputFolder,
                verifiedVideoCapturePipeline: true);
            recordingLifecycle.SnapshotChanged += OnSnapshotChanged;
            InitializeGlobalMuteHotKey();
            SetRecorderAvailable(true);
            StatusText = "正在整理 Windows 音訊裝置…";
            await RefreshEndpointsCoreAsync(announce: false);
            await RefreshTeamsWindowsCoreAsync();
            await InitializeVirtualMicrophonePreviewAsync();
            if (SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication)
            {
                await RefreshProcessCatalogCoreAsync();
            }
            RefreshStorageReadiness();
            StatusText = "正在檢查中斷復原與錄音庫…";
            await RecoverAtStartupAsync();
            StatusText = "正在啟動本機 Teams 會議偵測…";
            await InitializeLocalTeamsAutomationAsync();
            ApplySnapshot(recordingLifecycle.Snapshot);
            inputMuteTimer.Start();
            if (IsFollowTeamsMuteEnabled)
            {
                teamsMuteFollowTimer.Start();
            }
            _ = RefreshLibraryAfterInitializationAsync();
            StatusText = "錄音器已就緒。";
        }
        catch (Exception exception)
        {
            await DisposeLocalTeamsAutomationAsync();
            if (recordingLifecycle is not null)
            {
                recordingLifecycle.SnapshotChanged -= OnSnapshotChanged;
                recordingLifecycle.Dispose();
                recordingLifecycle = null;
                nativeRecorderBridge = null;
            }
            DisposeGlobalMuteHotKey();
            SetRecorderAvailable(false);
            StatusText = "原生錄音元件無法使用";
            ErrorText = CreateInitializationError(exception);
        }
        finally
        {
            isInitialized = true;
            isInitializing = false;
            IsBusy = false;
            UpdateCommandStates();
        }
    }

    public async Task ShutdownAsync()
    {
        if (isShuttingDown)
        {
            return;
        }

        isShuttingDown = true;
        telemetryTimer.Stop();
        playbackTimer.Stop();
        teamsLocalHeuristicTimer.Stop();
        inputMuteTimer.Stop();
        teamsMuteFollowTimer.Stop();
        UpdateCommandStates();

        // Close the local control endpoint before finalization.  A pipe request
        // can no longer race a stop/start with the recovery checkpoint below.
        await StopRecorderControlRuntimeAsync();

        try
        {
            await PersistAppSettingsAsync();
        }
        catch (Exception)
        {
            // The recording lifecycle must still be finalized safely even if a public
            // preference file cannot be written during shutdown.
            ErrorText = "無法儲存應用程式設定；下次啟動可能需要重新選擇裝置。";
        }

        var activeLifecycle = recordingLifecycle;
        // Media publication is the first shutdown dependency. A failure while
        // tearing down Teams, hotkeys, playback, or AI services must never skip
        // the recorder's final durable checkpoint/finalization attempt.
        if (activeLifecycle is not null)
        {
            try
            {
                // A request accepted just before the pipe was closed may still
                // be unwinding on the UI dispatcher.  Join the same VM gate
                // before finalization so it cannot overlap a start/stop.
                var finalization = await RunRecordingLifecycleActionAsync(
                    _ => activeLifecycle.FinalizeForRecoveryAsync(),
                    CancellationToken.None);
                if (!finalization.Published && finalization.Error is not null)
                {
                    // The application service has released the active plan but
                    // deliberately retained every recovery artifact.
                    ErrorText = finalization.Error.Message;
                }
            }
            catch (Exception exception)
            {
                ErrorText = $"Shutdown finalization failed; recovery evidence was retained: {exception.Message}";
            }
            finally
            {
                activeLifecycle.SnapshotChanged -= OnSnapshotChanged;
            }
        }

        if (virtualMicPublisher is not null)
        {
            await virtualMicPublisher.DisposeAsync();
            virtualMicPublisher = null;
        }
        recordingLifecycle = null;
        activeLifecycle?.Dispose();
        nativeRecorderBridge = null;
        await DisposeLocalTeamsAutomationAsync();
        DisposeGlobalMuteHotKey();
        recorderMicrophoneMute.Changed -= OnInputMuteChanged;
        mediaPlayer?.Dispose();
        mediaPlayer = null;
        OnPropertyChanged(nameof(PlaybackMediaPlayer));
        transcriptionCoordinator?.Dispose();
        transcriptionCoordinator = null;
        DisposeMeetingIntelligenceCoordinator();
        openAiAsrTransport?.Dispose();
        openAiAsrTransport = null;
        openAiProviderConnectionClient?.Dispose();
        openAiProviderConnectionClient = null;
        openAiProviderRepository = null;
        isOpenAiProviderInitialized = false;
        SetRecorderAvailable(false);
    }

    private async Task InitializeVirtualMicrophonePreviewAsync()
    {
        if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            VirtualMicrophoneStatusText = "正式版本已安全停用 test-signed 虛擬麥克風。";
            return;
        }

        var bridge = nativeRecorderBridge;
        var lifecycle = recordingLifecycle;
        if (bridge is null || lifecycle is null)
        {
            VirtualMicrophoneStatusText = "原生麥克風 PCM 來源尚未就緒。";
            return;
        }

        try
        {
            var identity = await new VirtualMicTrustedEndpointStore().LoadAsync();
            if (identity is null)
            {
                VirtualMicrophoneStatusText = "尚未配對 test-signed 虛擬麥克風端點。";
                return;
            }
            var endpoints = await lifecycle.RefreshEndpointsAsync();
            if (!endpoints.IsSuccess)
                throw new InvalidOperationException(endpoints.Operation.Error ?? "無法列舉音訊端點。");
            virtualMicPublisher = await VirtualMicPublisherRuntime.StartAsync(
                bridge, identity, endpoints.Endpoints);
            VirtualMicrophoneStatusText = "虛擬麥克風預覽已就緒；選取實體麥克風開始錄音後會即時發佈。";
        }
        catch (Exception error)
        {
            VirtualMicrophoneStatusText = $"虛擬麥克風不可用：{error.Message}";
        }
    }

    private async Task InitializeLocalTeamsAutomationAsync()
    {
        teamsAutomaticRecorder = new TeamsAutomaticRecordingController(
            StartTeamsAutomaticRecordingAsync,
            StopTeamsAutomaticRecordingAsync);
        teamsAutomaticRecorder.SnapshotChanged += OnTeamsAutomaticRecordingSnapshotChanged;
        teamsAutomaticRecorder.OperationFailed += OnTeamsAutomaticRecordingOperationFailed;
        teamsLocalHeuristicHost = new TeamsLocalHeuristicAutoStartHost(
            new TeamsLocalMeetingSignalSampler(processCatalog, GetRecordingLifecycle()),
            ForwardLocalHeuristicJoinedEvidenceAsync,
            ForwardLocalHeuristicEndedEvidenceAsync);
        isLocalHeuristicAutoStartEnabled = restoreTeamsAutomaticRecordingAfterInitialization;
        restoreTeamsAutomaticRecordingAfterInitialization = false;
        teamsLocalHeuristicTimer.Start();
        if (IsLocalHeuristicAutoStartEnabled)
        {
            await teamsAutomaticRecorder.SetEnabledAsync(true);
            teamsAutomaticSnapshot = teamsAutomaticRecorder.Snapshot;
        }
        OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
        OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
    }

    private async Task DisposeLocalTeamsAutomationAsync()
    {
        teamsLocalHeuristicTimer.Stop();
        var host = teamsLocalHeuristicHost;
        teamsLocalHeuristicHost = null;
        teamsLocalHeuristicSnapshot = null;
        if (host is not null) await host.DisposeAsync();
        await DisposeTeamsAutomaticRecordingAsync();
    }

    private async void OnTeamsLocalHeuristicTimerTick(DispatcherQueueTimer _, object __)
    {
        var host = teamsLocalHeuristicHost;
        if (isShuttingDown || host is null || !IsLocalHeuristicAutoStartEnabled || teamsAutomaticRecorder?.Snapshot.IsEnabled != true)
            return;
        try
        {
            var changed = await host.PollAsync(new TeamsLocalHeuristicPolicy(true));
            if (!isShuttingDown && ReferenceEquals(host, teamsLocalHeuristicHost))
            {
                teamsLocalHeuristicSnapshot = changed;
                OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception exception) { ErrorText = $"本機 Teams 會議偵測暫時無法使用：{exception.Message}"; }
    }

    private async Task ForwardLocalHeuristicJoinedEvidenceAsync(CancellationToken cancellationToken)
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic?.Snapshot.IsEnabled == true && IsLocalHeuristicAutoStartEnabled)
            await automatic.SetMeetingPresenceAsync(true, cancellationToken);
    }

    private async Task ForwardLocalHeuristicEndedEvidenceAsync(CancellationToken cancellationToken)
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic?.Snapshot.IsEnabled == true && IsLocalHeuristicAutoStartEnabled)
            await automatic.SetMeetingPresenceAsync(false, cancellationToken);
    }

    private async Task RevokeLocalTeamsAutomationConsentAsync(int consentRevision)
    {
        var automatic = teamsAutomaticRecorder;
        var host = teamsLocalHeuristicHost;
        var wasAutomaticEnabled = automatic?.Snapshot.IsEnabled == true;
        try
        {
            if (consentRevision != Volatile.Read(ref localTeamsAutomationConsentRevision) ||
                IsLocalHeuristicAutoStartEnabled)
            {
                return;
            }

            if (wasAutomaticEnabled)
            {
                // The reducer transfers an active automatic capture to manual
                // ownership; withdrawing consent never discards media.
                await automatic!.SetEnabledAsync(false);
            }

            if (consentRevision != Volatile.Read(ref localTeamsAutomationConsentRevision) ||
                IsLocalHeuristicAutoStartEnabled)
            {
                // Consent was restored while the asynchronous disable was in
                // flight. Restore the previous controller state rather than
                // allowing a stale revoke to win after the newer UI choice.
                if (wasAutomaticEnabled && automatic is not null)
                {
                    await automatic.SetEnabledAsync(true);
                }
                return;
            }

            if (host is not null)
            {
                await host.ResetAsync();
            }

            if (!isShuttingDown && ReferenceEquals(automatic, teamsAutomaticRecorder))
            {
                teamsAutomaticSnapshot = automatic?.Snapshot ?? TeamsAutoMeetingSnapshot.Initial;
                teamsLocalHeuristicSnapshot = null;
                OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
                OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
                NotifyRecordingOverlayStateChanged();
                UpdateCommandStates();
            }
        }
        catch (ObjectDisposedException) { }
        catch (OperationCanceledException) { }
        catch (Exception exception)
        {
            if (!isShuttingDown) ErrorText = $"無法停用本機 Teams 自動錄音：{exception.Message}";
        }
    }

    private async Task EnableTeamsAutomaticRecordingAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !CanEnableTeamsAutomaticRecording)
        {
            return;
        }

        isTeamsAutomaticRecordingOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            await automatic.SetEnabledAsync(true);
            teamsAutomaticSnapshot = automatic.Snapshot;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
            PersistAppSettingsInBackground();
        }
        catch (Exception exception)
        {
            ErrorText = $"無法啟用 Teams 自動錄音：{exception.Message}";
        }
        finally
        {
            isTeamsAutomaticRecordingOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private async Task DisableTeamsAutomaticRecordingAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !IsTeamsAutomaticRecordingEnabled)
        {
            return;
        }

        isTeamsAutomaticRecordingOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            // Disabling automation never stops an in-progress capture.  The reducer transfers
            // ownership to the user, preventing an unexpected loss of a recording.
            await automatic.SetEnabledAsync(false);
            teamsAutomaticSnapshot = automatic.Snapshot;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
            PersistAppSettingsInBackground();
        }
        catch (Exception exception)
        {
            ErrorText = $"無法停用 Teams 自動錄音：{exception.Message}";
        }
        finally
        {
            isTeamsAutomaticRecordingOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private async Task CancelTeamsAutomaticRecordingStartAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !CanCancelTeamsAutomaticRecordingStart)
        {
            return;
        }

        isTeamsAutomaticRecordingOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            await automatic.CancelStartCountdownAsync();
        }
        catch (ObjectDisposedException)
        {
            // Shutdown may win a click already queued by the compact window.
        }
        catch (Exception exception)
        {
            ErrorText = $"無法取消本次 Teams 自動開始：{exception.Message}";
        }
        finally
        {
            isTeamsAutomaticRecordingOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private Task StopRecordingFromOverlayAsync() => StopAsync();

    private async Task DisposeTeamsAutomaticRecordingAsync()
    {
        var automatic = teamsAutomaticRecorder;
        teamsAutomaticRecorder = null;
        teamsAutomaticSnapshot = TeamsAutoMeetingSnapshot.Initial;
        OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
        OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
        NotifyRecordingOverlayStateChanged();

        if (automatic is null)
        {
            return;
        }

        automatic.SnapshotChanged -= OnTeamsAutomaticRecordingSnapshotChanged;
        automatic.OperationFailed -= OnTeamsAutomaticRecordingOperationFailed;
        await automatic.DisposeAsync();
    }

    private void OnTeamsAutomaticRecordingSnapshotChanged(object? sender, TeamsAutoMeetingSnapshot changed)
    {
        void Apply()
        {
            if (isShuttingDown || !ReferenceEquals(sender, teamsAutomaticRecorder))
            {
                return;
            }

            teamsAutomaticSnapshot = changed;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
            NotifyRecordingOverlayStateChanged();
            UpdateCommandStates();
        }

        if (dispatcherQueue.HasThreadAccess) Apply();
        else _ = dispatcherQueue.TryEnqueue(Apply);
    }

    private void OnTeamsAutomaticRecordingOperationFailed(object? _, string detail) =>
        ReportTeamsAutomaticRecordingFailure(detail);

    private void ReportTeamsAutomaticRecordingFailure(string detail)
    {
        void Apply()
        {
            if (!isShuttingDown)
            {
                ErrorText = $"Teams 自動錄音操作失敗：{detail}";
            }
        }

        if (dispatcherQueue.HasThreadAccess) Apply();
        else _ = dispatcherQueue.TryEnqueue(Apply);
    }

    private Task ToggleLocalMicrophoneMuteAsync()
    {
        recorderMicrophoneMute.SetLocalMuted(!recorderMicrophoneMute.IsLocalMuted);
        return Task.CompletedTask;
    }

    private void InitializeGlobalMuteHotKey()
    {
        try
        {
            globalHotKeyRegistrar = new WindowsGlobalHotKeyRegistrar();
            globalMuteHotKey = new GlobalMuteHotKeyService(recorderMicrophoneMute, globalHotKeyRegistrar);
            globalMuteHotKeyStatus = "Ctrl+Alt+M 可在任何視窗切換本機錄音麥克風靜音。";
        }
        catch (Exception exception)
        {
            DisposeGlobalMuteHotKey();
            globalMuteHotKeyStatus = $"Ctrl+Alt+M 無法註冊：{exception.Message}";
        }
        OnPropertyChanged(nameof(GlobalMuteHotKeyStatus));
    }

    private void DisposeGlobalMuteHotKey()
    {
        globalMuteHotKey?.Dispose();
        globalMuteHotKey = null;
        globalHotKeyRegistrar?.Dispose();
        globalHotKeyRegistrar = null;
    }

    private void OnInputMuteChanged(bool muted)
    {
        void Apply()
        {
            if (isShuttingDown)
            {
                return;
            }

            ApplyRecordingMicrophoneMute(muted);
            OnPropertyChanged(nameof(IsRecordingMicrophoneMuted));
            OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
            OnPropertyChanged(nameof(MicrophoneHealthText));
            NotifyLiveAudioHealthChanged();
        }

        if (dispatcherQueue.HasThreadAccess)
        {
            Apply();
        }
        else
        {
            _ = dispatcherQueue.TryEnqueue(Apply);
        }
    }

    private void ApplyRecordingMicrophoneMute(bool muted)
    {
        if (snapshot.State != RecordingCoordinatorState.Recording ||
            SelectedMicrophoneEndpoint?.EndpointId is null ||
            recordingLifecycle is null)
        {
            return;
        }

        var result = recordingLifecycle.SetMicrophoneMuted(muted);
        if (!result.IsSuccess)
        {
            ErrorText = result.Error ?? "無法更新錄音麥克風靜音狀態。";
        }
    }

    private bool IsSetupEditable =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        snapshot.State is RecordingCoordinatorState.Ready or
            RecordingCoordinatorState.Stopped or
            RecordingCoordinatorState.Failed;

    private bool SelectedDevicesReady =>
        (SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication ||
         SelectedRenderEndpoint is { IsAvailable: true }) &&
        (SelectedMicrophoneEndpoint is null or { EndpointId: null } or { IsAvailable: true });

    private bool SelectedProcessReady =>
        SelectedCaptureSource?.Kind != CaptureSourceKind.SelectedApplication ||
        SelectedProcess is { IsAvailable: true };

    private bool SelectedVideoWindowReady =>
        !IsSharedContentCaptureEnabled || SelectedVideoCaptureWindow is not null;

    private bool CanStart =>
        IsSetupEditable &&
        storageCanStart &&
        SelectedDevicesReady &&
        SelectedProcessReady &&
        SelectedVideoWindowReady &&
        recordingLifecycle is not { HasPublicationInProgress: true };

    private bool CanStop =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        (snapshot.State is RecordingCoordinatorState.Starting or
            RecordingCoordinatorState.Recording or
            RecordingCoordinatorState.Stopping ||
            snapshot.State == RecordingCoordinatorState.Faulted && snapshot.NeedsNativeCleanup);

    private bool CanRefreshDevices => IsSetupEditable;

    private bool CanRefreshProcessCatalog => IsSetupEditable;

    private bool CanRefreshTeamsWindows => IsTeamsWindowSelectionEnabled;

    private bool CanRefreshLibrary => !IsBusy && !IsLibraryLoading && !isShuttingDown;

    private bool CanPlay => mediaPlayer is not null && SelectedLibraryItem is { IsPlayable: true } &&
                            !IsBusy && !IsLibraryLoading && !isShuttingDown;

    private bool CanPause =>
        mediaPlayer?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing &&
        !isShuttingDown;

    public bool CanManageLibrary =>
        SelectedLibraryItem is { IsManaged: true } &&
        !isShuttingDown;

    public bool CanConfirmRecycle =>
        IsRecycleConfirmationVisible &&
        pendingRecycleIdentity is not null &&
        !isShuttingDown;

    private Task StartAsync() => RunOperationAsync(() =>
        RunRecordingLifecycleActionAsync(async cancellationToken =>
        {
            var result = await StartRecordingAsync(RecordingSessionKind.Manual, cancellationToken: cancellationToken);
            if (result.State == RecordingCoordinatorState.Recording)
            {
                await NotifyManualRecordingStartedAsync();
            }
            return true;
        }, CancellationToken.None));

    private Task StartTestAsync() => RunOperationAsync(() =>
        RunRecordingLifecycleActionAsync(async cancellationToken =>
        {
            var result = await StartRecordingAsync(
                RecordingSessionKind.Test,
                TimeSpan.FromSeconds(10),
                cancellationToken);
            if (result.State == RecordingCoordinatorState.Recording)
            {
                pendingTestPlaybackGeneration = result.Generation;
                await NotifyManualRecordingStartedAsync();
            }
            return true;
        }, CancellationToken.None));

    private Task StopAsync() => RunOperationAsync(() =>
        RunRecordingLifecycleActionAsync(async cancellationToken =>
        {
            await StopRecordingCoreAsync(suppressAutomaticRestart: true, cancellationToken);
            return true;
        }, CancellationToken.None));

    private async Task StopRecordingCoreAsync(bool suppressAutomaticRestart, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        pendingTestPlaybackGeneration = null;
        var automatic = teamsAutomaticRecorder;
        if (suppressAutomaticRestart && automatic?.Snapshot.RecordingOwner == RecordingOwner.TeamsAutomatic)
        {
            // An explicit UI or pipe Stop is a user decision.  Suppress any
            // restart for the current meeting before ending this capture.
            await automatic.SuppressUntilMeetingEndsAsync(cancellationToken);
        }

        var result = await GetRecordingLifecycle().StopAsync();
        ApplySnapshot(result);
        await EnsureSessionPublishedAsync();
        await RefreshLibraryCoreAsync();
        await NotifyManualRecordingStoppedAsync();
    }

    private async Task<T> RunRecordingLifecycleActionAsync<T>(
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        await recordingLifecycleActionGate.WaitAsync(cancellationToken);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            return await action(cancellationToken);
        }
        finally
        {
            recordingLifecycleActionGate.Release();
        }
    }

    private async Task NotifyManualRecordingStartedAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !automatic.Snapshot.IsEnabled)
        {
            return;
        }

        try { await automatic.NotifyManualRecordingStartedAsync(); }
        catch (ObjectDisposedException) { }
    }

    private async Task NotifyManualRecordingStoppedAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null)
        {
            return;
        }

        try { await automatic.NotifyManualRecordingStoppedAsync(); }
        catch (ObjectDisposedException) { }
    }

    private Task<T> InvokeOnUiAsync<T>(Func<Task<T>> operation)
    {
        if (dispatcherQueue.HasThreadAccess)
        {
            return operation();
        }

        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!dispatcherQueue.TryEnqueue(async () =>
            {
                try { completion.TrySetResult(await operation()); }
                catch (Exception exception) { completion.TrySetException(exception); }
            }))
        {
            completion.TrySetException(new InvalidOperationException("WinUI dispatcher is unavailable."));
        }

        return completion.Task;
    }

    private Task<TeamsAutomaticStartResult> StartTeamsAutomaticRecordingAsync(CancellationToken cancellationToken) =>
        InvokeOnUiAsync(() => StartTeamsAutomaticRecordingOnUiAsync(cancellationToken));

    private Task<TeamsAutomaticStartResult> StartTeamsAutomaticRecordingOnUiAsync(CancellationToken cancellationToken) =>
        RunRecordingLifecycleActionAsync(
            _ => StartTeamsAutomaticRecordingOnUiCoreAsync(cancellationToken),
            cancellationToken);

    private async Task<TeamsAutomaticStartResult> StartTeamsAutomaticRecordingOnUiCoreAsync(CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested || isShuttingDown)
        {
            return TeamsAutomaticStartResult.BlockedBy("應用程式正在停止。" );
        }

        if (!IsLocalHeuristicAutoStartEnabled)
        {
            return TeamsAutomaticStartResult.BlockedBy("Teams 尚未提供可信的進行中會議狀態。" );
        }

        if (!CanStart)
        {
            return TeamsAutomaticStartResult.BlockedBy("錄音尚未就緒；請檢查裝置、可用容量與目前錄音狀態。" );
        }

        IsBusy = true;
        try
        {
            var result = await StartRecordingAsync(RecordingSessionKind.Meeting, cancellationToken: cancellationToken);
            if (result.State != RecordingCoordinatorState.Recording)
            {
                return TeamsAutomaticStartResult.Failed(result.Error ?? "原生錄音元件沒有進入錄音狀態。" );
            }

            if (cancellationToken.IsCancellationRequested || isShuttingDown)
            {
                // StartMixedAsync has no cancellation token.  If cancellation arrived during it,
                // immediately finish the just-created capture while the bridge is still alive.
                var stopped = await GetRecordingLifecycle().StopAsync();
                ApplySnapshot(stopped);
                await EnsureSessionPublishedAsync();
                await RefreshLibraryCoreAsync();
                return TeamsAutomaticStartResult.BlockedBy("Teams 會議狀態已改變，已取消剛開始的錄音。" );
            }

            return TeamsAutomaticStartResult.Succeeded();
        }
        catch (Exception exception)
        {
            // RecordingLifecycleService clears the session plan on a failed start.
            ErrorText = $"Teams 自動錄音無法開始：{exception.Message}";
            return TeamsAutomaticStartResult.Failed(exception.Message);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task StopTeamsAutomaticRecordingAsync(CancellationToken cancellationToken)
    {
        await InvokeOnUiAsync(() => RunRecordingLifecycleActionAsync(async lifecycleCancellationToken =>
        {
            if (isShuttingDown || cancellationToken.IsCancellationRequested || recordingLifecycle is null ||
                snapshot.State is not (RecordingCoordinatorState.Starting or RecordingCoordinatorState.Recording or RecordingCoordinatorState.Stopping))
            {
                return true;
            }

            IsBusy = true;
            try
            {
                var stopped = await recordingLifecycle.StopAsync();
                ApplySnapshot(stopped);
                await EnsureSessionPublishedAsync();
                await RefreshLibraryCoreAsync();
                return true;
            }
            catch (Exception exception)
            {
                ErrorText = $"Teams 自動錄音無法停止：{exception.Message}";
                throw;
            }
            finally
            {
                IsBusy = false;
            }
        }, cancellationToken));
    }

    private Task RefreshEndpointsAsync() => RunOperationAsync(
        () => RefreshEndpointsCoreAsync(announce: true));

    private Task RefreshProcessCatalogAsync() => RunOperationAsync(RefreshProcessCatalogCoreAsync);

    private Task RefreshTeamsWindowsAsync() => RunOperationAsync(RefreshTeamsWindowsCoreAsync);

    private async Task RefreshTeamsWindowsCoreAsync()
    {
        var previous = SelectedVideoCaptureWindow?.Target;
        var targets = await Task.Run(videoTargetCatalog.ListTargets);
        TeamsCaptureWindows.Clear();
        foreach (var target in targets) TeamsCaptureWindows.Add(new VideoCaptureWindowChoice(target));
        SelectedVideoCaptureWindow = previous is null
            ? TeamsCaptureWindows.FirstOrDefault()
            : TeamsCaptureWindows.FirstOrDefault(choice =>
                VideoCaptureTargetSelection.Resolve(previous, [choice.Target]) is not null);
    }

    internal RecorderCrashContext CaptureCrashContext() => new(
        snapshot.State.ToString(),
        recordingStartedAt is null ? null : Math.Max(0, (long)elapsed.TotalSeconds),
        storageCapacity?.AvailableBytes,
        snapshot.HasRecoverableFault,
        snapshot.Request?.Mode.ToString() ?? "none");

    public Task<RecorderControlStatus> GetRecorderControlStatusAsync(CancellationToken cancellationToken)
    {
        // The named-pipe status request calls this directly even while the UI
        // dispatcher is occupied by bounded startup work. Keep this method to
        // atomic field and immutable snapshot reads; all mutations remain
        // serialized through RecorderControlLifecycleOwnerAdapter.
        cancellationToken.ThrowIfCancellationRequested();
        var state = !isInitializing && isInitialized && !isRecorderAvailable
            ? RecorderControlRecordingState.Faulted
            : snapshot.State switch
        {
            RecordingCoordinatorState.Ready or RecordingCoordinatorState.Stopped => RecorderControlRecordingState.Idle,
            RecordingCoordinatorState.Starting => RecorderControlRecordingState.Starting,
            RecordingCoordinatorState.Recording => RecorderControlRecordingState.Recording,
            RecordingCoordinatorState.Stopping => RecorderControlRecordingState.Stopping,
            _ => RecorderControlRecordingState.Faulted,
        };
        var operation = isShuttingDown || isFaultFinalizationInProgress
            ? RecorderControlLifecycleOperation.Finalize
            : snapshot.State == RecordingCoordinatorState.Starting
                ? RecorderControlLifecycleOperation.Start
                : snapshot.State == RecordingCoordinatorState.Stopping
                    ? RecorderControlLifecycleOperation.Stop
                    : recorderControlStopTask is { IsCompleted: false }
                        ? RecorderControlLifecycleOperation.Stop
                    : isInitializing
                        ? RecorderControlLifecycleOperation.Refresh
                        : RecorderControlLifecycleOperation.None;
        var version = typeof(RecordingViewModel).Assembly.GetName().Version?.ToString() ?? "0.0.0";
        return Task.FromResult(new RecorderControlStatus(
            AppRunning: !isShuttingDown,
            AppVersion: version,
            RecordingState: state,
            LifecycleOperation: operation,
            ElapsedSeconds: state == RecorderControlRecordingState.Recording
                ? Math.Clamp((long)elapsed.TotalSeconds, 0, 31_536_000)
                : null,
            MicrophoneMuted: recorderMicrophoneMute.IsMuted,
            AutoModeEnabled: IsTeamsAutomaticRecordingEnabled));
    }

    public async Task<RecorderControlActionResult> StartRecorderControlAsync(CancellationToken cancellationToken)
    {
        if (isShuttingDown || !isInitialized || recordingLifecycle is null || !isRecorderAvailable)
        {
            return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
        }

        if (snapshot.State == RecordingCoordinatorState.Recording)
        {
            return RecorderControlActionResult.NoOp();
        }

        if (IsBusy || snapshot.State is RecordingCoordinatorState.Starting or RecordingCoordinatorState.Stopping)
        {
            return RecorderControlActionResult.Rejected(RecorderControlErrorCode.Busy);
        }

        return await RunRecordingLifecycleActionAsync(async token =>
        {
            if (isShuttingDown || !CanStart)
            {
                return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
            }

            IsBusy = true;
            try
            {
                var result = await StartRecordingAsync(RecordingSessionKind.Manual, cancellationToken: token);
                if (result.State != RecordingCoordinatorState.Recording)
                {
                    return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
                }

                await NotifyManualRecordingStartedAsync();
                return RecorderControlActionResult.Accepted();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception)
            {
                return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
            }
            finally
            {
                IsBusy = false;
            }
        }, cancellationToken);
    }

    public Task<RecorderControlActionResult> StopRecorderControlAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (isShuttingDown || recordingLifecycle is null)
        {
            return Task.FromResult(RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady));
        }

        if (recorderControlStopTask is { IsCompleted: false })
        {
            return Task.FromResult(RecorderControlActionResult.NoOp());
        }

        if (snapshot.State is RecordingCoordinatorState.Ready or RecordingCoordinatorState.Stopped or RecordingCoordinatorState.Failed)
        {
            return Task.FromResult(RecorderControlActionResult.NoOp());
        }

        if (IsBusy)
        {
            return Task.FromResult(RecorderControlActionResult.Rejected(RecorderControlErrorCode.Busy));
        }

        var stopTask = StopRecorderControlInBackgroundAsync();
        recorderControlStopTask = stopTask;
        _ = ObserveRecorderControlStopAsync(stopTask);
        return Task.FromResult(RecorderControlActionResult.Accepted());
    }

    private async Task StopRecorderControlInBackgroundAsync()
    {
        await RunRecordingLifecycleActionAsync(async token =>
        {
            if (isShuttingDown || recordingLifecycle is null)
            {
                return true;
            }

            IsBusy = true;
            try
            {
                await StopRecordingCoreAsync(suppressAutomaticRestart: true, token);
                return true;
            }
            catch (Exception)
            {
                ErrorText = "本機控制要求的停止作業失敗；已保留復原證據。";
                return false;
            }
            finally
            {
                IsBusy = false;
            }
        }, CancellationToken.None);
    }

    private async Task ObserveRecorderControlStopAsync(Task stopTask)
    {
        try
        {
            await stopTask;
        }
        finally
        {
            if (ReferenceEquals(recorderControlStopTask, stopTask))
            {
                recorderControlStopTask = null;
            }
            UpdateCommandStates();
        }
    }

    public async Task<RecorderControlActionResult> SetRecorderControlAutomaticModeAsync(
        bool enabled,
        CancellationToken cancellationToken)
    {
        var automatic = teamsAutomaticRecorder;
        if (isShuttingDown || automatic is null || enabled && !IsLocalHeuristicAutoStartEnabled)
        {
            return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
        }

        if (automatic.Snapshot.IsEnabled == enabled)
        {
            return RecorderControlActionResult.NoOp();
        }

        try
        {
            await automatic.SetEnabledAsync(enabled, cancellationToken);
            teamsAutomaticSnapshot = automatic.Snapshot;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsLocalAutomaticRecordingStatusText));
            PersistAppSettingsInBackground();
            return RecorderControlActionResult.Accepted();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (ObjectDisposedException)
        {
            return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
        }
        catch (Exception)
        {
            return RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady);
        }
    }

    public Task<RecorderControlActionResult> SetRecorderControlMicrophoneMutedAsync(
        bool muted,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (isShuttingDown)
        {
            return Task.FromResult(RecorderControlActionResult.Rejected(RecorderControlErrorCode.NotReady));
        }

        if (recorderMicrophoneMute.IsLocalMuted == muted)
        {
            return Task.FromResult(RecorderControlActionResult.NoOp());
        }

        recorderMicrophoneMute.SetLocalMuted(muted);
        return Task.FromResult(RecorderControlActionResult.Accepted());
    }

    private async Task RefreshProcessCatalogCoreAsync()
    {
        // Process enumeration can be slow or deny access to individual processes.
        // The Application catalog filters those cases and exposes no paths or command lines.
        var entries = await Task.Run(processCatalog.GetProcesses);
        var previous = SelectedProcess;

        ProcessCatalog.Clear();
        foreach (var entry in entries)
        {
            ProcessCatalog.Add(new ProcessSelectionChoice(
                entry.ProcessId,
                entry.StartedAtUtc,
                entry.ApplicationName,
                entry.ProcessName,
                entry.WindowTitle,
                entry.HasWindow,
                entry.Availability));
        }

        SelectedProcess = ProcessCatalog.FirstOrDefault(candidate =>
            candidate.HasSameIdentity(previous));

        var restoredStatus = false;
        if (SelectedProcess is null && pendingSelectedApplicationExecutable is { } executable)
        {
            var matches = ProcessCatalog
                .Where(candidate => SameExecutable(candidate.ProcessName, executable))
                .Take(2)
                .ToArray();
            if (matches.Length == 1)
            {
                SelectedProcess = matches[0];
                ProcessCatalogStatusText = $"已重新連接 {matches[0].DisplayName}。";
                restoredStatus = true;
            }
            else if (matches.Length > 1)
            {
                ProcessCatalogStatusText = $"找到多個 {executable} 程序；為避免選錯來源，請手動選取。";
                restoredStatus = true;
            }
        }

        pendingSelectedApplicationExecutable = null;
        if (!restoredStatus)
        {
            ProcessCatalogStatusText = SelectedProcess is not null
                ? $"已保留 {SelectedProcess.DisplayName} 的目前程序選擇。"
                : ProcessCatalog.Count == 0
                    ? "找不到可用的應用程式程序；請先啟動目標應用程式，然後重新整理。"
                    : $"已列出 {ProcessCatalog.Count} 個可用程序；請選取要錄製的應用程式。";
        }
    }

    private static bool SameExecutable(string left, string right) =>
        WindowsExecutableBasename.TryCreateExecutableBasename(left, out var normalizedLeft) &&
        WindowsExecutableBasename.TryCreateExecutableBasename(right, out var normalizedRight) &&
        string.Equals(normalizedLeft, normalizedRight, StringComparison.OrdinalIgnoreCase);

    private Task RefreshLibraryAsync() => RunOperationAsync(RefreshLibraryCoreAsync);

    private Task PlayAsync() => RunOperationAsync(async () =>
    {
        if (mediaPlayer is null)
        {
            PlaybackText = "播放元件尚未準備完成。";
            return;
        }

        var target = CaptureLibraryActionTarget(requireManaged: false);
        var item = await ResolveCanonicalLibraryActionAsync(target);
        // Selection is allowed to change while the filesystem is re-checked;
        // never attach a just-resolved old row to the newly selected stage.
        if (!IsCurrentLibraryActionTarget(target))
        {
            return;
        }

        if (!item.IsPlayable)
        {
            PlaybackText = "請選取存在的 MP4 或舊版 M4A 檔案。";
            return;
        }

        if (!PathEquals(loadedPlaybackPath, item.MediaPath))
        {
            mediaPlayer.Source = MediaSource.CreateFromUri(new Uri(item.MediaPath, UriKind.Absolute));
            loadedPlaybackPath = item.MediaPath;
            ClearPlaybackTimeline();
        }

        mediaPlayer.Volume = PlaybackVolume;
        mediaPlayer.PlaybackSession.PlaybackRate = SelectedPlaybackRate;
        mediaPlayer.Play();
        PlaybackText = $"正在播放：{item.DisplayName}";
    });

    private Task PauseAsync() => RunOperationAsync(() =>
    {
        mediaPlayer?.Pause();
        PlaybackText = "已暫停。";
        return Task.CompletedTask;
    });

    private Task StopPlaybackAsync() => RunOperationAsync(() =>
    {
        mediaPlayer?.Pause();
        if (mediaPlayer is not null)
        {
            mediaPlayer.PlaybackSession.Position = TimeSpan.Zero;
        }

        SetPlaybackProgress(0d);
        SetPlaybackPositionSeconds(0d);
        PlaybackText = "已停止。";
        return Task.CompletedTask;
    });

    private Task SkipPlaybackAsync(double offsetSeconds) => RunOperationAsync(() =>
    {
        if (!CanSeek || mediaPlayer is null)
        {
            return Task.CompletedTask;
        }

        SeekPlaybackToSeconds(mediaPlayer.PlaybackSession.Position.TotalSeconds + offsetSeconds);
        return Task.CompletedTask;
    });

    private Task SaveLibraryMetadataAsync() => RunOperationAsync(async () =>
    {
        var target = CaptureLibraryActionTarget(requireManaged: true);
        var tags = LibraryTagsText.Split(
            [',', ';', '\r', '\n'],
            StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var library = GetLibraryService();
        await ResolveCanonicalLibraryActionAsync(target);
        await Task.Run(async () => await library.UpdateMetadataAsync(
            target.Identity,
            LibraryTitle,
            tags,
            IsLibraryFavorite));
        await RefreshLibraryCoreAsync();
        PlaybackText = "已儲存工作階段資料。";
    });

    private Task OpenLibraryFolderAsync() => RunOperationAsync(async () =>
    {
        var target = CaptureLibraryActionTarget(requireManaged: true);
        var item = await ResolveCanonicalLibraryActionAsync(target);
        if (!Directory.Exists(item.SessionPath))
        {
            throw new DirectoryNotFoundException("選取的工作階段資料夾已不存在。");
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = item.SessionPath,
            UseShellExecute = true,
        });
    });

    private Task SaveDiagnosticsAsync() => RunOperationAsync(async () =>
    {
        var result = await GetRecordingLifecycle().ExportDiagnosticsAsync(diagnosticsDirectory);
        DiagnosticsExportStatusText = $"已儲存診斷報告：{result.FileName}（{result.EntryCount:N0} 筆）。可按「開啟診斷資料夾」取得檔案。";
        StatusText = "診斷報告已儲存。";
        UpdateCommandStates();
    });

    private Task OpenDiagnosticsFolderAsync() => RunOperationAsync(() =>
    {
        if (!Directory.Exists(diagnosticsDirectory))
        {
            throw new DirectoryNotFoundException("尚未儲存診斷報告；請先按「儲存診斷報告」。");
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = diagnosticsDirectory,
            UseShellExecute = true,
        });
        return Task.CompletedTask;
    });

    private Task RequestRecycleLibraryAsync() => RunOperationAsync(async () =>
    {
        var target = CaptureLibraryActionTarget(requireManaged: true);
        var item = await ResolveCanonicalLibraryActionAsync(target);
        if (!IsCurrentLibraryActionTarget(target))
        {
            return;
        }

        pendingRecycleIdentity = target.Identity;
        pendingRecycleDisplayName = item.DisplayName;
        IsRecycleConfirmationVisible = true;
    });

    private Task CancelRecycleLibraryAsync() => RunOperationAsync(() =>
    {
        pendingRecycleIdentity = null;
        pendingRecycleDisplayName = null;
        IsRecycleConfirmationVisible = false;
        return Task.CompletedTask;
    });

    private Task ConfirmRecycleLibraryAsync() => RunOperationAsync(async () =>
    {
        var expected = pendingRecycleIdentity;
        if (!IsRecycleConfirmationVisible || expected is null)
        {
            throw new InvalidOperationException("請先確認移至資源回收桶。");
        }

        // Verify and recycle the exact row that the confirmation referred to,
        // rather than whichever row happens to be selected now.
        var library = GetLibraryService();
        var canonical = await Task.Run(() => library.ResolveCanonicalSession(expected))
            ?? throw new IOException("該工作階段已被移除或取代；未執行刪除。請重新整理錄音庫。");
        if (PathEquals(loadedPlaybackPath, canonical.MediaPath))
        {
            ClearLoadedPlayback();
        }

        await Task.Run(() => library.RecycleSession(expected, userConfirmed: true));
        pendingRecycleIdentity = null;
        pendingRecycleDisplayName = null;
        IsRecycleConfirmationVisible = false;
        await RefreshLibraryCoreAsync();
        PlaybackText = "已將工作階段移至資源回收桶。";
    });

    private async Task<RecordingCoordinatorSnapshot> StartRecordingAsync(
        RecordingSessionKind kind,
        TimeSpan? testDuration = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!SelectedDevicesReady)
        {
            throw new InvalidOperationException("請重新選取可用的輸出裝置與麥克風後再開始錄製。");
        }

        await RefreshTeamsPlaybackEndpointObservationAsync();
        RefreshStorageReadiness();
        var lifecycle = GetRecordingLifecycle();
        var requestedVideoTarget = SelectedVideoTargetOrNull();
        RecordingLifecycleStartResult started;
        if (SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication)
        {
            var process = SelectedProcess
                ?? throw new InvalidOperationException("請先選擇應用程式。");
            if (!process.IsAvailable)
            {
                throw new InvalidOperationException("所選應用程式程序已無法使用。");
            }

            // The application layer verifies PID + start time immediately before
            // native capture and fails closed if the identity is no longer current.
            started = await lifecycle.StartAsync(new RecordingStartRequest(
                kind,
                RecordingAudioSource.SelectedProcessLoopback,
                MicrophoneEndpointId: SelectedMicrophoneEndpoint?.EndpointId,
                ProcessTarget: new SelectedProcessTarget(
                    process.ProcessId,
                    process.StartedAtUtc,
                    process.ProcessName),
                IncludeProcessTree: true,
                TestDuration: testDuration,
                VideoTarget: requestedVideoTarget), cancellationToken);
        }
        else
        {
            started = await lifecycle.StartAsync(new RecordingStartRequest(
                kind,
                RecordingAudioSource.SystemLoopback,
                RenderEndpointId: SelectedRenderEndpoint?.EndpointId,
                MicrophoneEndpointId: SelectedMicrophoneEndpoint?.EndpointId,
                TestDuration: testDuration,
                VideoTarget: requestedVideoTarget), cancellationToken);
        }
        var plan = started.Session;
        // New Windows sessions are always MP4.  Legacy root-level M4A files
        // remain a playback-only compatibility path in the library.
        NextOutputPath = plan.FinalVideoPath;
        lastResultText = $"正在建立工作階段：{plan.FinalVideoPath}";
        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();

        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        ErrorText = null;
        OnPropertyChanged(nameof(ElapsedText));
        isTeamsWindowCaptureEnabled = requestedVideoTarget is not null;
        teamsWindowCaptureStatus = requestedVideoTarget is null
            ? "可從浮動視窗啟用所選 Teams 畫面；音訊會持續錄製。"
            : "Teams 畫面錄製中。";
        ApplySnapshot(started.Snapshot);
        return started.Snapshot;
    }

    private VideoCaptureTarget? SelectedVideoTargetOrNull() =>
        IsSharedContentCaptureEnabled
            ? SelectedVideoCaptureWindow?.Target ?? throw new InvalidOperationException("Select a Teams shared-content window before recording.")
            : null;

    private async Task RefreshEndpointsCoreAsync(bool announce = false)
    {
        var result = await GetRecordingLifecycle().RefreshEndpointsAsync();
        if (!result.IsSuccess)
        {
            ErrorText = result.Operation.Error ?? "無法取得 Windows 音訊裝置。";
            return;
        }

        var renderSelection = EndpointRefreshSelection.Retain(
            SelectedRenderEndpoint?.EndpointId,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Render));
        var microphoneSelection = EndpointRefreshSelection.Retain(
            SelectedMicrophoneEndpoint?.EndpointId,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Capture));
        ReplaceEndpoints(
            RenderEndpoints,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Render),
            EndpointChoice.SystemDefault);
        ReplaceEndpoints(
            CaptureEndpoints,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Capture),
            EndpointChoice.NoMicrophone);

        if (announce)
        {
            StatusText = $"已重新整理 {RenderEndpoints.Count - 1} 個輸出裝置和 {CaptureEndpoints.Count - 1} 個麥克風。";
            ErrorText = null;
        }

        var initialMicrophoneEndpointId = SelectedMicrophoneEndpoint is null
            ? MicrophoneDefaultSelectionPolicy.SelectInitialCaptureEndpointId(result.Endpoints)
            : null;
        SelectedRenderEndpoint = RetainOrMarkUnavailable(
            RenderEndpoints,
            renderSelection,
            "輸出裝置");
        SelectedMicrophoneEndpoint = RetainOrMarkUnavailable(
            CaptureEndpoints,
            microphoneSelection,
            "麥克風");
        if (initialMicrophoneEndpointId is not null)
        {
            SelectedMicrophoneEndpoint = CaptureEndpoints.FirstOrDefault(choice =>
                string.Equals(choice.EndpointId, initialMicrophoneEndpointId, StringComparison.Ordinal));
        }
        ApplyPendingAppSettingsAfterEndpointRefresh();
        windowsConsoleDefaultRenderEndpointId = result.Endpoints
            .FirstOrDefault(endpoint => endpoint.Flow == CaptureEndpointFlow.Render &&
                                        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Console))
            ?.EndpointId;
        await RefreshTeamsPlaybackEndpointObservationAsync();
        OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
        OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
    }

    private async Task RefreshTeamsPlaybackEndpointObservationAsync()
    {
        if (SelectedCaptureSource?.Kind == CaptureSourceKind.SelectedApplication || recordingLifecycle is null)
        {
            teamsPlaybackEndpointObservation = TeamsPlaybackEndpointObservation.Unknown;
            OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
            OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
            return;
        }

        try
        {
            var probeTask = teamsPlaybackEndpointProbeTask ??=
                Task.Run(recordingLifecycle.ProbeTeamsRenderEndpoints);
            var result = await probeTask.WaitAsync(TeamsPlaybackEndpointProbeTimeout);
            if (ReferenceEquals(probeTask, teamsPlaybackEndpointProbeTask) && probeTask.IsCompleted)
            {
                teamsPlaybackEndpointProbeTask = null;
            }
            teamsPlaybackEndpointObservation = result.IsSuccess
                ? TeamsPlaybackEndpointObservation.Known(
                    result.ActiveEndpoints.Select(endpoint => endpoint.EndpointId))
                : TeamsPlaybackEndpointObservation.Unknown;
        }
        // The probe is advisory only. It must not prevent manual/test/Teams
        // starts if a driver, an old bridge, or an audio-session broker cannot
        // provide a useful answer.
        catch (Exception) when (!isShuttingDown)
        {
            teamsPlaybackEndpointObservation = TeamsPlaybackEndpointObservation.Unknown;
        }

        OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
        OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
    }

    private async Task RecoverAtStartupAsync()
    {
        try
        {
            var recoveryResults = await Task.Run(() => GetLibraryService().RecoverEvidenceAtStartupAsync());
            var recoveredCount = recoveryResults.Count(result => result.Recovered);
            if (recoveredCount > 0)
            {
                StatusText = $"已復原 {recoveredCount} 個先前中斷的音訊工作階段。";
            }
        }
        catch (Exception exception)
        {
            ErrorText = $"無法檢查中斷復原：{exception.Message}";
        }

    }

    private async Task RefreshLibraryAfterInitializationAsync()
    {
        IsLibraryLoading = true;
        try
        {
            await RefreshLibraryCoreAsync();
        }
        finally
        {
            IsLibraryLoading = false;
        }
    }

    private async Task RefreshLibraryCoreAsync()
    {
        try
        {
            var library = GetLibraryService();
            var projections = await Task.Run(() => library.ListSessions()
                .Select(TryCreateLibraryRecording)
                .Where(static item => item is not null)
                .Cast<LibraryRecording>()
                .ToArray());
            if (isShuttingDown)
            {
                return;
            }
            var selectedIdentity = SelectedLibraryItem?.Identity;
            allLibraryItems.Clear();
            allLibraryItems.AddRange(projections);
            ApplyLibraryQuery(selectedIdentity);
        }
        catch (Exception exception)
        {
            ErrorText = $"無法讀取本機工作階段資料庫：{exception.Message}";
        }
    }

    private void ApplyLibraryQuery(RecordingLibrarySessionIdentity? preferredSelection = null)
    {
        var selectedIdentity = preferredSelection ?? SelectedLibraryItem?.Identity;
        var query = LibrarySearchText;
        var visible = allLibraryItems
            .Where(item => !LibraryFavoritesOnly || item.IsFavorite)
            .Where(item => item.SearchDocument.Matches(query))
            .Select(item => item with { TranscriptSnippet = item.SearchDocument.TranscriptSnippet(query) })
            .ToArray();

        LibraryItems.Clear();
        foreach (var item in visible)
        {
            LibraryItems.Add(item);
        }

        SelectedLibraryItem = selectedIdentity is null
            ? null
            : visible.FirstOrDefault(item => item.Identity == selectedIdentity);
        OnPropertyChanged(nameof(LibrarySummaryText));
    }

    private static LibraryRecording? TryCreateLibraryRecording(RecordingSessionLibraryItem session)
    {
        try
        {
            var displayName = string.IsNullOrWhiteSpace(session.Metadata.Title)
                ? session.IsManaged
                    ? Path.GetFileName(session.FolderPath)
                    : Path.GetFileNameWithoutExtension(session.MediaPath)
                : session.Metadata.Title;
            var identity = RecordingLibrarySessionIdentity.Create(session);
            return new LibraryRecording(
                displayName,
                session.MediaPath,
                session.FolderPath,
                IsPlayable: File.Exists(session.MediaPath),
                session.Metadata.Title,
                session.Metadata.Tags,
                session.Metadata.IsFavorite,
                session.Kind,
                session.MediaBytes,
                session.HasRecoverableBackup,
                session.IsManaged,
                session.Metadata.MediaKind,
                session.Metadata.RecoveryState,
                session.Metadata.Source,
                identity,
                RecordingLibrarySearchDocument.Create(session, displayName),
                RecordingLibraryArtifactStatus.Read(session.FolderPath, session.IsManaged));
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
        catch (ArgumentException) { return null; }
    }

    private sealed record LibraryActionTarget(
        RecordingLibrarySessionIdentity Identity,
        long SelectionGeneration,
        string DisplayName);

    private LibraryActionTarget CaptureLibraryActionTarget(bool requireManaged)
    {
        var item = SelectedLibraryItem
            ?? throw new InvalidOperationException("請先從錄音庫選取工作階段。");
        if (!item.IsPlayable)
        {
            throw new IOException("選取的媒體檔案已不存在。請重新整理錄音庫。");
        }

        if (requireManaged && !item.IsManaged)
        {
            throw new InvalidOperationException("舊版 M4A 可播放，但無法由此版本編輯資料或移至資源回收桶。");
        }

        return new(item.Identity, librarySelectionGeneration, item.DisplayName);
    }

    private async Task<LibraryRecording> ResolveCanonicalLibraryActionAsync(LibraryActionTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        var library = GetLibraryService();
        return await Task.Run(() =>
        {
            var canonical = library.ResolveCanonicalSession(target.Identity)
                ?? throw new IOException("選取的工作階段已被移除或取代；未對其他錄音執行操作。請重新整理後再試一次。");
            return TryCreateLibraryRecording(canonical)
                ?? throw new IOException("選取的工作階段在重新驗證時已不再可用。請重新整理錄音庫。");
        });
    }

    private bool IsCurrentLibraryActionTarget(LibraryActionTarget target) =>
        librarySelectionGeneration == target.SelectionGeneration &&
        SelectedLibraryItem?.Identity == target.Identity;

    private async Task<RecordingSessionPublicationResult> EnsureSessionPublishedAsync()
    {
        var result = await GetRecordingLifecycle().PublishCompletedAsync();
        if (result.Session is null)
        {
            return result;
        }

        if (result.Published)
        {
            NextOutputPath = result.Session.FinalVideoPath;
            lastResultText = $"已發佈：{result.Session.FinalVideoPath}";
            StatusText = "錄音已儲存。";
            await RefreshLibraryCoreAsync();
        }
        else
        {
            lastResultText = "The recording could not be published; recovery evidence was retained.";
            ErrorText = result.Error?.Message ?? "The recording session could not be published.";
        }

        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();
        return result;
    }

    private async Task CompleteTestPlaybackAsync(long generation)
    {
        if (pendingTestPlaybackGeneration != generation || isShuttingDown)
        {
            return;
        }

        pendingTestPlaybackGeneration = null;
        try
        {
            var publication = await EnsureSessionPublishedAsync();
            if (!publication.Published || publication.Session is null || mediaPlayer is null)
            {
                return;
            }

            await RefreshLibraryCoreAsync();
            var publishedPath = Path.GetFullPath(publication.Session.FinalVideoPath);
            var item = allLibraryItems.FirstOrDefault(candidate =>
                PathEquals(candidate.MediaPath, publishedPath));
            if (item is null)
            {
                return;
            }

            LibrarySearchText = string.Empty;
            LibraryFavoritesOnly = false;
            SelectedLibraryItem = item;
            await PlayAsync();
            PlaybackText = $"測試錄音已儲存並正在播放：{item.DisplayName}";
        }
        catch (Exception exception)
        {
            ErrorText = $"測試錄音已儲存，但無法自動播放：{exception.Message}";
        }
    }

    private void RefreshStorageReadiness()
    {
        try
        {
            storageCapacity = GetRecordingLifecycle().GetCapacityStatus();
            storageCanStart = storageCapacity.CanStart;
        }
        catch
        {
            storageCapacity = new StorageCapacityStatus(null, RecordingStorageDecision.Stop);
            storageCanStart = false;
        }

        OnPropertyChanged(nameof(StorageReadinessText));
        UpdateCommandStates();
    }

    private RecordingLibraryService GetLibraryService()
    {
        var root = OutputFolder.Trim();
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new InvalidOperationException("請先輸入工作階段資料夾。");
        }

        var fullRoot = Path.GetFullPath(root);
        if (libraryService is null || !PathEquals(libraryServiceRoot, fullRoot))
        {
            libraryService = new RecordingLibraryService(new SessionStorageService(fullRoot));
            libraryServiceRoot = fullRoot;
        }

        return libraryService;
    }

    private void ResetSessionStorage()
    {
        libraryService = null;
        libraryServiceRoot = null;
        storageCapacity = null;
        storageCanStart = false;
    }

    private static void ReplaceEndpoints(
        ObservableCollection<EndpointChoice> target,
        IEnumerable<NativeCaptureEndpoint> endpoints,
        EndpointChoice defaultChoice)
    {
        target.Clear();
        target.Add(defaultChoice);
        foreach (var endpoint in endpoints
                     .OrderBy(GetEndpointRank)
                     .ThenBy(endpoint => endpoint.FriendlyName, StringComparer.CurrentCultureIgnoreCase))
        {
            target.Add(new EndpointChoice(
                endpoint.EndpointId,
                string.IsNullOrWhiteSpace(endpoint.FriendlyName)
                    ? "未命名音訊裝置"
                    : endpoint.FriendlyName,
                endpoint.DefaultRoles));
        }
    }

    private static EndpointChoice RetainOrMarkUnavailable(
        ObservableCollection<EndpointChoice> choices,
        EndpointRefreshSelection selection,
        string kind)
    {
        var endpointId = selection.EndpointId;
        var match = choices.FirstOrDefault(choice =>
            string.Equals(choice.EndpointId, endpointId, StringComparison.Ordinal));
        if (selection.IsAvailable && match is not null)
        {
            return match;
        }

        var unavailable = new EndpointChoice(
            endpointId,
            $"已中斷的{kind}",
            EndpointDefaultRole.None,
            IsAvailable: false);
        choices.Add(unavailable);
        return unavailable;
    }

    private static int GetEndpointRank(NativeCaptureEndpoint endpoint) =>
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Console) ? 0 :
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Multimedia) ? 1 :
        endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Communications) ? 2 : 3;

    private async void OnTelemetryTimerTick(DispatcherQueueTimer _, object __) =>
        await RefreshTelemetryAsync();

    private async void OnInputMuteTimerTick(DispatcherQueueTimer _, object __)
    {
        if (isShuttingDown || isInputMuteRefreshInProgress)
        {
            return;
        }

        var endpointId = SelectedMicrophoneEndpoint?.EndpointId;
        if (string.IsNullOrWhiteSpace(endpointId))
        {
            monitoredInputEndpointId = null;
            recorderMicrophoneMute.SetInputMuted(false);
            return;
        }

        isInputMuteRefreshInProgress = true;
        try
        {
            var observed = await Task.Run(() =>
            {
                var available = inputMuteMonitor.TryRead(endpointId, out var muted);
                return (available, muted);
            });
            if (isShuttingDown || !string.Equals(endpointId, SelectedMicrophoneEndpoint?.EndpointId, StringComparison.Ordinal))
            {
                return;
            }

            if (observed.available)
            {
                monitoredInputEndpointId = endpointId;
                recorderMicrophoneMute.SetInputMuted(observed.muted);
            }
            else if (!string.Equals(monitoredInputEndpointId, endpointId, StringComparison.Ordinal))
            {
                // A newly selected endpoint has no trustworthy observation yet.
                // Never carry a mute bit from the previously selected device.
                monitoredInputEndpointId = null;
                recorderMicrophoneMute.SetInputMuted(false);
            }
        }
        finally
        {
            isInputMuteRefreshInProgress = false;
        }
    }

    private async void OnTeamsMuteFollowTimerTick(DispatcherQueueTimer _, object __)
    {
        if (isShuttingDown || !IsFollowTeamsMuteEnabled || isTeamsMuteFollowRefreshInProgress)
        {
            return;
        }

        var revision = Volatile.Read(ref teamsMuteFollowRevision);
        isTeamsMuteFollowRefreshInProgress = true;
        try
        {
            var observed = await Task.Run(() =>
            {
                var mute = teamsMuteFollowProbe.Observe();
                if (mute.State == TeamsMuteFollowState.NotInCall && recordingLifecycle is not null)
                {
                    // Teams can temporarily remove its toolbar from the UIA
                    // tree while a call remains active. An active Teams WASAPI
                    // render session makes that absence ambiguous, not proof
                    // that the call ended. Fail closed until the exact button
                    // is visible again; system-output capture is unaffected.
                    var audio = recordingLifecycle.ProbeTeamsRenderEndpoints();
                    if (audio.IsSuccess && audio.ActiveEndpoints.Count > 0)
                    {
                        return TeamsMuteFollowObservation.Unavailable(
                            TeamsUiAutomationFailure.ControlNotFound);
                    }
                }
                return mute;
            });
            if (isShuttingDown || !IsFollowTeamsMuteEnabled ||
                revision != Volatile.Read(ref teamsMuteFollowRevision))
            {
                return;
            }

            teamsMuteFollowObservation = observed;
            recorderMicrophoneMute.SetTeamsMuted(observed.ShouldMuteRecorder);
            OnPropertyChanged(nameof(TeamsMuteFollowStatusText));
            OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
            NotifyRecordingOverlayStateChanged();
        }
        finally
        {
            isTeamsMuteFollowRefreshInProgress = false;
        }
    }

    private async Task RefreshTelemetryAsync()
    {
        if (isShuttingDown ||
            isTelemetryRefreshInProgress ||
            isLowStorageStopInProgress ||
            snapshot.State != RecordingCoordinatorState.Recording ||
            recordingLifecycle is null)
        {
            return;
        }

        isTelemetryRefreshInProgress = true;
        try
        {
            RefreshElapsed();
            var now = DateTimeOffset.UtcNow;
            if (now >= nextStorageCapacityCheckUtc)
            {
                nextStorageCapacityCheckUtc = now.AddSeconds(2);
                storageCapacity = recordingLifecycle.GetCapacityStatus();
                OnPropertyChanged(nameof(StorageReadinessText));
                if (storageCapacity.Decision == RecordingStorageDecision.AudioOnly &&
                    isTeamsWindowCaptureEnabled &&
                    !isLowStorageVideoDowngradeInProgress)
                {
                    isLowStorageVideoDowngradeInProgress = true;
                    try
                    {
                        await SetTeamsWindowCaptureDuringRecordingAsync(false);
                        if (!isTeamsWindowCaptureEnabled)
                        {
                            teamsWindowCaptureStatus = "可用空間不足 1 GiB；畫面錄製已停止，音訊繼續錄製。";
                            NotifyRecordingOverlayStateChanged();
                        }
                    }
                    finally
                    {
                        isLowStorageVideoDowngradeInProgress = false;
                    }
                }
                if (storageCapacity.Decision == RecordingStorageDecision.Stop)
                {
                    isLowStorageStopInProgress = true;
                    ErrorText = "儲存空間已低於安全下限；正在停止並保存最近的耐久 checkpoint。";
                    await StopAsync();
                    return;
                }
            }
            ApplySnapshot(await recordingLifecycle.RefreshAsync());
        }
        catch (Exception exception)
        {
            ErrorText = $"無法更新錄音狀態：{exception.Message}";
        }
        finally
        {
            isLowStorageStopInProgress = false;
            isTelemetryRefreshInProgress = false;
        }
    }

    private void OnSnapshotChanged(object? _, RecordingCoordinatorSnapshot changed)
    {
        if (isShuttingDown)
        {
            return;
        }

        if (dispatcherQueue.HasThreadAccess)
        {
            ApplySnapshot(changed);
            return;
        }

        _ = dispatcherQueue.TryEnqueue(() => ApplySnapshot(changed));
    }

    private void ApplySnapshot(RecordingCoordinatorSnapshot changed)
    {
        if (isShuttingDown)
        {
            return;
        }

        snapshot = changed;
        if (virtualMicPublisher is { State: VirtualMicPublisherRuntimeState.Unavailable } failedPublisher)
        {
            VirtualMicrophoneStatusText = string.IsNullOrWhiteSpace(failedPublisher.FailureReason)
                ? "虛擬麥克風在錄音期間中斷；本機錄音會繼續。"
                : $"虛擬麥克風在錄音期間中斷：{failedPublisher.FailureReason}";
        }
        NotifyRecordingOverlayStateChanged();
        RefreshElapsed();
        if (changed.State == RecordingCoordinatorState.Recording)
        {
            AppendWaveform(OutputWaveformBars, changed.Stats.PrimaryLevelPeak);
            AppendWaveform(InputWaveformBars, changed.Stats.MicrophoneLevelPeak);
            ApplyRecordingMicrophoneMute(recorderMicrophoneMute.IsMuted);
            if (!telemetryTimer.IsRunning)
            {
                telemetryTimer.Start();
            }
        }
        else
        {
            telemetryTimer.Stop();
            ResetWaveforms();
            isTeamsWindowCaptureEnabled = false;
            isTeamsWindowCaptureToggleInProgress = false;
            teamsWindowCaptureStatus = null;
        }

        if (changed.State is RecordingCoordinatorState.Stopped or
            RecordingCoordinatorState.Failed or
            RecordingCoordinatorState.Faulted)
        {
            recordingStartedAt = null;
        }

        StatusText = GetStatusText(changed);
        if (!string.IsNullOrWhiteSpace(changed.Error))
        {
            ErrorText = changed.Error;
        }

        if (changed.State == RecordingCoordinatorState.Stopped && !changed.HasRecoverableFault)
        {
            if (pendingTestPlaybackGeneration == changed.Generation)
            {
                _ = CompleteTestPlaybackAsync(changed.Generation);
            }
            else
            {
                _ = EnsureSessionPublishedAsync();
            }
        }
        else if (changed.State == RecordingCoordinatorState.Faulted && !isFaultFinalizationInProgress)
        {
            _ = FinalizeFaultedSessionAsync();
        }

        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(PeakPercent));
        OnPropertyChanged(nameof(PeakText));
        OnPropertyChanged(nameof(OutputLevelPercent));
        OnPropertyChanged(nameof(OutputLevelText));
        OnPropertyChanged(nameof(InputLevelPercent));
        OnPropertyChanged(nameof(InputLevelText));
        NotifyLiveAudioHealthChanged();
        OnPropertyChanged(nameof(AggregateHealthText));
        OnPropertyChanged(nameof(RenderHealthText));
        OnPropertyChanged(nameof(MicrophoneHealthText));
        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();
    }

    private void NotifyLiveAudioHealthChanged()
    {
        OnPropertyChanged(nameof(PrimaryHealthTitle));
        OnPropertyChanged(nameof(PrimaryHealthDetail));
        OnPropertyChanged(nameof(PrimaryHealthGlyph));
        OnPropertyChanged(nameof(PrimaryHealthBrush));
        OnPropertyChanged(nameof(MicrophoneHealthTitle));
        OnPropertyChanged(nameof(MicrophoneHealthDetail));
        OnPropertyChanged(nameof(MicrophoneHealthGlyph));
        OnPropertyChanged(nameof(MicrophoneHealthBrush));
        OnPropertyChanged(nameof(AudioHealthSummaryText));
    }

    private static string HealthGlyph(LiveAudioHealthStatus status) => status switch
    {
        LiveAudioHealthStatus.Healthy => "\uE73E",
        LiveAudioHealthStatus.Warning => "\uE7BA",
        LiveAudioHealthStatus.Recovered => "\uE73E",
        _ => "\uE946",
    };

    private static double AudioLevelPercent(float rms)
    {
        if (!float.IsFinite(rms) || rms <= 0.000001f)
        {
            return 0;
        }

        // A logarithmic meter keeps normal speech visible while preserving a
        // true zero for silence. The overlay covers the useful -60..0 dBFS range.
        var decibels = 20d * Math.Log10(rms);
        return Math.Clamp((decibels + 60d) / 60d * 100d, 0d, 100d);
    }

    private static Brush HealthBrush(LiveAudioHealthStatus status) => status switch
    {
        LiveAudioHealthStatus.Healthy => HealthyHealthBrush,
        LiveAudioHealthStatus.Warning => WarningHealthBrush,
        LiveAudioHealthStatus.Recovered => RecoveredHealthBrush,
        _ => NeutralHealthBrush,
    };

    private static void AppendWaveform(ObservableCollection<WaveformBar> bars, float peak)
    {
        if (bars.Count >= WaveformBarCount)
        {
            bars.RemoveAt(0);
        }

        bars.Add(WaveformBar.FromPeak(peak));
    }

    private void ResetWaveforms()
    {
        OutputWaveformBars.Clear();
        InputWaveformBars.Clear();
        for (var index = 0; index < WaveformBarCount; index++)
        {
            OutputWaveformBars.Add(WaveformBar.Silence);
            InputWaveformBars.Add(WaveformBar.Silence);
        }
    }

    private async Task FinalizeFaultedSessionAsync()
    {
        var lifecycle = recordingLifecycle;
        if (lifecycle is null || isShuttingDown)
        {
            return;
        }

        isFaultFinalizationInProgress = true;
        NotifyRecordingOverlayStateChanged();
        try
        {
            var result = await lifecycle.FinalizeForRecoveryAsync();
            if (result.Published)
            {
                await RefreshLibraryCoreAsync();
            }
            else if (result.Error is not null)
            {
                ErrorText = result.Error.Message;
            }
        }
        catch (Exception exception)
        {
            ErrorText = $"Capture finalization failed; recovery evidence was retained: {exception.Message}";
        }
        finally
        {
            isFaultFinalizationInProgress = false;
            NotifyRecordingOverlayStateChanged();
            UpdateCommandStates();
        }
    }

    private void RefreshElapsed()
    {
        if (recordingStartedAt is { } startedAt)
        {
            elapsed = DateTimeOffset.Now - startedAt;
            OnPropertyChanged(nameof(ElapsedText));
        }
    }

    private void UpdatePlaybackPosition()
    {
        if (mediaPlayer is null)
        {
            return;
        }

        var session = mediaPlayer.PlaybackSession;
        var duration = Math.Max(0d, session.NaturalDuration.TotalSeconds);
        PlaybackDurationSeconds = duration;
        var position = Math.Clamp(session.Position.TotalSeconds, 0d, duration);
        var progress = duration > 0d ? position / duration : 0d;
        SetPlaybackProgress(progress);
        SetPlaybackPositionSeconds(position);
    }

    private void SetPlaybackProgress(double value)
    {
        isUpdatingPlaybackPosition = true;
        try
        {
            PlaybackProgress = value;
        }
        finally
        {
            isUpdatingPlaybackPosition = false;
        }
    }

    private void SetPlaybackPositionSeconds(double value)
    {
        isUpdatingPlaybackPosition = true;
        try
        {
            PlaybackPositionSeconds = Math.Clamp(value, 0d, Math.Max(0d, PlaybackDurationSeconds));
        }
        finally
        {
            isUpdatingPlaybackPosition = false;
        }

        OnPropertyChanged(nameof(PlaybackElapsedText));
        OnPropertyChanged(nameof(PlaybackRemainingText));
        OnPropertyChanged(nameof(PlaybackTimeReadout));
    }

    private void SeekPlaybackByProgress(double progress)
    {
        SeekPlaybackToSeconds(Math.Max(0d, PlaybackDurationSeconds) * Math.Clamp(progress, 0d, 1d));
    }

    private void SeekPlaybackToSeconds(double seconds)
    {
        if (!CanSeek || mediaPlayer is null)
        {
            return;
        }

        var duration = Math.Max(0d, mediaPlayer.PlaybackSession.NaturalDuration.TotalSeconds);
        var clamped = Math.Clamp(seconds, 0d, duration);
        mediaPlayer.PlaybackSession.Position = TimeSpan.FromSeconds(clamped);
        SetPlaybackPositionSeconds(clamped);
        SetPlaybackProgress(duration > 0d ? clamped / duration : 0d);
    }

    private void ResetPlaybackForSelectionChange(LibraryRecording? selected)
    {
        if (selected is not null && PathEquals(loadedPlaybackPath, selected.MediaPath))
        {
            return;
        }

        ClearLoadedPlayback();
    }

    private void ClearLoadedPlayback()
    {
        playbackTimer.Stop();
        if (mediaPlayer is not null)
        {
            mediaPlayer.Pause();
            mediaPlayer.PlaybackSession.Position = TimeSpan.Zero;
            mediaPlayer.Source = null;
        }

        loadedPlaybackPath = null;
        ClearPlaybackTimeline();
    }

    private void ClearPlaybackTimeline()
    {
        PlaybackDurationSeconds = 0d;
        SetPlaybackPositionSeconds(0d);
        SetPlaybackProgress(0d);
    }

    private static string FormatPlaybackTime(double seconds, bool includesHours)
    {
        var totalSeconds = Math.Max(0, (int)Math.Round(double.IsFinite(seconds) ? seconds : 0d));
        return includesHours
            ? $"{totalSeconds / 3600:00}:{totalSeconds / 60 % 60:00}:{totalSeconds % 60:00}"
            : $"{totalSeconds / 60:00}:{totalSeconds % 60:00}";
    }

    private async Task RunOperationAsync(Func<Task> operation)
    {
        if (isShuttingDown)
        {
            return;
        }

        IsBusy = true;
        try
        {
            await operation();
        }
        catch (Exception exception)
        {
            StatusText = "操作未完成";
            ErrorText = exception.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private RecordingLifecycleService GetRecordingLifecycle() => recordingLifecycle
        ?? throw new InvalidOperationException("錄音元件尚未準備完成。");

    private void SetRecorderAvailable(bool value)
    {
        if (isRecorderAvailable == value)
        {
            return;
        }

        isRecorderAvailable = value;
        OnPropertyChanged(nameof(ReadinessText));
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
        OnPropertyChanged(nameof(IsTeamsWindowSelectionEnabled));
    }

    private void NotifyRecordingOverlayStateChanged()
    {
        OnPropertyChanged(nameof(RecordingOverlayState));
        OnPropertyChanged(nameof(ActiveRecordingOverlayKind));
        OnPropertyChanged(nameof(IsTeamsAutomaticRecordingCountdownVisible));
        OnPropertyChanged(nameof(TeamsAutomaticRecordingCountdownSeconds));
        OnPropertyChanged(nameof(CanCancelTeamsAutomaticRecordingStart));
        OnPropertyChanged(nameof(CanStopRecordingFromOverlay));
        RecordingOverlayStateChanged?.Invoke(this, RecordingOverlayState);
    }

    private void UpdateCommandStates()
    {
        StartCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        StartTestCommand.RaiseCanExecuteChanged();
        SaveDiagnosticsCommand.RaiseCanExecuteChanged();
        OpenDiagnosticsFolderCommand.RaiseCanExecuteChanged();
        RefreshDevicesCommand.RaiseCanExecuteChanged();
        RefreshProcessCatalogCommand.RaiseCanExecuteChanged();
        RefreshTeamsWindowsCommand.RaiseCanExecuteChanged();
        RefreshLibraryCommand.RaiseCanExecuteChanged();
        PlayCommand.RaiseCanExecuteChanged();
        PauseCommand.RaiseCanExecuteChanged();
        StopPlaybackCommand.RaiseCanExecuteChanged();
        SkipBackward15Command.RaiseCanExecuteChanged();
        SkipForward15Command.RaiseCanExecuteChanged();
        SaveLibraryMetadataCommand.RaiseCanExecuteChanged();
        OpenLibraryFolderCommand.RaiseCanExecuteChanged();
        RequestRecycleLibraryCommand.RaiseCanExecuteChanged();
        ConfirmRecycleLibraryCommand.RaiseCanExecuteChanged();
        CancelRecycleLibraryCommand.RaiseCanExecuteChanged();
        EnableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        DisableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        CancelTeamsAutomaticRecordingStartCommand.RaiseCanExecuteChanged();
        StopRecordingFromOverlayCommand.RaiseCanExecuteChanged();
        ToggleLocalMicrophoneMuteCommand.RaiseCanExecuteChanged();
        TestOpenAiProviderConnectionCommand.RaiseCanExecuteChanged();
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
        OnPropertyChanged(nameof(IsTeamsWindowSelectionEnabled));
        OnPropertyChanged(nameof(CanSaveDiagnostics));
        OnPropertyChanged(nameof(CanOpenDiagnosticsFolder));
        OnPropertyChanged(nameof(CanSeek));
        OnPropertyChanged(nameof(CanManageLibrary));
        OnPropertyChanged(nameof(CanConfirmRecycle));
        OnPropertyChanged(nameof(IsRecordingMicrophoneMuted));
        OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
        OnPropertyChanged(nameof(GlobalMuteHotKeyStatus));
        OnPropertyChanged(nameof(TeamsMuteFollowStatusText));
        OnPropertyChanged(nameof(IsOpenAiProviderAvailable));
        OnPropertyChanged(nameof(CanSaveOpenAiProvider));
        OnPropertyChanged(nameof(CanTestOpenAiProvider));
        OnPropertyChanged(nameof(CanRemoveOpenAiApiKey));
        OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
        OnPropertyChanged(nameof(CanStartOpenAiTranscription));
        OnPropertyChanged(nameof(CanImportAudioForTranscription));
        OnPropertyChanged(nameof(CanGenerateOpenAiSummary));
        OnPropertyChanged(nameof(CanCancelMeetingIntelligence));
        OnPropertyChanged(nameof(CanSaveTranscript));
        OnPropertyChanged(nameof(CanSaveMeetingIntelligence));
    }

    private static string GetStatusText(RecordingCoordinatorSnapshot snapshot) => snapshot.State switch
    {
        RecordingCoordinatorState.Ready => "準備就緒",
        RecordingCoordinatorState.Starting => "正在開始錄音…",
        RecordingCoordinatorState.Recording when snapshot.IsTestRecording => "10 秒測試錄音中",
        RecordingCoordinatorState.Recording => "錄音中",
        RecordingCoordinatorState.Stopping => "正在停止並儲存…",
        RecordingCoordinatorState.Stopped when snapshot.HasRecoverableFault => "錄音異常已完成清理；保留可復原證據，可開始新的錄音。",
        RecordingCoordinatorState.Stopped => "正在發佈 MP4 工作階段…",
        RecordingCoordinatorState.Failed => "無法開始錄音",
        RecordingCoordinatorState.Faulted => "錄音異常，已保留可復原的工作檔（若存在）。",
        _ => "未知狀態",
    };

    private static string CreateInitializationError(Exception exception) => exception switch
    {
        DllNotFoundException => $"無法載入原生錄音 DLL。請建立相符的 x64 bridge。詳細資料：{exception.Message}",
        BadImageFormatException => $"原生 DLL 架構不符合 x64 App。詳細資料：{exception.Message}",
        NativeRecorderInteropException => $"原生錄音元件版本不相容。詳細資料：{exception.Message}",
        _ => $"無法初始化原生錄音元件。詳細資料：{exception.Message}",
    };

    private static string FormatBytes(long? bytes) => bytes is { } available
        ? available >= 1024L * 1024 * 1024
            ? $"{available / 1024d / 1024d / 1024d:0.0} GiB"
            : $"{available / 1024d / 1024d:0} MiB"
        : "未知";

    private static bool PathEquals(string? left, string? right) =>
        left is not null && right is not null &&
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);

    private bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

/// <summary>
/// One column in the lightweight live level waveform.  The height keeps a
/// visible floor so silence is distinguishable from a missing UI control.
/// </summary>
public sealed record WaveformBar(double Height, double Opacity)
{
    public static WaveformBar Silence { get; } = new(4, 0.25);

    public static WaveformBar FromPeak(float peak)
    {
        var normalized = Math.Clamp(peak, 0F, 1F);
        return new(
            Height: 4 + normalized * 44,
            Opacity: 0.3 + normalized * 0.7);
    }
}

public sealed record EndpointChoice(
    string? EndpointId,
    string DisplayName,
    EndpointDefaultRole DefaultRoles,
    bool IsAvailable = true)
{
    public static EndpointChoice SystemDefault { get; } = new(
        EndpointId: null,
        DisplayName: "系統預設輸出裝置",
        DefaultRoles: EndpointDefaultRole.None);

    public static EndpointChoice NoMicrophone { get; } = new(
        EndpointId: null,
        DisplayName: "不錄製麥克風",
        DefaultRoles: EndpointDefaultRole.None);
}

internal sealed record AiProviderEditorDraft(
    string BaseUrl,
    string GroupId,
    string AsrModel,
    string LlmModel,
    string Language,
    string Prompt,
    string MeetingIntelligencePrompt,
    string ApiKeyReplacement)
{
    public static AiProviderEditorDraft GenericDefault { get; } = new(
        OpenAICompatibleProviderProfile.DefaultBaseUrl,
        string.Empty,
        OpenAICompatibleProviderProfile.DefaultAsrModel,
        OpenAICompatibleProviderProfile.DefaultLlmModel,
        "yue",
        string.Empty,
        string.Empty,
        string.Empty);

    public static AiProviderEditorDraft HktDefault { get; } = new(
        string.Empty,
        string.Empty,
        OpenAICompatibleProviderProfile.HktDefaultAsrModel,
        OpenAICompatibleProviderProfile.HktDefaultLlmModel,
        "yue",
        string.Empty,
        string.Empty,
        string.Empty);

    public static AiProviderEditorDraft FromProfile(OpenAICompatibleProviderProfile profile) => new(
        profile.BaseUrl,
        profile.GroupId ?? string.Empty,
        profile.AsrModel,
        profile.LlmModel,
        profile.Language,
        profile.Prompt,
        profile.MeetingIntelligencePrompt,
        string.Empty);
}

public sealed record AIProviderKindChoice(AIProviderKind Kind, string DisplayName)
{
    public static AIProviderKindChoice HktGenAI { get; } = new(AIProviderKind.HktGenAI, "HKT GenAI Platform");
    public static AIProviderKindChoice OpenAICompatible { get; } = new(AIProviderKind.OpenAICompatible, "OpenAI 相容");

    public static AIProviderKindChoice From(AIProviderKind kind) =>
        kind == AIProviderKind.HktGenAI ? HktGenAI : OpenAICompatible;
}

public sealed record LibraryRecording(
    string DisplayName,
    string MediaPath,
    string SessionPath,
    bool IsPlayable,
    string? Title,
    IReadOnlyList<string> Tags,
    bool IsFavorite,
    RecordingSessionKind Kind,
    long MediaBytes,
    bool HasRecoverableBackup,
    bool IsManaged,
    string MediaKind,
    RecordingRecoveryState RecoveryState,
    string Source,
    RecordingLibrarySessionIdentity Identity,
    RecordingLibrarySearchDocument SearchDocument,
    RecordingLibraryArtifactStatus ArtifactStatus,
    string? TranscriptSnippet = null)
{
    // Kept as a compatibility alias for any diagnostic or UI binding compiled
    // before the library became media-kind neutral.
    public long AudioBytes => MediaBytes;

    // MP4 is a container, not a promise of a video track. Crash-safe Windows
    // sessions may publish AAC-only MP4, so the canonical metadata must own
    // playback-stage selection.
    public bool IsVideo => string.Equals(MediaKind, "video", StringComparison.OrdinalIgnoreCase);

    public string MediaKindText => IsVideo ? "影片" : "純音訊";

    public string KindText => Kind switch
    {
        RecordingSessionKind.Meeting => "會議",
        RecordingSessionKind.Test => "測試",
        _ => "手動",
    };

    public string AvailabilityText => IsManaged ? "受管理工作階段" : "舊版 M4A · 僅可播放";

    public string TagsText => Tags.Count == 0 ? "未加標籤" : string.Join("、", Tags);

    public string? RecoveryChipText => RecoveryState switch
    {
        RecordingRecoveryState.VideoLostAudioPreserved => "影片遺失，已保留音訊",
        RecordingRecoveryState.RecoveredAfterInterruption => "已從中斷復原",
        RecordingRecoveryState.FailedEvidenceRetained => "保留復原證據",
        _ => null,
    };

    public string? AiChipText => ArtifactStatus.AiChipText;

    public string SourceText => Source switch
    {
        "teamsAutomatic" => "Teams 自動",
        "imported" => "匯入",
        _ => "手動",
    };
}

public sealed record PlaybackRateChoice(double Rate, string DisplayName);
