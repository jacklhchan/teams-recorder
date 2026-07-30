using Recorder.Core;

internal static class InputMuteTests
{
    public static void IndependentMuteCausesOnlyPublishEffectiveTransitions()
    {
        var coordinator = new InputMuteCoordinator();
        var transitions = new List<bool>();
        coordinator.Changed += transitions.Add;

        coordinator.SetInputMuted(true);
        coordinator.SetLocalMuted(true);
        coordinator.SetInputMuted(false);
        coordinator.SetLocalMuted(false);

        if (!transitions.SequenceEqual([true, false]))
            throw new InvalidOperationException("Independent mute causes should only publish changes to the effective state.");
    }

    public static void HotKeyTogglesLocalMuteWithoutClearingInputMute()
    {
        var coordinator = new InputMuteCoordinator();
        coordinator.SetInputMuted(true);
        var registrar = new FakeRegistrar();
        var service = new GlobalMuteHotKeyService(coordinator, registrar);

        registrar.Registration.Raise();
        if (!coordinator.IsLocalMuted || !coordinator.IsInputMuted || !coordinator.IsMuted)
            throw new InvalidOperationException("The hotkey must set local mute without clearing input mute.");

        coordinator.SetInputMuted(false);
        if (!coordinator.IsMuted)
            throw new InvalidOperationException("Local mute should keep the microphone muted after input mute clears.");

        registrar.Registration.Raise();
        if (coordinator.IsMuted || coordinator.IsLocalMuted)
            throw new InvalidOperationException("The second hotkey press should clear only local mute.");

        service.Dispose();
        if (!registrar.Registration.IsDisposed)
            throw new InvalidOperationException("Hotkey registration was not disposed.");
    }

    private sealed class FakeRegistrar : IGlobalHotKeyRegistrar
    {
        public FakeRegistration Registration { get; } = new();
        public IGlobalHotKeyRegistration RegisterCtrlAltM() => Registration;
    }

    private sealed class FakeRegistration : IGlobalHotKeyRegistration
    {
        public event EventHandler? Pressed;
        public bool IsDisposed { get; private set; }
        public void Raise() => Pressed?.Invoke(this, EventArgs.Empty);
        public void Dispose() => IsDisposed = true;
    }
}
