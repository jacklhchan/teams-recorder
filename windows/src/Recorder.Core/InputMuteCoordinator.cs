namespace Recorder.Core;

/// <summary>Combines independent local and hardware/input mute causes without toggling state.</summary>
public sealed class InputMuteCoordinator
{
    private readonly object gate = new();
    private bool localMuted;
    private bool inputMuted;

    public bool IsMuted { get { lock (gate) return localMuted || inputMuted; } }
    public bool IsLocalMuted { get { lock (gate) return localMuted; } }
    public bool IsInputMuted { get { lock (gate) return inputMuted; } }
    public event Action<bool>? Changed;

    public void SetLocalMuted(bool muted) => Set(ref localMuted, muted);
    public void SetInputMuted(bool muted) => Set(ref inputMuted, muted);

    private void Set(ref bool target, bool value)
    {
        bool? changed = null;
        lock (gate)
        {
            var before = localMuted || inputMuted;
            target = value;
            var after = localMuted || inputMuted;
            if (before != after) changed = after;
        }
        if (changed is { } muted) Changed?.Invoke(muted);
    }
}

/// <summary>Platform adapter for one registered global shortcut. Implementations must unregister on Dispose.</summary>
public interface IGlobalHotKeyRegistration : IDisposable
{
    event EventHandler? Pressed;
}

public interface IGlobalHotKeyRegistrar
{
    IGlobalHotKeyRegistration RegisterCtrlAltM();
}

/// <summary>Owns Ctrl+Alt+M registration and maps it to an explicit local-mute state update.</summary>
public sealed class GlobalMuteHotKeyService : IDisposable
{
    private readonly InputMuteCoordinator mute;
    private readonly IGlobalHotKeyRegistration registration;
    private bool disposed;
    public GlobalMuteHotKeyService(InputMuteCoordinator mute, IGlobalHotKeyRegistrar registrar)
    {
        this.mute = mute ?? throw new ArgumentNullException(nameof(mute));
        registration = (registrar ?? throw new ArgumentNullException(nameof(registrar))).RegisterCtrlAltM();
        registration.Pressed += OnPressed;
    }
    private void OnPressed(object? sender, EventArgs args) => mute.SetLocalMuted(!mute.IsLocalMuted);
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        registration.Pressed -= OnPressed;
        registration.Dispose();
    }
}
