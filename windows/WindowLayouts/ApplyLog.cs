using System;
using System.IO;

namespace WindowLayouts;

/// <summary>Writes the apply log: %LOCALAPPDATA%\WindowLayouts\apply.log</summary>
public static class ApplyLog
{
    public static string FilePath => Path.Combine(LayoutStore.Shared.DirectoryPath, "apply.log");
    private static readonly object Gate = new();
    private const long MaxBytes = 512 * 1024;

    public static void Write(string line)
    {
        lock (Gate)
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes) info.Delete();
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}{Environment.NewLine}");
            }
            catch { }
        }
    }
}
