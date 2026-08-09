namespace TeamsRecorder.Windows.Application.VirtualMic;

/// <summary>
/// Compile-time safety gate for the optional, test-signed virtual microphone.
/// A Release binary has no supported path to turn the preview on at runtime.
/// </summary>
public static class VirtualMicPreviewBuildPolicy
{
    // This is intentionally a property rather than a const: a Release build
    // must compile the unreachable guarded implementation for testability,
    // while still returning false at every runtime call site.
    public static bool IsTestSignedPreviewCompiled
    {
        get
        {
#if TEAMSRECORDER_TESTSIGNED_VIRTUAL_MIC
            return true;
#else
            return false;
#endif
        }
    }

    public const string ReleaseDisabledReason =
        "The test-signed virtual microphone preview is not compiled into this build.";
}

/// <summary>Immutable identifiers shared by the INF, broker and app pairing.</summary>
public static class VirtualMicPreviewIdentity
{
    public const string HardwareId = "ROOT\\TeamsRecorderVirtualMic";
    public const string ServiceName = "TeamsRecorderVirtualMic";
    public const string FriendlyName = VirtualMicCapabilityDetector.StableFriendlyName;
}

/// <summary>
/// A post-install pairing. The endpoint ID is intentionally supplied as an
/// exact value because Windows assigns it at installation time; friendly names
/// are display metadata and never a standalone trust signal.
/// </summary>
public sealed record VirtualMicTrustedEndpointIdentity(
    string EndpointId,
    string HardwareId,
    string FriendlyName)
{
    public bool HasExpectedStaticIdentity =>
        string.Equals(HardwareId, VirtualMicPreviewIdentity.HardwareId, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(FriendlyName, VirtualMicPreviewIdentity.FriendlyName, StringComparison.Ordinal);

    public bool IsWellFormed =>
        !string.IsNullOrWhiteSpace(EndpointId) &&
        EndpointId.Length <= 1_024 &&
        EndpointId.IndexOf('\0') < 0 &&
        HasExpectedStaticIdentity;
}

public enum VirtualMicPreviewCapabilityState
{
    Disabled,
    IdentityRejected,
    EndpointUnavailable,
    Available,
}

public sealed record VirtualMicPreviewCapability(
    VirtualMicPreviewCapabilityState State,
    string? EndpointId,
    string Reason)
{
    public bool IsAvailable => State == VirtualMicPreviewCapabilityState.Available;
}

/// <summary>
/// App-side handshake before any PCM broker is opened. The detector is kept
/// separate from recorder lifecycle/UI plumbing so an eventual adapter cannot
/// accidentally convert a preview capability into a default microphone.
/// </summary>
public static class VirtualMicPreviewHandshake
{
    public static VirtualMicPreviewCapability Evaluate(
        VirtualMicTrustedEndpointIdentity? trustedIdentity,
        IReadOnlyList<NativeCaptureEndpoint>? endpoints)
    {
        if (!VirtualMicPreviewBuildPolicy.IsTestSignedPreviewCompiled)
        {
            return new(
                VirtualMicPreviewCapabilityState.Disabled,
                null,
                VirtualMicPreviewBuildPolicy.ReleaseDisabledReason);
        }

        if (trustedIdentity is null || !trustedIdentity.IsWellFormed)
        {
            return new(
                VirtualMicPreviewCapabilityState.IdentityRejected,
                null,
                "The virtual microphone pairing does not match the expected driver identity; integration remains disabled.");
        }

        var endpointCapability = VirtualMicCapabilityDetector.Detect(endpoints!, trustedIdentity.EndpointId);
        if (!endpointCapability.IsAvailable)
        {
            return new(
                VirtualMicPreviewCapabilityState.EndpointUnavailable,
                null,
                endpointCapability.Reason);
        }

        return new(
            VirtualMicPreviewCapabilityState.Available,
            endpointCapability.EndpointId,
            "Trusted test virtual microphone endpoint is available.");
    }

    /// <summary>
    /// Opens the current-user PCM broker only after the same exact paired
    /// endpoint passed the capability check. This method deliberately does not
    /// start a recorder, change a default device, or fall back to another mic.
    /// </summary>
    public static Task<VirtualMicPcmBrokerConnection> ConnectBrokerAsync(
        VirtualMicPreviewCapability capability,
        VirtualMicPcmBrokerSession session,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(capability);
        ArgumentNullException.ThrowIfNull(session);
        if (!capability.IsAvailable || string.IsNullOrEmpty(capability.EndpointId) ||
            !string.Equals(capability.EndpointId, session.Identity.EndpointId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Virtual microphone broker connection requires an available exact endpoint pairing.");
        }

        return VirtualMicPcmBrokerClient.ConnectAsync(session, timeout, cancellationToken);
    }
}
