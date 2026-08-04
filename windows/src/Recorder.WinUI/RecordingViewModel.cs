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
using TeamsRecorder.Windows.Application.Control;
using TeamsRecorder.Windows.Application.AI;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Settings;
using TeamsRecorder.Windows.Application.Storage;
using TeamsRecorder.Windows.Application.Transcription;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Keeps device choice, native recording lifecycle, session publication, and
/// local playback at the WinUI edge. The coordinator remains the single owner
/// of native start/stop serialization.
/// </summary>
public sealed class RecordingViewModel : INotifyPropertyChanged, IRecordingOverlayStateSource
{
    private const int WaveformBarCount = 48;
    private static readonly Brush HealthyHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.ForestGreen);
    private static readonly Brush WarningHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.DarkOrange);
    private static readonly Brush RecoveredHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.Goldenrod);
    private static readonly Brush NeutralHealthBrush = new SolidColorBrush(global::Microsoft.UI.Colors.Gray);
    private readonly DispatcherQueue dispatcherQueue;
    private readonly DispatcherQueueTimer telemetryTimer;
    private readonly DispatcherQueueTimer playbackTimer;
    // RecordingLifecycleService keeps native capture, the temporary session plan,
    // and final publication in the Application layer.  This VM only maps that
    // state to WinUI properties and commands.
    private RecordingLifecycleService? recordingLifecycle;
    private readonly IProcessCatalog processCatalog = new ProcessCatalog();
    private RecordingLibraryService? libraryService;
    private string? libraryServiceRoot;
    private readonly IRecorderAppSettingsStore appSettingsStore = new JsonRecorderAppSettingsStore();
    private readonly SemaphoreSlim appSettingsWriteGate = new(1, 1);
    private RecorderAppSettings? pendingAppSettings;
    private bool restoreTeamsMuteSyncAfterInitialization;
    private bool restoreTeamsAutomaticRecordingAfterInitialization;
    // AI provider settings are deliberately application-layer services. The view model
    // owns no persisted API key: the repository keeps it separately in per-user DPAPI.
    private OpenAICompatibleProviderRepository? openAiProviderRepository;
    private OpenAICompatibleAsrHttpTransport? openAiAsrTransport;
    private OpenAICompatibleProviderConnectionClient? openAiProviderConnectionClient;
    private RecordingSessionAsrJobCoordinator? transcriptionCoordinator;
    private OpenAiCompatibleMeetingSummaryClient? meetingSummaryClient;
    private MeetingSummaryCoordinator? meetingSummaryCoordinator;
    private RecordingCoordinatorSnapshot snapshot = RecordingCoordinatorSnapshot.Initial;
    private MediaPlayer? mediaPlayer;
    private EndpointChoice? selectedRenderEndpoint;
    private EndpointChoice? selectedMicrophoneEndpoint;
    private CaptureSourceChoice? selectedCaptureSource;
    private ProcessSelectionChoice? selectedProcess;
    private LibraryRecording? selectedLibraryItem;
    private string? loadedPlaybackPath;
    private string outputFolder;
    private string nextOutputPath = "開始錄製後會建立 M4A 工作階段。";
    private string lastResultText = "尚未完成新的錄製工作階段。";
    private string statusText = "正在準備錄音元件…";
    private string? errorText;
    private DateTimeOffset? recordingStartedAt;
    private TimeSpan elapsed;
    private StorageCapacityStatus? storageCapacity;
    private bool storageCanStart;
    private bool isBusy;
    private bool isInitialized;
    private bool isInitializing;
    private bool isRecorderAvailable;
    private bool isShuttingDown;
    private bool isTelemetryRefreshInProgress;
    private bool isFaultFinalizationInProgress;
    private bool isUpdatingPlaybackPosition;
    private double playbackProgress;
    private string playbackText = "請從資料庫選取有效的 M4A 檔案。";
    private string libraryTitle = string.Empty;
    private string libraryTagsText = string.Empty;
    private bool isLibraryFavorite;
    private bool isRecycleConfirmationVisible;
    private readonly InputMuteCoordinator teamsInputMute = new();
    private TeamsThirdPartyApiClient? teamsApiClient;
    private TeamsMuteSyncCoordinator? teamsMuteSync;
    private TeamsAutomaticRecordingController? teamsAutomaticRecorder;
    private TeamsMuteSyncSnapshot teamsMuteSnapshot = TeamsMuteSyncSnapshot.Initial;
    private TeamsAutoMeetingSnapshot teamsAutomaticSnapshot = TeamsAutoMeetingSnapshot.Initial;
    private bool isTeamsMuteSyncEnabled;
    private bool isTeamsMuteSyncOperationInProgress;
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
    private string openAiApiBaseUrl = "https://api.openai.com/v1";
    private string openAiAsrModel = "gpt-4o-transcribe";
    private string openAiLlmModel = "gpt-5.6-terra";
    private string openAiLanguage = "zh";
    private string openAiPrompt = "";
    private bool isOpenAiProviderInitialized;
    private bool hasOpenAiApiKey;
    private bool isTestingOpenAiProvider;
    private string openAiProviderIntegrationStatus = "正在準備本機 OpenAI 相容 API 設定。";
    // Endpoint IDs stay in memory only. They are used solely to compare the
    // active Windows Teams audio session with the current loopback choice.
    private TeamsPlaybackEndpointObservation teamsPlaybackEndpointObservation = TeamsPlaybackEndpointObservation.Unknown;
    private string? windowsConsoleDefaultRenderEndpointId;

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
        RefreshLibraryCommand = new AsyncRelayCommand(RefreshLibraryAsync, () => CanRefreshLibrary);
        PlayCommand = new AsyncRelayCommand(PlayAsync, () => CanPlay);
        PauseCommand = new AsyncRelayCommand(PauseAsync, () => CanPause);
        StopPlaybackCommand = new AsyncRelayCommand(StopPlaybackAsync, () => mediaPlayer is not null);
        SaveLibraryMetadataCommand = new AsyncRelayCommand(SaveLibraryMetadataAsync, () => CanManageLibrary);
        OpenLibraryFolderCommand = new AsyncRelayCommand(OpenLibraryFolderAsync, () => CanManageLibrary);
        RequestRecycleLibraryCommand = new AsyncRelayCommand(RequestRecycleLibraryAsync, () => CanManageLibrary);
        ConfirmRecycleLibraryCommand = new AsyncRelayCommand(ConfirmRecycleLibraryAsync, () => CanConfirmRecycle);
        CancelRecycleLibraryCommand = new AsyncRelayCommand(CancelRecycleLibraryAsync, () => IsRecycleConfirmationVisible);
        EnableTeamsMuteSyncCommand = new AsyncRelayCommand(EnableTeamsMuteSyncAsync, () => CanManageTeamsMuteSync && !IsTeamsMuteSyncEnabled);
        DisableTeamsMuteSyncCommand = new AsyncRelayCommand(DisableTeamsMuteSyncAsync, () => CanManageTeamsMuteSync && IsTeamsMuteSyncEnabled);
        RequestTeamsPairingCommand = new AsyncRelayCommand(RequestTeamsPairingAsync, () => CanRequestTeamsPairing);
        RepairTeamsPairingCommand = new AsyncRelayCommand(RepairTeamsPairingAsync, () => CanRepairTeamsPairing);
        EnableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(EnableTeamsAutomaticRecordingAsync, () => CanEnableTeamsAutomaticRecording);
        DisableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(DisableTeamsAutomaticRecordingAsync, () => CanDisableTeamsAutomaticRecording);
        CancelTeamsAutomaticRecordingStartCommand = new AsyncRelayCommand(CancelTeamsAutomaticRecordingStartAsync, () => CanCancelTeamsAutomaticRecordingStart);
        StopRecordingFromOverlayCommand = new AsyncRelayCommand(StopRecordingFromOverlayAsync, () => CanStopRecordingFromOverlay);
        ToggleLocalMicrophoneMuteCommand = new AsyncRelayCommand(ToggleLocalMicrophoneMuteAsync, () => !isShuttingDown);
        TestOpenAiProviderConnectionCommand = new AsyncRelayCommand(TestOpenAiProviderConnectionAsync, () => CanTestOpenAiProvider);
        teamsInputMute.Changed += OnInputMuteChanged;
        CaptureSources.Add(CaptureSourceChoice.SystemAudio);
        CaptureSources.Add(CaptureSourceChoice.SelectedApplication);
        selectedCaptureSource = CaptureSourceChoice.Default;
        ResetWaveforms();
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

    public ObservableCollection<LibraryRecording> LibraryItems { get; } = [];

    /// <summary>Model IDs discovered by the explicitly requested provider connection test.</summary>
    public ObservableCollection<string> OpenAiDiscoveredModels { get; } = [];

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

    public AsyncRelayCommand RefreshLibraryCommand { get; }

    public AsyncRelayCommand PlayCommand { get; }

    public AsyncRelayCommand PauseCommand { get; }

    public AsyncRelayCommand StopPlaybackCommand { get; }

    public AsyncRelayCommand SaveLibraryMetadataCommand { get; }

    public AsyncRelayCommand OpenLibraryFolderCommand { get; }

    public AsyncRelayCommand RequestRecycleLibraryCommand { get; }

    public AsyncRelayCommand ConfirmRecycleLibraryCommand { get; }

    public AsyncRelayCommand CancelRecycleLibraryCommand { get; }

    public AsyncRelayCommand EnableTeamsMuteSyncCommand { get; }

    public AsyncRelayCommand DisableTeamsMuteSyncCommand { get; }

    public AsyncRelayCommand RequestTeamsPairingCommand { get; }

    /// <summary>
    /// Re-attempts local Teams pairing after an explicit user request. This is deliberately
    /// user initiated: a health failure must never silently replace a pairing relationship
    /// while a meeting is in progress.
    /// </summary>
    public AsyncRelayCommand RepairTeamsPairingCommand { get; }

    public AsyncRelayCommand EnableTeamsAutomaticRecordingCommand { get; }

    public AsyncRelayCommand DisableTeamsAutomaticRecordingCommand { get; }

    /// <summary>Cancel the pending Teams-only automatic start without disabling the opt-in.</summary>
    public AsyncRelayCommand CancelTeamsAutomaticRecordingStartCommand { get; }

    /// <summary>Stop the active capture from the compact recording window.</summary>
    public AsyncRelayCommand StopRecordingFromOverlayCommand { get; }

    public AsyncRelayCommand ToggleLocalMicrophoneMuteCommand { get; }

    public AsyncRelayCommand TestOpenAiProviderConnectionCommand { get; }

    public bool IsRecordingMicrophoneMuted => teamsInputMute.IsMuted;

    public string RecordingMicrophoneMuteText => SelectedMicrophoneEndpoint?.EndpointId is null
        ? "未選取錄音麥克風；靜音設定會在下一次選取麥克風後套用。"
        : IsRecordingMicrophoneMuted
            ? "錄音中的麥克風已靜音；系統輸出錄音不受影響。"
            : "錄音中的麥克風未靜音。";

    public string GlobalMuteHotKeyStatus => globalMuteHotKeyStatus;

    /// <summary>Teams integration is an explicit, persisted non-secret opt-in; pairing credentials remain in DPAPI storage.</summary>
    public bool IsTeamsMuteSyncEnabled
    {
        get => isTeamsMuteSyncEnabled;
        private set
        {
            if (SetProperty(ref isTeamsMuteSyncEnabled, value))
            {
                OnPropertyChanged(nameof(TeamsMuteEnableButtonText));
                UpdateCommandStates();
            }
        }
    }

    public bool CanManageTeamsMuteSync => !isShuttingDown && !isTeamsMuteSyncOperationInProgress;

    /// <summary>A paired connection does not need another pairing request.</summary>
    public bool CanRequestTeamsPairing =>
        CanManageTeamsMuteSync &&
        IsTeamsMuteSyncEnabled &&
        !teamsMuteSnapshot.IsPairingKnown;

    /// <summary>Whether the user may repair a stale or otherwise unusable local Teams pairing.</summary>
    public bool CanRepairTeamsPairing => CanManageTeamsMuteSync && IsTeamsMuteSyncEnabled;

    private TeamsTransportHealthAssessment TeamsTransportHealthAssessment =>
        teamsApiClient?.TransportSnapshot.Health ?? TeamsTransportDiagnosticSnapshot.Initial.Health;

    /// <summary>
    /// A paired credential without a complete meeting update on the current connection is
    /// surfaced as a diagnostic signal.
    /// </summary>
    public bool IsTeamsPairingRepairRecommended =>
        IsTeamsMuteSyncEnabled &&
        (teamsMuteSnapshot.Status == TeamsMuteSyncStatus.WaitingForPairingApproval ||
         TeamsTransportHealthAssessment.Status is TeamsTransportHealth.Degraded or
             TeamsTransportHealth.Unavailable or
             TeamsTransportHealth.PairingRequired);

    public string TeamsPairingHealthText => !IsTeamsMuteSyncEnabled
        ? "Teams API 健康檢查尚未啟用。"
        : TeamsTransportHealthAssessment.Status == TeamsTransportHealth.Healthy
            ? "Teams API 健康：目前連線已收到完整會議狀態。"
            : $"Teams API 健康：{TeamsTransportHealthAssessment.Detail} 可使用「修復 Teams 配對」重新建立本機憑證；實際開始仍只會由完整的 Teams 會議狀態觸發。";

    /// <summary>
    /// Automatic recording is deliberately a separate opt-in.  A Teams connection alone is
    /// insufficient: this remains false until a paired API supplies an authoritative meeting state.
    /// </summary>
    public bool IsTeamsAutomaticRecordingEnabled => teamsAutomaticSnapshot.IsEnabled;

    private bool HasTrustedTeamsMeetingState =>
        IsTeamsMuteSyncEnabled &&
        teamsMuteSnapshot.IsPairingKnown &&
        teamsMuteSnapshot.Status is TeamsMuteSyncStatus.Ready or TeamsMuteSyncStatus.InMeeting &&
        teamsMuteSnapshot.LastMeetingState is not null;

    /// <summary>
    /// Automation may be enabled for a paired connection before it reports a meeting.
    /// Starting capture still requires <see cref="HasTrustedTeamsMeetingState"/>.
    /// </summary>
    private bool HasPairedTeamsConnection =>
        IsTeamsMuteSyncEnabled &&
        teamsMuteSnapshot.IsPairingKnown &&
        teamsApiClient?.TransportSnapshot is { IsConnected: true, PairingCredentialPresent: true };

    public bool CanEnableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        !IsTeamsAutomaticRecordingEnabled &&
        HasPairedTeamsConnection;

    public bool CanDisableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        IsTeamsAutomaticRecordingEnabled;

    /// <summary>
    /// State intended for the compact recording window. It is visible for any active capture
    /// (manual, test, or Teams automatic), plus the Teams-only start countdown.
    /// </summary>
    public RecordingOverlayState RecordingOverlayState => new(
        IsVisible: snapshot.State == RecordingCoordinatorState.Recording || IsTeamsAutomaticRecordingCountdownVisible,
        IsRecording: snapshot.State == RecordingCoordinatorState.Recording,
        IsTeamsAutomaticStartCountdown: IsTeamsAutomaticRecordingCountdownVisible,
        CountdownSeconds: TeamsAutomaticRecordingCountdownSeconds,
        CanCancelAutomaticStart: CanCancelTeamsAutomaticRecordingStart,
        CanStopRecording: CanStopRecordingFromOverlay);

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

    public string TeamsMuteEnableButtonText => IsTeamsMuteSyncEnabled ? "停用 Teams 靜音同步" : "啟用 Teams 靜音同步";

    public string TeamsMuteStatusText => teamsMuteSnapshot.Status switch
    {
        TeamsMuteSyncStatus.Disabled => "未啟用：不會連線至 Teams，也不會變更任何音訊輸入。",
        TeamsMuteSyncStatus.WaitingForTeamsApi => "正在等待本機 Teams Third-party API。請先啟動相容的 Teams 桌面用戶端。",
        TeamsMuteSyncStatus.WaitingForPairingApproval => "需要在 Teams 中核准配對；核准後才會收到會議狀態。",
        TeamsMuteSyncStatus.WaitingForMeeting => teamsMuteSnapshot.IsPairingKnown
            ? "Teams 已配對，正在等待 Teams 會議狀態。"
            : "已連線，正在等待 Teams 會議狀態。",
        TeamsMuteSyncStatus.Ready => "已取得 Teams 狀態；目前不在會議中。",
        TeamsMuteSyncStatus.InMeeting => teamsMuteSnapshot.LastMeetingState?.IsMuted == true
            ? "Teams 會議中：Teams 最近回報已靜音（Preview 快照）。"
            : "Teams 會議中：Teams 最近回報未靜音（Preview 快照；後續變更未驗證）。",
        TeamsMuteSyncStatus.Failed => string.IsNullOrWhiteSpace(teamsMuteSnapshot.Detail)
            ? "Teams 整合發生錯誤；請重新啟用或檢查 Teams。"
            : $"Teams 整合發生錯誤：{teamsMuteSnapshot.Detail}",
        _ => "Teams 整合狀態未知。",
    };

    public string TeamsMuteRoutingText => teamsMuteSnapshot.LastMeetingState is not { IsInMeeting: true }
        ? "此 Preview 只會讀取已配對 Teams 連線推送的狀態；不會向 Teams 發出靜音命令。"
        : !teamsMuteSnapshot.IsMicrophoneRoutingEngaged
            ? "Teams 只提供了會議快照。尚未驗證後續靜音事件，因此 Recorder 不會依「未靜音」快照自動開啟本機錄音麥克風。"
        : teamsInputMute.IsInputMuted
            ? "Teams 推送了靜音狀態：已靜音本次 M4A 錄音內選取的麥克風來源；不會改變 Teams 本身。"
            : "Teams 推送了後續未靜音狀態：本次 M4A 錄音內選取的麥克風來源可用；不會改變 Teams 本身。";

    public string TeamsAutomaticRecordingStatusText => !IsTeamsAutomaticRecordingEnabled
        ? HasPairedTeamsConnection
            ? "未啟用自動錄音：Teams 已配對。啟用後會等待可信的 Teams 會議狀態，才開始或停止錄音。"
            : "自動錄音尚未可用：請先啟用 Teams 同步、完成配對，並等待可信的會議狀態。"
        : teamsAutomaticSnapshot.State switch
        {
            TeamsAutoMeetingState.WaitingForMeeting => "自動錄音已啟用：正在等待 Teams 回報進入會議。",
            TeamsAutoMeetingState.StartCountdown(var seconds) => $"自動錄音已啟用：確認會議狀態後 {seconds} 秒開始。",
            TeamsAutoMeetingState.Starting => "自動錄音正在開始 M4A 工作階段。",
            TeamsAutoMeetingState.AutomaticRecording => "自動錄音進行中；離開會議後會先等待停止緩衝時間。",
            TeamsAutoMeetingState.ManualRecording => "手動錄音進行中；Teams 回報離開會議後會先等待停止緩衝時間。",
            TeamsAutoMeetingState.StopCountdown(var seconds) when teamsAutomaticSnapshot.RecordingOwner == RecordingOwner.Manual => $"Teams 回報已離開會議；{seconds} 秒後停止手動會議錄音。",
            TeamsAutoMeetingState.StopCountdown(var seconds) => $"Teams 回報已離開會議；{seconds} 秒後停止自動錄音。",
            TeamsAutoMeetingState.Stopping when teamsAutomaticSnapshot.RecordingOwner == RecordingOwner.Manual => "正在停止並儲存手動會議錄音。",
            TeamsAutoMeetingState.Stopping => "正在停止並儲存自動錄音。",
            TeamsAutoMeetingState.SuppressedUntilMeetingEnd => "本次會議的自動錄音已暫停，直到 Teams 回報離開會議。",
            TeamsAutoMeetingState.StartBlocked(var reason) => $"自動錄音未開始：{reason}",
            TeamsAutoMeetingState.StartFailed(var reason) => $"自動錄音失敗：{reason}",
            _ => "自動錄音狀態未知。",
        };

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
            "Preview／實驗性模式：請選擇一個可用的 Teams 應用程式或背景程序；程序不可用時會拒絕錄音，不會改錄系統音訊。",
        CaptureSourceKind.SelectedApplication =>
            $"Preview／實驗性模式：只會錄製 {SelectedProcess!.DisplayName}（PID {SelectedProcess.ProcessId}）；不保證包含所有參與者音訊，也不會回退至系統音訊。",
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
                PlaybackText = value is null
                    ? "請從資料庫選取有效的 M4A 檔案。"
                    : $"已選取：{value.DisplayName}";
                LibraryTitle = value?.Title ?? string.Empty;
                LibraryTagsText = value is null ? string.Empty : string.Join(", ", value.Tags);
                IsLibraryFavorite = value?.IsFavorite ?? false;
                IsRecycleConfirmationVisible = false;
                OnPropertyChanged(nameof(SelectedLibraryDetails));
                UpdateCommandStates();
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
        ? $"確認將「{item.DisplayName}」移至資源回收桶？此操作不會立即永久刪除檔案。"
        : string.Empty;

    public string SelectedLibraryDetails => SelectedLibraryItem is { } item
        ? $"{item.KindText} · {item.AudioBytes / 1024d / 1024d:0.0} MiB" +
          (item.HasRecoverableBackup ? " · 偵測到可復原備份" : string.Empty)
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

    public bool CanGenerateOpenAiSummary => CanStartOpenAiTranscription;

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

    public string LibrarySummaryText => $"{LibraryItems.Count} 個可播放工作階段 · {LibraryItems.Count(item => item.IsFavorite)} 個最愛";

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
                SeekPlayback(clamped);
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
        mediaPlayer.MediaOpened += (_, _) => dispatcherQueue.TryEnqueue(() =>
        {
            PlaybackText = "可播放。";
            playbackTimer.Start();
            UpdateCommandStates();
        });
        mediaPlayer.MediaFailed += (_, args) => dispatcherQueue.TryEnqueue(() =>
        {
            playbackTimer.Stop();
            PlaybackText = $"無法播放：{args.ErrorMessage}";
            UpdateCommandStates();
        });
        mediaPlayer.PlaybackSession.PlaybackStateChanged += (_, _) =>
            dispatcherQueue.TryEnqueue(UpdateCommandStates);
    }

    internal RecorderControlStatus GetControlStatus()
    {
        var stats = snapshot.Stats;
        var meeting = teamsMuteSnapshot.LastMeetingState;
        return new RecorderControlStatus(
            DateTimeOffset.UtcNow,
            isInitialized && isRecorderAvailable && !isShuttingDown,
            snapshot.Generation,
            snapshot.State.ToString(),
            snapshot.State == RecordingCoordinatorState.Recording,
            snapshot.IsTestRecording,
            IsRecordingMicrophoneMuted,
            SelectedRenderEndpoint?.DisplayName ?? "unavailable",
            SelectedMicrophoneEndpoint?.DisplayName ?? "none",
            SelectedCaptureSource?.Kind.ToString() ?? "unavailable",
            StatusText,
            ErrorText,
            new RecorderControlAudioStatus(
                stats.Mode.ToString(),
                stats.SourceSampleRate,
                stats.SourceChannels,
                stats.Packets,
                stats.InputFrames,
                stats.OutputFrames,
                stats.SilentPackets,
                stats.Discontinuities,
                stats.Peak,
                stats.PrimaryLevelPeak,
                stats.PrimaryLevelRms,
                stats.MicrophoneLevelPeak,
                stats.MicrophoneLevelRms,
                ToControlTimeline(stats.RenderTimeline),
                ToControlTimeline(stats.MicrophoneTimeline)),
            new RecorderControlTeamsStatus(
                IsTeamsMuteSyncEnabled,
                teamsMuteSnapshot.Status.ToString(),
                teamsMuteSnapshot.IsPairingKnown,
                teamsMuteSnapshot.IsPairingAuthenticated,
                meeting?.IsInMeeting,
                meeting?.IsMuted,
                IsTeamsAutomaticRecordingEnabled,
                teamsAutomaticSnapshot.State.GetType().Name,
                teamsApiClient?.TransportSnapshot ?? TeamsTransportDiagnosticSnapshot.Initial));
    }

    internal async Task<RecorderControlStatus> ExecuteControlRequestAsync(RecorderControlRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.SchemaVersion != RecorderControlProtocol.SchemaVersion)
            throw new RecorderControlException("unsupported_schema", "Unsupported control protocol schema version.");
        if (string.IsNullOrWhiteSpace(request.RequestId) || request.RequestId.Length > 80)
            throw new RecorderControlException("invalid_request", "requestId is required and must not exceed 80 characters.");
        if (!RecorderControlProtocol.IsSupportedCommand(request.Command))
            throw new RecorderControlException("unknown_command", "The requested control command is not supported.");

        if (request.Command != RecorderControlProtocol.Status)
            EnsureExpectedGeneration(request.ExpectedGeneration);

        switch (request.Command)
        {
            case RecorderControlProtocol.Status:
                break;
            case RecorderControlProtocol.RefreshDevices:
                await RefreshEndpointsAsync();
                break;
            case RecorderControlProtocol.RefreshTeams:
                if (teamsMuteSync is null)
                    throw new RecorderControlException("not_ready", "Teams integration is not enabled.");
                await teamsMuteSync.RefreshStateAsync();
                break;
            case RecorderControlProtocol.PairTeams:
                if (teamsMuteSync is null || !IsTeamsMuteSyncEnabled)
                    throw new RecorderControlException("not_ready", "Teams integration is not enabled.");
                await teamsMuteSync.RequestPairingAsync();
                break;
            case RecorderControlProtocol.ResetTeamsPairing:
                if (teamsMuteSync is null || !IsTeamsMuteSyncEnabled)
                    throw new RecorderControlException("not_ready", "Teams integration is not enabled.");
                await teamsMuteSync.ResetPairingAsync();
                break;
            case RecorderControlProtocol.Start:
                if (!CanStart) throw new RecorderControlException("invalid_state", "Recorder is not ready to start.");
                await StartAsync();
                break;
            case RecorderControlProtocol.Test:
                if (!CanStart) throw new RecorderControlException("invalid_state", "Recorder is not ready to start a test.");
                await StartTestAsync();
                break;
            case RecorderControlProtocol.Stop:
                if (!CanStop) throw new RecorderControlException("invalid_state", "There is no active recording to stop.");
                await StopAsync();
                break;
            case RecorderControlProtocol.SetMicrophoneMute:
                if (!request.Muted.HasValue)
                    throw new RecorderControlException("invalid_request", "muted must be supplied for microphone.setMuted.");
                teamsInputMute.SetLocalMuted(request.Muted.Value);
                break;
            case RecorderControlProtocol.Diagnostics:
                if (!CanSaveDiagnostics)
                    throw new RecorderControlException("not_ready", "Diagnostics are not available yet.");
                await SaveDiagnosticsAsync();
                break;
        }

        return GetControlStatus();
    }

    private void EnsureExpectedGeneration(long? expectedGeneration)
    {
        if (!expectedGeneration.HasValue)
            throw new RecorderControlException("generation_required", "expectedGeneration is required for commands that change or refresh recorder state.");
        if (expectedGeneration.Value != snapshot.Generation)
            throw new RecorderControlException(
                "stale_generation",
                $"Expected generation {expectedGeneration.Value}, current generation is {snapshot.Generation}.");
    }

    private static RecorderControlTimelineStatus ToControlTimeline(NativeSourceTimelineStats value) => new(
        value.DriftCorrections,
        value.LatePackets,
        value.LateFramesDropped,
        value.QueueOverflows,
        value.SourceDisconnects,
        value.Discontinuities);

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
        meetingSummaryClient = new OpenAiCompatibleMeetingSummaryClient();
        meetingSummaryCoordinator = new MeetingSummaryCoordinator(meetingSummaryClient);

        try
        {
            var profile = await openAiProviderRepository.LoadProfileAsync();
            hasOpenAiApiKey = await openAiProviderRepository.HasApiKeyAsync();
            if (profile is not null)
            {
                OpenAiApiBaseUrl = profile.BaseUrl;
                OpenAiAsrModel = profile.AsrModel;
                OpenAiLlmModel = profile.LlmModel;
                OpenAiLanguage = profile.Language;
                OpenAiPrompt = profile.Prompt;
                OpenAiProviderIntegrationStatus = "已載入本機 AI 供應商設定。按下 ASR 或摘要前仍會逐次要求確認。";
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
        var profile = OpenAICompatibleProviderProfile.Validated(
            OpenAiApiBaseUrl, OpenAiAsrModel, OpenAiLlmModel, OpenAiLanguage, OpenAiPrompt);
        await providers.SaveAsync(profile, replacementApiKey);
        OpenAiApiBaseUrl = profile.BaseUrl;
        OpenAiAsrModel = profile.AsrModel;
        OpenAiLlmModel = profile.LlmModel;
        OpenAiLanguage = profile.Language;
        OpenAiPrompt = profile.Prompt;
        hasOpenAiApiKey = await providers.HasApiKeyAsync();
        OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
        OpenAiProviderIntegrationStatus = string.IsNullOrWhiteSpace(replacementApiKey)
            ? "已儲存 AI 供應商設定；既有 API 金鑰保持不變。"
            : "已儲存 AI 供應商設定與目前 Windows 使用者的加密 API 金鑰。";
    });

    public Task ClearOpenAiApiKeyAsync() => RunOperationAsync(async () =>
    {
        var providers = openAiProviderRepository
            ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。");
        await providers.ClearApiKeyAsync();
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
        var profile = OpenAICompatibleProviderProfile.Validated(
            OpenAiApiBaseUrl, OpenAiAsrModel, OpenAiLlmModel, OpenAiLanguage, OpenAiPrompt);

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

    /// <summary>Starts a user-confirmed ASR job for one completed, managed M4A session.</summary>
    public Task StartOpenAiTranscriptionAsync() => RunOperationAsync(async () =>
    {
        var coordinator = transcriptionCoordinator
            ?? throw new InvalidOperationException("AI 逐字稿服務尚未準備完成。");
        var plan = GetSelectedManagedSessionPlan();
        var job = await coordinator.StartAsync(plan, explicitlyOptedIn: true);
        OpenAiProviderIntegrationStatus = "正在上傳並產生逐字稿；此工作只處理已完成的 M4A。";
        try
        {
            await job.Completion;
            OpenAiProviderIntegrationStatus = "逐字稿已完成並安全儲存在此錄音工作階段。";
            await RefreshLibraryCoreAsync();
        }
        catch
        {
            OpenAiProviderIntegrationStatus = "逐字稿未完成；已保留可檢查的本機工作階段狀態。";
            throw;
        }
    });

    /// <summary>Starts a separately user-confirmed meeting-summary request from an owned transcript.</summary>
    public Task GenerateOpenAiSummaryAsync() => RunOperationAsync(async () =>
    {
        var providers = openAiProviderRepository
            ?? throw new InvalidOperationException("AI 供應商設定尚未準備完成。");
        var coordinator = meetingSummaryCoordinator
            ?? throw new InvalidOperationException("AI 摘要服務尚未準備完成。");
        var plan = GetSelectedManagedSessionPlan();
        var snapshot = await providers.SnapshotAsync();
        OpenAiProviderIntegrationStatus = "正在傳送已完成逐字稿以產生摘要。音訊不會再次上傳。";
        try
        {
            await coordinator.SummarizeAndPublishAsync(plan, snapshot, userConsentGranted: true);
            OpenAiProviderIntegrationStatus = "摘要已完成並安全儲存在此錄音工作階段。";
        }
        catch
        {
            OpenAiProviderIntegrationStatus = "摘要未完成；已保留可檢查的本機工作階段狀態。";
            throw;
        }
    });

    private RecordingSessionPlan GetSelectedManagedSessionPlan()
    {
        var item = SelectedLibraryItem is { IsManaged: true, IsPlayable: true } selected
            ? selected
            : throw new InvalidOperationException("請先選取一個已完成且受管理的 M4A 錄音。" );
        var folder = Path.GetFullPath(item.SessionPath);
        if (!RecordingSessionLayout.TryGetKind(Path.GetFileName(folder), out var kind) || kind != item.Kind ||
            !PathEquals(item.MediaPath, Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName)))
            throw new IOException("選取的項目不是可供 AI 處理的受管理錄音工作階段。");
        return new RecordingSessionPlan(
            item.Kind,
            folder,
            Path.Combine(folder, RecordingSessionLayout.FinalAudioFileName),
            Path.Combine(folder, RecordingSessionLayout.BackupAudioFileName),
            Path.Combine(folder, RecordingSessionLayout.MetadataFileName),
            new StorageCapacityStatus(null, RecordingStorageDecision.Normal));
    }

    private async Task RestoreAppSettingsAsync()
    {
        try
        {
            pendingAppSettings = await appSettingsStore.LoadAsync();
            restoreTeamsMuteSyncAfterInitialization = pendingAppSettings?.TeamsMuteSyncEnabled == true;
            restoreTeamsAutomaticRecordingAfterInitialization = restoreTeamsMuteSyncAfterInitialization &&
                pendingAppSettings?.TeamsAutomaticRecordingEnabled == true;
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
            restoreTeamsMuteSyncAfterInitialization = false;
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
            // A PID or executable path is intentionally not saved. Restarting into this
            // mode requires the user to choose a currently live Teams process and never
            // falls back to system loopback.
            SelectedProcess = null;
            ProcessCatalogStatusText = "已還原「指定應用程式」模式；請重新整理並選取目前的 Teams 程序後才可開始錄音。";
        }
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
        TeamsMuteSyncEnabled = IsTeamsMuteSyncEnabled,
        TeamsAutomaticRecordingEnabled = IsTeamsAutomaticRecordingEnabled,
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
            await RestoreAppSettingsAsync();
            await InitializeOpenAiProviderAsync();
            recordingLifecycle = new RecordingLifecycleService(new NativeRecorderBridge(), OutputFolder);
            recordingLifecycle.SnapshotChanged += OnSnapshotChanged;
            InitializeGlobalMuteHotKey();
            SetRecorderAvailable(true);
            await RefreshEndpointsCoreAsync(announce: false);
            RefreshStorageReadiness();
            await RecoverAndRefreshLibraryAsync();
            await RestoreTeamsIntegrationAsync();
            ApplySnapshot(recordingLifecycle.Snapshot);
        }
        catch (Exception exception)
        {
            if (recordingLifecycle is not null)
            {
                recordingLifecycle.SnapshotChanged -= OnSnapshotChanged;
                recordingLifecycle.Dispose();
                recordingLifecycle = null;
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
        UpdateCommandStates();

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

        await DisposeTeamsMuteSyncAsync();
        DisposeGlobalMuteHotKey();
        teamsInputMute.Changed -= OnInputMuteChanged;

        var activeLifecycle = recordingLifecycle;
        if (activeLifecycle is not null)
        {
            try
            {
                var finalization = await activeLifecycle.FinalizeForRecoveryAsync();
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

        recordingLifecycle = null;
        activeLifecycle?.Dispose();
        mediaPlayer?.Dispose();
        mediaPlayer = null;
        transcriptionCoordinator?.Dispose();
        transcriptionCoordinator = null;
        meetingSummaryClient?.Dispose();
        meetingSummaryClient = null;
        openAiAsrTransport?.Dispose();
        openAiAsrTransport = null;
        openAiProviderConnectionClient?.Dispose();
        openAiProviderConnectionClient = null;
        openAiProviderRepository = null;
        isOpenAiProviderInitialized = false;
        SetRecorderAvailable(false);
    }

    private Task EnableTeamsMuteSyncAsync() => EnableTeamsMuteSyncAsync(restoreAutomaticRecording: false);

    private async Task RestoreTeamsIntegrationAsync()
    {
        var restoreSync = restoreTeamsMuteSyncAfterInitialization;
        var restoreAutomaticRecording = restoreTeamsAutomaticRecordingAfterInitialization;
        restoreTeamsMuteSyncAfterInitialization = false;
        restoreTeamsAutomaticRecordingAfterInitialization = false;
        if (restoreSync)
        {
            await EnableTeamsMuteSyncAsync(restoreAutomaticRecording);
        }
    }

    private async Task EnableTeamsMuteSyncAsync(bool restoreAutomaticRecording)
    {
        if (IsTeamsMuteSyncEnabled || isShuttingDown)
        {
            return;
        }

        isTeamsMuteSyncOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            teamsApiClient = new TeamsThirdPartyApiClient(
                TeamsThirdPartyApiIdentity.Recorder(typeof(RecordingViewModel).Assembly.GetName().Version?.ToString() ?? "0.0.0"),
                new WindowsDpapiTeamsPairingTokenStore());
            teamsMuteSync = new TeamsMuteSyncCoordinator(teamsApiClient, new InputMuteCoordinatorSink(teamsInputMute));
            teamsMuteSync.SnapshotChanged += OnTeamsMuteSnapshotChanged;
            teamsMuteSync.MeetingPresenceChanged += OnTeamsMeetingPresenceChanged;
            teamsAutomaticRecorder = new TeamsAutomaticRecordingController(
                StartTeamsAutomaticRecordingAsync,
                StopTeamsAutomaticRecordingAsync);
            teamsAutomaticRecorder.SnapshotChanged += OnTeamsAutomaticRecordingSnapshotChanged;
            teamsAutomaticRecorder.OperationFailed += OnTeamsAutomaticRecordingOperationFailed;
            await teamsMuteSync.SetEnabledAsync(true);
            teamsMuteSnapshot = teamsMuteSync.Snapshot;
            IsTeamsMuteSyncEnabled = true;
            if (restoreAutomaticRecording && teamsAutomaticRecorder is { } automatic)
            {
                await automatic.SetEnabledAsync(true);
                teamsAutomaticSnapshot = automatic.Snapshot;
                var meeting = teamsMuteSnapshot.LastMeetingState;
                if (meeting is { } trustedMeeting && HasTrustedTeamsMeetingState)
                {
                    await automatic.SetMeetingPresenceAsync(trustedMeeting.IsInMeeting);
                }
                OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
                OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            }
            OnPropertyChanged(nameof(TeamsMuteStatusText));
            OnPropertyChanged(nameof(TeamsMuteRoutingText));
            PersistAppSettingsInBackground();
        }
        catch (Exception exception)
        {
            await DisposeTeamsMuteSyncAsync();
            ErrorText = $"無法啟用 Teams 靜音同步：{exception.Message}";
        }
        finally
        {
            isTeamsMuteSyncOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private async Task DisableTeamsMuteSyncAsync()
    {
        isTeamsMuteSyncOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            await DisposeTeamsMuteSyncAsync();
            PersistAppSettingsInBackground();
        }
        catch (Exception exception)
        {
            ErrorText = $"無法停止 Teams 靜音同步：{exception.Message}";
        }
        finally
        {
            isTeamsMuteSyncOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private async Task RequestTeamsPairingAsync()
    {
        var sync = teamsMuteSync;
        if (sync is null || !CanRequestTeamsPairing)
        {
            return;
        }

        isTeamsMuteSyncOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            await sync.RequestPairingAsync();
            teamsMuteSnapshot = sync.Snapshot;
            OnPropertyChanged(nameof(TeamsMuteStatusText));
        }
        catch (Exception exception)
        {
            ErrorText = $"尚未能要求 Teams 配對：{exception.Message}";
        }
        finally
        {
            isTeamsMuteSyncOperationInProgress = false;
            UpdateCommandStates();
        }
    }

    private async Task RepairTeamsPairingAsync()
    {
        var sync = teamsMuteSync;
        if (sync is null || !CanRepairTeamsPairing)
        {
            return;
        }

        isTeamsMuteSyncOperationInProgress = true;
        UpdateCommandStates();
        try
        {
            await sync.ResetPairingAsync();
            teamsMuteSnapshot = sync.Snapshot;
            OnPropertyChanged(nameof(TeamsMuteStatusText));
            OnPropertyChanged(nameof(TeamsPairingHealthText));
            OnPropertyChanged(nameof(IsTeamsPairingRepairRecommended));
        }
        catch (Exception exception)
        {
            ErrorText = $"無法重新嘗試 Teams 配對：{exception.Message}";
        }
        finally
        {
            isTeamsMuteSyncOperationInProgress = false;
            UpdateCommandStates();
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
            var meeting = teamsMuteSnapshot.LastMeetingState;
            if (meeting is { } trustedMeeting && HasTrustedTeamsMeetingState)
            {
                await automatic.SetMeetingPresenceAsync(trustedMeeting.IsInMeeting);
            }
            teamsAutomaticSnapshot = automatic.Snapshot;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
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

    private async Task DisposeTeamsMuteSyncAsync()
    {
        await DisposeTeamsAutomaticRecordingAsync();

        var sync = teamsMuteSync;
        var client = teamsApiClient;
        teamsMuteSync = null;
        teamsApiClient = null;
        IsTeamsMuteSyncEnabled = false;
        teamsMuteSnapshot = TeamsMuteSyncSnapshot.Initial;
        teamsInputMute.SetInputMuted(false);
        OnPropertyChanged(nameof(TeamsMuteStatusText));
        OnPropertyChanged(nameof(TeamsMuteRoutingText));

        if (sync is not null)
        {
            sync.SnapshotChanged -= OnTeamsMuteSnapshotChanged;
            sync.MeetingPresenceChanged -= OnTeamsMeetingPresenceChanged;
            sync.Dispose();
        }

        if (client is not null)
        {
            await client.DisposeAsync();
        }
    }

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

    private void OnTeamsMuteSnapshotChanged(object? sender, TeamsMuteSyncSnapshot changed)
    {
        if (isShuttingDown)
        {
            return;
        }

        void Apply()
        {
            if (isShuttingDown || !ReferenceEquals(sender, teamsMuteSync))
            {
                return;
            }

            teamsMuteSnapshot = changed;
            OnPropertyChanged(nameof(TeamsMuteStatusText));
            OnPropertyChanged(nameof(TeamsMuteRoutingText));
            OnPropertyChanged(nameof(TeamsPairingHealthText));
            OnPropertyChanged(nameof(IsTeamsPairingRepairRecommended));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            UpdateCommandStates();

            if (HasTrustedTeamsMeetingState &&
                teamsAutomaticRecorder is { } automatic &&
                changed.LastMeetingState is { } meeting)
            {
                // SnapshotChanged is queued onto the UI thread, while MeetingPresenceChanged is
                // raised by the WebSocket callback.  Feed the controller here as well so a fresh
                // trusted state cannot be lost merely because the UI queue runs after that event.
                _ = UpdateTeamsAutomaticMeetingPresenceAsync(automatic, meeting.IsInMeeting);
            }
        }

        if (dispatcherQueue.HasThreadAccess)
        {
            Apply();
        }
        else
        {
            dispatcherQueue.TryEnqueue(Apply);
        }
    }

    private void OnTeamsMeetingPresenceChanged(object? sender, bool isInMeeting)
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !ReferenceEquals(sender, teamsMuteSync) || isShuttingDown)
        {
            return;
        }

        _ = UpdateTeamsAutomaticMeetingPresenceAsync(automatic, isInMeeting);
    }

    private async Task UpdateTeamsAutomaticMeetingPresenceAsync(TeamsAutomaticRecordingController automatic, bool isInMeeting)
    {
        try
        {
            // A state event is only accepted from the current coordinator, and the coordinator
            // has already validated the paired API message before raising this event.
            if (!ReferenceEquals(automatic, teamsAutomaticRecorder) || !HasTrustedTeamsMeetingState)
            {
                return;
            }

            await automatic.SetMeetingPresenceAsync(isInMeeting);
        }
        catch (ObjectDisposedException)
        {
            // A disable/shutdown can race an already-queued Teams callback.
        }
        catch (Exception exception)
        {
            ReportTeamsAutomaticRecordingFailure(exception.Message);
        }
    }

    private async Task DisableTeamsAutomaticRecordingAfterTrustLossAsync()
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic is null || !automatic.Snapshot.IsEnabled)
        {
            return;
        }

        try
        {
            await automatic.SetEnabledAsync(false);
            teamsAutomaticSnapshot = automatic.Snapshot;
            ErrorText = "Teams 會議狀態不再可信；已停用自動錄音。現有錄音會保留並交由使用者控制。";
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            NotifyRecordingOverlayStateChanged();
            UpdateCommandStates();
        }
        catch (ObjectDisposedException)
        {
        }
        catch (Exception exception)
        {
            ReportTeamsAutomaticRecordingFailure(exception.Message);
        }
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
        teamsInputMute.SetLocalMuted(!teamsInputMute.IsLocalMuted);
        return Task.CompletedTask;
    }

    private void InitializeGlobalMuteHotKey()
    {
        try
        {
            globalHotKeyRegistrar = new WindowsGlobalHotKeyRegistrar();
            globalMuteHotKey = new GlobalMuteHotKeyService(teamsInputMute, globalHotKeyRegistrar);
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
            OnPropertyChanged(nameof(TeamsMuteRoutingText));
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

    private bool CanStart =>
        IsSetupEditable &&
        storageCanStart &&
        SelectedDevicesReady &&
        SelectedProcessReady &&
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

    private bool CanRefreshLibrary => !IsBusy && !isShuttingDown;

    private bool CanPlay => mediaPlayer is not null && SelectedLibraryItem is { IsPlayable: true } && !isShuttingDown;

    private bool CanPause =>
        mediaPlayer?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing &&
        !isShuttingDown;

    public bool CanManageLibrary =>
        SelectedLibraryItem is { IsManaged: true } &&
        !isShuttingDown;

    public bool CanConfirmRecycle =>
        IsRecycleConfirmationVisible &&
        SelectedLibraryItem is not null &&
        !isShuttingDown;

    private Task StartAsync() => RunOperationAsync(async () =>
    {
        var result = await StartRecordingAsync(RecordingSessionKind.Manual);
        if (result.State == RecordingCoordinatorState.Recording)
        {
            await NotifyManualRecordingStartedAsync();
        }
    });

    private Task StartTestAsync() => RunOperationAsync(async () =>
    {
        var result = await StartRecordingAsync(RecordingSessionKind.Test, TimeSpan.FromSeconds(10));
        if (result.State == RecordingCoordinatorState.Recording)
        {
            await NotifyManualRecordingStartedAsync();
        }
    });

    private Task StopAsync() => RunOperationAsync(async () =>
    {
        var automatic = teamsAutomaticRecorder;
        if (automatic?.Snapshot.RecordingOwner == RecordingOwner.TeamsAutomatic)
        {
            // An explicit Stop is a user decision.  Suppress re-starts for this meeting before
            // stopping the capture, then retain the finished session normally.
            await automatic.SuppressUntilMeetingEndsAsync();
        }

        var result = await GetRecordingLifecycle().StopAsync();
        ApplySnapshot(result);
        await EnsureSessionPublishedAsync();
        await RefreshLibraryCoreAsync();
        await NotifyManualRecordingStoppedAsync();
    });

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

    private async Task<TeamsAutomaticStartResult> StartTeamsAutomaticRecordingOnUiAsync(CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested || isShuttingDown)
        {
            return TeamsAutomaticStartResult.BlockedBy("應用程式正在停止。" );
        }

        if (!HasTrustedTeamsMeetingState || teamsMuteSnapshot.LastMeetingState is not { IsInMeeting: true })
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
            var result = await StartRecordingAsync(RecordingSessionKind.Meeting);
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
        await InvokeOnUiAsync(async () =>
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
        });
    }

    private Task RefreshEndpointsAsync() => RunOperationAsync(
        () => RefreshEndpointsCoreAsync(announce: true));

    private Task RefreshProcessCatalogAsync() => RunOperationAsync(RefreshProcessCatalogCoreAsync);

    private async Task RefreshProcessCatalogCoreAsync()
    {
        // Process enumeration can be slow or deny access to individual processes.
        // The Application catalog filters those cases and exposes no paths or command lines.
        var entries = TeamsProcessCatalogPolicy.FilterForTeams(
            await Task.Run(processCatalog.GetProcesses));
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
        ProcessCatalogStatusText = ProcessCatalog.Count == 0
            ? "找不到可用的 Teams 程序；請先開啟 Microsoft Teams，然後重新整理。"
            : $"已列出 {ProcessCatalog.Count} 個可用的 Teams 程序。";
    }

    private Task RefreshLibraryAsync() => RunOperationAsync(RefreshLibraryCoreAsync);

    private Task PlayAsync() => RunOperationAsync(() =>
    {
        if (SelectedLibraryItem is not { IsPlayable: true } item || mediaPlayer is null)
        {
            PlaybackText = "請選取存在的 M4A 檔案。";
            return Task.CompletedTask;
        }

        if (!PathEquals(loadedPlaybackPath, item.MediaPath))
        {
            mediaPlayer.Source = MediaSource.CreateFromUri(new Uri(item.MediaPath, UriKind.Absolute));
            loadedPlaybackPath = item.MediaPath;
        }

        mediaPlayer.Play();
        PlaybackText = $"正在播放：{item.DisplayName}";
        return Task.CompletedTask;
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
        PlaybackText = "已停止。";
        return Task.CompletedTask;
    });

    private Task SaveLibraryMetadataAsync() => RunOperationAsync(async () =>
    {
        var item = SelectedLibraryItem
            ?? throw new InvalidOperationException("請先選取要編輯的工作階段。");
        var tags = LibraryTagsText.Split(
            [',', ';', '\r', '\n'],
            StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var library = GetLibraryService();
        await Task.Run(() => library.UpdateMetadataAsync(
            item.SessionPath,
            LibraryTitle,
            tags,
            IsLibraryFavorite));
        await RefreshLibraryCoreAsync();
        SelectedLibraryItem = LibraryItems.FirstOrDefault(candidate =>
            PathEquals(candidate.SessionPath, item.SessionPath));
        PlaybackText = "已儲存工作階段資料。";
    });

    private Task OpenLibraryFolderAsync() => RunOperationAsync(() =>
    {
        var item = SelectedLibraryItem
            ?? throw new InvalidOperationException("請先選取要開啟的工作階段。");
        if (!Directory.Exists(item.SessionPath))
        {
            throw new DirectoryNotFoundException("選取的工作階段資料夾已不存在。");
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = item.SessionPath,
            UseShellExecute = true,
        });
        return Task.CompletedTask;
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

    private Task RequestRecycleLibraryAsync() => RunOperationAsync(() =>
    {
        if (SelectedLibraryItem is null)
        {
            throw new InvalidOperationException("請先選取要移除的工作階段。");
        }

        IsRecycleConfirmationVisible = true;
        return Task.CompletedTask;
    });

    private Task CancelRecycleLibraryAsync() => RunOperationAsync(() =>
    {
        IsRecycleConfirmationVisible = false;
        return Task.CompletedTask;
    });

    private Task ConfirmRecycleLibraryAsync() => RunOperationAsync(async () =>
    {
        var item = SelectedLibraryItem
            ?? throw new InvalidOperationException("請先選取要移除的工作階段。");
        if (!IsRecycleConfirmationVisible)
        {
            throw new InvalidOperationException("請先確認移至資源回收桶。");
        }

        if (PathEquals(loadedPlaybackPath, item.MediaPath))
        {
            mediaPlayer?.Pause();
            if (mediaPlayer is not null)
            {
                mediaPlayer.PlaybackSession.Position = TimeSpan.Zero;
            }
            SetPlaybackProgress(0d);
            loadedPlaybackPath = null;
        }

        await Task.Run(() => GetLibraryService().RecycleSession(item.SessionPath, userConfirmed: true));
        IsRecycleConfirmationVisible = false;
        SelectedLibraryItem = null;
        await RefreshLibraryCoreAsync();
        PlaybackText = "已將工作階段移至資源回收桶。";
    });

    private async Task<RecordingCoordinatorSnapshot> StartRecordingAsync(RecordingSessionKind kind, TimeSpan? testDuration = null)
    {
        if (!SelectedDevicesReady)
        {
            throw new InvalidOperationException("請重新選取可用的輸出裝置與麥克風後再開始錄製。");
        }

        await RefreshTeamsPlaybackEndpointObservationAsync();
        RefreshStorageReadiness();
        var lifecycle = GetRecordingLifecycle();
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
                TestDuration: testDuration));
        }
        else
        {
            started = await lifecycle.StartAsync(new RecordingStartRequest(
                kind,
                RecordingAudioSource.SystemLoopback,
                RenderEndpointId: SelectedRenderEndpoint?.EndpointId,
                MicrophoneEndpointId: SelectedMicrophoneEndpoint?.EndpointId,
                TestDuration: testDuration));
        }
        var plan = started.Session;
        NextOutputPath = plan.FinalAudioPath;
        lastResultText = $"正在建立工作階段：{plan.FinalAudioPath}";
        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();

        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        ErrorText = null;
        OnPropertyChanged(nameof(ElapsedText));
        ApplySnapshot(started.Snapshot);
        return started.Snapshot;
    }

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
            var result = await Task.Run(recordingLifecycle.ProbeTeamsRenderEndpoints);
            teamsPlaybackEndpointObservation = result.IsSuccess
                ? TeamsPlaybackEndpointObservation.Known(
                    result.ActiveEndpoints.Select(endpoint => endpoint.EndpointId))
                : TeamsPlaybackEndpointObservation.Unknown;
        }
        // The probe is advisory only. It must not prevent manual/test/Teams
        // starts if a driver, an old bridge, or an audio-session broker cannot
        // provide a useful answer.
        catch (Exception)
        {
            teamsPlaybackEndpointObservation = TeamsPlaybackEndpointObservation.Unknown;
        }

        OnPropertyChanged(nameof(TeamsPlaybackEndpointWarning));
        OnPropertyChanged(nameof(HasTeamsPlaybackEndpointWarning));
    }

    private async Task RecoverAndRefreshLibraryAsync()
    {
        try
        {
            var startup = await Task.Run(() => GetLibraryService().RecoverAtStartupAsync());
            var recoveredCount = startup.RecoveryResults.Count(result => result.Recovered);
            if (recoveredCount > 0)
            {
                StatusText = $"已復原 {recoveredCount} 個先前中斷的音訊工作階段。";
            }
        }
        catch (Exception exception)
        {
            ErrorText = $"無法檢查中斷復原：{exception.Message}";
        }

        await RefreshLibraryCoreAsync();
    }

    private async Task RefreshLibraryCoreAsync()
    {
        try
        {
            var sessions = await Task.Run(() => GetLibraryService().ListSessions());
            var selectedPath = SelectedLibraryItem?.MediaPath;
            LibraryItems.Clear();
            foreach (var session in sessions)
            {
                var displayName = string.IsNullOrWhiteSpace(session.Metadata.Title)
                    ? session.IsManaged
                        ? Path.GetFileName(session.FolderPath)
                        : Path.GetFileNameWithoutExtension(session.AudioPath)
                    : session.Metadata.Title;
                LibraryItems.Add(new LibraryRecording(
                    displayName,
                    session.AudioPath,
                    session.FolderPath,
                    IsPlayable: File.Exists(session.AudioPath),
                    session.Metadata.Title,
                    session.Metadata.Tags,
                    session.Metadata.IsFavorite,
                    session.Kind,
                    session.AudioBytes,
                    session.HasRecoverableBackup,
                    session.IsManaged));
            }

            SelectedLibraryItem = LibraryItems.FirstOrDefault(item =>
                PathEquals(item.MediaPath, selectedPath));
            OnPropertyChanged(nameof(LibrarySummaryText));
        }
        catch (Exception exception)
        {
            ErrorText = $"無法讀取本機工作階段資料庫：{exception.Message}";
        }
    }

    private async Task EnsureSessionPublishedAsync()
    {
        var result = await GetRecordingLifecycle().PublishCompletedAsync();
        if (result.Session is null)
        {
            return;
        }

        if (result.Published)
        {
            NextOutputPath = result.Session.FinalAudioPath;
            lastResultText = $"Published: {result.Session.FinalAudioPath}";
            StatusText = "Recording saved.";
            await RefreshLibraryCoreAsync();
        }
        else
        {
            lastResultText = "The recording could not be published; recovery evidence was retained.";
            ErrorText = result.Error?.Message ?? "The recording session could not be published.";
        }

        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();
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

    private async Task RefreshTelemetryAsync()
    {
        if (isShuttingDown ||
            isTelemetryRefreshInProgress ||
            snapshot.State != RecordingCoordinatorState.Recording ||
            recordingLifecycle is null)
        {
            return;
        }

        isTelemetryRefreshInProgress = true;
        try
        {
            RefreshElapsed();
            ApplySnapshot(await recordingLifecycle.RefreshAsync());
        }
        catch (Exception exception)
        {
            ErrorText = $"無法更新錄音狀態：{exception.Message}";
        }
        finally
        {
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
        NotifyRecordingOverlayStateChanged();
        RefreshElapsed();
        if (changed.State == RecordingCoordinatorState.Recording)
        {
            AppendWaveform(OutputWaveformBars, changed.Stats.PrimaryLevelPeak);
            AppendWaveform(InputWaveformBars, changed.Stats.MicrophoneLevelPeak);
            ApplyRecordingMicrophoneMute(teamsInputMute.IsMuted);
            if (!telemetryTimer.IsRunning)
            {
                telemetryTimer.Start();
            }
        }
        else
        {
            telemetryTimer.Stop();
            ResetWaveforms();
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
            _ = EnsureSessionPublishedAsync();
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
        var progress = session.NaturalDuration.TotalSeconds > 0
            ? Math.Clamp(session.Position.TotalSeconds / session.NaturalDuration.TotalSeconds, 0d, 1d)
            : 0d;
        SetPlaybackProgress(progress);
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

    private void SeekPlayback(double progress)
    {
        if (!CanSeek || mediaPlayer is null)
        {
            return;
        }

        mediaPlayer.PlaybackSession.Position = TimeSpan.FromTicks(
            (long)(mediaPlayer.PlaybackSession.NaturalDuration.Ticks * progress));
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
        RefreshLibraryCommand.RaiseCanExecuteChanged();
        PlayCommand.RaiseCanExecuteChanged();
        PauseCommand.RaiseCanExecuteChanged();
        StopPlaybackCommand.RaiseCanExecuteChanged();
        SaveLibraryMetadataCommand.RaiseCanExecuteChanged();
        OpenLibraryFolderCommand.RaiseCanExecuteChanged();
        RequestRecycleLibraryCommand.RaiseCanExecuteChanged();
        ConfirmRecycleLibraryCommand.RaiseCanExecuteChanged();
        CancelRecycleLibraryCommand.RaiseCanExecuteChanged();
        EnableTeamsMuteSyncCommand.RaiseCanExecuteChanged();
        DisableTeamsMuteSyncCommand.RaiseCanExecuteChanged();
        RequestTeamsPairingCommand.RaiseCanExecuteChanged();
        RepairTeamsPairingCommand.RaiseCanExecuteChanged();
        EnableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        DisableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        CancelTeamsAutomaticRecordingStartCommand.RaiseCanExecuteChanged();
        StopRecordingFromOverlayCommand.RaiseCanExecuteChanged();
        ToggleLocalMicrophoneMuteCommand.RaiseCanExecuteChanged();
        TestOpenAiProviderConnectionCommand.RaiseCanExecuteChanged();
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
        OnPropertyChanged(nameof(CanSaveDiagnostics));
        OnPropertyChanged(nameof(CanOpenDiagnosticsFolder));
        OnPropertyChanged(nameof(CanSeek));
        OnPropertyChanged(nameof(CanManageLibrary));
        OnPropertyChanged(nameof(CanConfirmRecycle));
        OnPropertyChanged(nameof(CanManageTeamsMuteSync));
        OnPropertyChanged(nameof(CanRequestTeamsPairing));
        OnPropertyChanged(nameof(CanRepairTeamsPairing));
        OnPropertyChanged(nameof(TeamsPairingHealthText));
        OnPropertyChanged(nameof(IsTeamsPairingRepairRecommended));
        OnPropertyChanged(nameof(IsRecordingMicrophoneMuted));
        OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
        OnPropertyChanged(nameof(GlobalMuteHotKeyStatus));
        OnPropertyChanged(nameof(IsOpenAiProviderAvailable));
        OnPropertyChanged(nameof(CanSaveOpenAiProvider));
        OnPropertyChanged(nameof(CanTestOpenAiProvider));
        OnPropertyChanged(nameof(CanRemoveOpenAiApiKey));
        OnPropertyChanged(nameof(OpenAiApiKeyFieldLabel));
        OnPropertyChanged(nameof(CanStartOpenAiTranscription));
        OnPropertyChanged(nameof(CanGenerateOpenAiSummary));
    }

    private static string GetStatusText(RecordingCoordinatorSnapshot snapshot) => snapshot.State switch
    {
        RecordingCoordinatorState.Ready => "準備就緒",
        RecordingCoordinatorState.Starting => "正在開始錄音…",
        RecordingCoordinatorState.Recording when snapshot.IsTestRecording => "10 秒測試錄音中",
        RecordingCoordinatorState.Recording => "錄音中",
        RecordingCoordinatorState.Stopping => "正在停止並儲存…",
        RecordingCoordinatorState.Stopped when snapshot.HasRecoverableFault => "錄音異常已完成清理；保留可復原證據，可開始新的錄音。",
        RecordingCoordinatorState.Stopped => "正在發佈 M4A 工作階段…",
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

    /// <summary>
    /// The Teams API supplies an absolute mute state.  This adapter only feeds the
    /// in-process coordinator; a later host may observe it to drive a real input
    /// path, but this WinUI shell neither requires nor probes for a virtual driver.
    /// </summary>
    private sealed class InputMuteCoordinatorSink(InputMuteCoordinator coordinator) : IRecorderMicrophoneMuteSink
    {
        public void SetMuted(bool muted) => coordinator.SetInputMuted(muted);
    }

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

public sealed record LibraryRecording(
    string DisplayName,
    string MediaPath,
    string SessionPath,
    bool IsPlayable,
    string? Title,
    IReadOnlyList<string> Tags,
    bool IsFavorite,
    RecordingSessionKind Kind,
    long AudioBytes,
    bool HasRecoverableBackup,
    bool IsManaged)
{
    public string KindText => Kind switch
    {
        RecordingSessionKind.Meeting => "會議",
        RecordingSessionKind.Test => "測試",
        _ => "手動",
    };

    public string AvailabilityText => IsManaged ? "受管理工作階段" : "舊版 M4A · 僅可播放";

    public string TagsText => Tags.Count == 0 ? "未加標籤" : string.Join("、", Tags);
}
