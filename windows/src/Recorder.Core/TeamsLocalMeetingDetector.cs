namespace Recorder.Core;

/// <summary>
/// The in-memory identity of a single top-level Teams window.  A PID or HWND
/// on its own is not an identity: Windows can reuse both after a process exits.
/// This value is deliberately runtime-only and must never be written to session
/// metadata, diagnostics, telemetry, or an IPC payload.
/// </summary>
public readonly record struct TeamsWindowIdentity(
    int ProcessId,
    nint WindowHandle,
    long ProcessCreationTimeFileTimeUtc)
{
    public bool IsWellFormed => ProcessId > 0 && WindowHandle != nint.Zero &&
                                 ProcessCreationTimeFileTimeUtc > 0;
}

/// <summary>
/// A previously admitted Teams meeting surface.  It intentionally carries no
/// title, executable path, account, meeting subject, or other user content.
/// </summary>
public sealed record TeamsLocalMeetingWindow(TeamsWindowIdentity Identity)
{
    public bool IsWellFormed => Identity.IsWellFormed;
}

public enum TeamsLocalMeetingObservationKind
{
    /// <summary>The window inventory completed; an empty list is a known absence.</summary>
    Complete,
    /// <summary>The platform could not produce a trustworthy inventory.</summary>
    Unavailable,
    /// <summary>More than one (or otherwise malformed) candidate was observed.</summary>
    Ambiguous,
}

/// <summary>
/// A bounded, privacy-safe input to the local meeting reducer.  At most 32
/// admitted surfaces are represented.  The detector treats an overflow as
/// ambiguous rather than selecting a possibly unrelated window.
/// </summary>
public sealed record TeamsLocalMeetingObservation
{
    public const int MaximumCandidateCount = 32;

    private TeamsLocalMeetingObservation(
        TeamsLocalMeetingObservationKind kind,
        IReadOnlyList<TeamsLocalMeetingWindow> candidates)
    {
        Kind = kind;
        Candidates = candidates;
    }

    public TeamsLocalMeetingObservationKind Kind { get; }
    public IReadOnlyList<TeamsLocalMeetingWindow> Candidates { get; }

    public static TeamsLocalMeetingObservation Unavailable { get; } =
        new(TeamsLocalMeetingObservationKind.Unavailable, Array.Empty<TeamsLocalMeetingWindow>());

    public static TeamsLocalMeetingObservation Ambiguous { get; } =
        new(TeamsLocalMeetingObservationKind.Ambiguous, Array.Empty<TeamsLocalMeetingWindow>());

    public static TeamsLocalMeetingObservation Complete(
        IEnumerable<TeamsLocalMeetingWindow> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);

        var distinct = new List<TeamsLocalMeetingWindow>();
        var identities = new HashSet<TeamsWindowIdentity>();
        foreach (var candidate in candidates)
        {
            if (candidate is null || !candidate.IsWellFormed)
            {
                // Do not discard malformed native input and then mistake the
                // remainder for a confirmed meeting.
                return Ambiguous;
            }

            if (!identities.Add(candidate.Identity))
            {
                continue;
            }

            distinct.Add(candidate);
            if (distinct.Count > MaximumCandidateCount)
            {
                return Ambiguous;
            }
        }

        return new TeamsLocalMeetingObservation(
            TeamsLocalMeetingObservationKind.Complete,
            distinct.ToArray());
    }
}

public enum TeamsLocalMeetingDetectionState
{
    Waiting,
    Confirming,
    Detected,
    Ending,
    Ambiguous,
    Unavailable,
}

/// <summary>
/// The public projection intentionally has no HWND, PID, title, account,
/// token, path, or exception text.  It is safe to bind to UI and IPC status.
/// </summary>
public sealed record TeamsLocalMeetingDetectionSnapshot(
    TeamsLocalMeetingDetectionState State,
    bool IsMeetingPresent,
    int ObservationsRemaining)
{
    public static TeamsLocalMeetingDetectionSnapshot Initial { get; } =
        new(TeamsLocalMeetingDetectionState.Waiting, false, 0);
}

/// <summary>
/// A transition is present only when a debounced, identity-validated meeting
/// state changed.  Repeated WinEvent notifications therefore cannot start or
/// stop automatic recording more than once.
/// </summary>
public sealed record TeamsLocalMeetingDetectionUpdate(
    TeamsLocalMeetingDetectionSnapshot Snapshot,
    bool? MeetingPresenceChanged);

public sealed record TeamsLocalMeetingDetectorOptions
{
    public int ConfirmObservations { get; init; } = 3;
    public int EndObservations { get; init; } = 15;
    public TimeSpan MinimumObservationSpacing { get; init; } = TimeSpan.FromMilliseconds(750);

    public void Validate()
    {
        if (ConfirmObservations is < 1 or > 60)
        {
            throw new ArgumentOutOfRangeException(nameof(ConfirmObservations));
        }

        if (EndObservations is < 1 or > 60)
        {
            throw new ArgumentOutOfRangeException(nameof(EndObservations));
        }

        if (MinimumObservationSpacing < TimeSpan.Zero ||
            MinimumObservationSpacing > TimeSpan.FromSeconds(10))
        {
            throw new ArgumentOutOfRangeException(nameof(MinimumObservationSpacing));
        }
    }
}

/// <summary>
/// Pure, testable meeting-presence reducer.  It accepts only an already
/// admitted Teams top-level window identity.  A PID/HWND reuse changes the
/// complete identity and immediately ends the old meeting before a replacement
/// may earn a new confirmation sequence.
/// </summary>
public sealed class TeamsLocalMeetingDetector
{
    private readonly TeamsLocalMeetingDetectorOptions options;
    private TeamsWindowIdentity? confirmingIdentity;
    private TeamsWindowIdentity? detectedIdentity;
    private int confirmationCount;
    private int missingCount;
    private DateTimeOffset? lastAcceptedObservationAt;
    private TeamsLocalMeetingDetectionSnapshot snapshot = TeamsLocalMeetingDetectionSnapshot.Initial;

    public TeamsLocalMeetingDetector(TeamsLocalMeetingDetectorOptions? options = null)
    {
        this.options = options ?? new TeamsLocalMeetingDetectorOptions();
        this.options.Validate();
    }

    public TeamsLocalMeetingDetectionSnapshot Snapshot => snapshot;

    /// <summary>
    /// Runtime-only access for a caller that must perform a one-shot UIA action.
    /// Do not persist this value or expose it from public status payloads.
    /// </summary>
    public TeamsWindowIdentity? ActiveIdentity => detectedIdentity;

    public TeamsLocalMeetingDetectionUpdate Observe(
        TeamsLocalMeetingObservation observation,
        DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(observation);

        // An identity disappearance/replacement is safety-critical.  It bypasses
        // the spacing gate so PID/HWND reuse cannot keep a prior meeting active.
        var urgentIdentityLoss = detectedIdentity is { } active &&
            observation.Kind == TeamsLocalMeetingObservationKind.Complete &&
            !observation.Candidates.Any(candidate => candidate.Identity == active);

        if (!urgentIdentityLoss && IsJitter(now))
        {
            return new(snapshot, null);
        }

        lastAcceptedObservationAt = now;
        return observation.Kind switch
        {
            TeamsLocalMeetingObservationKind.Unavailable => ObserveUnavailable(),
            TeamsLocalMeetingObservationKind.Ambiguous => ObserveAmbiguous(),
            TeamsLocalMeetingObservationKind.Complete => ObserveComplete(observation.Candidates),
            _ => new(snapshot, null),
        };
    }

    /// <summary>
    /// Clears local-only state.  It emits a false transition when necessary so a
    /// host can stop its automatic-recording countdown without trusting a stale
    /// Teams identity.
    /// </summary>
    public TeamsLocalMeetingDetectionUpdate Reset()
    {
        var wasDetected = detectedIdentity is not null;
        confirmingIdentity = null;
        detectedIdentity = null;
        confirmationCount = 0;
        missingCount = 0;
        lastAcceptedObservationAt = null;
        snapshot = TeamsLocalMeetingDetectionSnapshot.Initial;
        return new(snapshot, wasDetected ? false : null);
    }

    private TeamsLocalMeetingDetectionUpdate ObserveUnavailable()
    {
        // A transient WinEvent/UIA/inventory failure is not evidence that a
        // meeting ended.  Preserve the prior presence, but never create one.
        snapshot = new TeamsLocalMeetingDetectionSnapshot(
            TeamsLocalMeetingDetectionState.Unavailable,
            detectedIdentity is not null,
            0);
        return new(snapshot, null);
    }

    private TeamsLocalMeetingDetectionUpdate ObserveAmbiguous()
    {
        if (detectedIdentity is not null)
        {
            // We cannot prove the former identity still exists.  Do not let an
            // ambiguous collection inherit the old meeting's authority.
            return EndForIdentityLoss(TeamsLocalMeetingDetectionState.Ambiguous);
        }

        confirmingIdentity = null;
        confirmationCount = 0;
        missingCount = 0;
        snapshot = new TeamsLocalMeetingDetectionSnapshot(
            TeamsLocalMeetingDetectionState.Ambiguous,
            false,
            0);
        return new(snapshot, null);
    }

    private TeamsLocalMeetingDetectionUpdate ObserveComplete(
        IReadOnlyList<TeamsLocalMeetingWindow> candidates)
    {
        if (candidates.Count > 1)
        {
            return ObserveAmbiguous();
        }

        if (detectedIdentity is { } active)
        {
            if (candidates.Count == 1 && candidates[0].Identity == active)
            {
                missingCount = 0;
                snapshot = new TeamsLocalMeetingDetectionSnapshot(
                    TeamsLocalMeetingDetectionState.Detected,
                    true,
                    0);
                return new(snapshot, null);
            }

            if (candidates.Count == 1)
            {
                // A valid but different identity is a hard boundary.  Seed the
                // new candidate, but emit the old meeting's end first.
                var replacement = candidates[0].Identity;
                detectedIdentity = null;
                missingCount = 0;
                confirmingIdentity = replacement;
                confirmationCount = 1;
                snapshot = new TeamsLocalMeetingDetectionSnapshot(
                    TeamsLocalMeetingDetectionState.Confirming,
                    false,
                    options.ConfirmObservations - confirmationCount);
                return new(snapshot, false);
            }

            missingCount++;
            if (missingCount >= options.EndObservations)
            {
                return EndForIdentityLoss(TeamsLocalMeetingDetectionState.Waiting);
            }

            snapshot = new TeamsLocalMeetingDetectionSnapshot(
                TeamsLocalMeetingDetectionState.Ending,
                true,
                options.EndObservations - missingCount);
            return new(snapshot, null);
        }

        if (candidates.Count == 0)
        {
            confirmingIdentity = null;
            confirmationCount = 0;
            missingCount = 0;
            snapshot = TeamsLocalMeetingDetectionSnapshot.Initial;
            return new(snapshot, null);
        }

        var candidate = candidates[0].Identity;
        if (confirmingIdentity == candidate)
        {
            confirmationCount++;
        }
        else
        {
            confirmingIdentity = candidate;
            confirmationCount = 1;
        }

        if (confirmationCount < options.ConfirmObservations)
        {
            snapshot = new TeamsLocalMeetingDetectionSnapshot(
                TeamsLocalMeetingDetectionState.Confirming,
                false,
                options.ConfirmObservations - confirmationCount);
            return new(snapshot, null);
        }

        detectedIdentity = candidate;
        confirmingIdentity = null;
        confirmationCount = 0;
        missingCount = 0;
        snapshot = new TeamsLocalMeetingDetectionSnapshot(
            TeamsLocalMeetingDetectionState.Detected,
            true,
            0);
        return new(snapshot, true);
    }

    private TeamsLocalMeetingDetectionUpdate EndForIdentityLoss(
        TeamsLocalMeetingDetectionState nextState)
    {
        detectedIdentity = null;
        confirmingIdentity = null;
        confirmationCount = 0;
        missingCount = 0;
        snapshot = nextState switch
        {
            TeamsLocalMeetingDetectionState.Waiting => TeamsLocalMeetingDetectionSnapshot.Initial,
            _ => new TeamsLocalMeetingDetectionSnapshot(nextState, false, 0),
        };
        return new(snapshot, false);
    }

    private bool IsJitter(DateTimeOffset now) =>
        lastAcceptedObservationAt is { } previous &&
        now >= previous &&
        now - previous < options.MinimumObservationSpacing;
}
