using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Recorder.Core;
using TeamsRecorder.Windows.Application;
using TeamsRecorder.Windows.Application.Recovery;
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
    private NativeRecorderBridge? nativeBridge;
    private RecordingCoordinator? coordinator;
    private SessionStorageService? sessionStorage;
    private SessionRecoveryService? recoveryService;
    private string? storageServiceRoot;
    private RecordingSessionPlan? activeSession;
    private Task? activeSessionPublication;
    private RecordingCoordinatorSnapshot snapshot = RecordingCoordinatorSnapshot.Initial;
    private MediaPlayer? mediaPlayer;
    private EndpointChoice? selectedRenderEndpoint;
    private EndpointChoice? selectedMicrophoneEndpoint;
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
    private bool isUpdatingPlaybackPosition;
    private double playbackProgress;
    private string playbackText = "請從資料庫選取有效的 M4A 檔案。";

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
        RefreshLibraryCommand = new AsyncRelayCommand(RefreshLibraryAsync, () => CanRefreshLibrary);
        PlayCommand = new AsyncRelayCommand(PlayAsync, () => CanPlay);
        PauseCommand = new AsyncRelayCommand(PauseAsync, () => CanPause);
        StopPlaybackCommand = new AsyncRelayCommand(StopPlaybackAsync, () => mediaPlayer is not null);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<EndpointChoice> RenderEndpoints { get; } = [];

    public ObservableCollection<EndpointChoice> CaptureEndpoints { get; } = [];

    public ObservableCollection<LibraryRecording> LibraryItems { get; } = [];

    public AsyncRelayCommand StartCommand { get; }

    public AsyncRelayCommand StopCommand { get; }

    public AsyncRelayCommand StartTestCommand { get; }

    public AsyncRelayCommand RefreshDevicesCommand { get; }

    public AsyncRelayCommand RefreshLibraryCommand { get; }

    public AsyncRelayCommand PlayCommand { get; }

    public AsyncRelayCommand PauseCommand { get; }

    public AsyncRelayCommand StopPlaybackCommand { get; }

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
                UpdateCommandStates();
            }
        }
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
                UpdateCommandStates();
            }
        }
    }

    public string OutputFolder
    {
        get => outputFolder;
        set
        {
            if (!SetProperty(ref outputFolder, value ?? string.Empty))
            {
                return;
            }

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
        : "尚未可用：請依錯誤訊息修正 native bridge 或裝置設定。";

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

    public string RenderHealthText => snapshot.Stats.SourceSampleRate == 0
        ? "系統輸出：等待第一個音訊封包。"
        : $"系統輸出：bridge 輸出 48 kHz stereo；來源格式 {snapshot.Stats.SourceSampleRate:N0} Hz / {snapshot.Stats.SourceChannels} 聲道。";

    public string MicrophoneHealthText => SelectedMicrophoneEndpoint switch
    {
        { IsAvailable: false } => "麥克風：裝置中斷，已封鎖開始錄製。",
        { EndpointId: null } => "麥克風：未選取（不錄製）。",
        _ => "麥克風：已選取並會納入 mixed 錄音；來源別統計待 bridge 擴充。",
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

    public string LibrarySummaryText => $"{LibraryItems.Count} 個可播放工作階段";

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
            nativeBridge = new NativeRecorderBridge();
            coordinator = new RecordingCoordinator(nativeBridge);
            coordinator.SnapshotChanged += OnSnapshotChanged;
            isRecorderAvailable = true;
            await RefreshEndpointsCoreAsync();
            RefreshStorageReadiness();
            await RecoverAndRefreshLibraryAsync();
            ApplySnapshot(coordinator.Snapshot);
        }
        catch (Exception exception)
        {
            coordinator?.SnapshotChanged -= OnSnapshotChanged;
            coordinator = null;
            nativeBridge?.Dispose();
            nativeBridge = null;
            isRecorderAvailable = false;
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

        var activeCoordinator = coordinator;
        if (activeCoordinator is not null)
        {
            try
            {
                var stopped = await activeCoordinator.StopAsync();
                ApplySnapshot(stopped);
                await EnsureSessionPublishedAsync();
            }
            catch
            {
                // Leave a valid backup for conservative startup recovery rather
                // than deleting evidence while the process is closing.
            }
            finally
            {
                activeCoordinator.SnapshotChanged -= OnSnapshotChanged;
            }
        }

        coordinator = null;
        nativeBridge?.Dispose();
        nativeBridge = null;
        mediaPlayer?.Dispose();
        mediaPlayer = null;
        isRecorderAvailable = false;
    }

    private bool IsSetupEditable =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        snapshot.State is RecordingCoordinatorState.Ready or
            RecordingCoordinatorState.Stopped or
            RecordingCoordinatorState.Failed;

    private bool SelectedDevicesReady =>
        SelectedRenderEndpoint is { IsAvailable: true } &&
        (SelectedMicrophoneEndpoint is null or { EndpointId: null } or { IsAvailable: true });

    private bool CanStart =>
        IsSetupEditable &&
        storageCanStart &&
        SelectedDevicesReady &&
        activeSessionPublication is null;

    private bool CanStop =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        (snapshot.State is RecordingCoordinatorState.Starting or
            RecordingCoordinatorState.Recording or
            RecordingCoordinatorState.Stopping ||
            snapshot.State == RecordingCoordinatorState.Faulted && snapshot.NeedsNativeCleanup);

    private bool CanRefreshDevices => IsSetupEditable;

    private bool CanRefreshLibrary => !IsBusy && !isShuttingDown;

    private bool CanPlay => mediaPlayer is not null && SelectedLibraryItem is { IsPlayable: true } && !isShuttingDown;

    private bool CanPause =>
        mediaPlayer?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing &&
        !isShuttingDown;

    private Task StartAsync() => RunOperationAsync(async () =>
    {
        var request = CreateStartRequest(RecordingSessionKind.Manual);
        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        ErrorText = null;
        OnPropertyChanged(nameof(ElapsedText));

        var result = await GetCoordinator().StartMixedAsync(request);
        ApplySnapshot(result);
        if (result.State != RecordingCoordinatorState.Recording)
        {
            activeSession = null;
        }
    });

    private Task StartTestAsync() => RunOperationAsync(async () =>
    {
        var request = CreateStartRequest(RecordingSessionKind.Test);
        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        ErrorText = null;
        OnPropertyChanged(nameof(ElapsedText));

        var result = await GetCoordinator().StartMixedTestAsync(request, TimeSpan.FromSeconds(10));
        ApplySnapshot(result);
        if (result.State != RecordingCoordinatorState.Recording)
        {
            activeSession = null;
        }
    });

    private Task StopAsync() => RunOperationAsync(async () =>
    {
        var result = await GetCoordinator().StopAsync();
        ApplySnapshot(result);
        await EnsureSessionPublishedAsync();
        await RefreshLibraryCoreAsync();
    });

    private Task RefreshEndpointsAsync() => RunOperationAsync(RefreshEndpointsCoreAsync);

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

    private NativeMixedRecordingRequest CreateStartRequest(RecordingSessionKind kind)
    {
        if (!SelectedDevicesReady)
        {
            throw new InvalidOperationException("請重新選取可用的輸出裝置與麥克風後再開始錄製。");
        }

        RefreshStorageReadiness();
        var storage = GetSessionStorage();
        var plan = storage.CreateSessionPlan(kind);
        activeSession = plan;
        activeSessionPublication = null;
        NextOutputPath = plan.FinalAudioPath;
        lastResultText = $"正在建立工作階段：{plan.FinalAudioPath}";
        OnPropertyChanged(nameof(ResultText));
        UpdateCommandStates();

        return new NativeMixedRecordingRequest(
            plan.BackupAudioPath,
            SelectedRenderEndpoint?.EndpointId,
            SelectedMicrophoneEndpoint?.EndpointId);
    }

    private async Task RefreshEndpointsCoreAsync()
    {
        var result = await GetCoordinator().RefreshEndpointsAsync();
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
            var recovery = GetRecoveryService();
            var recovered = await Task.Run(() => recovery.RecoverAsync());
            var recoveredCount = recovered.Count(result => result.Recovered);
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
            var storage = GetSessionStorage();
            var sessions = await Task.Run(storage.ListSessions);
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
                    IsPlayable: File.Exists(session.AudioPath)));
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

    private Task EnsureSessionPublishedAsync()
    {
        if (activeSession is not { } plan)
        {
            return Task.CompletedTask;
        }

        if (activeSessionPublication is not null)
        {
            return activeSessionPublication;
        }

        try
        {
            activeSessionPublication = PublishSessionAsync(GetSessionStorage(), plan);
            UpdateCommandStates();
            return activeSessionPublication;
        }
        catch (Exception exception)
        {
            ErrorText = $"無法發佈完成的 M4A 工作階段：{exception.Message}";
            activeSession = null;
            return Task.CompletedTask;
        }
    }

    private async Task PublishSessionAsync(SessionStorageService storage, RecordingSessionPlan plan)
    {
        try
        {
            await storage.PublishCompletedMediaAsync(plan);
            NextOutputPath = plan.FinalAudioPath;
            lastResultText = $"已完成並儲存：{plan.FinalAudioPath}";
            StatusText = "已停止並儲存 M4A 工作階段。";
            OnPropertyChanged(nameof(ResultText));
            await RefreshLibraryCoreAsync();
        }
        catch (Exception exception)
        {
            lastResultText = "M4A 可能已完成，但工作階段中繼資料無法發佈；下次啟動會保留復原證據。";
            ErrorText = $"停止後無法發佈工作階段：{exception.Message}";
            OnPropertyChanged(nameof(ResultText));
        }
        finally
        {
            if (activeSession == plan)
            {
                activeSession = null;
            }

            activeSessionPublication = null;
            UpdateCommandStates();
        }
    }

    private void RefreshStorageReadiness()
    {
        try
        {
            storageCapacity = GetSessionStorage().GetCapacityStatus();
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

    private SessionStorageService GetSessionStorage()
    {
        var root = OutputFolder.Trim();
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new InvalidOperationException("請先輸入工作階段資料夾。");
        }

        var fullRoot = Path.GetFullPath(root);
        if (sessionStorage is null || !PathEquals(storageServiceRoot, fullRoot))
        {
            sessionStorage = new SessionStorageService(fullRoot);
            recoveryService = new SessionRecoveryService(sessionStorage);
            storageServiceRoot = fullRoot;
        }

        return sessionStorage;
    }

    private SessionRecoveryService GetRecoveryService()
    {
        _ = GetSessionStorage();
        return recoveryService
            ?? throw new InvalidOperationException("工作階段復原服務尚未準備完成。");
    }

    private void ResetSessionStorage()
    {
        sessionStorage = null;
        recoveryService = null;
        storageServiceRoot = null;
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
            coordinator is null)
        {
            return;
        }

        isTelemetryRefreshInProgress = true;
        try
        {
            RefreshElapsed();
            ApplySnapshot(await coordinator.RefreshAsync());
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

        if (changed.State == RecordingCoordinatorState.Stopped)
        {
            _ = EnsureSessionPublishedAsync();
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

    private RecordingCoordinator GetCoordinator() => coordinator
        ?? throw new InvalidOperationException("錄音元件尚未準備完成。");

    private void UpdateCommandStates()
    {
        StartCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        StartTestCommand.RaiseCanExecuteChanged();
        RefreshDevicesCommand.RaiseCanExecuteChanged();
        RefreshLibraryCommand.RaiseCanExecuteChanged();
        PlayCommand.RaiseCanExecuteChanged();
        PauseCommand.RaiseCanExecuteChanged();
        StopPlaybackCommand.RaiseCanExecuteChanged();
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
        OnPropertyChanged(nameof(CanSeek));
    }

    private static string GetStatusText(RecordingCoordinatorSnapshot snapshot) => snapshot.State switch
    {
        RecordingCoordinatorState.Ready => "準備就緒",
        RecordingCoordinatorState.Starting => "正在開始錄音…",
        RecordingCoordinatorState.Recording when snapshot.IsTestRecording => "10 秒測試錄音中",
        RecordingCoordinatorState.Recording => "錄音中",
        RecordingCoordinatorState.Stopping => "正在停止並儲存…",
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
    bool IsPlayable);
