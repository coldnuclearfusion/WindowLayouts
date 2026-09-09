using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace WindowLayouts;

/// <summary>Matches saved window entries to real windows.</summary>
public static class WindowMatcher
{
    public static List<(WindowEntry entry, WindowInfo? window)> Match(IList<WindowEntry> entries, IList<WindowInfo> windows)
    {
        var available = windows.ToList();
        var assigned = new Dictionary<Guid, WindowInfo>();

        // 1) exact title match
        foreach (var e in entries)
        {
            if (e.TitleMatch == TitleMatch.Order || string.IsNullOrEmpty(e.Title)) continue;
            int i = available.FindIndex(w => w.Title == e.Title);
            if (i >= 0) { assigned[e.Id] = available[i]; available.RemoveAt(i); }
        }

        // 2) similar titles (for example tab titles that partly changed), best pairs first.
        //    Words shared by all windows (such as the app name) are excluded from the score.
        var boilerplate = CommonTokens(available.Select(w => w.Title));
        var candidates = new List<(int ei, int wi, double score)>();
        for (int ei = 0; ei < entries.Count; ei++)
        {
            var e = entries[ei];
            if (assigned.ContainsKey(e.Id) || e.TitleMatch == TitleMatch.Order || string.IsNullOrEmpty(e.Title)) continue;
            for (int wi = 0; wi < available.Count; wi++)
            {
                double s = Similarity(e.Title, available[wi].Title, boilerplate);
                if (s >= 0.3) candidates.Add((ei, wi, s));
            }
        }
        candidates.Sort((a, b) => b.score.CompareTo(a.score));
        var usedEntries = new HashSet<int>();
        var usedWindows = new HashSet<int>();
        foreach (var c in candidates)
        {
            if (usedEntries.Contains(c.ei) || usedWindows.Contains(c.wi)) continue;
            assigned[entries[c.ei].Id] = available[c.wi];
            usedEntries.Add(c.ei);
            usedWindows.Add(c.wi);
        }
        available = available.Where((w, i) => !usedWindows.Contains(i)).ToList();

        // 3) remaining entries take the remaining windows in order
        foreach (var e in entries)
        {
            if (assigned.ContainsKey(e.Id)) continue;
            if (e.TitleMatch == TitleMatch.Title && !string.IsNullOrEmpty(e.Title)) continue;
            if (available.Count == 0) break;
            assigned[e.Id] = available[0];
            available.RemoveAt(0);
        }

        return entries.Select(e => (e, assigned.TryGetValue(e.Id, out var w) ? w : null)).ToList();
    }

    private static readonly Regex Splitter = new(@"[^\p{L}\p{N}]+", RegexOptions.Compiled);

    public static HashSet<string> Tokens(string s) =>
        Splitter.Split(s.ToLowerInvariant()).Where(t => t.Length > 0).ToHashSet(StringComparer.Ordinal);

    /// <summary>Words that appear in every one of two or more window titles</summary>
    public static HashSet<string> CommonTokens(IEnumerable<string> titles)
    {
        var list = titles.ToList();
        if (list.Count < 2) return new HashSet<string>(StringComparer.Ordinal);
        var common = Tokens(list[0]);
        foreach (var t in list.Skip(1)) common.IntersectWith(Tokens(t));
        return common;
    }

    public static double Similarity(string a, string b, HashSet<string>? boilerplate = null)
    {
        var la = a.ToLowerInvariant();
        var lb = b.ToLowerInvariant();
        if (la == lb) return 1;
        var ta = Tokens(la);
        var tb = Tokens(lb);
        if (boilerplate != null) { ta.ExceptWith(boilerplate); tb.ExceptWith(boilerplate); }
        if (ta.Count == 0 || tb.Count == 0) return 0;
        if (la.Contains(lb) || lb.Contains(la)) return 0.9;
        int common = ta.Count(t => tb.Contains(t));
        return (double)common / Math.Min(ta.Count, tb.Count);
    }
}
