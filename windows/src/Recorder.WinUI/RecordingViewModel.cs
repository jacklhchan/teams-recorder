using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using TeamsRecorder.Windows.Application;

namespace TeamsRecorder.Windows.WinUI;

/// <summary>
/// Keeps WinUI concerns at the edge of the application while the recording
/// coordinator remains the owner of native lifecycle and serialization.
/// </summary>
public sealed class RecordingViewModel : INotifyPropertyChanged
{
    private readonly DispatcherQueue dispatcherQueue;
    private readonly DispatcherQueueTimer telemetryTimer;
    private NativeRecorderBridge? nativeBridge;
    private RecordingCoordinator? coordinator;
    private RecordingCoordinatorSnapshot snapshot = RecordingCoordinatorSnapshot.Initial;
    private EndpointChoice? selectedEndpoint;
    private string outputFolder;
    private string nextOutputPath = "開始錄音後會顯示 WAV 儲存位置。";
    private string statusText = "正在準備錄音元件…";
    private string? errorText;
    private DateTimeOffset? recordingStartedAt;
    private TimeSpan elapsed;
    private bool isBusy;
    private bool isInitialized;
    private bool isInitializing;
    private bool isRecorderAvailable;
    private bool isShuttingDown;
    private bool isTelemetryRefreshInProgress;

    public RecordingViewModel()
    {
        dispatcherQueue = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Teams Recorder 必須在 WinUI 執行緒上建立。");
        telemetryTimer = dispatcherQueue.CreateTimer();
        telemetryTimer.Interval = TimeSpan.FromMilliseconds(400);
        telemetryTimer.Tick += OnTelemetryTimerTick;

        outputFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Teams Recorder",
            "Recordings");

        StartCommand = new AsyncRelayCommand(StartAsync, () => CanStart);
        StopCommand = new AsyncRelayCommand(StopAsync, () => CanStop);
        StartTestCommand = new AsyncRelayCommand(StartTestAsync, () => CanStart);
        RefreshDevicesCommand = new AsyncRelayCommand(RefreshEndpointsAsync, () => CanRefreshDevices);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<EndpointChoice> Endpoints { get; } = [];

    public AsyncRelayCommand StartCommand { get; }

    public AsyncRelayCommand StopCommand { get; }

    public AsyncRelayCommand StartTestCommand { get; }

    public AsyncRelayCommand RefreshDevicesCommand { get; }

    public EndpointChoice? SelectedEndpoint
    {
        get => selectedEndpoint;
        set
        {
            if (SetProperty(ref selectedEndpoint, value))
            {
                OnPropertyChanged(nameof(SelectedEndpointDescription));
            }
        }
    }

    public string OutputFolder
    {
        get => outputFolder;
        set
        {
            if (SetProperty(ref outputFolder, value ?? string.Empty))
            {
                OnPropertyChanged(nameof(NextOutputPath));
            }
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

    public bool IsDeviceSelectionEnabled => CanStart;

    public string SelectedEndpointDescription => SelectedEndpoint switch
    {
        null => "正在讀取 Windows 的輸出裝置…",
        { EndpointId: null } => "使用 Windows 目前設定的預設輸出裝置。",
        _ => $"指定裝置：{SelectedEndpoint.DisplayName}",
    };

    public string ElapsedText => elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture);

    public double PeakPercent => Math.Clamp((double)snapshot.Stats.Peak * 100d, 0d, 100d);

    public string PeakText => $"{PeakPercent:0.0}%";

    public string PacketText => snapshot.Stats.Packets.ToString("N0", CultureInfo.CurrentCulture);

    public string SourceHealthText
    {
        get
        {
            var format = snapshot.Stats.SourceSampleRate == 0
                ? "等待音訊資料"
                : $"{snapshot.Stats.SourceSampleRate:N0} Hz · {snapshot.Stats.SourceChannels} 聲道";
            return $"{snapshot.Stats.Discontinuities:N0} 次 / {format}";
        }
    }

    private bool CanStart =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        snapshot.State is RecordingCoordinatorState.Ready or
            RecordingCoordinatorState.Stopped or
            RecordingCoordinatorState.Failed;

    private bool CanStop =>
        isRecorderAvailable &&
        !IsBusy &&
        !isShuttingDown &&
        ((snapshot.State is RecordingCoordinatorState.Starting or
            RecordingCoordinatorState.Recording or
            RecordingCoordinatorState.Stopping) ||
            (snapshot.State == RecordingCoordinatorState.Faulted && snapshot.NeedsNativeCleanup));

    private bool CanRefreshDevices => CanStart;

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
            // RecordingCoordinator captures the current SynchronizationContext, so it must
            // be created from this WinUI thread rather than a background continuation.
            nativeBridge = new NativeRecorderBridge();
            coordinator = new RecordingCoordinator(nativeBridge);
            coordinator.SnapshotChanged += OnSnapshotChanged;
            isRecorderAvailable = true;
            await RefreshEndpointsCoreAsync();
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
        UpdateCommandStates();

        var activeCoordinator = coordinator;
        if (activeCoordinator is not null)
        {
            try
            {
                await activeCoordinator.StopAsync();
            }
            catch
            {
                // The process is exiting. Dispose only after the coordinator had a chance to stop.
            }
            finally
            {
                activeCoordinator.SnapshotChanged -= OnSnapshotChanged;
            }
        }

        coordinator = null;
        nativeBridge?.Dispose();
        nativeBridge = null;
        isRecorderAvailable = false;
    }

    private Task StartAsync() => RunOperationAsync(async () =>
    {
        var outputPath = CreateOutputPath();
        NextOutputPath = outputPath;
        ErrorText = null;
        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        OnPropertyChanged(nameof(ElapsedText));

        var result = await GetCoordinator().StartAsync(new NativeRecordingRequest(
            RecordingCaptureMode.SystemLoopback,
            outputPath,
            SelectedEndpoint?.EndpointId));
        ApplySnapshot(result);
    });

    private Task StartTestAsync() => RunOperationAsync(async () =>
    {
        var outputPath = CreateOutputPath();
        NextOutputPath = outputPath;
        ErrorText = null;
        recordingStartedAt = DateTimeOffset.Now;
        elapsed = TimeSpan.Zero;
        OnPropertyChanged(nameof(ElapsedText));

        var result = await GetCoordinator().StartTestAsync(
            new NativeRecordingRequest(
                RecordingCaptureMode.SystemLoopback,
                outputPath,
                SelectedEndpoint?.EndpointId),
            TimeSpan.FromSeconds(10));
        ApplySnapshot(result);
    });

    private Task StopAsync() => RunOperationAsync(async () =>
    {
        var result = await GetCoordinator().StopAsync();
        ApplySnapshot(result);
    });

    private Task RefreshEndpointsAsync() => RunOperationAsync(RefreshEndpointsCoreAsync);

    private async Task RefreshEndpointsCoreAsync()
    {
        var activeCoordinator = GetCoordinator();
        var result = await activeCoordinator.RefreshEndpointsAsync();
        if (!result.IsSuccess)
        {
            ErrorText = result.Operation.Error ?? "無法取得 Windows 的輸出裝置。";
            return;
        }

        var currentEndpointId = SelectedEndpoint?.EndpointId;
        Endpoints.Clear();
        Endpoints.Add(EndpointChoice.SystemDefault);

        foreach (var endpoint in result.Endpoints
                     .Where(endpoint => endpoint.Flow == CaptureEndpointFlow.Render)
                     .OrderBy(GetEndpointRank)
                     .ThenBy(endpoint => endpoint.FriendlyName, StringComparer.CurrentCultureIgnoreCase))
        {
            var name = string.IsNullOrWhiteSpace(endpoint.FriendlyName)
                ? "未命名輸出裝置"
                : endpoint.FriendlyName;
            Endpoints.Add(new EndpointChoice(endpoint.EndpointId, name, endpoint.DefaultRoles));
        }

        SelectedEndpoint = FindEndpoint(currentEndpointId) ?? EndpointChoice.SystemDefault;
        if (Endpoints.Count == 1)
        {
            ErrorText = "沒有可列出的輸出裝置；仍可嘗試使用 Windows 的系統預設裝置。";
        }
        else if (snapshot.Error is null)
        {
            ErrorText = null;
        }
    }

    private async void OnTelemetryTimerTick(DispatcherQueueTimer sender, object args)
    {
        await RefreshTelemetryAsync();
    }

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
            var result = await coordinator.RefreshAsync();
            ApplySnapshot(result);
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

    private void OnSnapshotChanged(object? sender, RecordingCoordinatorSnapshot changedSnapshot)
    {
        if (isShuttingDown)
        {
            return;
        }

        if (dispatcherQueue.HasThreadAccess)
        {
            ApplySnapshot(changedSnapshot);
            return;
        }

        _ = dispatcherQueue.TryEnqueue(() => ApplySnapshot(changedSnapshot));
    }

    private void ApplySnapshot(RecordingCoordinatorSnapshot changedSnapshot)
    {
        if (isShuttingDown)
        {
            return;
        }

        snapshot = changedSnapshot;
        RefreshElapsed();

        if (changedSnapshot.State == RecordingCoordinatorState.Recording)
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

        if (changedSnapshot.State is RecordingCoordinatorState.Stopped or
            RecordingCoordinatorState.Failed or
            RecordingCoordinatorState.Faulted)
        {
            recordingStartedAt = null;
        }

        StatusText = GetStatusText(changedSnapshot);
        if (!string.IsNullOrWhiteSpace(changedSnapshot.Error))
        {
            ErrorText = changedSnapshot.Error;
        }
        else if (changedSnapshot.State is RecordingCoordinatorState.Ready or
                 RecordingCoordinatorState.Recording or
                 RecordingCoordinatorState.Stopped)
        {
            ErrorText = null;
        }

        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(PeakPercent));
        OnPropertyChanged(nameof(PeakText));
        OnPropertyChanged(nameof(PacketText));
        OnPropertyChanged(nameof(SourceHealthText));
        UpdateCommandStates();
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
            ErrorText = $"{exception.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private RecordingCoordinator GetCoordinator() =>
        coordinator ?? throw new InvalidOperationException("錄音元件尚未準備完成。");

    private string CreateOutputPath()
    {
        var folder = OutputFolder.Trim();
        if (string.IsNullOrWhiteSpace(folder))
        {
            throw new InvalidOperationException("請先輸入 WAV 輸出資料夾。");
        }

        Directory.CreateDirectory(folder);
        var timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        for (var suffix = 0; suffix < 100; suffix++)
        {
            var name = suffix == 0
                ? $"recording-{timestamp}.wav"
                : $"recording-{timestamp}-{suffix:D2}.wav";
            var candidate = Path.Combine(folder, name);
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new IOException("無法建立不會覆寫既有錄音的檔名。");
    }

    private EndpointChoice? FindEndpoint(string? endpointId)
    {
        if (string.IsNullOrEmpty(endpointId))
        {
            return EndpointChoice.SystemDefault;
        }

        foreach (var endpoint in Endpoints)
        {
            if (string.Equals(endpoint.EndpointId, endpointId, StringComparison.Ordinal))
            {
                return endpoint;
            }
        }

        return null;
    }

    private static int GetEndpointRank(NativeCaptureEndpoint endpoint)
    {
        if (endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Console))
        {
            return 0;
        }

        if (endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Multimedia))
        {
            return 1;
        }

        return endpoint.DefaultRoles.HasFlag(EndpointDefaultRole.Communications) ? 2 : 3;
    }

    private void RefreshElapsed()
    {
        if (recordingStartedAt is not { } startedAt)
        {
            return;
        }

        elapsed = DateTimeOffset.Now - startedAt;
        OnPropertyChanged(nameof(ElapsedText));
    }

    private void UpdateCommandStates()
    {
        StartCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        StartTestCommand.RaiseCanExecuteChanged();
        RefreshDevicesCommand.RaiseCanExecuteChanged();
        OnPropertyChanged(nameof(IsDeviceSelectionEnabled));
    }

    private static string GetStatusText(RecordingCoordinatorSnapshot changedSnapshot) =>
        changedSnapshot.State switch
        {
            RecordingCoordinatorState.Ready => "準備就緒",
            RecordingCoordinatorState.Starting => "正在開始錄音…",
            RecordingCoordinatorState.Recording when changedSnapshot.IsTestRecording => "10 秒測試錄音中",
            RecordingCoordinatorState.Recording => "錄音中",
            RecordingCoordinatorState.Stopping => "正在停止並寫入 WAV…",
            RecordingCoordinatorState.Stopped => "已停止並儲存 WAV",
            RecordingCoordinatorState.Failed => "無法開始錄音",
            RecordingCoordinatorState.Faulted when changedSnapshot.NeedsNativeCleanup => "錄音異常，正在等待清理",
            RecordingCoordinatorState.Faulted => "錄音異常，請重新啟動 App",
            _ => "未知狀態",
        };

    private static string CreateInitializationError(Exception exception) => exception switch
    {
        DllNotFoundException => $"無法載入原生錄音 DLL。請建立 x64 Release 版本後重新啟動 App。詳細資料：{exception.Message}",
        BadImageFormatException => $"原生錄音 DLL 的架構不符合 x64 App。請使用 x64 Release 版本。詳細資料：{exception.Message}",
        NativeRecorderInteropException => $"原生錄音元件版本不相容。詳細資料：{exception.Message}",
        _ => $"無法初始化原生錄音元件。詳細資料：{exception.Message}",
    };

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
    EndpointDefaultRole DefaultRoles)
{
    public static EndpointChoice SystemDefault { get; } = new(
        EndpointId: null,
        DisplayName: "系統預設輸出裝置",
        DefaultRoles: EndpointDefaultRole.None);
}
