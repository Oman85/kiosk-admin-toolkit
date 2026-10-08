// CSV for the events file and the launchers' ledgers, read and written the
// way Python's csv module does it - fast enough for 400 days of a fleet,
// which a PowerShell loop over characters is not.
using System;
using System.Collections.Generic;
using System.Text;

namespace KioskFleetWeb
{
    public static class Csv
    {
        // Every record of the text, each a list of fields. Quotes may wrap a
        // field ("" is a quote inside one) and a quoted field may hold line
        // breaks. Empty lines are no record.
        public static List<string[]> Records(string text)
        {
            var records = new List<string[]>();
            var fields = new List<string>();
            var field = new StringBuilder();
            int i = 0, n = text.Length;
            bool inQuotes = false, any = false;
            while (i < n)
            {
                char c = text[i];
                if (inQuotes)
                {
                    if (c == '"')
                    {
                        if (i + 1 < n && text[i + 1] == '"') { field.Append('"'); i += 2; continue; }
                        inQuotes = false; i++; continue;
                    }
                    field.Append(c); i++; continue;
                }
                if (c == '"' && field.Length == 0) { inQuotes = true; any = true; i++; continue; }
                if (c == ',') { fields.Add(field.ToString()); field.Clear(); any = true; i++; continue; }
                if (c == '\r' || c == '\n')
                {
                    if (any || field.Length > 0) { fields.Add(field.ToString()); records.Add(fields.ToArray()); }
                    fields.Clear(); field.Clear(); any = false;
                    if (c == '\r' && i + 1 < n && text[i + 1] == '\n') i++;
                    i++; continue;
                }
                field.Append(c); any = true; i++;
            }
            if (any || field.Length > 0) { fields.Add(field.ToString()); records.Add(fields.ToArray()); }
            return records;
        }

        // The records after the first, as dictionaries by the first's names.
        // A missing field is "", an extra one is dropped.
        public static List<Dictionary<string, string>> Rows(string text)
        {
            var records = Records(text);
            var rows = new List<Dictionary<string, string>>(Math.Max(0, records.Count - 1));
            if (records.Count == 0) return rows;
            var header = records[0];
            for (int r = 1; r < records.Count; r++)
            {
                var f = records[r];
                var d = new Dictionary<string, string>(header.Length, StringComparer.Ordinal);
                for (int j = 0; j < header.Length; j++) d[header[j]] = j < f.Length ? f[j] : "";
                rows.Add(d);
            }
            return rows;
        }

        // The order of these keys, compared character by character as Python
        // compares strings, ties kept in their first order: a stable sort.
        public static int[] Order(string[] keys, bool descending)
        {
            var idx = new int[keys.Length];
            for (int i = 0; i < idx.Length; i++) idx[i] = i;
            Array.Sort(idx, (a, b) =>
            {
                int c = string.CompareOrdinal(keys[a], keys[b]);
                if (descending) c = -c;
                return c != 0 ? c : a.CompareTo(b);
            });
            return idx;
        }

        public static string Field(string value, bool always)
        {
            value = value ?? "";
            if (always || value.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0)
                return "\"" + value.Replace("\"", "\"\"") + "\"";
            return value;
        }

        // Rows (dictionaries) under a header of these columns, CRLF after each line.
        public static string Write(System.Collections.IEnumerable rows, string[] columns, bool quoteAll)
        {
            var sb = new StringBuilder();
            for (int j = 0; j < columns.Length; j++) { if (j > 0) sb.Append(','); sb.Append(Field(columns[j], quoteAll)); }
            sb.Append("\r\n");
            foreach (var o in rows)
            {
                var d = o as System.Collections.IDictionary;
                for (int j = 0; j < columns.Length; j++)
                {
                    if (j > 0) sb.Append(',');
                    object v = d != null && d.Contains(columns[j]) ? d[columns[j]] : null;
                    sb.Append(Field(v == null ? "" : v.ToString(), quoteAll));
                }
                sb.Append("\r\n");
            }
            return sb.ToString();
        }
    }
}
