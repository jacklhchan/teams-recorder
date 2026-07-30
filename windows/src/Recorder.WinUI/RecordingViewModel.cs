using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
using TeamsRecorder.Windows.Application.Library;
using TeamsRecorder.Windows.Application.Storage;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Keeps device choice, native recording lifecycle, session publication, and
/// local playback at the WinUI edge. The coordinator remains the single owner
/// of native start/stop serialization.
/// </summary>
public sealed class RecordingViewModel : INotifyPropertyChanged
{
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

    public RecordingViewModel()
    {
        dispatcherQueue = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Teams Recorder 必須在 WinUI 執行緒上建立。");
        telemetryTimer = dispatcherQueue.CreateTimer();
        telemetryTimer.Interval = TimeSpan.FromMilliseconds(400);
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
        RequestTeamsPairingCommand = new AsyncRelayCommand(RequestTeamsPairingAsync, () => CanManageTeamsMuteSync && IsTeamsMuteSyncEnabled);
        EnableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(EnableTeamsAutomaticRecordingAsync, () => CanEnableTeamsAutomaticRecording);
        DisableTeamsAutomaticRecordingCommand = new AsyncRelayCommand(DisableTeamsAutomaticRecordingAsync, () => CanDisableTeamsAutomaticRecording);
        ToggleLocalMicrophoneMuteCommand = new AsyncRelayCommand(ToggleLocalMicrophoneMuteAsync, () => !isShuttingDown);
        teamsInputMute.Changed += OnInputMuteChanged;
        CaptureSources.Add(CaptureSourceChoice.SystemAudio);
        CaptureSources.Add(CaptureSourceChoice.SelectedApplication);
        selectedCaptureSource = CaptureSourceChoice.SystemAudio;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<EndpointChoice> RenderEndpoints { get; } = [];

    public ObservableCollection<EndpointChoice> CaptureEndpoints { get; } = [];

    public ObservableCollection<CaptureSourceChoice> CaptureSources { get; } = [];

    public ObservableCollection<ProcessSelectionChoice> ProcessCatalog { get; } = [];

    public ObservableCollection<LibraryRecording> LibraryItems { get; } = [];

    public AsyncRelayCommand StartCommand { get; }

    public AsyncRelayCommand StopCommand { get; }

    public AsyncRelayCommand StartTestCommand { get; }

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

    public AsyncRelayCommand EnableTeamsAutomaticRecordingCommand { get; }

    public AsyncRelayCommand DisableTeamsAutomaticRecordingCommand { get; }

    public AsyncRelayCommand ToggleLocalMicrophoneMuteCommand { get; }

    public bool IsRecordingMicrophoneMuted => teamsInputMute.IsMuted;

    public string RecordingMicrophoneMuteText => SelectedMicrophoneEndpoint?.EndpointId is null
        ? "未選取錄音麥克風；靜音設定會在下一次選取麥克風後套用。"
        : IsRecordingMicrophoneMuted
            ? "錄音中的麥克風已靜音；系統輸出錄音不受影響。"
            : "錄音中的麥克風未靜音。";

    public string GlobalMuteHotKeyStatus => globalMuteHotKeyStatus;

    /// <summary>Teams integration is deliberately opt-in and is off at every app launch.</summary>
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

    /// <summary>
    /// Automatic recording is deliberately a separate opt-in.  A Teams connection alone is
    /// insufficient: this remains false until a paired API supplies an authoritative meeting state.
    /// </summary>
    public bool IsTeamsAutomaticRecordingEnabled => teamsAutomaticSnapshot.IsEnabled;

    private bool HasTrustedTeamsMeetingState =>
        IsTeamsMuteSyncEnabled &&
        teamsMuteSnapshot.IsPairingAuthenticated &&
        teamsMuteSnapshot.Status is TeamsMuteSyncStatus.Ready or TeamsMuteSyncStatus.InMeeting &&
        teamsMuteSnapshot.LastMeetingState is not null;

    public bool CanEnableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        !IsTeamsAutomaticRecordingEnabled &&
        HasTrustedTeamsMeetingState;

    public bool CanDisableTeamsAutomaticRecording =>
        !isShuttingDown &&
        !isTeamsAutomaticRecordingOperationInProgress &&
        IsTeamsAutomaticRecordingEnabled;

    public string TeamsMuteEnableButtonText => IsTeamsMuteSyncEnabled ? "停用 Teams 靜音同步" : "啟用 Teams 靜音同步";

    public string TeamsMuteStatusText => teamsMuteSnapshot.Status switch
    {
        TeamsMuteSyncStatus.Disabled => "未啟用：不會連線至 Teams，也不會變更任何音訊輸入。",
        TeamsMuteSyncStatus.WaitingForTeamsApi => "正在等待本機 Teams Third-party API。請先啟動相容的 Teams 桌面用戶端。",
        TeamsMuteSyncStatus.WaitingForPairingApproval => "需要在 Teams 中核准配對；核准後才會收到會議狀態。",
        TeamsMuteSyncStatus.WaitingForMeeting => "已連線，正在等待 Teams 會議狀態。",
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
        ? HasTrustedTeamsMeetingState
            ? "未啟用自動錄音：必須由使用者明確啟用，才會依可信的 Teams 會議狀態開始或停止錄音。"
            : "自動錄音尚未可用：請先啟用 Teams 同步、完成配對，並等待可信的會議狀態。"
        : teamsAutomaticSnapshot.State switch
        {
            TeamsAutoMeetingState.WaitingForMeeting => "自動錄音已啟用：正在等待 Teams 回報進入會議。",
            TeamsAutoMeetingState.StartCountdown(var seconds) => $"自動錄音已啟用：確認會議狀態後 {seconds} 秒開始。",
            TeamsAutoMeetingState.Starting => "自動錄音正在開始 M4A 工作階段。",
            TeamsAutoMeetingState.AutomaticRecording => "自動錄音進行中；離開會議後會先等待停止緩衝時間。",
            TeamsAutoMeetingState.StopCountdown(var seconds) => $"Teams 回報已離開會議；{seconds} 秒後停止自動錄音。",
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
                UpdateCommandStates();
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
                UpdateCommandStates();
            }
        }
    }

    public CaptureSourceChoice? SelectedCaptureSource
    {
        get => selectedCaptureSource;
        set
        {
            if (SetProperty(ref selectedCaptureSource, value ?? CaptureSourceChoice.SystemAudio))
            {
                OnPropertyChanged(nameof(SelectedCaptureSourceDescription));
                OnPropertyChanged(nameof(RenderEndpointSelectionVisibility));
                OnPropertyChanged(nameof(SelectedApplicationPanelVisibility));
                UpdateCommandStates();
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
            "請選擇一個可用的應用程式或背景程序。",
        CaptureSourceKind.SelectedApplication =>
            $"只會錄製 {SelectedProcess!.DisplayName}（PID {SelectedProcess.ProcessId}）。",
        _ => "錄製系統音訊，並使用所選輸出裝置。",
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
            recordingLifecycle = new RecordingLifecycleService(new NativeRecorderBridge(), OutputFolder);
            recordingLifecycle.SnapshotChanged += OnSnapshotChanged;
            InitializeGlobalMuteHotKey();
            SetRecorderAvailable(true);
            await RefreshEndpointsCoreAsync();
            RefreshStorageReadiness();
            await RecoverAndRefreshLibraryAsync();
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
        SetRecorderAvailable(false);
    }

    private async Task EnableTeamsMuteSyncAsync()
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
            OnPropertyChanged(nameof(TeamsMuteStatusText));
            OnPropertyChanged(nameof(TeamsMuteRoutingText));
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
        if (sync is null || !IsTeamsMuteSyncEnabled)
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
            if (meeting is null || !HasTrustedTeamsMeetingState)
            {
                await automatic.SetEnabledAsync(false);
                ErrorText = "Teams 會議狀態在啟用自動錄音前失去信任；未開始錄音。";
                return;
            }

            await automatic.SetMeetingPresenceAsync(meeting.IsInMeeting);
            teamsAutomaticSnapshot = automatic.Snapshot;
            OnPropertyChanged(nameof(IsTeamsAutomaticRecordingEnabled));
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
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
            OnPropertyChanged(nameof(TeamsAutomaticRecordingStatusText));
            UpdateCommandStates();

            if (!HasTrustedTeamsMeetingState && teamsAutomaticRecorder?.Snapshot.IsEnabled == true)
            {
                _ = DisableTeamsAutomaticRecordingAfterTrustLossAsync();
            }
            else if (HasTrustedTeamsMeetingState &&
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
        SelectedLibraryItem is not null &&
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

    private Task RefreshEndpointsAsync() => RunOperationAsync(RefreshEndpointsCoreAsync);

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

    private async Task RefreshEndpointsCoreAsync()
    {
        var result = await GetRecordingLifecycle().RefreshEndpointsAsync();
        if (!result.IsSuccess)
        {
            ErrorText = result.Operation.Error ?? "無法取得 Windows 音訊裝置。";
            return;
        }

        var renderId = SelectedRenderEndpoint?.EndpointId;
        var microphoneId = SelectedMicrophoneEndpoint?.EndpointId;
        ReplaceEndpoints(
            RenderEndpoints,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Render),
            EndpointChoice.SystemDefault);
        ReplaceEndpoints(
            CaptureEndpoints,
            result.Endpoints.Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Capture),
            EndpointChoice.NoMicrophone);

        SelectedRenderEndpoint = RetainOrMarkUnavailable(
            RenderEndpoints,
            renderId,
            "輸出裝置");
        SelectedMicrophoneEndpoint = RetainOrMarkUnavailable(
            CaptureEndpoints,
            microphoneId,
            "麥克風");
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
                    ? Path.GetFileName(session.FolderPath)
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
                    session.HasRecoverableBackup));
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
        string? endpointId,
        string kind)
    {
        var match = choices.FirstOrDefault(choice =>
            string.Equals(choice.EndpointId, endpointId, StringComparison.Ordinal));
        if (match is not null)
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
        RefreshElapsed();
        if (changed.State == RecordingCoordinatorState.Recording)
        {
            ApplyRecordingMicrophoneMute(teamsInputMute.IsMuted);
            if (!telemetryTimer.IsRunning)
            {
                telemetryTimer.Start();
            }
        }
        else
        {
            telemetryTimer.Stop();
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
        OnPropertyChanged(nameof(AggregateHealthText));
        OnPropertyChanged(nameof(RenderHealthText));
        OnPropertyChanged(nameof(MicrophoneHealthText));
        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();
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

    private void UpdateCommandStates()
    {
        StartCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        StartTestCommand.RaiseCanExecuteChanged();
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
        EnableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        DisableTeamsAutomaticRecordingCommand.RaiseCanExecuteChanged();
        ToggleLocalMicrophoneMuteCommand.RaiseCanExecuteChanged();
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
        OnPropertyChanged(nameof(CanSeek));
        OnPropertyChanged(nameof(CanManageLibrary));
        OnPropertyChanged(nameof(CanConfirmRecycle));
        OnPropertyChanged(nameof(CanManageTeamsMuteSync));
        OnPropertyChanged(nameof(IsRecordingMicrophoneMuted));
        OnPropertyChanged(nameof(RecordingMicrophoneMuteText));
        OnPropertyChanged(nameof(GlobalMuteHotKeyStatus));
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
    bool HasRecoverableBackup)
{
    public string KindText => Kind switch
    {
        RecordingSessionKind.Meeting => "會議",
        RecordingSessionKind.Test => "測試",
        _ => "手動",
    };

    public string TagsText => Tags.Count == 0 ? "未加標籤" : string.Join("、", Tags);
}
