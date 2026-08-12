using TeamsRecorder.Windows.Application.Transcription;

return await MediaFoundationAsrWorkerHost.RunAsync(args, Console.In, Console.Out, CancellationToken.None);
