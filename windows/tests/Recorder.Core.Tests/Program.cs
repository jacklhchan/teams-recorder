using Recorder.Core;
using TeamsRecorder.Windows.Application;

var tests = new (string Name, Action Run)[]
{
    ("storage policy uses exact thresholds", StoragePolicyUsesExactThresholds),
    ("meeting starts after countdown", MeetingStartsAfterCountdown),
    ("manual recording suppresses Teams until end", ManualRecordingSuppressesTeamsUntilEnd),
    ("meeting rejoin cancels stop debounce", MeetingRejoinCancelsStopDebounce),
    ("suppression during stop debounce survives a transient rejoin", SuppressionDuringStopDebounceSurvivesRejoin),
    ("explicit user stop releases automatic recording ownership", ExplicitUserStopReleasesAutomaticOwnership),
    ("meeting end commits exactly one stop", MeetingEndCommitsOneStop),
    ("committed stop waits for completion before restarting", CommittedStopWaitsForCompletion),
    ("disabling automatic recording transfers ownership", DisableTransfersOwnership),
    ("disabling while starting cancels automatic start", DisableWhileStartingCancelsStart),
    ("manual start does not steal active automatic ownership", ManualStartDoesNotStealAutomaticOwnership),
    ("late completions are idempotent", LateCompletionsAreIdempotent),
    ("failed automatic start waits for meeting end", FailedStartWaitsForMeetingEnd),
    ("native recording coordinator starts, refreshes, and stops", NativeCoordinatorStartsRefreshesAndStops),
    ("native recording coordinator exposes copied endpoint snapshots", NativeCoordinatorExposesEndpointSnapshots),
    ("endpoint refresh keeps explicit device choices without fallback", EndpointRefreshRetainsExplicitDeviceChoices),
    ("native recording coordinator reports a failed start and allows retry", NativeCoordinatorReportsFailedStartAndAllowsRetry),
    ("failed native stop faults the coordinator and blocks retries", NativeCoordinatorFaultsAfterFailedStop),
    ("an in-recording native fault requests one cleanup stop", NativeCoordinatorRequestsCleanupAfterInRecordingFault),
    ("native recording coordinator does not publish a late start after stop", NativeCoordinatorSuppressesLateStartAfterStop),
    ("test recording stops exactly once after its scheduled delay", TestRecordingStopsExactlyOnce)
    ,("recording start request validates sources and optional microphone endpoints", RecordingStartRequestTests.ValidatesSystemAndSelectedProcessWithOptionalMicrophone)
    ,("recording start request rejects ambiguous source selections", RecordingStartRequestTests.RejectsAmbiguousOrIncompatibleSelections)
    ,("process capture selection requires its full current identity", RecordingStartRequestTests.SelectsProcessOnlyWhenItsFullIdentityIsCurrent)
    ,("process capture rejects PID reuse", RecordingStartRequestTests.RejectsPidReuseRatherThanCapturingTheWrongProcess)
    ,("process capture never falls back when selection is unavailable", RecordingStartRequestTests.DoesNotFallbackWhenSelectedProcessIsUnavailable)
    ,("source selection maps system and microphone modes without fallback", RecordingStartRequestTests.MapsSystemAndMicrophoneWithoutInventingEndpoints)
    ,("source selection preserves explicit system render endpoint", RecordingStartRequestTests.MapsSystemRenderEndpointThroughTheLegacyNativeRequest)
    ,("process targets and metadata share one executable-basename policy", RecordingStartRequestTests.UsesOneExecutableBasenamePolicyForProcessTargetsAndMetadata)
    ,("Teams capture defaults to recommended system loopback", CaptureSourceChoiceTests.DefaultsToRecommendedSystemLoopback)
    ,("process-loopback is preview and never silently changes source", CaptureSourceChoiceTests.MarksProcessLoopbackAsPreviewAndNeverSilentlyFallsBack)
    ,("Teams playback mismatch does not warn without an observation", TeamsPlaybackEndpointMismatchPolicyTests.DoesNotWarnWithoutAnIndependentTeamsObservation)
    ,("Teams playback mismatch warns for Windows default", TeamsPlaybackEndpointMismatchPolicyTests.WarnsWhenTeamsDiffersFromTheWindowsDefault)
    ,("Teams playback mismatch warns for an explicit endpoint", TeamsPlaybackEndpointMismatchPolicyTests.WarnsWhenTeamsDiffersFromAnExplicitSelection)
    ,("Teams playback mismatch ignores matching and process audio", TeamsPlaybackEndpointMismatchPolicyTests.DoesNotWarnForMatchingOrProcessAudioRequests)
    ,("Teams playback mismatch accepts any active Teams endpoint match", TeamsPlaybackEndpointMismatchPolicyTests.DoesNotWarnWhenAnyObservedTeamsEndpointMatches)
    ,("initial microphone selection prefers Windows communications default", MicrophoneDefaultSelectionPolicyTests.PrefersTheCommunicationsDefaultForInitialMicrophone)
    ,("initial microphone selection uses an available capture endpoint", MicrophoneDefaultSelectionPolicyTests.UsesAnyAvailableCaptureWhenWindowsHasNoDefaultRole)
    ,("initial microphone selection excludes render endpoints", MicrophoneDefaultSelectionPolicyTests.NeverSelectsRenderEndpointsAsMicrophones)
    ,("Teams picker excludes unrelated process windows", TeamsProcessCatalogPolicyTests.ExposesOnlyMicrosoftTeamsWithoutUsingWindowTitles)
    ,("Windows capture metadata round trips its approved envelope", MetadataPrivacyTests.WindowsCaptureMetadataRoundTripsTheApprovedEnvelope)
    ,("Windows capture metadata removes transient process identifiers", MetadataPrivacyTests.MetadataPrivacyDropsTransientProcessIdentifiers)
    ,("Windows executable basenames retain ordinary spaces and Unicode provenance", MetadataPrivacyTests.ExecutableBasenamesSupportOrdinarySpacesAndUnicodeWithoutDroppingProvenance)
    ,("mixed recording request validates its audio-only contract", AudioMvpTests.MixedRequestValidatesAudioOnlyContract)
    ,("mixed recording coordinator starts, stops, and retries", AudioMvpTests.MixedCoordinatorStartsStopsAndRetries)
    ,("mixed test recording stops after its scheduled delay", AudioMvpTests.MixedTestRecordingStopsAfterScheduledDelay)
    ,("recoverable mixed fault retains evidence and permits restart", AudioMvpTests.RecoverableFaultRetainsEvidenceAndAllowsRestart)
    ,("selected-audio test cancellation does not fall back or double-stop", AudioMvpTests.SelectedAudioTestCancelsWithoutFallbackOrDoubleStop)
    ,("selected-audio request rejects fallback-shaped options", AudioMvpTests.SelectedAudioRequestRejectsFallbackShapedOptions)
    ,("selected-audio test auto-stop publishes exactly once", SelectedAudioLifecycleTests.TestAutoStopPublishesExactlyOnce)
    ,("selected process disappearance fails closed and cleans empty state", SelectedAudioLifecycleTests.ProcessDisappearanceFailsClosedAndCleansOnlyEmptyFolder)
    ,("selected-audio fault retains recoverable backup", SelectedAudioLifecycleTests.RecoverableSelectedFaultKeepsAccumulatedBackup)
    ,("selected-audio fault cleanup permits a new recording and invalidates old generation", SelectedAudioLifecycleTests.FaultFinalizationAllowsRestartAndInvalidatesOldGeneration)
    ,("selected-audio relaunch recovery retains bounded capture provenance", SelectedAudioLifecycleTests.RelaunchRecoveryRetainsSelectedCaptureProvenance)
    ,("session capacity respects block and warning boundaries", SessionStorageTests.CapacityBoundariesAreExact)
    ,("session allocation and publishing do not overwrite media", SessionStorageTests.AllocationAndPublishDoNotOverwrite)
    ,("session library ignores unsafe and incomplete entries", SessionStorageTests.LibraryIgnoresUnsafeIncompleteAndMalformedEntries)
    ,("session recovery is idempotent and never clobbers", SessionStorageTests.RecoveryIsIdempotentAndNeverClobbers)
    ,("session storage blocks unavailable capacity", SessionStorageTests.CapacityUnavailableBlocksStart)
    ,("session metadata normalizes malformed optional fields", SessionStorageTests.MetadataNormalizesMalformedOptionalFields)
    ,("session metadata edits preserve media and unknown fields", SessionStorageTests.MetadataEditsPreserveMediaAndUnknownFields)
    ,("session recycle rejects foreign and incomplete folders", SessionStorageTests.RecycleRejectsForeignAndIncompleteFolders)
    ,("session folder names are whitelisted", SessionStorageTests.FolderNamesAreWhitelisted)
    ,("session allocation uses deterministic collision suffixes", SessionStorageTests.AllocatesDeterministicCollisionSuffix)
    ,("new Windows sessions write canonical source and participants", SessionStorageTests.NewSessionsWriteCanonicalSourceAndParticipants)
    ,("future session schema versions survive round trips", SessionStorageTests.FutureSchemaVersionSurvivesRoundTrip)
    ,("root recording-session fixture round trips through Windows metadata", SessionStorageTests.RootContractFixtureRoundTrips)
    ,("failed starts clean only empty owned session folders", SessionStorageTests.FailedStartCleanupOnlyRemovesEmptyOwnedFolder)
    ,("startup recovery promotes only complete partial M4A evidence", SessionStorageTests.RecoveryPromotesCompletePartialM4aOnly)
    ,("metadata publication failures retain retryable media", SessionStorageTests.MetadataFailuresRetainRetryableMedia)
    ,("recording library startup recovery and metadata edits round trip", RecordingLibraryServiceTests.StartupRecoveryRefreshesLibraryAndMetadataEditsRoundTrip)
    ,("recording library requires recycle confirmation and preserves failed-start evidence", RecordingLibraryServiceTests.RecycleRequiresConfirmationAndFailedStartCleanupPreservesEvidence)
    ,("recording library lists legacy root M4A files as playback-only", RecordingLibraryServiceTests.LegacyRootM4aFilesRemainDiscoverableAndPlaybackOnly)
    ,("video capture is gated until a frame pipeline is verified", VideoCaptureTests.FeatureGateFailsClosedUntilFramePipelineExists)
    ,("video capture target selection requires the same live window", VideoCaptureTests.TargetSelectionRequiresTheSameLiveWindow)
    ,("Teams protocol uses a local endpoint with pairing only", TeamsIntegrationTests.ProtocolUsesLocalEndpointAndPairingOnly)
    ,("Teams protocol rejects partial meeting state", TeamsIntegrationTests.ProtocolDecodesCompleteMeetingStateOnly)
    ,("Teams mute sync routes supported updates and fails closed", TeamsIntegrationTests.MuteCoordinatorUsesAbsoluteStateAndFailsClosed)
    ,("Teams mute sync ignores out-of-meeting mute state", TeamsIntegrationTests.MuteCoordinatorDoesNotChangeMicForOutOfMeetingState)
    ,("Teams mute sync rejects unauthenticated meeting state", TeamsIntegrationTests.MuteCoordinatorRejectsUnauthenticatedMeetingState)
    ,("Teams issued credential remains valid when pairing is available", TeamsIntegrationTests.MuteCoordinatorKeepsIssuedCredentialWhenTeamsOffersPairing)
    ,("Teams mute sync fails closed on API errors", TeamsIntegrationTests.MuteCoordinatorFailsClosedOnApiError)
    ,("Teams WebSocket client promotes pairing token without losing state", TeamsTransportTests.ClientPromotesTokenRefreshWithoutDroppingConnection)
    ,("Teams WebSocket client delivers authenticated push updates", TeamsTransportTests.ClientDeliversAuthenticatedPushUpdates)
    ,("Teams state-query rejection preserves later meeting pushes", TeamsTransportTests.StateQueryFailureDoesNotBlockLaterMeetingPush)
    ,("Teams WebSocket client fails closed after a remote close", TeamsTransportTests.ClientFailsClosedWhenRemoteSocketClosesDuringMeeting)
    ,("Teams WebSocket client drops events after stop", TeamsTransportTests.ClientDropsLateEventsAfterStop)
    ,("Teams WebSocket client bounds fragmented payloads", TeamsTransportTests.ClientClosesAndReconnectsAfterOversizedFragmentedPayload)
    ,("Teams WebSocket client clears an invalid pairing token", TeamsTransportTests.ClientClearsAnInvalidPairingTokenBeforeReconnecting)
    ,("Teams WebSocket client requests fresh pairing once", TeamsTransportTests.ClientRequestsPairingOnceForAnUncredentialedConnection)
    ,("Teams pairing requires an enabled, connected client", TeamsIntegrationTests.MuteCoordinatorOnlyReportsPairingAfterEnabledClientAcceptsIt)
    ,("Teams pairing only accepts already-paired after an explicit pair command", TeamsIntegrationTests.MuteCoordinatorOnlyTreatsAlreadyPairedAsAReplyToAnExplicitPairCommand)
    ,("live health is neutral before capture and healthy with signals", LiveAudioHealthAdvisorTests.ReportsNeutralBeforeCaptureAndHealthySignalsDuringCapture)
    ,("live health distinguishes silence, disconnect, and microphone mute", LiveAudioHealthAdvisorTests.WarnsOnSilentOrDisconnectedInputsButKeepsMutedMicNeutral)
    ,("live health reports a recovered signal after historical interruptions", LiveAudioHealthAdvisorTests.ReportsRecoveryAfterHistoricalInterruptionsWhenSignalsAreLive)
    ,("Windows global hotkey routes messages and unregisters once", WindowsGlobalHotKeyRegistrarTests.RoutesCtrlAltMAndUnregistersExactlyOnce)
    ,("Windows global hotkey reports unavailable registrations", WindowsGlobalHotKeyRegistrarTests.FailsWithWin32ErrorWhenCtrlAltMIsUnavailable)
    ,("input mute only publishes effective transitions", InputMuteTests.IndependentMuteCausesOnlyPublishEffectiveTransitions)
    ,("global mute hotkey preserves Teams input mute", InputMuteTests.HotKeyTogglesLocalMuteWithoutClearingInputMute)
    ,("virtual microphone accepts the trusted endpoint", VirtualMicCapabilityTests.TrustedCaptureEndpointIsAvailable)
    ,("virtual microphone rejects a missing trusted endpoint", VirtualMicCapabilityTests.MissingTrustedIdentityFailsClosed)
    ,("virtual microphone rejects an identity/name mismatch", VirtualMicCapabilityTests.MismatchedFriendlyNameForTrustedIdentityFailsClosed)
    ,("virtual microphone rejects a friendly-name spoof", VirtualMicCapabilityTests.FriendlyNameSpoofWithoutTrustedIdentityFailsClosed)
    ,("Teams automatic recorder starts and debounces stop", TeamsAutomaticRecordingControllerTests.StartsAfterCountdownAndStopsAfterDebounce)
    ,("Teams automatic recorder cleans up a late start", TeamsAutomaticRecordingControllerTests.CancelsLateAutomaticStartAndStopsLateCapture)
    ,("Teams automatic recorder permits snapshot reentry", TeamsAutomaticRecordingControllerTests.SnapshotHandlerCanSynchronouslyReenterWithoutDeadlock)
    ,("Teams automatic recorder safely disposes late work", TeamsAutomaticRecordingControllerTests.DisposeDoesNotWaitForAnUncooperativeStartAndStillStopsItLater)
    ,("Teams automatic recorder retries a blocked start only after meeting re-entry", TeamsAutomaticRecordingControllerTests.BlockedStartWaitsForMeetingEndBeforeRetrying)
    ,("Teams automatic recorder publishes each countdown snapshot", TeamsAutomaticRecordingControllerTests.PublishesEachCountdownSnapshot)
    ,("Teams automatic recorder suppresses a cancelled countdown until meeting end", TeamsAutomaticRecordingControllerTests.UserCancellationSuppressesUntilMeetingEndsThenAllowsReentry)
    ,("Teams automatic recorder does not restart after a manual stop in the same meeting", TeamsAutomaticRecordingControllerTests.ManualStopDuringAutomaticRecordingDoesNotRestartUntilMeetingReentry)
    ,("local diagnostic export is sanitized and includes capture choices", LocalDiagnosticLogTests.ExportsBoundedSanitizedCaptureDiagnostics)
    ,("local diagnostic export remains bounded", LocalDiagnosticLogTests.BoundsItsInMemoryExport)
    ,("public app choices survive restart without credentials", RecorderAppSettingsTests.RoundTripsPublicChoicesWithoutSecrets)
    ,("app settings preserve no-microphone and reject unsafe future data", RecorderAppSettingsTests.PreservesNoMicrophoneAndRejectsUnsafeFutureSettings)
    ,("OpenAI-compatible meeting summary sends consented JSON safely", OpenAiCompatibleMeetingSummaryClientTests.SendsOpenAiCompatibleJsonOnlyAfterConsent)
    ,("OpenAI-compatible meeting summary rejects unsafe requests before network", OpenAiCompatibleMeetingSummaryClientTests.RejectsConsentOversizeAndUnsafeProfileBeforeNetwork)
    ,("OpenAI-compatible meeting summary retries and bounds provider responses", OpenAiCompatibleMeetingSummaryClientTests.RetriesTransientFailureAndBoundsResponse)
    ,("OpenAI-compatible provider defaults and normalizes its profile", OpenAICompatibleProviderTests.DefaultsMatchOpenAiAndNormalizeVersionedBaseUrl)
    ,("OpenAI-compatible provider rejects unsafe URLs and future schemas", OpenAICompatibleProviderTests.ProfileRejectsInsecureOrSensitiveUrlsAndFutureSchema)
    ,("OpenAI-compatible provider keeps API key out of profile JSON", OpenAICompatibleProviderTests.RepositoryKeepsKeyOutOfProfileJsonAndSnapshotsItSeparately)
    ,("OpenAI-compatible provider discovers models with a request-scoped key", OpenAICompatibleProviderConnectionTests.DiscoversModelsAndKeepsAuthenticationRequestScoped)
    ,("OpenAI-compatible provider allows manual models and rejects unsafe failures", OpenAICompatibleProviderConnectionTests.AcceptsManualModelProvidersAndRejectsUnsafeFailures)
    ,("transcription artifacts publish atomically with bounded prior copies", TranscriptionArtifactTests.PublishesAtomicallyWithBoundedPreviousArtifacts)
    ,("transcription startup recovery marks in-progress work interrupted", TranscriptionArtifactTests.StartupRecoveryMarksOnlyInProgressStateInterrupted)
    ,("transcription publisher rejects foreign artifact folders", TranscriptionArtifactTests.RefusesForeignOrReparseArtifactLocation)
    ,("meeting summary publishes only owned consented transcripts safely", MeetingSummaryArtifactTests.CoordinatorReadsOnlyOwnedTranscriptAndPublishesBoundedArtifacts)
    ,("meeting summary requires consent and owned session folders", MeetingSummaryArtifactTests.CoordinatorRequiresConsentAndRefusesForeignSessions)
    ,("meeting summary retains redacted failure state", MeetingSummaryArtifactTests.CoordinatorKeepsSafeFailureState)
    ,("OpenAI-compatible ASR uses the multipart contract and bearer key", OpenAICompatibleAsrClientTests.UsesOpenAiMultipartContractAndBearerKey)
    ,("OpenAI-compatible ASR falls back to JSON when verbose JSON is rejected", OpenAICompatibleAsrClientTests.FallsBackToJsonOnlyForUnsupportedVerboseJson)
    ,("OpenAI-compatible ASR retries transient responses", OpenAICompatibleAsrClientTests.RetriesTransientResponsesWithRetryAfter)
    ,("OpenAI-compatible ASR bounds data and honors cancellation", OpenAICompatibleAsrClientTests.BoundsAudioAndResponseAndHonorsCancellation)
    ,("OpenAI-compatible ASR rejects bad authentication and responses", OpenAICompatibleAsrClientTests.DoesNotRetryAuthenticationOrAcceptInvalidPayload)
    ,("OpenAI-compatible ASR uses the shared provider snapshot", OpenAICompatibleAsrClientTests.UsesTheSharedProviderSnapshotWithoutPersistingItsKey)
    ,("post-recording ASR requires opt-in and publishes a completed M4A transcript", RecordingSessionAsrJobCoordinatorTests.TranscribesOnlyAnExplicitCompletedSessionAndPublishesArtifacts)
    ,("post-recording ASR rejects partial, foreign, and oversized media before upload", RecordingSessionAsrJobCoordinatorTests.RejectsPartialForeignAndOversizedMediaWithoutUploading)
    ,("post-recording ASR serializes jobs and retains terminal cancellation or failure", RecordingSessionAsrJobCoordinatorTests.EnforcesOneJobAndRecordsCancellationOrProviderFailure)
};

var failed = 0;
foreach (var (name, run) in tests)
{
    try { run(); Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {name}: {error.Message}"); }
}
return failed == 0 ? 0 : 1;

static void StoragePolicyUsesExactThresholds()
{
    var policy = new RecordingStoragePolicy();
    Equal(RecordingStorageDecision.Normal, policy.Decide(RecordingStoragePolicy.WarningBytes));
    Equal(RecordingStorageDecision.Warn, policy.Decide(RecordingStoragePolicy.WarningBytes - 1));
    Equal(RecordingStorageDecision.AudioOnly, policy.Decide(RecordingStoragePolicy.VideoMinimumBytes - 1));
    Equal(RecordingStorageDecision.Stop, policy.Decide(RecordingStoragePolicy.DefaultAudioStopBytes - 1));
}

static void MeetingStartsAfterCountdown()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 2);
    var snapshot = EnableAndEnterMeeting(machine);
    Equal(new TeamsAutoMeetingState.StartCountdown(2), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked());
    Equal(new TeamsAutoMeetingState.Starting(), transition.Snapshot.State);
    Commands(transition, new TeamsAutoMeetingCommand.StartAutomaticRecording());
    snapshot = machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.AutomaticStartSucceeded()).Snapshot;
    Equal(RecordingOwner.TeamsAutomatic, snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.AutomaticRecording(), snapshot.State);
}

static void ManualRecordingSuppressesTeamsUntilEnd()
{
    var machine = new TeamsAutoMeetingMachine();
    var snapshot = EnableAndEnterMeeting(machine);
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.ManualRecordingStarted());
    Equal(RecordingOwner.Manual, transition.Snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), transition.Snapshot.State);
    snapshot = machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.StartCountdown(5), snapshot.State);
}

static void MeetingRejoinCancelsStopDebounce()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    Equal(new TeamsAutoMeetingState.StopCountdown(1), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.AutomaticRecording(), snapshot.State);
}

static void MeetingEndCommitsOneStop()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked());
    Commands(transition, new TeamsAutoMeetingCommand.StopAutomaticRecording());
    Equal(new TeamsAutoMeetingState.Stopping(), transition.Snapshot.State);
    Equal(0, machine.Reduce(transition.Snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Commands.Count);
}

static void SuppressionDuringStopDebounceSurvivesRejoin()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 2);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.SuppressUntilMeetingEnd()).Snapshot;
    Equal(new TeamsAutoMeetingState.StopCountdown(2), snapshot.State);
    if (!snapshot.SuppressesStopUntilEndDebounce) throw new InvalidOperationException("Expected deferred suppression.");
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
}

static void ExplicitUserStopReleasesAutomaticOwnership()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.SuppressUntilMeetingEnd()).Snapshot;
    Equal(RecordingOwner.None, snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), snapshot.State);
}

static void CommittedStopWaitsForCompletion()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    Equal(new TeamsAutoMeetingState.Stopping(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.Stopping(), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted()).Snapshot;
    Equal(new TeamsAutoMeetingState.StartCountdown(1), snapshot.State);
}

static void DisableTransfersOwnership()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var transition = machine.Reduce(StartAutomaticRecording(machine), new TeamsAutoMeetingEvent.AutoMeetingEnabled(false));
    Equal(new TeamsAutoMeetingState.Disabled(), transition.Snapshot.State);
    Equal(RecordingOwner.Manual, transition.Snapshot.RecordingOwner);
    Commands(transition, new TeamsAutoMeetingCommand.TransferAutomaticRecordingToManual());
}

static void DisableWhileStartingCancelsStart()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    var transition = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutoMeetingEnabled(false));
    Equal(new TeamsAutoMeetingState.Disabled(), transition.Snapshot.State);
    Commands(transition, new TeamsAutoMeetingCommand.CancelAutomaticStart());
}

static void ManualStartDoesNotStealAutomaticOwnership()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var transition = machine.Reduce(StartAutomaticRecording(machine), new TeamsAutoMeetingEvent.ManualRecordingStarted());
    Equal(RecordingOwner.TeamsAutomatic, transition.Snapshot.RecordingOwner);
    Equal(new TeamsAutoMeetingState.SuppressedUntilMeetingEnd(), transition.Snapshot.State);
    Equal(0, transition.Commands.Count);
}

static void LateCompletionsAreIdempotent()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1, stopDebounceSeconds: 1);
    var snapshot = StartAutomaticRecording(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StopDebounceTicked()).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted()).Snapshot;
    var repeatedStop = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStopCompleted());
    Equal(snapshot, repeatedStop.Snapshot);
    Equal(0, repeatedStop.Commands.Count);

    var disabled = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutoMeetingEnabled(false)).Snapshot;
    var lateStart = machine.Reduce(disabled, new TeamsAutoMeetingEvent.AutomaticStartSucceeded());
    Equal(disabled, lateStart.Snapshot);
    Equal(0, lateStart.Commands.Count);
}

static void FailedStartWaitsForMeetingEnd()
{
    var machine = new TeamsAutoMeetingMachine(startCountdownSeconds: 1);
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStartFailed("capture unavailable")).Snapshot;
    Equal(new TeamsAutoMeetingState.StartFailed("capture unavailable"), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
    Equal(new TeamsAutoMeetingState.StartFailed("capture unavailable"), snapshot.State);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(false)).Snapshot;
    Equal(new TeamsAutoMeetingState.WaitingForMeeting(), snapshot.State);
}

static void NativeCoordinatorStartsRefreshesAndStops()
{
    var bridge = new FakeNativeRecorderBridge();
    var coordinator = new RecordingCoordinator(bridge);
    var request = SystemLoopbackRequest();

    var started = coordinator.StartAsync(request).GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Recording, started.State);
    Equal(request, started.Request!);

    bridge.Stats = bridge.Stats with
    {
        Packets = 4,
        InputFrames = 1_920,
        OutputFrames = 1_920,
        Peak = 0.75F,
    };
    var refreshed = coordinator.RefreshAsync().GetAwaiter().GetResult();
    Equal((ulong)4, refreshed.Stats.Packets);
    Equal(0.75F, refreshed.Stats.Peak);

    var firstStop = coordinator.StopAsync();
    var secondStop = coordinator.StopAsync();
    var stopped = firstStop.GetAwaiter().GetResult();
    secondStop.GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Stopped, stopped.State);
    Equal(1, bridge.StopCalls);
}

static void NativeCoordinatorExposesEndpointSnapshots()
{
    var expectedEndpoint = new NativeCaptureEndpoint(
        CaptureEndpointFlow.Render,
        EndpointDefaultRole.Console | EndpointDefaultRole.Multimedia,
        "render-endpoint-id",
        "Speakers");
    var bridge = new FakeNativeRecorderBridge
    {
        EndpointResult = new NativeEndpointEnumerationResult(
            NativeOperationResult.Success(),
            [expectedEndpoint]),
    };
    var coordinator = new RecordingCoordinator(bridge);

    var endpoints = coordinator.RefreshEndpointsAsync().GetAwaiter().GetResult();
    if (!endpoints.IsSuccess)
    {
        throw new InvalidOperationException(endpoints.Operation.Error);
    }
    Equal(1, endpoints.Endpoints.Count);
    Equal(expectedEndpoint, endpoints.Endpoints[0]);
}

static void EndpointRefreshRetainsExplicitDeviceChoices()
{
    var available = new[]
    {
        new NativeCaptureEndpoint(
            CaptureEndpointFlow.Render,
            EndpointDefaultRole.Console,
            "render-speakers",
            "Speakers"),
    };

    var retained = EndpointRefreshSelection.Retain("render-speakers", available);
    Equal("render-speakers", retained.EndpointId!);
    Equal(true, retained.IsAvailable);

    var disconnected = EndpointRefreshSelection.Retain("render-headset", available);
    Equal("render-headset", disconnected.EndpointId!);
    Equal(false, disconnected.IsAvailable);

    var intentionalDefault = EndpointRefreshSelection.Retain(null, available);
    if (intentionalDefault.EndpointId is not null || !intentionalDefault.IsAvailable)
    {
        throw new InvalidOperationException("Refreshing endpoints must not replace an intentional default choice.");
    }
}

static void NativeCoordinatorReportsFailedStartAndAllowsRetry()
{
    var bridge = new FakeNativeRecorderBridge
    {
        StartResult = NativeOperationResult.Failure(
            NativeRecorderResult.CaptureError,
            "The selected microphone is unavailable."),
    };
    var coordinator = new RecordingCoordinator(bridge);

    var failed = coordinator.StartAsync(SystemLoopbackRequest()).GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Failed, failed.State);
    Equal("The selected microphone is unavailable.", failed.Error!);

    bridge.StartResult = NativeOperationResult.Success();
    var retry = coordinator.StartAsync(SystemLoopbackRequest("retry.wav")).GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Recording, retry.State);
    Equal(2L, retry.Generation);
}

static void NativeCoordinatorFaultsAfterFailedStop()
{
    var bridge = new FakeNativeRecorderBridge
    {
        StopResult = NativeOperationResult.Failure(
            NativeRecorderResult.CaptureError,
            "The capture writer could not finalize."),
    };
    var coordinator = new RecordingCoordinator(bridge);

    coordinator.StartAsync(SystemLoopbackRequest()).GetAwaiter().GetResult();
    var faulted = coordinator.StopAsync().GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Faulted, faulted.State);
    if (faulted.NeedsNativeCleanup)
    {
        throw new InvalidOperationException("A failed stop must not schedule another native cleanup attempt.");
    }
    Throws<InvalidOperationException>(() => coordinator.StartAsync(SystemLoopbackRequest("retry.wav")));
}

static void NativeCoordinatorRequestsCleanupAfterInRecordingFault()
{
    var bridge = new FakeNativeRecorderBridge
    {
        SnapshotResult = NativeRecorderResult.CaptureError,
        SnapshotError = "The capture writer reported an I/O failure.",
        StopResult = NativeOperationResult.Failure(
            NativeRecorderResult.CaptureError,
            "The capture writer reported an I/O failure."),
    };
    var coordinator = new RecordingCoordinator(bridge);

    coordinator.StartAsync(SystemLoopbackRequest()).GetAwaiter().GetResult();
    var faulted = coordinator.RefreshAsync().GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Faulted, faulted.State);
    if (!faulted.NeedsNativeCleanup)
    {
        throw new InvalidOperationException("An in-recording native fault must request cleanup.");
    }

    var afterCleanup = coordinator.StopAsync().GetAwaiter().GetResult();
    Equal(1, bridge.StopCalls);
    Equal(RecordingCoordinatorState.Faulted, afterCleanup.State);
    if (afterCleanup.NeedsNativeCleanup)
    {
        throw new InvalidOperationException("The failed cleanup must not loop indefinitely.");
    }
}

static void NativeCoordinatorSuppressesLateStartAfterStop()
{
    using var releaseStart = new ManualResetEventSlim(false);
    var bridge = new FakeNativeRecorderBridge
    {
        StartRelease = releaseStart,
    };
    var coordinator = new RecordingCoordinator(bridge);
    var states = new List<RecordingCoordinatorState>();
    coordinator.SnapshotChanged += (_, changed) =>
    {
        lock (states)
        {
            states.Add(changed.State);
        }
    };

    var startTask = coordinator.StartAsync(SystemLoopbackRequest());
    if (!bridge.StartEntered.Task.Wait(TimeSpan.FromSeconds(2)))
    {
        throw new InvalidOperationException("The fake native start did not begin.");
    }

    var stopTask = coordinator.StopAsync();
    Equal(RecordingCoordinatorState.Stopping, coordinator.Snapshot.State);
    releaseStart.Set();

    startTask.GetAwaiter().GetResult();
    var stopped = stopTask.GetAwaiter().GetResult();
    Equal(RecordingCoordinatorState.Stopped, stopped.State);
    Equal(1, bridge.StopCalls);
    lock (states)
    {
        if (states.Contains(RecordingCoordinatorState.Recording))
        {
            throw new InvalidOperationException("A stale start published a recording state after stop was requested.");
        }
    }
}

static void TestRecordingStopsExactlyOnce()
{
    var bridge = new FakeNativeRecorderBridge();
    var delay = new ControllableRecordingDelay();
    var coordinator = new RecordingCoordinator(bridge, delay);
    using var stopped = new ManualResetEventSlim(false);
    coordinator.SnapshotChanged += (_, changed) =>
    {
        if (changed.State == RecordingCoordinatorState.Stopped)
        {
            stopped.Set();
        }
    };

    var started = coordinator.StartTestAsync(SystemLoopbackRequest(), TimeSpan.FromSeconds(10))
        .GetAwaiter()
        .GetResult();
    Equal(RecordingCoordinatorState.Recording, started.State);
    if (!started.IsTestRecording)
    {
        throw new InvalidOperationException("Expected the session to be marked as a test recording.");
    }
    if (!delay.Entered.Task.Wait(TimeSpan.FromSeconds(2)))
    {
        throw new InvalidOperationException("The test delay was not scheduled.");
    }

    delay.Complete();
    if (!stopped.Wait(TimeSpan.FromSeconds(2)))
    {
        throw new InvalidOperationException("The scheduled test stop did not complete.");
    }
    Equal(1, bridge.StopCalls);
}

static TeamsAutoMeetingSnapshot EnableAndEnterMeeting(TeamsAutoMeetingMachine machine)
{
    var snapshot = machine.Reduce(TeamsAutoMeetingSnapshot.Initial, new TeamsAutoMeetingEvent.AutoMeetingEnabled(true)).Snapshot;
    return machine.Reduce(snapshot, new TeamsAutoMeetingEvent.MeetingPresenceChanged(true)).Snapshot;
}

static TeamsAutoMeetingSnapshot StartAutomaticRecording(TeamsAutoMeetingMachine machine)
{
    var snapshot = EnableAndEnterMeeting(machine);
    snapshot = machine.Reduce(snapshot, new TeamsAutoMeetingEvent.StartCountdownTicked()).Snapshot;
    return machine.Reduce(snapshot, new TeamsAutoMeetingEvent.AutomaticStartSucceeded()).Snapshot;
}

static void Commands(TeamsAutoMeetingTransition transition, params TeamsAutoMeetingCommand[] expected)
{
    Equal(expected.Length, transition.Commands.Count);
    for (var i = 0; i < expected.Length; i++) Equal(expected[i], transition.Commands[i]);
}

static void Equal<T>(T expected, T actual) where T : notnull
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
        throw new InvalidOperationException($"Expected {expected}; got {actual}.");
}

static void Throws<TException>(Action action) where TException : Exception
{
    try
    {
        action();
    }
    catch (TException)
    {
        return;
    }

    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static NativeRecordingRequest SystemLoopbackRequest(string fileName = "recording.wav") => new(
    RecordingCaptureMode.SystemLoopback,
    $"C:\\recordings\\{fileName}");

sealed class FakeNativeRecorderBridge : INativeRecorderBridge
{
    private readonly object gate = new();
    private NativeRecorderState state = NativeRecorderState.Ready;

    public NativeOperationResult StartResult { get; set; } = NativeOperationResult.Success();

    public NativeOperationResult StopResult { get; set; } = NativeOperationResult.Success();

    public NativeRecorderResult SnapshotResult { get; set; } = NativeRecorderResult.Ok;

    public string? SnapshotError { get; set; }

    public NativeCaptureStats Stats { get; set; } = NativeCaptureStats.Empty(RecordingCaptureMode.SystemLoopback);

    public NativeEndpointEnumerationResult EndpointResult { get; set; } = new(
        NativeOperationResult.Success(),
        Array.Empty<NativeCaptureEndpoint>());

    public ManualResetEventSlim? StartRelease { get; set; }

    public TaskCompletionSource StartEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public int StopCalls { get; private set; }

    public NativeOperationResult Start(NativeRecordingRequest request)
    {
        StartEntered.TrySetResult();
        StartRelease?.Wait();
        lock (gate)
        {
            if (StartResult.IsSuccess)
            {
                state = NativeRecorderState.Recording;
            }
            return StartResult;
        }
    }

    public NativeOperationResult StartMixed(NativeMixedRecordingRequest request)
    {
        request.Validate();
        StartEntered.TrySetResult();
        StartRelease?.Wait();
        lock (gate)
        {
            if (StartResult.IsSuccess)
            {
                state = NativeRecorderState.Recording;
            }
            return StartResult;
        }
    }

    public NativeOperationResult Stop()
    {
        lock (gate)
        {
            StopCalls++;
            if (StopResult.IsSuccess)
            {
                state = NativeRecorderState.Stopped;
            }
            return StopResult;
        }
    }

    public NativeRecorderSnapshot GetSnapshot()
    {
        lock (gate)
        {
            return new NativeRecorderSnapshot(SnapshotResult, state, Stats, SnapshotError);
        }
    }

    public NativeEndpointEnumerationResult EnumerateEndpoints() => EndpointResult;

    public void Dispose()
    {
    }
}

sealed class ControllableRecordingDelay : IRecordingDelay
{
    private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken)
    {
        Entered.TrySetResult();
        return completion.Task.WaitAsync(cancellationToken);
    }

    public void Complete() => completion.TrySetResult();
}
