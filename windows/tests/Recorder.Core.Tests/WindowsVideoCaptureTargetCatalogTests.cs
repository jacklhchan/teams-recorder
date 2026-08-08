using Recorder.Core;
using TeamsRecorder.Windows.Application;

internal static class WindowsVideoCaptureTargetCatalogTests
{
    public static void OnlyOffersAdmittedTeamsWindows()
    {
        var valid = Candidate("ms-teams.exe", 0x1234, 101, "Meeting");
        var popOut = Candidate("ms-teams.exe", 0x5678, 101, "Shared content");
        var catalog = new WindowsVideoCaptureTargetCatalog(new FakeSnapshotProvider(
        [
            valid,
            popOut,
            Candidate("notepad.exe", 0x6789, 202, "Teams impostor"),
            valid with { IsCloaked = true, WindowHandle = (nint)0x9999 },
            valid with { IsHigherIntegrity = true, WindowHandle = (nint)0x8888 },
        ]));

        var targets = catalog.ListTargets();
        if (targets.Count != 2 || !targets.Any(target => target.WindowHandle == (nint)0x1234) ||
            !targets.Any(target => target.WindowHandle == (nint)0x5678))
        {
            throw new InvalidOperationException("The catalog did not enumerate exactly the admitted Teams top-level windows.");
        }
    }

    private static VideoCaptureTargetCandidate Candidate(string name, nint window, long created, string title) => new(
        42, window, created, name, title, true, true, false, false, false, 1280, 720);

    private sealed class FakeSnapshotProvider(IReadOnlyList<VideoCaptureTargetCandidate> candidates)
        : IVideoCaptureWindowSnapshotProvider
    {
        public IReadOnlyList<VideoCaptureTargetCandidate> ListCandidates() => candidates;
    }
}
